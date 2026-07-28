import AppKit
import CoreText
import Darwin
import GhosttyKit
import MarkdownUI
import SwiftMath
import SwiftUI

/// Ambient analysis uses an independent ephemeral Codex invocation. Results
/// are rendered only after the model says the completed command has a useful,
/// concrete next step.
@MainActor
final class AmbientAnalyzer {
    static let shared = AmbientAnalyzer()

    private struct Work {
        let block: PromptBlockStore.Block
        weak var surface: PromptTerminalSurface?
    }

    private var queue: [Work] = []
    private var active: Work?
    private var activeRequestID: UUID?
    private var response = ""

    private init() {}

    func consider(_ block: PromptBlockStore.Block, on surface: PromptTerminalSurface) {
        guard let provider = CapabilityRouter.shared.provider(for: .assistant),
              provider.descriptor.id == .codex,
              provider.descriptor.traits.contains(.structuredOutput) else { return }
        guard !block.command.isEmpty,
              !["clear", "reset", "exit"].contains(block.command.lowercased()) else { return }
        queue.append(.init(block: block, surface: surface))
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard active == nil, !queue.isEmpty else { return }
        let work = queue.removeFirst()
        guard work.surface != nil else { startIfNeeded(); return }
        active = work
        response = ""
        let instructions = """
        You silently review one completed terminal command and decide whether useful next actions exist. Mundane success, expected output, and results with no meaningful next step are not worth analyzing. When worthwhile, generate the smallest useful set of complementary actions, up to three. An `insertCommand` action places a safe single-line shell command at the prompt for review. An `askAI` action sends its single-line question to Prompt's assistant only after the user clicks it. Choose concise verb-led labels and real macOS SF Symbol names that semantically fit each action. Never propose destructive commands. Do not explain or summarize the result; the UI displays only the generated buttons.
        """
        let evidence = """
        Return only JSON matching this shape:
        {"actions":[{"kind":"insertCommand|askAI","label":"...","value":"...","systemImage":"..."}]}
        Use {"actions":[]} when no action is worthwhile.

        Command: \(work.block.command)
        Exit code: \(work.block.exitCode)
        Duration: \(work.block.durationNanoseconds / 1_000_000) ms
        Working directory: \(work.block.cwd)
        """
        activeRequestID = CodexProvider.shared.respond(
            to: .init(
                text: evidence,
                instructions: instructions,
                modelID: CapabilityRouter.shared.route(for: .assistant)?.modelID
                    ?? DefaultAIModels.codex,
                projectRoot: work.block.cwd,
                terminalContext: String(work.block.snapshot.suffix(12_000)),
                conversationContext: "",
                allowsWorkspaceWrites: false)
        ) { [weak self] event in
            guard let self else { return }
            switch event {
            case .textDelta(let text):
                response += text
            case .completed:
                completeAnalysis()
            case .failed:
                finish()
            }
        }
    }

    private func completeAnalysis() {
            if let recommendation = PromptAmbientAnalysisResult.parse(response),
               let surface = active?.surface,
               PromptTerminalEnvironment.allowsRichContent(on: surface),
               PromptNativeInputRouter.promptInput(on: surface)?.isEmpty == true {
                PromptRichContentStore.shared.presentRecommendation(recommendation, on: surface)
            }
            finish()
    }

    private func finish() {
        activeRequestID = nil
        active = nil
        response = ""
        startIfNeeded()
    }
}
