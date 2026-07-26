import AppKit
import CoreText
import Darwin
import GhosttyKit
import MarkdownUI
import SwiftMath
import SwiftUI

@MainActor
final class PromptController: NSObject {
    static let shared = PromptController()
    private weak var terminalWindow: NSWindow?

    func install() {
        let cwd = activeSurface()?.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        PromptModel.shared.start(cwd: cwd)
    }

    func attach(to window: NSWindow) {
        guard let contentView = window.contentView,
              PromptTerminalSurface.find(in: contentView) != nil else { return }
        terminalWindow = window
    }

    func toggle() {
        show()
    }

    func show() {
        PromptModel.shared.captureTerminal()
        NotificationCenter.default.post(name: .promptFocusCommandBar, object: activeSurface())
    }

    func hide() {
        terminalWindow?.makeKeyAndOrderFront(nil)
        activeSurface()?.focus()
    }

    func activeSurface() -> PromptTerminalSurface? {
        let window = terminalWindow ?? NSApp.keyWindow
        if let focused = PromptTerminalSurface.find(containing: window?.firstResponder as? NSView) {
            return focused
        }
        guard let root = window?.contentView else { return nil }
        return PromptTerminalSurface.find(in: root)
    }

    func pressReturn() {
        guard let surface = activeSurface() else { return }
        Self.pressReturn(on: surface)
    }

    static func pressReturn(on surfaceView: PromptTerminalSurface) {
        guard let surface = surfaceView.surface else { return }
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.keycode = 0x24 // macOS virtual key code for Return
        event.text = nil
        event.composing = false
        event.mods = GHOSTTY_MODS_NONE
        event.consumed_mods = GHOSTTY_MODS_NONE
        event.unshifted_codepoint = 13
        _ = ghostty_surface_key(surface, event)
    }

}

enum PromptInputMode: String, CaseIterable { case shell = "Shell", ai = "AI" }

enum PromptSurfaceMode: String, CaseIterable {
    case autoShell = "Auto"
    case shell = "Shell"
    case assistant = "Assistant"
    case agent = "Agent"

    var icon: String {
        switch self {
        case .autoShell: "wand.and.stars"
        case .shell: "terminal"
        case .assistant: "bubble.left.and.text.bubble.right"
        case .agent: "hammer"
        }
    }

    var next: Self {
        switch self {
        case .autoShell: .shell
        case .shell: .assistant
        case .assistant: .agent
        case .agent: .autoShell
        }
    }

    var aiLane: PromptAILane? {
        switch self {
        case .autoShell, .shell: nil
        case .assistant: .assistant
        case .agent: .agent
        }
    }
}

enum PromptTabDisposition: Equatable {
    case passToTerminal
    case consume
    case acceptAutocomplete
    case switchMode(PromptSurfaceMode)

    static func resolve(
        surfaceMode: PromptSurfaceMode,
        input: String?,
        hasAutocomplete: Bool
    ) -> Self {
        guard let input else {
            return surfaceMode == .autoShell ? .passToTerminal : .switchMode(surfaceMode.next)
        }
        if input.isEmpty { return .switchMode(surfaceMode.next) }
        // A concrete inline candidate is tied to the token at the cursor, not
        // to how Enter will route the complete line. This permits paths,
        // binaries and flags inside natural-language Assistant requests.
        if hasAutocomplete { return .acceptAutocomplete }
        // Completion is an editor concern, independent of what Enter will do.
        // If Copilot has not produced a candidate yet, let readline/ZLE handle
        // Tab synchronously. It can still complete the final filename, binary,
        // or flag inside a natural-language Assistant request.
        return .passToTerminal
    }
}

enum PromptRouteOverride: String, CaseIterable { case automatic = "Auto", shell = "Shell", ai = "AI" }

struct PromptSubmissionResolution: Equatable {
    let mode: PromptInputMode
    let lane: PromptAILane?

    static func resolve(
        surfaceMode: PromptSurfaceMode,
        text: String,
        shell: String? = nil,
        cwd: String? = nil
    ) -> Self {
        if surfaceMode == .shell { return .init(mode: .shell, lane: nil) }
        guard surfaceMode == .autoShell else { return .init(mode: .ai, lane: surfaceMode.aiLane) }
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("/shell ") || lower.hasPrefix("$ ") { return .init(mode: .shell, lane: nil) }
        if lower.hasPrefix("/assistant ") || lower.hasPrefix("/ask ") || lower.hasPrefix("/ai ") || lower.hasPrefix("? ") {
            return .init(mode: .ai, lane: .assistant)
        }
        if lower.hasPrefix("/agent ") { return .init(mode: .ai, lane: .agent) }
        // Keep the old command as a compatibility alias; it now uses the
        // normal Assistant because insertion is a standard capability.
        if lower.hasPrefix("/suggest ") { return .init(mode: .ai, lane: .assistant) }
        let mode = PromptInputClassifier.classify(text, shell: shell, cwd: cwd)
        return .init(mode: mode, lane: mode == .ai ? .assistant : nil)
    }
}

enum PromptComposerPresentation { case inline, commandBar
    /// Temporary product switch while inline interaction is developed.
    static let current: Self = .inline
}

enum PromptTypography {
    static let sans = "Geist"
    static let mono = "Geist Mono"

    static func registerBundledFonts() {
        for filename in ["Geist-Variable.ttf", "GeistMono-Variable.ttf"] {
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("Fonts/\(filename)"),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func verifyGeistInstallation(in bundle: Bundle = .main) -> Bool {
        guard let resources = bundle.resourceURL else { return false }
        let monoURL = resources.appendingPathComponent("Fonts/GeistMono-Variable.ttf")
        let sansURL = resources.appendingPathComponent("Fonts/Geist-Variable.ttf")
        guard FileManager.default.fileExists(atPath: monoURL.path),
              FileManager.default.fileExists(atPath: sansURL.path) else { return false }
        registerBundledFonts()
        let mono = CTFontCreateWithName(PromptTypography.mono as CFString, 14, nil)
        let sans = CTFontCreateWithName(PromptTypography.sans as CFString, 14, nil)
        let monoName = CTFontCopyPostScriptName(mono) as String
        let sansName = CTFontCopyPostScriptName(sans) as String
        return monoName.lowercased().contains("geistmono") &&
            sansName.lowercased().contains("geist") &&
            CTFontCopyVariationAxes(mono) != nil &&
            CTFontCopyVariationAxes(sans) != nil
    }
}

struct PromptInputClassifier {
    static func classify(
        _ raw: String,
        shell: String? = nil,
        cwd: String? = nil
    ) -> PromptInputMode {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        guard !text.isEmpty else { return .shell }
        if ["/ai ", "/ask ", "/agent ", "/suggest ", "? "].contains(where: lower.hasPrefix) {
            return .ai
        }
        if lower.hasPrefix("/shell ") || lower.hasPrefix("$ ") { return .shell }
        // Command lookup alone is not enough to infer intent. macOS ships
        // executables such as `what`, and user environments can add many more
        // names that are also ordinary conversational verbs. Recognize strong
        // request phrasing before asking zsh whether the first word resolves.
        if looksLikeAssistantRequest(text) { return .ai }
        return PromptShellInputProbe.classify(
            text,
            shell: shell ?? ProcessInfo.processInfo.environment["SHELL"],
            cwd: cwd)
    }

    static func looksLikeAssistantRequest(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace)
        guard words.count >= 2 else { return false }

        // Flags and shell operators are an explicit indication that the user
        // means the executable, even when its name overlaps natural language.
        let shellOperators = CharacterSet(charactersIn: "|&;<>`$")
        if words.dropFirst().contains(where: { $0.hasPrefix("-") }) ||
            text.unicodeScalars.contains(where: shellOperators.contains) {
            return false
        }

        let first = String(words[0]).trimmingCharacters(in: .punctuationCharacters)
        let second = String(words[1]).trimmingCharacters(in: .punctuationCharacters)
        let questionAuxiliaries: Set<String> = [
            "am", "is", "are", "was", "were", "do", "does", "did", "can",
            "could", "will", "would", "should", "has", "have", "had",
        ]
        if ["what", "why", "when", "where", "who", "how"].contains(first),
           questionAuxiliaries.contains(second) {
            return true
        }
        if first == "tell", ["me", "us"].contains(second) { return true }
        if ["can", "could", "would", "will"].contains(first), second == "you" { return true }
        return first == "please"
    }

    static func strippedInput(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["/ai ", "/ask ", "/agent ", "/suggest ", "/shell ", "? ", "$ "]
            where text.lowercased().hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }
}

/// Uses the session's shell as the parser and command resolver. The probe's
/// DEBUG hook exits before the parsed command can execute. Unknown shells,
/// timeouts, syntax errors, and probe failures deliberately remain in Shell:
/// Auto must never steal uncertain terminal input and send it to Assistant.
private enum PromptShellInputProbe {
    private static let cacheLock = NSLock()
    private static var cache: [String: PromptInputMode] = [:]
    private static let zshProbe = #"""
    setopt extendedglob
    typeset -gi prompt_auto_debug_count=0
    TRAPDEBUG() {
      (( ++prompt_auto_debug_count == 1 )) && return 0
      local -a prompt_auto_words
      prompt_auto_words=("${(z)ZSH_DEBUG_CMD}")
      local prompt_auto_word
      for prompt_auto_word in "${prompt_auto_words[@]}"; do
        [[ $prompt_auto_word == [[:IDENT:]]##=* ]] && continue
        whence -w -- "$prompt_auto_word" >/dev/null 2>&1 && exit 40
        exit 41
      done
      exit 41
    }
    eval -- "$1"
    """#

    static func classify(_ text: String, shell: String?, cwd: String?) -> PromptInputMode {
        guard let shell, URL(fileURLWithPath: shell).lastPathComponent == "zsh",
              FileManager.default.isExecutableFile(atPath: shell) else {
            return .shell
        }
        let cacheKey = "\(shell)\u{0}\(cwd ?? "")\u{0}\(text)"
        cacheLock.lock()
        if let cached = cache[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Both user and global startup files are disabled. Classification must
        // never execute shell configuration merely because the user typed.
        process.arguments = ["-dfc", zshProbe, "prompt-auto", text]
        let inherited = ProcessInfo.processInfo.environment
        let inheritedPath = inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", inheritedPath]
            .joined(separator: ":")
        var environment: [String: String] = [
            "PATH": searchPath,
            "HOME": inherited["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": inherited["TMPDIR"] ?? NSTemporaryDirectory(),
        ]
        for key in ["LANG", "LC_ALL", "LC_CTYPE"] {
            if let value = inherited[key] { environment[key] = value }
        }
        process.environment = environment
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return .shell }
        guard finished.wait(timeout: .now() + 0.35) == .success else {
            process.terminate()
            return .shell
        }
        let result: PromptInputMode = process.terminationStatus == 41 ? .ai : .shell
        cacheLock.lock()
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        cache[cacheKey] = result
        cacheLock.unlock()
        return result
    }
}

extension Notification.Name {
    static let promptFocusCommandBar = Notification.Name("dev.prompt.focusCommandBar")
    static let promptSurfaceDidClick = Notification.Name("dev.prompt.surfaceDidClick")
    static let promptModeDidChange = Notification.Name("dev.prompt.modeDidChange")
    static let promptShowModePicker = Notification.Name("dev.prompt.showModePicker")
    static let promptDismissModePicker = Notification.Name("dev.prompt.dismissModePicker")
    static let promptProposeCommand = Notification.Name("dev.prompt.proposeCommand")
    static let PromptCommandKey = "command"
    static let PromptModeKey = "mode"
}

/// Routes only completed native shell input. Ghostty/readline continue to own
/// the editor itself, including its cursor, selection, history and IME state.
@MainActor
enum PromptNativeInputRouter {
    private static var surfaceModes: [ObjectIdentifier: PromptSurfaceMode] = [:]
    private static var preferredAILanes: [ObjectIdentifier: PromptAILane] = [:]
    private static var suggestedCommands: [ObjectIdentifier: String] = [:]
    private static var remoteInputs: [ObjectIdentifier: String] = [:]

    static func surfaceMode(for surfaceView: PromptTerminalSurface) -> PromptSurfaceMode {
        surfaceModes[ObjectIdentifier(surfaceView)] ?? .autoShell
    }

    static func setSurfaceMode(_ value: PromptSurfaceMode, for surfaceView: PromptTerminalSurface) {
        let id = ObjectIdentifier(surfaceView)
        surfaceModes[id] = value
        if let lane = value.aiLane { preferredAILanes[id] = lane }
        NotificationCenter.default.post(
            name: .promptModeDidChange,
            object: surfaceView,
            userInfo: [Notification.Name.PromptModeKey: value])
    }

    static func route(for surfaceView: PromptTerminalSurface, text: String) -> PromptInputMode {
        resolution(for: surfaceView, text: text).mode
    }

    static func resolution(for surfaceView: PromptTerminalSurface, text: String) -> PromptSubmissionResolution {
        let classification = PromptTerminalEnvironment.shellClassificationContext(on: surfaceView)
        return PromptSubmissionResolution.resolve(
            surfaceMode: surfaceMode(for: surfaceView),
            text: text,
            shell: classification.shell,
            cwd: classification.cwd)
    }

    static func routeOverride(for surfaceView: PromptTerminalSurface) -> PromptRouteOverride {
        switch surfaceMode(for: surfaceView) {
        case .autoShell: .automatic
        case .shell: .shell
        case .assistant, .agent: .ai
        }
    }

    static func setOverride(_ value: PromptRouteOverride, for surfaceView: PromptTerminalSurface) {
        switch value {
        case .automatic: setSurfaceMode(.autoShell, for: surfaceView)
        case .shell: setSurfaceMode(.shell, for: surfaceView)
        case .ai:
            let lane = preferredAILanes[ObjectIdentifier(surfaceView)] ?? .assistant
            switch lane {
            case .assistant: setSurfaceMode(.assistant, for: surfaceView)
            case .agent: setSurfaceMode(.agent, for: surfaceView)
            }
        }
    }

    static func tabDisposition(on surfaceView: PromptTerminalSurface) -> PromptTabDisposition {
        guard PromptTerminalEnvironment.allowsRichContent(on: surfaceView) else { return .passToTerminal }
        let input = promptInput(on: surfaceView)
        let result = PromptTabDisposition.resolve(
            surfaceMode: surfaceMode(for: surfaceView),
            input: input,
            hasAutocomplete: !PromptAutocompleteModel.shared.suggestion(for: surfaceView).isEmpty)
        if case .switchMode(.agent) = result,
           PromptTerminalCapabilities.isManagedRemote(surfaceView) {
            return .switchMode(.autoShell)
        }
        return result
    }

    static func selectSurfaceMode(_ mode: PromptSurfaceMode, for surfaceView: PromptTerminalSurface) {
        let allowedMode: PromptSurfaceMode = mode == .agent && PromptTerminalCapabilities.isManagedRemote(surfaceView)
            ? .assistant
            : mode
        setSurfaceMode(allowedMode, for: surfaceView)
        PromptAutocompleteModel.shared.clear(on: surfaceView)
        DispatchQueue.main.async { surfaceView.focus() }
    }

    static func selectSurfaceModeFromKeyboard(_ mode: PromptSurfaceMode, for surfaceView: PromptTerminalSurface) {
        selectSurfaceMode(mode, for: surfaceView)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .promptShowModePicker, object: surfaceView)
        }
    }

    static func cleanup(for surfaceView: PromptTerminalSurface) {
        let id = ObjectIdentifier(surfaceView)
        surfaceModes.removeValue(forKey: id)
        preferredAILanes.removeValue(forKey: id)
        suggestedCommands.removeValue(forKey: id)
        remoteInputs.removeValue(forKey: id)
    }

    static func setSuggestedCommand(_ command: String, for surfaceView: PromptTerminalSurface) {
        suggestedCommands[ObjectIdentifier(surfaceView)] = command
    }

    static func isSuggestedCommand(_ input: String, for surfaceView: PromptTerminalSurface) -> Bool {
        guard let command = suggestedCommands[ObjectIdentifier(surfaceView)] else { return false }
        if input.isEmpty || input == command { return true }
        // Once the user edits or submits the proposal it becomes ordinary
        // shell input and the transient badge disappears.
        suggestedCommands.removeValue(forKey: ObjectIdentifier(surfaceView))
        return false
    }

    static func clearSuggestedCommand(for surfaceView: PromptTerminalSurface) {
        suggestedCommands.removeValue(forKey: ObjectIdentifier(surfaceView))
    }

    static func promptInput(on surfaceView: PromptTerminalSurface) -> String? {
        if PromptTerminalCapabilities.isManagedRemote(surfaceView) {
            return remoteInputs[ObjectIdentifier(surfaceView)] ?? ""
        }
        guard let surface = surfaceView.surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_prompt_input(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return "" }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len))
        return String(decoding: bytes, as: UTF8.self)
    }

    static func observeRemoteKeyDown(_ event: NSEvent, on surfaceView: PromptTerminalSurface) {
        guard PromptTerminalCapabilities.isManagedRemote(surfaceView),
              PromptTerminalCapabilities.allowsAI(on: surfaceView) else { return }
        let id = ObjectIdentifier(surfaceView)
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if event.keyCode == 0x24 || event.keyCode == 0x4C {
            return
        }
        if event.keyCode == 0x33, modifiers.isEmpty {
            if var value = remoteInputs[id], !value.isEmpty { value.removeLast(); remoteInputs[id] = value }
            return
        }
        if modifiers == [.control] {
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "u" || key == "c" { remoteInputs[id] = "" }
            return
        }
        guard modifiers.isEmpty,
              let characters = event.characters,
              !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return }
        remoteInputs[id, default: ""].append(contentsOf: characters)
    }

    static func handleReturn(on surfaceView: PromptTerminalSurface) -> Bool {
        // Full-screen applications and remote sessions exclusively own their
        // PTY. Never inspect, classify, clear, or replace their input.
        guard PromptTerminalEnvironment.allowsRichContent(on: surfaceView) else { return false }
        guard let raw = promptInput(on: surfaceView) else { return false }
        let resolution = resolution(for: surfaceView, text: raw)
        guard resolution.mode == .ai else {
            if PromptTerminalCapabilities.isManagedRemote(surfaceView) {
                remoteInputs[ObjectIdentifier(surfaceView)] = ""
            }
            PromptBlockStore.shared.noteSubmission(
                raw.trimmingCharacters(in: .whitespacesAndNewlines),
                on: surfaceView)
            clearSuggestedCommand(for: surfaceView)
            let command = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if command == "clear" || command == "reset" || command.hasPrefix("clear ") {
                PromptRichContentStore.shared.clear(for: surfaceView)
            }
            return false
        }
        let value = PromptInputClassifier.strippedInput(raw)
        guard !value.isEmpty, let surface = surfaceView.surface else { return false }

        _ = PromptModel.shared.submitFromTerminal(
            value,
            mode: .ai,
            lane: resolution.lane ?? .assistant,
            surface: surfaceView
        ) {
            // Clear the shell editor only after the model has atomically
            // accepted and reserved the terminal submission.
            var killLine = UInt8(0x15) // readline/zle backward-kill-line (Ctrl-U)
            withUnsafePointer(to: &killLine) { pointer in
                ghostty_surface_text_input(
                    surface,
                    UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self),
                    1)
            }
            remoteInputs[ObjectIdentifier(surfaceView)] = ""
        }
        // Routing and service availability are separate decisions. Once this
        // line has resolved to AI, Return must never fall through to the PTY:
        // submitFromTerminal can temporarily reject while Codex is connecting
        // or another turn is active, and returning false here would execute
        // the natural-language request as a zsh command.
        return true
    }
}
