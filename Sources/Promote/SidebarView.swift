import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct SidebarView: View {
    @ObservedObject var store: SessionStore

    @State private var pendingDelete: String?
    @State private var hoveredAgent: String?
    @State private var editingSession: String?
    @State private var renameText = ""
    @State private var groupingSession: String?
    @State private var newGroupName = ""
    @State private var hoveredSession: String?
    @State private var cmdHeld = false
    @State private var flagsMonitor: Any?

    @AppStorage("agentsPanelHeight") private var agentsPanelHeight = Settings.agentsPanelHeight
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
        .onAppear { startMonitoringModifiers() }
        .onDisappear { stopMonitoringModifiers() }
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
        // min row height 1: rows size to content; no forced 24px spacer rows
        List(selection: $store.selected) {
            // zero-height dummy row soaks up the List's first-row top inset,
            // so the real first row sits at normal inter-row spacing
            Color.clear
                .frame(height: 0)
                .listRowInsets(EdgeInsets())
                .selectionDisabled()

            ForEach(Array(store.grouped.enumerated()), id: \.element.0) { idx, groupEntry in
                let groupName = groupEntry.0
                let isDefaultGroup = groupName == store.defaultGroup
                let sessions = groupEntry.1

                // divider as its own non-selectable row so hover/selection pills never cover it
                if idx > 0 {
                    Divider()
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 2, trailing: 8))
                        .selectionDisabled()
                }

                groupHeader(groupName, isDefault: isDefaultGroup)

                ForEach(sessions) { session in
                    sessionRow(session)
                        .tag(session.name)
                        .contextMenu { sessionMenu(session) }
                        .onDrag { NSItemProvider(object: session.name as NSString) }
                }
                .onInsert(of: [.utf8PlainText, .plainText]) { index, providers in
                    providers.first?.loadObject(ofClass: NSString.self) { object, _ in
                        guard let name = object as? String else { return }
                        DispatchQueue.main.async {
                            store.handleDrop(
                                name: name,
                                group: isDefaultGroup ? nil : groupName,
                                at: index
                            )
                        }
                    }
                }
            }

            if store.grouped.flatMap(\.1).isEmpty {
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

        VStack(alignment: .leading) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    if editingSession == session.name {
                        TextField("Session Name", text: $renameText)
                            .textFieldStyle(.roundedBorder)
                            .focused($renameFocused)
                            .onSubmit { commitRename(old: session.name) }
                            .onExitCommand { editingSession = nil }
                    } else {
                        Text(session.name)
                            .lineLimit(1)
                            .font(.body.weight(.medium))
                            .foregroundStyle(
                                hoveredSession == session.name && !isSelected
                                    ? Color.accentColor
                                    : Color.primary
                            )
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
                                Text("#\(pr.number)")
                                    .underline()
                            }
                            .buttonStyle(.plain)

                            Text(pr.state.label)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(pr.state.color, in: Capsule())
                                .foregroundStyle(.white)
                        } else {
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
                        if store.locked.contains(session.name) {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Locked: pane can't be closed")
                        }

                        if let agentStatus {
                            StatusDot(status: agentStatus)
                                .help("Agent: \(agentStatus.title)")
                        }

                        Spacer(minLength: 0)

                        if (cmdHeld || hoveredSession == session.name),
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
    }

    @ViewBuilder
    private func sessionMenu(_ session: Session) -> some View {
        Button("Rename") {
            renameText = session.name
            editingSession = session.name
            // TextField isn't in the hierarchy yet this tick; focus next runloop pass
            DispatchQueue.main.async { renameFocused = true }
        }

        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.name, forType: .string)
        }

        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.path, forType: .string)
        }
        .disabled(session.path.isEmpty)

        Button("Copy Branch Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(store.details(for: session.name).branch ?? "", forType: .string)
        }
        .disabled(store.details(for: session.name).branch == nil)

        Divider()

        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.path)])
        }
        .disabled(session.path.isEmpty)

        Button("Open in VS Code") {
            let dir = URL(fileURLWithPath: session.path)
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
                NSWorkspace.shared.open([dir], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        .disabled(session.path.isEmpty)

        Divider()

        Menu("Color") {
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

            Button("None") {
                store.setColor(session.name, hex: nil)
            }
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
                Text("Agents")
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
            StatusDot(status: agent.status, size: 7)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 1) {
                // ponytail: hard 12-char slice so the top-right tool name never collides
                Text(agent.session.count > 12 ? agent.session.prefix(12) + "…" : agent.session)
                    .lineLimit(1)
                Text(agent.status.title)
                    .font(.caption)
                    .foregroundStyle(agent.status.color)
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
        let statuses = Set(store.agents(for: sessionName).map(\.status))
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

    private func startMonitoringModifiers() {
        cmdHeld = NSEvent.modifierFlags.contains(.command)
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            cmdHeld = event.modifierFlags.contains(.command)
            return event
        }
    }

    private func stopMonitoringModifiers() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        cmdHeld = false
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

// status dot; pulses while the agent is working
struct StatusDot: View {
    let status: AgentStatus
    var size: CGFloat = 8

    var body: some View {
        if status == .working {
            Circle()
                .fill(status.color)
                .frame(width: size, height: size)
                .phaseAnimator([1.0, 0.35]) { dot, opacity in
                    dot.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration: 0.7)
                }
        } else {
            Circle()
                .fill(status.color)
                .frame(width: size, height: size)
        }
    }
}

