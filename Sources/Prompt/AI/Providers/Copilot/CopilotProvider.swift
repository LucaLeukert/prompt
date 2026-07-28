import Foundation
#if DEBUG
    import SwiftUI
#endif

@MainActor
final class CopilotProvider: AutocompleteProviding, ConversationProviding {
    static let shared = CopilotProvider()

    let descriptor = AIProviderDescriptor(
        id: .copilot,
        displayName: "GitHub Copilot",
        systemImage: "text.cursor",
        capabilities: [.assistant, .autocomplete],
        traits: [.cancellation])

    private(set) var status: AIProviderStatus = .stopped {
        didSet { AIProviderRegistry.shared.providerStatusDidChange() }
    }
    private let completionServer = CopilotCompletionServer()
    private var assistantProcesses: [UUID: Process] = [:]
    private var capabilityStatuses: [AICapability: AIProviderStatus] = [
        .assistant: .stopped,
        .autocomplete: .stopped,
    ]

    private init() {
        completionServer.onStatus = { [weak self] value in
            guard let self else { return }
            if value == "Copilot ready" {
                capabilityStatuses[.autocomplete] = .ready(account: nil)
            } else if value.contains("Install Node.js") {
                capabilityStatuses[.autocomplete] =
                    .unavailable(.runtimeMissing("GitHub Copilot Language Server"))
            } else if value.contains("Unable") || value.contains("exited") {
                capabilityStatuses[.autocomplete] = .failed(value)
            }
            refreshOverallStatus()
            #if DEBUG
                PromptAIDebug.emit("GitHub Copilot", "status", value)
            #endif
        }
    }

    func start(cwd: String) {
        guard capabilityStatuses[.autocomplete]?.isReady != true,
              capabilityStatuses[.autocomplete] != .starting else { return }
        status = .starting
        capabilityStatuses[.assistant] = Self.findCopilotCLI() == nil
            ? .unavailable(.runtimeMissing("GitHub Copilot CLI"))
            : .ready(account: nil)
        capabilityStatuses[.autocomplete] = .starting
        refreshOverallStatus()
        completionServer.start(cwd: cwd)
    }

    func stop() {
        completionServer.stop()
        status = .stopped
        capabilityStatuses[.assistant] = .stopped
        capabilityStatuses[.autocomplete] = .stopped
    }

    func status(for capability: AICapability) -> AIProviderStatus {
        capabilityStatuses[capability]
            ?? .unavailable(.incompatibleRuntime("Capability is not supported"))
    }

    func repairAction(for capability: AICapability) -> AIProviderRepairAction? {
        switch status {
        case .unavailable(.runtimeMissing):
            .installRuntime(
                name: "GitHub Copilot Language Server",
                url: URL(string: "https://github.com/github/copilot-language-server-release")!)
        case .unavailable(.authenticationRequired), .unavailable(.invalidCredential):
            .authenticate
        case .failed: .retry
        default: nil
        }
    }

    func complete(
        _ request: AutocompleteRequest,
        completion: @escaping (Result<[AutocompleteCandidate], Error>) -> Void
    ) {
        completionServer.complete(
            prefix: request.prefix,
            cwd: request.cwd,
            terminal: request.terminal
        ) { values in
            completion(.success(values.enumerated().compactMap {
                guard !Self.isNoOpCompletion(
                    prefix: request.prefix,
                    suffix: $0.element,
                    cwd: request.cwd
                ) else {
                    #if DEBUG
                        PromptAIDebug.emit(
                            "Copilot Completion",
                            "filtered",
                            "Discarded no-op completion: \(request.prefix)\($0.element)")
                    #endif
                    return nil
                }
                return AutocompleteCandidate(text: $0.element, providerIndex: $0.offset)
            }))
        }
    }

    nonisolated static func isNoOpCompletion(prefix: String, suffix: String, cwd: String) -> Bool {
        let command = (prefix + suffix)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard command == "cd" || command.hasPrefix("cd ") || command.hasPrefix("cd\t") else {
            return false
        }
        var destination = String(command.dropFirst(2))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        destination = destination.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"'"))
        if ["", ".", "$PWD", "${PWD}"].contains(destination) { return true }
        guard !destination.hasPrefix("-"), !destination.contains(" ") else { return false }

        let base = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        let resolved: URL
        if destination.hasPrefix("/") {
            resolved = URL(fileURLWithPath: destination, isDirectory: true).standardizedFileURL
        } else {
            resolved = base.appendingPathComponent(destination, isDirectory: true)
                .standardizedFileURL
        }
        return resolved.path == base.path
    }

    func accepted(_ candidate: AutocompleteCandidate) {
        completionServer.accept(index: candidate.providerIndex)
    }

    func respond(
        to request: ConversationRequest,
        onEvent: @escaping (ConversationEvent) -> Void
    ) -> UUID {
        let id = UUID()
        guard let executable = Self.findCopilotCLI() else {
            onEvent(.failed("Install GitHub Copilot CLI to use Copilot Assistant."))
            return id
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "-p",
            """
            \(request.instructions)

            Respond as an assistant only. Do not execute commands or modify files.
            User request: \(request.text)
            Current directory: \(request.projectRoot)
            <terminal_output>
            \(String(request.terminalContext.suffix(12_000)))
            </terminal_output>
            """,
            "-s",
            "--model", request.modelID,
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: request.projectRoot)
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] finished in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            let errorText = String(data: errorData, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self?.assistantProcesses[id] = nil
                if finished.terminationStatus == 0 {
                    if !text.isEmpty { onEvent(.textDelta(text)) }
                    onEvent(.completed)
                } else {
                    onEvent(.failed(errorText.isEmpty ? "Copilot Assistant failed." : errorText))
                }
            }
        }
        do {
            try process.run()
            assistantProcesses[id] = process
        } catch {
            onEvent(.failed(error.localizedDescription))
        }
        return id
    }

    func cancel(requestID: UUID) {
        assistantProcesses.removeValue(forKey: requestID)?.terminate()
    }

    private static func findCopilotCLI() -> String? {
        [
            "/opt/homebrew/bin/copilot",
            "/usr/local/bin/copilot",
            "/usr/bin/copilot",
        ].first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private func refreshOverallStatus() {
        let values = capabilityStatuses.values
        if values.contains(where: \.isReady) {
            status = .ready(account: nil)
        } else if let failure = values.first(where: {
            if case .failed = $0 { return true }
            return false
        }) {
            status = failure
        } else if let unavailable = values.first(where: {
            if case .unavailable = $0 { return true }
            return false
        }) {
            status = unavailable
        } else {
            status = .starting
        }
    }
}

#if DEBUG
    extension CopilotProvider: AIDebugPageProviding {
        var debugPageTitle: String { "GitHub Copilot" }
        func makeDebugPage() -> AnyView { AnyView(CopilotDebugPage()) }
    }
#endif
