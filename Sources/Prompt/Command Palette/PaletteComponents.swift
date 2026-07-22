import SwiftUI
import UniformTypeIdentifiers

private struct PromptGlassEffectContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

private extension View {
    @ViewBuilder
    func promptLiquidGlassSurface(tint: Color? = nil, cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                tint.map { Glass.regular.tint($0) } ?? .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }

    @ViewBuilder
    func promptGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self.buttonStyle(.plain)
        }
    }
}

struct PromptCommandAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let shortcut: [String]
    let action: () -> Void
}

struct PromptCommandOption: Identifiable, Hashable {
    /// Unique identifier for this option.
    let id = UUID()
    /// The primary text displayed for this command.
    let title: String
    /// Group heading displayed above related commands.
    let section: String
    /// Secondary text displayed below the title.
    let subtitle: String?
    /// Tooltip text shown on hover.
    let description: String?
    /// Keyboard shortcut symbols to display.
    let symbols: [String]?
    /// SF Symbol name for the leading icon.
    let leadingIcon: String?
    /// Color for the leading indicator circle.
    let leadingColor: Color?
    /// Badge text displayed as a pill.
    let badge: String?
    /// Whether to visually emphasize this option.
    let emphasis: Bool
    /// Sort key for stable ordering when titles are equal.
    let sortKey: AnySortKey?
    /// The action to perform when this option is selected.
    let action: () -> Void
    /// Child options shown inside this same palette surface.
    let children: (() -> [PromptCommandOption])?
    /// A purpose-built folder browser shown inside this palette.
    let folderPicker: PromptFolderPickerConfiguration?
    let sidebarEditor: PromptWorkspaceStore?
    /// Actions shown by Cmd-K for this exact command. These travel with an
    /// option into child pages instead of falling back to palette-wide actions.
    let contextualActions: (() -> [PromptCommandAction])?
    let primaryActionTitle: String

    init(
        title: String,
        section: String = "Commands",
        subtitle: String? = nil,
        description: String? = nil,
        symbols: [String]? = nil,
        leadingIcon: String? = nil,
        leadingColor: Color? = nil,
        badge: String? = nil,
        emphasis: Bool = false,
        sortKey: AnySortKey? = nil,
        primaryActionTitle: String? = nil,
        contextualActions: (() -> [PromptCommandAction])? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.section = section
        self.subtitle = subtitle
        self.description = description
        self.symbols = symbols
        self.leadingIcon = leadingIcon
        self.leadingColor = leadingColor
        self.badge = badge
        self.emphasis = emphasis
        self.sortKey = sortKey
        self.action = action
        self.children = nil
        self.folderPicker = nil
        self.sidebarEditor = nil
        self.contextualActions = contextualActions
        self.primaryActionTitle = primaryActionTitle ?? title
    }

    init(
        title: String,
        section: String = "Commands",
        subtitle: String? = nil,
        description: String? = nil,
        symbols: [String]? = nil,
        leadingIcon: String? = nil,
        primaryActionTitle: String? = nil,
        contextualActions: (() -> [PromptCommandAction])? = nil,
        children: @escaping () -> [PromptCommandOption]
    ) {
        self.title = title
        self.section = section
        self.subtitle = subtitle
        self.description = description
        self.symbols = symbols
        self.leadingIcon = leadingIcon
        self.leadingColor = nil
        self.badge = nil
        self.emphasis = false
        self.sortKey = nil
        self.action = {}
        self.children = children
        self.folderPicker = nil
        self.sidebarEditor = nil
        self.contextualActions = contextualActions
        self.primaryActionTitle = primaryActionTitle ?? "Open \(title)"
    }

    init(
        title: String,
        section: String = "Commands",
        subtitle: String? = nil,
        description: String? = nil,
        leadingIcon: String = "folder.badge.plus",
        folderPicker: PromptFolderPickerConfiguration,
        primaryActionTitle: String? = nil,
        contextualActions: (() -> [PromptCommandAction])? = nil
    ) {
        self.title = title
        self.section = section
        self.subtitle = subtitle
        self.description = description
        self.symbols = nil
        self.leadingIcon = leadingIcon
        self.leadingColor = nil
        self.badge = nil
        self.emphasis = false
        self.sortKey = nil
        self.action = {}
        self.children = nil
        self.folderPicker = folderPicker
        self.sidebarEditor = nil
        self.contextualActions = contextualActions
        self.primaryActionTitle = primaryActionTitle ?? "Browse \(title)"
    }

    init(title: String, section: String = "Commands", subtitle: String? = nil, description: String? = nil, leadingIcon: String = "sidebar.left", sidebarEditor: PromptWorkspaceStore, contextualActions: (() -> [PromptCommandAction])? = nil) {
        self.title = title
        self.section = section
        self.subtitle = subtitle
        self.description = description
        self.symbols = ["⌘", "K"]
        self.leadingIcon = leadingIcon
        self.leadingColor = nil
        self.badge = nil
        self.emphasis = false
        self.sortKey = nil
        self.action = {}
        self.children = nil
        self.folderPicker = nil
        self.sidebarEditor = sidebarEditor
        self.contextualActions = contextualActions
        self.primaryActionTitle = "Edit sidebar"
    }

    static func == (lhs: PromptCommandOption, rhs: PromptCommandOption) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct PromptCommandPaletteContentView: View {
    @Binding var isPresented: Bool
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    var options: [PromptCommandOption]
    @State private var rawQuery = ""
    @State private var selectedIndex: UInt? = 0
    @State private var hoveredOptionID: UUID?
    @State private var pages: [(title: String, options: [PromptCommandOption])] = []
    @State private var folderPicker: PromptFolderPickerConfiguration?
    @State private var sidebarEditor: PromptWorkspaceStore?
    @State private var actionsArePresented = false

    private var visibleOptions: [PromptCommandOption] { pages.last?.options ?? options }

    var query: String {
        rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The options that we should show, taking into account any filtering from
    // the query. Options with matching leadingColor are ranked higher.
    var filteredOptions: [PromptCommandOption] {
        if query.isEmpty {
            return visibleOptions
        } else {
            // Filter by title/subtitle match OR color match
            let filtered = visibleOptions.filter {
                $0.title.promptMatchedIndices(for: query) != nil ||
                ($0.subtitle?.promptMatchedIndices(for: query) != nil) ||
                colorMatchScore(for: $0.leadingColor, query: query) > 0
            }

            // Sort by color match score (higher scores first), then maintain original order
            return filtered.sorted { a, b in
                let scoreA = colorMatchScore(for: a.leadingColor, query: query)
                let scoreB = colorMatchScore(for: b.leadingColor, query: query)
                return scoreA > scoreB
            }
        }
    }

    var selectedOption: PromptCommandOption? {
        guard let selectedIndex else { return nil }
        return if selectedIndex < filteredOptions.count {
            filteredOptions[Int(selectedIndex)]
        } else {
            filteredOptions.last
        }
    }

    var body: some View {
        let scheme: ColorScheme = if OSColor(backgroundColor).isLightColor {
            .light
        } else {
            .dark
        }

        PromptGlassEffectContainer(spacing: 18) {
            if let sidebarEditor {
                PromptSidebarVisualEditor(store: sidebarEditor, onBack: { self.sidebarEditor = nil })
            } else if let folderPicker {
                FolderPickerView(
                    configuration: folderPicker,
                    isPresented: $isPresented,
                    onBack: { self.folderPicker = nil })
            } else {
        ZStack(alignment: .bottomTrailing) {
        VStack(alignment: .leading, spacing: 0) {
            CommandPaletteQuery(
                query: $rawQuery,
                title: pages.last?.title,
                canGoBack: !pages.isEmpty,
                dismissOnFocusLoss: !actionsArePresented,
                onBack: goBack
            ) { event in
                switch event {
                case .exit:
                    if pages.isEmpty { isPresented = false } else { goBack() }

                case .submit:
                    if let selectedOption { activate(selectedOption) }

                case .move(.up):
                    if filteredOptions.isEmpty { break }
                    let current = selectedIndex ?? UInt(filteredOptions.count)
                    selectedIndex = (current == 0)
                        ? UInt(filteredOptions.count - 1)
                        : current - 1

                case .move(.down):
                    if filteredOptions.isEmpty { break }
                    let current = selectedIndex ?? UInt.max
                    selectedIndex = (current >= UInt(filteredOptions.count - 1))
                        ? 0
                        : current + 1

                case .move(.left):
                    if !pages.isEmpty { goBack() }

                case .move:
                    break
                }
            }
            .onChange(of: query) { _ in
                // Always keep an actionable row selected so Return works immediately.
                selectedIndex = filteredOptions.isEmpty ? nil : 0
            }

            Divider().opacity(0.55)

            CommandTable(
                options: filteredOptions,
                query: query,
                selectedIndex: $selectedIndex,
                hoveredOptionID: $hoveredOptionID) { option in
                    activate(option)
            }

            Divider().opacity(0.55)

            HStack(spacing: 16) {
                PaletteHint(keys: ["↑", "↓"], label: "Navigate")
                PaletteHint(keys: ["↩"], label: "Select")
                Spacer()
                if let selectedOption {
                    Button {
                        activate(selectedOption)
                    } label: {
                        PaletteHint(
                            keys: ["↩"],
                            label: selectedOption.children == nil && selectedOption.folderPicker == nil && selectedOption.sidebarEditor == nil ? "Run" : "Open")
                    }
                    .promptGlassButtonStyle()

                    Button { toggleActions() } label: {
                        PaletteHint(keys: ["⌘", "K"], label: "Actions")
                    }
                    .promptGlassButtonStyle()
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 18)
            .frame(height: 48)
        }
            if actionsArePresented, let selectedOption {
                CommandActionsView(
                    option: selectedOption,
                    onPrimary: { activate(selectedOption) },
                    onDismiss: { actionsArePresented = false })
                    .frame(width: 330)
                    .padding(.trailing, 12)
                    .padding(.bottom, 54)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                    .zIndex(4)
            }

            Button { toggleActions() } label: { Color.clear }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: [.command])
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
            }
        }
        .frame(maxWidth: 720)
        .promptLiquidGlassSurface(
            tint: backgroundColor.opacity(scheme == .dark ? 0.12 : 0.06),
            cornerRadius: 28)
        .padding()
        .environment(\.colorScheme, scheme)
        .onChange(of: isPresented) { newValue in
            if !newValue {
                // This is optional, since most of the time
                // there will be a delay before the next use.
                // To keep behavior the same as before, we reset it.
                rawQuery = ""
                selectedIndex = 0
                pages = []
                folderPicker = nil
                sidebarEditor = nil
                actionsArePresented = false
            }
        }
    }

    private func activate(_ option: PromptCommandOption) {
        actionsArePresented = false
        if let picker = option.folderPicker {
            folderPicker = picker
        } else if let editor = option.sidebarEditor {
            sidebarEditor = editor
        } else if let children = option.children {
            pages.append((option.title, children()))
            rawQuery = ""
            selectedIndex = 0
        } else {
            isPresented = false
            option.action()
        }
    }

    private func toggleActions() {
        guard selectedOption != nil else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            actionsArePresented.toggle()
        }
    }

    private func goBack() {
        guard !pages.isEmpty else { isPresented = false; return }
        pages.removeLast()
        rawQuery = ""
        selectedIndex = 0
    }

    /// Returns a score (0.0 to 1.0) indicating how well a color matches a search query color name.
    /// Returns 0 if no color name in the query matches, or if the color is nil.
    private func colorMatchScore(for color: Color?, query: String) -> Double {
        guard let color = color else { return 0 }

        let queryLower = query.lowercased()
        let nsColor = NSColor(color)

        var bestScore: Double = 0
        for name in NSColor.colorNames {
            guard queryLower.contains(name),
                  let systemColor = NSColor(named: name) else { continue }

            let distance = nsColor.distance(to: systemColor)
            // Max distance in weighted RGB space is ~3.0, so normalize and invert
            // Use a threshold to determine "close enough" matches
            let maxDistance: Double = 1.5
            if distance < maxDistance {
                let score = 1.0 - (distance / maxDistance)
                bestScore = max(bestScore, score)
            }
        }

        return bestScore
    }
}

private struct PromptSidebarVisualEditor: View {
    @ObservedObject var store: PromptWorkspaceStore
    let onBack: () -> Void
    @State private var selection: UUID?
    @State private var actionsVisible = false
    @StateObject private var keyMonitor = PromptSidebarEditorKeyMonitor()

    private var groups: [(String, [PromptSession])] {
        let sessions = store.orderedSessions
        var result = store.sidebarFolders.map { folder in (folder, sessions.filter { store.folder(for: $0) == folder }) }
        let automatic = sessions.filter { store.folder(for: $0) == nil }
        let names = Array(Set(automatic.map { machine($0.configuration) })).sorted()
        result += names.map { name in (name, automatic.filter { machine($0.configuration) == name }) }
        return result
    }
    private var sessions: [PromptSession] { groups.flatMap(\.1) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: onBack) { Image(systemName: "chevron.left").frame(width: 28, height: 28) }.promptGlassButtonStyle()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Edit sidebar").font(.system(size: 17, weight: .semibold))
                        Text("Drag sessions into groups or reorder them").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { createFolder() } label: { Label("Folder", systemImage: "folder.badge.plus") }.promptGlassButtonStyle()
                }.padding(.horizontal, 18).frame(height: 64)
                Divider().opacity(0.55)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(groups, id: \.0) { name, sessions in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Image(systemName: store.sidebarFolders.contains(name) ? "folder" : "desktopcomputer")
                                    Text(name).fontWeight(.semibold)
                                    Spacer(); Text("\(sessions.count)").foregroundStyle(.tertiary)
                                }
                                .font(.system(size: 13)).padding(.horizontal, 10).frame(height: 32)
                                .contextMenu { folderMenu(name) }
                                .modifier(PromptSessionDropTarget(store: store, target: sessions.first?.id, folder: store.sidebarFolders.contains(name) ? name : nil))
                                ForEach(sessions) { session in
                                    editorRow(session)
                                        .draggable(PromptSessionDragPayload(id: session.id))
                                        .modifier(PromptSessionDropTarget(store: store, target: session.id, folder: store.sidebarFolders.contains(name) ? name : nil))
                                }
                                if sessions.isEmpty {
                                    Text("Drop a session here").font(.caption).foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity).frame(height: 38)
                                }
                            }
                            .padding(7)
                            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding(12)
                }.frame(height: 410)
                Divider().opacity(0.55)
                HStack { PaletteHint(keys: ["drag"], label: "Move"); PaletteHint(keys: ["⌘", "K"], label: "Actions"); Spacer(); Text("Changes apply instantly").foregroundStyle(.tertiary) }
                    .font(.system(size: 11, weight: .medium)).padding(.horizontal, 18).frame(height: 48)
            }
            if actionsVisible, let session = selectedSession {
                CommandActionsView(
                    option: actionOption(session),
                    onPrimary: { store.focus(sessionID: session.id, paneID: session.focusedPaneID) },
                    onDismiss: { actionsVisible = false },
                    customActions: actionItems(session))
                    .frame(width: 330).padding(.trailing, 12).padding(.bottom, 54)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
        }
        .onAppear { if selection == nil { selection = sessions.first?.id } }
        .onChange(of: actionsVisible) { keyMonitor.actionsVisible = $0 }
        .onReceive(keyMonitor.$action.compactMap { $0 }) { action in
            switch action {
            case .up: moveSelection(-1)
            case .down: moveSelection(1)
            case .actions:
                if selectedSession != nil { withAnimation(.easeOut(duration: 0.14)) { actionsVisible.toggle() } }
            }
            keyMonitor.action = nil
        }
    }

    private var selectedSession: PromptSession? { selection.flatMap { id in store.workspace.sessions.first { $0.id == id } } }

    private func editorRow(_ session: PromptSession) -> some View {
        Button { selection = session.id; actionsVisible = false } label: {
            HStack(spacing: 10) {
                Image(systemName: session.configuration.isRemote ? "network" : "terminal").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) { Text(session.title).fontWeight(.medium); Text((store.runtime.surface(for: session.focusedPaneID)?.workingDirectory ?? session.configuration.configuredDirectory ?? "Starting…").promptDisplayPath).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer(); Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            }.padding(.horizontal, 10).frame(height: 48).contentShape(Rectangle())
                .background(selection == session.id ? PromptTheme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).contextMenu { sessionMenu(session) }
    }

    private func actionOption(_ session: PromptSession) -> PromptCommandOption {
        PromptCommandOption(title: session.title, section: "Session", subtitle: (store.runtime.surface(for: session.focusedPaneID)?.workingDirectory ?? session.configuration.configuredDirectory)?.promptDisplayPath, description: "Sidebar session") {}
    }

    private func actionItems(_ session: PromptSession) -> [PromptCommandAction] {
        var items = [
            PromptCommandAction(title: "Open Session", icon: "return", shortcut: ["↩"]) { store.focus(sessionID: session.id, paneID: session.focusedPaneID) },
            PromptCommandAction(title: "Rename…", icon: "pencil", shortcut: []) { rename(session) },
            PromptCommandAction(title: "Move to Top", icon: "arrow.up.to.line", shortcut: []) { store.moveSession(session.id, before: store.workspace.sessions.first?.id) },
            PromptCommandAction(title: "Automatic Group", icon: "desktopcomputer", shortcut: []) { store.assignSession(session.id, to: nil) },
        ]
        items += store.sidebarFolders.map { folder in PromptCommandAction(title: "Move to \(folder)", icon: "folder", shortcut: []) { store.assignSession(session.id, to: folder) } }
        items.append(PromptCommandAction(title: "Close Session", icon: "xmark", shortcut: []) { store.closeSession(session.id) })
        return items
    }

    private func moveSelection(_ delta: Int) {
        guard !sessions.isEmpty else { return }
        let current = selection.flatMap { id in sessions.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : 0)
        let next = (current + delta + sessions.count) % sessions.count
        selection = sessions[next].id
        actionsVisible = false
    }

    @ViewBuilder private func sessionMenu(_ session: PromptSession) -> some View { Button("Rename…") { rename(session) }; Menu("Move to group") { moveMenu(session) }; Divider(); Button("Close Session", role: .destructive) { store.closeSession(session.id) } }
    @ViewBuilder private func moveMenu(_ session: PromptSession) -> some View { Button("Automatic") { store.assignSession(session.id, to: nil) }; ForEach(store.sidebarFolders, id: \.self) { folder in Button(folder) { store.assignSession(session.id, to: folder) } } }
    @ViewBuilder private func folderMenu(_ name: String) -> some View { if store.sidebarFolders.contains(name) { Button("Rename…") { renameFolder(name) }; Button("Delete Folder", role: .destructive) { store.deleteSidebarFolder(name) } } }
    private func machine(_ config: PromptSessionConfiguration) -> String { switch config { case .local: "Local"; case .remote(let value): value.destination } }
    private func createFolder() { if let value = PromptSidebarPrompts.text(title: "New sidebar folder", value: "") { store.createSidebarFolder(named: value) } }
    private func rename(_ session: PromptSession) { if let value = PromptSidebarPrompts.text(title: "Rename session", value: session.title) { store.renameSession(session.id, to: value) } }
    private func renameFolder(_ name: String) { if let value = PromptSidebarPrompts.text(title: "Rename folder", value: name) { store.renameSidebarFolder(name, to: value) } }
}

@MainActor
private final class PromptSidebarEditorKeyMonitor: ObservableObject {
    enum Action { case up, down, actions }
    @Published var action: Action?
    var actionsVisible = false
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command],
                   event.charactersIgnoringModifiers?.lowercased() == "k" {
                    self?.action = .actions
                    return nil
                }
                guard event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else { return event }
                if self?.actionsVisible == true { return event }
                if event.keyCode == 126 { self?.action = .up; return nil }
                if event.keyCode == 125 { self?.action = .down; return nil }
                return event
            }
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

struct PromptFolderPickerEntry: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
}

struct PromptFolderPickerConfiguration {
    let initialDirectory: String
    let displayName: (String) -> String
    let directories: (String) async throws -> [PromptFolderPickerEntry]
    let onSelect: (String) -> Void
    let onReveal: ((String) -> Void)?
}

private struct FolderPickerView: View {
    let configuration: PromptFolderPickerConfiguration
    @Binding var isPresented: Bool
    let onBack: () -> Void

    @State private var directory: String
    @State private var pathField: String
    @State private var entries: [PromptFolderPickerEntry] = []
    @State private var selectedIndex = 0
    @State private var loadError: String?
    @State private var isLoading = false
    @FocusState private var pathFocused: Bool

    init(configuration: PromptFolderPickerConfiguration, isPresented: Binding<Bool>, onBack: @escaping () -> Void) {
        self.configuration = configuration
        _isPresented = isPresented
        self.onBack = onBack
        _directory = State(initialValue: configuration.initialDirectory)
        _pathField = State(initialValue: configuration.displayName(configuration.initialDirectory))
    }

    private var parentPath: String? {
        if directory == "/" || directory == "~" { return nil }
        if directory.hasPrefix("~/") {
            let value = String(directory.dropLast(directory.split(separator: "/").last?.count ?? 0))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return value.isEmpty ? "~" : value
        }
        let parent = (directory as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 24, height: 28)
                }
                .promptGlassButtonStyle()
                .help("Back")

                TextField("Folder path", text: $pathField)
                    .font(.system(size: 17, weight: .semibold))
                    .textFieldStyle(.plain)
                    .focused($pathFocused)
                    .onSubmit { choose(pathField) }

                Button { chooseCurrentDirectory() } label: {
                    HStack(spacing: 8) {
                        Text("Add")
                            .foregroundStyle(.primary)
                        Text("⌘ Enter")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                }
                .promptGlassButtonStyle(prominent: true)

                Button(action: chooseCurrentDirectory) { Color.clear }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)
            .frame(height: 62)
            .background {
                Group {
                    Button { moveSelection(.up) } label: { Color.clear }
                        .keyboardShortcut(.upArrow, modifiers: [])
                    Button { moveSelection(.down) } label: { Color.clear }
                        .keyboardShortcut(.downArrow, modifiers: [])
                    Button { goToParent() } label: { Color.clear }
                        .keyboardShortcut(.delete, modifiers: [])
                    Button { openSelected() } label: { Color.clear }
                        .keyboardShortcut(.return, modifiers: [])
                }
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }

            Divider().opacity(0.55)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        Text("Directories")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)

                        if let parentPath {
                            FolderPickerRow(name: "..", icon: "arrow.turn.up.left", selected: selectedIndex == 0) {
                                navigate(to: parentPath)
                            }
                            .id("__parent")
                        }

                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            let rowIndex = index + (parentPath == nil ? 0 : 1)
                            FolderPickerRow(name: entry.name, icon: "folder", selected: selectedIndex == rowIndex) {
                                navigate(to: entry.path)
                            }
                            .id(entry.id)
                        }

                        if isLoading {
                            ProgressView().controlSize(.small).padding(18)
                        } else if let loadError {
                            Text(loadError)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(18)
                        } else if entries.isEmpty && parentPath == nil {
                            Text("No subdirectories")
                                .foregroundStyle(.secondary)
                                .padding(18)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 420)
                .onChange(of: selectedIndex) { _ in
                    if selectedIndex == 0, parentPath != nil { proxy.scrollTo("__parent") }
                    else {
                        let offset = selectedIndex - (parentPath == nil ? 0 : 1)
                        if entries.indices.contains(offset) { proxy.scrollTo(entries[offset].id) }
                    }
                }
            }
            .onMoveCommand { direction in
                moveSelection(direction)
            }
            .onSubmit { openSelected() }

            Divider().opacity(0.55)

            HStack(spacing: 14) {
                PaletteHint(keys: ["↑", "↓"], label: "Navigate")
                PaletteHint(keys: ["↩"], label: "Open")
                PaletteHint(keys: ["⌫"], label: "Back")
                PaletteHint(keys: ["esc"], label: "Close")
                Spacer()
                if let onReveal = configuration.onReveal {
                    Button("Open in Finder") { onReveal(directory) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 18)
            .frame(height: 48)
        }
        .onExitCommand { isPresented = false }
        .task(id: directory) { await loadDirectory() }
        .onAppear { DispatchQueue.main.async { pathFocused = false } }
    }

    private func openSelected() {
        if selectedIndex == 0, let parentPath { navigate(to: parentPath); return }
        let offset = selectedIndex - (parentPath == nil ? 0 : 1)
        if entries.indices.contains(offset) { navigate(to: entries[offset].path) }
    }

    private func navigate(to value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        directory = trimmed
        pathField = configuration.displayName(trimmed)
        selectedIndex = 0
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        // Arrow navigation deliberately leaves path editing and hands focus to
        // the directory list, so the following Return opens the highlighted row.
        pathFocused = false
        let count = entries.count + (parentPath == nil ? 0 : 1)
        guard count > 0 else { return }
        if direction == .up { selectedIndex = selectedIndex == 0 ? count - 1 : selectedIndex - 1 }
        if direction == .down { selectedIndex = (selectedIndex + 1) % count }
    }

    private func goToParent() {
        // NSTextField owns Delete while editing, preserving normal character deletion.
        guard !pathFocused, let parentPath else { return }
        navigate(to: parentPath)
    }

    private func choose(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isPresented = false
        configuration.onSelect(trimmed)
    }

    private func chooseCurrentDirectory() {
        choose(pathFocused ? pathField : directory)
    }

    private func loadDirectory() async {
        isLoading = true
        loadError = nil
        do {
            entries = try await configuration.directories(directory)
        } catch {
            entries = []
            loadError = error.localizedDescription
        }
        selectedIndex = 0
        isLoading = false
    }
}

private struct FolderPickerRow: View {
    let name: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text(name)
                    .font(.system(size: 15, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(selected ? Color.secondary.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CommandActionsView: View {
    let option: PromptCommandOption
    let onPrimary: () -> Void
    let onDismiss: () -> Void
    var customActions: [PromptCommandAction]? = nil

    @State private var query = ""
    @State private var selectedIndex = 0
    @StateObject private var keyMonitor = PromptCommandActionsKeyMonitor()
    @FocusState private var searchFocused: Bool

    private var actions: [PromptCommandAction] {
        if let customActions { return customActions }
        if let contextualActions = option.contextualActions { return contextualActions() }
        return [PromptCommandAction(
            title: option.primaryActionTitle,
            icon: "return",
            shortcut: ["↩"],
            action: onPrimary)]
    }

    private var filteredActions: [PromptCommandAction] {
        guard !query.isEmpty else { return actions }
        return actions.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(option.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 44)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(filteredActions.enumerated()), id: \.element.id) { index, item in
                        Button { perform(item) } label: {
                            HStack(spacing: 11) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 14, weight: .medium))
                                    .frame(width: 20)
                                Text(item.title)
                                    .font(.system(size: 14, weight: .medium))
                                Spacer()
                                if !item.shortcut.isEmpty {
                                    HStack(spacing: 3) {
                                        ForEach(item.shortcut, id: \.self) { key in
                                            Text(key)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .frame(height: 24)
                                                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 11)
                            .frame(height: 40)
                            .background(index == selectedIndex ? Color.secondary.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 205)

            Divider().opacity(0.55)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("Search for actions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit { activateSelected() }
            }
            .padding(.horizontal, 13)
            .frame(height: 44)
        }
        .promptLiquidGlassSurface(cornerRadius: 20)
        .onAppear {
            searchFocused = true
            DispatchQueue.main.async { searchFocused = true }
        }
        .onReceive(keyMonitor.$action.compactMap { $0 }) { action in
            switch action {
            case .up:
                if !filteredActions.isEmpty { selectedIndex = selectedIndex == 0 ? filteredActions.count - 1 : selectedIndex - 1 }
            case .down:
                if !filteredActions.isEmpty { selectedIndex = (selectedIndex + 1) % filteredActions.count }
            case .submit: activateSelected()
            case .dismiss: onDismiss()
            }
            keyMonitor.action = nil
        }
        .onChange(of: query) { _ in selectedIndex = 0 }
        .onMoveCommand { direction in
            guard !filteredActions.isEmpty else { return }
            if direction == .up { selectedIndex = selectedIndex == 0 ? filteredActions.count - 1 : selectedIndex - 1 }
            if direction == .down { selectedIndex = (selectedIndex + 1) % filteredActions.count }
        }
        .onExitCommand { onDismiss() }
    }

    private func activateSelected() {
        guard filteredActions.indices.contains(selectedIndex) else { return }
        perform(filteredActions[selectedIndex])
    }

    private func perform(_ item: PromptCommandAction) {
        onDismiss()
        item.action()
    }

}

@MainActor
private final class PromptCommandActionsKeyMonitor: ObservableObject {
    enum Action { case up, down, submit, dismiss }
    @Published var action: Action?
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else { return event }
                switch event.keyCode {
                case 126: self?.action = .up
                case 125: self?.action = .down
                case 36, 76: self?.action = .submit
                case 53: self?.action = .dismiss
                default: return event
                }
                return nil
            }
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

/// The text field for building the query for the command palette.
private struct CommandPaletteQuery: View {
    @Binding var query: String
    var title: String?
    var canGoBack: Bool
    var dismissOnFocusLoss: Bool
    var onBack: () -> Void
    var onEvent: ((KeyboardEvent) -> Void)?
    @FocusState private var isTextFieldFocused: Bool

    init(query: Binding<String>, title: String?, canGoBack: Bool, dismissOnFocusLoss: Bool, onBack: @escaping () -> Void, onEvent: ((KeyboardEvent) -> Void)? = nil) {
        _query = query
        self.title = title
        self.canGoBack = canGoBack
        self.dismissOnFocusLoss = dismissOnFocusLoss
        self.onBack = onBack
        self.onEvent = onEvent
    }

    enum KeyboardEvent {
        case exit
        case submit
        case move(MoveCommandDirection)
    }

    var body: some View {
        ZStack {
            Group {
                Button { onEvent?(.move(.up)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button { onEvent?(.move(.down)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.downArrow, modifiers: [])

                Button { onEvent?(.move(.up)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.init("p"), modifiers: [.control])
                Button { onEvent?(.move(.down)) } label: { Color.clear }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.init("n"), modifiers: [.control])
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)

            HStack(spacing: 12) {
                if canGoBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .promptGlassButtonStyle()
                    .help("Back")
                }
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(title.map { "Search \($0.lowercased())…" } ?? "Search sessions and commands…", text: $query)
                    .font(.system(size: 17, weight: .regular))
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
            }
                .padding(.horizontal, 18)
                .frame(height: 62)
                .textFieldStyle(.plain)
                .onChange(of: isTextFieldFocused) { focused in
                    if !focused && dismissOnFocusLoss {
                        onEvent?(.exit)
                    }
                }
                .onExitCommand { onEvent?(.exit) }
                .onMoveCommand { onEvent?(.move($0)) }
                .onSubmit { onEvent?(.submit) }
                .onAppear {
                    // Grab focus on the first appearance.
                    // Debug and Release build using Xcode 26.4,
                    // has same issue again
                    // Fixes: https://github.com/ghostty-org/ghostty/issues/8497
                    // SearchOverlay works magically as expected, I don't know
                    // why it's different here, but dispatching to next loop fixes it
                    DispatchQueue.main.async {
                        isTextFieldFocused = true
                    }
                }
        }
    }
}

private struct CommandTable: View {
    var options: [PromptCommandOption]
    var query: String
    @Binding var selectedIndex: UInt?
    @Binding var hoveredOptionID: UUID?
    var action: (PromptCommandOption) -> Void

    var body: some View {
        if options.isEmpty {
            Text("No matches")
                .foregroundStyle(.secondary)
                .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(options.enumerated()), id: \.1.id) { index, option in
                            if index == 0 || options[index - 1].section != option.section {
                                Text(option.section.uppercased())
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .tracking(0.7)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, index == 0 ? 4 : 13)
                                    .padding(.bottom, 4)
                            }
                            CommandRow(
                                option: option,
                                query: query,
                                isSelected: {
                                    if let selected = selectedIndex {
                                        return selected == index ||
                                            (selected >= options.count &&
                                                index == options.count - 1)
                                    } else {
                                        return false
                                    }
                                }(),
                                hoveredID: $hoveredOptionID
                            ) {
                                action(option)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 420)
                .onChange(of: selectedIndex) { _ in
                    guard let selectedIndex,
                          selectedIndex < options.count else { return }
                    proxy.scrollTo(
                        options[Int(selectedIndex)].id)
                }
            }
        }
    }
}

/// A single row in the command palette.
private struct CommandRow: View {
    let option: PromptCommandOption
    var query: String
    var isSelected: Bool
    @Binding var hoveredID: UUID?
    var action: () -> Void

    private var highlightedTitle: Text {
        guard !query.isEmpty,
              let indices = option.title.promptMatchedIndices(for: query) else {
            return Text(option.title)
                .fontWeight(option.emphasis ? .medium : .regular)
        }

        var attributed = AttributedString(option.title)
        attributed[attributed.startIndex...].font = .body
            .weight(option.emphasis ? .medium : .regular)

        for idx in indices {
            let offset = option.title.distance(from: option.title.startIndex, to: idx)
            let attrStart = attributed.index(attributed.startIndex, offsetByCharacters: offset)
            let attrEnd = attributed.index(attrStart, offsetByCharacters: 1)
            attributed[attrStart..<attrEnd].font = .body.bold()
            attributed[attrStart..<attrEnd].foregroundColor = Color.accentColor
        }

        return Text(attributed)
    }

    private func highlightedSubtitle(_ subtitle: String) -> Text {
        guard !query.isEmpty,
              option.title.promptMatchedIndices(for: query) == nil,
              let indices = subtitle.promptMatchedIndices(for: query) else {
            return Text(subtitle)
        }

        var attributed = AttributedString(subtitle)

        for idx in indices {
            let offset = subtitle.distance(from: subtitle.startIndex, to: idx)
            let attrStart = attributed.index(attributed.startIndex, offsetByCharacters: offset)
            let attrEnd = attributed.index(attrStart, offsetByCharacters: 1)
            attributed[attrStart..<attrEnd].font = .caption.bold()
            attributed[attrStart..<attrEnd].foregroundColor = Color.accentColor
        }

        return Text(attributed)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let color = option.leadingColor {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }

                if let icon = option.leadingIcon {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
                            .frame(width: 34, height: 34)
                        Image(systemName: icon)
                        .foregroundStyle(option.emphasis ? Color.accentColor : .secondary)
                        .font(.system(size: 14, weight: .medium))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    highlightedTitle

                    if let subtitle = option.subtitle {
                        highlightedSubtitle(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let badge = option.badge, !badge.isEmpty {
                    Text(badge)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.15))
                        )
                        .foregroundStyle(Color.accentColor)
                }

                if let symbols = option.symbols {
                    ShortcutSymbolsView(symbols: symbols)
                        .foregroundStyle(.secondary)
                }

                if option.children != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? Color.primary.opacity(0.095)
                    : (hoveredID == option.id
                       ? Color.primary.opacity(0.055)
                       : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(option.emphasis && !isSelected ? 0.3 : 0), lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .help(option.description ?? "")
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? option.id : nil
        }
    }
}

private struct PaletteHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 5))
            }
            Text(label).foregroundStyle(.secondary)
        }
    }
}

/// A row of Text representing a shortcut.
private struct ShortcutSymbolsView: View {
    let symbols: [String]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol)
                    .frame(minWidth: 13)
            }
        }
    }
}

extension String {
    /// Returns the character indices that match `query`, trying a substring match first,
    /// then falling back to initials matching (first letter of each word).
    /// - Returns: `nil` if neither matches.
    func promptMatchedIndices(for query: String) -> [String.Index]? {
        guard !query.isEmpty else { return nil }

        // Prefer substring match.
        if let range = self.range(of: query, options: .caseInsensitive) {
            return Array(self[range].indices)
        }

        // Fall back to initials match.
        let words = self.split(whereSeparator: \.isWhitespace)
        var queryIndex = query.startIndex
        var matched: [String.Index] = []

        for word in words {
            guard queryIndex < query.endIndex else { break }

            if word.first?.lowercased() == query[queryIndex].lowercased() {
                matched.append(word.startIndex)
                queryIndex = query.index(after: queryIndex)
            }
        }

        return queryIndex == query.endIndex ? matched : nil
    }
}
