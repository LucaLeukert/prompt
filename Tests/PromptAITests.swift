import Foundation
import AppKit
import CoreText
import GhosttyKit
import Testing
@testable import Prompt

@Suite("Prompt AI integration")
struct PromptAITests {
    @Test func tmuxControlOutputDecodesOctalAndEscapedBackslashes() {
        #expect(PromptTmuxControlParser.decode(#"hello\015\012path\\name"#) == Array("hello\r\npath\\name".utf8))
    }

    @Test func oldRemoteConfigurationsDecodeIntoControlMode() throws {
        let json = #"{"destination":"host","workingDirectory":"/srv/app","persistentSessionName":"prompt","attachOnly":false}"#
        let configuration = try JSONDecoder().decode(PromptRemoteSessionConfiguration.self, from: Data(json.utf8))
        #expect(configuration.transport == .controlMode)
        #expect(configuration.tmuxPaneID == nil)
    }

    @Test func tmuxControlParserSelectsActivePaneAndFiltersOtherOutput() {
        var output: [UInt8] = []
        let parser = PromptTmuxControlParser(requestedPane: nil) { output += $0 }
        parser.consume(line: "PROMPT_PANE=%1:0")
        parser.consume(line: "PROMPT_PANE=%2:1")
        parser.consume(line: #"%output %1 ignored\015\012"#)
        parser.consume(line: #"%output %2 selected\015\012"#)
        #expect(parser.selectedPane == "%2")
        #expect(String(decoding: output, as: UTF8.self) == "selected\r\n")
    }

    @Test @MainActor func tmuxPaneGeometryBuildsNativeSplitTree() {
        let left = PromptTerminalRuntime.RemotePaneDescriptor(id: "%1", active: true, command: "zsh", workingDirectory: "/a", left: 0, top: 0, width: 40, height: 24)
        let rightTop = PromptTerminalRuntime.RemotePaneDescriptor(id: "%2", active: false, command: "zsh", workingDirectory: "/b", left: 40, top: 0, width: 40, height: 12)
        let rightBottom = PromptTerminalRuntime.RemotePaneDescriptor(id: "%3", active: false, command: "zsh", workingDirectory: "/c", left: 40, top: 12, width: 40, height: 12)
        let panes = ["%1": PromptPane(), "%2": PromptPane(), "%3": PromptPane()]
        let tree = PromptWorkspaceStore.makeRemoteSplitTree([left, rightTop, rightBottom], panes: panes)
        guard case .split(.horizontal, _, .leaf, let right)? = tree,
              case .split(.vertical, _, .leaf, .leaf) = right else {
            Issue.record("Expected a native horizontal split with a nested vertical split")
            return
        }
    }

    @Test func remoteCommandStartsWithAnExecutable() {
        let command = PromptRemoteCommand.build(.init(
            destination: "pi",
            workingDirectory: "/home/luca",
            persistentSessionName: "prompt",
            attachOnly: false))

        #expect(command.contains(PromptTmuxControlBridge.argument))
        #expect(command.contains("'/home/luca'"))
        #expect(command.hasSuffix("create"))
    }

    @Test func remoteCommandExpandsHomeDirectoryOnRemoteHost() {
        let command = PromptRemoteCommand.buildLegacy(.init(
            destination: "pi",
            workingDirectory: "~",
            persistentSessionName: "prompt",
            attachOnly: false,
            transport: .legacyTTY))

        #expect(command.contains("cd -- \"$HOME\""))
        #expect(!command.contains("cd -- '~'"))
    }

    @Test @MainActor func persistentRemoteSessionCommandIsSafeAndReconnectable() {
        #expect(PromptSessionLauncher.isSafeRemote("dev@example.com"))
        #expect(PromptSessionLauncher.isSafeRemote("my-host"))
        #expect(!PromptSessionLauncher.isSafeRemote("host; reboot"))
        #expect(PromptSessionLauncher.isSafeSession("prompt_12.dev"))
        #expect(!PromptSessionLauncher.isSafeSession("bad name"))

        let create = PromptSessionLauncher.remoteCommand(
            destination: "dev@example.com", session: "prompt-1", attachOnly: false)
        #expect(create.contains(PromptTmuxControlBridge.argument))
        #expect(create.hasSuffix("create"))

        let attach = PromptSessionLauncher.remoteCommand(
            destination: "server", session: "main", attachOnly: true)
        #expect(attach.contains(PromptTmuxControlBridge.argument))
        #expect(attach.hasSuffix("attach"))

        let legacy = PromptRemoteCommand.buildLegacy(.init(
            destination: "server", workingDirectory: nil, persistentSessionName: "main",
            attachOnly: false, transport: .legacyTTY))
        #expect(legacy.contains("ServerAliveInterval=20"))
        #expect(legacy.contains("tmux new-session -A -s"))
        #expect(legacy.contains("reconnecting in 3s"))
    }

    @Test @MainActor func newRemoteSessionsUseDistinctSafeTmuxNames() {
        let first = PromptSessionLauncher.newRemoteSessionName()
        let second = PromptSessionLauncher.newRemoteSessionName()
        #expect(first != second)
        #expect(PromptSessionLauncher.isSafeSession(first))
        #expect(PromptSessionLauncher.isSafeSession(second))
    }

    @Test @MainActor func tailnetDiscoveryKeepsOnlinePeersWithReachableSSH() {
        let json = #"""
        {
          "BackendState": "Running",
          "Peer": {
            "one": { "DNSName": "server.example.ts.net.", "HostName": "server", "OS": "linux", "TailscaleIPs": ["100.64.0.1"], "Online": true },
            "two": { "DNSName": "phone.example.ts.net.", "HostName": "phone", "OS": "iOS", "TailscaleIPs": ["100.64.0.2"], "Online": true },
            "three": { "DNSName": "offline.example.ts.net.", "HostName": "offline", "OS": "linux", "TailscaleIPs": ["100.64.0.3"], "Online": false },
            "four": { "DNSName": "sleepy-server.example.ts.net.", "HostName": "sleepy-server", "OS": "linux", "TailscaleIPs": ["100.64.0.4"], "Online": true }
          }
        }
        """#
        var probed: [String] = []
        let hosts = PromptSessionLauncher.tailnetSSHHosts(from: Data(json.utf8)) { address in
            probed.append(address)
            return address == "100.64.0.1"
        }

        #expect(hosts == ["server.example.ts.net", "sleepy-server.example.ts.net"])
        #expect(Set(probed) == ["100.64.0.1", "100.64.0.2", "100.64.0.4"])
    }

    @Test @MainActor func tailnetDiscoveryRequiresRunningBackend() {
        let json = #"{"BackendState":"Stopped","Peer":{"one":{"DNSName":"server.ts.net.","TailscaleIPs":["100.64.0.1"],"Online":true}}}"#
        let hosts = PromptSessionLauncher.tailnetSSHHosts(from: Data(json.utf8)) { _ in true }
        #expect(hosts.isEmpty)
    }

    @Test @MainActor func tailnetMagicDNSNameMatchesShortSSHConfigAlias() {
        #expect(PromptSessionLauncher.tailnetHost("pi.tail7a47ac.ts.net", matchesSSHHost: "pi"))
        #expect(PromptSessionLauncher.tailnetHost("pi.tail7a47ac.ts.net.", matchesSSHHost: "user@pi"))
        #expect(!PromptSessionLauncher.tailnetHost("raspberrypi.tail7a47ac.ts.net", matchesSSHHost: "pi"))
    }

    @Test func debugModelOptionsIncludeLunaLow() {
        #expect(PromptModel.debugModelOptions.contains("gpt-5.6-luna"))
    }

    @Test func promptBuilderKeepsIrrelevantAmbientContextOut() {
        let prompt = PromptBuilder.build(.init(
            userText: "hello jhi",
            projectRoot: FileManager.default.temporaryDirectory.path,
            terminalText: "git status\nfatal: unrelated repository output"))
        #expect(prompt.userText == "hello jhi")
        #expect(prompt.contextText == nil)
        #expect(prompt.appServerInput.count == 1)
    }

    @Test func promptBuilderLeavesTerminalContextForToolsToFetch() {
        let prompt = PromptBuilder.build(.init(
            userText: "why did parser_build fail?",
            projectRoot: FileManager.default.temporaryDirectory.path,
            terminalText: "parser_build failed with exit code 1"))
        #expect(prompt.contextText == nil)
        #expect(prompt.appServerInput.count == 1)
    }

    @Test func promptBuilderSelectsTerminalLaneInstructions() {
        let assistant = PromptBuilder.build(.init(
            userText: "why did this fail?",
            projectRoot: "/tmp/project",
            terminalText: "build failed",
            lane: .assistant))
        let agent = PromptBuilder.build(.init(
            userText: "fix the failing tests",
            projectRoot: "/tmp/project",
            terminalText: "build failed",
            lane: .agent))
        #expect(assistant.baseInstructions == PromptBuilder.assistantInstructions)
        #expect(assistant.baseInstructions.contains("terminal_read"))
        #expect(assistant.baseInstructions.contains("terminal_read_file"))
        #expect(assistant.baseInstructions.contains("terminal_suggest_command"))
        #expect(assistant.baseInstructions.contains("do not probe several tools"))
        #expect(assistant.baseInstructions.contains("do not ask them to paste output"))
        #expect(assistant.baseInstructions.contains("Read named files directly"))
        #expect(assistant.baseInstructions.contains("does not perform the requested task"))
        #expect(assistant.baseInstructions.contains("Suggested a command that would"))
        #expect(assistant.baseInstructions.contains("how do I check what is on port 443"))
        #expect(assistant.baseInstructions.contains("actionable shell instructions"))
        #expect(agent.baseInstructions == PromptBuilder.agentInstructions)
        #expect(agent.baseInstructions.contains("not a code editor"))
    }

    @Test func promptBuilderConstrainsRemoteAssistantToRemoteTerminalTools() {
        let prompt = PromptBuilder.build(.init(
            userText: "inspect this output",
            projectRoot: "/tmp/local-placeholder",
            terminalText: "remote output",
            isRemote: true))
        #expect(prompt.baseInstructions == PromptBuilder.remoteAssistantInstructions)
        #expect(prompt.baseInstructions.contains("terminal_read"))
        #expect(prompt.baseInstructions.contains("terminal_suggest_command"))
        #expect(prompt.baseInstructions.contains("Remote file access") == true)
        #expect(prompt.baseInstructions.contains("Never use local workspace tools"))
    }

    @Test func terminalToolsAreStrictlyScopedByLane() {
        #expect(PromptTerminalTool.available(in: .assistant) == [.read, .readCommands, .readFile, .suggestCommand])
        #expect(PromptTerminalTool.available(in: .agent) == [.read, .readCommands, .readFile, .suggestCommand, .run])
        #expect(!PromptTerminalTool.read.requiresApproval)
        #expect(!PromptTerminalTool.readCommands.requiresApproval)
        #expect(!PromptTerminalTool.readFile.requiresApproval)
        #expect(!PromptTerminalTool.suggestCommand.requiresApproval)
        #expect(PromptTerminalTool.run.requiresApproval)
    }

    @Test func remoteTerminalToolsExposeOnlyImplementedCapabilities() {
        #expect(PromptTerminalTool.available(in: .assistant, isRemote: true) == [.read, .suggestCommand])
        #expect(PromptTerminalTool.available(in: .agent, isRemote: true) == [.read, .suggestCommand])
        #expect(PromptTerminalTool.available(in: .assistant, isRemote: false) == PromptTerminalTool.available(in: .assistant))
    }

    @Test func remoteAIExperimentIsDisabledUnlessExplicitlyEnabled() {
        let suite = "PromptAITests.RemoteAIExperiment.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Could not create an isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!PromptExperimentalFeatures.remoteAIEnabled(in: defaults))
        defaults.set(true, forKey: PromptExperimentalFeatures.remoteAIEnabledDefaultsKey)
        #expect(PromptExperimentalFeatures.remoteAIEnabled(in: defaults))
    }

    @Test func dynamicTerminalToolSpecsUseFunctionProtocol() {
        let spec = PromptTerminalTool.run.appServerSpec
        #expect(spec["type"] as? String == "function")
        #expect(spec["name"] as? String == "terminal_run")
        #expect(PromptTerminalTool(appServerName: "terminal_run") == .run)
        let schema = spec["inputSchema"] as? [String: Any]
        #expect(schema?["additionalProperties"] as? Bool == false)
        #expect(schema?["required"] as? [String] == ["command"])

        let suggestion = PromptTerminalTool.suggestCommand.appServerSpec
        #expect(suggestion["name"] as? String == "terminal_suggest_command")
        let description = suggestion["description"] as? String
        #expect(description?.contains("Proactively use this") == true)
        #expect(description?.contains("Do not merely print the command in prose") == true)
        #expect(description?.contains("does NOT press Enter") == true)
    }

    @Test func surfaceModeLaneCycleIsExhaustive() {
        #expect(PromptSurfaceMode.autoShell.next == .shell)
        #expect(PromptSurfaceMode.shell.next == .assistant)
        #expect(PromptSurfaceMode.assistant.next == .agent)
        #expect(PromptSurfaceMode.agent.next == .autoShell)
        #expect(PromptSurfaceMode.allCases.map(\.next) == [.shell, .assistant, .agent, .autoShell])
    }

    @Test func tabDispositionAlwaysPreservesPromptCompletion() {
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .autoShell, input: "git status", hasAutocomplete: false) == .passToTerminal)
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .autoShell, input: "git sta", hasAutocomplete: true) == .acceptAutocomplete)
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .autoShell, input: "why did this fail?", hasAutocomplete: true) == .acceptAutocomplete)
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .assistant, input: "git sta", hasAutocomplete: true) == .acceptAutocomplete)
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .agent, input: "git sta", hasAutocomplete: true) == .acceptAutocomplete)
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .assistant, input: "git sta", hasAutocomplete: false) == .passToTerminal)
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .agent, input: "what is in read", hasAutocomplete: true) == .acceptAutocomplete)
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .agent, input: "why did this fail?", hasAutocomplete: false) == .passToTerminal)
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .assistant, input: "what is in read", hasAutocomplete: false) == .passToTerminal)
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .autoShell, input: "", hasAutocomplete: false) == .switchMode(.shell))
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .shell, input: "", hasAutocomplete: false) == .switchMode(.assistant))
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .assistant, input: "", hasAutocomplete: false) == .switchMode(.agent))
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .agent, input: "", hasAutocomplete: false) == .switchMode(.autoShell))
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .autoShell, input: nil, hasAutocomplete: true) == .passToTerminal)
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .assistant, input: nil, hasAutocomplete: true) == .switchMode(.agent))
        #expect(PromptTabDisposition.resolve(
            surfaceMode: .agent, input: nil, hasAutocomplete: true) == .switchMode(.autoShell))
    }

    @Test func copilotCompletionDefaultsToShellInputScope() {
        #expect(PromptAutocompleteModel.shouldComplete(
            prefix: "git checkout feat", completesAIInput: false))
        #expect(PromptAutocompleteModel.shouldComplete(
            prefix: "cat READ", completesAIInput: false))
        #expect(!PromptAutocompleteModel.shouldComplete(
            prefix: "what is in read", completesAIInput: false))
        #expect(PromptAutocompleteModel.shouldComplete(
            prefix: "what is in read", completesAIInput: true))
        #expect(PromptAutocompleteModel.shouldComplete(
            prefix: "git checkout feat",
            completesAIInput: false,
            shell: "/bin/zsh",
            cwd: "/tmp"))
        #expect(!PromptAutocompleteModel.shouldComplete(
            prefix: "explain why the build failed",
            completesAIInput: false,
            shell: "/bin/zsh",
            cwd: "/tmp"))
    }

    @Test func submissionResolutionSeparatesShellAndAILanes() {
        #expect(PromptSubmissionResolution.resolve(surfaceMode: .autoShell, text: "git status") ==
            .init(mode: .shell, lane: nil))
        #expect(PromptSubmissionResolution.resolve(surfaceMode: .autoShell, text: "why did this fail?") ==
            .init(mode: .ai, lane: .assistant))
        #expect(PromptSubmissionResolution.resolve(surfaceMode: .shell, text: "why did this fail?") ==
            .init(mode: .shell, lane: nil))
        #expect(PromptSubmissionResolution.resolve(surfaceMode: .agent, text: "git status") ==
            .init(mode: .ai, lane: .agent))
        #expect(PromptSubmissionResolution.resolve(surfaceMode: .assistant, text: "git status") ==
            .init(mode: .ai, lane: .assistant))
    }

    @Test func suggestedCommandParserRequiresExactlyOneLine() {
        #expect(PromptSuggestedCommand.parse(#"{"command":"git status --short"}"#) == "git status --short")
        #expect(PromptSuggestedCommand.parse(#"{"command":""}"#) == nil)
        #expect(PromptSuggestedCommand.parse(#"{"command":"echo one\necho two"}"#) == nil)
        #expect(PromptSuggestedCommand.parse(#"{"command":"echo one\recho two"}"#) == nil)
        #expect(PromptSuggestedCommand.parse(#"{"command":null}"#) == nil)
        #expect(PromptSuggestedCommand.parse("not json") == nil)
    }

    @Test func ambientAnalysisOnlySurfacesWorthwhileSafeRecommendations() {
        let useful = PromptAmbientAnalysisResult.parse(
            #"{"worthAnalyzing":true,"actions":[{"kind":"insertCommand","title":"Find process","value":"lsof -nP -iTCP:8080 -sTCP:LISTEN","systemImage":"magnifyingglass"},{"kind":"askAI","title":"Understand failure","value":"Explain the last command failure","systemImage":"questionmark.circle"}]}"#)
        #expect(useful == .init(
            actions: [
                .init(
                    kind: .insertCommand,
                    title: "Find process",
                    value: "lsof -nP -iTCP:8080 -sTCP:LISTEN",
                    systemImage: "magnifyingglass"),
                .init(
                    kind: .askAI,
                    title: "Understand failure",
                    value: "Explain the last command failure",
                    systemImage: "questionmark.circle"),
            ]))
        #expect(PromptAmbientAnalysisResult.parse(
            #"{"worthAnalyzing":false,"actions":[]}"#) == nil)

        let invalidAction = PromptAmbientAnalysisResult.parse(
            "{\"worthAnalyzing\":true,\"actions\":[{\"kind\":\"insertCommand\",\"title\":\"Run\",\"value\":\"echo one\\necho two\",\"systemImage\":\"play.fill\"}]}")
        #expect(invalidAction == nil)

        let fallbackSymbol = PromptAmbientAnalysisResult.parse(
            #"{"worthAnalyzing":true,"actions":[{"kind":"insertCommand","title":"Inspect","value":"git status","systemImage":"not.a.real.symbol"}]}"#)
        #expect(fallbackSymbol?.actions.first?.systemImage == "sparkles")
    }

    @Test func terminalSubmissionEligibilitySerializesGlobalTurns() {
        #expect(PromptTerminalSubmissionEligibility.allows(connected: true, isRunning: false))
        #expect(!PromptTerminalSubmissionEligibility.allows(connected: false, isRunning: false))
        #expect(!PromptTerminalSubmissionEligibility.allows(connected: true, isRunning: true))
        #expect(!PromptTerminalSubmissionEligibility.allows(connected: false, isRunning: true))
    }

    @Test func insertionEligibilityRequiresStablePromptEnvironment() {
        #expect(PromptInsertionEligibility.allows(
            richContentAllowed: true, originalCWD: "/tmp/project", currentCWD: "/tmp/project", promptIsEmpty: true))
        #expect(!PromptInsertionEligibility.allows(
            richContentAllowed: false, originalCWD: "/tmp/project", currentCWD: "/tmp/project", promptIsEmpty: true))
        #expect(!PromptInsertionEligibility.allows(
            richContentAllowed: true, originalCWD: "/tmp/project", currentCWD: "/tmp/other", promptIsEmpty: true))
        #expect(!PromptInsertionEligibility.allows(
            richContentAllowed: true, originalCWD: "/tmp/project", currentCWD: "/tmp/project", promptIsEmpty: false))
    }

    @Test func copilotCompletionSuffixesAreCleanedForTerminalInsertion() {
        #expect(PromptAutocompleteModel.clean("git status --short\n", prefix: "git sta") == "tus --short")
        #expect(PromptAutocompleteModel.clean("```shell\ntus\n```", prefix: "git sta") == "tus")
    }

    @Test func completionContextResolvesPartialPathsAndGitProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/project-alpha"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/unrelated"), withIntermediateDirectories: true)
        try "ref: refs/heads/context-test\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = PromptCompletionContextEngine.build(
            prefix: "cd src/pro", cwd: root.path, terminal: "$ git status\nOn branch context-test")
        #expect(context.pathCandidates == ["src/project-alpha/"])
        #expect(context.document.contains("# Git branch: context-test"))
        #expect(context.document.contains("# - src/project-alpha/"))
        #expect(context.document.contains("# - cd src/project-alpha/"))
        #expect(context.document.split(separator: "\n", omittingEmptySubsequences: false)[context.commandLine] == "# ")
        #expect(context.expectsSuffixOnly)
    }

    @Test func completionContextPreservesNestedDirectoryPrefixesAndIgnoresTerminalPadding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Vendor/ghostty/macos"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = PromptCompletionContextEngine.build(
            prefix: "cd Vendor/ghostty/     ", cwd: root.path, terminal: "")
        #expect(context.pathCandidates == ["Vendor/ghostty/macos/"])
        #expect(context.document.contains("# - cd Vendor/ghostty/macos/"))
        #expect(context.document.split(separator: "\n", omittingEmptySubsequences: false)[context.commandLine] == "# ")
    }

    @Test func completionContextParsesPipelinesAndLoadsProjectScripts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"scripts":{"build":"swift build","test:unit":"swift test"},"dependencies":{"swift-argument-parser":"1.0.0"}}"#
            .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = PromptCompletionContextEngine.build(
            prefix: "echo ready | npm run bu", cwd: root.path, terminal: "$ npm run test:unit")
        #expect(context.document.contains("# Active command: npm"))
        #expect(context.document.contains("# Previous shell operator: |"))
        #expect(context.document.contains("# Cursor role: argument 2 for npm"))
        #expect(context.document.contains("# - npm run build"))
        #expect(context.document.contains("# - swift-argument-parser"))
    }

    @Test func completionContextRecognizesRedirectionTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try "".write(to: root.appendingPathComponent("logs/output.log"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = PromptCompletionContextEngine.build(
            prefix: "printf hello > logs/ou", cwd: root.path, terminal: "")
        #expect(context.pathCandidates == ["logs/output.log"])
        #expect(context.document.contains("# Cursor role: redirection target"))
        #expect(context.document.contains("# - printf hello > logs/output.log"))
    }

    @Test func completionContextLoadsGitRefsWithoutRunningGit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git/refs/heads/feature"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try "deadbeef\n".write(
            to: root.appendingPathComponent(".git/refs/heads/feature/context-engine"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let context = PromptCompletionContextEngine.build(
            prefix: "git switch fea", cwd: root.path, terminal: "")
        #expect(context.document.contains("# Git local branches:"))
        #expect(context.document.contains("# - feature/context-engine"))
        #expect(context.document.contains("# Git branch: main"))
    }

    @Test func completionContextHasAHardSizeBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dependencies = (0..<1_000).map { "\"dependency-\($0)\":\"1.0.0\"" }.joined(separator: ",")
        try "{\"dependencies\":{\(dependencies)}}".write(
            to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let terminal = (0..<200).map { "long-output-\($0)-" + String(repeating: "x", count: 250) }.joined(separator: "\n")
        let context = PromptCompletionContextEngine.build(prefix: "npm run bu", cwd: root.path, terminal: terminal)
        #expect(context.document.count < 19_000)
        #expect(context.document.split(separator: "\n", omittingEmptySubsequences: false)[context.commandLine] == "npm run bu")
    }

    @Test func richContentYieldsToExclusiveTerminalApplications() {
        #expect(!PromptTerminalEnvironment.allowsRichContent(alternateScreen: true, process: "zsh"))
        #expect(!PromptTerminalEnvironment.allowsRichContent(alternateScreen: false, process: "vim"))
        #expect(!PromptTerminalEnvironment.allowsRichContent(alternateScreen: false, process: "ssh"))
        #expect(PromptTerminalEnvironment.allowsRichContent(alternateScreen: false, process: "zsh"))
    }

    @Test func richParserSeparatesMarkdownAndLatex() {
        #expect(PromptRichParser.segments("## Result\n\n$$x = \\frac{1}{2}$$\n\nDone.") == [
            .markdown("## Result\n\n"),
            .math("x = \\frac{1}{2}"),
            .markdown("\n\nDone."),
        ])
        #expect(PromptRichParser.segments("Streaming $x + 1") == [
            .markdown("Streaming $x + 1"),
        ])
    }

    @Test func projectResolverFindsGitRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("Sources/Feature")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ProjectResolver.resolve(from: nested.path) == root.path)
    }

    @Test func projectResolverRecognizesGitWorktreeFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "gitdir: /tmp/prompt-main/.git/worktrees/feature\n"
            .write(to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let nested = root.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(ProjectResolver.resolve(from: nested.path) == root.path)
    }

    @Test func requestIDsDecodeBothJSONRepresentations() {
        #expect(CodexAppServer.stringID(42) == "42")
        #expect(CodexAppServer.stringID("thread-request") == "thread-request")
        #expect(CodexAppServer.stringID(nil) == nil)
    }

    @Test func inputClassifierSeparatesShellFromNaturalLanguage() {
        #expect(PromptInputClassifier.classify("git status --short") == .shell)
        #expect(PromptInputClassifier.classify("npm test && echo done") == .shell)
        #expect(PromptInputClassifier.classify("why did the last build fail?") == .ai)
        // `what` is a real executable on macOS, but these are requests rather
        // than invocations of that executable.
        #expect(PromptInputClassifier.classify("what is running on 5555") == .ai)
        // A local session supplies its cwd while managed remotes intentionally
        // use the same local zsh probe without a remote cwd.
        let localAndRemoteCWDs: [String?] = ["/tmp", nil]
        for cwd in localAndRemoteCWDs {
            #expect(PromptInputClassifier.classify(
                "what is the capital of France", shell: "/bin/zsh", cwd: cwd) == .ai)
            #expect(PromptInputClassifier.classify(
                "tell me a poem", shell: "/bin/zsh", cwd: cwd) == .ai)
        }
        #expect(PromptInputClassifier.classify("what --help") == .shell)
        #expect(PromptInputClassifier.classify("what is $PATH") == .shell)
        #expect(PromptInputClassifier.classify("explain this repository") == .ai)
        #expect(PromptInputClassifier.classify("okay can you inspect this") == .ai)
        #expect(PromptInputClassifier.classify("review the changes") == .ai)
        #expect(PromptInputClassifier.classify("cd src/prompt") == .shell)
        #expect(PromptInputClassifier.classify(
            "vi ~/.ssh/known_hosts", shell: "/bin/zsh", cwd: "/tmp") == .shell)
        #expect(PromptInputClassifier.classify(
            "why did this fail?", shell: "/bin/zsh", cwd: "/tmp") == .ai)
        #expect(PromptInputClassifier.classify(
            "FOO=bar printf '%s\\n' ok", shell: "/bin/zsh", cwd: "/tmp") == .shell)
        #expect(PromptInputClassifier.classify("FOO=bar npm test") == .shell)
        #expect(PromptInputClassifier.classify("rg TODO Sources --glob *.swift") == .shell)
        #expect(PromptInputClassifier.classify("/ai ls is behaving strangely") == .ai)
        #expect(PromptInputClassifier.classify("/shell explain --help") == .shell)
        #expect(PromptInputClassifier.strippedInput("? explain this") == "explain this")
    }

    @Test func shellProbeNeverExecutesSubmittedPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = root.appendingPathComponent("existing")
        let original = Data("safe".utf8)
        try original.write(to: existing)
        let targets = (0..<8).map { root.appendingPathComponent("created-\($0)") }
        let payloads = [
            "touch \(targets[0].path)",
            "printf owned > \(targets[1].path)",
            "echo $(touch \(targets[2].path))",
            "cat <(touch \(targets[3].path))",
            "echo owned | tee \(targets[4].path)",
            "touch \(targets[5].path) &",
            "trap 'touch \(targets[6].path)' EXIT",
            "command rm -f \(existing.path)",
            ": > \(existing.path)",
        ]

        for payload in payloads {
            _ = PromptInputClassifier.classify(payload, shell: "/bin/zsh", cwd: root.path)
        }

        #expect(try Data(contentsOf: existing) == original)
        for target in targets {
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func geistVariableFontsAreBundledAndResolvable() {
        #expect(PromptTypography.verifyGeistInstallation())
    }

    @Test func contextEngineLeavesWorkspaceDiscoveryToAgentTools() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Always run focused tests.".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "struct ContextBeacon { let retrievalSignal = true }".write(
            to: root.appendingPathComponent("Beacon.swift"), atomically: true, encoding: .utf8)
        try runGit(["init", "-q"], at: root)
        try runGit(["add", "AGENTS.md", "Beacon.swift"], at: root)

        let context = PromptContextEngine.shared.retrieve(
            query: "Where is retrievalSignal?",
            projectRoot: root.path,
            terminal: "build failed in Beacon.swift")
        #expect(!context.contains("Beacon.swift"))
        #expect(!context.contains("retrievalSignal"))
        #expect(!context.contains("[rules: AGENTS.md]"))
    }

    @Test func structuredCommandProposalCanPopulateComposer() {
        let output = PromptCommandProposal.parse(#"{"response":"No listener found.","command":"lsof -nP -i :4444"}"#)
        #expect(output?.response == "No listener found.")
        #expect(output?.command == "lsof -nP -i :4444")
        #expect(PromptCommandProposal.parse(#"{"response":"Bad","command":"echo one\necho two"}"#) == nil)
        #expect(PromptCommandProposal.parse("```json\n{}\n```") == nil)
        #expect(PromptCommandProposal.fromExecutedCommands(["lsof -nP -i :4444"], request: "what process is on port 4444") == "lsof -nP -i :4444")
        #expect(PromptCommandProposal.fromExecutedCommands(["rg TODO"], request: "review the code") == nil)
    }

    @Test func richContentReservationTracksVisualContent() {
        let short = PromptRichContentStore.requiredRows(
            request: "hello", response: "Short answer.", toolCalls: 0, columns: 80)
        let long = PromptRichContentStore.requiredRows(
            request: "read this", response: String(repeating: "wrapped content ", count: 80), toolCalls: 2, columns: 40)
        #expect(short == 8)
        #expect(long > short)
        #expect(long <= 80)
        #expect(PromptRichContentStore.nextReservationRows(
            current: 6, required: 40, maximum: 24, frozen: false) == 24)
        #expect(PromptRichContentStore.nextReservationRows(
            current: 6, required: 40, maximum: 24, frozen: true) == 6)
    }

    @Test @MainActor func compositeSurfaceMirrorsOutputAndForwardsEncodedInput() async throws {
        guard let delegate = NSApplication.shared.delegate as? PromptApplicationDelegate else {
            Issue.record("Prompt application delegate is unavailable")
            return
        }
        let application = delegate.runtime.application
        let router = PromptCompositeIORouter()
        let presentationConfiguration = GhosttyAppKitSurfaceConfiguration(
            workingDirectory: nil,
            command: nil,
            initialInput: nil,
            manualIOWriteHandler: { [weak router] data in router?.forwardInput(data) })
        guard let presentation = application.makeSurface(configuration: presentationConfiguration) else {
            Issue.record("Failed to create manual presentation surface")
            return
        }
        let authorityConfiguration = GhosttyAppKitSurfaceConfiguration(
            workingDirectory: nil,
            command: "/bin/cat",
            initialInput: nil)
        guard let authority = application.makeSurface(configuration: authorityConfiguration) else {
            Issue.record("Failed to create authoritative PTY surface")
            return
        }
        let surface = PromptTerminalSurface.wrap(presentation.hostedView)
        surface.configureComposite(authority: authority, router: router)

        // Keep this hidden pair alive until the test host exits. Closing the
        // last PTY-backed libghostty surface is an application-level quit
        // request, which would terminate the shared XCTest host and make this
        // integration test disrupt otherwise unrelated tests.
        _ = Unmanaged.passRetained(surface)

        surface.sendText("composite-io-probe")
        PromptController.pressReturn(on: surface)

        let deadline = ContinuousClock.now + .seconds(2)
        var contents = ""
        repeat {
            try await Task.sleep(for: .milliseconds(20))
            contents = screenText(surface)
        } while !contents.contains("composite-io-probe") && ContinuousClock.now < deadline

        #expect(contents.contains("composite-io-probe"))
    }

    @MainActor
    private func screenText(_ surface: PromptTerminalSurface) -> String {
        guard let handle = surface.surfaceHandle else { return "" }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(handle, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(handle, &text) }
        guard let value = text.text else { return "" }
        return String(cString: value)
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
