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

@MainActor
final class PromptPaneHitRegionRegistry: ObservableObject {
    private final class WeakRegion {
        weak var view: NSView?

        init(_ view: NSView) {
            self.view = view
        }
    }

    private var regions: [PromptPane.ID: WeakRegion] = [:]
    @Published private(set) var frames: [PromptPane.ID: CGRect] = [:]

    func register(_ view: NSView, for paneID: PromptPane.ID) {
        regions[paneID] = WeakRegion(view)
        updateFrame(of: view, for: paneID)
    }

    func unregister(_ view: NSView, for paneID: PromptPane.ID) {
        guard regions[paneID]?.view === view else { return }
        regions.removeValue(forKey: paneID)
        frames.removeValue(forKey: paneID)
    }

    func updateFrame(of view: NSView, for paneID: PromptPane.ID) {
        guard view.window != nil else { return }
        let frame = view.convert(view.bounds, to: nil)
        guard frames[paneID] != frame else { return }
        frames[paneID] = frame
    }

    func paneID(at event: NSEvent) -> PromptPane.ID? {
        guard let eventWindow = event.window else { return nil }
        regions = regions.filter { $0.value.view != nil }
        return regions.first { _, region in
            guard let view = region.view,
                  !view.isHidden,
                  view.window === eventWindow else { return false }
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }?.key
    }
}

private final class PromptPaneHitRegionView: NSView {
    let paneID: PromptPane.ID
    weak var registry: PromptPaneHitRegionRegistry?

    init(paneID: PromptPane.ID, registry: PromptPaneHitRegionRegistry) {
        self.paneID = paneID
        self.registry = registry
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            registry?.register(self, for: paneID)
        } else {
            registry?.unregister(self, for: paneID)
        }
    }

    override func layout() {
        super.layout()
        registry?.updateFrame(of: self, for: paneID)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct PromptPaneHitRegion: NSViewRepresentable {
    let paneID: PromptPane.ID
    let registry: PromptPaneHitRegionRegistry

    func makeNSView(context: Context) -> PromptPaneHitRegionView {
        PromptPaneHitRegionView(paneID: paneID, registry: registry)
    }

    func updateNSView(_ view: PromptPaneHitRegionView, context: Context) {}

    static func dismantleNSView(_ view: PromptPaneHitRegionView, coordinator: ()) {
        view.registry?.unregister(view, for: view.paneID)
    }
}

@MainActor
private final class PromptWindow: NSWindow {
    weak var workspaceStore: PromptWorkspaceStore?

    @discardableResult
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        guard accepted,
              let workspaceStore,
              let surface = PromptTerminalSurface.find(containing: responder as? NSView),
              let paneID = workspaceStore.runtime.paneID(forSurfaceID: surface.id),
              let session = workspaceStore.workspace.sessions.first(where: {
                  $0.splitTree.panes.contains(where: { $0.id == paneID })
              }) else { return accepted }
        // Ghostty calls this while its local mouse monitor is transferring
        // first-responder status. Defer publishing SwiftUI state until AppKit
        // has finished that responder transition.
        DispatchQueue.main.async { [weak workspaceStore] in
            workspaceStore?.focusFromSurface(sessionID: session.id, paneID: paneID)
        }
        return accepted
    }

    override func sendEvent(_ event: NSEvent) {
        guard [.keyDown, .keyUp, .flagsChanged].contains(event.type),
              let workspaceStore else {
            super.sendEvent(event)
            return
        }

        switch workspaceStore.inputRouter.route(
            event,
            editableControlIsFocused: editableControlIsFocused) {
        case .consume:
            return
        case .focusedControl:
            guard focusOwnedInputIfNeeded() else { return }
        case .activeSession:
            guard let session = workspaceStore.workspace.sessions.first(where: {
                $0.id == workspaceStore.workspace.focusedSessionID
            }), let surface = workspaceStore.runtime.surface(for: session.focusedPaneID) else { return }
            surface.focus()
        }

        super.sendEvent(event)
    }

    private var editableControlIsFocused: Bool {
        if let textView = firstResponder as? NSTextView { return textView.isEditable }
        if let textField = firstResponder as? NSTextField {
            return textField.isEditable && textField.isEnabled
        }
        return false
    }

    @discardableResult
    private func focusOwnedInputIfNeeded() -> Bool {
        guard let field = firstVisibleEditableTextField(in: contentView) else { return false }
        if firstResponder !== field, firstResponder !== field.currentEditor() {
            makeFirstResponder(field)
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
            }
        }
        return true
    }

    private func firstVisibleEditableTextField(in view: NSView?) -> NSTextField? {
        guard let view, !view.isHidden else { return nil }
        // SwiftUI appends overlays after the content they cover. Walk the
        // hierarchy front-to-back so an action menu's search field wins over
        // the still-visible palette search field behind it.
        for subview in view.subviews.reversed() {
            if let field = firstVisibleEditableTextField(in: subview) { return field }
        }
        if let field = view as? NSTextField, field.isEditable, field.isEnabled {
            return field
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
    }

    private var focusedSurface: PromptTerminalSurface? {
        guard let session = store.workspace.sessions.first(where: { $0.id == store.workspace.focusedSessionID }) else { return nil }
        return store.runtime.surface(for: session.focusedPaneID)
    }
}

private struct PromptSessionSidebar: View {
    @ObservedObject var store: PromptWorkspaceStore
    @ObservedObject private var inputRouter: PromptInputRouter
    @State private var collapsedGroups: Set<String> = []
    @State private var hoveredGroup: String?

    init(store: PromptWorkspaceStore) {
        self.store = store
        inputRouter = store.inputRouter
    }

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
                            sessionRow(session, shortcut: inputRouter.isCommandKeyPressed && index < 9 ? index + 1 : nil, grouped: false)
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
                                            sessionRow(session, shortcut: inputRouter.isCommandKeyPressed ? index.flatMap { $0 < 9 ? $0 + 1 : nil } : nil, grouped: true)
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
    @ObservedObject private var paneHitRegions: PromptPaneHitRegionRegistry
    @ObservedObject private var promptModel = AIModel.shared
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
        self.paneHitRegions = store.runtime.paneHitRegions
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
        let prefix = session.configuration.localTypeLabel.map { "\($0)  ·  " } ?? ""
        if let identity = session.configuration.containerIdentity {
            return "\(prefix)\(identity)  ·  \(path)"
        }
        if let repository = session.configuration.worktreeRepository {
            let repo = URL(fileURLWithPath: repository).lastPathComponent
            let branch = session.configuration.worktreeBranch ?? runtime.localGitBranches[session.focusedPaneID]
            return "\(prefix)\(repo)" + (branch.map { "  ·  git:\($0)" } ?? "")
        }
        if let branch = remoteStatus?.gitBranch ?? runtime.localGitBranches[session.focusedPaneID] {
            return "\(prefix)\(path)  ·  git:\(branch)"
        }
        return prefix + path
    }

    private enum AgentKind {
        case codex, claude

        var label: String { self == .codex ? "Codex" : "Claude" }
        var icon: String { self == .codex ? "sparkles" : "wand.and.stars" }
        var tint: Color { self == .codex ? PromptTheme.accent : Color(red: 0.83, green: 0.53, blue: 0.31) }
    }

    private var agentActivity: AIModel.SidebarAgentActivity? {
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

            HStack(alignment: .center, spacing: 7) {
                if session.splitTree.paneCount > 1 {
                    PromptSidebarLayoutIndicator(
                        tree: session.splitTree,
                        focusedPaneID: session.focusedPaneID,
                        paneFrames: paneHitRegions.frames)
                        .frame(width: 20, height: 14)
                        .help("Current pane layout")
                }

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
            .padding(.top, 7)
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
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: remoteConnectionState?.isOffline == true
                ? "wifi.exclamationmark"
                : session.configuration.sidebarIcon)
                .font(.system(size: 14))
                .foregroundStyle(session.configuration.isPrivileged ? Color.orange : (remoteConnectionState?.isOffline == true ? Color.red : Color.secondary))
                .frame(width: 18, height: 18, alignment: .center)
                .help(session.configuration.sidebarSummary)
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
        HStack(alignment: .center, spacing: 10) {
            CodexMark()
                .frame(width: 18, height: 18)
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
        let layoutInset: CGFloat = session.splitTree.paneCount > 1 ? 32 : 0
        switch (pullRequest != nil, shortcut != nil) {
        case (true, true): return layoutInset + 50
        case (true, false): return layoutInset + 24
        case (false, true): return layoutInset + 24
        case (false, false): return layoutInset
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
        Text(metadata)
            .font(.system(size: 10, design: .monospaced))
            .lineLimit(1)
            .foregroundStyle(.tertiary)
    }

    private func abbreviated(_ path: String) -> String {
        path.promptDisplayPath
    }
}

private struct PromptSidebarLayoutIndicator: View {
    let tree: PromptSplitTree
    let focusedPaneID: PromptPane.ID
    let paneFrames: [PromptPane.ID: CGRect]

    private let gap: CGFloat = 2.5
    private let cornerRadius: CGFloat = 1
    private let minimumChipExtent: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let panes = livePaneRects(in: bounds) ?? paneRects(tree, in: bounds)

            for pane in panes {
                let isFocused = pane.id == focusedPaneID
                let chip = readableChip(for: pane.rect, in: bounds)
                let path = Path(roundedRect: chip, cornerRadius: cornerRadius)

                context.fill(
                    path,
                    with: .color(Color.white.opacity(isFocused ? 0.62 : 0.12)))
                context.stroke(
                    path,
                    with: .color(Color.white.opacity(isFocused ? 0.85 : 0.22)),
                    lineWidth: isFocused ? 0.75 : 0.5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(
            "Pane layout, \(tree.paneCount) panes, focused pane \(focusedPaneNumber)")
    }

    private var focusedPaneNumber: Int {
        (tree.panes.firstIndex(where: { $0.id == focusedPaneID }) ?? 0) + 1
    }

    private func readableChip(for paneRect: CGRect, in bounds: CGRect) -> CGRect {
        let available = bounds.insetBy(dx: gap / 2, dy: gap / 2)
        let width = min(max(paneRect.width - gap, minimumChipExtent), available.width)
        let height = min(max(paneRect.height - gap, minimumChipExtent), available.height)
        let x = min(
            max(paneRect.midX - width / 2, available.minX),
            available.maxX - width)
        let y = min(
            max(paneRect.midY - height / 2, available.minY),
            available.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func livePaneRects(
        in bounds: CGRect
    ) -> [(id: PromptPane.ID, rect: CGRect)]? {
        let panes = tree.panes
        let live = panes.compactMap { pane -> (PromptPane.ID, CGRect)? in
            guard let frame = paneFrames[pane.id],
                  frame.width > 0,
                  frame.height > 0 else { return nil }
            return (pane.id, frame)
        }
        guard live.count == panes.count,
              var union = live.first?.1 else { return nil }
        for (_, frame) in live.dropFirst() {
            union = union.union(frame)
        }
        guard union.width > 0, union.height > 0 else { return nil }

        return live.map { id, frame in
            let x = bounds.minX + ((frame.minX - union.minX) / union.width) * bounds.width
            // AppKit window coordinates rise from the bottom; Canvas
            // coordinates rise from the top.
            let y = bounds.minY + ((union.maxY - frame.maxY) / union.height) * bounds.height
            return (
                id,
                CGRect(
                    x: x,
                    y: y,
                    width: (frame.width / union.width) * bounds.width,
                    height: (frame.height / union.height) * bounds.height))
        }
    }

    private func paneRects(
        _ node: PromptSplitTree,
        in rect: CGRect
    ) -> [(id: PromptPane.ID, rect: CGRect)] {
        switch node {
        case .leaf(let pane):
            return [(pane.id, rect)]
        case .split(let axis, let fraction, let first, let second):
            let ratio = min(max(fraction, 0), 1)
            if axis == .horizontal {
                let firstWidth = rect.width * ratio
                let firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: firstWidth,
                    height: rect.height)
                let secondRect = CGRect(
                    x: rect.minX + firstWidth,
                    y: rect.minY,
                    width: rect.width - firstWidth,
                    height: rect.height)
                return paneRects(first, in: firstRect) + paneRects(second, in: secondRect)
            }

            let firstHeight = rect.height * ratio
            let firstRect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: firstHeight)
            let secondRect = CGRect(
                x: rect.minX,
                y: rect.minY + firstHeight,
                width: rect.width,
                height: rect.height - firstHeight)
            return paneRects(first, in: firstRect) + paneRects(second, in: secondRect)
        }
    }

    private func splitDividers(_ node: PromptSplitTree, in rect: CGRect) -> [Path] {
        guard case .split(let axis, let fraction, let first, let second) = node else {
            return []
        }
        let ratio = min(max(fraction, 0), 1)
        var divider = Path()

        if axis == .horizontal {
            let splitX = rect.minX + rect.width * ratio
            divider.move(to: CGPoint(x: splitX, y: rect.minY))
            divider.addLine(to: CGPoint(x: splitX, y: rect.maxY))
            let firstRect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: splitX - rect.minX,
                height: rect.height)
            let secondRect = CGRect(
                x: splitX,
                y: rect.minY,
                width: rect.maxX - splitX,
                height: rect.height)
            return [divider]
                + splitDividers(first, in: firstRect)
                + splitDividers(second, in: secondRect)
        }

        let splitY = rect.minY + rect.height * ratio
        divider.move(to: CGPoint(x: rect.minX, y: splitY))
        divider.addLine(to: CGPoint(x: rect.maxX, y: splitY))
        let firstRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: splitY - rect.minY)
        let secondRect = CGRect(
            x: rect.minX,
            y: splitY,
            width: rect.width,
            height: rect.maxY - splitY)
        return [divider]
            + splitDividers(first, in: firstRect)
            + splitDividers(second, in: secondRect)
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
            if let url = Bundle.main.url(forResource: "OpenAIBlossom", withExtension: "svg", subdirectory: "Fonts"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().renderingMode(.original).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "circle.hexagongrid.fill").resizable().aspectRatio(contentMode: .fit)
            }
        }
        .accessibilityLabel("Codex")
    }
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
                GeometryReader { geometry in
                    PromptHostedTerminalView(
                        surface: surface,
                        paneID: pane.id,
                        runtime: store.runtime)
                        .id(pane.id)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .modifier(PromptPaneDropTarget(
                            store: store,
                            sessionID: session.id,
                            targetPaneID: pane.id))
                        .contentShape(Rectangle())
                        .background(PromptPaneHitRegion(
                            paneID: pane.id,
                            registry: store.runtime.paneHitRegions))
                        .clipped()
                }
            }
        case .split(let axis, let fraction, let first, let second):
            if axis == .horizontal {
                HSplitView {
                    PromptSplitNodeView(store: store, session: session, tree: first)
                        .frame(
                            minWidth: 80,
                            idealWidth: max(80, CGFloat(fraction) * 1_000),
                            maxWidth: .infinity,
                            maxHeight: .infinity)
                    PromptSplitNodeView(store: store, session: session, tree: second)
                        .frame(
                            minWidth: 80,
                            idealWidth: max(80, CGFloat(1 - fraction) * 1_000),
                            maxWidth: .infinity,
                            maxHeight: .infinity)
                }
            } else {
                VSplitView {
                    PromptSplitNodeView(store: store, session: session, tree: first)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 80,
                            idealHeight: max(80, CGFloat(fraction) * 1_000),
                            maxHeight: .infinity)
                    PromptSplitNodeView(store: store, session: session, tree: second)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 80,
                            idealHeight: max(80, CGFloat(1 - fraction) * 1_000),
                            maxHeight: .infinity)
                }
            }
        }
    }
}

private struct PromptPaneDropTarget: ViewModifier {
    let store: PromptWorkspaceStore
    let sessionID: PromptSession.ID
    let targetPaneID: PromptPane.ID
    @State private var dropState = PromptPaneDropState.idle

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [.ghosttySurfaceId],
                            delegate: PromptPaneDropDelegate(
                                dropState: $dropState,
                                viewSize: geometry.size,
                                store: store,
                                sessionID: sessionID,
                                targetPaneID: targetPaneID))
                }
            }
            .overlay {
                if case .dropping(let zone) = dropState {
                    PromptPaneDropPreview(zone: zone)
                        .padding(5)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
    }
}

private enum PromptPaneDropState: Equatable {
    case idle
    case dropping(PromptPaneDropZone)
}

private struct PromptPaneDropDelegate: DropDelegate {
    @Binding var dropState: PromptPaneDropState
    let viewSize: CGSize
    let store: PromptWorkspaceStore
    let sessionID: PromptSession.ID
    let targetPaneID: PromptPane.ID

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.ghosttySurfaceId])
    }

    func dropEntered(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.1)) {
            dropState = .dropping(Self.zone(at: info.location, in: viewSize))
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard case .dropping = dropState else {
            return DropProposal(operation: .forbidden)
        }
        dropState = .dropping(Self.zone(at: info.location, in: viewSize))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.1)) { dropState = .idle }
    }

    func performDrop(info: DropInfo) -> Bool {
        let dropZone = Self.zone(at: info.location, in: viewSize)
        dropState = .idle
        guard let provider = info.itemProviders(for: [.ghosttySurfaceId]).first else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.ghosttySurfaceId.identifier) { data, _ in
            guard let data, data.count == MemoryLayout<uuid_t>.size else { return }
            var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            _ = withUnsafeMutableBytes(of: &bytes) { data.copyBytes(to: $0) }
            let surfaceID = UUID(uuid: bytes)
            DispatchQueue.main.async {
                _ = store.movePane(
                    in: sessionID,
                    sourceSurfaceID: surfaceID,
                    relativeTo: targetPaneID,
                    zone: dropZone)
            }
        }
        return true
    }

    static func zone(at point: CGPoint, in size: CGSize) -> PromptPaneDropZone {
        guard size.width > 0, size.height > 0 else { return .right }
        let relativeX = point.x / size.width
        let relativeY = point.y / size.height
        if (0.25 ... 0.75).contains(relativeX), (0.25 ... 0.75).contains(relativeY) {
            return .center
        }
        let distances: [(PromptPaneDropZone, CGFloat)] = [
            (.left, point.x),
            (.right, size.width - point.x),
            (.top, point.y),
            (.bottom, size.height - point.y),
        ]
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .right
    }
}

private struct PromptPaneDropPreview: View {
    let zone: PromptPaneDropZone

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(red: 0.02, green: 0.48, blue: 0.95).opacity(0.28))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color(red: 0.05, green: 0.58, blue: 1), lineWidth: 2)
                }
                .frame(
                    width: zone == .left || zone == .right ? size.width / 2 : size.width,
                    height: zone == .top || zone == .bottom ? size.height / 2 : size.height)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: alignment)
        }
    }

    private var alignment: Alignment {
        switch zone {
        case .center: .center
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}

extension PromptSessionConfiguration {
    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    var isAnchored: Bool {
        guard case .local(let local) = self else { return false }
        return local.behavior == .anchored
    }

    var isPrivileged: Bool {
        guard case .local(let local) = self else { return false }
        return local.behavior == .privileged
    }

    var localTypeLabel: String? {
        guard case .local(let local) = self else { return nil }
        switch local.behavior {
        case .standard: return nil
        case .anchored: return "Anchored"
        case .task:
            if let code = local.lastExitCode { return code == 0 ? "Completed" : "Failed \(code)" }
            return "Task"
        case .disposable: return "Disposable"
        case .scratch: return "Scratch"
        case .project: return "Project"
        case .worktree: return "Worktree"
        case .container: return "Container"
        case .privileged: return "PRIVILEGED"
        }
    }

    var sidebarIcon: String {
        switch self {
        case .remote: return "network"
        case .local(let local):
            switch local.behavior {
            case .standard: return "terminal"
            case .anchored: return "pin"
            case .task: return local.lastExitCode.map { $0 == 0 ? "checkmark.circle" : "xmark.circle" } ?? "play.circle"
            case .disposable: return "timer"
            case .scratch: return "square.dashed"
            case .project: return "folder"
            case .worktree: return "arrow.triangle.branch"
            case .container: return "shippingbox"
            case .privileged: return "lock.shield"
            }
        }
    }

    var containerIdentity: String? {
        guard case .local(let local) = self else { return nil }
        return local.details?.composeService.map { "compose:\($0)" } ?? local.details?.container
    }

    var worktreeRepository: String? {
        guard case .local(let local) = self else { return nil }
        return local.details?.repository
    }

    var worktreeBranch: String? {
        guard case .local(let local) = self else { return nil }
        return local.details?.branch
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
        case .local(let local):
            let type = localTypeLabel ?? "Local"
            return local.command.map { "\(type) · \($0)" } ?? "\(type) shell"
        case .remote(let remote): return "SSH · \(remote.destination) · persistent"
        }
    }
}
