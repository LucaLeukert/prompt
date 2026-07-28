import Foundation
import Security

final class APIKeyStore {
    static let shared = APIKeyStore()
    private let service = "net.leukert.prompt.ai-provider"

    private init() {}

    func containsKey(for providerID: AIProviderID) -> Bool {
        readKey(for: providerID) != nil
    }

    func readKey(for providerID: AIProviderID) -> String? {
        var query = baseQuery(for: providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func setKey(_ key: String, for providerID: AIProviderID) -> Bool {
        guard let data = key.data(using: .utf8), !key.isEmpty else { return false }
        let query = baseQuery(for: providerID)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            return SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    func removeKey(for providerID: AIProviderID) -> Bool {
        let status = SecItemDelete(baseQuery(for: providerID) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(for providerID: AIProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.rawValue,
        ]
    }
}
