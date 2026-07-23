import AppKit
import SwiftUI
import Darwin

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

/// A Codex TUI can be pointed at an app-server instead of starting its own
/// private backend. Prompt transparently proxies that connection so the
/// sidebar sees the authoritative thread events emitted for `/new` and
/// `/resume`. Notifications are scoped to the owning client, so a separate
/// observer connection cannot see them. This also avoids inferring the active
/// thread from session history, which does not record the TUI's selection.
private final class PromptCodexAgentObserver {
    var onNotification: (([String: Any]) -> Void)?

    private let socketPath: String
    private let upstreamSocketPath: String
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientDescriptor: Int32 = -1
    private var upstreamDescriptor: Int32 = -1
    private var secondaryConnections: [Int32: Int32] = [:]
    private var clientBuffer = Data()
    private var serverBuffer = Data()
    private var sentWebSocketHandshake = false
    private var receivedWebSocketHandshake = false
    private var pendingThreadRequestIDs: Set<String> = []
    private let queue = DispatchQueue(label: "dev.prompt.codex-sidebar-observer")

    init(socketPath: String, upstreamSocketPath: String) {
        self.socketPath = socketPath
        self.upstreamSocketPath = upstreamSocketPath
    }

    func start() -> Bool {
        try? FileManager.default.removeItem(atPath: socketPath)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0, bindSocket(descriptor, to: socketPath), Darwin.listen(descriptor, 1) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            return false
        }
        listener = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { Darwin.close(descriptor) }
        acceptSource = source
        source.resume()
        return true
    }

    func stop() {
        stopConnection()
        acceptSource?.cancel()
        acceptSource = nil
        listener = -1
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func acceptClient() {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        let upstream = socket(AF_UNIX, SOCK_STREAM, 0)
        guard upstream >= 0, connectSocket(upstream, to: upstreamSocketPath) else {
            Darwin.close(client)
            if upstream >= 0 { Darwin.close(upstream) }
            return
        }

        let observesTraffic = clientDescriptor < 0
        if observesTraffic {
            clientDescriptor = client
            upstreamDescriptor = upstream
        } else {
            secondaryConnections[client] = upstream
        }
        Thread.detachNewThread { [weak self] in
            self?.relay(client: client, upstream: upstream, observesTraffic: observesTraffic)
        }
    }

    private func stopConnection() {
        let client = clientDescriptor
        let upstream = upstreamDescriptor
        clientDescriptor = -1
        upstreamDescriptor = -1
        if client >= 0 {
            Darwin.shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }
        if upstream >= 0 {
            Darwin.shutdown(upstream, SHUT_RDWR)
            Darwin.close(upstream)
        }
        let secondary = secondaryConnections
        secondaryConnections.removeAll()
        for (client, upstream) in secondary {
            Darwin.shutdown(client, SHUT_RDWR)
            Darwin.close(client)
            Darwin.shutdown(upstream, SHUT_RDWR)
            Darwin.close(upstream)
        }
        serverBuffer.removeAll(keepingCapacity: true)
        clientBuffer.removeAll(keepingCapacity: true)
        pendingThreadRequestIDs.removeAll()
        sentWebSocketHandshake = false
        receivedWebSocketHandshake = false
    }

    private func relay(client: Int32, upstream: Int32, observesTraffic: Bool) {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var polls = [
                pollfd(fd: client, events: Int16(POLLIN), revents: 0),
                pollfd(fd: upstream, events: Int16(POLLIN), revents: 0),
            ]
            let ready = Darwin.poll(&polls, nfds_t(polls.count), -1)
            guard ready > 0 else {
                if errno == EINTR { continue }
                break
            }
            for (index, source, destination, observesServer) in [
                (0, client, upstream, false),
                (1, upstream, client, true),
            ] where polls[index].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(source, buffer.baseAddress, buffer.count)
                }
                guard count > 0 else {
                    finishConnection(client: client, upstream: upstream)
                    return
                }
                let data = Data(bytes.prefix(count))
                guard writeAll(data, to: destination) else {
                    finishConnection(client: client, upstream: upstream)
                    return
                }
                if observesTraffic {
                    if observesServer { consumeServerData(data) }
                    else { consumeClientData(data) }
                }
            }
        }
        finishConnection(client: client, upstream: upstream)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard var address = rawBuffer.baseAddress else { return true }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                remaining -= written
                address = address.advanced(by: written)
            }
            return true
        }
    }

    private func finishConnection(client: Int32, upstream: Int32) {
        queue.async { [weak self] in
            guard let self else { return }
            if clientDescriptor == client, upstreamDescriptor == upstream {
                stopConnection()
            } else if secondaryConnections.removeValue(forKey: client) == upstream {
                Darwin.shutdown(client, SHUT_RDWR)
                Darwin.close(client)
                Darwin.shutdown(upstream, SHUT_RDWR)
                Darwin.close(upstream)
            }
        }
    }

    private func bindSocket(_ descriptor: Int32, to path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    private func connectSocket(_ descriptor: Int32, to path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    private func consumeServerData(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            serverBuffer.append(data)
            if !receivedWebSocketHandshake {
                let terminator = Data("\r\n\r\n".utf8)
                guard let range = serverBuffer.range(of: terminator) else { return }
                serverBuffer.removeSubrange(serverBuffer.startIndex ..< range.upperBound)
                receivedWebSocketHandshake = true
            }
            while let payload = nextWebSocketPayload(from: &serverBuffer) {
                guard let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                    continue
                }
                if value["method"] != nil {
                    DispatchQueue.main.async { self.onNotification?(value) }
                } else if let id = CodexAppServer.stringID(value["id"]),
                          pendingThreadRequestIDs.remove(id) != nil,
                          let result = value["result"] as? [String: Any],
                          let thread = result["thread"] as? [String: Any] {
                    DispatchQueue.main.async {
                        var params: [String: Any] = ["thread": thread]
                        if let model = result["model"] as? String { params["model"] = model }
                        if let effort = result["reasoningEffort"] as? String { params["reasoningEffort"] = effort }
                        self.onNotification?(["method": "thread/started", "params": params])
                    }
                }
            }
        }
    }

    private func consumeClientData(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            clientBuffer.append(data)
            if !sentWebSocketHandshake {
                let terminator = Data("\r\n\r\n".utf8)
                guard let range = clientBuffer.range(of: terminator) else { return }
                clientBuffer.removeSubrange(clientBuffer.startIndex ..< range.upperBound)
                sentWebSocketHandshake = true
            }
            while let payload = nextWebSocketPayload(from: &clientBuffer) {
                guard let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      let method = value["method"] as? String else { continue }
                if ["thread/start", "thread/resume", "thread/fork"].contains(method),
                   let id = CodexAppServer.stringID(value["id"]) {
                    pendingThreadRequestIDs.insert(id)
                } else if method == "turn/start",
                          let params = value["params"] as? [String: Any],
                          let threadID = params["threadId"] as? String,
                          let model = params["model"] as? String {
                    var update: [String: Any] = ["threadId": threadID, "model": model]
                    if let effort = (params["effort"] as? String) ?? (params["reasoningEffort"] as? String) {
                        update["reasoningEffort"] = effort
                    }
                    DispatchQueue.main.async {
                        self.onNotification?([
                            "method": "thread/model/updated",
                            "params": update,
                        ])
                    }
                }
            }
        }
    }

    private func nextWebSocketPayload(from buffer: inout Data) -> Data? {
        guard buffer.count >= 2 else { return nil }
        let bytes = [UInt8](buffer.prefix(10))
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var payloadLength = Int(bytes[1] & 0x7F)
        var headerLength = 2
        if payloadLength == 126 {
            guard buffer.count >= 4 else { return nil }
            payloadLength = Int(bytes[2]) << 8 | Int(bytes[3])
            headerLength = 4
        } else if payloadLength == 127 {
            guard buffer.count >= 10 else { return nil }
            let length = bytes[2 ..< 10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard length <= UInt64(Int.max) else { return nil }
            payloadLength = Int(length)
            headerLength = 10
        }
        let maskLength = masked ? 4 : 0
        guard buffer.count >= headerLength + maskLength + payloadLength else { return nil }
        let mask = masked ? [UInt8](buffer[headerLength ..< (headerLength + 4)]) : []
        let payloadStart = headerLength + maskLength
        var payload = Data(buffer[payloadStart ..< (payloadStart + payloadLength)])
        buffer.removeSubrange(0 ..< (payloadStart + payloadLength))
        if masked {
            for index in payload.indices { payload[index] ^= mask[index % 4] }
        }
        // Codex 0.145 sends JSON-RPC as binary WebSocket messages over Unix
        // sockets, while older builds used text messages.
        return opcode == 0x1 || opcode == 0x2 ? payload : Data()
    }
}

private extension PromptCodexAgentObserver {
    /// App-server notifications are scoped to the client connection that owns
    /// the TUI thread. Acting as a transparent proxy lets Prompt observe that
    /// exact stream; opening a second client only sees its own empty state.
    func waitForUpstreamAndStart() -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: upstreamSocketPath), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard FileManager.default.fileExists(atPath: upstreamSocketPath) else { return false }
        return start()
    }
}

private final class PromptCodexAgentBridge {
    var onThreadUpdate: ((PromptTerminalRuntime.SidebarCodexThread) -> Void)? {
        didSet {
            if let thread { onThreadUpdate?(thread) }
        }
    }

    private let executable: String
    private let socketDirectory: String
    private let socketPath: String
    private let upstreamSocketPath: String
    private let launcherPath: String
    private let server = Process()
    private let observer: PromptCodexAgentObserver
    private var thread: PromptTerminalRuntime.SidebarCodexThread?

    init?(paneID: PromptPane.ID, workingDirectory: String) {
        guard FileManager.default.isExecutableFile(atPath: PromptAgentCommand.codex) else { return nil }
        executable = PromptAgentCommand.codex
        socketDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/prompt/codex-\(paneID.uuidString)", isDirectory: true).path
        socketPath = "\(socketDirectory)/proxy.sock"
        upstreamSocketPath = "\(socketDirectory)/server.sock"
        launcherPath = "\(socketDirectory)/launch.command"
        observer = PromptCodexAgentObserver(socketPath: socketPath, upstreamSocketPath: upstreamSocketPath)
        observer.onNotification = { [weak self] notification in self?.consume(notification) }

        try? FileManager.default.removeItem(atPath: socketDirectory)
        guard (try? FileManager.default.createDirectory(
            atPath: socketDirectory, withIntermediateDirectories: true)) != nil else { return nil }
        let launcher = """
        #!/bin/sh
        exec \(Self.shellQuote(executable)) -C \(Self.shellQuote(workingDirectory)) \
        --remote \(Self.shellQuote("unix://\(socketPath)"))
        """
        guard (try? launcher.write(toFile: launcherPath, atomically: true, encoding: .utf8)) != nil,
              Darwin.chmod(launcherPath, S_IRWXU) == 0 else { return nil }
        server.executableURL = URL(fileURLWithPath: executable)
        server.arguments = ["app-server", "--listen", "unix://\(upstreamSocketPath)"]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        server.terminationHandler = { [weak self] _ in self?.observer.stop() }
        do { try server.run() } catch { return nil }

        guard observer.waitForUpstreamAndStart() else {
            server.terminate()
            return nil
        }
    }

    deinit { stop() }

    var command: String {
        launcherPath
    }

    func stop() {
        observer.stop()
        if server.isRunning { server.terminate() }
        try? FileManager.default.removeItem(atPath: socketDirectory)
    }

    private func consume(_ notification: [String: Any]) {
        guard let method = notification["method"] as? String,
              let params = notification["params"] as? [String: Any] else { return }
        switch method {
        case "thread/started":
            guard let value = params["thread"] as? [String: Any],
                  let id = value["id"] as? String else { return }
            let name = (value["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = (value["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = name?.isEmpty == false ? name! : (preview?.isEmpty == false ? preview! : "New Codex thread")
            let updated = (value["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
            let status = (value["status"] as? [String: Any])?["type"] as? String
            let existing = thread?.id == id ? thread : nil
            publish(.init(
                id: id,
                title: title,
                updatedAt: updated,
                isWorking: status == "active",
                model: params["model"] as? String ?? existing?.model,
                reasoningEffort: params["reasoningEffort"] as? String ?? existing?.reasoningEffort))

        case "thread/name/updated":
            guard let id = params["threadId"] as? String,
                  let name = params["threadName"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  thread?.id == id, let thread else { return }
            publish(.init(id: id, title: name, updatedAt: Date(), isWorking: thread.isWorking, model: thread.model, reasoningEffort: thread.reasoningEffort))

        case "thread/status/changed":
            guard let id = params["threadId"] as? String,
                  let thread, thread.id == id else { return }
            let active = ((params["status"] as? [String: Any])?["type"] as? String) == "active"
            publish(.init(id: id, title: thread.title, updatedAt: Date(), isWorking: active, model: thread.model, reasoningEffort: thread.reasoningEffort))

        case "turn/started", "turn/completed":
            guard let id = params["threadId"] as? String,
                  let thread, thread.id == id else { return }
            publish(.init(id: id, title: thread.title, updatedAt: Date(), isWorking: method == "turn/started", model: thread.model, reasoningEffort: thread.reasoningEffort))

        case "thread/model/updated":
            guard let id = params["threadId"] as? String,
                  let model = params["model"] as? String,
                  let thread, thread.id == id else { return }
            publish(.init(
                id: id,
                title: thread.title,
                updatedAt: Date(),
                isWorking: thread.isWorking,
                model: model,
                reasoningEffort: params["reasoningEffort"] as? String ?? thread.reasoningEffort))

        case "item/started", "item/completed":
            guard let id = params["threadId"] as? String,
                  let thread, thread.id == id,
                  let item = params["item"] as? [String: Any],
                  item["type"] as? String == "userMessage",
                  let content = item["content"] as? [[String: Any]] else { return }
            let prompt = content.compactMap { $0["text"] as? String }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return }
            publish(.init(
                id: id,
                title: prompt,
                updatedAt: Date(),
                isWorking: thread.isWorking,
                model: thread.model,
                reasoningEffort: thread.reasoningEffort))

        default:
            break
        }
    }

    private func publish(_ value: PromptTerminalRuntime.SidebarCodexThread) {
        thread = value
        onThreadUpdate?(value)
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }
}

@MainActor
final class PromptTerminalRuntime: ObservableObject {
    struct SidebarPullRequest: Equatable {
        let number: Int
        let title: String
        let isDraft: Bool
        let state: String
        let url: URL
    }
    struct SidebarCodexThread: Equatable {
        let id: String
        let title: String
        let updatedAt: Date
        let isWorking: Bool
        let model: String?
        let reasoningEffort: String?
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
    @Published private(set) var localCodexThreads: [PromptPane.ID: SidebarCodexThread] = [:]
    private var localStatusTasks: [PromptPane.ID: Task<Void, Never>] = [:]
    private var localCodexPaneIDs: Set<PromptPane.ID> = []
    private var codexBridges: [PromptPane.ID: PromptCodexAgentBridge] = [:]
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
                    if command.lowercased().contains("codex") {
                        self.localCodexPaneIDs.insert(paneID)
                    }
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
            let isCodexAgent = local.command?.lowercased().contains("codex") == true
            let bridge = isCodexAgent
                ? PromptCodexAgentBridge(paneID: pane.id, workingDirectory: local.workingDirectory)
                : nil
            let adapterConfig = GhosttyAppKitSurfaceConfiguration(
                workingDirectory: local.workingDirectory,
                command: bridge?.command ?? local.command,
                initialInput: nil)
            guard let hosted = application.makeSurface(configuration: adapterConfig) else { return nil }
            surface = PromptTerminalSurface.wrap(hosted.hostedView)
            if let bridge {
                // The TUI can start its thread while makeSurface is still
                // returning. Register the bridge before installing the
                // callback, because the callback immediately replays that
                // already-observed thread.
                codexBridges[pane.id] = bridge
                bridge.onThreadUpdate = { [weak self, weak bridge] thread in
                    guard let self, self.codexBridges[pane.id] === bridge else { return }
                    self.localCodexThreads[pane.id] = thread
                }
            }

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
        case .local(let local):
            if local.command?.lowercased().contains("codex") == true {
                localCodexPaneIDs.insert(pane.id)
            }
            monitorLocalPane(pane.id, surface: surface, configuredDirectory: local.workingDirectory)
        }
        return surface
    }

    func surface(for paneID: PromptPane.ID) -> PromptTerminalSurface? { surfaces[paneID] }

    func localCodexThread(for surface: PromptTerminalSurface) -> SidebarCodexThread? {
        guard let paneID = surfaces.first(where: { $0.value === surface })?.key,
              codexBridges[paneID] != nil else { return nil }
        return localCodexThreads[paneID]
    }

    func isLocalCodexSurface(_ surface: PromptTerminalSurface) -> Bool {
        guard let paneID = surfaces.first(where: { $0.value === surface })?.key else { return false }
        return codexBridges[paneID] != nil
    }

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
        localCodexThreads.removeValue(forKey: paneID)
        localCodexPaneIDs.remove(paneID)
        codexBridges.removeValue(forKey: paneID)?.stop()
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

    private func monitorLocalPane(_ paneID: PromptPane.ID, surface: PromptTerminalSurface, configuredDirectory: String) {
        localStatusTasks[paneID]?.cancel()
        localStatusTasks[paneID] = Task { [weak self, weak surface] in
            while !Task.isCancelled {
                let directory = surface?.workingDirectory ?? configuredDirectory
                if let branch = await Self.fetchLocalGitBranch(directory) {
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
            process.arguments = ["pr", "view", branch, "--json", "number,title,isDraft,state,url"]
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let object = try? JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any],
                  let number = object["number"] as? Int,
                  let title = object["title"] as? String,
                  let state = object["state"] as? String,
                  let urlString = object["url"] as? String,
                  let url = URL(string: urlString) else { return nil }
            return SidebarPullRequest(
                number: number,
                title: title,
                isDraft: object["isDraft"] as? Bool ?? false,
                state: state,
                url: url)
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
