import Foundation
import Logging

/// Application-wide logging backed by bounded files in `~/.prompt/logs`.
enum PromptLogging {
    static let directory = PromptPaths().root.appendingPathComponent("logs", isDirectory: true)
    static let currentFile = directory.appendingPathComponent("prompt.log")

    private static let lock = NSLock()
    private static var isBootstrapped = false

    static func bootstrap() {
        lock.withLock {
            guard !isBootstrapped else { return }
            LoggingSystem.bootstrap { label in
                PromptFileLogHandler(label: label)
            }
            isBootstrapped = true
        }

        NSSetUncaughtExceptionHandler { exception in
            let logger = Logger(label: "net.leukert.prompt.crash")
            logger.critical(
                "Uncaught Objective-C exception",
                metadata: [
                    "name": "\(exception.name.rawValue)",
                    "reason": "\(exception.reason ?? "No reason provided")",
                    "stack": "\(exception.callStackSymbols.joined(separator: " | "))",
                ])
        }
    }
}

enum PromptLog {
    static var application: Logger { Logger(label: "net.leukert.prompt.application") }
    static var persistence: Logger { Logger(label: "net.leukert.prompt.persistence") }
    static var sessions: Logger { Logger(label: "net.leukert.prompt.sessions") }
    static var terminal: Logger { Logger(label: "net.leukert.prompt.terminal") }
    static var commandPalette: Logger { Logger(label: "net.leukert.prompt.command-palette") }
    static var tailnet: Logger { Logger(label: "net.leukert.prompt.tailnet") }
}

private struct PromptFileLogHandler: LogHandler {
    private static let backend = PromptLogFileBackend()

    let label: String
    var metadata: Logger.Metadata = [:]
    var metadataProvider: Logger.MetadataProvider?
    var logLevel: Logger.Level

    init(label: String) {
        self.label = label
        #if DEBUG
            logLevel = .debug
        #else
            logLevel = .info
        #endif
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var combinedMetadata = metadata
        metadataProvider?.get().forEach { combinedMetadata[$0.key] = $0.value }
        event.metadata?.forEach { combinedMetadata[$0.key] = $0.value }
        if let error = event.error {
            combinedMetadata["error"] = "\(error)"
        }
        Self.backend.write(
            level: event.level,
            label: label,
            message: event.message.description,
            metadata: combinedMetadata,
            file: URL(fileURLWithPath: event.file).lastPathComponent,
            function: event.function,
            line: event.line)
    }
}

private final class PromptLogFileBackend: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()
    private let maximumFileSize: UInt64 = 5 * 1_024 * 1_024
    private let retainedFileCount = 5
    private var fileHandle: FileHandle?

    init() {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        lock.withLock { openFile() }
    }

    deinit {
        try? fileHandle?.close()
    }

    func write(
        level: Logger.Level,
        label: String,
        message: String,
        metadata: Logger.Metadata,
        file: String,
        function: String,
        line: UInt
    ) {
        lock.withLock {
            let metadataText = metadata.keys.sorted().map {
                "\($0)=\(sanitize(metadata[$0]?.description ?? ""))"
            }.joined(separator: " ")
            let context = "\(file):\(line) \(function)"
            let suffix = metadataText.isEmpty ? "" : " \(metadataText)"
            let entry = "\(formatter.string(from: Date())) [\(level)] [\(label)] \(sanitize(message))\(suffix) — \(context)\n"
            guard let data = entry.data(using: .utf8) else { return }

            rotateIfNeeded(for: UInt64(data.count))
            if fileHandle == nil { openFile() }
            do {
                try fileHandle?.write(contentsOf: data)
                try fileHandle?.synchronize()
            } catch {
                writeToStandardError("Prompt logging failed: \(error.localizedDescription)\n")
                try? fileHandle?.close()
                fileHandle = nil
            }
            #if DEBUG
                writeToStandardError(entry)
            #endif
        }
    }

    private func openFile() {
        do {
            try fileManager.createDirectory(
                at: PromptLogging.directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if !fileManager.fileExists(atPath: PromptLogging.currentFile.path) {
                fileManager.createFile(
                    atPath: PromptLogging.currentFile.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: PromptLogging.currentFile)
            try handle.seekToEnd()
            fileHandle = handle
        } catch {
            writeToStandardError("Prompt could not open its log file: \(error.localizedDescription)\n")
        }
    }

    private func rotateIfNeeded(for incomingSize: UInt64) {
        let currentSize = (try? PromptLogging.currentFile.resourceValues(
            forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        guard currentSize + incomingSize > maximumFileSize else { return }

        try? fileHandle?.close()
        fileHandle = nil
        for index in stride(from: retainedFileCount - 1, through: 1, by: -1) {
            let source = rotatedFile(index)
            let destination = rotatedFile(index + 1)
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: destination)
            }
        }
        if fileManager.fileExists(atPath: PromptLogging.currentFile.path) {
            try? fileManager.moveItem(at: PromptLogging.currentFile, to: rotatedFile(1))
        }
        openFile()
    }

    private func rotatedFile(_ index: Int) -> URL {
        PromptLogging.directory.appendingPathComponent("prompt.\(index).log")
    }

    private func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func writeToStandardError(_ value: String) {
        FileHandle.standardError.write(Data(value.utf8))
    }
}
