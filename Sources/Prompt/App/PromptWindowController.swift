import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

enum PromptTheme {
    static let canvas = Color(red: 0.090, green: 0.090, blue: 0.086)
    static let sidebar = Color(red: 0.153, green: 0.157, blue: 0.165)
    static let elevated = Color(red: 0.125, green: 0.125, blue: 0.122)
    static let selection = Color.white.opacity(0.075)
    static let border = Color.white.opacity(0.10)
    static let accent = Color(red: 0.063, green: 0.639, blue: 0.498)
}

enum PromptKeyboardFocusRouting {
    @MainActor
    static func preservesEditableControl(_ responder: NSResponder?) -> Bool {
        if let textView = responder as? NSTextView { return textView.isEditable }
        if let textField = responder as? NSTextField { return textField.isEditable && textField.isEnabled }
        return false
    }
}

/// Keeps AppKit's responder chain aligned with Prompt's input model.
///
/// Ghostty surfaces are native AppKit views embedded in SwiftUI. SwiftUI can
/// leave a sidebar control (or a previously focused surface) as first
/// responder after the visible workspace has changed. That makes ordinary
/// typing appear to disappear. The command palette is the one exception: it
/// owns keyboard input for its complete lifetime, including its Cmd-K actions
/// popover.
@MainActor
private final class PromptWindow: NSWindow {
    weak var workspaceStore: PromptWorkspaceStore?

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, let workspaceStore else {
            super.sendEvent(event)
            return
        }

        if workspaceStore.isCommandPalettePresented {
            // Some palette pages (for example the sidebar editor) intentionally
            // have no text field. Their local monitors handle navigation; do
            // not let any unhandled characters fall through to the terminal.
            guard focusPaletteInputIfAvailable() else { return }
        } else if !PromptKeyboardFocusRouting.preservesEditableControl(firstResponder),
                  let session = workspaceStore.workspace.sessions.first(where: {
            $0.id == workspaceStore.workspace.focusedSessionID
        }), let surface = workspaceStore.runtime.surface(for: session.focusedPaneID) {
            // Application shortcuts are consumed by the local shortcut router
            // before they arrive here. Reclaim terminal focus after sidebar
            // interactions, but preserve SwiftUI's field editor while a
            // composer or command-bar field owns keyboard input.
            surface.focus()
        }

        super.sendEvent(event)
    }

    @discardableResult
    private func focusPaletteInputIfAvailable() -> Bool {
        // The palette's search and folder-path fields are native NSTextFields.
        // Focusing the visible editable field immediately before dispatching
        // each event closes the SwiftUI/AppKit focus race and prevents the
        // underlying terminal from receiving palette input.
        guard let field = firstVisibleEditableTextField(in: contentView) else { return false }
        // NSTextField uses a shared NSTextView field editor as the actual
        // first responder. Calling makeFirstResponder on an already active
        // field selects its full contents, so doing that for every keyDown
        // turns typing "hello" into five replacements. Only reclaim focus
        // after it has genuinely moved outside the palette field.
        if firstResponder !== field, firstResponder !== field.currentEditor() {
            makeFirstResponder(field)
        }
        return true
    }

    private func firstVisibleEditableTextField(in view: NSView?) -> NSTextField? {
        guard let view, !view.isHidden else { return nil }
        if let field = view as? NSTextField, field.isEditable, field.isEnabled {
            return field
        }
        for subview in view.subviews {
            if let field = firstVisibleEditableTextField(in: subview) { return field }
        }
        return nil
    }
}

@MainActor
final class PromptWindowController: NSWindowController, ObservableObject {
    let store: PromptWorkspaceStore

    var isCommandPalettePresented: Bool {
        get { store.isCommandPalettePresented }
        set { store.isCommandPalettePresented = newValue }
    }

    init(store: PromptWorkspaceStore) {
        self.store = store
        let root = PromptWorkspaceView(store: store)
        let hosting = NSHostingController(rootView: root)
        let window = PromptWindow(contentViewController: hosting)
        window.workspaceStore = store
        window.title = "Prompt"
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.minSize = NSSize(width: 720, height: 440)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.086, alpha: 1)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.setFrameAutosaveName("PromptMainWindow")
    }

    required init?(coder: NSCoder) { nil }
}

private struct PromptWorkspaceView: View {
    @ObservedObject var store: PromptWorkspaceStore

    var body: some View {
        HStack(spacing: 0) {
            PromptSessionSidebar(store: store)
                .frame(width: 300)
                .background(PromptTheme.sidebar)
            Divider()
            if let session = store.workspace.sessions.first(where: { $0.id == store.workspace.focusedSessionID }) {
                PromptSplitNodeView(store: store, session: session, tree: session.splitTree)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "terminal").font(.largeTitle)
                    Text("No Sessions").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(PromptTheme.canvas)
        .preferredColorScheme(.dark)
        .tint(PromptTheme.accent)
        .overlay {
            PromptCommandPaletteView(
                store: store,
                surface: focusedSurface,
                isPresented: $store.isCommandPalettePresented)
        }
        .background {
            HStack {
                ForEach(0 ..< 9, id: \.self) { index in
                    Button { store.focusSidebarSession(at: index) } label: { Color.clear }
                        .buttonStyle(.plain)
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
                }
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private var focusedSurface: PromptTerminalSurface? {
        guard let session = store.workspace.sessions.first(where: { $0.id == store.workspace.focusedSessionID }) else { return nil }
        return store.runtime.surface(for: session.focusedPaneID)
    }
}

private struct PromptSessionSidebar: View {
    @ObservedObject var store: PromptWorkspaceStore
    @State private var collapsedGroups: Set<String> = []
    @StateObject private var commandKey = PromptCommandKeyMonitor()
    @State private var hoveredGroup: String?

    private var groups: [(String, [PromptSession])] {
        var result: [(String, [PromptSession])] = []
        let sessions = store.orderedSessions
        let custom = store.sidebarFolders.map { folder in (folder, sessions.filter { store.folder(for: $0) == folder }) }
        result.append(contentsOf: custom)
        let automatic = sessions.filter { store.folder(for: $0) == nil }
        let names = Array(Set(automatic.map(\.configuration.sidebarMachine))).sorted()
        result.append(contentsOf: names.map { name in (name, automatic.filter { $0.configuration.sidebarMachine == name }) })
        return result
    }

    private var visibleSessions: [PromptSession] {
        if store.sidebarLayout == .flat { return store.orderedSessions }
        return groups.flatMap { collapsedGroups.contains($0.0) ? [] : $0.1 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SESSIONS").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    Text("\(store.workspace.sessions.count) open").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Menu {
                    Section("Layout") {
                        Picker("Layout", selection: $store.sidebarLayout) {
                            Text("Flat").tag(PromptWorkspaceStore.SidebarLayout.flat)
                            Text("Grouped by machine").tag(PromptWorkspaceStore.SidebarLayout.grouped)
                        }
                    }
                    Section("Sort sessions") {
                        Picker("Sort", selection: $store.sidebarSort) {
                            ForEach(PromptWorkspaceStore.SidebarSort.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                    Divider()
                    Button("Manage folders in Command Palette…") { store.isCommandPalettePresented = true }
                } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Button { store.createLocal(directory: NSHomeDirectory()) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if store.sidebarLayout == .flat {
                        ForEach(Array(store.orderedSessions.enumerated()), id: \.element.id) { index, session in
                            sessionRow(session, shortcut: commandKey.isPressed && index < 9 ? index + 1 : nil, grouped: false)
                                .draggable(PromptSessionDragPayload(id: session.id))
                                .modifier(PromptSessionDropTarget(store: store, target: session.id, folder: store.folder(for: session)))
                        }
                    } else {
                        ForEach(groups, id: \.0) { name, sessions in
                            VStack(alignment: .leading, spacing: 0) {
                                Button { toggle(name) } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .bold))
                                            .rotationEffect(.degrees(collapsedGroups.contains(name) ? 0 : 90))
                                        Image(systemName: store.sidebarFolders.contains(name) ? "folder" : "desktopcomputer")
                                            .foregroundStyle(.secondary)
                                        Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                        Spacer()
                                        Text("\(sessions.count)").font(.caption).foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle()).padding(.horizontal, 8).frame(height: 38)
                                }.buttonStyle(.plain)
                                    .contextMenu { groupContextMenu(name) }
                                    .modifier(PromptSessionDropTarget(store: store, target: nil, folder: store.sidebarFolders.contains(name) ? name : nil))
                                if !collapsedGroups.contains(name) {
                                    VStack(spacing: 2) {
                                        ForEach(sessions) { session in
                                            let index = visibleSessions.firstIndex(where: { $0.id == session.id })
                                            sessionRow(session, shortcut: commandKey.isPressed ? index.flatMap { $0 < 9 ? $0 + 1 : nil } : nil, grouped: true)
                                                .draggable(PromptSessionDragPayload(id: session.id))
                                                .modifier(PromptSessionDropTarget(store: store, target: session.id, folder: store.sidebarFolders.contains(name) ? name : nil))
                                                .onHover { hovering in
                                                    withAnimation(.easeOut(duration: 0.14)) {
                                                        hoveredGroup = hovering ? name : (hoveredGroup == name ? nil : hoveredGroup)
                                                    }
                                                }
                                        }
                                    }
                                    .padding(.leading, 19)
                                    .overlay(alignment: .leading) {
                                        Rectangle()
                                            .fill(hoveredGroup == name ? Color.white.opacity(0.28) : PromptTheme.border)
                                            .frame(width: hoveredGroup == name ? 1.5 : 1)
                                            .padding(.leading, 7)
                                    }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }
        }
        .onAppear { syncVisualOrder() }
        .onChange(of: store.sidebarLayout) { _ in syncVisualOrder() }
        .onChange(of: store.sidebarSort) { _ in syncVisualOrder() }
        .onChange(of: store.workspace.sessions.map(\.id)) { _ in syncVisualOrder() }
        .onChange(of: collapsedGroups) { _ in syncVisualOrder() }
    }

    private func toggle(_ name: String) {
        if collapsedGroups.contains(name) { collapsedGroups.remove(name) } else { collapsedGroups.insert(name) }
    }

    private func syncVisualOrder() { store.updateSidebarVisualOrder(visibleSessions.map(\.id)) }

    private func sessionRow(_ session: PromptSession, shortcut: Int?, grouped: Bool) -> some View {
        PromptSidebarSessionRow(store: store, session: session, shortcut: shortcut, grouped: grouped)
    }

    @ViewBuilder private func groupContextMenu(_ name: String) -> some View {
        if store.sidebarFolders.contains(name) {
            Button("Rename Folder…") { if let value = PromptSidebarPrompts.text(title: "Rename folder", value: name) { store.renameSidebarFolder(name, to: value) } }
            Button("Delete Folder", role: .destructive) { store.deleteSidebarFolder(name) }
        }
    }
}

private struct PromptSidebarSessionRow: View {
    @ObservedObject var store: PromptWorkspaceStore
    @ObservedObject private var runtime: PromptTerminalRuntime
    @ObservedObject private var promptModel = PromptModel.shared
    let session: PromptSession
    let shortcut: Int?
    let grouped: Bool
    @State private var hovering = false
    @State private var showsAgentCard = false
    @State private var showsCloseHint = false
    @State private var closeHintGeneration = 0

    init(store: PromptWorkspaceStore, session: PromptSession, shortcut: Int?, grouped: Bool) {
        self.store = store
        self.runtime = store.runtime
        self.session = session
        self.shortcut = shortcut
        self.grouped = grouped
    }

    private var surface: PromptTerminalSurface? { store.runtime.surface(for: session.focusedPaneID) }
    private var remoteStatus: PromptTerminalRuntime.RemotePaneStatus? { runtime.remotePaneStatuses[session.focusedPaneID] }
    private var remoteConnectionState: PromptTerminalRuntime.RemoteConnectionState? { runtime.remoteConnectionStates[session.focusedPaneID] }
    private var directory: String { remoteStatus?.workingDirectory ?? surface?.workingDirectory ?? session.configuration.configuredDirectory ?? "Connecting…" }
    private var displayTitle: String {
        let folder = URL(fileURLWithPath: directory).lastPathComponent
        return folder.isEmpty || folder == "/" || directory == "Connecting…" ? session.title : folder
    }
    private var context: String? {
        if case .offline(let description) = remoteConnectionState { return description }
        if let status = remoteStatus, status.isBusy { return "Running \(status.command)" }
        guard let title = surface?.title.trimmingCharacters(in: .whitespacesAndNewlines),
              !session.configuration.isRemote, !title.isEmpty, title != session.title,
              !title.contains(directory), !title.contains("@"),
              !title.hasPrefix("~"), !title.hasPrefix("/"), !title.contains("/Users/") else { return nil }
        return title
    }
    private var isExecuting: Bool {
        if session.configuration.isRemote { return remoteStatus?.isBusy ?? false }
        return surface?.promptInput() == nil
    }
    private var metadata: String {
        let path = abbreviated(directory)
        if let branch = remoteStatus?.gitBranch ?? runtime.localGitBranches[session.focusedPaneID] {
            return "\(path)  ·  git:\(branch)"
        }
        return path
    }

    private enum AgentKind {
        case codex, claude

        var label: String { self == .codex ? "Codex" : "Claude" }
        var icon: String { self == .codex ? "sparkles" : "wand.and.stars" }
        var tint: Color { self == .codex ? PromptTheme.accent : Color(red: 0.83, green: 0.53, blue: 0.31) }
    }

    private var agentActivity: PromptModel.SidebarAgentActivity? {
        guard let surface else { return nil }
        return promptModel.sidebarAgentActivity(for: surface)
    }

    private var agentKind: AgentKind? {
        if agentActivity != nil { return .codex }
        let candidates = [remoteStatus?.command, runtime.localPaneCommands[session.focusedPaneID], session.configuration.launchCommand, surface?.title]
            .compactMap { $0?.lowercased() }
        if candidates.contains(where: { $0.contains("codex") }) { return .codex }
        if candidates.contains(where: { $0.contains("claude") }) { return .claude }
        return nil
    }

    private var agentHeadline: String {
        if let thread = runtime.localCodexThreads[session.focusedPaneID], !thread.title.isEmpty { return thread.title }
        if let activity = agentActivity, !activity.title.isEmpty { return activity.title }
        if let context, !context.hasPrefix("Running ") { return context }
        let trimmedTitle = surface?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let generic = ["codex", "claude", "terminal", session.title.lowercased()]
        if !trimmedTitle.isEmpty,
           !generic.contains(trimmedTitle.lowercased()),
           !trimmedTitle.contains(directory),
           !trimmedTitle.contains("/Users/") { return trimmedTitle }
        return session.title == "Codex" || session.title == "Claude" ? "\(displayTitle) workspace" : session.title
    }

    private var pullRequest: PromptTerminalRuntime.SidebarPullRequest? {
        guard !session.configuration.isRemote else { return nil }
        return runtime.localPullRequests[session.focusedPaneID]
    }

    private var startedAt: Date? {
        runtime.localCommandStartedAt[session.focusedPaneID]
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { store.focus(sessionID: session.id, paneID: session.focusedPaneID) } label: {
                Group {
                    if let agentKind { agentRow(agentKind) } else { standardRow }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 58)
                .contentShape(Rectangle())
                .scaleEffect(hovering ? 1.012 : 1, anchor: .leading)
                .offset(x: hovering ? 3 : 0)
                .animation(.spring(response: 0.18, dampingFraction: 0.72), value: hovering)
                .background(
                    session.id == store.workspace.focusedSessionID
                        ? PromptTheme.selection
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(
                    session.id == store.workspace.focusedSessionID ? PromptTheme.border : .clear,
                    lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            if pullRequest != nil || shortcut != nil {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if let pullRequest {
                        Link(destination: pullRequest.url) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Image(systemName: "arrow.triangle.pull")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("\(pullRequest.number)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                            .foregroundStyle(pullRequestColor)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(pullRequest.title) · Open on GitHub")
                    }
                    if let shortcut { shortcutLabel }
                }
                .padding(.trailing, 8)
                .padding(.top, 8)
            }
        }
        .onHover {
            hovering = $0
            showsAgentCard = $0 && agentKind != nil
        }
        .animation(.easeOut(duration: 0.12), value: shortcut)
        .popover(isPresented: $showsCloseHint, arrowEdge: .bottom) {
            HStack(spacing: 9) {
                Image(systemName: "command").foregroundStyle(PromptTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agentKind == .codex ? "Ctrl-C interrupts Codex turns" : "Ctrl-C interrupts remote commands")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Use ⌘W to close this session.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .popover(isPresented: $showsAgentCard, arrowEdge: .trailing) {
            if agentKind != nil {
                if #available(macOS 13.3, *) {
                    mouseTransparentAgentHoverCard
                        .presentationCornerRadius(12)
                } else {
                    mouseTransparentAgentHoverCard
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .promptRemoteControlC)) { note in
            guard session.id == store.workspace.focusedSessionID,
                  note.object as AnyObject? === surface else { return }
            closeHintGeneration += 1
            let generation = closeHintGeneration
            showsCloseHint = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                guard closeHintGeneration == generation else { return }
                showsCloseHint = false
            }
        }
        .contextMenu {
            Button("Rename…") { if let value = PromptSidebarPrompts.text(title: "Rename session", value: session.title) { store.renameSession(session.id, to: value) } }
            Menu("Move to Group") {
                Button("Automatic") { store.assignSession(session.id, to: nil) }
                ForEach(store.sidebarFolders, id: \.self) { folder in Button(folder) { store.assignSession(session.id, to: folder) } }
            }
            Divider()
            Button("Close Session", role: .destructive) { store.closeSession(session.id) }
        }
    }

    private var standardRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: remoteConnectionState?.isOffline == true ? "wifi.exclamationmark" : (session.configuration.isRemote ? "network" : "terminal"))
                .font(.system(size: 14))
                .foregroundStyle(remoteConnectionState?.isOffline == true ? Color.red : Color.secondary)
                .frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if isExecuting { ProgressView().controlSize(.mini) }
                }
                .padding(.trailing, headerAccessoryInset)
                if let context { Text(context).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                metadataLine
            }
        }
        .padding(.horizontal, 10)
    }

    private func agentRow(_ kind: AgentKind) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CodexMark()
                .frame(width: 18, height: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(agentHeadline).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if agentActivity?.isWorking == true || runtime.localCodexThreads[session.focusedPaneID]?.isWorking == true { ProgressView().controlSize(.mini) }
                if let startedAt, agentActivity?.isWorking == true {
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(startedAt, style: .relative).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.trailing, headerAccessoryInset)
            HStack(spacing: 6) {
                if let branch = remoteStatus?.gitBranch ?? runtime.localGitBranches[session.focusedPaneID] {
                    Text(branch)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                } else {
                    Text(abbreviated(directory)).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                }
            }
            .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
    }

    private var pullRequestColor: Color {
        guard let pullRequest else { return .secondary }
        if pullRequest.isDraft { return Color.secondary }
        switch pullRequest.state {
        case "MERGED": return Color.purple
        case "CLOSED": return Color.red
        default: return Color.green
        }
    }

    private var headerAccessoryInset: CGFloat {
        switch (pullRequest != nil, shortcut != nil) {
        case (true, true): return 50
        case (true, false): return 24
        case (false, true): return 24
        case (false, false): return 0
        }
    }

    private var agentHoverCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(agentHeadline)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            hoverCardRow(systemImage: "folder", text: displayTitle)

            if let host = Host.current().localizedName, !host.isEmpty {
                hoverCardRow(systemImage: "desktopcomputer", text: host)
            }

            if let branch = remoteStatus?.gitBranch ?? runtime.localGitBranches[session.focusedPaneID] {
                hoverCardRow(systemImage: "arrow.triangle.branch", text: branch, monospaced: true)
            }

            if let pullRequest {
                hoverCardRow(
                    systemImage: pullRequest.isDraft ? "pencil" : "arrow.triangle.pull",
                    text: "#\(pullRequest.number) · \(pullRequest.title)",
                    color: pullRequestColor)
            }

            HStack(spacing: 7) {
                CodexMark().frame(width: 13, height: 13)
                Text(codexModelSummary)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .frame(width: 220, alignment: .leading)
        .padding(12)
    }

    private var mouseTransparentAgentHoverCard: some View {
        agentHoverCard
            .background(PromptMouseTransparentPopover())
            .allowsHitTesting(false)
    }

    private var codexModelSummary: String {
        guard let thread = runtime.localCodexThreads[session.focusedPaneID] else { return "Codex" }
        let model = thread.model.map(formatCodexModel) ?? "Codex"
        guard let effort = thread.reasoningEffort, !effort.isEmpty else { return model }
        return "\(model) · \(effort.prefix(1).uppercased())\(effort.dropFirst())"
    }

    private func formatCodexModel(_ model: String) -> String {
        model.split(separator: "-").map { component in
            let value = String(component)
            if value.lowercased() == "gpt" { return "GPT" }
            if value.allSatisfy({ $0.isNumber || $0 == "." }) { return value }
            return value.prefix(1).uppercased() + value.dropFirst()
        }
        .joined(separator: "-")
    }

    private func hoverCardRow(
        systemImage: String,
        text: String,
        monospaced: Bool = false,
        color: Color = .secondary
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .frame(width: 13)
            Text(text)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .lineLimit(1)
        }
        .foregroundStyle(color)
    }

    private var shortcutLabel: some View {
        Text("⌘\(shortcut!)").font(.caption2.monospaced()).foregroundStyle(.secondary)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }

    private var metadataLine: some View {
        HStack(spacing: 5) {
            Text(metadata)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
            let panes = remoteStatus?.paneCount ?? session.splitTree.paneCount
            if panes > 1 { Text("· \(panes) panes").font(.system(size: 10)) }
        }.foregroundStyle(.tertiary)
    }

    private func abbreviated(_ path: String) -> String {
        path.promptDisplayPath
    }
}

/// SwiftUI presents a popover in a separate AppKit window. Making that window
/// mouse-transparent keeps this hover-only card from consuming the click that
/// selects its sidebar row.
private struct PromptMouseTransparentPopover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        PromptMouseTransparentView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.ignoresMouseEvents = true
    }
}

private final class PromptMouseTransparentView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.ignoresMouseEvents = true
    }
}

private struct CodexMark: View {
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "ChatGPTMark", withExtension: "svg", subdirectory: "Fonts"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().renderingMode(.template).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "circle.hexagongrid.fill").resizable().aspectRatio(contentMode: .fit)
            }
        }
        .foregroundStyle(.white)
        .accessibilityLabel("Codex")
    }
}

@MainActor
private final class PromptCommandKeyMonitor: ObservableObject {
    @Published var isPressed = false
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            self?.isPressed = event.modifierFlags.contains(.command)
            return event
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

struct PromptSessionDragPayload: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .promptSession)
    }
}

struct PromptSessionDropTarget: ViewModifier {
    let store: PromptWorkspaceStore
    let target: PromptSession.ID?
    let folder: String?
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(targeted ? PromptTheme.accent.opacity(0.9) : .clear, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .dropDestination(for: PromptSessionDragPayload.self) { values, _ in
                guard let id = values.first?.id, id != target else { return false }
                store.assignSession(id, to: folder)
                store.moveSession(id, before: target)
                return true
            } isTargeted: { value in
                withAnimation(.easeOut(duration: 0.12)) { targeted = value }
            }
    }
}

enum PromptSidebarPrompts {
    static func text(title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

extension UTType {
    static let promptSession = UTType(exportedAs: "dev.prompt.sidebar-session")
}

private struct PromptSplitNodeView: View {
    @ObservedObject var store: PromptWorkspaceStore
    let session: PromptSession
    let tree: PromptSplitTree

    var body: some View {
        switch tree {
        case .leaf(let pane):
            if let surface = store.runtime.surface(for: pane.id) {
                PromptHostedTerminalView(surface: surface, paneID: pane.id, runtime: store.runtime)
                    .id(pane.id)
                    .onTapGesture { store.focus(sessionID: session.id, paneID: pane.id) }
            }
        case .split(let axis, _, let first, let second):
            if axis == .horizontal {
                HSplitView {
                    PromptSplitNodeView(store: store, session: session, tree: first)
                    PromptSplitNodeView(store: store, session: session, tree: second)
                }
            } else {
                VSplitView {
                    PromptSplitNodeView(store: store, session: session, tree: first)
                    PromptSplitNodeView(store: store, session: session, tree: second)
                }
            }
        }
    }
}

extension PromptSessionConfiguration {
    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    var sidebarMachine: String {
        switch self { case .local: "Local"; case .remote(let remote): remote.destination }
    }
    var configuredDirectory: String? {
        switch self { case .local(let local): local.workingDirectory; case .remote(let remote): remote.workingDirectory }
    }
    var launchCommand: String? {
        if case .local(let local) = self { return local.command }
        return nil
    }
    var sidebarSummary: String {
        switch self {
        case .local(let local): local.command.map { "Local · \($0)" } ?? "Local shell"
        case .remote(let remote): "SSH · \(remote.destination) · persistent"
        }
    }
}
