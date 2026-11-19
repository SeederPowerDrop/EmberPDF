// SPDX-License-Identifier: MPL-2.0

import Foundation
import LocalAuthentication
import Security

struct LegacyKeychainACLContents {
    let trustedApplications: CFArray?
    let description: String?
    let promptSelector: SecKeychainPromptSelector
}

struct LegacyKeychainMigrationError: Error {
    let status: OSStatus
}

/// Keeps the exact item, access object, ACL entries, trusted applications and
/// prompt selectors intact. Only a matching human-readable description changes.
protocol LegacyKeychainPromptNameOperating {
    associatedtype Item
    associatedtype Access
    associatedtype Entry

    func copyItem(_ query: [CFString: Any]) -> Result<Item, LegacyKeychainMigrationError>
    func copyAccess(_ item: Item) -> Result<Access, LegacyKeychainMigrationError>
    func copyEntries(_ access: Access) -> Result<[Entry], LegacyKeychainMigrationError>
    func copyContents(_ entry: Entry) -> Result<LegacyKeychainACLContents, LegacyKeychainMigrationError>
    func setContents(_ contents: LegacyKeychainACLContents, for entry: Entry) -> OSStatus
    func setAccess(_ access: Access, for item: Item) -> OSStatus
}

enum LegacyKeychainPromptNameMigration {
    /// Call only after a successful credential read, inside a silent
    /// SystemKeychainAccess.perform operation. This never reads secret data.
    static func rename(query: [CFString: Any], from: String, to: String) -> OSStatus {
        rename(query: query, from: from, to: to, using: SystemLegacyKeychainPromptNameOperator())
    }

    static func rename<Operator: LegacyKeychainPromptNameOperating>(
        query: [CFString: Any],
        from: String,
        to: String,
        using operations: Operator
    ) -> OSStatus {
        guard
            let context = query[kSecUseAuthenticationContext] as? LAContext,
            context.interactionNotAllowed,
            query[kSecUseDataProtectionKeychain] == nil,
            !from.isEmpty,
            !to.isEmpty
        else { return errSecParam }
        guard from != to else { return errSecSuccess }

        var lookup = query
        lookup.removeValue(forKey: kSecReturnData)
        lookup.removeValue(forKey: kSecReturnAttributes)
        lookup.removeValue(forKey: kSecReturnPersistentRef)
        lookup.removeValue(forKey: kSecValueData)
        lookup[kSecReturnRef] = kCFBooleanTrue
        lookup[kSecMatchLimit] = kSecMatchLimitOne

        do {
            let item = try operations.copyItem(lookup).get()
            let access = try operations.copyAccess(item).get()
            let entries = try operations.copyEntries(access).get()
            var replacements: [(Operator.Entry, LegacyKeychainACLContents)] = []

            // Read every simple entry before mutating the copied access object.
            // Opaque partition/integrity ACLs remain entirely untouched.
            for entry in entries {
                let contents: LegacyKeychainACLContents
                switch operations.copyContents(entry) {
                case let .success(value):
                    contents = value
                case let .failure(error) where error.status == errSecACLNotSimple:
                    continue
                case let .failure(error):
                    return error.status
                }
                guard contents.description == from else { continue }
                replacements.append((entry, LegacyKeychainACLContents(
                    trustedApplications: contents.trustedApplications,
                    description: to,
                    promptSelector: contents.promptSelector
                )))
            }
            guard !replacements.isEmpty else { return errSecSuccess }

            for (entry, contents) in replacements {
                let status = operations.setContents(contents, for: entry)
                guard status == errSecSuccess else { return status }
            }
            // The existing owner, authorization tags, application references and
            // prompt flags are retained in the original copied Access object.
            return operations.setAccess(access, for: item)
        } catch let error as LegacyKeychainMigrationError {
            return error.status
        } catch {
            return errSecInternalComponent
        }
    }
}

private struct SystemLegacyKeychainPromptNameOperator: LegacyKeychainPromptNameOperating {
    func copyItem(_ query: [CFString: Any]) -> Result<SecKeychainItem, LegacyKeychainMigrationError> {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return .failure(.init(status: status)) }
        guard let result, CFGetTypeID(result) == SecKeychainItemGetTypeID() else {
            return .failure(.init(status: errSecInvalidItemRef))
        }
        // Security returns this exact CF type when a legacy item ref is requested.
        return .success(unsafeBitCast(result, to: SecKeychainItem.self))
    }

    func copyAccess(_ item: SecKeychainItem) -> Result<SecAccess, LegacyKeychainMigrationError> {
        var access: SecAccess?
        let status = SecKeychainItemCopyAccess(item, &access)
        guard status == errSecSuccess else { return .failure(.init(status: status)) }
        guard let access else { return .failure(.init(status: errSecInvalidItemRef)) }
        return .success(access)
    }

    func copyEntries(_ access: SecAccess) -> Result<[SecACL], LegacyKeychainMigrationError> {
        var list: CFArray?
        let status = SecAccessCopyACLList(access, &list)
        guard status == errSecSuccess else { return .failure(.init(status: status)) }
        guard let list else { return .failure(.init(status: errSecInvalidItemRef)) }
        var entries: [SecACL] = []
        for index in 0..<CFArrayGetCount(list) {
            guard let pointer = CFArrayGetValueAtIndex(list, index) else {
                return .failure(.init(status: errSecInvalidItemRef))
            }
            let entry = Unmanaged<SecACL>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(entry) == SecACLGetTypeID() else {
                return .failure(.init(status: errSecInvalidItemRef))
            }
            entries.append(entry)
        }
        return .success(entries)
    }

    func copyContents(_ entry: SecACL) -> Result<LegacyKeychainACLContents, LegacyKeychainMigrationError> {
        var applications: CFArray?
        var description: CFString?
        var selector = SecKeychainPromptSelector(rawValue: 0)
        let status = SecACLCopyContents(entry, &applications, &description, &selector)
        guard status == errSecSuccess else { return .failure(.init(status: status)) }
        return .success(LegacyKeychainACLContents(
            trustedApplications: applications,
            description: description as String?,
            promptSelector: selector
        ))
    }

    func setContents(_ contents: LegacyKeychainACLContents, for entry: SecACL) -> OSStatus {
        guard let description = contents.description else { return errSecParam }
        return SecACLSetContents(
            entry,
            contents.trustedApplications,
            description as CFString,
            contents.promptSelector
        )
    }

    func setAccess(_ access: SecAccess, for item: SecKeychainItem) -> OSStatus {
        SecKeychainItemSetAccess(item, access)
    }
}
