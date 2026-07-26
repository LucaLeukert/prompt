import AppKit
import CoreText
import Darwin
import GhosttyKit
import MarkdownUI
import SwiftMath
import SwiftUI

final class CodexAppServer {
    enum ServerError: LocalizedError {
        case executableMissing, exited, response(String)
        var errorDescription: String? {
            switch self {
            case .executableMissing: "The Codex CLI was not found."
            case .exited: "Codex app-server exited."
            case .response(let value): value
            }
        }
    }

    var onNotification: (([String: Any]) -> Void)?
    var onServerRequest: (([String: Any]) -> Void)?
    private let service: String
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var callbacks: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private let queue = DispatchQueue(label: "dev.prompt.codex-app-server")

    init(service: String) {
        self.service = service
        #if DEBUG
            PromptAIDebug.emit(service, "state", "service created")
        #endif
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        #if DEBUG
            PromptAIDebug.emit(service, "state", "locating Codex CLI")
        #endif
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            #if DEBUG
                PromptAIDebug.emit(service, "error", "Codex CLI not found")
            #endif
            completion(.failure(ServerError.executableMissing)); return
        }
        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process
        self.input = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let value = String(data: data, encoding: .utf8) else { return }
            #if DEBUG
                PromptAIDebug.emit(self?.service ?? "Unknown", "stderr", value.trimmingCharacters(in: .whitespacesAndNewlines))
            #endif
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                PromptLog.application.warning(
                    "AI app server exited",
                    metadata: ["service": "\(self?.service ?? "unknown")"])
                #if DEBUG
                    if let self { PromptAIDebug.emit(self.service, "error", "app-server exited") }
                #endif
                self?.process = nil
            }
        }
        do {
            try process.run()
            #if DEBUG
                PromptAIDebug.emit(service, "state", "app-server launched · pid \(process.processIdentifier)")
            #endif
        } catch {
            PromptLog.application.error(
                "AI app server launch failed",
                metadata: [
                    "error": "\(error)",
                    "service": "\(service)",
                ])
            #if DEBUG
                PromptAIDebug.emit(service, "error", "launch failed: \(error.localizedDescription)")
            #endif
            completion(.failure(error)); return
        }
        request("initialize", params: [
            "clientInfo": ["name": "prompt", "title": "Prompt", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true, "requestAttestation": false],
        ]) { [weak self] result in
            switch result {
            case .success:
                #if DEBUG
                    PromptAIDebug.emit(self?.service ?? "Unknown", "state", "initialize succeeded")
                #endif
                self?.notify("initialized", params: [:])
                completion(.success(()))
            case .failure(let error):
                #if DEBUG
                    PromptAIDebug.emit(self?.service ?? "Unknown", "error", "initialize failed: \(error.localizedDescription)")
                #endif
                completion(.failure(error))
            }
        }
    }

    func request(_ method: String, params: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let id = String(nextID); nextID += 1
        callbacks[id] = completion
        #if DEBUG
            PromptAIDebug.emit(service, "request", "#\(id) → \(method) · \(params.keys.sorted().joined(separator: ", "))")
        #endif
        write(["id": Int(id)!, "method": method, "params": params])
    }

    func notify(_ method: String, params: [String: Any]) {
        write(["method": method, "params": params])
    }

    func respond(id: String, result: [String: Any]) {
        let value: Any = Int(id) ?? id
        write(["id": value, "result": result])
    }

    func respondTool(id: String, success: Bool, text: String) {
        respond(id: id, result: [
            "contentItems": [["type": "inputText", "text": text]],
            "success": success,
        ])
    }

    private func write(_ value: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(value), var data = try? JSONSerialization.data(withJSONObject: value) else { return }
        data.append(0x0A)
        queue.async { [weak self] in try? self?.input?.write(contentsOf: data) }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                DispatchQueue.main.async { self.route(object) }
            }
        }
    }

    private func route(_ value: [String: Any]) {
        if let id = Self.stringID(value["id"]), let callback = callbacks.removeValue(forKey: id), value["method"] == nil {
            if let error = value["error"] as? [String: Any] {
                #if DEBUG
                    PromptAIDebug.emit(service, "error", "#\(id) ← \(error["message"] as? String ?? "request failed")")
                #endif
                callback(.failure(ServerError.response(error["message"] as? String ?? "Codex request failed")))
            } else {
                #if DEBUG
                    let result = value["result"] as? [String: Any] ?? [:]
                    PromptAIDebug.emit(service, "response", "#\(id) ← success · \(result.keys.sorted().joined(separator: ", "))")
                #endif
                callback(.success(value["result"] as? [String: Any] ?? [:]))
            }
        } else if value["id"] != nil, value["method"] != nil {
            #if DEBUG
                PromptAIDebug.emit(service, "server request", value["method"] as? String ?? "unknown")
            #endif
            onServerRequest?(value)
        } else {
            #if DEBUG
                if let method = value["method"] as? String, !method.contains("delta") {
                    if method == "error",
                       let params = value["params"],
                       JSONSerialization.isValidJSONObject(params),
                       let data = try? JSONSerialization.data(withJSONObject: params),
                       let detail = String(data: data, encoding: .utf8) {
                        PromptAIDebug.emit(service, "error", "error · \(detail)")
                    } else {
                        PromptAIDebug.emit(service, "notification", method)
                    }
                }
            #endif
            onNotification?(value)
        }
    }

    static func stringID(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? Int { return String(value) }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}

/// Minimal client for GitHub's official Copilot Language Server. It uses only
/// the inline-completion LSP method, which is the completion entitlement rather
/// than Copilot Chat or agent requests.
