// SPDX-License-Identifier: MPL-2.0

import Foundation
import Security

private func containsAPIKeyHeaderControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
        scalar.value == 0 || scalar.value == 10 || scalar.value == 13
    }
}

protocol SecureAIAPIKeyStoring {
    func loadAPIKey(for scope: AIAPIKeyScope) throws -> String?
    func saveAPIKey(_ apiKey: String, for scope: AIAPIKeyScope) throws
    func deleteAPIKey(for scope: AIAPIKeyScope) throws
    func containsAPIKey(for scope: AIAPIKeyScope) throws -> Bool
}

struct AIAPIKeyScope: Hashable {
    let configurationID: UUID
    let provider: AIProviderKind

    init(configurationID: UUID, provider: AIProviderKind) {
        self.configurationID = configurationID
        self.provider = provider
    }

    init(configuration: AIProviderConfiguration) {
        self.init(configurationID: configuration.id, provider: configuration.kind)
    }
}

struct AIKeychainCopyResult {
    let status: OSStatus
    let data: Data?
}

protocol AIKeychainItemOperating {
    func copyMatching(_ query: [CFString: Any]) -> AIKeychainCopyResult
    func add(_ attributes: [CFString: Any]) -> OSStatus
    func update(
        _ query: [CFString: Any],
        attributes: [CFString: Any]
    ) -> OSStatus
    func delete(_ query: [CFString: Any]) -> OSStatus
}

struct SystemAIKeychainItemOperator: AIKeychainItemOperating {
    func copyMatching(_ query: [CFString: Any]) -> AIKeychainCopyResult {
        var result: CFTypeRef?
        let status = SystemKeychainAccess.perform(query: query) {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        return AIKeychainCopyResult(status: status, data: result as? Data)
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        SystemKeychainAccess.perform(query: attributes) {
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    func update(
        _ query: [CFString: Any],
        attributes: [CFString: Any]
    ) -> OSStatus {
        SystemKeychainAccess.perform(query: query) {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        SystemKeychainAccess.perform(query: query) {
            SecItemDelete(query as CFDictionary)
        }
    }

}

enum SecureAIAPIKeyStoreError: LocalizedError, Equatable {
    case invalidAPIKey
    case authenticationRequired
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "The API key is empty or invalid."
        case .authenticationRequired:
            return L10n.string(
                "ai.settings.key_access_requires_reentry",
                defaultValue: "저장된 API 키에 접근할 수 없습니다. 설정 > AI에서 이 공급자의 API 키를 다시 저장해 주세요. 로그인 키체인이 잠겨 있다면 먼저 잠금을 해제해 주세요."
            )
        case let .keychain(status):
            return (SecCopyErrorMessageString(status, nil) as String?)
                ?? "Keychain error \(status)"
        }
    }

    static func fromStatus(_ status: OSStatus) -> Self {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .authenticationRequired
        default:
            return .keychain(status)
        }
    }
}

/// Stores provider credentials in this macOS user's Keychain. Configuration
/// metadata is persisted separately and never contains an API key.
final class KeychainSecureAIAPIKeyStore: SecureAIAPIKeyStoring {
    static let shared = KeychainSecureAIAPIKeyStore()
    // Keep the storage identifier so existing credentials remain associated.
    static let defaultService = "com.hwattakpdf.ai-api-keys"
    static let credentialLabel = "EmberPDF AI Provider Credential"
    static let maximumAPIKeyByteCount = 64 * 1_024

    private let service: String
    private let keychain: any AIKeychainItemOperating

    init(
        service: String = KeychainSecureAIAPIKeyStore.defaultService,
        keychain: any AIKeychainItemOperating = SystemAIKeychainItemOperator()
    ) {
        self.service = service
        self.keychain = keychain
    }

    func loadAPIKey(for scope: AIAPIKeyScope) throws -> String? {
        var query = baseQuery(for: scope)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        let result = keychain.copyMatching(query)
        if result.status == errSecItemNotFound || result.status == errSecMissingEntitlement {
            return try loadLegacyAPIKey(for: scope)
        }
        guard result.status == errSecSuccess else {
            throw SecureAIAPIKeyStoreError.fromStatus(result.status)
        }
        // Reading a credential must never change its label or access controls.
        // Legacy ACL updates can force a second password dialog even when the
        // optional Keychain interaction switch is disabled.
        return try decodedAPIKey(from: result.data)
    }

    func saveAPIKey(_ apiKey: String, for scope: AIAPIKeyScope) throws {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !normalized.isEmpty,
            !containsAPIKeyHeaderControlCharacter(normalized),
            let data = normalized.data(using: .utf8),
            data.count <= Self.maximumAPIKeyByteCount
        else {
            throw SecureAIAPIKeyStoreError.invalidAPIKey
        }

        var attributes = baseQuery(for: scope)
        attributes[kSecValueData] = data
        attributes[kSecAttrLabel] = Self.credentialLabel
        attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = keychain.add(attributes)
        switch addStatus {
        case errSecSuccess:
            removeLegacyCopy(for: scope)
        case errSecDuplicateItem:
            let updateStatus = keychain.update(
                baseQuery(for: scope),
                attributes: [kSecValueData: data, kSecAttrLabel: Self.credentialLabel]
            )
            if updateStatus == errSecMissingEntitlement {
                try saveLegacyAPIKey(data, for: scope)
                return
            }
            guard updateStatus == errSecSuccess else {
                throw SecureAIAPIKeyStoreError.fromStatus(updateStatus)
            }
            removeLegacyCopy(for: scope)
        case errSecMissingEntitlement:
            try saveLegacyAPIKey(data, for: scope)
        default:
            throw SecureAIAPIKeyStoreError.fromStatus(addStatus)
        }
    }

    func deleteAPIKey(for scope: AIAPIKeyScope) throws {
        let legacyStatus = keychain.delete(legacyBaseQuery(for: scope))
        guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
            throw SecureAIAPIKeyStoreError.fromStatus(legacyStatus)
        }

        let status = keychain.delete(baseQuery(for: scope))
        if status == errSecMissingEntitlement { return }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureAIAPIKeyStoreError.fromStatus(status)
        }
    }

    func containsAPIKey(for scope: AIAPIKeyScope) throws -> Bool {
        // App launch and UI refreshes inspect metadata only, without prompting
        // or loading a secret. Actual AI requests also prohibit system dialogs.
        let result = keychain.copyMatching(availabilityQuery(baseQuery(for: scope)))
        switch result.status {
        case errSecSuccess, errSecInteractionNotAllowed:
            // The item exists; a read will explain if it needs to be re-saved.
            return true
        case errSecItemNotFound, errSecMissingEntitlement:
            let legacyResult = keychain.copyMatching(availabilityQuery(legacyBaseQuery(for: scope)))
            if legacyResult.status == errSecSuccess || legacyResult.status == errSecInteractionNotAllowed {
                return true
            }
            if legacyResult.status == errSecItemNotFound { return false }
            throw SecureAIAPIKeyStoreError.fromStatus(legacyResult.status)
        default:
            throw SecureAIAPIKeyStoreError.fromStatus(result.status)
        }
    }

    private func noninteractiveQuery(_ query: [CFString: Any]) -> [CFString: Any] {
        var query = query
        // Use an explicit query policy rather than depending on LAContext's
        // service-backed property setter. SystemKeychainAccess also enforces
        // this policy for the file-based login Keychain, which ignores it.
        query[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
        return query
    }

    private func availabilityQuery(_ query: [CFString: Any]) -> [CFString: Any] {
        var query = query
        query[kSecReturnAttributes] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        return query
    }

    /// Internal for deterministic security-policy tests.
    func baseQuery(for scope: AIAPIKeyScope) -> [CFString: Any] {
        noninteractiveQuery([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(for: scope),
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain: kCFBooleanTrue as Any
        ])
    }

    /// Compatibility path for ad-hoc builds without a provisioned access
    /// group. It remains user-scoped and explicitly non-synchronizing.
    func legacyBaseQuery(for scope: AIAPIKeyScope) -> [CFString: Any] {
        noninteractiveQuery([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(for: scope),
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ])
    }

    private func account(for scope: AIAPIKeyScope) -> String {
        "provider-\(scope.provider.rawValue.lowercased())-\(scope.configurationID.uuidString.lowercased())"
    }

    private func decodedAPIKey(from data: Data?) throws -> String {
        guard
            let data,
            data.count <= Self.maximumAPIKeyByteCount,
            let value = String(data: data, encoding: .utf8),
            !value.isEmpty,
            !containsAPIKeyHeaderControlCharacter(value)
        else {
            throw SecureAIAPIKeyStoreError.invalidAPIKey
        }
        return value
    }

    private func loadLegacyAPIKey(for scope: AIAPIKeyScope) throws -> String? {
        var query = legacyBaseQuery(for: scope)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        let result = keychain.copyMatching(query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else {
            throw SecureAIAPIKeyStoreError.fromStatus(result.status)
        }
        return try decodedAPIKey(from: result.data)
    }

    private func saveLegacyAPIKey(_ data: Data, for scope: AIAPIKeyScope) throws {
        var attributes = legacyBaseQuery(for: scope)
        attributes[kSecValueData] = data
        attributes[kSecAttrLabel] = Self.credentialLabel

        let status = keychain.add(attributes)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = keychain.update(
                legacyBaseQuery(for: scope),
                attributes: [kSecValueData: data, kSecAttrLabel: Self.credentialLabel]
            )
            guard updateStatus == errSecSuccess else {
                throw SecureAIAPIKeyStoreError.fromStatus(updateStatus)
            }
        default:
            throw SecureAIAPIKeyStoreError.fromStatus(status)
        }
    }

    private func removeLegacyCopy(for scope: AIAPIKeyScope) {
        // The preferred store already has the new value. Cleanup must not
        // turn a successful save into an error or authorize an old item's ACL.
        _ = keychain.delete(legacyBaseQuery(for: scope))
    }
}

final class InMemorySecureAIAPIKeyStore: SecureAIAPIKeyStoring {
    var keys: [AIAPIKeyScope: String]
    var loadError: Error?
    var saveError: Error?
    var deleteError: Error?

    init(keys: [AIAPIKeyScope: String] = [:]) {
        self.keys = keys
    }

    func loadAPIKey(for scope: AIAPIKeyScope) throws -> String? {
        if let loadError { throw loadError }
        return keys[scope]
    }

    func saveAPIKey(_ apiKey: String, for scope: AIAPIKeyScope) throws {
        if let saveError { throw saveError }
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !normalized.isEmpty,
            !containsAPIKeyHeaderControlCharacter(normalized)
        else {
            throw SecureAIAPIKeyStoreError.invalidAPIKey
        }
        keys[scope] = normalized
    }

    func deleteAPIKey(for scope: AIAPIKeyScope) throws {
        if let deleteError { throw deleteError }
        keys.removeValue(forKey: scope)
    }

    func containsAPIKey(for scope: AIAPIKeyScope) throws -> Bool {
        keys[scope] != nil
    }
}
