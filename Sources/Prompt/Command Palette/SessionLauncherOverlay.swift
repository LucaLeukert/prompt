import AppKit
import OSLog
import SwiftUI

struct PromptCommandPaletteView: View {
    @ObservedObject var store: PromptWorkspaceStore
    let surface: PromptTerminalSurface?
    @Binding var isPresented: Bool

    var body: some View {
        if isPresented {
            GeometryReader { geometry in
                VStack {
                    Spacer().frame(height: geometry.size.height * 0.05)
                    PromptCommandPaletteContentView(
                        store: store,
                        isPresented: $isPresented,
                        backgroundColor: PromptTheme.elevated,
                        options: commandOptions)
                    Spacer()
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .onDisappear { surface?.focus() }
        }
    }

    private var commandOptions: [PromptCommandOption] {
        let directory = surface?.workingDirectory ?? NSHomeDirectory()
        var options: [PromptCommandOption] = [
            PromptCommandOption(
                title: "Current directory",
                section: "Create session",
                subtitle: directory.promptDisplayPath,
                description: "Open here, or press Command-K for another local session type",
                symbols: ["⌘", "T"],
                leadingIcon: "terminal",
                primaryActionTitle: "Open shell in current directory",
                contextualActions: {
                    PromptSessionLauncher.currentDirectoryActions(store: store, directory: directory)
                }) {
                    store.createLocal(directory: directory)
                },
            PromptCommandOption(title: "Open folder…", section: "Create session", subtitle: "Choose a folder on this Mac", description: "Browse folders without leaving the palette", folderPicker: PromptSessionLauncher.localFolderPicker(store: store, at: directory), primaryActionTitle: "Browse local folders"),
            PromptCommandOption(
                title: "Git open…",
                section: "Create session",
                subtitle: "Repositories and registered worktrees",
                description: "Browse Git locations, or press Command-K to create a worktree",
                leadingIcon: "arrow.triangle.branch",
                folderPicker: PromptSessionLauncher.gitFolderPicker(store: store, at: directory),
                primaryActionTitle: "Browse Git repositories",
                contextualActions: {
                    PromptSessionLauncher.gitActions(store: store, directory: directory)
                }),
            PromptCommandOption(title: "Container…", section: "Create session", subtitle: "Docker containers and Compose services", description: "Open an interactive shell in a container", leadingIcon: "shippingbox", primaryActionTitle: "Choose a container", children: {
                PromptSessionLauncher.containerOptions(store: store, directory: directory)
            }),
            PromptCommandOption(title: "Remote session…", section: "Create session", subtitle: "SSH config and Tailscale", description: "Discover SSH hosts, pick a folder, and open a reconnectable session", leadingIcon: "network", primaryActionTitle: "Choose a remote host", children: {
                PromptSessionLauncher.remoteOptions(store: store)
            }),
            PromptCommandOption(title: "Split right", section: "Actions", description: "Split the focused session horizontally", symbols: ["⌘", "D"], leadingIcon: "rectangle.split.2x1", primaryActionTitle: "Split focused session right") {
                store.splitFocused(axis: .horizontal)
            },
            PromptCommandOption(title: "Split down", section: "Actions", description: "Split the focused session vertically", symbols: ["⇧", "⌘", "D"], leadingIcon: "rectangle.split.1x2", primaryActionTitle: "Split focused session down") {
                store.splitFocused(axis: .vertical)
            },
            PromptCommandOption(title: "Close pane", section: "Actions", description: "Close the focused pane", symbols: ["⌘", "W"], leadingIcon: "xmark.rectangle", primaryActionTitle: "Close focused pane") {
                store.closeFocusedPane()
            },
            PromptCommandOption(title: "Edit sidebar", section: "Sidebar", subtitle: "Arrange groups and sessions visually", description: "Drag, rename, group, and manage the sidebar", leadingIcon: "rectangle.3.group", sidebarEditor: store),
            PromptCommandOption(title: "Sidebar layout…", section: "Sidebar", subtitle: store.sidebarLayout == .flat ? "Flat" : "Grouped", description: "Choose how sessions are organized", leadingIcon: "sidebar.left", primaryActionTitle: "Choose sidebar layout", children: {
                [
                    PromptCommandOption(title: "Flat", section: "Layout", description: "Show one continuous session list", leadingIcon: "list.bullet", primaryActionTitle: "Use flat sidebar layout") { store.sidebarLayout = .flat },
                    PromptCommandOption(title: "Grouped", section: "Layout", description: "Nest sessions by machine or custom folder", leadingIcon: "list.bullet.indent", primaryActionTitle: "Use grouped sidebar layout") { store.sidebarLayout = .grouped },
                ]
            }),
            PromptCommandOption(title: "Sort sessions…", section: "Sidebar", subtitle: store.sidebarSort.label, description: "Change sidebar ordering", leadingIcon: "arrow.up.arrow.down", primaryActionTitle: "Choose session sort order", children: {
                PromptWorkspaceStore.SidebarSort.allCases.map { sort in
                    PromptCommandOption(title: sort.label, section: "Sort sessions", description: sort.detail, leadingIcon: store.sidebarSort == sort ? "checkmark" : "circle", primaryActionTitle: "Sort sessions by \(sort.label.lowercased())") { store.sidebarSort = sort }
                }
            }),
            PromptCommandOption(title: "New sidebar folder…", section: "Sidebar", description: "Create a custom session group", leadingIcon: "folder.badge.plus", primaryActionTitle: "Create sidebar folder", action: {
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
            }),
            PromptCommandOption(title: "Move session to folder…", section: "Sidebar", subtitle: store.sidebarFolders.isEmpty ? "Create a folder first" : nil, description: "Move the focused session into a custom group", leadingIcon: "folder", primaryActionTitle: "Choose destination folder", children: {
                [PromptCommandOption(title: "Automatic (by machine)", section: "Folders", leadingIcon: "desktopcomputer", primaryActionTitle: "Group focused session automatically") { store.assignFocusedSession(to: nil) }]
                    + store.sidebarFolders.map { folder in PromptCommandOption(title: folder, section: "Folders", leadingIcon: "folder", primaryActionTitle: "Move focused session to \(folder)") { store.assignFocusedSession(to: folder) } }
            }),
        ]
        options.append(contentsOf: openSessionOptions)
        options.append(contentsOf: PromptSessionLauncher.savedRemoteSessions.map { remote in
            PromptCommandOption(title: remote.name, section: "Recent remote sessions", subtitle: remote.destination, description: "Attach to persistent session \(remote.session)", leadingIcon: "arrow.clockwise.circle", primaryActionTitle: "Reconnect to \(remote.name)") {
                PromptSessionLauncher.open(remote, store: store)
            }
        })
        return options
    }

    private var openSessionOptions: [PromptCommandOption] {
        store.workspace.sessions.flatMap { session in
            session.splitTree.panes.map { pane in
                PromptCommandOption(title: pane.title.isEmpty ? session.title : pane.title, section: "Open sessions", subtitle: store.runtime.surface(for: pane.id)?.workingDirectory?.promptDisplayPath, description: "Focus this terminal", leadingIcon: "rectangle.on.rectangle", primaryActionTitle: "Focus \(pane.title.isEmpty ? session.title : pane.title)") {
                    store.focus(sessionID: session.id, paneID: pane.id)
                }
            }
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

    private static let logger = Logger(subsystem: "net.leukert.prompt", category: "tailnet-discovery")
    private static let savedKey = "PromptPersistentRemoteSessions"
    private static let tailnetSavedKey = "PromptDiscoveredTailnetHosts"
    private static let gitLocationsCacheFileName = "git-locations.json"
    private static let gitLocationsCacheLimit = 40
    private static var tailnetCache: (date: Date, hosts: [String])?

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

    static func gitFolderPicker(store: PromptWorkspaceStore, at path: String) -> PromptFolderPickerConfiguration {
        let current = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = PromptLocalSessionLauncher.gitRoot(containing: current)
        let initial = root.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? current
        let cached = cachedGitLocations()
        let seeds = Array(Set(
            store.workspace.sessions.compactMap(\.configuration.configuredDirectory)
                + [current]))
        return PromptFolderPickerConfiguration(
            initialDirectory: initial,
            displayName: { $0.promptDisplayPath },
            directories: { directory in
                let locations = await Task.detached {
                    PromptLocalSessionLauncher.gitLocations(
                        searching: directory,
                        seeds: seeds,
                        cached: cached)
                }.value
                rememberGitLocations(locations)
                return locations.map { location in
                    let repository = URL(fileURLWithPath: location.repository).lastPathComponent
                    let worktreeName = URL(fileURLWithPath: location.path).lastPathComponent
                    let name = location.isMainWorktree ? repository : "\(repository) · \(location.branch ?? worktreeName)"
                    let detail = [
                        location.isMainWorktree ? "repository" : "worktree",
                        location.branch.map { "git:\($0)" },
                        location.path.promptDisplayPath,
                    ].compactMap { $0 }.joined(separator: "  ·  ")
                    return PromptFolderPickerEntry(
                        name: name,
                        path: location.path,
                        subtitle: detail,
                        icon: location.isMainWorktree ? "folder.badge.gearshape" : "arrow.triangle.branch")
                }
            },
            onSelect: { openGitLocation($0, store: store) },
            onReveal: { NSWorkspace.shared.open(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) },
            sectionTitle: "Git repositories & worktrees",
            actionTitle: "Open",
            emptyText: "No Git repositories found in this location",
            selectsEntries: true)
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

    static func worktreeOptions(store: PromptWorkspaceStore, directory: String) -> [PromptCommandOption] {
        do {
            let worktrees = try PromptLocalSessionLauncher.worktrees(containing: directory)
            let attach = worktrees.map { worktree in
                PromptCommandOption(
                    title: URL(fileURLWithPath: worktree.path).lastPathComponent,
                    section: "Git worktrees",
                    subtitle: [worktree.branch, worktree.path.promptDisplayPath].compactMap { $0 }.joined(separator: " · "),
                    description: worktree.isMain ? "Main repository worktree" : "Attach without transferring ownership to Prompt",
                    leadingIcon: worktree.isMain ? "folder" : "arrow.triangle.branch",
                    primaryActionTitle: "Attach to \(worktree.path)",
                    action: {
                        let details = PromptLocalSessionDetails(
                            repository: worktree.repository,
                            branch: worktree.branch,
                            worktreePath: worktree.path,
                            worktreeOwnership: .external)
                        _ = store.createLocal(
                            directory: worktree.path,
                            title: worktree.branch ?? URL(fileURLWithPath: worktree.path).lastPathComponent,
                            behavior: .worktree,
                            details: details)
                    })
            }
            let create = PromptCommandOption(
                title: "Create worktree…",
                section: "Actions",
                subtitle: URL(fileURLWithPath: worktrees.first?.repository ?? directory).lastPathComponent,
                description: "Create a Prompt-owned worktree for a new branch",
                leadingIcon: "plus",
                primaryActionTitle: "Create Git worktree") {
                    createWorktree(store: store, directory: worktrees.first?.repository ?? directory)
                }
            return attach + [create]
        } catch {
            return [PromptCommandOption(
                title: "Git worktrees unavailable",
                section: "Worktree",
                subtitle: error.localizedDescription,
                description: "Select a directory inside a Git repository",
                leadingIcon: "exclamationmark.triangle",
                primaryActionTitle: "Show worktree error") { show(error) }]
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

    static func containerOptions(store: PromptWorkspaceStore, directory: String) -> [PromptCommandOption] {
        do {
            let containers = try PromptLocalSessionLauncher.containers()
            let containerOptions = containers.map { container in
                PromptCommandOption(
                    title: container.name,
                    section: "Docker containers",
                    subtitle: "\(container.state) · \(container.id)",
                    description: container.state == "running" ? "Open /bin/sh in this container" : "Start this container before opening a shell",
                    leadingIcon: container.state == "running" ? "shippingbox" : "pause.circle",
                    primaryActionTitle: "Open \(container.name)") {
                        guard container.state == "running" else {
                            show(PromptLocalSessionLauncher.LaunchError.failed("Container \(container.name) is \(container.state). Start it and try again."))
                            return
                        }
                        let details = PromptLocalSessionDetails(container: container.name)
                        _ = store.createLocal(
                            directory: directory,
                            command: PromptLocalSessionLauncher.containerCommand(identity: container.id),
                            title: container.name,
                            behavior: .container,
                            details: details)
                    }
            }
            let services = (try? PromptLocalSessionLauncher.composeServices(directory: directory)) ?? []
            let composeOptions = services.map { service in
                PromptCommandOption(
                    title: service,
                    section: "Docker Compose services",
                    subtitle: directory.promptDisplayPath,
                    description: "Open /bin/sh in the running Compose service",
                    leadingIcon: "square.3.layers.3d",
                    primaryActionTitle: "Open Compose service \(service)",
                    action: {
                        let details = PromptLocalSessionDetails(composeService: service)
                        _ = store.createLocal(
                            directory: directory,
                            command: PromptLocalSessionLauncher.composeCommand(service: service),
                            title: service,
                            behavior: .container,
                            details: details)
                    })
            }
            if containerOptions.isEmpty && composeOptions.isEmpty {
                throw PromptLocalSessionLauncher.LaunchError.failed("Docker is available, but no containers or Compose services were found.")
            }
            return containerOptions + composeOptions
        } catch {
            return [PromptCommandOption(
                title: "Docker unavailable",
                section: "Container",
                subtitle: error.localizedDescription,
                description: "Install or start Docker and try again",
                leadingIcon: "exclamationmark.triangle",
                primaryActionTitle: "Show Docker error") { show(error) }]
        }
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

    private static func show(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    static var savedRemoteSessions: [PromptRemoteSession] {
        PromptSettings.shared.value(forKey: savedKey) ?? []
    }

    static func refreshTailnetDiscovery() {
        tailnetCache = nil
        _ = discoverTailnetSSHHosts()
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

    static func remoteOptions(store: PromptWorkspaceStore) -> [PromptCommandOption] {
        let configuredHosts = Set(savedRemoteSessions.map(\.destination) + sshConfigHosts)
        let tailnetHosts = Set(discoverTailnetSSHHosts())
        let configured = configuredHosts.compactMap { host -> (title: String, destination: String, isTailnet: Bool)? in
            guard !tailnetHosts.contains(where: { tailnetHost($0, matchesSSHHost: host) }) else { return nil }
            return (host, host, false)
        }
        let discovered = tailnetHosts.map { destination in
            let title = destination.split(separator: ".").first.map(String.init) ?? destination
            return (title: title, destination: destination, isTailnet: true)
        }
        let hosts = configured + discovered
        return hosts.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.flatMap { host in
            [
                PromptCommandOption(title: host.title, section: host.isTailnet ? "Tailnet SSH hosts" : "SSH hosts", subtitle: host.isTailnet ? "Discovered through Tailscale · \(host.destination)" : "Native panes and inline AI", description: "Open a controlled tmux session on \(host.destination)", leadingIcon: host.isTailnet ? "point.3.connected.trianglepath.dotted" : "network", folderPicker: remoteFolderPicker(store: store, host: host.destination, transport: .controlMode), primaryActionTitle: "Choose folder on \(host.title)"),
                PromptCommandOption(title: "\(host.title) · Legacy TTY", section: host.isTailnet ? "Tailnet SSH compatibility" : "SSH compatibility", subtitle: "Standard attached tmux client", description: "Use when tmux control mode is unavailable", leadingIcon: "network.slash", folderPicker: remoteFolderPicker(store: store, host: host.destination, transport: .legacyTTY), primaryActionTitle: "Choose legacy TTY folder on \(host.title)"),
            ]
        }
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
                logger.error("Failed to run Tailscale at \(executable.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8) ?? ""
                logger.error("Tailscale status attempt \(attempt) exited with \(process.terminationStatus): \(message, privacy: .public)")
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
            logger.info("Tailscale status returned \(data.count) bytes and \(hosts.count) SSH candidates: \(hosts.joined(separator: ","), privacy: .public)")
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

    private static func remoteFolderPicker(
        store: PromptWorkspaceStore,
        host: String,
        transport: PromptRemoteTransport = .controlMode
    ) -> PromptFolderPickerConfiguration {
        PromptFolderPickerConfiguration(
            initialDirectory: "~",
            displayName: { $0.promptDisplayPath },
            directories: { try await remoteDirectories(host: host, at: $0) },
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
            onReveal: nil)
    }

    private static func remember(_ descriptor: PromptRemoteSession) {
        var values = savedRemoteSessions.filter { $0.destination != descriptor.destination || $0.session != descriptor.session }
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

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
