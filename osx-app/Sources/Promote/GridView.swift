import SwiftUI
import AppKit

// Renders one session group's layout tree. Each leaf mounts only its active tab.
// ponytail: inactive tabs are unmounted (no tmux client, no window-size tug); switching
// re-attaches. Upgrade path: keep every tab mounted in a ZStack if that feels slow.
// ponytail: a split/collapse moves a leaf in the view tree, so its terminal re-attaches.
struct GridView: View {
    @ObservedObject var store: SessionStore
    let gid: String
    let node: LayoutNode
    var path: [Bool] = []

    var body: some View {
        switch node {
        case .leaf(let tabs, _) where tabs.isEmpty:
            EmptySessionPane(store: store, gid: gid, path: path)
        case .leaf(let tabs, let active):
            SessionTabPane(store: store, tabs: tabs, active: tabs[min(max(active, 0), tabs.count - 1)])
        case .split(let axis, let ratio, let first, let second):
            SplitContainer(axis: axis, ratio: ratio, onCommit: { store.setRatio(gid: gid, path: path, $0) }) {
                GridView(store: store, gid: gid, node: first, path: path + [false])
            } second: {
                GridView(store: store, gid: gid, node: second, path: path + [true])
            }
        }
    }
}

private struct EmptySessionPane: View {
    @ObservedObject var store: SessionStore
    let gid: String
    let path: [Bool]
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x1").font(.title2)
            Text("Drop a session here").font(.callout)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Color.accentColor.opacity(0.2) : Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onDrop(of: SessionDrag.acceptedTypes, isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            // Sidebar drags carry a bare name; nothing else is droppable on an empty pane.
            SessionDrag.loadName(from: provider, plainText: true) { name in
                guard let name else { return }
                DispatchQueue.main.async { store.fillEmptyPane(gid: gid, path: path, with: name) }
            }
            return true
        }
        .overlay(alignment: .topTrailing) {
            Button {
                store.closeEmptyPane(gid: gid, path: path)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close empty pane")
            .accessibilityLabel("Close empty pane")
        }
        .contextMenu {
            Button("Close Pane") { store.closeEmptyPane(gid: gid, path: path) }
        }
    }
}

// Shared by grid leaves and standalone sessions so even one session has a tab strip.
struct SessionTabPane: View {
    @ObservedObject var store: SessionStore
    let tabs: [String]
    let active: String

    var body: some View {
        let focused = store.selected == active
        VStack(spacing: 0) {
            TabStrip(store: store, tabs: tabs, active: active, focused: focused)
            TerminalPane(session: active, isFocused: focused, onFocus: { [store] in
                if store.selected != active { store.selected = active }
            }, canDropSession: { [store] name in
                store.canDropSession(name, onto: active)
            }, onDropSession: { [store] name, edge in
                store.moveSession(name, beside: active, edge: edge)
            })
            .id("\(active)#\(store.terminalEpoch)")
        }
    }
}

private struct TabStrip: View {
    @ObservedObject var store: SessionStore
    let tabs: [String]
    let active: String
    let focused: Bool
    @State private var insertionIndex: Int?
    @State private var dropEndTimer: Timer?
    @State private var tabFrames: [String: CGRect] = [:]
    @Namespace private var tabCoordinates
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var showRename = false

    // ponytail: "§tab:" payload prefix keeps a tab drag from being read as a sidebar order
    // token (sidebar onInsert / bin also accept plain text). Can't collide with a sane session name.
    static let dragPrefix = SessionDrag.tabPrefix

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { viewport in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(tabs.enumerated()), id: \.element) { index, name in
                            chip(name)
                                .fixedSize(horizontal: true, vertical: false)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: TabFramePreference.self,
                                            value: [name: geometry.frame(in: .named(tabCoordinates))])
                                    }
                                    .allowsHitTesting(false)
                                }
                                .onDrop(of: SessionDrag.acceptedTypes, delegate: TabStripDropDelegate(
                                    tabs: tabs, frames: tabFrames, targetTab: name, insertionIndex: $insertionIndex,
                                    onDrop: { name, anchor in store.moveTab(name, toLeafOf: active, anchor: anchor) }
                                ))
                                .overlay(alignment: .leading) {
                                    if insertionIndex == index { insertionMarker.offset(x: -2) }
                                }
                                .overlay(alignment: .trailing) {
                                    if index == tabs.count - 1 && insertionIndex == tabs.count {
                                        insertionMarker.offset(x: 2)
                                    }
                                }
                        }
                        Text(insertionIndex == nil ? "" : "Drop as tab")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 80)
                            .allowsHitTesting(false)
                    }
                    .padding(.horizontal, 4)
                    .frame(minWidth: viewport.size.width, minHeight: 26, alignment: .leading)
                    .contentShape(Rectangle())
                    // Pointer and tab bounds must share the scroll-content coordinate space.
                    .coordinateSpace(name: tabCoordinates)
                    .onDrop(of: SessionDrag.acceptedTypes, delegate: TabStripDropDelegate(
                        tabs: tabs, frames: tabFrames, insertionIndex: $insertionIndex,
                        onDrop: { name, anchor in store.moveTab(name, toLeafOf: active, anchor: anchor) }
                    ))
                }
            }
            if focused {
                Button {
                    store.newTab(beside: active)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New tab in this panel (⌘T)")
                .accessibilityLabel("New tab in this panel")
            }
        }
        .frame(height: 26)
        .onPreferenceChange(TabFramePreference.self) { tabFrames = $0 }
        .onChange(of: insertionIndex != nil) { _, showingFeedback in
            dropEndTimer?.invalidate()
            dropEndTimer = nil
            guard showingFeedback else { return }
            // SwiftUI can omit dropExited when another destination handles the drop
            // or the drag is cancelled. Track release even in the drag run loop.
            let timer = Timer(timeInterval: 0.1, repeats: true) { timer in
                guard NSEvent.pressedMouseButtons == 0 else { return }
                timer.invalidate()
                insertionIndex = nil
                dropEndTimer = nil
            }
            dropEndTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            clearDropFeedback()
        }
        .onDisappear { clearDropFeedback() }
        .alert("Rename Chat", isPresented: $showRename) {
            TextField("Chat name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let renaming { store.renameChat(renaming, to: renameText) }
                renaming = nil
            }
        } message: {
            Text("Choose a name to identify this chat. Leave it blank to use the tmux session name.")
        }
        .background(insertionIndex != nil ? Color.accentColor.opacity(0.2) : Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            // focused leaf marker
            Rectangle().fill(focused ? Color.accentColor : .clear).frame(height: 2)
                .allowsHitTesting(false)
        }
    }

    private func clearDropFeedback() {
        dropEndTimer?.invalidate()
        dropEndTimer = nil
        insertionIndex = nil
    }

    private var insertionMarker: some View {
        Capsule().fill(Color.accentColor).frame(width: 3, height: 24).allowsHitTesting(false)
    }

    private func chip(_ name: String) -> some View {
        let isActive = name == active
        return HStack(spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(store.color(of: name) ?? .secondary.opacity(0.4)).frame(width: 7, height: 7)
                if let status = store.agentStatus(for: name) {
                    StatusDot(status: status, size: 10)
                }
                Text(store.chatName(for: name)).font(.caption).lineLimit(1)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { store.selected = name })
            Button {
                store.requestKillSession(name)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(store.locked.contains(name) ? "Locked" : "Close session")
            .disabled(store.locked.contains(name))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isActive ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onDrag { SessionDrag.provider(name, text: Self.dragPrefix + name) }
        .help("tmux: " + name)
        .contextMenu {
            SessionSplitMenu(store: store, name: name)
            Divider()
            Button("Rename") {
                renaming = name
                renameText = store.chatName(for: name)
                showRename = true
            }
            if store.chatNames[name] != nil {
                Button("Use tmux Session Name") { store.renameChat(name, to: "") }
            }
            Divider()
            Button("Kill Session", role: .destructive) { store.requestKillSession(name) }
                .disabled(store.locked.contains(name))
        }
    }
}

private struct TabFramePreference: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TabStripDropDelegate: DropDelegate {
    let tabs: [String]
    let frames: [String: CGRect]
    var targetTab: String? = nil
    @Binding var insertionIndex: Int?
    let onDrop: (String, TabDropAnchor) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: SessionDrag.acceptedTypes) }
    func dropEntered(info: DropInfo) { insertionIndex = index(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        insertionIndex = index(info)
        // NSItemProvider sources can advertise copy only. The store performs
        // the actual move, so accepting copy does not duplicate the session.
        return DropProposal(operation: insertionIndex == nil ? .forbidden : .copy)
    }
    func dropExited(info: DropInfo) { insertionIndex = nil }
    func performDrop(info: DropInfo) -> Bool {
        defer { insertionIndex = nil }
        guard let gap = index(info), let anchor = TabDropPosition.anchor(at: gap, in: tabs),
              let provider = info.itemProviders(for: SessionDrag.acceptedTypes).first else { return false }
        SessionDrag.loadName(from: provider) { name in
            guard let name else { return }
            DispatchQueue.main.async { onDrop(name, anchor) }
        }
        return true
    }
    private func index(_ info: DropInfo) -> Int? {
        if let targetTab {
            guard let tabIndex = tabs.firstIndex(of: targetTab),
                  let width = frames[targetTab]?.width, width > 0 else { return nil }
            // DropInfo is local to this chip; scrolling cannot shift the midpoint.
            return tabIndex + (info.location.x < width / 2 ? 0 : 1)
        }
        return TabDropPosition.index(x: info.location.x, tabs: tabs, frames: frames)
    }
}

// Shared by tab and sidebar menus; every action targets the clicked session.
struct SessionSplitMenu: View {
    @ObservedObject var store: SessionStore
    let name: String

    var body: some View {
        Button("New Tab") { store.newTab(beside: name) }
        Divider()
        Button("Split Right") { store.splitSession(name, direction: .right) }
        Menu("Split & Group") {
            ForEach(SplitDirection.allCases, id: \.self) { direction in
                Button("Split " + direction.title) { store.splitSession(name, direction: direction) }
            }
            Divider()
            ForEach(SplitDirection.allCases, id: \.self) { direction in
                Button("Move " + direction.moveTitle) { store.moveSession(name, direction: direction) }
                    .disabled(store.moveTarget(for: name, direction: direction) == nil)
            }
            Divider()
            Menu("Group With") {
                ForEach(store.sessions.filter { $0.name != name }) { session in
                    Button(store.chatName(for: session.name) + " (" + session.name + ")") {
                        store.moveTab(name, toLeafOf: session.name)
                    }
                }
            }
            .disabled(store.sessions.count < 2)
        }
    }
}

// two children + a draggable 1pt divider; ratio persists on drag end
private struct SplitContainer<First: View, Second: View>: View {
    let axis: SplitAxis
    let ratio: Double
    let onCommit: (Double) -> Void
    let first: First
    let second: Second
    @State private var dragRatio: Double?
    @State private var dragStart: Double?
    @State private var cursorPushed = false

    // real layout strip, not an overlay: terminals are AppKit views and win hit-testing
    // over any SwiftUI overlay that straddles them
    private let grabWidth: CGFloat = 6

    init(axis: SplitAxis, ratio: Double, onCommit: @escaping (Double) -> Void,
         @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second) {
        self.axis = axis
        self.ratio = ratio
        self.onCommit = onCommit
        self.first = first()
        self.second = second()
    }

    var body: some View {
        GeometryReader { geo in
            let horizontal = axis == .horizontal
            let total = horizontal ? geo.size.width : geo.size.height
            let firstLength = max(0, (total - grabWidth) * (dragRatio ?? ratio))
            let stack = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            stack {
                first.frame(width: horizontal ? firstLength : nil, height: horizontal ? nil : firstLength)
                divider(total: total, horizontal: horizontal).zIndex(1)
                second.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func divider(total: CGFloat, horizontal: Bool) -> some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
        }
        .frame(width: horizontal ? grabWidth : nil, height: horizontal ? nil : grabWidth)
        .contentShape(Rectangle())
        .onHover { setCursor($0, horizontal: horizontal) }
        // SwiftUI skips onHover(false) when the view goes away mid-hover (split collapsed)
        .onDisappear { setCursor(false, horizontal: horizontal) }
        .gesture(
            // global space: the handle moves with the drag, local translation would drift
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let usable = total - grabWidth
                    guard usable > 0 else { return }
                    let start = dragStart ?? ratio
                    dragStart = start
                    let delta = horizontal ? value.translation.width : value.translation.height
                    dragRatio = min(max(start + delta / usable, LayoutNode.ratioRange.lowerBound),
                                    LayoutNode.ratioRange.upperBound)
                }
                .onEnded { _ in
                    if let dragRatio { onCommit(dragRatio) }
                    dragRatio = nil
                    dragStart = nil
                }
        )
    }

    // push/pop only on change so the cursor stack stays balanced
    private func setCursor(_ inside: Bool, horizontal: Bool) {
        guard inside != cursorPushed else { return }
        cursorPushed = inside
        if inside {
            (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        } else {
            NSCursor.pop()
        }
    }
}
