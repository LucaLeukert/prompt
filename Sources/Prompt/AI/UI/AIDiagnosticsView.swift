#if DEBUG
    import AppKit
    import SwiftUI

    @MainActor
    protocol AIDebugPageProviding {
        var debugPageTitle: String { get }
        func makeDebugPage() -> AnyView
    }

    @MainActor
    final class AIDiagnosticsWindowController: NSWindowController {
        static let shared = AIDiagnosticsWindowController()

        private init() {
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: AIDiagnosticsView()))
            window.title = "AI Diagnostics"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 840, height: 600))
            window.minSize = NSSize(width: 700, height: 460)
            window.isReleasedWhenClosed = false
            super.init(window: window)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func show() {
            AISystem.bootstrap(cwd: FileManager.default.homeDirectoryForCurrentUser.path)
            showWindow(nil)
            window?.center()
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private struct AIDiagnosticsView: View {
        @ObservedObject private var debug = PromptAIDebugModel.shared
        @ObservedObject private var registry = AIProviderRegistry.shared
        @State private var selection = "overview"

        private var pages: [(id: String, title: String, page: any AIDebugPageProviding)] {
            registry.providers.values.compactMap { provider in
                guard let page = provider as? any AIDebugPageProviding else { return nil }
                return (provider.descriptor.id.rawValue, page.debugPageTitle, page)
            }.sorted { $0.title < $1.title }
        }

        var body: some View {
            NavigationSplitView {
                List(selection: $selection) {
                    Text("Overview").tag("overview")
                    Section("Providers") {
                        ForEach(pages, id: \.id) { page in
                            Text(page.title).tag(page.id)
                        }
                    }
                    Text("All Events").tag("events")
                }
                .navigationSplitViewColumnWidth(min: 150, ideal: 180)
            } detail: {
                if selection == "overview" {
                    AIOverviewDebugPage()
                } else if selection == "events" {
                    AIEventLogView(events: PromptAIDebugModel.shared.events)
                } else if let page = pages.first(where: { $0.id == selection }) {
                    page.page.makeDebugPage()
                } else {
                    VStack {
                        Image(systemName: "wrench.and.screwdriver")
                        Text("No Debug Page")
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    struct AIOverviewDebugPage: View {
        @ObservedObject private var debug = PromptAIDebugModel.shared
        @ObservedObject private var registry = AIProviderRegistry.shared
        @ObservedObject private var router = CapabilityRouter.shared

        var body: some View {
            List {
                ForEach(
                    registry.providers.values.sorted {
                        $0.descriptor.displayName < $1.descriptor.displayName
                    },
                    id: \.descriptor.id
                ) { provider in
                    Section(provider.descriptor.displayName) {
                        LabeledContent("Overall", value: provider.status.debugLabel)
                        ForEach(
                            provider.descriptor.capabilities.sorted { $0.rawValue < $1.rawValue },
                            id: \.self
                        ) { capability in
                            LabeledContent(capability.rawValue.capitalized) {
                                Text(provider.status(for: capability).debugLabel)
                                if router.route(for: capability)?.providerID == provider.descriptor.id {
                                    Text("Selected").foregroundStyle(.secondary)
                                }
                            }
                        }
                        LabeledContent("Identifier", value: provider.descriptor.id.rawValue)
                    }
                }
                Section("Telemetry") {
                    LabeledContent("Buffered events", value: "\(debug.events.count)")
                }
            }
            .navigationTitle("AI Overview")
        }
    }

    struct ProviderDebugPage: View {
        let provider: any AIProvider
        let services: [String]
        @ObservedObject private var debug = PromptAIDebugModel.shared

        private var events: [PromptAIDebugEvent] {
            debug.events.filter { services.contains($0.service) }
        }

        var body: some View {
            VStack(spacing: 0) {
                Form {
                    Section("Provider") {
                        LabeledContent("Status", value: provider.status.debugLabel)
                        LabeledContent("Identifier", value: provider.descriptor.id.rawValue)
                        ForEach(
                            provider.descriptor.capabilities.sorted { $0.rawValue < $1.rawValue },
                            id: \.self
                        ) { capability in
                            LabeledContent(
                                capability.rawValue.capitalized,
                                value: provider.status(for: capability).debugLabel)
                        }
                    }
                    HStack {
                        Button("Start") {
                            provider.start(cwd: FileManager.default.homeDirectoryForCurrentUser.path)
                        }
                        Button("Stop") { provider.stop() }
                        Spacer()
                    }
                }
                .formStyle(.grouped)
                .frame(maxHeight: 260)
                Divider()
                AIEventLogView(events: events)
            }
            .navigationTitle(provider.descriptor.displayName)
        }
    }

    struct CodexDebugPage: View {
        @ObservedObject private var model = AIModel.shared
        @ObservedObject private var debug = PromptAIDebugModel.shared
        @State private var message = ""
        @State private var isWorking = false

        private var events: [PromptAIDebugEvent] {
            debug.events.filter {
                ["ChatGPT (Codex)", "Ambient Command Analysis"].contains($0.service)
            }
        }

        var body: some View {
            VStack(spacing: 0) {
                Form {
                    Section("Account") {
                        LabeledContent("Provider", value: "ChatGPT (Codex)")
                        LabeledContent("Status", value: CodexProvider.shared.status.debugLabel)
                        LabeledContent("Account", value: model.account)
                        LabeledContent("Transport", value: "Ephemeral Codex CLI")
                        HStack {
                            Button("Sign In with ChatGPT") {
                                perform { done in
                                    CodexProvider.shared.startLogin(completion: done)
                                }
                            }
                            Button("Check Account") {
                                perform { done in
                                    CodexProvider.shared.refreshAccount(completion: done)
                                }
                            }
                            Button("Sign Out") {
                                perform { done in
                                    CodexProvider.shared.logout(completion: done)
                                }
                            }
                            if isWorking { ProgressView().controlSize(.small) }
                            Spacer()
                        }
                        if !message.isEmpty {
                            Text(message)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Section("Runtime") {
                        LabeledContent("Project root", value: model.projectRoot)
                        LabeledContent("Default model", value: DefaultAIModels.codex)
                        LabeledContent("Persistence", value: "Ephemeral; no Codex session files")
                        HStack {
                            Button("Refresh Account") { model.refresh() }
                            Button("Stop") { CodexProvider.shared.stop() }
                            Spacer()
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(minHeight: 270, idealHeight: 310, maxHeight: 350)
                Divider()
                AIEventLogView(events: events, title: "Codex Activity")
            }
            .navigationTitle("ChatGPT (Codex)")
        }

        private func perform(_ action: (@escaping (String) -> Void) -> Void) {
            isWorking = true
            message = ""
            action { result in
                message = result
                isWorking = false
            }
        }
    }

    struct OpenAIDebugPage: View {
        @ObservedObject private var debug = PromptAIDebugModel.shared
        @State private var apiKey = ""
        @State private var message = ""

        private var events: [PromptAIDebugEvent] {
            debug.events.filter { $0.service == "OpenAI API" }
        }

        var body: some View {
            VStack(spacing: 0) {
                Form {
                    Section("Credential") {
                        LabeledContent("Status", value: OpenAIProvider.shared.status.debugLabel)
                        SecureField("OpenAI API key", text: $apiKey)
                        HStack {
                            Button("Save API Key") {
                                let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard APIKeyStore.shared.setKey(key, for: .openAI) else {
                                    message = "The API key could not be saved to Keychain."
                                    return
                                }
                                apiKey = ""
                                OpenAIProvider.shared.start(cwd: AIModel.shared.projectRoot)
                                message = "API key saved to Keychain."
                            }
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Remove API Key") {
                                _ = APIKeyStore.shared.removeKey(for: .openAI)
                                OpenAIProvider.shared.start(cwd: AIModel.shared.projectRoot)
                                message = "API key removed."
                            }
                            Spacer()
                        }
                        Text("This provider uses OpenAI API billing. ChatGPT sign-in and subscriptions do not supply an API key.")
                            .foregroundStyle(.secondary)
                        if !message.isEmpty {
                            Text(message)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(minHeight: 230, idealHeight: 260, maxHeight: 300)
                Divider()
                AIEventLogView(events: events, title: "OpenAI API Activity")
            }
            .navigationTitle("OpenAI API")
        }
    }

    struct CopilotDebugPage: View {
        @ObservedObject private var debug = PromptAIDebugModel.shared
        @ObservedObject private var router = CapabilityRouter.shared
        @State private var prefix = "git "
        @State private var cwd = FileManager.default.homeDirectoryForCurrentUser.path
        @State private var terminal = ""
        @State private var result = "No test has been run."
        @State private var isTesting = false
        @State private var activeTestID: UUID?

        private var events: [PromptAIDebugEvent] {
            debug.events.filter { $0.service.contains("Copilot") }
        }

        var body: some View {
            VStack(spacing: 0) {
                Form {
                    Section("Adapter") {
                        LabeledContent(
                            "Route",
                            value: router.route(for: .autocomplete)?.providerID.rawValue ?? "None")
                        LabeledContent(
                            "Status",
                            value: CopilotProvider.shared.status(for: .autocomplete).debugLabel)
                    }
                    Section("Completion test") {
                        TextField("Command prefix", text: $prefix)
                            .font(.system(.body, design: .monospaced))
                        TextField("Terminal directory", text: $cwd)
                            .font(.system(.body, design: .monospaced))
                        TextField("Terminal context", text: $terminal, axis: .vertical)
                            .lineLimit(2 ... 4)
                            .font(.system(.body, design: .monospaced))
                        HStack {
                            Button("Run", action: runCompletionTest)
                                .disabled(isTesting || prefix.isEmpty)
                            Button("Restart") {
                                CopilotProvider.shared.stop()
                                CopilotProvider.shared.start(cwd: safeCWD)
                            }
                            if isTesting { ProgressView().controlSize(.small) }
                            Spacer()
                        }
                    }
                    Section("Result") {
                        Text(result)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 45, alignment: .topLeading)
                    }
                }
                .formStyle(.grouped)
                .frame(minHeight: 280, idealHeight: 340, maxHeight: 380)
                Divider()
                AIEventLogView(events: events, title: "Copilot Activity")
            }
            .navigationTitle("GitHub Copilot")
        }

        private var safeCWD: String {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory)
                && isDirectory.boolValue
                ? cwd
                : FileManager.default.homeDirectoryForCurrentUser.path
        }

        private func runCompletionTest() {
            let testID = UUID()
            activeTestID = testID
            isTesting = true
            result = "Waiting for Copilot…"
            CopilotProvider.shared.start(cwd: safeCWD)
            CopilotProvider.shared.complete(
                .init(prefix: prefix, cwd: safeCWD, terminal: terminal)
            ) { response in
                guard activeTestID == testID else { return }
                activeTestID = nil
                isTesting = false
                switch response {
                case .success(let candidates):
                    result = candidates.isEmpty
                        ? "No suggestions returned. Inspect the request and raw response below."
                        : candidates.enumerated().map { "\($0.offset + 1). \($0.element.text)" }
                        .joined(separator: "\n")
                case .failure(let error):
                    result = "Error: \(error.localizedDescription)"
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                guard activeTestID == testID else { return }
                activeTestID = nil
                isTesting = false
                result = "Timed out after 15 seconds."
            }
        }
    }

    struct AIEventLogView: View {
        @ObservedObject private var debug = PromptAIDebugModel.shared
        let events: [PromptAIDebugEvent]
        var title = "Event Log"
        @State private var selectedEventID: UUID?

        private var selectedEvent: PromptAIDebugEvent? {
            events.first { $0.id == selectedEventID }
        }

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Text(title).fontWeight(.medium)
                    Text("\(events.count)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Selected") {
                        if let selectedEvent {
                            copyText(Self.formattedPayload(selectedEvent.message))
                        }
                    }
                    .disabled(selectedEvent == nil)
                    Button("Copy All") { copy(events) }
                    Button("Clear All") { debug.clear() }
                }
                .padding(8)
                Divider()
                List(selection: $selectedEventID) {
                    ForEach(events.reversed()) { event in
                        HStack(spacing: 8) {
                            Text(Self.formatter.string(from: event.date))
                                .foregroundStyle(.secondary)
                                .frame(width: 76, alignment: .leading)
                            Text(event.service)
                                .frame(width: 128, alignment: .leading)
                            Text(event.level)
                                .frame(width: 104, alignment: .leading)
                            Text(event.message.replacingOccurrences(of: "\n", with: " ↵ "))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .tag(event.id)
                    }
                }
                .frame(minHeight: 120)
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    Text(Self.highlightedPayload(
                        selectedEvent?.message
                            ?? "Select an event to inspect its full payload."))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(8)
                }
                .frame(minHeight: 90, idealHeight: 150)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }

        private func copy(_ events: [PromptAIDebugEvent]) {
            let text = events.map {
                "\(Self.formatter.string(from: $0.date)) [\($0.service)] [\($0.level)] \($0.message)"
            }.joined(separator: "\n")
            copyText(text)
        }

        private func copyText(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        private static func formattedPayload(_ value: String) -> String {
            guard let data = value.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  JSONSerialization.isValidJSONObject(object),
                  let formatted = try? JSONSerialization.data(
                      withJSONObject: object,
                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: formatted, encoding: .utf8) else {
                return value
            }
            return text
        }

        private static func highlightedPayload(_ value: String) -> AttributedString {
            let text = formattedPayload(value)
            var output = AttributedString(text)
            applyColor(#""(?:\\.|[^"\\])*""#, color: .systemGreen, text: text, to: &output)
            applyColor(#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, color: .systemOrange, text: text, to: &output)
            applyColor(#"\b(?:true|false|null)\b"#, color: .systemPurple, text: text, to: &output)
            applyColor(#""(?:\\.|[^"\\])*"(?=\s*:)"#, color: .systemBlue, text: text, to: &output)
            return output
        }

        private static func applyColor(
            _ pattern: String,
            color: NSColor,
            text: String,
            to output: inout AttributedString
        ) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let stringRange = Range(match.range, in: text),
                      let attributedRange = Range(stringRange, in: output) else { continue }
                output[attributedRange].foregroundColor = Color(nsColor: color)
            }
        }

        private static let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter
        }()
    }

    extension AIProviderStatus {
        var debugLabel: String {
            switch self {
            case .stopped: "Stopped"
            case .starting: "Starting"
            case .ready(let account): account.map { "Ready (\($0))" } ?? "Ready"
            case .unavailable(let issue): "Unavailable: \(String(describing: issue))"
            case .failed(let message): "Failed: \(message)"
            }
        }
    }

#endif
