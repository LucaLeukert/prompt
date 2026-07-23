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
            PromptCommandOption(title: "Current directory", section: "Create session", subtitle: directory.promptDisplayPath, description: "Open a local shell", symbols: ["⌘", "T"], leadingIcon: "terminal", primaryActionTitle: "Open shell in current directory") {
                store.createLocal(directory: directory)
            },
            PromptCommandOption(title: "Local project…", section: "Create session", subtitle: "Choose a folder on this Mac", description: "Browse folders without leaving the palette", folderPicker: PromptSessionLauncher.localFolderPicker(store: store, at: directory), primaryActionTitle: "Browse local projects"),
            PromptCommandOption(title: "Remote session…", section: "Create session", subtitle: "SSH config and Tailscale", description: "Discover SSH hosts, pick a folder, and open a reconnectable session", leadingIcon: "network", primaryActionTitle: "Choose a remote host", children: {
                PromptSessionLauncher.remoteOptions(store: store)
            }),
            PromptCommandOption(title: "Codex agent", section: "Create session", subtitle: directory.promptDisplayPath, description: "Start Codex in a dedicated session", leadingIcon: "sparkles", primaryActionTitle: "Start Codex in current directory") {
                store.createLocal(directory: directory, command: PromptAgentCommand.codex, title: "Codex")
            },
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
    private static let logger = Logger(subsystem: "net.leukert.prompt", category: "tailnet-discovery")
    private static let savedKey = "PromptPersistentRemoteSessions"
    private static let tailnetSavedKey = "PromptDiscoveredTailnetHosts"
    private static var tailnetCache: (date: Date, hosts: [String])?

    static var savedRemoteSessions: [PromptRemoteSession] {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let value = try? JSONDecoder().decode([PromptRemoteSession].self, from: data) else { return [] }
        return value
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
            onReveal: { NSWorkspace.shared.open(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) })
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

    private static func localDirectories(at path: String) -> [PromptFolderPickerEntry] {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
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
        let lastSuccessfulHosts = UserDefaults.standard.stringArray(forKey: tailnetSavedKey) ?? []
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
            UserDefaults.standard.set(hosts, forKey: tailnetSavedKey)
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
                // A new picker selection represents a new remote terminal. Give
                // it a stable, unique tmux identity so it reconnects after a
                // network drop without attaching other Prompt sessions to it.
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
        if let data = try? JSONEncoder().encode(Array(values.prefix(12))) { UserDefaults.standard.set(data, forKey: savedKey) }
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
