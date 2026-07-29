import Foundation
import Logging

/// The single home for Prompt-owned files.
///
/// Add durable files with `configurationFile(_:)` and disposable files with
/// `cacheFile(_:)`; callers do not need to know or recreate the directory
/// layout.
struct PromptPaths {
    let root: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        root = homeDirectory.appendingPathComponent(".prompt", isDirectory: true)
    }

    var settings: URL { configurationFile("config.json") }
    var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    var providers: URL { root.appendingPathComponent("providers", isDirectory: true) }
    var conversations: URL {
        root.appendingPathComponent("ai/conversations", isDirectory: true)
    }

    func providerDirectory(_ id: AIProviderID) -> URL {
        providers.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    func configurationFile(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: false)
    }

    func cacheFile(_ name: String) -> URL {
        cache.appendingPathComponent(name, isDirectory: false)
    }

    func prepare(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: providers, withIntermediateDirectories: true)
    }
}

/// A small, typed JSON settings store backed by `~/.prompt/config.json`.
final class PromptSettings {
    static let shared = PromptSettings()

    private let paths: PromptPaths
    private let fileManager: FileManager
    private let lock = NSLock()
    private var values: [String: JSONValue]
    private let canPersist: Bool

    init(
        paths: PromptPaths = PromptPaths(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.fileManager = fileManager
        do {
            try paths.prepare(fileManager: fileManager)
        } catch {
            PromptLog.persistence.error(
                "Could not prepare Prompt storage",
                metadata: ["error": "\(error)"])
        }
        if fileManager.fileExists(atPath: paths.settings.path) {
            if let data = try? Data(contentsOf: paths.settings),
               let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
                values = decoded
                canPersist = true
            } else {
                // Never replace an existing configuration that we cannot
                // understand. Reads can still fall back to legacy defaults,
                // but writes remain disabled until the file is repaired.
                values = [:]
                canPersist = false
                PromptLog.persistence.error("Configuration exists but could not be decoded; writes are disabled")
            }
        } else {
            values = [:]
            canPersist = true
        }
    }

    func value<T: Codable>(_ type: T.Type = T.self, forKey key: String) -> T? {
        lock.withLock {
            values[key]?.decode(type)
        }
    }

    func set<T: Codable>(_ value: T, forKey key: String) {
        lock.withLock {
            guard let encoded = JSONValue(value) else { return }
            values[key] = encoded
            persist()
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard canPersist else { return false }
        do {
            let data = try JSONEncoder.prompt.encode(values)
            try paths.prepare(fileManager: fileManager)
            try data.write(to: paths.settings, options: [.atomic])
            return true
        } catch {
            PromptLog.persistence.error(
                "Could not persist configuration",
                metadata: ["error": "\(error)"])
            return false
        }
    }
}

private enum JSONValue: Codable {
    case bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]), null

    init?<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self = decoded
    }

    func decode<T: Decodable>(_ type: T.Type) -> T? {
        (try? JSONEncoder().encode(self)).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private extension JSONEncoder {
    static var prompt: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
