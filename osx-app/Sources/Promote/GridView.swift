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
            // only reachable from hand-edited/corrupt gridLayouts; reconcile repairs it next pass
            Color.clear
        case .leaf(let tabs, let active):
            LeafView(store: store, tabs: tabs, active: tabs[min(max(active, 0), tabs.count - 1)])
        case .split(let axis, let ratio, let first, let second):
            SplitContainer(axis: axis, ratio: ratio, onCommit: { store.setRatio(gid: gid, path: path, $0) }) {
                GridView(store: store, gid: gid, node: first, path: path + [false])
            } second: {
                GridView(store: store, gid: gid, node: second, path: path + [true])
            }
        }
    }
}

private struct LeafView: View {
    @ObservedObject var store: SessionStore
    let tabs: [String]
    let active: String

    var body: some View {
        let focused = store.selected == active
        VStack(spacing: 0) {
            TabStrip(store: store, tabs: tabs, active: active, focused: focused)
            TerminalPane(session: active, isFocused: focused, onFocus: { [store] in
                if store.selected != active { store.selected = active }
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
    @State private var dropTargeted = false

    // ponytail: "§tab:" payload prefix keeps a tab drag from being read as a sidebar order
    // token (sidebar onInsert / bin also accept plain text). Can't collide with a sane session name.
    static let dragPrefix = "§tab:"

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(tabs, id: \.self) { name in
                    chip(name)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 26)
        .background(dropTargeted ? Color.accentColor.opacity(0.25) : Color(nsColor: .windowBackgroundColor))
        // drop a tab from another cell here: it moves into this cell
        .onDrop(of: [.utf8PlainText, .plainText], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let payload = object as? String, payload.hasPrefix(Self.dragPrefix) else { return }
                let name = String(payload.dropFirst(Self.dragPrefix.count))
                DispatchQueue.main.async { store.moveTab(name, toLeafOf: active) }
            }
            return true
        }
        .overlay(alignment: .top) {
            // focused leaf marker
            Rectangle().fill(focused ? Color.accentColor : .clear).frame(height: 2)
        }
    }

    private func chip(_ name: String) -> some View {
        let isActive = name == active
        return HStack(spacing: 5) {
            Circle().fill(store.color(of: name) ?? .secondary.opacity(0.4)).frame(width: 7, height: 7)
            if let status = store.agentStatus(for: name) {
                StatusDot(status: status, size: 10)
            }
            Text(name).font(.caption).lineLimit(1)
            Button {
                store.closeGridSession(name)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(store.locked.contains(name) ? "Locked" : "Kill session")
            .disabled(store.locked.contains(name))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isActive ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        // simultaneousGesture, not onTapGesture: an exclusive tap swallows the mouse-down
        // and .onDrag never starts
        .simultaneousGesture(TapGesture().onEnded { store.selected = name })
        .onDrag { NSItemProvider(object: (Self.dragPrefix + name) as NSString) }
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
