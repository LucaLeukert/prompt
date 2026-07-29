import Foundation

@MainActor
final class AIProviderRegistry: ObservableObject {
    static let shared = AIProviderRegistry()

    @Published private(set) var providers: [AIProviderID: any AIProvider] = [:]

    private init() {}

    func register(_ provider: any AIProvider) {
        precondition(
            providers[provider.descriptor.id] == nil,
            "An AI provider with id \(provider.descriptor.id.rawValue) is already registered")
        providers[provider.descriptor.id] = provider
    }

    func provider(id: AIProviderID) -> (any AIProvider)? {
        providers[id]
    }

    func providers(for capability: AICapability) -> [any AIProvider] {
        providers.values
            .filter { $0.descriptor.capabilities.contains(capability) }
            .sorted { $0.descriptor.displayName < $1.descriptor.displayName }
    }

    func hasReadyProvider(for capability: AICapability) -> Bool {
        providers(for: capability).contains { $0.status(for: capability).isReady }
    }

    func providerStatusDidChange() {
        objectWillChange.send()
    }

    func startAll(cwd: String) {
        providers.values.forEach { $0.start(cwd: cwd) }
    }
}

@MainActor
final class CapabilityRouter: ObservableObject {
    static let shared = CapabilityRouter()
    private static let settingsKey = "AIRoutes.v1"

    @Published private(set) var routes: [AICapability: CapabilityRoute]
    private let settings: PromptSettings

    init(settings: PromptSettings = .shared) {
        self.settings = settings
        let saved: [CapabilityRoute] = settings.value(forKey: Self.settingsKey) ?? []
        routes = Dictionary(uniqueKeysWithValues: saved.map { ($0.capability, $0) })
        if routes[.assistant] == nil {
            routes[.assistant] = .init(
                capability: .assistant,
                providerID: .codex,
                modelID: DefaultAIModels.codex)
        }
        if routes[.agent] == nil {
            routes[.agent] = .init(
                capability: .agent,
                providerID: .codex,
                modelID: DefaultAIModels.codex)
        }
        if routes[.autocomplete] == nil {
            routes[.autocomplete] = .init(
                capability: .autocomplete,
                providerID: .copilot,
                modelID: "copilot-default")
        }
    }

    func route(for capability: AICapability) -> CapabilityRoute? {
        routes[capability]
    }

    func set(providerID: AIProviderID, modelID: String, for capability: AICapability) {
        guard AIProviderRegistry.shared.provider(id: providerID)?
            .descriptor.capabilities.contains(capability) == true else { return }
        routes[capability] = .init(
            capability: capability,
            providerID: providerID,
            modelID: modelID)
        persist()
    }

    func provider(for capability: AICapability) -> (any AIProvider)? {
        guard let route = route(for: capability),
              let provider = AIProviderRegistry.shared.provider(id: route.providerID),
              provider.descriptor.capabilities.contains(capability) else { return nil }
        return provider
    }

    private func persist() {
        settings.set(
            AICapability.allCases.compactMap { routes[$0] },
            forKey: Self.settingsKey)
    }
}

enum DefaultAIModels {
    static let codex = "gpt-5.3-codex-spark"
}
