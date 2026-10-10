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

    @Test func movingTabToAnotherLeaf() {
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("b", "c"))
        // source leaf keeps its other tab
        #expect(t.moving("c", toLeafOf: "a")
                == .split(axis: .horizontal, ratio: 0.5, first: leaf("a", "c", active: 1), second: leaf("b")))
        // source leaf emptied → split collapses
        #expect(t.moving("a", toLeafOf: "b") == leaf("b", "c", "a", active: 2))
    }

    @Test func movingWithinSameLeafOrUnknownIsNoOp() {
        let t = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("b", "c"))
        #expect(t.moving("c", toLeafOf: "b") == t)
        #expect(t.moving("x", toLeafOf: "a") == t)
        #expect(t.moving("a", toLeafOf: "x") == t)
    }
}

@Suite struct SessionPlacementTests {
    @Test(arguments: SplitDirection.allCases)
    func splitInEveryDirection(_ direction: SplitDirection) {
        let original = leaf("a", "b", active: 1)
        let next = original.placing("b", beside: "a", edge: direction)
        let expected = LayoutNode.split(axis: direction.axis, ratio: 0.5,
            first: direction.comesFirst ? leaf("b") : leaf("a"),
            second: direction.comesFirst ? leaf("a") : leaf("b"))
        #expect(next == expected)
    }

    @Test func movingAcrossPanesCollapsesSourceAndPreservesOtherTabs() {
        let original = LayoutNode.split(axis: .horizontal, ratio: 0.3,
                                        first: leaf("a"), second: leaf("b", "c", active: 1))
        #expect(original.placing("a", beside: "b", edge: .up)
            == .split(axis: .vertical, ratio: 0.5, first: leaf("a"), second: leaf("b", "c", active: 1)))
        #expect(original.placing("c", beside: "a", edge: .down).allSessions == ["a", "c", "b"])
    }

    @Test func importingAndGroupingSessions() {
        #expect(leaf("a").placing("external", beside: "a", edge: .left)
            == .split(axis: .horizontal, ratio: 0.5, first: leaf("external"), second: leaf("a")))
        #expect(leaf("a").placing("external", beside: "a", edge: nil) == leaf("a", "external", active: 1))
        #expect(leaf("a", "b").placing("b", beside: "a", edge: nil) == leaf("a", "b", active: 1))
        #expect(leaf("a").placing("a", beside: "a", edge: .left) == leaf("a"))
        #expect(leaf("a").placing("b", beside: "missing", edge: .left) == leaf("a"))
    }

    @Test func directionalMovesUseAdjacentPaneOrSiblingTab() {
        let tree = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("b"))
        #expect(tree.moveTarget(for: "a", direction: .right) == "b")
        #expect(tree.moveTarget(for: "b", direction: .left) == "a")
        #expect(tree.moveTarget(for: "a", direction: .left) == nil)
        #expect(leaf("a", "b").moveTarget(for: "a", direction: .up) == "b")
        #expect(leaf("a").moveTarget(for: "a", direction: .up) == nil)
    }

    @Test func dropZonesUseNearestEdgeAndCenterGroups() {
        #expect(SplitDirection.dropEdge(x: 0.1, y: 0.5) == .left)
        #expect(SplitDirection.dropEdge(x: 0.9, y: 0.5) == .right)
        #expect(SplitDirection.dropEdge(x: 0.5, y: 0.1) == .up)
        #expect(SplitDirection.dropEdge(x: 0.5, y: 0.9) == .down)
        #expect(SplitDirection.dropEdge(x: 0.1, y: 0.05) == .up)
        #expect(SplitDirection.dropEdge(x: 0.5, y: 0.5) == nil)
        #expect(SplitDirection.dropEdge(x: 0.25, y: 0.25) == nil)
    }
}

@Suite struct EmptyPaneTests {
    @Test(arguments: SplitDirection.allCases)
    func splittingOnlySessionLeavesEmptyPane(_ direction: SplitDirection) throws {
        let next = leaf("a").splittingOff("a", direction: direction)
        #expect(next.allSessions == ["a"])
        #expect(next.hasEmptyPane)
        #expect(next.isPersistentLayout)
        #expect(next.isEmptyPane(at: [direction.comesFirst]))
        #expect(LayoutNode.reconcile(next, members: ["a"], prunable: ["a"]) == next)
        #expect(try JSONDecoder().decode(LayoutNode.self, from: JSONEncoder().encode(next)) == next)
    }

    @Test func splitExtractsTabFromOwnPane() {
        let original = LayoutNode.split(axis: .horizontal, ratio: 0.3, first: leaf("a", "b", active: 1), second: leaf("c"))
        let next = original.splittingOff("b", direction: .right)
        #expect(next == .split(axis: .horizontal, ratio: 0.3,
            first: .split(axis: .horizontal, ratio: 0.5, first: leaf("a"), second: leaf("b")), second: leaf("c")))
        #expect(!next.hasEmptyPane)
        #expect(original.splittingOff("missing", direction: .right) == original)
    }

    @Test func fillingEmptyPaneMovesWithoutDuplicatingOrLosingSessions() {
        let tree = leaf("a").splittingOff("a", direction: .right)
        #expect(tree.fillingEmptyPane(at: [false], with: "a") == leaf("a"))
        #expect(tree.fillingEmptyPane(at: [false], with: "b")
            == .split(axis: .horizontal, ratio: 0.5, first: leaf("b"), second: leaf("a")))
        #expect(tree.fillingEmptyPane(at: [true], with: "b") == tree)
        let nested = tree.splittingOff("a", direction: .down)
        let moved = nested.fillingEmptyPane(at: [false], with: "a")
        #expect(moved.allSessions == ["a"])
        #expect(moved.hasEmptyPane)
    }

    @Test func closingEmptyPaneAndSessionRemoval() {
        let tree = leaf("a").splittingOff("a", direction: .right)
        #expect(tree.closingEmptyPane(at: [false]) == leaf("a"))
        #expect(tree.closingEmptyPane(at: [true]) == tree)
        #expect(!leaf("a").isPersistentLayout)
        #expect(LayoutNode.reconcile(tree, members: [], prunable: ["a"]) == nil)
        #expect(tree.removing("a")?.isPersistentLayout == false)
    }
}

@Suite struct CloseSplitPaneTests {
    @Test func closingSplitKeepsSessionAsTabAndNeighborActive() {
        let tree = LayoutNode.split(axis: .horizontal, ratio: 0.5,
            first: leaf("a"), second: leaf("b", "c", active: 1))
        #expect(tree.paneCloseDestination(for: "a") == "c")
        #expect(tree.closingPane(containing: "a") == leaf("b", "c", "a", active: 1))
        #expect(tree.closingPane(containing: "b") == leaf("a", "b", "c"))
    }

    @Test func allTabsSurviveAndOnlySourcePaneCollapses() {
        let tree = LayoutNode.split(axis: .horizontal, ratio: 0.3,
            first: leaf("a"), second: .split(axis: .vertical, ratio: 0.6,
                first: leaf("b", "c", active: 1), second: leaf("d", "e", active: 1)))
        let next = tree.closingPane(containing: "c")
        #expect(next == .split(axis: .horizontal, ratio: 0.3,
                              first: leaf("a"), second: leaf("d", "e", "b", "c", active: 1)))
        #expect(Set(next?.allSessions ?? []) == Set(tree.allSessions))
        #expect(next?.allSessions.count == tree.allSessions.count)
        #expect(LayoutNode.reconcile(next, members: tree.allSessions, prunable: Set(tree.allSessions)) == next)
    }

    @Test func closingBesideEmptyPanesPreservesSoleSession() {
        let tree = leaf("a").splittingOff("a", direction: .right)
        #expect(tree.closingPane(containing: "a") == leaf("a"))
        #expect(tree.closingPane(containing: "a")?.isPersistentLayout == false)
        #expect(leaf("a").closingPane(containing: "a") == nil)
        #expect(leaf("a", "b").closingPane(containing: "a") == nil)
        #expect(tree.closingPane(containing: "missing") == nil)
    }

    @Test func destinationSkipsEmptyPanesAndUsesOuterSibling() {
        let tree = LayoutNode.split(axis: .horizontal, ratio: 0.5,
            first: leaf("a").splittingOff("a", direction: .right), second: leaf("b", "c", active: 1))
        #expect(tree.paneCloseDestination(for: "a") == "c")
        let next = tree.closingPane(containing: "a")
        #expect(next?.allSessions == ["b", "c", "a"])
        #expect(next?.leafTabs(containing: "c") == ["b", "c", "a"])
    }
}

@Suite struct VacatedPaneTests {
    @Test func movingLastRightTabIntoLeftClosesRightPane() {
        let tree = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("left"), second: leaf("right"))
        #expect(tree.placing("right", beside: "left", edge: nil) == leaf("left", "right", active: 1))
        #expect(tree.removing("right") == leaf("left"))
    }

    @Test func movingLastRightTabIntoEmptyLeftClosesRightPane() {
        let tree = leaf("chat").splittingOff("chat", direction: .right)
        let next = tree.fillingEmptyPane(at: [false], with: "chat")
        #expect(next == leaf("chat"))
        #expect(!next.hasEmptyPane)
        #expect(!next.isPersistentLayout)
    }

    @Test func movingOneOfSeveralRightTabsKeepsRightPane() {
        let tree = LayoutNode.split(axis: .horizontal, ratio: 0.4, first: leaf("left"), second: leaf("a", "b", active: 1))
        #expect(tree.placing("b", beside: "left", edge: nil)
            == .split(axis: .horizontal, ratio: 0.4, first: leaf("left", "b", active: 1), second: leaf("a")))
    }
}

@Suite struct TabOrderTests {
    @Test func reorderBothDirectionsPreservesVisibleSession() {
        let original = leaf("a", "b", "c", "d", active: 1)
        #expect(original.reorderingTab("a", inLeafOf: "b", at: 4) == leaf("b", "c", "d", "a"))
        #expect(original.reorderingTab("d", inLeafOf: "b", at: 0) == leaf("d", "a", "b", "c", active: 2))
        #expect(original.reorderingTab("b", inLeafOf: "b", at: 4) == leaf("a", "c", "d", "b", active: 3))
        #expect(original.reorderingTab("a", inLeafOf: "b", at: 2) == leaf("b", "a", "c", "d"))
    }

    @Test func adjacentGapsAndInvalidNamesAreNoOps() {
        let original = leaf("a", "b", "c", active: 1)
        #expect(original.reorderingTab("b", inLeafOf: "a", at: 1) == original)
        #expect(original.reorderingTab("b", inLeafOf: "a", at: 2) == original)
        #expect(original.reorderingTab("missing", inLeafOf: "a", at: 0) == original)
        #expect(original.reorderingTab("b", inLeafOf: "missing", at: 0) == original)
        #expect(original.reorderingTab("b", inLeafOf: "a", at: -4) == leaf("b", "a", "c"))
        #expect(original.reorderingTab("b", inLeafOf: "a", at: 99) == leaf("a", "c", "b", active: 2))
    }

    @Test func reorderAfterMergeKeepsAllSessionsAndPersists() throws {
        let original = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("a", "b"), second: leaf("c"))
        let merged = original.placing("c", beside: "a", edge: nil)
        let sorted = merged.reorderingTab("c", inLeafOf: "a", at: 1)
        #expect(sorted == leaf("a", "c", "b", active: 1))
        #expect(LayoutNode.reconcile(sorted, members: ["a", "b", "c"], prunable: ["a", "b", "c"]) == sorted)
        #expect(try JSONDecoder().decode(LayoutNode.self, from: JSONEncoder().encode(sorted)) == sorted)
    }

    @Test func insertionMarkerTracksTabMidpointsIncludingScrollOffset() {
        let frames = ["a": CGRect(x: -60, y: 0, width: 100, height: 26),
                      "b": CGRect(x: 42, y: 0, width: 100, height: 26),
                      "c": CGRect(x: 144, y: 0, width: 100, height: 26)]
        #expect(TabDropPosition.index(x: 0, tabs: ["a", "b", "c"], frames: frames) == 1)
        #expect(TabDropPosition.index(x: 93, tabs: ["a", "b", "c"], frames: frames) == 2)
        #expect(TabDropPosition.index(x: 250, tabs: ["a", "b", "c"], frames: frames) == 3)
        #expect(TabDropPosition.index(x: -50, tabs: ["a", "b", "c"], frames: frames) == 0)
    }
}

@Suite struct StableTabDropTests {
    @Test func destinationFollowsTabWhenOrderChangesDuringPayloadLoad() throws {
        let anchor = try #require(TabDropPosition.anchor(at: 1, in: ["a", "b", "c"]))
        #expect(anchor == .before("b"))
        // A new tab appeared while the system was loading the drag item.
        let current = leaf("new", "a", "b", "c", "dragged")
        let index = try #require(anchor.index(in: current.allSessions))
        #expect(current.reorderingTab("dragged", inLeafOf: "b", at: index)
            == leaf("new", "a", "dragged", "b", "c"))
        #expect(anchor.index(in: ["a", "c"]) == nil)
    }

    @Test func appendDestinationUsesLatestEndPosition() {
        #expect(TabDropPosition.anchor(at: 3, in: ["a", "b", "c"]) == .end)
        #expect(TabDropAnchor.end.index(in: ["a", "b", "c", "new"]) == 4)
        #expect(TabDropPosition.anchor(at: 4, in: ["a", "b", "c"]) == nil)
    }

    @Test func unmeasuredTabsCannotSilentlyAppendDrop() {
        #expect(TabDropPosition.index(x: 30, tabs: ["a", "b"], frames: [:]) == nil)
        #expect(TabDropPosition.index(x: 30, tabs: ["a", "b"], frames: ["a": CGRect(x: 0, y: 0, width: 100, height: 26)]) == nil)
        #expect(TabDropPosition.index(x: 30, tabs: ["a"], frames: ["a": .zero]) == nil)
    }

    @Test func contentCoordinatesAgreeAfterHorizontalScroll() {
        let contentFrames = ["a": CGRect(x: 4, y: 0, width: 100, height: 26),
                             "b": CGRect(x: 106, y: 0, width: 100, height: 26),
                             "c": CGRect(x: 208, y: 0, width: 100, height: 26)]
        // 120px scrolled: pointer at viewport x=80 is content x=200 (after b).
        #expect(TabDropPosition.index(x: 200, tabs: ["a", "b", "c"], frames: contentFrames) == 2)
        #expect(TabDropPosition.index(x: 106, tabs: ["a", "b", "c"], frames: contentFrames) == 1)
    }
}

@Suite struct SessionCloseFocusTests {
    @Test func prefersRemainingTabInSamePane() {
        let layout = LayoutNode.split(axis: .horizontal, ratio: 0.5,
                                      first: leaf("other"), second: leaf("a", "closing", "b"))
        #expect(layout.survivingSession(afterClosing: "closing", live: ["other", "a", "b"]) == "b")
        #expect(layout.survivingSession(afterClosing: "closing", live: ["other", "a"]) == "a")
    }

    @Test func prefersVisibleTabInNeighboringPane() {
        let layout = LayoutNode.split(axis: .horizontal, ratio: 0.5,
                                      first: leaf("a", "b", active: 1), second: leaf("closing"))
        #expect(layout.survivingSession(afterClosing: "closing", live: ["a", "b", "unrelated"]) == "b")
        #expect(layout.survivingSession(afterClosing: "closing", live: ["a", "unrelated"]) == "a")
    }

    @Test func skipsPanesThatExitedTogether() {
        let layout = LayoutNode.split(axis: .horizontal, ratio: 0.5, first: leaf("survivor"),
                                      second: .split(axis: .vertical, ratio: 0.5,
                                                     first: leaf("closing"), second: leaf("also-dead")))
        #expect(layout.survivingSession(afterClosing: "closing", live: ["survivor", "unrelated"]) == "survivor")
        #expect(layout.survivingSession(afterClosing: "closing", live: ["unrelated"]) == nil)
    }

    @Test func lastSessionHasNoGroupReplacement() {
        #expect(leaf("closing").survivingSession(afterClosing: "closing", live: ["unrelated"]) == nil)
    }
}
