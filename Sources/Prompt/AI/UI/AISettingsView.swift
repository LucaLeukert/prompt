import AppKit
import SwiftUI

@MainActor
final class AISettingsWindowController: NSWindowController {
    static let shared = AISettingsWindowController()

    private init() {
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: AISettingsView()))
        window.title = "AI Providers"
        window.setContentSize(.init(width: 680, height: 560))
        window.minSize = .init(width: 600, height: 480)
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AISettingsView: View {
    @ObservedObject private var registry = AIProviderRegistry.shared
    @ObservedObject private var router = CapabilityRouter.shared
    @State private var apiKey = ""
    @State private var loginMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Providers").font(.title2.bold())
                    Text("Choose a provider and model independently for each capability.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("Capability routing") {
                    VStack(spacing: 12) {
                        routeRow(.assistant)
                        Divider()
                        routeRow(.agent)
                        Divider()
                        routeRow(.autocomplete)
                    }
                    .padding(.vertical, 6)
                }

                GroupBox("Providers") {
                    VStack(spacing: 0) {
                        ForEach(providerDescriptors, id: \.id) { descriptor in
                            providerRow(descriptor)
                            if descriptor.id != providerDescriptors.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 600, minHeight: 480)
    }

    private var providerDescriptors: [AIProviderDescriptor] {
        registry.providers.values.map(\.descriptor)
            .sorted { $0.displayName < $1.displayName }
    }

    @ViewBuilder
    private func routeRow(_ capability: AICapability) -> some View {
        let route = router.route(for: capability)
        let choices = registry.providers(for: capability)
        HStack(spacing: 12) {
            Image(systemName: capabilityIcon(capability))
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(capability.rawValue.capitalized)
                .fontWeight(.semibold)
                .frame(width: 110, alignment: .leading)
            Picker("", selection: Binding(
                get: { route?.providerID ?? choices.first?.descriptor.id ?? .codex },
                set: { providerID in
                    let model = defaultModel(providerID, capability: capability)
                    router.set(providerID: providerID, modelID: model, for: capability)
                }
            )) {
                ForEach(choices, id: \.descriptor.id) { provider in
                    Text(provider.descriptor.displayName).tag(provider.descriptor.id)
                }
            }
            .labelsHidden()
            TextField("Model", text: Binding(
                get: { router.route(for: capability)?.modelID ?? "" },
                set: { model in
                    guard let providerID = router.route(for: capability)?.providerID else { return }
                    router.set(providerID: providerID, modelID: model, for: capability)
                }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
        }
    }

    @ViewBuilder
    private func providerRow(_ descriptor: AIProviderDescriptor) -> some View {
        let provider = registry.provider(id: descriptor.id)
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: descriptor.systemImage).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.displayName).fontWeight(.semibold)
                    Text(descriptor.capabilities.map(\.rawValue.capitalized).sorted().joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(provider?.status.isReady == true ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(statusText(provider?.status ?? .stopped))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if descriptor.id == .openAI {
                HStack {
                    SecureField("OpenAI API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        guard APIKeyStore.shared.setKey(apiKey, for: .openAI) else {
                            loginMessage = "Could not save the API key in Keychain."
                            return
                        }
                        apiKey = ""
                        OpenAIProvider.shared.start(cwd: AIModel.shared.projectRoot)
                        loginMessage = "OpenAI API key saved in Keychain."
                    }
                    Button("Remove") {
                        _ = APIKeyStore.shared.removeKey(for: .openAI)
                        OpenAIProvider.shared.start(cwd: AIModel.shared.projectRoot)
                    }
                }
            } else if descriptor.id == .codex,
                      provider?.status.isReady != true {
                Button("Sign in with ChatGPT") {
                    CodexProvider.shared.startLogin { message in loginMessage = message }
                }
            }
            if !loginMessage.isEmpty {
                Text(loginMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }

    private func defaultModel(_ providerID: AIProviderID, capability: AICapability) -> String {
        switch providerID {
        case .codex: DefaultAIModels.codex
        case .openAI: "gpt-5.1"
        case .copilot: capability == .autocomplete ? "copilot-default" : "gpt-5.1"
        default: ""
        }
    }

    private func capabilityIcon(_ capability: AICapability) -> String {
        switch capability {
        case .assistant: "bubble.left.and.text.bubble.right"
        case .agent: "hammer"
        case .autocomplete: "text.cursor"
        }
    }

    private func statusText(_ status: AIProviderStatus) -> String {
        switch status {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .ready(let account): account ?? "Ready"
        case .unavailable(.runtimeMissing(let runtime)): "\(runtime) missing"
        case .unavailable(.authenticationRequired): "Sign-in required"
        case .unavailable(.invalidCredential): "Invalid credential"
        case .unavailable(.incompatibleRuntime(let detail)): detail
        case .unavailable(.unsupportedModel(let model)): "Unsupported model: \(model)"
        case .unavailable(.rateLimited(let reset)): reset ?? "Rate limited"
        case .unavailable(.network(let detail)): detail
        case .failed(let detail): detail
        }
    }
}
