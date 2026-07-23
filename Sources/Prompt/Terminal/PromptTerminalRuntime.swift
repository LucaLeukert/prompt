import AppKit
import SwiftUI

/// Opt-in switches for functionality that is still being evaluated in real
/// terminal sessions. Values are deliberately absent unless an experiment is
/// explicitly enabled, so every flag defaults to `false`.
enum PromptExperimentalFeatures {
    static let remoteAIEnabledDefaultsKey = "PromptExperimentalRemoteAIEnabled"

    static var remoteAIEnabled: Bool {
        remoteAIEnabled(in: .ghostty)
    }

    static func remoteAIEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: remoteAIEnabledDefaultsKey) as? Bool ?? false
    }
}

@MainActor
enum PromptTerminalCapabilities {
    struct RemoteContext: Equatable {
        let destination: String
        var workingDirectory: String?
        let supportsInlineRichContent: Bool
    }

    private static var remotes: [ObjectIdentifier: RemoteContext] = [:]
    private static var compositeAuthorities: Set<ObjectIdentifier> = []

    static func registerRemote(_ configuration: PromptRemoteSessionConfiguration, on surface: PromptTerminalSurface) {
        remotes[ObjectIdentifier(surface)] = .init(
            destination: configuration.destination,
            workingDirectory: configuration.workingDirectory,
            supportsInlineRichContent: configuration.transport == .controlMode)
    }

    static func updateRemoteDirectory(_ directory: String, on surface: PromptTerminalSurface) {
        let id = ObjectIdentifier(surface)
        guard var context = remotes[id] else { return }
        context.workingDirectory = directory
        remotes[id] = context
    }

    static func remoteContext(for surface: PromptTerminalSurface) -> RemoteContext? {
        remotes[ObjectIdentifier(surface)]
    }

    static func isManagedRemote(_ surface: PromptTerminalSurface) -> Bool {
        remoteContext(for: surface) != nil
    }

    /// Managed SSH/tmux sessions stay terminal-only unless the remote AI
    /// experiment is explicitly enabled. Local surfaces are unaffected.
    static func allowsAI(on surface: PromptTerminalSurface) -> Bool {
        !isManagedRemote(surface) || PromptExperimentalFeatures.remoteAIEnabled
    }

    static func registerCompositeAuthority(_ surface: GhosttyAppKitSurface) {
        compositeAuthorities.insert(surface.identity)
    }

    static func isCompositeAuthority(_ surface: PromptTerminalSurface) -> Bool {
        compositeAuthorities.contains(surface.identity)
    }

    static func unregister(_ surface: PromptTerminalSurface) {
        remotes.removeValue(forKey: ObjectIdentifier(surface))
        compositeAuthorities.remove(surface.identity)
    }

    static func unregister(_ view: Ghostty.SurfaceView) {
        compositeAuthorities.remove(ObjectIdentifier(view))
    }
}

@MainActor
final class PromptTerminalRuntime: ObservableObject {
    struct SidebarPullRequest: Equatable {
        let number: Int
        let title: String
        let isDraft: Bool
    }
    struct RemotePaneDescriptor: Equatable {
        let id: String
        let active: Bool
        let command: String
        let workingDirectory: String
        let left: Int
        let top: Int
        let width: Int
        let height: Int
    }

    struct RemotePaneStatus: Equatable {
        var command: String
        var workingDirectory: String
        var gitBranch: String?
        var paneCount: Int
        var panes: [RemotePaneDescriptor] = []

        var isBusy: Bool {
            !["sh", "bash", "zsh", "fish", "dash", "nu", "xonsh"].contains(command)
        }
    }

    enum RemoteConnectionState: Equatable {
        case connecting
        case online
        case offline(String)

        var isOffline: Bool {
            if case .offline = self { return true }
            return false
        }
    }

    private struct RemoteStatusCheck {
        var status: RemotePaneStatus?
        var failureDescription: String?
    }

    let application: GhosttyAppKitApplication
    @Published private(set) var surfaces: [PromptPane.ID: PromptTerminalSurface] = [:]
    @Published private(set) var remotePaneStatuses: [PromptPane.ID: RemotePaneStatus] = [:]
    @Published private(set) var remoteConnectionStates: [PromptPane.ID: RemoteConnectionState] = [:]
    private var remoteStatusTasks: [PromptPane.ID: Task<Void, Never>] = [:]
    var remoteTmuxPaneIDs: [PromptPane.ID: String] = [:]
    private var remoteConfigurations: [PromptPane.ID: PromptRemoteSessionConfiguration] = [:]
    var onRemotePaneInventory: ((PromptPane.ID, [RemotePaneDescriptor]) -> Void)?
    @Published private(set) var localGitBranches: [PromptPane.ID: String] = [:]
    @Published private(set) var localPaneCommands: [PromptPane.ID: String] = [:]
    @Published private(set) var localPullRequests: [PromptPane.ID: SidebarPullRequest] = [:]
    @Published private(set) var localCommandStartedAt: [PromptPane.ID: Date] = [:]
    private var localStatusTasks: [PromptPane.ID: Task<Void, Never>] = [:]
    private var commandObservers: [NSObjectProtocol] = []
    private var pullRequestRefreshes: [PromptPane.ID: Date] = [:]

    init() {
        PromptTypography.registerBundledFonts()
        application = GhosttyAppKitApplication(configDefaults: """
        font-family = ""
        font-family = Geist Mono
        # Terminal input must preserve one glyph per typed cell. In particular,
        # Geist Mono's programming ligatures can reshape `--help` and make its
        # spaces look displaced while the cursor remains cell-aligned.
        font-feature = -calt, -liga, -dlig
        window-title-font-family = Geist
        background = 171716
        foreground = E8E8E6
        cursor-color = E8E8E6
        selection-background = 3A3A38
        selection-foreground = F7F7F5
        palette = 0=#171716
        palette = 1=#E06C75
        palette = 2=#76B947
        palette = 3=#D6B35A
        palette = 4=#61AEEE
        palette = 5=#C678DD
        palette = 6=#56B6C2
        palette = 7=#D6D6D3
        palette = 8=#666664
        palette = 9=#F07178
        palette = 10=#98C379
        palette = 11=#E5C07B
        palette = 12=#7AB7F0
        palette = 13=#D89BE8
        palette = 14=#7BC8D0
        palette = 15=#F5F5F3
        """)
        commandObservers = [
            NotificationCenter.default.addObserver(
                forName: .promptTerminalCommandSubmitted, object: nil, queue: .main) { [weak self] note in
                    guard let self,
                          let surface = note.object as? PromptTerminalSurface,
                          let command = note.userInfo?[Notification.Name.CommandTextKey] as? String,
                          let paneID = self.surfaces.first(where: { $0.value === surface })?.key else { return }
                    self.localPaneCommands[paneID] = command
                    self.localCommandStartedAt[paneID] = Date()
                },
            NotificationCenter.default.addObserver(
                forName: .ghosttyCommandDidFinish, object: nil, queue: .main) { [weak self] note in
                    guard let self,
                          let surface = note.object as? PromptTerminalSurface,
                          let paneID = self.surfaces.first(where: { $0.value === surface })?.key else { return }
                    self.localPaneCommands.removeValue(forKey: paneID)
                    self.localCommandStartedAt.removeValue(forKey: paneID)
                },
        ]
    }

    func createSurface(for pane: PromptPane, configuration: PromptSessionConfiguration) -> PromptTerminalSurface? {
        let surface: PromptTerminalSurface
        switch configuration {
        case .local(let local):
            let adapterConfig = GhosttyAppKitSurfaceConfiguration(
                workingDirectory: local.workingDirectory,
                command: local.command,
                initialInput: nil)
            guard let hosted = application.makeSurface(configuration: adapterConfig) else { return nil }
            surface = PromptTerminalSurface.wrap(hosted.hostedView)

        case .remote(let remote) where remote.transport == .controlMode:
            let router = PromptCompositeIORouter()
            let presentationConfig = GhosttyAppKitSurfaceConfiguration(
                workingDirectory: nil,
                command: nil,
                initialInput: nil,
                manualIOWriteHandler: { [weak router] data in router?.forwardInput(data) })
            guard let presentation = application.makeSurface(configuration: presentationConfig) else { return nil }
            let authorityConfig = GhosttyAppKitSurfaceConfiguration(
                workingDirectory: nil,
                command: PromptRemoteCommand.buildControlMode(remote),
                initialInput: nil)
            guard let authority = application.makeSurface(configuration: authorityConfig) else {
                presentation.requestClose()
                return nil
            }
            surface = PromptTerminalSurface.wrap(presentation.hostedView)
            surface.configureComposite(authority: authority, router: router)
            PromptTerminalCapabilities.registerCompositeAuthority(authority)

        case .remote(let remote):
            let adapterConfig = GhosttyAppKitSurfaceConfiguration(
                workingDirectory: nil,
                command: PromptRemoteCommand.buildLegacy(remote),
                initialInput: nil)
            guard let hosted = application.makeSurface(configuration: adapterConfig) else { return nil }
            surface = PromptTerminalSurface.wrap(hosted.hostedView)
        }
        surfaces[pane.id] = surface
        switch configuration {
        case .remote(let remote):
            PromptTerminalCapabilities.registerRemote(remote, on: surface)
            remoteConfigurations[pane.id] = remote
            if let tmuxPaneID = remote.tmuxPaneID { remoteTmuxPaneIDs[pane.id] = tmuxPaneID }
            monitorRemotePane(pane.id, configuration: remote, surface: surface)
        case .local: monitorLocalPane(pane.id, surface: surface)
        }
        return surface
    }

    func surface(for paneID: PromptPane.ID) -> PromptTerminalSurface? { surfaces[paneID] }

    func close(paneID: PromptPane.ID, terminateRemotePane: Bool = false) {
        if terminateRemotePane,
           let configuration = remoteConfigurations[paneID],
           configuration.transport == .controlMode,
           let tmuxPaneID = remoteTmuxPaneIDs[paneID] {
            Self.runRemoteTmux(configuration, arguments: ["kill-pane", "-t", tmuxPaneID])
        }
        remoteStatusTasks.removeValue(forKey: paneID)?.cancel()
        localStatusTasks.removeValue(forKey: paneID)?.cancel()
        remotePaneStatuses.removeValue(forKey: paneID)
        remoteConnectionStates.removeValue(forKey: paneID)
        remoteTmuxPaneIDs.removeValue(forKey: paneID)
        remoteConfigurations.removeValue(forKey: paneID)
        localGitBranches.removeValue(forKey: paneID)
        localPaneCommands.removeValue(forKey: paneID)
        localPullRequests.removeValue(forKey: paneID)
        localCommandStartedAt.removeValue(forKey: paneID)
        pullRequestRefreshes.removeValue(forKey: paneID)
        if let surface = surfaces.removeValue(forKey: paneID) {
            PromptTerminalCapabilities.unregister(surface)
            PromptNativeInputRouter.cleanup(for: surface)
            PromptRichContentStore.shared.clear(for: surface)
            surface.closeComposite()
            surface.requestClose()
        }
    }

    func splitRemotePane(_ paneID: PromptPane.ID, axis: PromptSplitAxis) -> Bool {
        guard let configuration = remoteConfigurations[paneID],
              configuration.transport == .controlMode,
              let tmuxPaneID = remoteTmuxPaneIDs[paneID] else { return false }
        Self.runRemoteTmux(
            configuration,
            arguments: ["split-window", axis == .horizontal ? "-h" : "-v", "-t", tmuxPaneID, "-c", "#{pane_current_path}"])
        return true
    }

    func focusRemotePane(_ paneID: PromptPane.ID) {
        guard let configuration = remoteConfigurations[paneID],
              configuration.transport == .controlMode,
              let tmuxPaneID = remoteTmuxPaneIDs[paneID] else { return }
        Self.runRemoteTmux(configuration, arguments: ["select-pane", "-t", tmuxPaneID])
    }

    private nonisolated static func runRemoteTmux(
        _ configuration: PromptRemoteSessionConfiguration,
        arguments: [String]
    ) {
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let command = (["tmux"] + arguments).map(shellQuote).joined(separator: " ")
            process.arguments = [
                "-o", "ConnectTimeout=3", "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                configuration.destination, "sh", "-lc", shellQuote(command),
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    private func monitorRemotePane(
        _ paneID: PromptPane.ID,
        configuration: PromptRemoteSessionConfiguration,
        surface: PromptTerminalSurface
    ) {
        remoteStatusTasks[paneID]?.cancel()
        remoteConnectionStates[paneID] = .connecting
        remoteStatusTasks[paneID] = Task { [weak self] in
            while !Task.isCancelled {
                let check = await Self.fetchRemotePaneStatus(configuration)
                if let status = check.status {
                    self?.remotePaneStatuses[paneID] = status
                    self?.remoteConnectionStates[paneID] = .online
                    PromptTerminalCapabilities.updateRemoteDirectory(status.workingDirectory, on: surface)
                    if self?.remoteTmuxPaneIDs[paneID] == nil,
                       let active = status.panes.first(where: \.active) {
                        self?.remoteTmuxPaneIDs[paneID] = active.id
                    }
                    self?.onRemotePaneInventory?(paneID, status.panes)
                } else {
                    self?.remoteConnectionStates[paneID] = .offline(
                        check.failureDescription ?? "The SSH connection could not be established.")
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func monitorLocalPane(_ paneID: PromptPane.ID, surface: PromptTerminalSurface) {
        localStatusTasks[paneID]?.cancel()
        localStatusTasks[paneID] = Task { [weak self, weak surface] in
            while !Task.isCancelled {
                if let directory = surface?.workingDirectory,
                   let branch = await Self.fetchLocalGitBranch(directory) {
                    self?.localGitBranches[paneID] = branch
                    let refreshDue = self?.pullRequestRefreshes[paneID].map { Date().timeIntervalSince($0) > 20 } ?? true
                    if refreshDue {
                        self?.pullRequestRefreshes[paneID] = Date()
                        let pullRequest = await Self.fetchPullRequest(directory, branch: branch)
                        if let pullRequest { self?.localPullRequests[paneID] = pullRequest }
                        else { self?.localPullRequests.removeValue(forKey: paneID) }
                    }
                } else {
                    self?.localGitBranches.removeValue(forKey: paneID)
                    self?.localPullRequests.removeValue(forKey: paneID)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private nonisolated static func fetchLocalGitBranch(_ directory: String) async -> String? {
        await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory, "symbolic-ref", "--quiet", "--short", "HEAD"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let branch = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return branch?.isEmpty == false ? branch : nil
        }.value
    }

    private nonisolated static func fetchPullRequest(_ directory: String, branch: String) async -> SidebarPullRequest? {
        await Task.detached {
            let executable = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first {
                FileManager.default.isExecutableFile(atPath: $0)
            }
            guard let executable else { return nil }
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["pr", "view", "--head", branch, "--json", "number,title,isDraft,state"]
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let object = try? JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any],
                  let number = object["number"] as? Int,
                  let title = object["title"] as? String,
                  (object["state"] as? String) == "OPEN" else { return nil }
            return SidebarPullRequest(number: number, title: title, isDraft: object["isDraft"] as? Bool ?? false)
        }.value
    }

    private nonisolated static func fetchRemotePaneStatus(_ configuration: PromptRemoteSessionConfiguration) async -> RemoteStatusCheck {
        await Task.detached {
            let session = configuration.persistentSessionName ?? "prompt"
            let format = "#{pane_id}|||#{pane_active}|||#{pane_current_command}|||#{pane_current_path}|||#{pane_left}|||#{pane_top}|||#{pane_width}|||#{pane_height}"
            let script = "tmux list-panes -t \(shellQuote(session)) -F \(shellQuote(format)) 2>/dev/null || exit 1"
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "ConnectTimeout=3", "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                configuration.destination, "sh", "-lc", shellQuote(script),
            ]
            process.standardOutput = output
            process.standardError = error
            do { try process.run() } catch {
                return RemoteStatusCheck(status: nil, failureDescription: "SSH could not be started on this Mac.")
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return RemoteStatusCheck(status: nil, failureDescription: remoteFailureDescription(message))
            }
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let panes = text.split(separator: "\n").compactMap { raw -> RemotePaneDescriptor? in
                let values = String(raw).components(separatedBy: "|||")
                guard values.count == 8 else { return nil }
                return .init(
                    id: values[0], active: values[1] == "1", command: values[2],
                    workingDirectory: values[3], left: Int(values[4]) ?? 0,
                    top: Int(values[5]) ?? 0, width: Int(values[6]) ?? 1,
                    height: Int(values[7]) ?? 1)
            }
            guard let active = panes.first(where: \.active) ?? panes.first else {
                return RemoteStatusCheck(status: nil, failureDescription: "Connected, but the remote tmux session is unavailable.")
            }
            let branchProcess = Process()
            let branchOutput = Pipe()
            branchProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let branchCommand = "git -C \(shellQuote(active.workingDirectory)) symbolic-ref --quiet --short HEAD"
            branchProcess.arguments = [
                "-o", "ConnectTimeout=3", "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                configuration.destination, "sh", "-lc", shellQuote(branchCommand),
            ]
            branchProcess.standardOutput = branchOutput
            branchProcess.standardError = FileHandle.nullDevice
            try? branchProcess.run()
            branchProcess.waitUntilExit()
            let branch = String(data: branchOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let status = RemotePaneStatus(
                command: active.command,
                workingDirectory: active.workingDirectory,
                gitBranch: branch?.isEmpty == false ? branch : nil,
                paneCount: panes.count,
                panes: panes)
            return RemoteStatusCheck(status: status, failureDescription: nil)
        }.value
    }

    private nonisolated static func remoteFailureDescription(_ rawMessage: String) -> String {
        let message = rawMessage.lowercased()
        if message.contains("could not resolve hostname") { return "The host name could not be resolved." }
        if message.contains("permission denied") { return "SSH authentication was rejected by the host." }
        if message.contains("connection refused") { return "The host refused the SSH connection on port 22." }
        if message.contains("connection reset") || message.contains("connection closed") {
            return "The host closed the SSH connection. It may be shutting down."
        }
        if message.contains("no route to host") || message.contains("network is unreachable") {
            return "There is no network route to this host."
        }
        if message.contains("timed out") || message.contains("operation timed out") {
            return "The host did not respond before the SSH timeout."
        }
        return "The host is not responding to SSH."
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum PromptRemoteCommand {
    static func build(_ remote: PromptRemoteSessionConfiguration) -> String {
        remote.transport == .controlMode ? buildControlMode(remote) : buildLegacy(remote)
    }

    static func buildControlMode(_ remote: PromptRemoteSessionConfiguration) -> String {
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        return [
            shellQuote(executable),
            PromptTmuxControlBridge.argument,
            shellQuote(remote.destination),
            shellQuote(remote.persistentSessionName ?? "prompt"),
            shellQuote(remote.tmuxPaneID ?? "-"),
            shellQuote(remote.workingDirectory ?? "-"),
            remote.attachOnly ? "attach" : "create",
        ].joined(separator: " ")
    }

    static func buildLegacy(_ remote: PromptRemoteSessionConfiguration) -> String {
        let destination = shellQuote(remote.destination)
        let name = shellQuote(remote.persistentSessionName ?? "prompt")
        let tmux = remote.attachOnly ? "tmux attach-session -t \(name)" : "tmux new-session -A -s \(name)"
        let body = remote.workingDirectory.map {
            let directory: String
            if $0 == "~" || $0 == "~/" { directory = "\"$HOME\"" }
            else if $0.hasPrefix("~/") { directory = "\"$HOME\"/" + shellQuote(String($0.dropFirst(2))) }
            else { directory = shellQuote($0) }
            return "cd -- \(directory) && \(tmux)"
        } ?? tmux
        let reconnectLoop = "while ! ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=20 -o ServerAliveCountMax=2 -tt \(destination) \(shellQuote(body)); do printf '\\nConnection lost; reconnecting in 3s…\\n'; sleep 3; done"
        return "/bin/sh -c \(shellQuote(reconnectLoop))"
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct PromptHostedTerminalView: View {
    @ObservedObject var surface: PromptTerminalSurface
    let paneID: PromptPane.ID
    let runtime: PromptTerminalRuntime
    @State private var showingAuthoritativeSurface = false
    private let screenModeTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Group {
                if showingAuthoritativeSurface, let authority = surface.authoritativeSurface {
                    GhosttyAppKitSurfaceHost(surface: authority, application: runtime.application)
                } else {
                    GhosttyAppKitSurfaceHost(surface: surface, application: runtime.application)
                }
                }
                if case .offline(let description) = runtime.remoteConnectionStates[paneID] {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remote host is offline")
                                .font(.system(size: 13, weight: .semibold))
                            Text(description + " Prompt will keep trying to reconnect.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.35)))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
                    .padding(14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: runtime.remoteConnectionStates[paneID])
            .onAppear { surface.synchronizeCompositeSize(geometry.size) }
            .onChange(of: geometry.size) { size in
                surface.synchronizeCompositeSize(size)
            }
            .onReceive(screenModeTimer) { _ in
                let alternate = surface.compositeIsAlternateScreen
                guard alternate != showingAuthoritativeSurface else { return }
                surface.synchronizeCompositeSize(geometry.size)
                showingAuthoritativeSurface = alternate
            }
        }
    }
}
