import AppKit
import CoreText
import Darwin
import GhosttyKit
import MarkdownUI
import SwiftMath
import SwiftUI

struct PromptThread: Identifiable, Hashable {
    let id: String
    var title: String
    var cwd: String
    var updatedAt: String
}

enum PromptTerminalEnvironment {
    struct ShellClassificationContext {
        let shell: String?
        let cwd: String?
    }

    private static let exclusiveProcesses: Set<String> = [
        "ssh", "mosh", "tmux", "screen", "vim", "nvim", "vi", "less", "more",
        "man", "top", "htop", "btop", "watch", "fzf", "ranger", "yazi",
    ]

    @MainActor
    static func allowsRichContent(on surfaceView: PromptTerminalSurface) -> Bool {
        guard PromptTerminalCapabilities.allowsAI(on: surfaceView) else { return false }
        guard let surface = surfaceView.surface else { return false }
        let alternate = PromptLibghostty.isAlternateScreen(surfaceView)
        let pid = Int32(ghostty_surface_foreground_pid(surface))
        guard pid > 0 else { return allowsRichContent(alternateScreen: alternate, process: nil) }
        var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else {
            return allowsRichContent(alternateScreen: alternate, process: nil)
        }
        let process = String(cString: name).lowercased()
        return allowsRichContent(alternateScreen: alternate, process: process)
    }

    static func allowsRichContent(alternateScreen: Bool, process: String?) -> Bool {
        guard !alternateScreen else { return false }
        guard let process else { return true }
        return !exclusiveProcesses.contains(process.lowercased())
    }

    @MainActor
    static func shellPath(on surfaceView: PromptTerminalSurface) -> String? {
        // A composite remote's presentation terminal intentionally has no
        // foreground process. Auto features still use the exact same safe,
        // non-executing zsh probe as local sessions; they must not inspect the
        // SSH/tmux bridge executable and treat it as the user's shell.
        if PromptTerminalCapabilities.isManagedRemote(surfaceView) {
            return localSyntaxProbeShell()
        }
        guard let surface = surfaceView.surface else { return nil }
        let pid = Int32(ghostty_surface_foreground_pid(surface))
        guard pid > 0 else { return ProcessInfo.processInfo.environment["SHELL"] }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
            return ProcessInfo.processInfo.environment["SHELL"]
        }
        return String(cString: path)
    }

    @MainActor
    static func shellClassificationContext(
        on surfaceView: PromptTerminalSurface
    ) -> ShellClassificationContext {
        ShellClassificationContext(
            shell: shellPath(on: surfaceView),
            // Remote paths do not necessarily exist on the Mac. The probe is
            // syntax/command classification only and safely keeps its local
            // working directory in that case.
            cwd: PromptTerminalCapabilities.isManagedRemote(surfaceView) ? nil : surfaceView.pwd)
    }

    private static func localSyntaxProbeShell() -> String? {
        let configured = ProcessInfo.processInfo.environment["SHELL"]
        if let configured,
           URL(fileURLWithPath: configured).lastPathComponent == "zsh",
           FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        return FileManager.default.isExecutableFile(atPath: "/bin/zsh") ? "/bin/zsh" : configured
    }
}

struct PromptMessage: Identifiable {
    enum Kind { case user, assistant, activity, error }
    let id = UUID()
    let kind: Kind
    var text: String
}

struct PromptApproval: Identifiable {
    let id: String
    let method: String
    let summary: String
    let richBlockID: UUID?
}

struct PromptToolCall: Identifiable {
    enum State { case running, complete, failed }
    let id: String
    let title: String
    var detail: String
    var state: State
}

enum PromptSuggestedCommand {
    static func parse(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String,
              isValid(command) else { return nil }
        return command
    }

    static func isValid(_ command: String) -> Bool {
        !command.isEmpty && !command.contains("\n") && !command.contains("\r")
    }
}

enum PromptTerminalSubmissionEligibility {
    static func allows(connected: Bool, isRunning: Bool) -> Bool {
        connected && !isRunning
    }
}

enum PromptInsertionEligibility {
    static func allows(
        richContentAllowed: Bool,
        originalCWD: String?,
        currentCWD: String?,
        promptIsEmpty: Bool
    ) -> Bool {
        richContentAllowed && originalCWD == currentCWD && promptIsEmpty
    }
}

enum PromptCommandProposal {
    struct Output: Equatable {
        let response: String
        let command: String?
    }

    static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "response": ["type": "string", "description": "The natural-language answer shown to the user."],
            "command": [
                "anyOf": [["type": "string"], ["type": "null"]],
                "description": "One single-line shell command to place in the command bar, or null.",
            ],
        ],
        "required": ["response", "command"],
        "additionalProperties": false,
    ]

    static func parse(_ text: String) -> Output? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = object["response"] as? String else { return nil }
        let command = object["command"] as? String
        guard command == nil || PromptSuggestedCommand.isValid(command!) else { return nil }
        return .init(response: response, command: command)
    }

    static func fromExecutedCommands(_ commands: [String], request: String) -> String? {
        let terms = request.lowercased()
        let isTerminalAction = ["command", "port", "process", "pid", "listen", "kill", "running", "terminal", "shell"]
            .contains { terms.contains($0) }
        guard isTerminalAction else { return nil }
        return commands.first(where: { !$0.contains("\n") && !$0.isEmpty })
    }

}
