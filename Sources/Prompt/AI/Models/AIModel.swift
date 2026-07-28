import AppKit
import CoreText
import Darwin
import GhosttyKit
import MarkdownUI
import SwiftMath
import SwiftUI

@MainActor
final class AIModel: ObservableObject {
    static let shared = AIModel()
    nonisolated static let debugModelOptions = ["gpt-5.3-codex-spark", "gpt-5.6-luna"]

    @Published var connected = false
    @Published var status = "Starting Codex…"
    @Published var account = "Codex"
    @Published var rateLimits = "Limits loading…"
    @Published var projectRoot = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var terminalContext = ""
    @Published var threads: [PromptThread] = []
    @Published var activeThreadID: String?
    @Published var messages: [PromptMessage] = []
    @Published var approvals: [PromptApproval] = []
    @Published var models: [String] = []
    @Published var selectedModel = "gpt-5.3-codex-spark"
    @Published var prompt = ""
    @Published var isRunning = false

    let server = CodexProvider.shared.client
    private weak var terminalResponseSurface: PromptTerminalSurface?
    private var terminalResponseCWD: String?
    private var activeAILane: PromptAILane = .assistant
    private enum TurnKind {
        case regular
        case terminal(PromptAILane)

        var isTerminalAgent: Bool {
            if case .terminal(.agent) = self { return true }
            return false
        }
    }
    private var activeTurnKind: TurnKind = .regular

    var selectedReasoningEffort: String? {
        selectedModel == "gpt-5.6-luna" ? "low" : nil
    }

    private func modelID(for capability: AICapability) -> String {
        CapabilityRouter.shared.route(for: capability)?.modelID ?? selectedModel
    }

    private func displayModel(for capability: AICapability) -> String {
        let model = modelID(for: capability)
        return model.contains("spark") ? "Spark" : model
    }
    private var terminalRichBlockID: UUID?
    private var streamingMessageID: UUID?
    private var activeTurnID: String?
    private var cancelledTurnIDs: Set<String> = []
    private var cancelledTerminalRequestIDs: Set<UUID> = []
    private var activeToolCalls: [String: PromptToolCall] = [:]
    private var executedCommands: [String] = []
    private var activeRequestText = ""
    private var externalRequestID: UUID?
    private weak var externalProvider: (any ConversationProviding)?
    private var activeConversation: AIConversation?
    private var isConnecting = false
    private var connectionWaiters: [(Result<Void, Error>) -> Void] = []
    private final class PendingTerminalRun {
        let requestID: String
        let command: String
        weak var surface: PromptTerminalSurface?

        init(requestID: String, command: String, surface: PromptTerminalSurface) {
            self.requestID = requestID
            self.command = command
            self.surface = surface
        }
    }
    private var pendingTerminalRuns: [String: PendingTerminalRun] = [:]

    /// A presentation-only view of a Prompt-managed terminal turn. The
    /// sidebar uses this to distinguish Agent mode from an ordinary shell.
    struct SidebarAgentActivity {
        let label: String
        let detail: String
        let title: String
        let isWorking: Bool
    }

    private init() {
        // Install the OSC 133 observer before the user runs the first command;
        // context retrieval must not be what activates terminal history.
        _ = PromptBlockStore.shared
        _ = AmbientAnalyzer.shared
        server.onNotification = { [weak self] message in self?.handle(message) }
        server.onServerRequest = { [weak self] message in self?.handleRequest(message) }
    }

    func start(
        cwd: String,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        projectRoot = ProjectResolver.resolve(from: cwd)
        AISystem.bootstrap(cwd: cwd)
        AutocompleteModel.shared.start(cwd: cwd)
        connected = false
        status = "Checking ChatGPT sign-in…"
        CodexProvider.shared.start(cwd: projectRoot)
        models = [DefaultAIModels.codex]
        server.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                connected = true
                refresh()
            case .failure:
                connected = false
            }
        }
        restoreConversations()
        completion?(.success(()))
    }

    func refresh() {
        CodexProvider.shared.refreshAccount { [weak self] message in
            guard let self else { return }
            account = CodexProvider.shared.status.isReady ? "ChatGPT" : "Not signed in"
            status = message
        }
        models = [DefaultAIModels.codex]
        restoreConversations()
        rateLimits = "Unavailable without app-server"
    }

    func select(_ thread: PromptThread) {
        if let conversation = ConversationStore.shared.load(id: UUID(uuidString: thread.id) ?? UUID()) {
            activeConversation = conversation
            activeThreadID = thread.id
            CapabilityRouter.shared.set(
                providerID: conversation.providerID,
                modelID: conversation.modelID,
                for: conversation.capability)
            messages = conversation.messages.map(Self.promptMessage)
            status = "Restored \(conversation.title)"
            return
        }
        activeConversation = nil
        activeThreadID = thread.id
        status = "Resuming \(thread.title)"
        server.request("thread/resume", params: [
            "threadId": thread.id,
            "cwd": projectRoot,
            "developerInstructions": PromptBuilder.baseInstructions,
        ]) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                messages.append(.init(kind: .error, text: error.localizedDescription))
            } else {
                status = "Thread resumed"
                readActiveThread()
            }
        }
    }

    func newThread() {
        activeConversation = nil
        activeThreadID = nil
        messages = []
        status = "New Prompt conversation"
    }

    func forkThread() {
        guard let id = activeThreadID else { return }
        server.request("thread/fork", params: ["threadId": id, "cwd": projectRoot]) { [weak self] result in
            guard let self, let value = try? result.get(),
                  let thread = value["thread"] as? [String: Any],
                  let id = thread["id"] as? String else { return }
            activeThreadID = id
            status = "Forked thread"
            refresh()
            readActiveThread()
        }
    }

    func archiveThread() {
        guard let id = activeThreadID else { return }
        server.request("thread/archive", params: ["threadId": id]) { [weak self] result in
            guard let self else { return }
            if (try? result.get()) != nil {
                activeThreadID = nil
                messages = []
                refresh()
            }
        }
    }

    func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        prompt = ""
        messages.append(.init(kind: .user, text: text))
        if let provider = conversationProvider(for: .assistant) {
            provider.start(cwd: projectRoot)
            startExternalTurn(text, lane: .assistant)
            return
        }
        guard connected,
              CapabilityRouter.shared.provider(for: .assistant)?
              .status(for: .assistant).isReady == true else {
            messages.append(.init(kind: .error, text: "The selected Assistant provider is unavailable."))
            return
        }
        if activeThreadID == nil {
            isRunning = true
            createThenSend(text)
            return
        }
        startTurn(text, kind: .regular)
    }

    @discardableResult
    func submitFromTerminal(
        _ text: String,
        mode: PromptInputMode,
        lane: PromptAILane = .assistant,
        surface: PromptTerminalSurface,
        clearInput: (() -> Void)? = nil
    ) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        switch mode {
        case .shell:
            surface.surfaceModel?.sendText(value)
            PromptController.pressReturn(on: surface)
            return true
        case .ai:
            let capability: AICapability = lane == .agent ? .agent : .assistant
            let routedProvider = CapabilityRouter.shared.provider(for: capability)
            routedProvider?.start(cwd: projectRoot)
            guard let selectedProvider = routedProvider,
                  routedProvider?.status(for: capability).isReady == true,
                  !isRunning else {
                status = routedProvider?.status(for: capability).isReady == true
                    ? "Finish the active Prompt turn before starting another."
                    : "The selected \(capability.rawValue.capitalized) provider is unavailable."
                return false
            }

            // Reserve the single model turn before mutating any per-request
            // origin state or beginning asynchronous thread creation.
            isRunning = true
            activeAILane = lane
            terminalResponseSurface = surface
            let remote = PromptTerminalCapabilities.remoteContext(for: surface)
            terminalResponseCWD = remote?.workingDirectory ?? surface.pwd
            if remote == nil {
                projectRoot = ProjectResolver.resolve(from: surface.pwd ?? projectRoot)
            }
            terminalRichBlockID = PromptRichContentStore.shared.begin(
                request: value,
                lane: lane,
                model: displayModel(for: capability),
                on: surface)
            // Reserve beneath the visible input first. Clearing readline/ZLE
            // afterward happens on the new live row, leaving the submitted
            // request intact as ordinary Ghostty terminal history.
            clearInput?()
            // The rich block has its own reserved scrollback rows. Restore the
            // child shell prompt immediately so AI and shell work can proceed
            // independently on the same surface.
            if remote == nil || surface.isComposite { PromptController.pressReturn(on: surface) }
            messages.append(.init(kind: .user, text: value))
            if lane == .agent, selectedProvider.descriptor.id == .codex {
                guard connected else {
                    failTerminalTurn("Codex app-server is not connected yet.")
                    return true
                }
                createTerminalThreadThenSend(value)
                return true
            }
            if selectedProvider is any ConversationProviding {
                startExternalTurn(value, lane: lane)
                return true
            }
            failTerminalTurn("The selected provider does not implement conversation execution.")
            return true
        }
    }

    func ownsTerminalInput(_ surface: PromptTerminalSurface) -> Bool {
        terminalResponseSurface === surface
    }

    func sidebarAgentActivity(for surface: PromptTerminalSurface) -> SidebarAgentActivity? {
        guard terminalResponseSurface === surface else { return nil }
        let label = activeTurnKind.isTerminalAgent ? "Codex agent" : "Codex"
        return .init(label: label, detail: status, title: activeRequestText, isWorking: isRunning)
    }

    @discardableResult
    func cancelTerminalTurn(on surface: PromptTerminalSurface) -> Bool {
        guard terminalResponseSurface === surface,
              isRunning,
              let blockID = terminalRichBlockID else { return false }
        if let externalRequestID, let externalProvider {
            externalProvider.cancel(requestID: externalRequestID)
            self.externalRequestID = nil
            self.externalProvider = nil
        } else if let threadID = activeThreadID, let turnID = activeTurnID {
            server.request("turn/interrupt", params: ["threadId": threadID, "turnId": turnID]) { _ in }
            cancelledTurnIDs.insert(turnID)
        } else {
            // Thread/turn creation is asynchronous. Remember this request so
            // a late callback cannot start work, or can interrupt immediately
            // if the server has already accepted turn/start.
            cancelledTerminalRequestIDs.insert(blockID)
        }
        PromptRichContentStore.shared.cancel(blockID, on: surface)
        isRunning = false
        status = "Turn cancelled"
        streamingMessageID = nil
        terminalRichBlockID = nil
        terminalResponseSurface = nil
        terminalResponseCWD = nil
        declinePendingTerminalRuns(reason: "The turn was cancelled.")
        activeTurnID = nil
        return true
    }

    private func conversationProvider(for capability: AICapability) -> (any ConversationProviding)? {
        CapabilityRouter.shared.provider(for: capability) as? any ConversationProviding
    }

    private func startExternalTurn(_ text: String, lane: PromptAILane) {
        let capability: AICapability = lane == .agent ? .agent : .assistant
        guard let provider = conversationProvider(for: capability),
              provider.status(for: capability).isReady,
              let route = CapabilityRouter.shared.route(for: capability) else {
            failTerminalTurn("The selected \(capability.rawValue.capitalized) provider is unavailable.")
            return
        }
        activeTurnKind = .terminal(lane)
        isRunning = true
        activeRequestText = text
        status = "\(provider.descriptor.displayName) is working…"
        let message = PromptMessage(kind: .assistant, text: "")
        messages.append(message)
        streamingMessageID = message.id
        externalProvider = provider
        ensureActiveConversation(for: capability, route: route, title: text)
        persistActiveConversation()
        let previousConversation = messages.dropLast().compactMap { message -> String? in
            switch message.kind {
            case .user: "User: \(message.text)"
            case .assistant: "Assistant: \(message.text)"
            case .activity, .error: nil
            }
        }.joined(separator: "\n\n")
        externalRequestID = provider.respond(
            to: .init(
                text: text,
                instructions: lane == .agent
                    ? PromptBuilder.agentInstructions
                    : PromptBuilder.assistantInstructions,
                modelID: route.modelID,
                projectRoot: projectRoot,
                terminalContext: terminalResponseSurface.map {
                    String($0.cachedVisibleContents.get().suffix(12_000))
                } ?? terminalContext,
                conversationContext: previousConversation,
                // Direct provider turns have no native PromptApproval bridge.
                // Agent-mode mutations must stay behind the app-server
                // terminal_run flow, which creates an approval for each command.
                allowsWorkspaceWrites: false),
            onEvent: { [weak self] event in
                self?.handleExternal(event)
            })
    }

    private func handleExternal(_ event: ConversationEvent) {
        switch event {
        case .textDelta(let delta):
            if let id = streamingMessageID,
               let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].text += delta
            }
            persistActiveConversation()
            if let surface = terminalResponseSurface, let blockID = terminalRichBlockID {
                PromptRichContentStore.shared.enqueue(delta, to: blockID, on: surface)
            }
        case .completed:
            status = "Turn complete"
            isRunning = false
            externalRequestID = nil
            externalProvider = nil
            finishTerminalStream()
            streamingMessageID = nil
            persistActiveConversation()
        case .failed(let message):
            externalRequestID = nil
            externalProvider = nil
            failTerminalTurn(message)
        }
    }

    private func createThenSend(_ text: String) {
        var params: [String: Any] = [
            "cwd": projectRoot,
            "approvalPolicy": "on-request",
            "sandbox": "workspace-write",
            "model": modelID(for: .assistant),
            "baseInstructions": PromptBuilder.baseInstructions,
            "developerInstructions": PromptBuilder.baseInstructions,
        ]
        if let effort = selectedReasoningEffort { params["reasoningEffort"] = effort }
        server.request("thread/start", params: params) { [weak self] result in
            guard let self else { return }
            guard let value = try? result.get(),
                  let thread = value["thread"] as? [String: Any],
                  let id = thread["id"] as? String else {
                isRunning = false
                status = "Unable to start a Codex thread."
                return
            }
            activeThreadID = id
            startTurn(text, kind: .regular)
            refresh()
        }
    }

    private func createTerminalThreadThenSend(_ text: String) {
        guard let requestID = terminalRichBlockID else { return }
        let instructions = switch activeAILane {
        case .assistant: PromptBuilder.assistantInstructions
        case .agent: PromptBuilder.agentInstructions
        }
        var params: [String: Any] = [
            "cwd": projectRoot,
            // Terminal AI never receives editor-style mutation privileges.
            // Agent execution is exclusively mediated by terminal_run below.
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "model": modelID(for: activeAILane == .agent ? .agent : .assistant),
            "baseInstructions": instructions,
            "developerInstructions": instructions,
            // Advertise only capabilities that can actually be called in this
            // lane. Each spec's description is the model-facing contract.
            "dynamicTools": PromptTerminalTool.available(
                in: activeAILane,
                isRemote: terminalResponseSurface.map(PromptTerminalCapabilities.isManagedRemote) ?? false
            ).map(\.appServerSpec),
        ]
        if let effort = selectedReasoningEffort { params["reasoningEffort"] = effort }
        server.request("thread/start", params: params) { [weak self] result in
            guard let self else { return }
            let value: [String: Any]
            switch result {
            case .success(let response): value = response
            case .failure(let error):
                if cancelledTerminalRequestIDs.remove(requestID) != nil { return }
                failTerminalTurn("Unable to start a lightweight Codex thread: \(error.localizedDescription)")
                return
            }
            guard
                let thread = value["thread"] as? [String: Any],
                let id = thread["id"] as? String else {
                failTerminalTurn("Unable to start a lightweight Codex thread.")
                return
            }
            if cancelledTerminalRequestIDs.remove(requestID) != nil
                || terminalRichBlockID != requestID
                || !isRunning {
                server.request("thread/archive", params: ["threadId": id]) { _ in }
                return
            }
            activeThreadID = id
            startTurn(text, kind: .terminal(activeAILane))
        }
    }

    private static let askOutputSchema: [String: Any] = [
        "type": "object",
        "properties": ["response": ["type": "string"]],
        "required": ["response"],
        "additionalProperties": false,
    ]

    private func startTurn(_ text: String, kind: TurnKind) {
        guard let id = activeThreadID else { return }
        let terminalRequestID = terminalRichBlockID
        activeTurnKind = kind
        isRunning = true
        status = "Codex is working…"
        activeRequestText = text
        activeToolCalls = [:]
        executedCommands = []
        let streamedMessage = PromptMessage(kind: .assistant, text: "")
        messages.append(streamedMessage)
        streamingMessageID = streamedMessage.id

        let lane: PromptAILane = switch kind {
        case .regular: .assistant
        case .terminal(let lane): lane
        }
        let prompt = PromptBuilder.build(.init(
            userText: text,
            projectRoot: projectRoot,
            terminalText: terminalContext,
            lane: lane,
            isRemote: terminalResponseSurface.map(PromptTerminalCapabilities.isManagedRemote) ?? false))
        var params: [String: Any] = [
            "threadId": id,
            "input": prompt.appServerInput,
            "cwd": projectRoot,
            "model": modelID(for: lane == .agent ? .agent : .assistant),
        ]
        if let effort = selectedReasoningEffort { params["reasoningEffort"] = effort }
        switch kind {
        case .regular:
            params["approvalPolicy"] = "on-request"
            params["sandbox"] = "workspace-write"
            params["outputSchema"] = PromptCommandProposal.outputSchema
        case .terminal:
            params["approvalPolicy"] = "never"
            params["sandbox"] = "read-only"
            params["outputSchema"] = Self.askOutputSchema
        }
        server.request("turn/start", params: params) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                let turn = value["turn"] as? [String: Any]
                let turnID = (turn?["id"] as? String) ?? (value["turnId"] as? String)
                if let terminalRequestID,
                   cancelledTerminalRequestIDs.remove(terminalRequestID) != nil {
                    if let turnID {
                        cancelledTurnIDs.insert(turnID)
                        server.request(
                            "turn/interrupt",
                            params: ["threadId": id, "turnId": turnID]) { _ in }
                    }
                    return
                }
                activeTurnID = turnID
            case .failure(let error):
                if let terminalRequestID,
                   cancelledTerminalRequestIDs.remove(terminalRequestID) != nil { return }
                failTerminalTurn(error.localizedDescription)
            }
        }
    }

    private func failTerminalTurn(_ text: String) {
        isRunning = false
        messages.append(.init(kind: .error, text: text))
        if let surface = terminalResponseSurface, let blockID = terminalRichBlockID {
            PromptRichContentStore.shared.fail(text, id: blockID, on: surface)
        }
        streamingMessageID = nil
        terminalRichBlockID = nil
        terminalResponseSurface = nil
        terminalResponseCWD = nil
        declinePendingTerminalRuns(reason: text)
        activeTurnID = nil
        persistActiveConversation()
    }

    private func restoreConversations() {
        let conversations = ConversationStore.shared.list()
        threads = conversations.map {
            .init(
                id: $0.id.uuidString,
                title: $0.title,
                cwd: $0.projectRoot ?? "",
                updatedAt: ISO8601DateFormatter().string(from: $0.updatedAt))
        }
        guard activeConversation == nil, let conversation = conversations.first else { return }
        activeConversation = conversation
        activeThreadID = conversation.id.uuidString
        messages = conversation.messages.map(Self.promptMessage)
    }

    private func ensureActiveConversation(
        for capability: AICapability,
        route: CapabilityRoute,
        title: String
    ) {
        guard activeConversation?.capability != capability
            || activeConversation?.providerID != route.providerID
            || activeConversation?.modelID != route.modelID else { return }
        activeConversation = .init(
            capability: capability,
            providerID: route.providerID,
            modelID: route.modelID,
            title: String(title.prefix(80)),
            projectRoot: projectRoot)
        activeThreadID = activeConversation?.id.uuidString
    }

    private func persistActiveConversation() {
        guard var conversation = activeConversation else { return }
        conversation.updatedAt = Date()
        conversation.messages = messages.compactMap { message in
            let role: ConversationMessage.Role = switch message.kind {
            case .user: .user
            case .assistant: .assistant
            case .activity: .activity
            case .error: .error
            }
            return .init(role: role, text: message.text)
        }
        activeConversation = conversation
        _ = ConversationStore.shared.save(conversation)
        restoreConversations()
    }

    private static func promptMessage(_ message: ConversationMessage) -> PromptMessage {
        let kind: PromptMessage.Kind = switch message.role {
        case .user: .user
        case .assistant: .assistant
        case .activity: .activity
        case .error: .error
        }
        return .init(kind: kind, text: message.text)
    }

    func captureTerminal() {
        guard let surface = PromptController.shared.activeSurface() else {
            status = "No active terminal surface"
            return
        }
        terminalContext = String(surface.cachedVisibleContents.get().suffix(12_000))
        projectRoot = ProjectResolver.resolve(from: surface.pwd ?? projectRoot)
        status = "Captured visible terminal context"
        refresh()
    }

    func insertIntoTerminal(_ text: String) {
        guard let surface = PromptController.shared.activeSurface() else { return }
        insertTerminalText(text, on: surface)
        status = "Inserted into terminal"
    }

    func performRecommendation(_ action: PromptRecommendationAction, on surface: PromptTerminalSurface) {
        switch action.kind {
        case .insertCommand:
            insertRecommendation(action.value, on: surface)
        case .askAI:
            guard PromptTerminalEnvironment.allowsRichContent(on: surface),
                  PromptNativeInputRouter.promptInput(on: surface)?.isEmpty == true else {
                status = "Recommendation ready, but the terminal prompt changed"
                return
            }
            _ = submitFromTerminal(action.value, mode: .ai, lane: .assistant, surface: surface)
        }
    }

    private func insertRecommendation(_ command: String, on surface: PromptTerminalSurface) {
        guard PromptTerminalEnvironment.allowsRichContent(on: surface),
              PromptNativeInputRouter.promptInput(on: surface)?.isEmpty == true else {
            status = "Recommendation ready, but the terminal prompt changed"
            return
        }
        PromptNativeInputRouter.setOverride(.shell, for: surface)
        PromptNativeInputRouter.setSuggestedCommand(command, for: surface)
        insertTerminalText(command, on: surface)
        surface.focus()
        status = "Recommendation inserted for review"
    }

    private func insertTerminalText(_ text: String, on surface: PromptTerminalSurface) {
        surface.surfaceModel?.sendText(text)
        guard let terminal = surface.surface else { return }
        _ = ghostty_surface_clear_selection(terminal)
        DispatchQueue.main.async { [weak surface] in
            guard let terminal = surface?.surface else { return }
            _ = ghostty_surface_clear_selection(terminal)
        }
    }

    func runInTerminal(_ text: String) {
        insertIntoTerminal(text)
        PromptController.shared.pressReturn()
        PromptController.shared.hide()
    }

    func handoffCLI() {
        guard let id = activeThreadID else { return }
        runInTerminal("codex resume \(id)")
    }

    func openCodexDesktop() {
        guard let id = activeThreadID else {
            NSWorkspace.shared.open(URL(fileURLWithPath: projectRoot))
            return
        }
        if let url = URL(string: "codex://threads/\(id)"), NSWorkspace.shared.open(url) { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Codex", projectRoot]
        try? task.run()
    }

    func approve(_ approval: PromptApproval, decision: String) {
        if let pending = pendingTerminalRuns.removeValue(forKey: approval.id) {
            let promptIsEmpty = pending.surface.flatMap { PromptNativeInputRouter.promptInput(on: $0) }?.isEmpty == true
            if decision == "accept", let surface = pending.surface,
               PromptInsertionEligibility.allows(
                   richContentAllowed: PromptTerminalEnvironment.allowsRichContent(on: surface),
                   originalCWD: terminalResponseCWD,
                   currentCWD: surface.pwd,
                   promptIsEmpty: promptIsEmpty) {
                insertTerminalText(pending.command, on: surface)
                PromptController.pressReturn(on: surface)
                server.respondTool(id: pending.requestID, success: true, text: "Command started in the terminal. Use terminal_read to inspect its output.")
            } else {
                let text = decision == "accept"
                    ? "The terminal prompt or working directory changed; execution was refused."
                    : "The user declined this command."
                server.respondTool(id: pending.requestID, success: false, text: text)
            }
            approvals.removeAll { $0.id == approval.id }
            return
        }
        server.respond(id: approval.id, result: ["decision": decision])
        approvals.removeAll { $0.id == approval.id }
    }

    private func readActiveThread() {
        guard let id = activeThreadID else { return }
        server.request("thread/read", params: ["threadId": id, "includeTurns": true]) { [weak self] result in
            guard let self, let value = try? result.get(),
                  let thread = value["thread"] as? [String: Any],
                  let turns = thread["turns"] as? [[String: Any]] else { return }
            var loaded: [PromptMessage] = []
            for turn in turns {
                for item in turn["items"] as? [[String: Any]] ?? [] {
                    switch item["type"] as? String {
                    case "agentMessage": loaded.append(.init(kind: .assistant, text: item["text"] as? String ?? ""))
                    case "userMessage":
                        let content = item["content"] as? [[String: Any]] ?? []
                        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                        loaded.append(.init(kind: .user, text: text))
                    case "commandExecution":
                        let command = item["command"] as? String ?? "Command"
                        loaded.append(.init(kind: .activity, text: "⌘ \(command)"))
                    case "fileChange": loaded.append(.init(kind: .activity, text: "File change"))
                    default: break
                    }
                }
            }
            messages = loaded
        }
    }

    private func loadThreads(_ result: Result<[String: Any], Error>) {
        guard let value = try? result.get() else { return }
        let data = value["data"] as? [[String: Any]] ?? []
        threads = data.compactMap { raw in
            guard let id = raw["id"] as? String else { return nil }
            return PromptThread(
                id: id,
                title: (raw["name"] as? String) ?? (raw["preview"] as? String)?.components(separatedBy: .newlines).first ?? "Codex thread",
                cwd: raw["cwd"] as? String ?? "",
                updatedAt: String(describing: raw["updatedAt"] ?? raw["createdAt"] ?? ""))
        }
    }

    private func handle(_ message: [String: Any]) {
        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return }
        switch method {
        case "turn/started":
            guard isRunning else { break }
            let turn = params["turn"] as? [String: Any]
            activeTurnID = (turn?["id"] as? String) ?? (params["turnId"] as? String)
        case "item/agentMessage/delta":
            if activeTurnID == nil { activeTurnID = params["turnId"] as? String }
            let delta = params["delta"] as? String ?? ""
            if let id = streamingMessageID,
               let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].text += delta
            } else {
                let message = PromptMessage(kind: .assistant, text: delta)
                messages.append(message)
                streamingMessageID = message.id
            }
        // The constrained final message streams as JSON. Buffer it until
        // completion so schema fields never appear in the conversation UI.
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any],
                  let itemID = item["id"] as? String,
                  let type = item["type"] as? String else { break }
            let completed = method == "item/completed"
            let failed = (item["status"] as? String) == "failed"
            let detail: String
            let title: String
            switch type {
            case "commandExecution":
                title = "Shell"
                detail = Self.commandText(from: item) ?? "Command"
                if !executedCommands.contains(detail), detail != "Command" { executedCommands.append(detail) }
            case "mcpToolCall":
                title = "MCP"
                detail = (item["tool"] as? String) ?? (item["name"] as? String) ?? "Tool call"
            case "dynamicToolCall":
                title = "Tool"
                detail = (item["tool"] as? String) ?? (item["name"] as? String) ?? "Tool call"
            case "fileChange":
                title = "Files"
                detail = "Applying changes"
            default:
                return
            }
            let call = PromptToolCall(id: itemID, title: title, detail: detail, state: failed ? .failed : completed ? .complete : .running)
            activeToolCalls[itemID] = call
            if let surface = terminalResponseSurface, let blockID = terminalRichBlockID {
                PromptRichContentStore.shared.upsertToolCall(call, blockID: blockID, on: surface)
            }
            if completed { messages.append(.init(kind: .activity, text: "\(title): \(detail)")) }
        case "item/commandExecution/outputDelta":
            if let delta = params["delta"] as? String, !delta.isEmpty {
                status = String(delta.suffix(100))
            }
        case "turn/diff/updated":
            messages.append(.init(kind: .activity, text: "Diff updated in the project"))
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            let completedID = (turn?["id"] as? String) ?? (params["turnId"] as? String)
            if let completedID, cancelledTurnIDs.remove(completedID) != nil { break }
            isRunning = false
            status = "Turn complete"
            let rawResponse = streamingMessageID.flatMap { messageID in
                messages.first(where: { $0.id == messageID })?.text
            } ?? ""
            let displayResponse: String
            let suggestedCommand: String?
            switch activeTurnKind {
            case .regular:
                let proposal = PromptCommandProposal.parse(rawResponse)
                displayResponse = proposal?.response ?? rawResponse
                suggestedCommand = proposal?.command
            case .terminal(.assistant), .terminal(.agent):
                let object = rawResponse.data(using: .utf8).flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                }
                displayResponse = Self.terminalDisplayResponse(
                    object?["response"] as? String ?? rawResponse
                )
                suggestedCommand = nil
            }
            if let messageID = streamingMessageID,
               let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index].text = displayResponse
            }
            if let surface = terminalResponseSurface, let blockID = terminalRichBlockID {
                PromptRichContentStore.shared.enqueue(displayResponse, to: blockID, on: surface)
            }
            if let surface = terminalResponseSurface,
               let command = suggestedCommand {
                offerCommand(command, on: surface)
            }
            finishTerminalStream()
            streamingMessageID = nil
            refresh()
        case "account/rateLimits/updated":
            rateLimits = Self.describeRateLimits(params)
        case "account/updated":
            if let accountValue = params["account"] as? [String: Any] {
                account = (accountValue["email"] as? String)
                    ?? (accountValue["planType"] as? String)
                    ?? "ChatGPT account"
                CodexProvider.shared.markReady(account: account)
                status = "Codex connected"
                refresh()
            } else {
                CodexProvider.shared.markUnavailable(.authenticationRequired)
                status = "ChatGPT sign-in required"
            }
        case "error":
            isRunning = false
            let text = Self.serverErrorMessage(from: params) ?? "Codex error"
            messages.append(.init(kind: .error, text: text))
            if let surface = terminalResponseSurface, let blockID = terminalRichBlockID {
                PromptRichContentStore.shared.fail(text, id: blockID, on: surface)
            }
            streamingMessageID = nil
            terminalRichBlockID = nil
            terminalResponseSurface = nil
            terminalResponseCWD = nil
            declinePendingTerminalRuns(reason: text)
            activeTurnID = nil
        default: break
        }
    }

    private static func serverErrorMessage(from value: Any) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let object = value as? [String: Any] {
            for key in ["message", "error", "detail", "reason"] {
                if let nested = object[key], let text = serverErrorMessage(from: nested) { return text }
            }
        }
        if let values = value as? [Any] {
            return values.compactMap(serverErrorMessage(from:)).first
        }
        return nil
    }

    private func finishTerminalStream() {
        guard let surface = terminalResponseSurface, let blockID = terminalRichBlockID else { return }
        PromptRichContentStore.shared.finishWhenDrained(blockID, on: surface) { [weak self] in
            guard let self else { return }
            terminalRichBlockID = nil
            terminalResponseSurface = nil
            terminalResponseCWD = nil
            activeTurnID = nil
        }
    }

    private func offerCommand(_ command: String, on surface: PromptTerminalSurface) {
        if PromptTerminalCapabilities.isManagedRemote(surface) {
            NotificationCenter.default.post(
                name: .promptProposeCommand,
                object: surface,
                userInfo: [Notification.Name.PromptCommandKey: command])
            status = "Remote command ready for review"
        } else if PromptComposerPresentation.current == .inline {
            // Inline mode uses the shell's native editor; there is no SwiftUI
            // command-bar view listening for proposal notifications. Insert
            // into the fresh prompt without sending Return so the command is
            // visible, editable, and still requires explicit confirmation.
            let promptIsEmpty = PromptNativeInputRouter.promptInput(on: surface)?.isEmpty == true
            guard PromptInsertionEligibility.allows(
                richContentAllowed: PromptTerminalEnvironment.allowsRichContent(on: surface),
                originalCWD: terminalResponseCWD,
                currentCWD: surface.pwd,
                promptIsEmpty: promptIsEmpty) else {
                status = "Command ready, but the terminal prompt changed"
                return
            }
            PromptNativeInputRouter.setOverride(.shell, for: surface)
            PromptNativeInputRouter.setSuggestedCommand(command, for: surface)
            insertTerminalText(command, on: surface)
            surface.focus()
            status = "Command inserted for review"
        } else {
            NotificationCenter.default.post(
                name: .promptProposeCommand,
                object: surface,
                userInfo: [Notification.Name.PromptCommandKey: command])
        }
    }

    private func handleRequest(_ message: [String: Any]) {
        guard let id = CodexRPCClient.stringID(message["id"]),
              let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        if method == "item/tool/call" {
            handleTerminalToolRequest(id: id, params: params)
            return
        }
        if method.contains("requestApproval") || method.hasSuffix("Approval") {
            let reason = params["reason"] as? String
            let command = (params["command"] as? String) ?? ((params["command"] as? [String])?.joined(separator: " "))
            approvals.append(.init(
                id: id,
                method: method,
                summary: reason ?? command ?? "Codex requests approval",
                richBlockID: activeTurnKind.isTerminalAgent ? terminalRichBlockID : nil))
        } else {
            server.respond(id: id, result: ["decision": "decline"])
        }
    }

    private func handleTerminalToolRequest(id: String, params: [String: Any]) {
        guard case .terminal(let lane) = activeTurnKind,
              let name = params["tool"] as? String,
              let tool = PromptTerminalTool(appServerName: name),
              PromptTerminalTool.available(in: lane).contains(tool) else {
            server.respondTool(id: id, success: false, text: "This tool is not available in the current AI mode.")
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard let surface = terminalResponseSurface else {
            server.respondTool(id: id, success: false, text: "The originating terminal is no longer available.")
            return
        }
        switch tool {
        case .read:
            let requested = (arguments["maxCharacters"] as? NSNumber)?.intValue ?? 12_000
            let limit = min(24_000, max(256, requested))
            let output = String(surface.cachedVisibleContents.get().suffix(limit))
            let remote = PromptTerminalCapabilities.remoteContext(for: surface)
            let directory = remote?.workingDirectory ?? surface.pwd ?? "unknown"
            let location = remote.map { "Remote host: \($0.destination)\n" } ?? ""
            server.respondTool(id: id, success: true, text: "\(location)Current directory: \(directory)\n<terminal-output>\n\(output)\n</terminal-output>")
        case .readCommands:
            let requested = (arguments["limit"] as? NSNumber)?.intValue ?? 6
            let blocks = PromptBlockStore.shared.recent(limit: min(20, max(1, requested)), on: surface)
            let text = blocks.isEmpty ? "No completed command blocks are available." : blocks.map { block in
                "cwd: \(block.cwd)\nexit: \(block.exitCode)\nduration_ms: \(block.durationNanoseconds / 1_000_000)\n<command-output>\n\(String(block.snapshot.suffix(12_000)))\n</command-output>"
            }.joined(separator: "\n\n---\n\n")
            server.respondTool(id: id, success: true, text: text)
        case .readFile:
            guard let path = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                server.respondTool(id: id, success: false, text: "terminal.read_file requires a relative file path.")
                return
            }
            let cwd = surface.pwd ?? terminalResponseCWD
            guard let cwd, let fileURL = readableFileURL(path: path, within: cwd) else {
                server.respondTool(id: id, success: false, text: "The requested path is not a readable text file inside the terminal's current working directory.")
                return
            }
            let requested = (arguments["maxCharacters"] as? NSNumber)?.intValue ?? 60_000
            let limit = min(100_000, max(256, requested))
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: limit + 1) ?? Data()
                let truncated = data.count > limit
                let content = String(decoding: data.prefix(limit), as: UTF8.self)
                server.respondTool(
                    id: id,
                    success: true,
                    text: "<file path=\"\(fileURL.lastPathComponent)\" truncated=\"\(truncated)\">\n\(content)\n</file>")
            } catch {
                server.respondTool(id: id, success: false, text: "Unable to read the requested file: \(error.localizedDescription)")
            }
        case .suggestCommand:
            guard let command = validTerminalCommand(arguments["command"]) else {
                server.respondTool(id: id, success: false, text: "terminal.suggest_command requires one non-empty single-line command.")
                return
            }
            if PromptTerminalCapabilities.isManagedRemote(surface) {
                offerCommand(command, on: surface)
                server.respondTool(
                    id: id,
                    success: true,
                    text: "The remote command was placed in Prompt's command bar for review. It was not executed.")
                return
            }
            let promptIsEmpty = PromptNativeInputRouter.promptInput(on: surface)?.isEmpty == true
            guard PromptInsertionEligibility.allows(
                richContentAllowed: PromptTerminalEnvironment.allowsRichContent(on: surface),
                originalCWD: terminalResponseCWD,
                currentCWD: surface.pwd,
                promptIsEmpty: promptIsEmpty) else {
                server.respondTool(id: id, success: false, text: "The terminal prompt or working directory changed; insertion was refused.")
                return
            }
            insertTerminalText(command, on: surface)
            surface.focus()
            server.respondTool(
                id: id,
                success: true,
                text: "The command was suggested to the user and left unexecuted at the shell prompt. No task was performed and no output was produced. The user must run it themselves if they choose.")
        case .run:
            guard let command = validTerminalCommand(arguments["command"]) else {
                server.respondTool(id: id, success: false, text: "terminal.run requires one non-empty single-line command.")
                return
            }
            let reason = (arguments["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingTerminalRuns[id] = .init(requestID: id, command: command, surface: surface)
            approvals.append(.init(
                id: id,
                method: PromptTerminalTool.run.rawValue,
                summary: reason?.isEmpty == false ? reason! : command,
                richBlockID: terminalRichBlockID))
        }
    }

    private func validTerminalCommand(_ value: Any?) -> String? {
        guard let command = value as? String,
              PromptSuggestedCommand.isValid(command) else { return nil }
        return command
    }

    private func readableFileURL(path: String, within cwd: String) -> URL? {
        guard !path.contains("\0") else { return nil }
        let root = URL(fileURLWithPath: cwd, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path, relativeTo: root)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: candidate.path) else { return nil }
        return candidate
    }

    private func declinePendingTerminalRuns(reason: String) {
        for pending in pendingTerminalRuns.values {
            server.respondTool(id: pending.requestID, success: false, text: reason)
        }
        let ids = Set(pendingTerminalRuns.keys)
        approvals.removeAll { ids.contains($0.id) }
        pendingTerminalRuns.removeAll()
    }

    private static func describeRateLimits(_ raw: [String: Any]) -> String {
        let limits = raw["rateLimits"] as? [String: Any] ?? raw
        func percent(_ key: String) -> String? {
            guard let window = limits[key] as? [String: Any] else { return nil }
            if let used = window["usedPercent"] as? Double { return "\(Int(100 - used))% left" }
            if let used = window["usedPercent"] as? Int { return "\(100 - used)% left" }
            return nil
        }
        return percent("primary") ?? percent("secondary") ?? "Limits available"
    }

    nonisolated static func terminalDisplayResponse(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["response:", "**response:**"]
        let lowercased = trimmed.lowercased()

        let withoutLabel: String
        if let prefix = prefixes.first(where: { lowercased.hasPrefix($0) }) {
            withoutLabel = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            withoutLabel = trimmed
        }
        return PromptAIOutputSanitizer.sanitize(withoutLabel)
    }

    private static func commandText(from item: [String: Any]) -> String? {
        if let command = item["command"] as? String { return command }
        if let command = item["command"] as? [String] { return command.joined(separator: " ") }
        return nil
    }

}

enum PromptAIOutputSanitizer {
    private static let documentFenceLanguages = [
        "markdown", "md", "gfm", "commonmark",
    ]

    /// Models sometimes wrap a complete rendered answer in a `markdown`
    /// code fence. Unwrap only that exact whole-document shape. Other fenced
    /// languages and partial/malformed fences remain literal user content.
    nonisolated static func sanitize(_ source: String) -> String {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0 ..< 2 {
            guard let unwrapped = unwrapMarkdownDocumentFence(value) else { break }
            value = unwrapped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private nonisolated static func unwrapMarkdownDocumentFence(_ source: String) -> String? {
        guard let firstBreak = source.firstIndex(of: "\n"),
              let lastBreak = source.lastIndex(of: "\n"),
              firstBreak < lastBreak else { return nil }

        let opening = String(source[..<firstBreak])
            .trimmingCharacters(in: .whitespaces)
        guard let marker = opening.first, marker == "`" || marker == "~" else { return nil }
        let markerCount = opening.prefix { $0 == marker }.count
        guard markerCount >= 3 else { return nil }

        let language = opening.dropFirst(markerCount)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard documentFenceLanguages.contains(language) else { return nil }

        let closing = String(source[source.index(after: lastBreak)...])
            .trimmingCharacters(in: .whitespaces)
        guard closing.count >= markerCount,
              closing.allSatisfy({ $0 == marker }) else { return nil }

        return String(source[source.index(after: firstBreak) ..< lastBreak])
    }
}
