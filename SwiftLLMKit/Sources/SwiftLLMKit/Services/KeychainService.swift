import Foundation
import Security

/// Manages API key storage in the macOS Keychain.
///
/// Each provider's API key is stored as a generic password with:
/// - Service: `<keychainServicePrefix>.<appBundleID>`
/// - Account: provider ID
public struct KeychainService: Sendable {
    private let service: String

    /// Creates a keychain service scoped to the given identifiers.
    /// - Parameters:
    ///   - keychainServicePrefix: A reverse-DNS prefix, e.g. "com.yourname.SwiftLLMKit".
    ///   - appIdentifier: Typically `Bundle.main.bundleIdentifier`.
    public init(keychainServicePrefix: String, appIdentifier: String) {
        self.service = "\(keychainServicePrefix).\(appIdentifier)"
    }

    /// Stores or updates an API key for the given provider.
    /// - Throws: `KeychainError` if the operation fails.
    public func save(apiKey: String, forProviderID providerID: String) throws {
        guard let data = apiKey.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID
        ]

        // Try to update first
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet — add it
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.saveFailed(status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.saveFailed(status: updateStatus)
        }
    }

    /// Retrieves the API key for the given provider, or `nil` if not stored.
    public func apiKey(forProviderID providerID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the API key for the given provider.
    /// - Throws: `KeychainError` if deletion fails (not found is not an error).
    public func delete(forProviderID providerID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }
}

/// Errors from Keychain operations.
public enum KeychainError: Error, LocalizedError {
    case encodingFailed
    case saveFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode API key as UTF-8"
        case .saveFailed(let status):
            return "Keychain save failed (OSStatus \(status))"
        case .deleteFailed(let status):
            return "Keychain delete failed (OSStatus \(status))"
        }
    }
}
