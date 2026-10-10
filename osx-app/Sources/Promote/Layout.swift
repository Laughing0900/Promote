import Foundation

// Grid layout for a session group: binary splits nest into any grid, leaves hold tabs.
// Pure value type — no tmux, no AppKit — so it's unit-tested (Tests/PromoteTests).
enum SplitAxis: String, Codable {
    case horizontal   // first | second
    case vertical     // first over second
}

enum SplitDirection: String, CaseIterable {
    case up, down, left, right

    var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
    var comesFirst: Bool { self == .up || self == .left }
    var title: String { rawValue.capitalized }
    var moveTitle: String {
        switch self {
        case .up: return "Above"
        case .down: return "Below"
        case .left: return "Left"
        case .right: return "Right"
        }
    }

    // Coordinates are normalized with the origin at the top left.
    static func dropEdge(x: Double, y: Double) -> SplitDirection? {
        let distances: [(SplitDirection, Double)] = [(.left, x), (.right, 1 - x), (.up, y), (.down, 1 - y)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < 0.25 else { return nil }
        return nearest.0
    }
}

indirect enum LayoutNode: Codable, Equatable {
    case leaf(tabs: [String], active: Int)   // an empty array is an intentional empty pane
    case split(axis: SplitAxis, ratio: Double, first: LayoutNode, second: LayoutNode)

    static let ratioRange = 0.1...0.9

    var allSessions: [String] {
        switch self {
        case .leaf(let tabs, _): return tabs
        case .split(_, _, let a, let b): return a.allSessions + b.allSessions
        }
    }

    var hasEmptyPane: Bool {
        switch self {
        case .leaf(let tabs, _): return tabs.isEmpty
        case .split(_, _, let a, let b): return a.hasEmptyPane || b.hasEmptyPane
        }
    }

    // A single session still needs a layout when it sits beside an empty pane.
    var isPersistentLayout: Bool { allSessions.count >= 2 || (!allSessions.isEmpty && hasEmptyPane) }

    // Choose focus before reconciliation removes the exited session's location.
    func survivingSession(afterClosing name: String, live: Set<String>) -> String? {
        guard let tabs = leafTabs(containing: name), let index = tabs.firstIndex(of: name) else { return nil }
        let neighbors = Array(tabs.dropFirst(index + 1)) + Array(tabs.prefix(index).reversed())
        if let neighbor = neighbors.first(where: live.contains) { return neighbor }
        // Retain the closing tab as an anchor while pruning other exited sessions.
        var remaining = self
        for dead in allSessions where dead != name && !live.contains(dead) {
            if let next = remaining.removing(dead) { remaining = next }
        }
        return remaining.paneCloseDestination(for: name)
    }

    // Prefer the nearest sibling subtree, keeping its currently visible tab active.
    func paneCloseDestination(for name: String) -> String? {
        guard contains(name) else { return nil }
        switch self {
        case .leaf: return nil
        case .split(_, _, let a, let b):
            return a.contains(name)
                ? a.paneCloseDestination(for: name) ?? b.firstActiveSession
                : b.paneCloseDestination(for: name) ?? a.lastActiveSession
        }
    }

    private var firstActiveSession: String? {
        switch self {
        case .leaf(let tabs, let active): return tabs.isEmpty ? nil : tabs[min(max(active, 0), tabs.count - 1)]
        case .split(_, _, let a, let b): return a.firstActiveSession ?? b.firstActiveSession
        }
    }

    private var lastActiveSession: String? {
        switch self {
        case .leaf: return firstActiveSession
        case .split(_, _, let a, let b): return b.lastActiveSession ?? a.lastActiveSession
        }
    }

    // nil means there is no split to close. Every session survives as a tab.
    func closingPane(containing name: String) -> LayoutNode? {
        guard case .split = self, let tabs = leafTabs(containing: name) else { return nil }
        guard let destination = paneCloseDestination(for: name) else {
            // Only empty panes remain: collapse them and keep this session's tabs.
            return .leaf(tabs: tabs, active: tabs.firstIndex(of: name) ?? 0)
        }
        var next = self
        for tab in tabs {
            guard let rest = next.removing(tab) else { return nil }
            next = rest.insertTab(tab, into: destination)
        }
        return next.activating(destination)
    }

    func splittingOff(_ name: String, direction: SplitDirection) -> LayoutNode {
        mapLeaf(containing: name) { tabs, active in
            let rest = LayoutNode.leaf(tabs: tabs, active: active).removing(name) ?? .leaf(tabs: [], active: 0)
            let moved = LayoutNode.leaf(tabs: [name], active: 0)
            return .split(axis: direction.axis, ratio: 0.5,
                          first: direction.comesFirst ? moved : rest,
                          second: direction.comesFirst ? rest : moved)
        }
    }

    func isEmptyPane(at path: [Bool]) -> Bool {
        if path.isEmpty {
            if case .leaf(let tabs, _) = self { return tabs.isEmpty }
            return false
        }
        guard case .split(_, _, let a, let b) = self else { return false }
        return (path[0] ? b : a).isEmptyPane(at: Array(path.dropFirst()))
    }

    func fillingEmptyPane(at path: [Bool], with name: String) -> LayoutNode {
        guard isEmptyPane(at: path) else { return self }
        // Fill and remove in one pass: collapsing the source first would change the path.
        func visit(_ node: LayoutNode, _ here: [Bool]) -> LayoutNode? {
            switch node {
            case .leaf:
                return here == path ? .leaf(tabs: [name], active: 0) : node.removing(name)
            case .split(let axis, let ratio, let a, let b):
                switch (visit(a, here + [false]), visit(b, here + [true])) {
                case (let a?, let b?): return .split(axis: axis, ratio: ratio, first: a, second: b)
                case (let a?, nil): return a
                case (nil, let b?): return b
                case (nil, nil): return nil
                }
            }
        }
        return visit(self, []) ?? self
    }

    func closingEmptyPane(at path: [Bool]) -> LayoutNode? {
        guard isEmptyPane(at: path) else { return self }
        if path.isEmpty { return nil }
        guard case .split(let axis, let ratio, let a, let b) = self else { return self }
        let rest = Array(path.dropFirst())
        if path[0] {
            guard let next = b.closingEmptyPane(at: rest) else { return a }
            return .split(axis: axis, ratio: ratio, first: a, second: next)
        }
        guard let next = a.closingEmptyPane(at: rest) else { return b }
        return .split(axis: axis, ratio: ratio, first: next, second: b)
    }

    func contains(_ name: String) -> Bool { allSessions.contains(name) }

    func leafTabs(containing name: String) -> [String]? {
        switch self {
        case .leaf(let tabs, _): return tabs.contains(name) ? tabs : nil
        case .split(_, _, let a, let b): return a.leafTabs(containing: name) ?? b.leafTabs(containing: name)
        }
    }

    // The index is a gap in the original tab order (0...count), before removing the source.
    func reorderingTab(_ name: String, inLeafOf target: String, at index: Int) -> LayoutNode {
        mapLeaf(containing: target) { tabs, active in
            guard let oldIndex = tabs.firstIndex(of: name) else { return .leaf(tabs: tabs, active: active) }
            let visible = tabs[min(max(active, 0), tabs.count - 1)]
            let gap = min(max(index, 0), tabs.count)
            var next = tabs
            next.remove(at: oldIndex)
            next.insert(name, at: gap - (oldIndex < gap ? 1 : 0))
            return .leaf(tabs: next, active: next.firstIndex(of: visible) ?? 0)
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

    func split(_ name: String, beside focused: String, direction: SplitDirection) -> LayoutNode {
        guard !contains(name) else { return self }
        return mapLeaf(containing: focused) { tabs, active in
            let existing = LayoutNode.leaf(tabs: tabs, active: active)
            let added = LayoutNode.leaf(tabs: [name], active: 0)
            return .split(axis: direction.axis, ratio: 0.5,
                          first: direction.comesFirst ? added : existing,
                          second: direction.comesFirst ? existing : added)
        }
    }

    // Works for an existing tab or a session arriving from another group.
    func placing(_ name: String, beside target: String, edge: SplitDirection?) -> LayoutNode {
        guard name != target, contains(target) else { return self }
        if edge == nil, leafTabs(containing: target)?.contains(name) == true { return activating(name) }
        guard let base = contains(name) ? removing(name) : self else { return self }
        if let edge { return base.split(name, beside: target, direction: edge) }
        return base.insertTab(name, into: target)
    }

    // Prefer a sibling tab; otherwise choose the closest pane in the requested direction.
    func moveTarget(for name: String, direction: SplitDirection) -> String? {
        if let other = leafTabs(containing: name)?.first(where: { $0 != name }) { return other }
        let leaves = leafFrames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let source = leaves.first(where: { $0.tabs.contains(name) }) else { return nil }
        return leaves.filter { leaf in
            guard !leaf.tabs.contains(name) else { return false }
            switch direction {
            case .left: return leaf.rect.midX < source.rect.midX
            case .right: return leaf.rect.midX > source.rect.midX
            case .up: return leaf.rect.midY < source.rect.midY
            case .down: return leaf.rect.midY > source.rect.midY
            }
        }.min { a, b in
            hypot(a.rect.midX - source.rect.midX, a.rect.midY - source.rect.midY)
                < hypot(b.rect.midX - source.rect.midX, b.rect.midY - source.rect.midY)
        }?.tabs.first
    }

    private func leafFrames(in rect: CGRect) -> [(tabs: [String], rect: CGRect)] {
        switch self {
        case .leaf(let tabs, _): return [(tabs, rect)]
        case .split(let axis, let ratio, let first, let second):
            var a = rect
            var b = rect
            if axis == .horizontal {
                a.size.width *= ratio
                b.origin.x += a.width
                b.size.width -= a.width
            } else {
                a.size.height *= ratio
                b.origin.y += a.height
                b.size.height -= a.height
            }
            return first.leafFrames(in: a) + second.leafFrames(in: b)
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

    // drag a tab into the leaf holding `target`; an emptied source leaf collapses
    func moving(_ name: String, toLeafOf target: String) -> LayoutNode {
        guard name != target, contains(name), let targetTabs = leafTabs(containing: target),
              !targetTabs.contains(name), let rest = removing(name) else { return self }
        return rest.insertTab(name, into: target)
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
    // list after a reboot can't wipe cells. Intentional empty panes keep solo layouts alive.
    static func reconcile(_ layout: LayoutNode?, members: [String], prunable: Set<String>) -> LayoutNode? {
        let memberSet = Set(members)
        var tree = layout
        for name in layout?.allSessions ?? [] where !memberSet.contains(name) && prunable.contains(name) {
            tree = tree?.removing(name)
        }
        for name in members where !(tree?.contains(name) ?? false) {
            tree = tree?.appendingToFirstLeaf(name) ?? .leaf(tabs: [name], active: 0)
        }
        guard let tree, tree.isPersistentLayout else { return nil }
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
