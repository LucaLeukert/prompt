import Foundation
import Darwin

/// Headless tmux client used as the child process of a Ghostty surface.
/// Ghostty writes ordinary terminal input to this process. The bridge forwards
/// it to one tmux pane and writes that pane's decoded `%output` stream back to
/// Ghostty, leaving all visual layout under Prompt's control.
enum PromptTmuxControlBridge {
    static let argument = "--prompt-tmux-control-bridge"

    static func run(arguments: [String]) -> Never {
        guard arguments.count >= 6 else { exitWithMessage("Missing remote bridge arguments.") }
        configureRawInput()
        let destination = arguments[1]
        let session = arguments[2]
        let requestedPane = arguments[3] == "-" ? nil : arguments[3]
        let workingDirectory = arguments[4] == "-" ? nil : arguments[4]
        let attachOnly = arguments[5] == "attach"

        var tmux = attachOnly
            ? "exec tmux -C attach-session -t \(shellQuote(session))"
            : "exec tmux -C new-session -A -s \(shellQuote(session))"
        if let workingDirectory, !attachOnly {
            let directory: String
            if workingDirectory == "~" || workingDirectory == "~/" { directory = "\"$HOME\"" }
            else if workingDirectory.hasPrefix("~/") {
                directory = "\"$HOME\"/" + shellQuote(String(workingDirectory.dropFirst(2)))
            } else { directory = shellQuote(workingDirectory) }
            tmux += " -c \(directory)"
        }
        let sshArguments = [
            "-T", "-o", "ServerAliveInterval=20", "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=accept-new",
            destination, "sh", "-lc", shellQuote(tmux),
        ]
        var firstConnection = true
        while true {
            if !firstConnection {
                writeAll(FileHandle.standardOutput.fileDescriptor, Array("\r\nConnection lost; reconnecting to remote tmux…\r\n".utf8))
                Thread.sleep(forTimeInterval: 3)
            }
            firstConnection = false

            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArguments
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            do { try process.run() } catch { continue }

            let writer = PromptTmuxControlWriter(handle: input.fileHandleForWriting)
            let parser = PromptTmuxControlParser(requestedPane: requestedPane) { bytes in
                writeAll(FileHandle.standardOutput.fileDescriptor, bytes)
            }
            let outputHandle = output.fileHandleForReading
            outputHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                parser.consume(data)
                if let pane = parser.selectedPane { writer.select(pane: pane) }
            }
            writer.send("list-panes -F 'PROMPT_PANE=#{pane_id}:#{pane_active}'")

            var lastSize = (rows: 0, columns: 0)
            var inputClosed = false
            while process.isRunning {
                if let size = terminalSize(), size != lastSize {
                    lastSize = size
                    writer.resize(rows: size.rows, columns: size.columns, pane: parser.selectedPane)
                }
                var descriptor = pollfd(fd: FileHandle.standardInput.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let result = poll(&descriptor, 1, 150)
                guard result > 0, descriptor.revents & Int16(POLLIN) != 0 else { continue }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(descriptor.fd, &buffer, buffer.count)
                if count <= 0 { inputClosed = true; break }
                writer.sendInput(Array(buffer.prefix(count)), pane: parser.selectedPane)
            }
            outputHandle.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            if inputClosed { exit(0) }
        }
    }

    /// Ghostty's PTY normally turns Ctrl-C into SIGINT for its foreground
    /// child. The bridge must receive byte 0x03 instead so it can forward the
    /// interrupt to the selected remote pane without ever killing SSH itself.
    private static func configureRawInput() {
        let descriptor = FileHandle.standardInput.fileDescriptor
        var attributes = termios()
        guard tcgetattr(descriptor, &attributes) == 0 else { return }
        cfmakeraw(&attributes)
        _ = tcsetattr(descriptor, TCSANOW, &attributes)
    }

    private static func terminalSize() -> (rows: Int, columns: Int)? {
        var value = winsize()
        guard ioctl(FileHandle.standardInput.fileDescriptor, TIOCGWINSZ, &value) == 0 else { return nil }
        return (max(1, Int(value.ws_row)), max(1, Int(value.ws_col)))
    }

    private static func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, base, remaining)
                guard count > 0 else { return }
                base = base.advanced(by: count)
                remaining -= count
            }
        }
    }

    private static func exitWithMessage(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("prompt: \(message)\n").utf8))
        exit(2)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class PromptTmuxControlWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var selectedPane: String?
    private var bufferedInput: [UInt8] = []

    init(handle: FileHandle) { self.handle = handle }

    func select(pane: String) {
        lock.lock()
        defer { lock.unlock() }
        guard selectedPane == nil else { return }
        selectedPane = pane
        if !bufferedInput.isEmpty {
            sendInputLocked(bufferedInput, pane: pane)
            bufferedInput.removeAll()
        }
    }

    func send(_ command: String) {
        lock.lock()
        defer { lock.unlock() }
        sendLocked(command)
    }

    func sendInput(_ bytes: [UInt8], pane: String?) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let pane = pane ?? selectedPane else {
            bufferedInput.append(contentsOf: bytes)
            return
        }
        sendInputLocked(bytes, pane: pane)
    }

    func resize(rows: Int, columns: Int, pane: String?) {
        guard let pane = pane ?? selectedPane else { return }
        send("resize-pane -t \(pane) -x \(columns) -y \(rows)")
    }

    private func sendInputLocked(_ bytes: [UInt8], pane: String) {
        // `send-keys -H` avoids shell quoting and preserves control/escape bytes.
        for chunkStart in stride(from: 0, to: bytes.count, by: 256) {
            let chunk = bytes[chunkStart..<min(bytes.count, chunkStart + 256)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            sendLocked("send-keys -t \(pane) -H \(hex)")
        }
    }

    private func sendLocked(_ command: String) {
        do { try handle.write(contentsOf: Data((command + "\n").utf8)) } catch { }
    }
}

final class PromptTmuxControlParser: @unchecked Sendable {
    private var buffer = Data()
    private let requestedPane: String?
    private let output: ([UInt8]) -> Void
    private(set) var selectedPane: String?

    init(requestedPane: String?, output: @escaping ([UInt8]) -> Void) {
        self.requestedPane = requestedPane
        self.output = output
        selectedPane = requestedPane
    }

    func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .newlines)
            consume(line: line)
        }
    }

    func consume(line: String) {
        if line.hasPrefix("PROMPT_PANE=") {
            let value = String(line.dropFirst("PROMPT_PANE=".count))
            let components = value.split(separator: ":", maxSplits: 1).map(String.init)
            guard components.count == 2 else { return }
            if requestedPane == components[0] || (requestedPane == nil && components[1] == "1") {
                selectedPane = components[0]
            }
            return
        }
        guard line.hasPrefix("%output ") else { return }
        let payload = line.dropFirst("%output ".count)
        guard let separator = payload.firstIndex(of: " ") else { return }
        let pane = String(payload[..<separator])
        guard pane == selectedPane else { return }
        output(Self.decode(String(payload[payload.index(after: separator)...])))
    }

    static func decode(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x5C else {
                result.append(bytes[index]); index += 1; continue
            }
            if index + 3 < bytes.count,
               (0x30...0x37).contains(bytes[index + 1]),
               (0x30...0x37).contains(bytes[index + 2]),
               (0x30...0x37).contains(bytes[index + 3]) {
                let decoded = (bytes[index + 1] - 0x30) * 64
                    + (bytes[index + 2] - 0x30) * 8
                    + (bytes[index + 3] - 0x30)
                result.append(decoded)
                index += 4
            } else if index + 1 < bytes.count {
                result.append(bytes[index + 1])
                index += 2
            } else {
                result.append(bytes[index]); index += 1
            }
        }
        return result
    }
}
