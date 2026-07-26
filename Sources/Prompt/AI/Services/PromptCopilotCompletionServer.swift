import AppKit
import CoreText
import Darwin
import GhosttyKit
import MarkdownUI
import SwiftMath
import SwiftUI

final class PromptCopilotCompletionServer {
    var onStatus: ((String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var callbacks: [Int: (Any?) -> Void] = [:]
    private let queue = DispatchQueue(label: "dev.prompt.copilot-lsp")
    private var initialized = false
    private var starting = false
    private var workspace = FileManager.default.homeDirectoryForCurrentUser.path
    private var documentURI = ""
    private var documentVersion = 0
    private var pendingCompletion: (prefix: String, cwd: String, terminal: String, completion: ([String]) -> Void)?
    private var completionItems: [[String: Any]] = []
    private var signInStarted = false
    private var consecutiveLaunchFailures = 0
    private var retryAfter = Date.distantPast

    func start(cwd: String) {
        workspace = cwd == "/" ? FileManager.default.homeDirectoryForCurrentUser.path : cwd
        guard process == nil, !starting, Date() >= retryAfter else { return }
        starting = true
        onStatus?("Starting GitHub Copilot Language Server")
        #if DEBUG
            PromptAIDebug.emit("Copilot Completion", "state", "locating language server")
        #endif

        let executable: String
        let arguments: [String]
        let candidates = [
            "/opt/homebrew/bin/copilot-language-server",
            "/usr/local/bin/copilot-language-server",
        ]
        if let native = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            executable = native
            arguments = ["--stdio"]
        } else if let npx = Self.findNPX() {
            executable = npx
            arguments = ["--yes", "@github/copilot-language-server@1.524.0", "--stdio"]
        } else {
            starting = false
            onStatus?("Install Node.js or copilot-language-server to enable completions")
            #if DEBUG
                PromptAIDebug.emit("Copilot Completion", "error", "npx and copilot-language-server were not found")
            #endif
            return
        }

        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        var environment = ProcessInfo.processInfo.environment
        let executableDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [
            executableDirectory,
            inheritedPath,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ].joined(separator: ":")
        process.environment = environment
        input = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [weak self] in self?.consume($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let value = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.onStatus?(value.trimmingCharacters(in: .whitespacesAndNewlines))
                #if DEBUG
                    PromptAIDebug.emit("Copilot Completion", "stderr", value.trimmingCharacters(in: .whitespacesAndNewlines))
                #endif
            }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.process = nil
                self?.initialized = false
                self?.starting = false
                self?.callbacks.removeAll()
                if process.terminationStatus != 0 {
                    self?.consecutiveLaunchFailures += 1
                    let failures = self?.consecutiveLaunchFailures ?? 1
                    self?.retryAfter = Date().addingTimeInterval(min(30, pow(2, Double(failures))))
                }
                self?.onStatus?("Copilot Language Server exited (\(process.terminationStatus))")
                #if DEBUG
                    PromptAIDebug.emit("Copilot Completion", "error", "language server exited · \(process.terminationStatus)")
                #endif
            }
        }
        do {
            try process.run()
            self.process = process
            #if DEBUG
                PromptAIDebug.emit("Copilot Completion", "state", "language server launched · pid \(process.processIdentifier)")
            #endif
            initialize()
        } catch {
            starting = false
            onStatus?("Unable to launch Copilot: \(error.localizedDescription)")
            #if DEBUG
                PromptAIDebug.emit("Copilot Completion", "error", "launch failed: \(error.localizedDescription)")
            #endif
        }
    }

    func complete(prefix: String, cwd: String, terminal: String, completion: @escaping ([String]) -> Void) {
        start(cwd: cwd)
        pendingCompletion = (prefix, cwd, terminal, completion)
        guard initialized else { return }
        requestCompletion(prefix: prefix, cwd: cwd, terminal: terminal, completion: completion)
    }

    func accept(index: Int) {
        guard completionItems.indices.contains(index),
              let command = completionItems[index]["command"] as? [String: Any] else { return }
        var params: [String: Any] = ["command": command["command"] as? String ?? "github.copilot.didAcceptCompletionItem"]
        if let arguments = command["arguments"] { params["arguments"] = arguments }
        request("workspace/executeCommand", params: params) { _ in }
    }

    private func initialize() {
        let workspaceURI = URL(fileURLWithPath: workspace, isDirectory: true).absoluteString
        request("initialize", params: [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "workspaceFolders": [["uri": workspaceURI, "name": URL(fileURLWithPath: workspace).lastPathComponent]],
            "capabilities": [
                "workspace": ["workspaceFolders": true, "configuration": true],
                "window": ["showDocument": ["support": true]],
                "textDocument": ["inlineCompletion": [:]],
            ],
            "initializationOptions": [
                "editorInfo": ["name": "Prompt", "version": "0.1.0"],
                "editorPluginInfo": ["name": "Prompt Copilot Completion", "version": "0.1.0"],
            ],
        ]) { [weak self] result in
            guard let self, result != nil else {
                self?.onStatus?("Copilot initialization failed")
                return
            }
            initialized = true
            starting = false
            consecutiveLaunchFailures = 0
            retryAfter = .distantPast
            notify("initialized", params: [:])
            notify("workspace/didChangeConfiguration", params: ["settings": [:]])
            onStatus?("Copilot ready")
            #if DEBUG
                PromptAIDebug.emit("Copilot Completion", "state", "initialize succeeded")
            #endif
            if let pending = pendingCompletion {
                requestCompletion(prefix: pending.prefix, cwd: pending.cwd, terminal: pending.terminal, completion: pending.completion)
            }
        }
    }

    private func requestCompletion(prefix: String, cwd: String, terminal: String, completion: @escaping ([String]) -> Void) {
        if workspace != cwd {
            let oldURI = URL(fileURLWithPath: workspace, isDirectory: true).absoluteString
            let newURL = URL(fileURLWithPath: cwd, isDirectory: true)
            notify("workspace/didChangeWorkspaceFolders", params: ["event": [
                "removed": [["uri": oldURI, "name": URL(fileURLWithPath: workspace).lastPathComponent]],
                "added": [["uri": newURL.absoluteString, "name": newURL.lastPathComponent]],
            ]])
            workspace = cwd
        }
        let uri = URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(".prompt-terminal.sh").absoluteString
        let context = PromptCompletionContextEngine.build(prefix: prefix, cwd: cwd, terminal: terminal)
        let document = context.document
        let commandLine = context.commandLine
        documentVersion += 1
        if documentURI != uri {
            if !documentURI.isEmpty { notify("textDocument/didClose", params: ["textDocument": ["uri": documentURI]]) }
            documentURI = uri
            notify("textDocument/didOpen", params: ["textDocument": [
                "uri": uri, "languageId": "shellscript", "version": documentVersion, "text": document,
            ]])
            notify("textDocument/didFocus", params: ["textDocument": ["uri": uri]])
        } else {
            notify("textDocument/didChange", params: [
                "textDocument": ["uri": uri, "version": documentVersion],
                "contentChanges": [["text": document]],
            ])
        }
        let requestPrefix = prefix
        request("textDocument/inlineCompletion", params: [
            "textDocument": ["uri": uri, "version": documentVersion],
            "position": ["line": commandLine, "character": context.cursorCharacter],
            "context": ["triggerKind": 2],
            "formattingOptions": ["tabSize": 4, "insertSpaces": true],
        ]) { [weak self] result in
            guard let self, pendingCompletion?.prefix == requestPrefix else { return }
            let items: [[String: Any]]
            if let object = result as? [String: Any] {
                items = object["items"] as? [[String: Any]] ?? []
            } else {
                items = result as? [[String: Any]] ?? []
            }
            let values = items.compactMap { item -> String? in
                let edit = item["textEdit"] as? [String: Any]
                guard let text = item["insertText"] as? String ?? edit?["newText"] as? String else { return nil }
                let suffix = PromptAutocompleteModel.clean(
                    text,
                    prefix: requestPrefix,
                    expectsSuffixOnly: context.expectsSuffixOnly)
                return suffix.isEmpty ? nil : suffix
            }
            completionItems = items
            if let item = items.first {
                notify("textDocument/didShowCompletion", params: ["item": item])
            }
            #if DEBUG
                let shape = result is [[String: Any]]
                    ? "array"
                    : "object[\(((result as? [String: Any])?.keys.sorted().joined(separator: ",")) ?? "")]"
                PromptAIDebug.emit("Copilot Completion", "completion", "\(values.count) suggestion(s) · \(shape) · \(items.first?.keys.sorted().joined(separator: ",") ?? "no item") · input: \(String(requestPrefix.prefix(300)))")
                PromptAIDebug.emit("Copilot Completion", "context", "\(context.pathCandidates.count) path(s), \(context.executableCandidates.count) executable(s) · \(String(document.prefix(4_000)))")
            #endif
            guard !values.isEmpty else {
                self.requestPanelCompletion(
                    prefix: requestPrefix,
                    uri: uri,
                    version: self.documentVersion,
                    line: commandLine,
                    character: context.cursorCharacter,
                    expectsSuffixOnly: context.expectsSuffixOnly,
                    completion: completion)
                return
            }
            completion(Array(values.prefix(3)))
        }
    }

    private func requestPanelCompletion(
        prefix: String,
        uri: String,
        version: Int,
        line: Int,
        character: Int,
        expectsSuffixOnly: Bool,
        completion: @escaping ([String]) -> Void
    ) {
        request("textDocument/copilotPanelCompletion", params: [
            "textDocument": ["uri": uri, "version": version],
            "position": ["line": line, "character": character],
        ]) { [weak self] result in
            guard let self else { return }
            guard pendingCompletion?.prefix == prefix else { return }
            publishPanelItems(
                Self.completionItems(from: result),
                prefix: prefix,
                expectsSuffixOnly: expectsSuffixOnly,
                completion: completion)
        }
    }

    private func publishPanelItems(
        _ items: [[String: Any]],
        prefix: String,
        expectsSuffixOnly: Bool,
        completion: @escaping ([String]) -> Void
    ) {
        completionItems = items
        var seen = Set<String>()
        let values = items.compactMap { item -> String? in
            let edit = item["textEdit"] as? [String: Any]
            guard let text = item["insertText"] as? String ?? edit?["newText"] as? String else { return nil }
            let suffix = PromptAutocompleteModel.clean(
                text,
                prefix: prefix,
                expectsSuffixOnly: expectsSuffixOnly)
            guard !suffix.isEmpty, seen.insert(suffix).inserted else { return nil }
            return suffix
        }
        #if DEBUG
            PromptAIDebug.emit(
                "Copilot Completion",
                "panel completion",
                "\(values.count) suggestion(s) · \(items.count) returned item(s) · input: \(String(prefix.prefix(300)))")
        #endif
        completion(Array(values.prefix(3)))
    }

    private static func completionItems(from value: Any?) -> [[String: Any]] {
        if let items = value as? [[String: Any]] { return items }
        guard let object = value as? [String: Any] else { return [] }
        if let items = object["items"] as? [[String: Any]] { return items }
        if let value = object["value"] { return completionItems(from: value) }
        return []
    }

    private func request(_ method: String, params: [String: Any], completion: @escaping (Any?) -> Void) {
        let id = nextID
        nextID += 1
        callbacks[id] = completion
        #if DEBUG
            PromptAIDebug.emit("Copilot Completion", "request", "#\(id) → \(method)")
        #endif
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func notify(_ method: String, params: [String: Any]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func write(_ value: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: value) else { return }
        var framed = Data("Content-Length: \(json.count)\r\n\r\n".utf8)
        framed.append(json)
        queue.async { [weak self] in try? self?.input?.write(contentsOf: framed) }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            buffer.append(data)
            while let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                guard let lengthLine = header.components(separatedBy: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") }),
                    let length = Int(lengthLine.split(separator: ":", maxSplits: 1)[1]
                        .trimmingCharacters(in: .whitespaces)) else {
                    buffer.removeSubrange(..<headerEnd.upperBound)
                    continue
                }
                guard buffer.count >= headerEnd.upperBound + length else { break }
                let body = buffer.subdata(in: headerEnd.upperBound ..< (headerEnd.upperBound + length))
                buffer.removeSubrange(..<(headerEnd.upperBound + length))
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { continue }
                DispatchQueue.main.async { self.route(object) }
            }
        }
    }

    private func route(_ value: [String: Any]) {
        if let id = (value["id"] as? NSNumber)?.intValue ?? value["id"] as? Int,
           value["method"] == nil,
           let callback = callbacks.removeValue(forKey: id) {
            #if DEBUG
                if let error = value["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "request failed"
                    PromptAIDebug.emit(
                        "Copilot Completion",
                        message.contains("superseded") ? "cancelled" : "error",
                        "#\(id) ← \(message)")
                } else { PromptAIDebug.emit("Copilot Completion", "response", "#\(id) ← success") }
            #endif
            callback(value["result"])
            return
        }
        guard let method = value["method"] as? String else { return }
        let params = value["params"] as? [String: Any] ?? [:]
        if value["id"] != nil {
            let id = value["id"] as Any
            switch method {
            case "workspace/configuration": respond(id: id, result: [])
            case "window/showDocument":
                if let uri = params["uri"] as? String, let url = URL(string: uri) { NSWorkspace.shared.open(url) }
                respond(id: id, result: ["success": true])
            case "window/showMessageRequest": respond(id: id, result: NSNull())
            default: respond(id: id, result: NSNull())
            }
        } else if method == "didChangeStatus" {
            let kind = params["kind"] as? String ?? "Unknown"
            let message = params["message"] as? String ?? ""
            onStatus?("\(kind): \(message)")
            #if DEBUG
                PromptAIDebug.emit("Copilot Completion", kind == "Error" ? "error" : "status", "\(kind): \(message)")
            #endif
            if kind == "Error", !signInStarted { signIn() }
        } else if method == "window/logMessage" {
            #if DEBUG
                PromptAIDebug.emit("Copilot Completion", "log", params["message"] as? String ?? "")
            #endif
        }
    }

    private func respond(id: Any, result: Any) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func signIn() {
        signInStarted = true
        request("signIn", params: [:]) { [weak self] result in
            guard let self, let result = result as? [String: Any],
                  let command = result["command"] as? [String: Any] else { return }
            if let code = result["userCode"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                onStatus?("Sign-in code copied: \(code)")
            }
            request("workspace/executeCommand", params: command) { _ in }
        }
    }

    private static func findNPX() -> String? {
        let fm = FileManager.default
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("npx").path }
        let fixed = ["/opt/homebrew/bin/npx", "/usr/local/bin/npx"]
        if let value = (pathCandidates + fixed).first(where: fm.isExecutableFile(atPath:)) { return value }

        let versions = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/fnm/node-versions")
        guard let entries = try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) else { return nil }
        return entries.sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("installation/bin/npx").path }
            .first(where: fm.isExecutableFile(atPath:))
    }
}
