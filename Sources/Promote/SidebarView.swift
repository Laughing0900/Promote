import SwiftUI
import UniformTypeIdentifiers

// session list: grouping, hover, rename, drag, context menu, sidebar toolbar buttons
struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @Binding var sidebarVisibility: NavigationSplitViewVisibility
    @State private var editing: String?
    @State private var editText = ""
    @State private var pendingDelete: String?
    @State private var groupingSession: String?
    @State private var newGroupName = ""
    @State private var hovered: String?
    @State private var cmdHeld = false
    @State private var flagsMonitor: Any?
    @FocusState private var renameFocused: Bool

    // cmd+1..9 targets, sidebar visual order
    private var hotkeyIndex: [String: Int] {
        Dictionary(uniqueKeysWithValues:
            store.grouped.flatMap { $0.1 }.enumerated().prefix(9)
                .map { ($0.element.name, $0.offset + 1) })
    }

    var body: some View {
        List(selection: $store.selected) {
            ForEach(Array(store.grouped.enumerated()), id: \.element.0) { entry in
                let group = entry.element.0
                Section {
                    if entry.offset > 0 {
                        Divider()
                            .selectionDisabled() // plain separator, not a selectable row
                    }
                    ForEach(entry.element.1) { s in
                        row(s)
                            .tag(s.name)
                            .contextMenu { menu(s) }
                            .onDrag { NSItemProvider(object: s.name as NSString) }
                    }
                    .onInsert(of: [.utf8PlainText, .plainText]) { index, providers in
                        providers.first?.loadObject(ofClass: NSString.self) { obj, _ in
                            guard let name = obj as? String else { return }
                            DispatchQueue.main.async {
                                store.handleDrop(name: name,
                                                 group: group == store.defaultGroup ? nil : group,
                                                 at: index)
                            }
                        }
                    }
                } header: {
                    // default group needs no title
                    if group != store.defaultGroup { Text(group) }
                }
            }
        }
        .padding(.top, 6)
        .scrollContentBackground(.hidden)
        .background(
            // full-bleed sidebar background, up under toolbar + traffic lights
            Color(nsColor: .underPageBackgroundColor).ignoresSafeArea()
        )
        .toolbar(removing: .sidebarToggle) // buttons live at window level in ContentView
        .onAppear {
            // local monitor: only fires while app has focus
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { ev in
                cmdHeld = ev.modifierFlags.contains(.command)
                return ev
            }
        }
        .onDisappear {
            if let m = flagsMonitor { NSEvent.removeMonitor(m) }
            flagsMonitor = nil
        }
        .alert("New Group", isPresented: Binding(
            get: { groupingSession != nil },
            set: { if !$0 { groupingSession = nil } }
        )) {
            TextField("Group name", text: $newGroupName)
            Button("Create") {
                let g = newGroupName.trimmingCharacters(in: .whitespaces)
                if let s = groupingSession, !g.isEmpty {
                    store.setGroup(s, to: g)
                }
                groupingSession = nil
            }
            Button("Cancel", role: .cancel) { groupingSession = nil }
        }
        .confirmationDialog(
            "Kill session \u{201C}\(pendingDelete ?? "")\u{201D}?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Kill Session", role: .destructive) {
                if let n = pendingDelete { store.kill(n) }
                pendingDelete = nil
            }
        }
    }

    // MARK: - row

    @ViewBuilder
    private func row(_ s: Session) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if editing == s.name {
                    TextField("Name", text: $editText)
                        .textFieldStyle(.roundedBorder)
                        .focused($renameFocused)
                        .onSubmit { commitRename(s.name) }
                        .onExitCommand { editing = nil }
                } else {
                    Text(s.name).lineLimit(1)
                }
                // one line each: path / branch / PR status
                if !s.path.isEmpty {
                    Text(shortPath(s.path))
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let b = store.details[s.name]?.branch {
                    Label(b, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .opacity(0.8)
                }
                if let pr = store.details[s.name]?.pr {
                    HStack(spacing: 4) {
                        Text("#\(pr.number)")
                            .underline()
                            .foregroundStyle(.secondary)
                            .onTapGesture {
                                if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) }
                            }
                        Text(pr.state.rawValue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(pr.state.color, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
            if cmdHeld, let n = hotkeyIndex[s.name] {
                Text("\(n)")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }
            RoundedRectangle(cornerRadius: 2)
                .fill(store.color(of: s.name) ?? .clear)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovered == s.name && store.selected != s.name
                      ? Color.primary.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = s.name }
            else if hovered == s.name { hovered = nil }
        }
        // onDrag can eat List's selection click; select explicitly on tap
        .onTapGesture { store.selected = s.name }
    }

    // MARK: - context menu

    @ViewBuilder
    private func menu(_ s: Session) -> some View {
        Button("Rename") { startRename(s.name) }
        Menu("Color") {
            ForEach(palette) { entry in
                Button {
                    store.setColor(s.name, hex: entry.hex)
                } label: {
                    Label(entry.id, systemImage: "circle.fill")
                        .foregroundStyle(entry.color)
                }
            }
            Divider()
            Button("Choose Custom Color\u{2026}") {
                ColorPanelBridge.shared.open { ns in
                    store.setColor(s.name, hex: hexString(ns))
                }
            }
            Button("None") { store.setColor(s.name, hex: nil) }
        }
        Menu("Group") {
            Button(store.defaultGroup + " (default)") { store.setGroup(s.name, to: nil) }
            ForEach(store.groupNames, id: \.self) { g in
                Button(g) { store.setGroup(s.name, to: g) }
            }
            Divider()
            Button("New Group\u{2026}") {
                newGroupName = ""
                groupingSession = s.name
            }
        }
        Divider()
        Button("Kill Session", role: .destructive) { pendingDelete = s.name }
    }

    // MARK: - helpers

    private func shortPath(_ p: String) -> String {
        p.split(separator: "/").suffix(2).joined(separator: "/")
    }

    private func startRename(_ name: String) {
        editText = name
        editing = name
        renameFocused = true
    }

    private func commitRename(_ old: String) {
        let new = editText.trimmingCharacters(in: .whitespaces)
        editing = nil
        store.rename(old, to: new)
    }
}
