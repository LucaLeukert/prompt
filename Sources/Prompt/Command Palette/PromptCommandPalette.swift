import AppKit
import Logging
import SwiftUI

/// The root command palette and its declaratively composed destinations.
struct PromptCommandPaletteView: View {
    @ObservedObject var store: PromptWorkspaceStore
    let surface: PromptTerminalSurface?
    @Binding var isPresented: Bool

    var body: some View {
        if isPresented {
            GeometryReader { geometry in
                VStack {
                    Spacer().frame(height: geometry.size.height * 0.05)
                    PromptPaletteHost {
                        PromptPalettePage(
                            store: store,
                            isPresented: $isPresented,
                            title: nil,
                            content: rootCommands)
                    }
                    .frame(maxWidth: 720)
                    .promptLiquidGlassSurface(
                        tint: PromptTheme.elevated.opacity(0.12),
                        cornerRadius: 28)
                    .padding()
                    Spacer()
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .onDisappear { surface?.focus() }
        }
    }

    @ViewBuilder
    private func rootCommands() -> some View {
        let directory = surface?.workingDirectory ?? NSHomeDirectory()
        let containerCatalog = PromptSessionLauncher.containerCatalog(directory: directory)

        PromptPaletteSection("Create session") {
            PromptPaletteCommand("Current directory") {
                store.createLocal(directory: directory)
            }
            .subtitle(directory.promptDisplayPath)
            .help("Open here, or press Command-K for another local session type")
            .shortcut("⌘", "T")
            .icon("terminal")
            .primaryAction("Open shell in current directory")
            .actions {
                PromptSessionLauncher.currentDirectoryActions(store: store, directory: directory)
            }

            PromptPaletteCommand("Open folder…")
                .subtitle("Choose a folder on this Mac")
                .help("Browse folders without leaving the palette")
                .icon("folder.badge.plus")
                .destination(title: "Browse local folders") {
                    PromptFolderPickerDestination(
                        configuration: PromptSessionLauncher.localFolderPicker(store: store, at: directory),
                        isPresented: $isPresented,
                        keyboard: store.inputRouter)
                }
                .primaryAction("Browse local folders")

            PromptPaletteCommand("Git open…")
                .subtitle("Repositories and registered worktrees")
                .help("Browse Git locations, or press Command-K to create a worktree")
                .icon("arrow.triangle.branch")
                .destination(title: "Browse Git repositories") {
                    PromptGitPickerDestination(
                        configuration: PromptSessionLauncher.gitPicker(store: store, at: directory),
                        isPresented: $isPresented,
                        keyboard: store.inputRouter)
                }
                .actions {
                    PromptSessionLauncher.gitActions(store: store, directory: directory)
                }

            PromptPaletteCommand("Container…")
                .subtitle(
                    containerCatalog.error == nil
                        ? "Docker containers and Compose services"
                        : "Docker is unavailable")
                .help(
                    containerCatalog.error == nil
                        ? "Open an interactive shell in a container"
                        : "Start Docker or Colima to enable container sessions")
                .icon("shippingbox")
                .destination(title: "Choose a container") {
                    PromptPalettePage(
                        store: store,
                        isPresented: $isPresented,
                        title: "Container",
                        content: {
                            PromptContainerCommands(
                                store: store,
                                directory: directory,
                                catalog: containerCatalog)
                        })
                }
                .enabled(containerCatalog.error == nil)

            PromptPaletteCommand("Remote session…")
                .subtitle("SSH config and Tailscale")
                .help("Discover SSH hosts, pick a folder, and open a reconnectable session")
                .icon("network")
                .destination(title: "Choose a remote host") {
                    PromptPalettePage(
                        store: store,
                        isPresented: $isPresented,
                        title: "Remote session",
                        content: {
                            PromptRemoteCommands(
                                store: store,
                                isPresented: $isPresented)
                        })
                }
        }

        PromptPaletteSection("Actions") {
            PromptPaletteCommand("Split right") {
                store.splitFocused(axis: .horizontal)
            }
            .help("Split the focused session horizontally")
            .shortcut("⌘", "D")
            .icon("rectangle.split.2x1")
            .primaryAction("Split focused session right")

            PromptPaletteCommand("Split down") {
                store.splitFocused(axis: .vertical)
            }
            .help("Split the focused session vertically")
            .shortcut("⇧", "⌘", "D")
            .icon("rectangle.split.1x2")
            .primaryAction("Split focused session down")

            PromptPaletteCommand("Close pane") {
                store.closeFocusedPane()
            }
            .help("Close the focused pane")
            .shortcut("⌘", "W")
            .icon("xmark.rectangle")
            .primaryAction("Close focused pane")
        }

        PromptPaletteSection("Sidebar") {
            PromptPaletteCommand("Edit sidebar")
                .subtitle("Arrange groups and sessions visually")
                .help("Drag, rename, group, and manage the sidebar")
                .icon("rectangle.3.group")
                .destination(title: "Edit sidebar") {
                    PromptSidebarEditorDestination(
                        store: store,
                        keyboard: store.inputRouter)
                }

            PromptPaletteCommand("Sidebar layout…")
                .subtitle(store.sidebarLayout == .flat ? "Flat" : "Grouped")
                .help("Choose how sessions are organized")
                .icon("sidebar.left")
                .destination(title: "Choose sidebar layout") {
                    PromptPalettePage(
                        store: store,
                        isPresented: $isPresented,
                        title: "Sidebar layout",
                        content: {
                            PromptPaletteSection("Layout") {
                                PromptPaletteCommand("Flat") {
                                    store.sidebarLayout = .flat
                                }
                                .help("Show one continuous session list")
                                .icon("list.bullet")
                                .primaryAction("Use flat sidebar layout")

                                PromptPaletteCommand("Grouped") {
                                    store.sidebarLayout = .grouped
                                }
                                .help("Nest sessions by machine or custom folder")
                                .icon("list.bullet.indent")
                                .primaryAction("Use grouped sidebar layout")
                            }
                        })
                }

            PromptPaletteCommand("Sort sessions…")
                .subtitle(store.sidebarSort.label)
                .help("Change sidebar ordering")
                .icon("arrow.up.arrow.down")
                .destination(title: "Choose session sort order") {
                    PromptPalettePage(
                        store: store,
                        isPresented: $isPresented,
                        title: "Sort sessions",
                        content: {
                            PromptPaletteSection("Sort sessions") {
                                ForEach(PromptWorkspaceStore.SidebarSort.allCases, id: \.self) { sort in
                                    PromptPaletteCommand(sort.label) {
                                        store.sidebarSort = sort
                                    }
                                    .help(sort.detail)
                                    .icon(store.sidebarSort == sort ? "checkmark" : "circle")
                                    .primaryAction("Sort sessions by \(sort.label.lowercased())")
                                }
                            }
                        })
                }

            PromptPaletteCommand("New sidebar folder…") {
                let alert = NSAlert()
                alert.messageText = "New sidebar folder"
                alert.informativeText = "Choose a name for the session group."
                let field = NSTextField(string: "")
                field.placeholderString = "Folder name"
                field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
                alert.accessoryView = field
                alert.addButton(withTitle: "Create")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { store.createSidebarFolder(named: field.stringValue) }
            }
            .help("Create a custom session group")
            .icon("folder.badge.plus")
            .primaryAction("Create sidebar folder")

            PromptPaletteCommand("Move session to folder…")
                .subtitle(store.sidebarFolders.isEmpty ? "Create a folder first" : nil)
                .help("Move the focused session into a custom group")
                .icon("folder")
                .destination(title: "Choose destination folder") {
                    PromptPalettePage(
                        store: store,
                        isPresented: $isPresented,
                        title: "Move session to folder",
                        content: {
                            PromptPaletteSection("Folders") {
                                PromptPaletteCommand("Automatic (by machine)") {
                                    store.assignFocusedSession(to: nil)
                                }
                                .icon("desktopcomputer")
                                .primaryAction("Group focused session automatically")

                                ForEach(store.sidebarFolders, id: \.self) { folder in
                                    PromptPaletteCommand(folder) {
                                        store.assignFocusedSession(to: folder)
                                    }
                                    .icon("folder")
                                    .primaryAction("Move focused session to \(folder)")
                                }
                            }
                        })
                }
        }

        PromptPaletteSection("Open sessions") {
            ForEach(store.workspace.sessions) { session in
                ForEach(session.splitTree.panes) { pane in
                    PromptPaletteCommand(pane.title.isEmpty ? session.title : pane.title) {
                        store.focus(sessionID: session.id, paneID: pane.id)
                    }
                    .subtitle(store.runtime.surface(for: pane.id)?.workingDirectory?.promptDisplayPath)
                    .help("Focus this terminal")
                    .icon("rectangle.on.rectangle")
                    .primaryAction("Focus \(pane.title.isEmpty ? session.title : pane.title)")
                }
            }
        }

        PromptPaletteSection("Recent remote sessions") {
            ForEach(PromptSessionLauncher.savedRemoteSessions, id: \.self) { remote in
                PromptPaletteCommand(remote.name) {
                    PromptSessionLauncher.open(remote, store: store)
                }
                .subtitle(remote.directory?.promptDisplayPath ?? "Persistent session")
                .help("Attach to persistent session \(remote.session)")
                .icon("arrow.clockwise.circle")
                .primaryAction("Reconnect to \(remote.name)")
            }
        }
    }
}

private struct PromptContainerCommands: View {
    let store: PromptWorkspaceStore
    let directory: String
    private let catalog: PromptSessionLauncher.ContainerCatalog

    init(
        store: PromptWorkspaceStore,
        directory: String,
        catalog: PromptSessionLauncher.ContainerCatalog? = nil
    ) {
        self.store = store
        self.directory = directory
        self.catalog = catalog ?? PromptSessionLauncher.containerCatalog(directory: directory)
    }

    @ViewBuilder
    var body: some View {
        if let error = catalog.error {
            PromptPaletteSection("Container") {
                PromptPaletteCommand("Docker unavailable") {
                    PromptSessionLauncher.show(error)
                }
                .subtitle(error.localizedDescription)
                .help("Install or start Docker and try again")
                .icon("exclamationmark.triangle")
                .primaryAction("Show Docker error")
            }
        } else {
            if !catalog.containers.isEmpty {
                PromptPaletteSection("Docker containers") {
                    ForEach(catalog.containers, id: \.id) { container in
                        PromptPaletteCommand(container.name) {
                            PromptSessionLauncher.open(
                                container: container,
                                store: store,
                                directory: directory)
                        }
                        .subtitle("\(container.state) · \(container.id)")
                        .help(
                            container.state == "running"
                                ? "Open /bin/sh in this container"
                                : "Start this container before opening a shell")
                        .icon(container.state == "running" ? "shippingbox" : "pause.circle")
                        .primaryAction("Open \(container.name)")
                        .enabled(container.state == "running")
                    }
                }
            }

            if !catalog.composeServices.isEmpty {
                PromptPaletteSection("Docker Compose services") {
                    ForEach(catalog.composeServices, id: \.self) { service in
                        PromptPaletteCommand(service) {
                            PromptSessionLauncher.open(
                                composeService: service,
                                store: store,
                                directory: directory)
                        }
                        .subtitle(directory.promptDisplayPath)
                        .help("Open /bin/sh in the running Compose service")
                        .icon("square.3.layers.3d")
                        .primaryAction("Open Compose service \(service)")
                    }
                }
            }
        }
    }
}

private struct PromptRemoteCommands: View {
    let store: PromptWorkspaceStore
    @Binding var isPresented: Bool
    private let hosts: [PromptSessionLauncher.RemoteHost]

    init(store: PromptWorkspaceStore, isPresented: Binding<Bool>) {
        self.store = store
        _isPresented = isPresented
        hosts = PromptSessionLauncher.remoteHosts()
    }

    @ViewBuilder
    var body: some View {
        let configured = hosts.filter { !$0.isTailnet }
        let tailnet = hosts.filter(\.isTailnet)

        if !configured.isEmpty {
            PromptPaletteSection("SSH hosts") {
                ForEach(configured) { host in
                    hostCommand(host)
                }
            }
        }

        if !tailnet.isEmpty {
            PromptPaletteSection("Tailnet SSH hosts") {
                ForEach(tailnet) { host in
                    hostCommand(host)
                }
            }
        }

        if !configured.isEmpty {
            PromptPaletteSection("SSH compatibility") {
                ForEach(configured) { host in
                    compatibilityCommand(host)
                }
            }
        }

        if !tailnet.isEmpty {
            PromptPaletteSection("Tailnet SSH compatibility") {
                ForEach(tailnet) { host in
                    compatibilityCommand(host)
                }
            }
        }
    }

    private func hostCommand(_ host: PromptSessionLauncher.RemoteHost) -> some View {
        PromptPaletteCommand(host.title)
            .subtitle(
                host.isTailnet
                    ? "Discovered through Tailscale · \(host.destination)"
                    : "Native panes and inline AI")
            .help("Open a controlled tmux session on \(host.destination)")
            .icon(host.isTailnet ? "point.3.connected.trianglepath.dotted" : "network")
            .destination(title: "Choose folder on \(host.title)") {
                PromptFolderPickerDestination(
                    configuration: PromptSessionLauncher.remoteFolderPicker(
                        store: store,
                        host: host.destination,
                        transport: .controlMode),
                    isPresented: $isPresented,
                    keyboard: store.inputRouter)
            }
    }

    private func compatibilityCommand(_ host: PromptSessionLauncher.RemoteHost) -> some View {
        PromptPaletteCommand("\(host.title) · Legacy TTY")
            .subtitle("Standard attached tmux client")
            .help("Use when tmux control mode is unavailable")
            .icon("network.slash")
            .destination(title: "Choose legacy TTY folder on \(host.title)") {
                PromptFolderPickerDestination(
                    configuration: PromptSessionLauncher.remoteFolderPicker(
                        store: store,
                        host: host.destination,
                        transport: .legacyTTY),
                    isPresented: $isPresented,
                    keyboard: store.inputRouter)
            }
    }
}

extension PromptWorkspaceStore.SidebarSort {
    var label: String { switch self { case .manual: "Manual"; case .recent: "Recently used"; case .name: "Name" } }
    var detail: String { switch self { case .manual: "Keep creation order"; case .recent: "Put recently focused sessions first"; case .name: "Sort alphabetically" } }
}

struct PromptRemoteSession: Codable, Hashable {
    let destination: String
    let name: String
    let session: String
    var directory: String? = nil
}

@MainActor enum PromptSessionLauncher {
    enum CurrentDirectoryAction: String, CaseIterable {
        case anchored
        case task
        case disposable
        case scratch
        case privileged
        case codex

        var title: String {
            switch self {
            case .anchored: "Anchored session"
            case .task: "Run task…"
            case .disposable: "Disposable session…"
            case .scratch: "Scratch workspace"
            case .privileged: "Privileged session…"
            case .codex: "Codex agent"
            }
        }

        var icon: String {
            switch self {
            case .anchored: "pin"
            case .task: "play.circle"
            case .disposable: "timer"
            case .scratch: "square.dashed"
            case .privileged: "lock.shield"
            case .codex: "sparkles"
            }
        }
    }

    private static var logger: Logger { PromptLog.tailnet }
    private static let savedKey = "PromptPersistentRemoteSessions"
    private static let tailnetSavedKey = "PromptDiscoveredTailnetHosts"
    private static let gitLocationsCacheFileName = "git-locations.json"
    private static let gitLocationsCacheLimit = 40
    private static var tailnetCache: (date: Date, hosts: [String])?
    private static var remoteDirectoryCache: [String: [PromptFolderPickerEntry]] = [:]
    private static var remoteDirectoryPrefetches: Set<String> = []

    static func currentDirectoryActions(store: PromptWorkspaceStore, directory: String) -> [PromptCommandAction] {
        CurrentDirectoryAction.allCases.map { variant in
            PromptCommandAction(title: variant.title, icon: variant.icon, shortcut: []) {
                store.isCommandPalettePresented = false
                switch variant {
                case .anchored:
                    store.createLocal(directory: directory, behavior: .anchored)
                case .task:
                    guard let command = requestCommand(title: "Task command") else { return }
                    store.createLocal(directory: directory, command: command, title: "Task", behavior: .task)
                case .disposable:
                    guard let command = requestCommand(title: "Disposable command", allowsEmpty: true) else { return }
                    store.createLocal(
                        directory: directory,
                        command: command.isEmpty ? nil : command,
                        title: "Disposable",
                        behavior: .disposable)
                case .scratch:
                    createScratch(store: store)
                case .privileged:
                    createPrivileged(store: store, directory: directory)
                case .codex:
                    store.createLocal(directory: directory, command: PromptAgentCommand.codex, title: "Codex")
                }
            }
        }
    }

    static func gitActions(store: PromptWorkspaceStore, directory: String) -> [PromptCommandAction] {
        [
            PromptCommandAction(title: "Create worktree…", icon: "plus", shortcut: []) {
                store.isCommandPalettePresented = false
                createWorktree(store: store, directory: directory)
            },
        ]
    }

    static func requestCommand(title: String, allowsEmpty: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = allowsEmpty ? "Leave empty to open your login shell." : "Enter the command to run."
        let field = NSTextField(string: "")
        field.placeholderString = allowsEmpty ? "Optional command" : "Command"
        field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return allowsEmpty || !value.isEmpty ? value : nil
    }

    static func createScratch(store: PromptWorkspaceStore) {
        do {
            let directory = try PromptLocalSessionLauncher.createScratchDirectory()
            let details = PromptLocalSessionDetails(scratchDirectory: directory)
            if store.createLocal(directory: directory, title: "Scratch", behavior: .scratch, details: details) == nil {
                try? PromptLocalSessionLauncher.cleanupScratchDirectory(directory)
            }
        } catch { show(error) }
    }

    static func createProject(store: PromptWorkspaceStore, directory: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            show(PromptLocalSessionLauncher.LaunchError.missingDirectory(directory))
            return
        }
        let root = PromptLocalSessionLauncher.projectRoot(containing: directory)
        store.createLocal(directory: root, title: URL(fileURLWithPath: root).lastPathComponent, behavior: .project)
    }

    static func gitPicker(store: PromptWorkspaceStore, at path: String) -> PromptGitPickerConfiguration {
        let current = URL(fileURLWithPath: path).standardizedFileURL.path
        let searchDirectory = PromptLocalSessionLauncher.gitRoot(containing: current)
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? NSHomeDirectory()
        let cached = cachedGitLocations()
        let seeds = Array(Set(
            store.workspace.sessions.compactMap(\.configuration.configuredDirectory)
                + [current]))
        return PromptGitPickerConfiguration(
            cachedLocations: gitPickerEntries(cached),
            locations: {
                let locations = await Task.detached {
                    PromptLocalSessionLauncher.gitLocations(
                        searching: searchDirectory,
                        seeds: seeds,
                        cached: cached)
                }.value
                rememberGitLocations(locations)
                return gitPickerEntries(locations)
            },
            onSelect: { openGitLocation($0, store: store) },
            emptyText: "No Git repositories found")
    }

    private static func gitPickerEntries(
        _ locations: [PromptLocalSessionLauncher.GitLocation]
    ) -> [PromptGitPickerEntry] {
        locations.map { location in
            PromptGitPickerEntry(
                name: location.isMainWorktree
                    ? URL(fileURLWithPath: location.repository).lastPathComponent
                    : URL(fileURLWithPath: location.path).lastPathComponent,
                path: location.path,
                repository: location.repository,
                branch: location.branch,
                isMainWorktree: location.isMainWorktree)
        }
    }

    static func openGitLocation(_ path: String, store: PromptWorkspaceStore) {
        let requested = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        guard let root = PromptLocalSessionLauncher.gitRoot(containing: requested),
              let worktrees = try? PromptLocalSessionLauncher.worktrees(containing: root),
              let selected = worktrees.first(where: {
                  URL(fileURLWithPath: $0.path).standardizedFileURL.path == requested
              }) else {
            forgetCachedGitLocation(requested)
            show(PromptLocalSessionLauncher.LaunchError.failed("The selected directory is not an available Git repository or worktree."))
            return
        }
        let details = PromptLocalSessionDetails(
            repository: selected.repository,
            branch: selected.branch,
            worktreePath: selected.path,
            worktreeOwnership: .external)
        _ = store.createLocal(
            directory: selected.path,
            title: selected.isMain
                ? URL(fileURLWithPath: selected.repository).lastPathComponent
                : selected.branch ?? URL(fileURLWithPath: selected.path).lastPathComponent,
            behavior: selected.isMain ? .project : .worktree,
            details: details)
    }

    static func cachedGitLocations(
        paths: PromptPaths = PromptPaths()
    ) -> [PromptLocalSessionLauncher.GitLocation] {
        let cacheFile = paths.cacheFile(gitLocationsCacheFileName)
        if let data = try? Data(contentsOf: cacheFile),
           let locations = try? JSONDecoder().decode(
               [PromptLocalSessionLauncher.GitLocation].self,
               from: data) {
            return Array(locations.prefix(gitLocationsCacheLimit))
        }

        return []
    }

    static func rememberGitLocations(
        _ locations: [PromptLocalSessionLauncher.GitLocation],
        paths: PromptPaths = PromptPaths()
    ) {
        let existing = cachedGitLocations(paths: paths)
        let refreshedPaths = Set(locations.map(\.path))
        let ordered = locations + existing.filter { !refreshedPaths.contains($0.path) }
        let bounded = Array(ordered.prefix(gitLocationsCacheLimit))
        _ = persistGitLocations(bounded, paths: paths)
    }

    static func forgetCachedGitLocation(
        _ path: String,
        paths: PromptPaths = PromptPaths()
    ) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let remaining = cachedGitLocations(paths: paths).filter {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path != normalized
        }
        _ = persistGitLocations(remaining, paths: paths)
    }

    @discardableResult
    private static func persistGitLocations(
        _ locations: [PromptLocalSessionLauncher.GitLocation],
        paths: PromptPaths
    ) -> Bool {
        do {
            try paths.prepare()
            let data = try JSONEncoder().encode(locations)
            try data.write(to: paths.cacheFile(gitLocationsCacheFileName), options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    static func createWorktree(store: PromptWorkspaceStore, directory: String) {
        guard let repository = PromptLocalSessionLauncher.gitRoot(containing: directory) else {
            show(PromptLocalSessionLauncher.LaunchError.failed("Select or open a directory inside a Git repository first."))
            return
        }
        guard let branch = requestCommand(title: "New worktree branch"), !branch.isEmpty else { return }
        let safeName = branch.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
        let path = URL(fileURLWithPath: repository).deletingLastPathComponent()
            .appendingPathComponent(".prompt-worktrees")
            .appendingPathComponent(safeName).path
        do {
            let worktree = try PromptLocalSessionLauncher.createWorktree(
                repository: repository, path: path, branch: branch)
            let details = PromptLocalSessionDetails(
                repository: repository,
                branch: branch,
                worktreePath: worktree.path,
                worktreeOwnership: .prompt)
            store.createLocal(directory: worktree.path, title: branch, behavior: .worktree, details: details)
        } catch { show(error) }
    }

    struct ContainerCatalog {
        let containers: [PromptLocalSessionLauncher.Container]
        let composeServices: [String]
        let error: Error?
    }

    static func containerCatalog(directory: String) -> ContainerCatalog {
        do {
            let containers = try PromptLocalSessionLauncher.containers()
            let services = (try? PromptLocalSessionLauncher.composeServices(directory: directory)) ?? []
            if containers.isEmpty && services.isEmpty {
                throw PromptLocalSessionLauncher.LaunchError.failed("Docker is available, but no containers or Compose services were found.")
            }
            return ContainerCatalog(
                containers: containers,
                composeServices: services,
                error: nil)
        } catch {
            return ContainerCatalog(containers: [], composeServices: [], error: error)
        }
    }

    static func open(
        container: PromptLocalSessionLauncher.Container,
        store: PromptWorkspaceStore,
        directory: String
    ) {
        guard container.state == "running" else {
            show(PromptLocalSessionLauncher.LaunchError.failed(
                "Container \(container.name) is \(container.state). Start it and try again."))
            return
        }
        let details = PromptLocalSessionDetails(container: container.name)
        store.createLocal(
            directory: directory,
            command: PromptLocalSessionLauncher.containerCommand(identity: container.id),
            title: container.name,
            behavior: .container,
            details: details)
    }

    static func open(
        composeService: String,
        store: PromptWorkspaceStore,
        directory: String
    ) {
        let details = PromptLocalSessionDetails(composeService: composeService)
        store.createLocal(
            directory: directory,
            command: PromptLocalSessionLauncher.composeCommand(service: composeService),
            title: composeService,
            behavior: .container,
            details: details)
    }

    static func createPrivileged(store: PromptWorkspaceStore, directory: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Create a privileged session?"
        alert.informativeText = "Commands in this session may run with administrator privileges. The session remains visibly marked and elevation is never repeated during restoration."
        alert.addButton(withTitle: "Create Privileged Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let command = requestCommand(title: "Privileged command", allowsEmpty: true) else { return }
        store.createLocal(
            directory: directory,
            command: PromptLocalSessionLauncher.privilegedCommand(command.isEmpty ? nil : command),
            title: "Privileged",
            behavior: .privileged)
    }

    static func show(_ error: Error) {
        PromptLog.commandPalette.error(
            "Command palette action failed",
            metadata: ["error": "\(error)"])
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    static var savedRemoteSessions: [PromptRemoteSession] {
        uniqueRemoteSessions(PromptSettings.shared.value(forKey: savedKey) ?? [])
    }

    /// History is ordered newest-first. A host can have many UUID-backed tmux
    /// sessions, but the reconnect picker only needs its most recent one.
    static func uniqueRemoteSessions(_ sessions: [PromptRemoteSession]) -> [PromptRemoteSession] {
        var seenHosts: Set<String> = []
        return sessions.filter { seenHosts.insert($0.destination.lowercased()).inserted }
    }

    static func refreshTailnetDiscovery() {
        tailnetCache = nil
        let hosts = Set(
            savedRemoteSessions.map(\.destination)
                + sshConfigHosts
                + discoverTailnetSSHHosts())
        prefetchRemoteHomeDirectories(Array(hosts))
    }

    static func localFolderPicker(store: PromptWorkspaceStore, at path: String) -> PromptFolderPickerConfiguration {
        PromptFolderPickerConfiguration(
            initialDirectory: URL(fileURLWithPath: path).standardizedFileURL.path,
            displayName: { $0.promptDisplayPath },
            directories: { localDirectories(at: $0) },
            onSelect: { store.createLocal(directory: $0) },
            onReveal: { NSWorkspace.shared.open(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) },
            createDirectory: {
                try FileManager.default.createDirectory(
                    atPath: $0,
                    withIntermediateDirectories: true)
            })
    }

    struct RemoteHost: Identifiable {
        let title: String
        let destination: String
        let isTailnet: Bool

        var id: String { destination }
    }

    static func remoteHosts() -> [RemoteHost] {
        let configuredHosts = Set(savedRemoteSessions.map(\.destination) + sshConfigHosts)
        let tailnetHosts = Set(discoverTailnetSSHHosts())
        let configured = configuredHosts.compactMap { host -> RemoteHost? in
            guard !tailnetHosts.contains(where: { tailnetHost($0, matchesSSHHost: host) }) else { return nil }
            return RemoteHost(title: host, destination: host, isTailnet: false)
        }
        let discovered = tailnetHosts.map { destination in
            let title = destination.split(separator: ".").first.map(String.init) ?? destination
            return RemoteHost(title: title, destination: destination, isTailnet: true)
        }
        let hosts = (configured + discovered).sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        prefetchRemoteHomeDirectories(hosts.map(\.destination))
        return hosts
    }

    /// MagicDNS commonly exposes `pi.tailnet-name.ts.net` while ~/.ssh/config
    /// names the same machine simply `pi`. Treat those as one destination so
    /// discovery enriches the user's SSH alias instead of creating a duplicate.
    static func tailnetHost(_ tailnetHost: String, matchesSSHHost sshHost: String) -> Bool {
        func destinationHost(_ value: String) -> String {
            let withoutUser = value.split(separator: "@", maxSplits: 1).last.map(String.init) ?? value
            return withoutUser.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        }
        let tailnet = destinationHost(tailnetHost)
        let ssh = destinationHost(sshHost)
        return tailnet == ssh || tailnet.split(separator: ".").first.map(String.init) == ssh
    }

    static func tailnetSSHHosts(
        from data: Data,
        isSSHReachable: (String) -> Bool
    ) -> [String] {
        struct Status: Decodable {
            struct Peer: Decodable {
                let DNSName: String?
                let HostName: String?
                let OS: String?
                let TailscaleIPs: [String]?
                let Online: Bool?
            }

            let BackendState: String?
            let Peer: [String: Peer]?
        }

        guard let status = try? JSONDecoder().decode(Status.self, from: data),
              status.BackendState == "Running" else { return [] }
        return (status.Peer?.values ?? [:].values).compactMap { peer in
            guard peer.Online == true,
                  let address = peer.TailscaleIPs?.first(where: { !$0.contains(":") }) else { return nil }
            let mobileSystems = ["android", "ios", "tvos"]
            let isMobile = peer.OS.map { mobileSystems.contains($0.lowercased()) } ?? false
            guard isSSHReachable(address) || !isMobile else { return nil }
            let dnsName = peer.DNSName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let destination = dnsName?.isEmpty == false ? dnsName : peer.HostName
            guard let destination, isSafeRemote(destination) else { return nil }
            return destination
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func open(_ descriptor: PromptRemoteSession, store: PromptWorkspaceStore, attachOnly: Bool = false) {
        let config = PromptRemoteSessionConfiguration(destination: descriptor.destination, workingDirectory: descriptor.directory, persistentSessionName: descriptor.session, attachOnly: attachOnly)
        store.createRemote(config, title: "SSH · \(descriptor.name)")
    }

    static func remoteCommand(destination: String, session: String, attachOnly: Bool, directory: String? = nil) -> String {
        PromptRemoteCommand.build(.init(destination: destination, workingDirectory: directory, persistentSessionName: session, attachOnly: attachOnly))
    }

    static func isSafeRemote(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: #"^[A-Za-z0-9._@:-]+$"#, options: .regularExpression) != nil
    }

    static func isSafeSession(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    static func newRemoteSessionName() -> String {
        "prompt-" + UUID().uuidString.lowercased()
    }

    static func localDirectories(at path: String) -> [PromptFolderPickerEntry] {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        var children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])) ?? []

        // macOS marks /Volumes as hidden even though it is the canonical
        // browser entry point for mounted external and network drives.
        if url.path == "/" {
            let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            if FileManager.default.fileExists(atPath: volumes.path),
               !children.contains(where: { $0.standardizedFileURL == volumes }) {
                children.append(volumes)
            }
        }

        return children.compactMap { child in
            guard (try? child.resourceValues(forKeys: keys).isDirectory) == true else { return nil }
            return PromptFolderPickerEntry(name: child.lastPathComponent, path: child.path)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static var sshConfigHosts: [String] {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace)
            guard parts.first?.lowercased() == "host" else { return [] }
            return parts.dropFirst().map(String.init).filter { !$0.contains("*") && !$0.contains("?") && isSafeRemote($0) }
        }
    }

    private static func discoverTailnetSSHHosts() -> [String] {
        if let cache = tailnetCache, Date().timeIntervalSince(cache.date) < 30 {
            return cache.hosts
        }
        let lastSuccessfulHosts: [String] = PromptSettings.shared.value(forKey: tailnetSavedKey) ?? []
        guard let executable = tailscaleExecutable else {
            logger.error("Tailscale executable was not found")
            return lastSuccessfulHosts
        }
        for attempt in 1 ... 3 {
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = executable
            process.arguments = ["status", "--json"]
            process.standardOutput = output
            process.standardError = error
            do { try process.run() } catch {
                logger.error(
                    "Failed to run Tailscale",
                    metadata: ["error": "\(error)", "tool": "\(executable.lastPathComponent)"])
                continue
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8) ?? ""
                logger.error(
                    "Tailscale status attempt failed",
                    metadata: [
                        "attempt": "\(attempt)",
                        "exit_code": "\(process.terminationStatus)",
                        "message": "\(message)",
                    ])
                continue
            }
            let hosts = tailnetSSHHosts(from: data, isSSHReachable: sshPortIsReachable)
            guard !hosts.isEmpty else {
                logger.notice("Tailscale status attempt \(attempt) returned no SSH peers; waiting for peer state")
                if attempt < 3 { Thread.sleep(forTimeInterval: 0.35) }
                continue
            }
            tailnetCache = (Date(), hosts)
            PromptSettings.shared.set(hosts, forKey: tailnetSavedKey)
            logger.info(
                "Tailscale status returned SSH candidates",
                metadata: [
                    "candidate_count": "\(hosts.count)",
                    "response_bytes": "\(data.count)",
                ])
            return hosts
        }
        logger.error("Tailscale status produced no usable peers after three attempts; retaining \(lastSuccessfulHosts.count) previously discovered hosts")
        tailnetCache = (Date(), lastSuccessfulHosts)
        return lastSuccessfulHosts
    }

    private static var tailscaleExecutable: URL? {
        var candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/tailscale" }
        return candidates.lazy
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func sshPortIsReachable(_ address: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-z", "-G", "1", address, "22"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func remoteFolderPicker(
        store: PromptWorkspaceStore,
        host: String,
        transport: PromptRemoteTransport = .controlMode
    ) -> PromptFolderPickerConfiguration {
        PromptFolderPickerConfiguration(
            initialDirectory: "~",
            displayName: { $0.promptDisplayPath },
            directories: { directory in
                let entries = try await remoteDirectories(host: host, at: directory)
                cacheRemoteDirectories(entries, host: host, at: directory)
                return entries
            },
            onSelect: { directory in
                // Each Prompt session owns a UUID-backed tmux identity. The
                // UUID is persisted in its remote configuration for restores.
                let descriptor = PromptRemoteSession(
                    destination: host,
                    name: host,
                    session: newRemoteSessionName(),
                    directory: directory)
                remember(descriptor)
                let config = PromptRemoteSessionConfiguration(
                    destination: descriptor.destination,
                    workingDirectory: descriptor.directory,
                    persistentSessionName: descriptor.session,
                    attachOnly: false,
                    transport: transport)
                store.createRemote(config, title: "SSH · \(descriptor.name)")
            },
            onReveal: nil,
            cachedDirectories: { cachedRemoteDirectories(host: host, at: $0) },
            resolvePath: { PromptRemoteFolderPath.resolve($0) },
            browsingDirectory: { PromptRemoteFolderPath.resolve($0) },
            prepareDirectory: { try await createRemoteDirectory(host: host, at: $0) },
            errorMessage: { _ in
                "Couldn’t access this folder. Check the path and your connection, then try again."
            })
    }

    private static func remoteDirectoryCacheKey(host: String, directory: String) -> String {
        host + "\u{0}" + (PromptRemoteFolderPath.resolve(directory) ?? directory)
    }

    private static func cachedRemoteDirectories(
        host: String,
        at directory: String
    ) -> [PromptFolderPickerEntry]? {
        remoteDirectoryCache[remoteDirectoryCacheKey(host: host, directory: directory)]
    }

    private static func cacheRemoteDirectories(
        _ entries: [PromptFolderPickerEntry],
        host: String,
        at directory: String
    ) {
        remoteDirectoryCache[remoteDirectoryCacheKey(host: host, directory: directory)] = entries
    }

    private static func prefetchRemoteHomeDirectories(_ hosts: [String]) {
        for host in hosts {
            let key = remoteDirectoryCacheKey(host: host, directory: "~")
            guard remoteDirectoryCache[key] == nil,
                  remoteDirectoryPrefetches.insert(key).inserted else { continue }
            Task {
                defer { remoteDirectoryPrefetches.remove(key) }
                guard let entries = try? await remoteDirectories(host: host, at: "~") else { return }
                // Prefetching only warms the cache. It deliberately does not
                // publish into a picker that may already be showing another
                // directory or a user-controlled selection.
                remoteDirectoryCache[key] = entries
            }
        }
    }

    private static func remember(_ descriptor: PromptRemoteSession) {
        var values = savedRemoteSessions.filter {
            $0.destination.caseInsensitiveCompare(descriptor.destination) != .orderedSame
        }
        values.insert(descriptor, at: 0)
        PromptSettings.shared.set(Array(values.prefix(12)), forKey: savedKey)
    }

    private static func remoteDirectories(host: String, at directory: String) async throws -> [PromptFolderPickerEntry] {
        // A quoted `~` is not expanded by POSIX shells. Resolve it explicitly so
        // the picker starts in the remote account's home on every host.
        let requested: String
        if directory == "~" || directory == "~/" { requested = "$HOME" }
        else if directory.hasPrefix("~/") { requested = "$HOME/" + shellQuote(String(directory.dropFirst(2))) }
        else { requested = shellQuote(directory) }
        let script = "target=\(requested); cd -- \"$target\" && printf '%s\\0' \"$PWD\" && find . -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0"
        let quotedScript = shellQuote(script)
        return try await Task.detached {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "ConnectTimeout=8", "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                host, "sh", "-lc", quotedScript,
            ]
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Could not read this remote folder."
                throw NSError(domain: "PromptRemoteFolderPicker", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
            }
            let values = data.split(separator: 0).compactMap { String(data: $0, encoding: .utf8) }
            guard let base = values.first else { return [] }
            return values.dropFirst().map { relative in
                let name = String(relative.dropFirst(2))
                return PromptFolderPickerEntry(name: name, path: (base as NSString).appendingPathComponent(name))
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }

    private static func createRemoteDirectory(host: String, at directory: String) async throws {
        let resolved = PromptRemoteFolderPath.resolve(directory) ?? directory
        let requested: String
        if resolved == "~" { requested = "$HOME" }
        else if resolved.hasPrefix("~/") { requested = "$HOME/" + shellQuote(String(resolved.dropFirst(2))) }
        else { requested = shellQuote(resolved) }
        let script = "target=\(requested); mkdir -p -- \"$target\" && cd -- \"$target\""
        let quotedScript = shellQuote(script)
        try await Task.detached {
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "ConnectTimeout=8", "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                host, "sh", "-lc", quotedScript,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(
                    data: errors.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? "Could not create this remote folder."
                throw NSError(
                    domain: "PromptRemoteFolderPicker",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: message])
            }
        }.value
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
