import Foundation

struct ProviderSessionReference: Codable, Hashable {
    let providerID: AIProviderID
    let value: String
}

struct ConversationMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable {
        case user
        case assistant
        case activity
        case error
    }

    let id: UUID
    let role: Role
    var text: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

struct AIConversation: Codable, Identifiable, Hashable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let capability: AICapability
    let providerID: AIProviderID
    let modelID: String
    var providerSession: ProviderSessionReference?
    var title: String
    var projectRoot: String?
    let createdAt: Date
    var updatedAt: Date
    var messages: [ConversationMessage]

    init(
        id: UUID = UUID(),
        capability: AICapability,
        providerID: AIProviderID,
        modelID: String,
        title: String,
        projectRoot: String? = nil,
        createdAt: Date = Date()
    ) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.capability = capability
        self.providerID = providerID
        self.modelID = modelID
        self.title = title
        self.projectRoot = projectRoot
        self.createdAt = createdAt
        updatedAt = createdAt
        messages = []
    }
}
