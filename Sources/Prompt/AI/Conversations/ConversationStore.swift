import Foundation

final class ConversationStore {
    enum StoreError: Error {
        case unsupportedSchema(Int)
    }

    static let shared = ConversationStore()

    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        paths: PromptPaths = PromptPaths(),
        fileManager: FileManager = .default
    ) {
        directory = paths.conversations
        self.fileManager = fileManager
    }

    func list() -> [AIConversation] {
        lock.withLock {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { return [] }
            return urls
                .filter { $0.pathExtension == "json" }
                .compactMap(loadUnlocked)
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func load(id: UUID) -> AIConversation? {
        lock.withLock { loadUnlocked(fileURL(for: id)) }
    }

    @discardableResult
    func save(_ conversation: AIConversation) -> Bool {
        lock.withLock {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(conversation)
                try data.write(to: fileURL(for: conversation.id), options: [.atomic])
                return true
            } catch {
                PromptLog.persistence.error(
                    "Could not save AI conversation",
                    metadata: ["error": "\(error)"])
                return false
            }
        }
    }

    private func loadUnlocked(_ url: URL) -> AIConversation? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let value = try? decoder.decode(AIConversation.self, from: data),
              value.schemaVersion == AIConversation.schemaVersion else { return nil }
        return value
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension("json")
    }
}
