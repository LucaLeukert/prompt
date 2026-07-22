import AppKit
import GhosttyKit

@main
enum PromptMain {
    static func main() {
        if CommandLine.arguments.dropFirst().first == PromptTmuxControlBridge.argument {
            PromptTmuxControlBridge.run(arguments: Array(CommandLine.arguments.dropFirst()))
        }
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else { exit(1) }
        PromptTerminalIntegration.install()
        let application = NSApplication.shared
        let delegate = PromptApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
        withExtendedLifetime(delegate) {}
    }
}
