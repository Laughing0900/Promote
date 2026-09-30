import Foundation

// Grid layout for a session group: binary splits nest into any grid, leaves hold tabs.
// Pure value type — no tmux, no AppKit — so it's unit-tested (Tests/PromoteTests).
enum SplitAxis: String, Codable {
    case horizontal   // first | second
    case vertical     // first over second
}

indirect enum LayoutNode: Codable, Equatable {
    case leaf(tabs: [String], active: Int)   // session names, never empty
    case split(axis: SplitAxis, ratio: Double, first: LayoutNode, second: LayoutNode)

    static let ratioRange = 0.1...0.9

    var allSessions: [String] {
        switch self {
        case .leaf(let tabs, _): return tabs
        case .split(_, _, let a, let b): return a.allSessions + b.allSessions
        }
    }

    func contains(_ name: String) -> Bool { allSessions.contains(name) }

    func leafTabs(containing name: String) -> [String]? {
        switch self {
        case .leaf(let tabs, _): return tabs.contains(name) ? tabs : nil
        case .split(_, _, let a, let b): return a.leafTabs(containing: name) ?? b.leafTabs(containing: name)
        }
    }

    // append as a tab of the leaf holding `focused`, make it active
    func insertTab(_ name: String, into focused: String) -> LayoutNode {
        guard !contains(name) else { return self }
        return mapLeaf(containing: focused) { tabs, _ in .leaf(tabs: tabs + [name], active: tabs.count) }
    }

    // replace the leaf holding `focused` with a split: that leaf first, new tab second
    func split(_ name: String, beside focused: String, axis: SplitAxis) -> LayoutNode {
        guard !contains(name) else { return self }
        return mapLeaf(containing: focused) { tabs, active in
            .split(axis: axis, ratio: 0.5, first: .leaf(tabs: tabs, active: active), second: .leaf(tabs: [name], active: 0))
        }
    }

    // nil = tree empty; a split left with one child collapses into it
    func removing(_ name: String) -> LayoutNode? {
        switch self {
        case .leaf(let tabs, let active):
            guard let i = tabs.firstIndex(of: name) else { return self }
            var rest = tabs
            rest.remove(at: i)
            if rest.isEmpty { return nil }
            return .leaf(tabs: rest, active: i < active ? active - 1 : min(active, rest.count - 1))
        case .split(let axis, let ratio, let a, let b):
            switch (a.removing(name), b.removing(name)) {
            case (nil, nil): return nil
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (let x?, let y?): return .split(axis: axis, ratio: ratio, first: x, second: y)
            }
        }
    }

    func renaming(_ old: String, to new: String) -> LayoutNode {
        switch self {
        case .leaf(let tabs, let active):
            return .leaf(tabs: tabs.map { $0 == old ? new : $0 }, active: active)
        case .split(let axis, let ratio, let a, let b):
            return .split(axis: axis, ratio: ratio, first: a.renaming(old, to: new), second: b.renaming(old, to: new))
        }
    }

    func activating(_ name: String) -> LayoutNode {
        mapLeaf(containing: name) { tabs, _ in .leaf(tabs: tabs, active: tabs.firstIndex(of: name) ?? 0) }
    }

    // path addresses a split from the root: false = first child, true = second; [] = self
    func settingRatio(at path: [Bool], _ ratio: Double) -> LayoutNode {
        guard case .split(let axis, let current, let a, let b) = self else { return self }
        guard let head = path.first else {
            let clamped = min(max(ratio, Self.ratioRange.lowerBound), Self.ratioRange.upperBound)
            return .split(axis: axis, ratio: clamped, first: a, second: b)
        }
        let rest = Array(path.dropFirst())
        return head
            ? .split(axis: axis, ratio: current, first: a, second: b.settingRatio(at: rest, ratio))
            : .split(axis: axis, ratio: current, first: a.settingRatio(at: rest, ratio), second: b)
    }

    // Converge a stored layout onto tmux truth. `members` = live tagged + pending sessions.
    // Only `prunable` names (seen alive this run, not pending) may be dropped, so a partial
    // list after a reboot can't wipe cells. Under two sessions left = no longer a group.
    static func reconcile(_ layout: LayoutNode?, members: [String], prunable: Set<String>) -> LayoutNode? {
        let memberSet = Set(members)
        var tree = layout
        for name in layout?.allSessions ?? [] where !memberSet.contains(name) && prunable.contains(name) {
            tree = tree?.removing(name)
        }
        for name in members where !(tree?.contains(name) ?? false) {
            tree = tree?.appendingToFirstLeaf(name) ?? .leaf(tabs: [name], active: 0)
        }
        guard let tree, tree.allSessions.count >= 2 else { return nil }
        return tree
    }

    // naming only — grouping never parses names. "api" / "api-2" → lowest free "api-N", N ≥ 2
    static func nextFreeName(base: String, taken: Set<String>) -> String {
        var stem = base
        if let dash = base.lastIndex(of: "-"), dash != base.startIndex,
           Int(base[base.index(after: dash)...]) != nil {
            stem = String(base[..<dash])
        }
        var n = 2
        while taken.contains("\(stem)-\(n)") { n += 1 }
        return "\(stem)-\(n)"
    }

    private func appendingToFirstLeaf(_ name: String) -> LayoutNode {
        switch self {
        case .leaf(let tabs, let active): return .leaf(tabs: tabs + [name], active: active)
        case .split(let axis, let ratio, let a, let b):
            return .split(axis: axis, ratio: ratio, first: a.appendingToFirstLeaf(name), second: b)
        }
    }

    private func mapLeaf(containing name: String, _ transform: ([String], Int) -> LayoutNode) -> LayoutNode {
        switch self {
        case .leaf(let tabs, let active):
            return tabs.contains(name) ? transform(tabs, active) : self
        case .split(let axis, let ratio, let a, let b):
            return .split(axis: axis, ratio: ratio,
                          first: a.mapLeaf(containing: name, transform),
                          second: b.mapLeaf(containing: name, transform))
        }
    }
}
