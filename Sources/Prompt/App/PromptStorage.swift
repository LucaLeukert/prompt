import Foundation

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

    func configurationFile(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: false)
    }

    func cacheFile(_ name: String) -> URL {
        cache.appendingPathComponent(name, isDirectory: false)
    }

    func prepare(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
    }
}

/// A small, typed JSON settings store. Keeping the storage API here makes
/// adding future settings independent from Foundation's UserDefaults domains.
final class PromptSettings {
    static let shared = PromptSettings()

    private let paths: PromptPaths
    private let fileManager: FileManager
    private let legacyDefaults: UserDefaults?
    private let lock = NSLock()
    private var values: [String: JSONValue]

    init(
        paths: PromptPaths = PromptPaths(),
        fileManager: FileManager = .default,
        legacyDefaults: UserDefaults? = .standard
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.legacyDefaults = legacyDefaults
        try? paths.prepare(fileManager: fileManager)
        values = (try? Data(contentsOf: paths.settings))
            .flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
    }

    func value<T: Codable>(_ type: T.Type = T.self, forKey key: String) -> T? {
        lock.withLock {
            if let stored = values[key] { return stored.decode(type) }
            guard let legacy = legacyDefaults?.object(forKey: key),
                  let migrated = JSONValue(propertyListValue: legacy),
                  let result = migrated.decode(type) else { return nil }
            values[key] = migrated
            persist()
            legacyDefaults?.removeObject(forKey: key)
            return result
        }
    }

    func set<T: Codable>(_ value: T, forKey key: String) {
        lock.withLock {
            guard let encoded = JSONValue(value) else { return }
            values[key] = encoded
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder.prompt.encode(values) else { return }
        try? paths.prepare(fileManager: fileManager)
        try? data.write(to: paths.settings, options: [.atomic])
    }
}

private enum JSONValue: Codable {
    case bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]), null

    init?<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self = decoded
    }

    init?(propertyListValue value: Any) {
        switch value {
        case let value as Bool: self = .bool(value)
        case let value as NSNumber: self = .number(value.doubleValue)
        case let value as String: self = .string(value)
        case let value as Data:
            guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: value) else { return nil }
            self = decoded
        case let value as [Any]:
            let converted = value.compactMap(JSONValue.init(propertyListValue:))
            guard converted.count == value.count else { return nil }
            self = .array(converted)
        case let value as [String: Any]:
            let converted = value.compactMapValues(JSONValue.init(propertyListValue:))
            guard converted.count == value.count else { return nil }
            self = .object(converted)
        default: return nil
        }
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
