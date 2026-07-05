import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct SidebarView: View {
    @ObservedObject var store: SessionStore

    @State private var pendingDelete: String?
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
        List(selection: $store.selected) {
            ForEach(Array(store.grouped.enumerated()), id: \.offset) { idx, groupEntry in
                let groupName = groupEntry.0
                let isDefaultGroup = groupName == store.defaultGroup
                let sessions = groupEntry.1

                if idx > 0 {
                    Divider()
                        .selectionDisabled()
                }

                groupHeader(groupName, isDefault: isDefaultGroup)

                ForEach(sessions) { session in
                    sessionRow(session)
                        .tag(session.name)
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                        .listRowBackground(Color.clear)
                        .contextMenu { sessionMenu(session) }
                        .onDrag { NSItemProvider(object: session.name as NSString) }
                }
                .onInsert(of: [.utf8PlainText, .plainText]) { index, providers in
                    guard !store.hasSearch else { return }
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
                Text(store.hasSearch ? "No matching sessions" : "No tmux sessions")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
        .scrollContentBackground(.hidden)
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
            .padding(.top, 2)
            .selectionDisabled()
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        let details = store.details(for: session.name)
        let isSelected = store.selected == session.name

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
                }

                if !session.path.isEmpty {
                    Text(shortPath(session.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let branch = details.branch {
                    Text(branch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let pr = details.pr {
                    HStack(spacing: 4) {
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
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

            }

            Spacer(minLength: 0)

            VStack(spacing: 6) {
                if cmdHeld, let index = hotkeyIndexBySession[session.name] {
                    Text("\(index)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                }

                RoundedRectangle(cornerRadius: 2)
                    .fill(store.color(of: session.name) ?? .clear)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    hoveredSession == session.name && !isSelected
                        ? Color.primary.opacity(0.08)
                        : Color.clear
                )
        )
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

    @ViewBuilder
    private func sessionMenu(_ session: Session) -> some View {
        Button("Rename") {
            renameText = session.name
            editingSession = session.name
            renameFocused = true
        }

        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.name, forType: .string)
        }

        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.path)])
        }
        .disabled(session.path.isEmpty)

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

        Button("Kill Session", role: .destructive) {
            pendingDelete = session.name
        }
    }

    private var agentsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .frame(height: 9)
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
                            Settings.agentsPanelHeight = agentsPanelHeight
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
        .padding(.bottom, 10)
        .frame(height: agentsPanelHeight)
    }

    private func agentRow(_ agent: AgentInfo) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(agent.status.color)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.session)
                    .lineLimit(1)
                Text("\(agent.status.title) · \(agent.tool)")
                    .font(.caption)
                    .foregroundStyle(agent.status.color)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            store.selected = agent.session
        }
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
