import Foundation
import Testing
@testable import Promote

private func leaf(_ tabs: String..., active: Int = 0) -> LayoutNode { .leaf(tabs: tabs, active: active) }

@Suite struct LayoutTests {
    @Test func insertTabAppendsAndActivates() {
        #expect(leaf("a").insertTab("b", into: "a") == leaf("a", "b", active: 1))
    }

    @Test func insertTabIsNoOpWhenPresent() {
        let t = leaf("a", "b")
        #expect(t.insertTab("b", into: "a") == t)
    }

    @Test func splitReplacesFocusedLeaf() {
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("b"))
        let next = t.split("c", beside: "b", axis: .vertical)
        #expect(next == .split(axis: .horizontal, ratio: 0.5, first: leaf("a"),
                               second: .split(axis: .vertical, ratio: 0.5, first: leaf("b"), second: leaf("c"))))
    }

    @Test func splitIsNoOpWhenPresent() {
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("b"))
        #expect(t.split("b", beside: "a", axis: .vertical) == t)
    }

    @Test func removingTabClampsActive() {
        #expect(leaf("a", "b", active: 1).removing("b") == leaf("a"))
        #expect(leaf("a", "b", "c", active: 2).removing("a") == leaf("b", "c", active: 1))
        #expect(leaf("a", "b", "c", active: 0).removing("c") == leaf("a", "b", active: 0))
    }

    @Test func removingLastTabCollapsesSplit() {
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.3, first: leaf("a"), second: leaf("b", "c"))
        #expect(t.removing("a") == leaf("b", "c"))
        #expect(leaf("a").removing("a") == nil)
    }

    @Test func renamingAndActivating() {
        let t = LayoutNode.split(axis: .vertical, ratio: 0.5, first: leaf("a", "b"), second: leaf("c"))
        #expect(t.renaming("b", to: "z").allSessions == ["a", "z", "c"])
        #expect(t.activating("b") == .split(axis: .vertical, ratio: 0.5, first: leaf("a", "b", active: 1), second: leaf("c")))
        #expect(t.leafTabs(containing: "c") == ["c"])
        #expect(t.leafTabs(containing: "x") == nil)
    }

    @Test func settingRatioByPathAndClamp() {
        let inner = LayoutNode.split(axis: .vertical, ratio: 0.5, first: leaf("b"), second: leaf("c"))
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: inner)
        #expect(t.settingRatio(at: [], 0.95) == .split(axis: .horizontal, ratio: 0.9, first: leaf("a"), second: inner))
        #expect(t.settingRatio(at: [true], 0.25) == .split(axis: .horizontal, ratio: 0.5, first: leaf("a"),
            second: .split(axis: .vertical, ratio: 0.25, first: leaf("b"), second: leaf("c"))))
    }

    @Test func reconcileBuildsLeafFromTagsWhenNoLayout() {
        #expect(LayoutNode.reconcile(nil, members: ["a", "b"], prunable: []) == leaf("a", "b"))
        #expect(LayoutNode.reconcile(nil, members: ["a"], prunable: []) == nil)
    }

    @Test func reconcileAddsMissingMembersToFirstLeaf() {
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("b"))
        #expect(LayoutNode.reconcile(t, members: ["a", "b", "c"], prunable: ["a", "b"])
                == .split(axis: .horizontal, ratio: 0.5, first: leaf("a", "c"), second: leaf("b")))
    }

    @Test func reconcilePrunesOnlyPrunable() {
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a", "x"), second: leaf("b"))
        // x dead and seen → pruned
        #expect(LayoutNode.reconcile(t, members: ["a", "b"], prunable: ["a", "b", "x"])
                == .split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("b")))
        // x never seen alive (reboot, not restored yet) → kept
        #expect(LayoutNode.reconcile(t, members: ["a", "b"], prunable: ["a", "b"]) == t)
    }

    @Test func reconcileKeepsPendingUntaggedFocused() {
        // first split: focused "a" untagged in tmux but pending → caller passes it as member, not prunable
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("a-2"))
        #expect(LayoutNode.reconcile(t, members: ["a", "a-2"], prunable: []) == t)
    }

    @Test func reconcileDropsGroupUnderTwoMembers() {
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("b"))
        #expect(LayoutNode.reconcile(t, members: ["a"], prunable: ["a", "b"]) == nil)
    }

    @Test func codableRoundTrip() throws {
        let t = LayoutNode.split(axis: .vertical, ratio: 0.4, first: leaf("a", "b", active: 1), second: leaf("c"))
        let data = try JSONEncoder().encode(["g1": t])
        #expect(try JSONDecoder().decode([String: LayoutNode].self, from: data) == ["g1": t])
    }

    @Test func nextFreeName() {
        #expect(LayoutNode.nextFreeName(base: "api", taken: ["api"]) == "api-2")
        #expect(LayoutNode.nextFreeName(base: "api-2", taken: ["api", "api-2"]) == "api-3")
        #expect(LayoutNode.nextFreeName(base: "api", taken: ["api", "api-2", "api-4"]) == "api-3")
        #expect(LayoutNode.nextFreeName(base: "100", taken: ["100"]) == "100-2")
        #expect(LayoutNode.nextFreeName(base: "v2-nft", taken: ["v2-nft"]) == "v2-nft-2")
        #expect(LayoutNode.nextFreeName(base: "-3", taken: []) == "-3-2")
    }
}
