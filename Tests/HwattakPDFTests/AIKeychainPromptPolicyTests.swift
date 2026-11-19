// SPDX-License-Identifier: MPL-2.0

import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import HwattakPDF

/// Exercises the Keychain boundary with synthetic responses only. These tests
/// must never read or change credentials in the developer's login Keychain.
final class AIKeychainPromptPolicyTests: XCTestCase {
    private let scope = AIAPIKeyScope(configurationID: UUID(), provider: .openAI)
    private let currentLabel = "EmberPDF AI Provider Credential"

    func testAvailabilityRequestsOnlyMetadataWithoutAuthenticationUI() throws {
        let keychain = PromptPolicyKeychainOperator(copyResults: [.success()])
        let store = KeychainSecureAIAPIKeyStore(keychain: keychain)

        XCTAssertTrue(try store.containsAPIKey(for: scope))

        XCTAssertEqual(keychain.copyQueries.count, 1)
        let query = try XCTUnwrap(keychain.copyQueries.first)
        assertMetadataOnly(query)
        assertInteractionDisabled(query)
        XCTAssertEqual(query[kSecAttrService] as? String, "com.hwattakpdf.ai-api-keys")
        XCTAssertTrue(keychain.updateRequests.isEmpty)
        XCTAssertTrue(keychain.addQueries.isEmpty)
        XCTAssertTrue(keychain.deleteQueries.isEmpty)
    }

    func testAvailabilityFallbackAlsoRequestsOnlyMetadataWithoutAuthenticationUI() throws {
        for fallbackStatus in [errSecItemNotFound, errSecMissingEntitlement] {
            let keychain = PromptPolicyKeychainOperator(copyResults: [
                .failure(fallbackStatus), .success()
            ])
            let store = KeychainSecureAIAPIKeyStore(keychain: keychain)

            XCTAssertTrue(try store.containsAPIKey(for: scope))

            XCTAssertEqual(keychain.copyQueries.count, 2)
            for query in keychain.copyQueries {
                assertMetadataOnly(query)
                assertInteractionDisabled(query)
            }
            XCTAssertNil(keychain.copyQueries.last?[kSecUseDataProtectionKeychain])
            XCTAssertTrue(keychain.updateRequests.isEmpty)
        }
    }

    func testProtectedExistingCredentialRemainsAvailableForIntentionalAIUse() throws {
        for usesLegacyKeychain in [false, true] {
            let results: [AIKeychainCopyResult] = usesLegacyKeychain
                ? [.failure(errSecMissingEntitlement), .failure(errSecInteractionNotAllowed)]
                : [.failure(errSecInteractionNotAllowed)]
            let keychain = PromptPolicyKeychainOperator(copyResults: results)
            let store = KeychainSecureAIAPIKeyStore(keychain: keychain)

            XCTAssertTrue(try store.containsAPIKey(for: scope))
            XCTAssertEqual(keychain.copyQueries.count, usesLegacyKeychain ? 2 : 1)
            XCTAssertTrue(keychain.updateRequests.isEmpty)
        }
    }

    func testAvailabilityDistinguishesMissingCredentialFromDeniedAccess() throws {
        let missing = PromptPolicyKeychainOperator(copyResults: [
            .failure(errSecItemNotFound), .failure(errSecItemNotFound)
        ])
        XCTAssertFalse(try KeychainSecureAIAPIKeyStore(keychain: missing).containsAPIKey(for: scope))

        for usesLegacyKeychain in [false, true] {
            let results: [AIKeychainCopyResult] = usesLegacyKeychain
                ? [.failure(errSecMissingEntitlement), .failure(errSecAuthFailed)]
                : [.failure(errSecAuthFailed)]
            let denied = PromptPolicyKeychainOperator(copyResults: results)
            XCTAssertThrowsError(
                try KeychainSecureAIAPIKeyStore(keychain: denied).containsAPIKey(for: scope)
            ) { error in
                XCTAssertEqual(error as? SecureAIAPIKeyStoreError, .authenticationRequired)
            }
        }
    }

    func testAIRequestReadsSilentlyWithoutChangingLabelsSecretsOrAccessControls() throws {
        for usesLegacyKeychain in [false, true] {
            let results: [AIKeychainCopyResult] = usesLegacyKeychain
                ? [.failure(errSecMissingEntitlement), .success("synthetic-api-key")]
                : [.success("synthetic-api-key")]
            let keychain = PromptPolicyKeychainOperator(copyResults: results)
            let store = KeychainSecureAIAPIKeyStore(keychain: keychain)

            XCTAssertEqual(try store.loadAPIKey(for: scope), "synthetic-api-key")

            XCTAssertEqual(keychain.copyQueries.count, usesLegacyKeychain ? 2 : 1)
            for read in keychain.copyQueries {
                XCTAssertTrue(cfEqual(read[kSecReturnData], kCFBooleanTrue))
                assertInteractionDisabled(read)
            }
            XCTAssertTrue(keychain.updateRequests.isEmpty)
            XCTAssertTrue(keychain.addQueries.isEmpty)
            XCTAssertTrue(keychain.deleteQueries.isEmpty)
        }
    }

    func testProtectedReadRequestsAPIKeyReentryWithoutRetryingOrMutatingTheItem() {
        for usesLegacyKeychain in [false, true] {
            for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled] {
                let results: [AIKeychainCopyResult] = usesLegacyKeychain
                    ? [.failure(errSecMissingEntitlement), .failure(status)]
                    : [.failure(status)]
                let keychain = PromptPolicyKeychainOperator(copyResults: results)
                let store = KeychainSecureAIAPIKeyStore(keychain: keychain)

                XCTAssertThrowsError(try store.loadAPIKey(for: scope)) {
                    XCTAssertEqual($0 as? SecureAIAPIKeyStoreError, .authenticationRequired)
                }
                XCTAssertEqual(keychain.copyQueries.count, usesLegacyKeychain ? 2 : 1)
                keychain.copyQueries.forEach { assertInteractionDisabled($0) }
                XCTAssertTrue(keychain.updateRequests.isEmpty)
                XCTAssertTrue(keychain.addQueries.isEmpty)
                XCTAssertTrue(keychain.deleteQueries.isEmpty)
            }
        }
    }

    func testDeniedOrMissingReadDoesNotAttemptDisplayNameRepair() throws {
        for usesLegacyKeychain in [false, true] {
            for resultStatus in [errSecAuthFailed, errSecUserCanceled] {
                let results: [AIKeychainCopyResult] = usesLegacyKeychain
                    ? [.failure(errSecMissingEntitlement), .failure(resultStatus)]
                    : [.failure(resultStatus)]
                let keychain = PromptPolicyKeychainOperator(copyResults: results)
                let store = KeychainSecureAIAPIKeyStore(keychain: keychain)
                XCTAssertThrowsError(try store.loadAPIKey(for: scope))
                XCTAssertTrue(keychain.updateRequests.isEmpty)
            }
        }

        let missing = PromptPolicyKeychainOperator(copyResults: [
            .failure(errSecItemNotFound), .failure(errSecItemNotFound)
        ])
        XCTAssertNil(try KeychainSecureAIAPIKeyStore(keychain: missing).loadAPIKey(for: scope))
        XCTAssertTrue(missing.updateRequests.isEmpty)
    }

    func testInvalidCredentialPayloadDoesNotAttemptDisplayNameRepair() throws {
        for usesLegacyKeychain in [false, true] {
            let results: [AIKeychainCopyResult] = usesLegacyKeychain
                ? [.failure(errSecMissingEntitlement), .success("invalid\r\nkey")]
                : [.success("invalid\r\nkey")]
            let keychain = PromptPolicyKeychainOperator(copyResults: results)
            let store = KeychainSecureAIAPIKeyStore(keychain: keychain)

            XCTAssertThrowsError(try store.loadAPIKey(for: scope)) { error in
                XCTAssertEqual(error as? SecureAIAPIKeyStoreError, .invalidAPIKey)
            }
            XCTAssertTrue(keychain.updateRequests.isEmpty)
        }
    }

    func testReplacingExistingCredentialRefreshesLabelInBothKeychains() throws {
        for usesLegacyKeychain in [false, true] {
            let statuses: [OSStatus] = usesLegacyKeychain
                ? [errSecMissingEntitlement, errSecDuplicateItem]
                : [errSecDuplicateItem]
            let keychain = PromptPolicyKeychainOperator(addStatuses: statuses)
            let store = KeychainSecureAIAPIKeyStore(keychain: keychain)

            try store.saveAPIKey(" replacement-api-key ", for: scope)

            XCTAssertEqual(keychain.updateRequests.count, 1)
            let update = try XCTUnwrap(keychain.updateRequests.first)
            XCTAssertEqual(update.attributes[kSecAttrLabel] as? String, currentLabel)
            XCTAssertEqual(update.attributes[kSecValueData] as? Data, Data("replacement-api-key".utf8))
            XCTAssertNil(update.attributes[kSecAttrAccess])
            XCTAssertNil(update.attributes[kSecAttrAccessControl])
            XCTAssertEqual(
                cfEqual(update.query[kSecUseDataProtectionKeychain], kCFBooleanTrue),
                !usesLegacyKeychain
            )
            XCTAssertTrue(keychain.copyQueries.isEmpty)
            for query in keychain.addQueries + keychain.deleteQueries {
                assertInteractionDisabled(query)
            }
            assertInteractionDisabled(update.query)
        }
    }

    func testEntitlementFailureDuringReplacementUsesLegacyCredentialAndCurrentLabel() throws {
        let keychain = PromptPolicyKeychainOperator(
            addStatuses: [errSecDuplicateItem, errSecDuplicateItem],
            updateStatuses: [errSecMissingEntitlement, errSecSuccess]
        )
        let store = KeychainSecureAIAPIKeyStore(keychain: keychain)

        try store.saveAPIKey("replacement-api-key", for: scope)

        XCTAssertEqual(keychain.updateRequests.count, 2)
        let update = try XCTUnwrap(keychain.updateRequests.last)
        XCTAssertNil(update.query[kSecUseDataProtectionKeychain])
        XCTAssertEqual(update.attributes[kSecAttrLabel] as? String, currentLabel)
        XCTAssertEqual(update.attributes[kSecValueData] as? Data, Data("replacement-api-key".utf8))
        XCTAssertTrue(keychain.deleteQueries.isEmpty)
    }

    func testBlockedSaveReportsReentryWithoutInteractiveRetryOrACLUpdates() {
        for usesLegacyKeychain in [false, true] {
            let statuses: [OSStatus] = usesLegacyKeychain
                ? [errSecMissingEntitlement, errSecDuplicateItem]
                : [errSecDuplicateItem]
            let keychain = PromptPolicyKeychainOperator(
                addStatuses: statuses,
                updateStatuses: [errSecInteractionNotAllowed]
            )
            let store = KeychainSecureAIAPIKeyStore(keychain: keychain)

            XCTAssertThrowsError(try store.saveAPIKey("replacement-api-key", for: scope)) {
                XCTAssertEqual($0 as? SecureAIAPIKeyStoreError, .authenticationRequired)
            }
            XCTAssertEqual(keychain.updateRequests.count, 1)
            for query in keychain.addQueries + keychain.updateRequests.map(\.query) {
                assertInteractionDisabled(query)
            }
            XCTAssertTrue(keychain.deleteQueries.isEmpty)
            XCTAssertTrue(keychain.copyQueries.isEmpty)
        }
    }

    func testNewCredentialUsesEmberPDFLabelWithoutChangingAccessControls() throws {
        for usesLegacyKeychain in [false, true] {
            let keychain = PromptPolicyKeychainOperator(
                addStatuses: usesLegacyKeychain ? [errSecMissingEntitlement, errSecSuccess] : [errSecSuccess]
            )
            let store = KeychainSecureAIAPIKeyStore(keychain: keychain)
            try store.saveAPIKey("replacement-api-key", for: scope)
            let attributes = try XCTUnwrap(keychain.addQueries.last)
            XCTAssertEqual(attributes[kSecAttrLabel] as? String, currentLabel)
            XCTAssertNil(attributes[kSecAttrAccess])
            XCTAssertNil(attributes[kSecAttrAccessControl])
            assertInteractionDisabled(attributes)
            XCTAssertTrue(keychain.updateRequests.isEmpty)
        }
    }

    func testDeletingCredentialsAlsoForbidsAuthenticationDialogs() throws {
        let keychain = PromptPolicyKeychainOperator()
        let store = KeychainSecureAIAPIKeyStore(keychain: keychain)
        try store.deleteAPIKey(for: scope)
        XCTAssertEqual(keychain.deleteQueries.count, 2)
        keychain.deleteQueries.forEach { assertInteractionDisabled($0) }
        XCTAssertTrue(keychain.copyQueries.isEmpty)
        XCTAssertTrue(keychain.updateRequests.isEmpty)
    }

    func testBlockedLegacyCleanupDoesNotReportFailureAfterSavingPreferredCredential() throws {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            let keychain = PromptPolicyKeychainOperator()
            keychain.deleteStatus = status
            let store = KeychainSecureAIAPIKeyStore(keychain: keychain)

            try store.saveAPIKey("replacement-api-key", for: scope)

            XCTAssertEqual(keychain.addQueries.count, 1)
            XCTAssertEqual(keychain.deleteQueries.count, 1)
            assertInteractionDisabled(try XCTUnwrap(keychain.deleteQueries.first))
            XCTAssertTrue(keychain.updateRequests.isEmpty)
        }
    }

    func testExplicitNoUIPolicyDoesNotDependOnAuthenticationContextService() {
        let context = LAContext()
        context.interactionNotAllowed = false
        XCTAssertTrue(SystemKeychainAccess.requiresNoninteractiveAccess([
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
            kSecUseAuthenticationContext: context
        ]))
        XCTAssertTrue(SystemKeychainAccess.requiresNoninteractiveAccess([
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail
        ]))
        XCTAssertFalse(SystemKeychainAccess.requiresNoninteractiveAccess([:]))
    }

    func testSilentKeychainOperationDisablesThenRestoresInteraction() {
        for operationStatus in [errSecSuccess, errSecAuthFailed] {
            var events: [String] = []
            let result = SystemKeychainAccess.withoutInteraction(
                getAllowed: { pointer in
                    events.append("read")
                    pointer.pointee = DarwinBoolean(true)
                    return errSecSuccess
                },
                setAllowed: { allowed in
                    events.append(allowed ? "enable" : "disable")
                    return errSecSuccess
                },
                operation: {
                    events.append("operation")
                    return operationStatus
                }
            )

            XCTAssertEqual(result, operationStatus)
            XCTAssertEqual(events, ["read", "disable", "operation", "enable"])
        }
    }

    func testSilentKeychainOperationPreservesAnAlreadyDisabledInteractionFlag() {
        var events: [String] = []
        let result = SystemKeychainAccess.withoutInteraction(
            getAllowed: { pointer in
                events.append("read")
                pointer.pointee = DarwinBoolean(false)
                return errSecSuccess
            },
            setAllowed: { _ in
                events.append("unexpected flag change")
                return errSecSuccess
            },
            operation: {
                events.append("operation")
                return errSecSuccess
            }
        )

        XCTAssertEqual(result, errSecSuccess)
        XCTAssertEqual(events, ["read", "operation"])
    }

    func testSilentKeychainOperationAbortsWhenReadingInteractionPolicyFails() {
        var events: [String] = []
        let result = SystemKeychainAccess.withoutInteraction(
            getAllowed: { _ in
                events.append("read")
                return errSecNotAvailable
            },
            setAllowed: { _ in
                events.append("unexpected flag change")
                return errSecSuccess
            },
            operation: {
                events.append("unexpected operation")
                return errSecSuccess
            }
        )

        XCTAssertEqual(result, errSecNotAvailable)
        XCTAssertEqual(events, ["read"])
    }

    func testSilentKeychainOperationAbortsWhenDisablingInteractionFails() {
        var events: [String] = []
        let result = SystemKeychainAccess.withoutInteraction(
            getAllowed: { pointer in
                events.append("read")
                pointer.pointee = DarwinBoolean(true)
                return errSecSuccess
            },
            setAllowed: { allowed in
                events.append(allowed ? "enable" : "disable")
                return errSecNotAvailable
            },
            operation: {
                events.append("unexpected operation")
                return errSecSuccess
            }
        )

        XCTAssertEqual(result, errSecNotAvailable)
        XCTAssertEqual(events, ["read", "disable"])
    }

    private func assertMetadataOnly(
        _ query: [CFString: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(query[kSecReturnData], file: file, line: line)
        XCTAssertNil(query[kSecValueData], file: file, line: line)
        XCTAssertTrue(cfEqual(query[kSecReturnAttributes], kCFBooleanTrue), file: file, line: line)
        XCTAssertTrue(cfEqual(query[kSecMatchLimit], kSecMatchLimitOne), file: file, line: line)
    }

    private func assertInteractionDisabled(
        _ query: [CFString: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(cfEqual(query[kSecUseAuthenticationUI], kSecUseAuthenticationUIFail), file: file, line: line)
        XCTAssertTrue(SystemKeychainAccess.requiresNoninteractiveAccess(query), file: file, line: line)
    }

    private func cfEqual(_ value: Any?, _ expected: CFTypeRef) -> Bool {
        guard let value else { return false }
        return CFEqual(value as CFTypeRef, expected)
    }
}

private extension AIKeychainCopyResult {
    static func success(_ value: String? = nil) -> Self {
        Self(status: errSecSuccess, data: value.map { Data($0.utf8) })
    }

    static func failure(_ status: OSStatus) -> Self {
        Self(status: status, data: nil)
    }
}

private final class PromptPolicyKeychainOperator: AIKeychainItemOperating {
    struct UpdateRequest {
        let query: [CFString: Any]
        let attributes: [CFString: Any]
    }

    private(set) var copyQueries: [[CFString: Any]] = []
    private(set) var addQueries: [[CFString: Any]] = []
    private(set) var updateRequests: [UpdateRequest] = []
    private(set) var deleteQueries: [[CFString: Any]] = []
    private var copyResults: [AIKeychainCopyResult]
    private var addStatuses: [OSStatus]
    private var updateStatuses: [OSStatus]
    var deleteStatus = errSecItemNotFound

    init(
        copyResults: [AIKeychainCopyResult] = [],
        addStatuses: [OSStatus] = [],
        updateStatuses: [OSStatus] = []
    ) {
        self.copyResults = copyResults
        self.addStatuses = addStatuses
        self.updateStatuses = updateStatuses
    }

    func copyMatching(_ query: [CFString: Any]) -> AIKeychainCopyResult {
        copyQueries.append(query)
        return copyResults.isEmpty ? .failure(errSecItemNotFound) : copyResults.removeFirst()
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        addQueries.append(attributes)
        return addStatuses.isEmpty ? errSecSuccess : addStatuses.removeFirst()
    }

    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        updateRequests.append(UpdateRequest(query: query, attributes: attributes))
        return updateStatuses.isEmpty ? errSecSuccess : updateStatuses.removeFirst()
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        deleteQueries.append(query)
        return deleteStatus
    }

}
