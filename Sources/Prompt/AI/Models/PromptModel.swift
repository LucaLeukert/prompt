import AppKit
import CoreText
import Darwin
import GhosttyKit
import MarkdownUI
import SwiftMath
import SwiftUI

@MainActor
final class PromptModel: ObservableObject {
    static let shared = PromptModel()
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

    let server = CodexAppServer(service: "Main AI")
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
    private var terminalRichBlockID: UUID?
    private var streamingMessageID: UUID?
    private var activeTurnID: String?
    private var cancelledTurnIDs: Set<String> = []
    private var cancelledTerminalRequestIDs: Set<UUID> = []
    private var activeToolCalls: [String: PromptToolCall] = [:]
    private var executedCommands: [String] = []
    private var activeRequestText = ""
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
        _ = PromptAmbientAnalyzer.shared
        server.onNotification = { [weak self] message in self?.handle(message) }
        server.onServerRequest = { [weak self] message in self?.handleRequest(message) }
    }

    func start(cwd: String) {
        projectRoot = ProjectResolver.resolve(from: cwd)
        PromptAutocompleteModel.shared.start(cwd: cwd)
        status = "Connecting to Codex app-server…"
        server.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                connected = true
                status = "Codex connected"
                refresh()
            case .failure(let error):
                status = "Codex unavailable"
                messages.append(.init(kind: .error, text: error.localizedDescription))
            }
        }
    }

    func refresh() {
        guard connected else { return }
        server.request("thread/list", params: [
            "limit": 50,
            "sortKey": "updated_at",
            "sortDirection": "desc",
            "cwd": projectRoot,
        ]) { [weak self] result in self?.loadThreads(result) }
        server.request("model/list", params: ["limit": 100, "includeHidden": true]) { [weak self] result in
            guard let self, let value = try? result.get() else { return }
            let data = value["data"] as? [[String: Any]] ?? []
            models = data.compactMap { ($0["model"] ?? $0["id"]) as? String }
        }
        server.request("account/read", params: ["refreshToken": false]) { [weak self] result in
            guard let self, let value = try? result.get() else { return }
            let raw = value["account"] as? [String: Any] ?? value
            account = (raw["email"] as? String) ?? (raw["planType"] as? String) ?? "ChatGPT account"
        }
        server.request("account/rateLimits/read", params: [:]) { [weak self] result in
            guard let self, let value = try? result.get() else { return }
            rateLimits = Self.describeRateLimits(value)
        }
    }

    func select(_ thread: PromptThread) {
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
        var params: [String: Any] = [
            "cwd": projectRoot,
            "approvalPolicy": "on-request",
            "sandbox": "workspace-write",
            "model": selectedModel.isEmpty ? NSNull() : selectedModel,
            "baseInstructions": PromptBuilder.baseInstructions,
            "developerInstructions": PromptBuilder.baseInstructions,
            "threadSource": "appServer",
        ]
        if let effort = selectedReasoningEffort { params["reasoningEffort"] = effort }
        server.request("thread/start", params: params) { [weak self] result in
            guard let self, let value = try? result.get(),
                  let thread = value["thread"] as? [String: Any],
                  let id = thread["id"] as? String else { return }
            activeThreadID = id
            messages = []
            status = "New Prompt thread"
            refresh()
        }
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
        guard !text.isEmpty, connected, !isRunning else { return }
        prompt = ""
        messages.append(.init(kind: .user, text: text))
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
            guard PromptTerminalSubmissionEligibility.allows(
                connected: connected,
                isRunning: isRunning) else {
                status = connected
                    ? "Finish the active Prompt turn before starting another."
                    : "Codex app-server is not connected yet."
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
            clearInput?()
            terminalRichBlockID = PromptRichContentStore.shared.begin(
                request: value,
                lane: lane,
                model: selectedModel.contains("spark") ? "Spark" : selectedModel,
                on: surface)
            // The rich block has its own reserved scrollback rows. Restore the
            // child shell prompt immediately so AI and shell work can proceed
            // independently on the same surface.
            if remote == nil || surface.isComposite { PromptController.pressReturn(on: surface) }
            messages.append(.init(kind: .user, text: value))
            createTerminalThreadThenSend(value)
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
        if let threadID = activeThreadID, let turnID = activeTurnID {
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

    private func createThenSend(_ text: String) {
        var params: [String: Any] = [
            "cwd": projectRoot,
            "approvalPolicy": "on-request",
            "sandbox": "workspace-write",
            "model": selectedModel.isEmpty ? NSNull() : selectedModel,
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
            "model": selectedModel.isEmpty ? NSNull() : selectedModel,
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
            "model": selectedModel.isEmpty ? NSNull() : selectedModel,
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
                displayResponse = object?["response"] as? String ?? rawResponse
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
        guard let id = CodexAppServer.stringID(message["id"]),
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

    private static func commandText(from item: [String: Any]) -> String? {
        if let command = item["command"] as? String { return command }
        if let command = item["command"] as? [String] { return command.joined(separator: " ") }
        return nil
    }

}
