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
        if arguments.count > 6 {
            waitUntilReady(at: arguments[6])
        }

        var firstConnection = true
        while true {
            if !firstConnection {
                writeAll(FileHandle.standardOutput.fileDescriptor, Array("\r\nConnection lost; reconnecting to remote tmux…\r\n".utf8))
                Thread.sleep(forTimeInterval: 3)
            }
            firstConnection = false
            let shouldRestoreExistingScreen = remoteSessionExists(
                destination: destination,
                session: session)
            if attachOnly, !shouldRestoreExistingScreen {
                exitWithMessage("Remote tmux session \(session) does not exist.")
            }
            var tmux: String
            if shouldRestoreExistingScreen {
                tmux = "exec tmux -C attach-session -t \(shellQuote(session))"
            } else {
                tmux = "exec tmux -C new-session -s \(shellQuote(session))"
                if let workingDirectory {
                    let directory: String
                    if workingDirectory == "~" || workingDirectory == "~/" { directory = "\"$HOME\"" }
                    else if workingDirectory.hasPrefix("~/") {
                        directory = "\"$HOME\"/" + shellQuote(String(workingDirectory.dropFirst(2)))
                    } else { directory = shellQuote(workingDirectory) }
                    tmux += " -c \(directory)"
                }
                let startup = """
                if [ -r /run/motd.dynamic ]; then cat /run/motd.dynamic; printf '\\n'; fi
                exec "${SHELL:-/bin/sh}" -l
                """
                tmux += " " + shellQuote("/bin/sh -lc \(shellQuote(startup))")
            }
            let sshArguments = [
                "-T", "-o", "ServerAliveInterval=20", "-o", "ServerAliveCountMax=2",
                "-o", "StrictHostKeyChecking=accept-new",
                destination, "sh", "-lc", shellQuote(tmux),
            ]

            let process = Process()
            let input = Pipe()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArguments
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            do { try process.run() } catch { continue }
            writeAll(
                FileHandle.standardOutput.fileDescriptor,
                Array(PromptCompositeIORouter.remoteReadyMarker))

            let selectedPane = resolvePane(
                destination: destination,
                session: session,
                requestedPane: requestedPane)
            if let selectedPane, shouldRestoreExistingScreen {
                writeAll(
                    FileHandle.standardOutput.fileDescriptor,
                    initialScreen(
                        destination: destination,
                        pane: selectedPane))
            }
            let writer = PromptTmuxControlWriter(handle: input.fileHandleForWriting)
            let parser = PromptTmuxControlParser(
                requestedPane: selectedPane,
                output: { bytes in writeAll(FileHandle.standardOutput.fileDescriptor, bytes) })
            if let selectedPane { writer.select(pane: selectedPane) }
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

    /// The presentation surface must install its output tee before SSH/tmux
    /// can emit the initial prompt. Otherwise that one-time output is lost,
    /// and input typed into the apparently blank terminal can race pane setup.
    private static func waitUntilReady(at path: String) {
        while !FileManager.default.fileExists(atPath: path) {
            Thread.sleep(forTimeInterval: 0.005)
        }
        // The marker must remain present until it is observed. Removing it in
        // the parent immediately after creation turns the handshake into a
        // pulse that this polling child can miss.
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func terminalSize() -> (rows: Int, columns: Int)? {
        var value = winsize()
        guard ioctl(FileHandle.standardInput.fileDescriptor, TIOCGWINSZ, &value) == 0 else { return nil }
        return (max(1, Int(value.ws_row)), max(1, Int(value.ws_col)))
    }

    /// A newly attached tmux control client only receives future `%output`.
    /// Seed Ghostty with the active pane's existing screen so its shell prompt
    /// is visible before the user types.
    private static func initialScreen(destination: String, pane: String) -> [UInt8] {
        let contents = capturePane(destination: destination, pane: pane) ?? ""
        return Array(("\u{1B}[2J\u{1B}[H" + contents).utf8)
    }

    private static func resolvePane(
        destination: String,
        session: String,
        requestedPane: String?
    ) -> String? {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-T", "-o", "ConnectTimeout=3", "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                destination, "tmux", "list-panes", "-t", session,
                "-F", "'#{pane_id} #{pane_active}'",
            ]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                process.waitUntilExit()
                let lines = String(
                    decoding: output.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self)
                    .split(separator: "\n")
                    .map { $0.split(separator: " ", maxSplits: 1).map(String.init) }
                if let requestedPane,
                   lines.contains(where: { $0.first == requestedPane }) {
                    return requestedPane
                }
                if let active = lines.first(where: { $0.count == 2 && $0[1] == "1" })?.first {
                    return active
                }
                if let first = lines.first?.first { return first }
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return nil
    }

    private static func remoteSessionExists(destination: String, session: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T", "-o", "ConnectTimeout=3", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            destination, "tmux", "has-session", "-t", session,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func capturePane(destination: String, pane: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T", "-o", "ConnectTimeout=3", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            destination, "sh", "-lc",
            shellQuote(
                "tmux capture-pane -p -e -t \(shellQuote(pane)); "
                    + "tmux display-message -p -t \(shellQuote(pane)) "
                    + shellQuote("PROMPT_CURSOR=#{cursor_x}:#{cursor_y}")),
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let markerIndex = lines.lastIndex(where: { $0.hasPrefix("PROMPT_CURSOR=") }) else {
            return lines.joined(separator: "\r\n")
        }
        let coordinates = lines[markerIndex]
            .dropFirst("PROMPT_CURSOR=".count)
            .split(separator: ":")
            .compactMap { Int($0) }
        lines.removeSubrange(markerIndex...)
        let grid = lines.joined(separator: "\r\n")
        guard coordinates.count == 2 else { return grid }
        return grid + "\u{1B}[\(coordinates[1] + 1);\(coordinates[0] + 1)H"
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
            let chunk = bytes[chunkStart ..< min(bytes.count, chunkStart + 256)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            sendLocked("send-keys -t \(pane) -H \(hex)")
        }
    }

    private func sendLocked(_ command: String) {
        do { try handle.write(contentsOf: Data((command + "\n").utf8)) } catch {}
    }
}

final class PromptTmuxControlParser: @unchecked Sendable {
    private var buffer = Data()
    private let requestedPane: String?
    private let output: ([UInt8]) -> Void
    private let selection: ((String) -> Void)?
    private(set) var selectedPane: String?
    private var seededSelection = false

    init(
        requestedPane: String?,
        output: @escaping ([UInt8]) -> Void,
        selection: ((String) -> Void)? = nil
    ) {
        self.requestedPane = requestedPane
        self.output = output
        self.selection = selection
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
                if !seededSelection {
                    seededSelection = true
                    selection?(components[0])
                }
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
               (0x30 ... 0x37).contains(bytes[index + 1]),
               (0x30 ... 0x37).contains(bytes[index + 2]),
               (0x30 ... 0x37).contains(bytes[index + 3]) {
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
