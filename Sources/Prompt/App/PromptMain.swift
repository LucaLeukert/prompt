import AppKit
import GhosttyKit
import Logging

@MainActor
@objc(PromptApplication)
final class PromptApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           mainMenu?.performKeyEquivalent(with: event) == true {
            return
        }
        super.sendEvent(event)
    }
}

@main
enum PromptMain {
    static func main() {
        PromptLogging.bootstrap()
        var logger = PromptLog.application
        logger.info("Prompt process started", metadata: ["version": "\(Bundle.main.promptVersion)"])
        if CommandLine.arguments.dropFirst().first == PromptTmuxControlBridge.argument {
            logger.debug("Starting tmux control bridge")
            PromptTmuxControlBridge.run(arguments: Array(CommandLine.arguments.dropFirst()))
        }
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            logger.critical("Ghostty initialization failed")
            exit(1)
        }
        PromptTerminalIntegration.install()
        let application = PromptApplication.shared
        let delegate = PromptApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
        withExtendedLifetime(delegate) {}
    }
}

private extension Bundle {
    var promptVersion: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(version) (\(build))"
    }
}
