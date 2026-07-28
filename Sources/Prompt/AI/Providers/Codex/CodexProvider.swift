import AppKit
import Foundation
#if DEBUG
import SwiftUI
#endif

@MainActor
final class CodexProvider: ConversationProviding {
    static let shared = CodexProvider()

    let descriptor = AIProviderDescriptor(
        id: .codex,
        displayName: "ChatGPT (Codex)",
        systemImage: "sparkles",
        capabilities: [.assistant, .agent],
        traits: [
            .streaming, .cancellation, .structuredOutput, .toolCalling,
            .persistentSessions, .modelDiscovery, .accountInformation,
        ])

    private(set) var status: AIProviderStatus = .stopped {
        didSet { AIProviderRegistry.shared.providerStatusDidChange() }
    }
    let client = CodexRPCClient(service: "ChatGPT (Codex)")
    private let execClient = CodexExecClient()
    private var authProcess: Process?

    private init() {}

    func start(cwd: String) {
        guard status != .starting, !status.isReady else { return }
        status = .starting
        readLoginStatus { [weak self] signedIn, detail in
            guard let self else { return }
            status = signedIn
                ? .ready(account: "ChatGPT")
                : .unavailable(.authenticationRequired)
            #if DEBUG
                PromptAIDebug.emit(
                    "ChatGPT (Codex)", "authentication",
                    detail.isEmpty ? (signedIn ? "signed in" : "sign-in required") : detail)
            #endif
        }
    }

    func stop() {
        execClient.cancelAll()
        authProcess?.terminate()
        authProcess = nil
        status = .stopped
    }

    func repairAction(for capability: AICapability) -> AIProviderRepairAction? {
        switch status {
        case .unavailable(.runtimeMissing): .installRuntime(
                name: "Codex CLI",
                url: URL(string: "https://developers.openai.com/codex/cli")!)
        case .unavailable(.authenticationRequired), .unavailable(.invalidCredential):
            .authenticate
        case .failed: .retry
        default: nil
        }
    }

    func markStarting() {
        status = .starting
    }

    func markReady(account: String? = nil) {
        status = .ready(account: account)
    }

    func markUnavailable(_ issue: AIAvailabilityIssue) {
        status = .unavailable(issue)
    }

    func markFailed(_ message: String) {
        status = .failed(message)
    }

    func startLogin(completion: @escaping (String) -> Void) {
        guard authProcess == nil else {
            completion("A ChatGPT sign-in is already in progress.")
            return
        }
        guard let executableURL = CodexExecClient.executableURL else {
            completion("The Codex CLI was not found.")
            return
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["login"]
        process.environment = CodexExecClient.environment()
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.authProcess = nil
                if process.terminationStatus == 0 {
                    self?.refreshAccount(completion: { _ in })
                } else {
                    self?.markUnavailable(.authenticationRequired)
                }
            }
        }
        do {
            try process.run()
            authProcess = process
            completion("Browser sign-in started. Complete it in your browser, then click Check Account.")
        } catch {
            completion("Could not start sign-in: \(error.localizedDescription)")
        }
    }

    func refreshAccount(completion: @escaping (String) -> Void) {
        readLoginStatus { [weak self] signedIn, detail in
            self?.status = signedIn
                ? .ready(account: "ChatGPT")
                : .unavailable(.authenticationRequired)
            completion(signedIn ? detail : "No ChatGPT account is signed in.")
        }
    }

    func logout(completion: @escaping (String) -> Void) {
        guard let executableURL = CodexExecClient.executableURL else {
            completion("The Codex CLI was not found.")
            return
        }
        runCLI(executableURL: executableURL, arguments: ["logout"]) { [weak self] status, output in
            if status == 0 {
                self?.markUnavailable(.authenticationRequired)
                completion(output.isEmpty ? "Signed out." : output)
            } else {
                completion(output.isEmpty ? "Could not sign out." : output)
            }
        }
    }

    func respond(
        to request: ConversationRequest,
        onEvent: @escaping (ConversationEvent) -> Void
    ) -> UUID {
        execClient.run(request, onEvent: onEvent)
    }

    func cancel(requestID: UUID) {
        execClient.cancel(requestID)
    }

    private func readLoginStatus(completion: @escaping (Bool, String) -> Void) {
        guard let executableURL = CodexExecClient.executableURL else {
            status = .unavailable(.runtimeMissing("Codex CLI"))
            completion(false, "The Codex CLI was not found.")
            return
        }
        runCLI(executableURL: executableURL, arguments: ["login", "status"]) { code, output in
            completion(code == 0, output)
        }
    }

    private func runCLI(
        executableURL: URL,
        arguments: [String],
        completion: @escaping (Int32, String) -> Void
    ) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = CodexExecClient.environment()
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { process in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in completion(process.terminationStatus, text) }
        }
        do {
            try process.run()
        } catch {
            completion(-1, error.localizedDescription)
        }
    }
}

#if DEBUG
extension CodexProvider: AIDebugPageProviding {
    var debugPageTitle: String { "ChatGPT (Codex)" }
    func makeDebugPage() -> AnyView {
        AnyView(CodexDebugPage())
    }
}
#endif
