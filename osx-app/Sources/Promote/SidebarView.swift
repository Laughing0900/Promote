import SwiftUI
import UniformTypeIdentifiers
import AppKit

// dividers/headers/sessions flattened into one ForEach so a single onInsert covers
// every gap — including after each group's last row, which per-group ForEach can't
private enum SidebarRow: Identifiable {
    case divider(prevGroup: String, nextGroup: String)
    case header(String)
    case session(Session, group: String)

    var id: String {
        switch self {
        case .divider(_, let next): return "d:\(next)"
        case .header(let group): return "h:\(group)"
        case .session(let s, _): return "s:\(s.name)"
        }
    }
}

struct SidebarView: View {
    @ObservedObject var store: SessionStore

    @State private var pendingDelete: String?
    @State private var hoveredAgent: String?
    @State private var editingSession: String?
    @State private var renameText = ""
    @State private var groupingSession: String?
    @State private var newGroupName = ""
    @State private var hoveredSession: String?

    @AppStorage("agentsPanelHeight") private var agentsPanelHeight = 160.0
    @AppStorage("lastCopyKind") private var lastCopyKind = "Path"
    @AppStorage("lastEditApp") private var lastEditApp = "VS Code"
    @State private var dragBaseHeight: Double?

    @FocusState private var renameFocused: Bool

    private var hotkeyIndexBySession: [String: Int] {
        Dictionary(uniqueKeysWithValues: store.hotkeyOrderedSessions.enumerated().prefix(9).map {
            ($0.element.name, $0.offset + 1)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            sessionList
            if !store.agents.isEmpty {
                agentsPanel
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).ignoresSafeArea())
        .toolbar(removing: .sidebarToggle)
        .alert("New Group", isPresented: Binding(
            get: { groupingSession != nil },
            set: { if !$0 { groupingSession = nil } }
        )) {
            TextField("Group name", text: $newGroupName)
            Button("Create") {
                let candidate = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let session = groupingSession, !candidate.isEmpty {
                    store.setGroup(session, to: candidate)
                }
                groupingSession = nil
            }
            Button("Cancel", role: .cancel) {
                groupingSession = nil
            }
        }
        .confirmationDialog(
            "Kill session \u{201C}\(pendingDelete ?? "")\u{201D}?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Kill Session", role: .destructive) {
                if let pendingDelete {
                    store.kill(pendingDelete)
                }
                self.pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                self.pendingDelete = nil
            }
        }
    }

    private var sessionList: some View {
        // grouped filters/sorts every call; compute once per render
        let grouped = store.grouped

        var rows: [SidebarRow] = []
        for (idx, entry) in grouped.enumerated() {
            if idx > 0 { rows.append(.divider(prevGroup: grouped[idx - 1].0, nextGroup: entry.0)) }
            if entry.0 != store.defaultGroup { rows.append(.header(entry.0)) }
            for session in entry.1 { rows.append(.session(session, group: entry.0)) }
        }

        // min row height 1: rows size to content; no forced 24px spacer rows
        return List(selection: $store.selected) {
            // zero-height dummy row soaks up the List's first-row top inset,
            // so the real first row sits at normal inter-row spacing
            Color.clear
                .frame(height: 0)
                .listRowInsets(EdgeInsets())
                .selectionDisabled()

            ForEach(rows) { row in
                switch row {
                case .divider:
                    // divider as its own non-selectable row so hover/selection pills never cover it
                    Divider()
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 2, trailing: 8))
                        .selectionDisabled()
                case .header(let name):
                    groupHeader(name, isDefault: false)
                case .session(let session, _):
                    sessionRow(session)
                        .tag(session.name)
                        .contextMenu { sessionMenu(session) }
                        .onDrag { NSItemProvider(object: session.name as NSString) }
                }
            }
            .onInsert(of: [.utf8PlainText, .plainText]) { index, providers in
                let target = dropTarget(rows: rows, insertIndex: index)
                providers.first?.loadObject(ofClass: NSString.self) { object, _ in
                    guard let name = object as? String else { return }
                    DispatchQueue.main.async {
                        store.handleDrop(name: name, group: target.group, at: target.at)
                    }
                }
            }

            if grouped.flatMap(\.1).isEmpty {
                Text("No tmux sessions")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .contentMargins(.top, 0, for: .scrollContent)
        // contentMargins clamps at 0; negative frame padding is what actually eats the List's top inset
        .padding(.top, -34)
    }

    // map a flat insert index to (group, position-in-group) by looking at the row above the gap
    private func dropTarget(rows: [SidebarRow], insertIndex: Int) -> (group: String?, at: Int) {
        func normalized(_ g: String) -> String? { g == store.defaultGroup ? nil : g }

        guard let firstRow = rows.first else { return (nil, 0) }
        guard insertIndex > 0 else {
            // gap above everything → top of first group
            switch firstRow {
            case .divider(_, let g), .header(let g), .session(_, let g):
                return (normalized(g), 0)
            }
        }

        switch rows[min(insertIndex, rows.count) - 1] {
        case .session(_, let g):
            let pos = rows.prefix(insertIndex).filter {
                if case .session(_, let sg) = $0 { return sg == g }
                return false
            }.count
            return (normalized(g), pos)
        case .header(let g):
            return (normalized(g), 0)
        case .divider(_, let next):
            // gap below the divider = "top of the group underneath";
            // gap above it resolves via the session case → end of the group above
            return (normalized(next), 0)
        }
    }

    @ViewBuilder
    private func groupHeader(_ name: String, isDefault: Bool) -> some View {
        if !isDefault {
            HStack {
                Text(name)
                    .font(.caption.smallCaps().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
            .selectionDisabled()
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        let details = store.details(for: session.name)
        let isSelected = store.selected == session.name
        let agentStatus = summarizedAgentStatus(for: session.name)

        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if editingSession == session.name {
                    TextField("Session Name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .focused($renameFocused)
                        .onSubmit { commitRename(old: session.name) }
                        .onExitCommand { editingSession = nil }
                } else {
                    HStack(spacing: 4) {
                        if session.serving {
                            Circle()
                                .fill(colorFromHex("#01796f") ?? .green)
                                .frame(width: 6, height: 6)
                                .help("Dev server running")
                        }

                        if store.locked.contains(session.name) {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Locked: pane can't be closed")
                        }

                        Text(session.name)
                            .lineLimit(1)
                            .font(.body.weight(.medium))
                            .foregroundStyle(
                                hoveredSession == session.name && !isSelected
                                    ? Color.accentColor
                                    : Color.primary
                            )
                    }
                }

                // always render dir/git/pr lines (blank when absent) so every row is the same height
                Text(session.path.isEmpty ? " " : shortPath(session.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // PR badge line; branch is in the context menu (Copy Branch Name)
                HStack(spacing: 4) {
                    if let pr = details.pr {
                        Button {
                            if let url = URL(string: pr.url) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text(verbatim: "#\(pr.number)")
                                .background(alignment: .bottom) {
                                    Capsule()
                                        .fill(pr.state.color)
                                        .frame(height: 2)
                                        .offset(y: -1)
                                }
                        }
                        .buttonStyle(.plain)
                        .help(pr.state.label)
                    }

                    if let diff = details.diff {
                        (Text(verbatim: "+\(diff.added)").foregroundStyle(colorFromHex("#17B169") ?? .green)
                            + Text(verbatim: "-\(diff.deleted)").foregroundStyle(colorFromHex("#CF222E") ?? .red))
                            .help("Changed lines: \(diff.added) added, \(diff.deleted) deleted")
                    }

                    if details.pr == nil && details.diff == nil {
                        Text(" ")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 16, alignment: .leading)

            }

            Spacer(minLength: 0)

            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing, spacing: 3) {
                    if let agentStatus {
                        StatusDot(status: agentStatus)
                            .help("Agent: \(agentStatus.title)")
                    }

                    Spacer(minLength: 0)

                    if (store.cmdHeld || hoveredSession == session.name),
                       let index = hotkeyIndexBySession[session.name] {
                        Text("\(index)")
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .trailing)

                RoundedRectangle(cornerRadius: 2)
                    .fill(store.color(of: session.name) ?? .clear)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredSession = session.name
            } else if hoveredSession == session.name {
                hoveredSession = nil
            }
        }
        .onTapGesture {
            store.selected = session.name
        }
    }

    private static let copyKinds = ["Name", "Path", "Branch"]
    private static let editApps: [(name: String, bundleId: String)] = [
        ("VS Code", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Xcode", "com.apple.dt.Xcode"),
    ]

    private func copyValue(_ kind: String, _ session: Session) -> String? {
        switch kind {
        case "Name": return session.name
        case "Path": return session.path.isEmpty ? nil : session.path
        case "Branch": return store.details(for: session.name).branch
        default: return nil
        }
    }

    private func doCopy(_ kind: String, _ session: Session) {
        guard let value = copyValue(kind, session) else { return }
        lastCopyKind = kind
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func doEdit(_ appName: String, _ session: Session) {
        guard let app = Self.editApps.first(where: { $0.name == appName }) else { return }
        lastEditApp = appName
        openInApp(session, bundleId: app.bundleId)
    }

    private func openInApp(_ session: Session, bundleId: String) {
        let dir = URL(fileURLWithPath: session.path)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.open([dir], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @ViewBuilder
    private func sessionMenu(_ session: Session) -> some View {
        Button("Rename") {
            renameText = session.name
            editingSession = session.name
            // TextField isn't in the hierarchy yet this tick; focus next runloop pass
            DispatchQueue.main.async { renameFocused = true }
        }
       
        Menu("Group") {
            Button("Default (no group)") {
                store.setGroup(session.name, to: nil)
            }

            ForEach(store.groupNames, id: \.self) { group in
                Button(group) {
                    store.setGroup(session.name, to: group)
                }
            }

            Divider()

            Button("New Group\u{2026}") {
                groupingSession = session.name
                newGroupName = ""
            }
        }
        Menu("Color") {
            Button("None") {
                store.setColor(session.name, hex: nil)
            }

            Divider()

            ForEach(palette) { entry in
                Button {
                    store.setColor(session.name, hex: entry.hex)
                } label: {
                    Label {
                        Text(entry.id)
                    } icon: {
                        Image(nsImage: colorSwatch(NSColor(entry.color)))
                    }
                }
            }

            Divider()

            Button("Choose Custom Color\u{2026}") {
                ColorPanelBridge.shared.open { color in
                    store.setColor(session.name, hex: hexString(color))
                }
            }
        }

        Divider()

        Button("Copy \(lastCopyKind)") { doCopy(lastCopyKind, session) }
            .disabled(copyValue(lastCopyKind, session) == nil)

        Menu("Copy") {
            ForEach(Self.copyKinds, id: \.self) { kind in
                Button(kind) { doCopy(kind, session) }
                    .disabled(copyValue(kind, session) == nil)
            }
        }

        Button("Edit in \(lastEditApp)") { doEdit(lastEditApp, session) }
            .disabled(session.path.isEmpty)

        Menu("Edit") {
            ForEach(Self.editApps, id: \.name) { app in
                Button(app.name) { doEdit(app.name, session) }
                    .disabled(session.path.isEmpty)
            }
        }

            Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.path)])
        }
        .disabled(session.path.isEmpty)


        Button("Open PR") {
            if let pr = store.details(for: session.name).pr, let url = URL(string: pr.url) {
                NSWorkspace.shared.open(url)
            }
        }
        .disabled(store.details(for: session.name).pr == nil)

        Divider()

        let isLocked = store.locked.contains(session.name)
        Button(isLocked ? "Unlock" : "Lock") {
            store.setLocked(session.name, !isLocked)
        }

        Button("Kill Session", role: .destructive) {
            pendingDelete = session.name
        }
        .disabled(isLocked)
    }

    private var agentsPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .frame(height: 7)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        NSCursor.resizeUpDown.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(coordinateSpace: .global)
                        .onChanged { value in
                            if dragBaseHeight == nil {
                                dragBaseHeight = agentsPanelHeight
                            }
                            let resized = (dragBaseHeight ?? agentsPanelHeight) - value.translation.height
                            agentsPanelHeight = min(500, max(80, resized))
                        }
                        .onEnded { _ in
                            dragBaseHeight = nil
                        }
                )

            HStack {
                Text("Activity")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.agents.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.agents) { agent in
                        agentRow(agent)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 6)
        .frame(height: agentsPanelHeight)
    }

    private func agentRow(_ agent: AgentInfo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(status: agent.status, size: 14, isServer: agent.isServer)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 1) {
                // ponytail: hard 12-char slice so the top-right tool name never collides
                Text(agent.session.count > 12 ? agent.session.prefix(12) + "…" : agent.session)
                    .lineLimit(1)
                Text(agent.isServer ? "Running" : agent.status.title)
                    .font(.caption)
                    .foregroundStyle(agent.isServer ? (colorFromHex("#01796f") ?? .green) : agent.status.color)
            }

            Spacer(minLength: 4)

            Text(agent.tool)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(hoveredAgent == agent.paneId ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredAgent = inside ? agent.paneId : nil
        }
        .onTapGesture {
            store.selected = agent.session
        }
    }

    private func summarizedAgentStatus(for sessionName: String) -> AgentStatus? {
        let statuses = Set(store.agents(for: sessionName).filter { !$0.isServer }.map(\.status))
        if statuses.contains(.blocked) { return .blocked }
        if statuses.contains(.working) { return .working }
        if statuses.contains(.done) { return .done }
        if statuses.contains(.idle) { return .idle }
        return nil
    }

    private func commitRename(old: String) {
        let next = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingSession = nil
        store.rename(old, to: next)
    }

    private func shortPath(_ path: String) -> String {
        path.split(separator: "/").suffix(2).joined(separator: "/")
    }

    // menus render template symbols; use a concrete bitmap swatch for color previews
    private func colorSwatch(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// pixel hex dot-matrix status icon: tick/cross/idle patterns, dotm-hex-3 loading sweep
struct StatusDot: View {
    let status: AgentStatus
    var size: CGFloat = 16
    var isServer = false   // dev-server: green dotm-hex-1 orbit instead of status pattern

    private struct Dot {
        let key: Int      // row*10+index, for shape lookup
        let x: Double     // unit coords, 5 columns wide
        let y: Double
    }

    private static let dots: [Dot] = {
        let counts = [3, 4, 5, 4, 3]
        var out: [Dot] = []
        for (r, c) in counts.enumerated() {
            for i in 0..<c {
                out.append(Dot(key: r * 10 + i,
                               x: Double(i) + Double(5 - c) / 2.0,
                               y: Double(r) * 0.87))
            }
        }
        return out
    }()

    private static let tick: Set<Int> = [20, 30, 40, 31, 22, 12, 2]
    private static let cross: Set<Int> = [0, 2, 11, 12, 22, 31, 32, 40, 42]
    private static let idlePattern: Set<Int> = [0, 2, 20, 21, 22, 23, 24, 40, 42]
    // dotm-hex-1 perimeter, clockwise from top-left, as StatusDot keys
    private static let perimeter: [Int] = [0, 1, 2, 13, 24, 33, 42, 41, 40, 30, 20, 10]
    private static let serverGreen = colorFromHex("#01796f") ?? .green

    var body: some View {
        if status == .working || isServer {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
                matrix(time: tl.date.timeIntervalSinceReferenceDate)
            }
        } else {
            matrix(time: 0)
        }
    }

    private func matrix(time: TimeInterval) -> some View {
        Canvas { ctx, sz in
            let pitch = sz.width / 5
            let d = pitch * 0.75
            for dot in Self.dots {
                let cx = (dot.x + 0.5) * pitch
                let cy = (dot.y + 0.5) * pitch
                let rect = CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
                ctx.fill(Path(ellipseIn: rect), with: .color(color(for: dot, time: time)))
            }
        }
        .frame(width: size, height: size * 4.48 / 5)
    }

    private func color(for dot: Dot, time: TimeInterval) -> Color {
        if isServer { return serverColor(for: dot, time: time) }
        let dim = Color.primary.opacity(0.12)
        switch status {
        case .idle:
            return Color.primary.opacity(Self.idlePattern.contains(dot.key) ? 0.45 : 0.14)
        case .done:
            return Self.tick.contains(dot.key) ? status.color : dim
        case .blocked:
            return Self.cross.contains(dot.key) ? status.color : dim
        case .working:
            // port of dotm-hex-3 loader (dotmatrix.zzzzshawn.cloud): two diagonal
            // bands sweep across on a triangular wave, flash when they cross center
            let x = dot.x - 2.0
            let y = dot.y - 1.74
            let phase = (time / 1.276).truncatingRemainder(dividingBy: 1)
            let tri = 1 - abs(phase * 2 - 1)
            let sweep = tri * 3.9 - 1.95
            let glow = { (d: Double) in max(0.0, 1.0 - abs(d) / 0.55) }
            let gateA = glow(x * 0.86 + y * 0.5 - sweep)
            let gateB = glow(-x * 0.86 + y * 0.5 + sweep)
            let centerFlash = max(0, 1 - abs(sweep) / 0.68) * max(0, 1 - (x * x + y * y).squareRoot() / 1.9)
            let wake = 0.16 * max(0, 1 - abs(y - sweep * 0.22) / 1.2)
            let o = min(0.96, 0.08 + gateA * 0.7 + gateB * 0.7 + centerFlash * 0.42 + wake)
            return status.color.opacity(o)
        }
    }

    // port of dotm-hex-1 "Hex Orbit" (dotmatrix.zzzzshawn.cloud): two soft heads
    // chase around the perimeter half a lap apart, interior stays quietly lit
    private func serverColor(for dot: Dot, time: TimeInterval) -> Color {
        guard let idx = Self.perimeter.firstIndex(of: dot.key) else {
            return Self.serverGreen.opacity(dot.key == 22 ? 0.10 : (dot.key % 10 == 2 ? 0.20 : 0.18))
        }
        let pathLen = Double(Self.perimeter.count)
        let phase = (time / 0.9375).truncatingRemainder(dividingBy: 1)  // 1500ms base / 1.6 speed
        let headA = phase * pathLen
        let headB = (headA + pathLen / 2).truncatingRemainder(dividingBy: pathLen)
        let glow = { (head: Double) -> Double in
            var dist = (head - Double(idx)).truncatingRemainder(dividingBy: pathLen)
            if dist < 0 { dist += pathLen }
            let t = min(1.0, max(0.0, dist / 5.0))
            return 0.10 + (1 - t * t * (3 - 2 * t)) * 0.86  // 1 - smoothstep, trail span 5
        }
        return Self.serverGreen.opacity(min(0.96, max(glow(headA), glow(headB) * 0.74)))
    }
}

