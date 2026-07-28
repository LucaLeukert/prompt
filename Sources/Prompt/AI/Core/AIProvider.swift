import Foundation

enum AICapability: String, Codable, CaseIterable, Hashable {
    case assistant
    case agent
    case autocomplete
}

struct AIProviderTraits: OptionSet, Hashable {
    let rawValue: Int

    static let streaming = Self(rawValue: 1 << 0)
    static let cancellation = Self(rawValue: 1 << 1)
    static let structuredOutput = Self(rawValue: 1 << 2)
    static let toolCalling = Self(rawValue: 1 << 3)
    static let persistentSessions = Self(rawValue: 1 << 4)
    static let modelDiscovery = Self(rawValue: 1 << 5)
    static let accountInformation = Self(rawValue: 1 << 6)
}

struct AIProviderID: RawRepresentable, Codable, Hashable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        rawValue = value
    }

    static let openAI: Self = "openai-api"
    static let codex: Self = "openai-codex"
    static let copilot: Self = "github-copilot"
}

struct AIProviderDescriptor: Hashable {
    let id: AIProviderID
    let displayName: String
    let systemImage: String
    let capabilities: Set<AICapability>
    let traits: AIProviderTraits
}

struct AIModelDescriptor: Identifiable, Hashable {
    let id: String
    let displayName: String
}

enum AIAvailabilityIssue: Equatable {
    case runtimeMissing(String)
    case authenticationRequired
    case invalidCredential
    case incompatibleRuntime(String)
    case unsupportedModel(String)
    case rateLimited(String?)
    case network(String)
}

enum AIProviderStatus: Equatable {
    case stopped
    case starting
    case ready(account: String?)
    case unavailable(AIAvailabilityIssue)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum AIProviderRepairAction: Equatable {
    case authenticate
    case configureAPIKey
    case openURL(URL)
    case installRuntime(name: String, url: URL)
    case retry
}

@MainActor
protocol AIProvider: AnyObject {
    var descriptor: AIProviderDescriptor { get }
    var status: AIProviderStatus { get }
    func status(for capability: AICapability) -> AIProviderStatus
    func start(cwd: String)
    func stop()
    func repairAction(for capability: AICapability) -> AIProviderRepairAction?
}

extension AIProvider {
    func status(for capability: AICapability) -> AIProviderStatus {
        descriptor.capabilities.contains(capability)
            ? status
            : .unavailable(.incompatibleRuntime("Capability is not supported"))
    }
}

struct AutocompleteRequest {
    let prefix: String
    let cwd: String
    let terminal: String
}

struct AutocompleteCandidate: Hashable {
    let text: String
    let providerIndex: Int
}

@MainActor
protocol AutocompleteProviding: AIProvider {
    func complete(
        _ request: AutocompleteRequest,
        completion: @escaping (Result<[AutocompleteCandidate], Error>) -> Void
    )
    func accepted(_ candidate: AutocompleteCandidate)
}

struct ConversationRequest {
    let text: String
    let instructions: String
    let modelID: String
    let projectRoot: String
    let terminalContext: String
    let conversationContext: String
    let allowsWorkspaceWrites: Bool
}

enum ConversationEvent {
    case textDelta(String)
    case completed
    case failed(String)
}

@MainActor
protocol ConversationProviding: AIProvider {
    func respond(
        to request: ConversationRequest,
        onEvent: @escaping (ConversationEvent) -> Void
    ) -> UUID
    func cancel(requestID: UUID)
}

struct CapabilityRoute: Codable, Equatable {
    let capability: AICapability
    var providerID: AIProviderID
    var modelID: String
}
