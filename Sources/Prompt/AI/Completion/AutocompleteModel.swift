import AppKit
import CoreText
import Darwin
import GhosttyKit
import MarkdownUI
import SwiftMath
import SwiftUI

@MainActor
final class AutocompleteModel: ObservableObject {
    static let shared = AutocompleteModel()
    private static let completeAIInputSettingKey = "PromptCopilotCompletesAIInput"

    @Published private var suggestions: [ObjectIdentifier: [String]] = [:]
    @Published private var selectedIndices: [ObjectIdentifier: Int] = [:]
    @Published var completesAIInput: Bool {
        didSet { PromptSettings.shared.set(completesAIInput, forKey: Self.completeAIInputSettingKey) }
    }
    private var startupCWD = FileManager.default.homeDirectoryForCurrentUser.path
    private var activeSurfaceID: ObjectIdentifier?
    private weak var activeSurface: PromptTerminalSurface?
    private var activePrefix = ""
    private var generation = 0
    private var pending: DispatchWorkItem?

    private init() {
        completesAIInput = PromptSettings.shared.value(forKey: Self.completeAIInputSettingKey) ?? false
    }

    func start(cwd: String) {
        startupCWD = cwd
    }

    func observe(prefix: String, on surface: PromptTerminalSurface) {
        let id = ObjectIdentifier(surface)
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        // This view is polled roughly every frame. Do not inspect the shell
        // environment or launch a classifier process when nothing changed:
        // doing so can repeatedly ask macOS for removable-volume access when
        // the active terminal happens to be on an external disk.
        if activeSurfaceID == id, activePrefix == prefix { return }
        let classification = PromptTerminalEnvironment.shellClassificationContext(on: surface)
        guard PromptTerminalEnvironment.allowsRichContent(on: surface),
              Self.shouldComplete(
                  prefix: prefix,
                  completesAIInput: completesAIInput,
                  shell: classification.shell,
                  cwd: nil),
              trimmed.count >= 2 else {
            clear(on: surface)
            return
        }
        generation += 1
        let requestGeneration = generation
        pending?.cancel()
        suggestions[id] = []
        selectedIndices[id] = 0
        activeSurfaceID = id
        activeSurface = surface
        activePrefix = prefix
        let work = DispatchWorkItem { [weak self, weak surface] in
            guard let self, let surface, self.generation == requestGeneration else { return }
            self.request(prefix: prefix, on: surface, generation: requestGeneration)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    nonisolated static func shouldComplete(
        prefix: String,
        completesAIInput: Bool,
        shell: String? = nil,
        cwd: String? = nil
    ) -> Bool {
        completesAIInput || PromptInputClassifier.classify(prefix, shell: shell, cwd: cwd) == .shell
    }

    func suggestion(for surface: PromptTerminalSurface) -> String {
        let id = ObjectIdentifier(surface)
        guard let values = suggestions[id], !values.isEmpty else { return "" }
        return values[min(selectedIndices[id] ?? 0, values.count - 1)]
    }

    func selectionLabel(for surface: PromptTerminalSurface) -> String? {
        let id = ObjectIdentifier(surface)
        guard let values = suggestions[id], values.count > 1 else { return nil }
        return "\((selectedIndices[id] ?? 0) + 1)/\(values.count)"
    }

    @discardableResult
    func cycle(on surface: PromptTerminalSurface, direction: Int) -> Bool {
        let id = ObjectIdentifier(surface)
        guard let values = suggestions[id], values.count > 1 else { return false }
        let current = selectedIndices[id] ?? 0
        selectedIndices[id] = (current + direction + values.count) % values.count
        return true
    }

    @discardableResult
    func accept(on surface: PromptTerminalSurface) -> Bool {
        let id = ObjectIdentifier(surface)
        let suffix = suggestion(for: surface)
        guard !suffix.isEmpty else { return false }
        surface.surfaceModel?.sendText(suffix)
        if let terminal = surface.surface { _ = ghostty_surface_clear_selection(terminal) }
        DispatchQueue.main.async { [weak surface] in
            guard let terminal = surface?.surface else { return }
            _ = ghostty_surface_clear_selection(terminal)
        }
        let index = selectedIndices[id] ?? 0
        if let provider = autocompleteProvider() {
            provider.accepted(.init(text: suffix, providerIndex: index))
        }
        clear(on: surface)
        return true
    }

    func clear(on surface: PromptTerminalSurface) {
        let id = ObjectIdentifier(surface)
        suggestions[id] = nil
        selectedIndices[id] = nil
        if activeSurfaceID == id {
            generation += 1
            pending?.cancel()
            activeSurfaceID = nil
            activeSurface = nil
            activePrefix = ""
        }
    }

    private func request(prefix: String, on surface: PromptTerminalSurface, generation requestGeneration: Int) {
        let cwd = surface.pwd ?? (startupCWD == "/" ? FileManager.default.homeDirectoryForCurrentUser.path : startupCWD)
        // Copilot's public LSP accepts editor text but has no separate context
        // field. Real command history works reliably as shell comments, while
        // synthesized inventories can cause its post-processor to return no
        // items. Include the live viewport plus bounded completed command
        // blocks from this terminal so earlier workflow context survives
        // scrolling.
        var terminalParts = PromptBlockStore.shared.recent(limit: 6, on: surface)
            .reversed()
            .map { block in
                [
                    "$ \(block.command)",
                    String(block.snapshot.suffix(4_000)),
                    "[exit \(block.exitCode) in \(block.cwd)]",
                ].joined(separator: "\n")
            }
        terminalParts.append(String(surface.cachedVisibleContents.get().suffix(16_000)))
        let terminal = String(terminalParts.joined(separator: "\n").suffix(32_000))
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingWhitespaceCount = prefix.reversed().prefix {
            $0 == " " || $0 == "\t"
        }.count
        let completionPrefix = trimmedPrefix + (trailingWhitespaceCount == 1 ? " " : "")
        guard let provider = autocompleteProvider() else {
            clear(on: surface)
            return
        }
        provider.start(cwd: cwd)
        provider.complete(.init(
            prefix: completionPrefix,
            cwd: cwd,
            terminal: terminal
        )) { [weak self, weak surface] result in
            guard let self, let surface, generation == requestGeneration,
                  activeSurfaceID == ObjectIdentifier(surface), activePrefix == prefix else { return }
            let values = (try? result.get())?.map(\.text) ?? []
            suggestions[ObjectIdentifier(surface)] = values
            selectedIndices[ObjectIdentifier(surface)] = 0
        }
    }

    private func autocompleteProvider() -> (any AutocompleteProviding)? {
        CapabilityRouter.shared.provider(for: .autocomplete) as? any AutocompleteProviding
    }

    nonisolated static func clean(
        _ raw: String,
        prefix: String,
        expectsSuffixOnly: Bool = false
    ) -> String {
        var value = raw.trimmingCharacters(in: .newlines)
        if value.hasPrefix("```") {
            value = value.replacingOccurrences(of: "```shell", with: "")
                .replacingOccurrences(of: "```bash", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if expectsSuffixOnly {
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("#") {
                value.removeFirst()
                value = value.trimmingCharacters(in: .whitespaces)
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
        }
        if value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        if let newline = value.firstIndex(of: "\n") { value = String(value[..<newline]) }
        return String(value.prefix(240))
    }

}
