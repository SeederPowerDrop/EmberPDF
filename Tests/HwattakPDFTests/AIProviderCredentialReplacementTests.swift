// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

/// All credentials and persistence failures are synthetic; these tests never
/// inspect or modify the user's Keychain or application preferences.
final class AIProviderCredentialReplacementTests: XCTestCase {
    @MainActor
    func testProtectedCredentialUsesFreshIdentityAndPreservesProviderSettings() throws {
        let fixture = ReplacementFixture()

        try fixture.settings.saveAPIKey("replacement-key", for: .openAI)

        let replacement = fixture.settings.configuration(for: .openAI)
        let replacementScope = AIAPIKeyScope(configuration: replacement)
        XCTAssertNotEqual(replacement.id, fixture.original.id)
        var expected = fixture.original
        expected.id = replacement.id
        XCTAssertEqual(replacement, expected)
        XCTAssertEqual(fixture.settings.selectedProvider, .gemini)
        XCTAssertEqual(fixture.configurationStore.snapshot.configurations.first, replacement)
        XCTAssertEqual(fixture.configurationStore.snapshot.selectedProvider, .gemini)
        XCTAssertEqual(fixture.keyStore.keys[replacementScope], "replacement-key")
        XCTAssertNil(fixture.keyStore.keys[fixture.originalScope])
        XCTAssertEqual(fixture.keyStore.saveScopes, [replacementScope])
        XCTAssertEqual(fixture.keyStore.deleteScopes, [fixture.originalScope])
        XCTAssertTrue(fixture.settings.hasAPIKey(for: .openAI))
        XCTAssertNil(fixture.settings.apiKeyAvailability[fixture.original.id])
        XCTAssertNil(fixture.settings.lastErrorDescription)
        XCTAssertEqual(fixture.events.values, ["save-replacement", "commit-replacement", "delete-original"])

        let reloaded = AIProviderSettingsStore(
            configurationStore: fixture.configurationStore,
            keyStore: fixture.keyStore
        )
        XCTAssertEqual(reloaded.configuration(for: .openAI), replacement)
        XCTAssertTrue(reloaded.hasAPIKey(for: .openAI))
    }

    @MainActor
    func testReplacementSaveFailureRetainsOriginalConfigurationAndCredential() {
        let fixture = ReplacementFixture()
        fixture.keyStore.replacementSaveError = .keySaveFailed

        XCTAssertThrowsError(try fixture.settings.saveAPIKey("replacement-key", for: .openAI)) { error in
            XCTAssertEqual(error as? ReplacementTestError, .keySaveFailed)
        }

        XCTAssertEqual(fixture.settings.configuration(for: .openAI), fixture.original)
        XCTAssertEqual(fixture.configurationStore.snapshot, fixture.originalSnapshot)
        XCTAssertEqual(fixture.keyStore.keys, [fixture.originalScope: "original-key"])
        XCTAssertEqual(fixture.keyStore.saveScopes.count, 1)
        XCTAssertFalse(fixture.keyStore.saveScopes.contains(fixture.originalScope))
        XCTAssertEqual(fixture.keyStore.deleteScopes, fixture.keyStore.saveScopes)
        XCTAssertFalse(fixture.keyStore.deleteScopes.contains(fixture.originalScope))
        XCTAssertTrue(fixture.settings.hasAPIKey(for: .openAI))
        XCTAssertEqual(fixture.settings.lastErrorDescription, ReplacementTestError.keySaveFailed.localizedDescription)
    }

    @MainActor
    func testReplacementSnapshotFailureRollsBackNewKeyAndRetainsOldAssociation() {
        let fixture = ReplacementFixture()
        fixture.configurationStore.rejectReplacement = true

        XCTAssertThrowsError(try fixture.settings.saveAPIKey("replacement-key", for: .openAI)) { error in
            XCTAssertEqual(error as? ReplacementTestError, .configurationSaveFailed)
        }

        XCTAssertEqual(fixture.settings.configuration(for: .openAI), fixture.original)
        XCTAssertEqual(fixture.configurationStore.snapshot, fixture.originalSnapshot)
        XCTAssertEqual(fixture.keyStore.keys, [fixture.originalScope: "original-key"])
        XCTAssertFalse(fixture.keyStore.saveScopes.contains(fixture.originalScope))
        XCTAssertEqual(fixture.keyStore.deleteScopes, fixture.keyStore.saveScopes)
        XCTAssertTrue(fixture.settings.hasAPIKey(for: .openAI))
        XCTAssertEqual(fixture.settings.lastErrorDescription, ReplacementTestError.configurationSaveFailed.localizedDescription)
    }

    @MainActor
    func testDeniedRollbackPreservesOriginalPersistenceErrorAndOldIdentity() {
        let fixture = ReplacementFixture()
        fixture.configurationStore.rejectReplacement = true
        fixture.keyStore.rejectReplacementCleanup = true

        XCTAssertThrowsError(try fixture.settings.saveAPIKey("replacement-key", for: .openAI)) { error in
            XCTAssertEqual(error as? ReplacementTestError, .configurationSaveFailed)
        }

        XCTAssertEqual(fixture.settings.configuration(for: .openAI), fixture.original)
        XCTAssertEqual(fixture.configurationStore.snapshot, fixture.originalSnapshot)
        XCTAssertEqual(fixture.keyStore.keys[fixture.originalScope], "original-key")
        XCTAssertFalse(fixture.keyStore.deleteScopes.contains(fixture.originalScope))
        XCTAssertEqual(fixture.settings.lastErrorDescription, ReplacementTestError.configurationSaveFailed.localizedDescription)
    }

    @MainActor
    func testNormalSaveAlsoUsesFreshIdentityWithoutUpdatingOldCredential() throws {
        let fixture = ReplacementFixture()
        fixture.keyStore.rejectOriginalSave = false

        try fixture.settings.saveAPIKey("replacement-key", for: .openAI)

        let replacement = fixture.settings.configuration(for: .openAI)
        let replacementScope = AIAPIKeyScope(configuration: replacement)
        XCTAssertNotEqual(replacement.id, fixture.original.id)
        XCTAssertEqual(fixture.configurationStore.snapshot.configurations.first, replacement)
        XCTAssertEqual(fixture.keyStore.keys, [replacementScope: "replacement-key"])
        XCTAssertEqual(fixture.keyStore.saveScopes, [replacementScope])
        XCTAssertEqual(fixture.keyStore.deleteScopes, [fixture.originalScope])
        XCTAssertTrue(fixture.settings.hasAPIKey(for: .openAI))
        XCTAssertNil(fixture.settings.lastErrorDescription)
    }

    @MainActor
    func testWritableButUnreadableLegacyCredentialIsReplacedWithReadableNewItem() throws {
        let fixture = ReplacementFixture()
        fixture.keyStore.rejectOriginalSave = false
        fixture.keyStore.rejectOriginalRead = true
        fixture.keyStore.rejectOriginalCleanup = true
        // Model the legacy Keychain's separate write and read permissions: an
        // in-place update succeeds, but it does not repair the old read ACL.
        try fixture.keyStore.saveAPIKey("original-key", for: fixture.originalScope)
        XCTAssertThrowsError(try fixture.keyStore.loadAPIKey(for: fixture.originalScope)) { error in
            XCTAssertEqual(error as? SecureAIAPIKeyStoreError, .authenticationRequired)
        }
        fixture.keyStore.saveScopes = []
        fixture.events.values = []

        try fixture.settings.saveAPIKey("replacement-key", for: .openAI)

        let replacementScope = AIAPIKeyScope(configuration: fixture.settings.configuration(for: .openAI))
        XCTAssertNotEqual(replacementScope, fixture.originalScope)
        XCTAssertEqual(fixture.keyStore.saveScopes, [replacementScope])
        XCTAssertEqual(try fixture.keyStore.loadAPIKey(for: replacementScope), "replacement-key")
        XCTAssertEqual(fixture.keyStore.keys[fixture.originalScope], "original-key")
        XCTAssertTrue(fixture.settings.hasAPIKey(for: .openAI))
        XCTAssertNil(fixture.settings.lastErrorDescription)
    }

    @MainActor
    func testDeniedOldCredentialCleanupDoesNotUndoSuccessfulReplacement() throws {
        let fixture = ReplacementFixture()
        fixture.keyStore.rejectOriginalCleanup = true

        try fixture.settings.saveAPIKey("replacement-key", for: .openAI)

        let replacement = fixture.settings.configuration(for: .openAI)
        XCTAssertNotEqual(replacement.id, fixture.original.id)
        XCTAssertEqual(fixture.configurationStore.snapshot.configurations.first, replacement)
        XCTAssertEqual(fixture.keyStore.keys[AIAPIKeyScope(configuration: replacement)], "replacement-key")
        XCTAssertEqual(fixture.keyStore.keys[fixture.originalScope], "original-key")
        XCTAssertTrue(fixture.settings.hasAPIKey(for: .openAI))
        XCTAssertNil(fixture.settings.lastErrorDescription)
    }

    @MainActor
    func testFirstCredentialSaveAlsoUsesFreshIdentity() throws {
        let fixture = ReplacementFixture()
        fixture.keyStore.keys = [:]
        fixture.settings.refreshAPIKeyAvailability()
        XCTAssertFalse(fixture.settings.hasAPIKey(for: .openAI))

        try fixture.settings.saveAPIKey("first-key", for: .openAI)

        let replacementScope = AIAPIKeyScope(configuration: fixture.settings.configuration(for: .openAI))
        XCTAssertNotEqual(replacementScope, fixture.originalScope)
        XCTAssertEqual(fixture.keyStore.keys, [replacementScope: "first-key"])
        XCTAssertEqual(fixture.keyStore.saveScopes, [replacementScope])
        XCTAssertTrue(fixture.settings.hasAPIKey(for: .openAI))
    }
}

private enum ReplacementTestError: LocalizedError, Equatable {
    case keySaveFailed
    case configurationSaveFailed

    var errorDescription: String? {
        switch self {
        case .keySaveFailed: "Synthetic key save failure"
        case .configurationSaveFailed: "Synthetic configuration save failure"
        }
    }
}

private final class ReplacementEvents {
    var values: [String] = []
}

@MainActor
private struct ReplacementFixture {
    let original: AIProviderConfiguration
    let originalScope: AIAPIKeyScope
    let originalSnapshot: AIProviderConfigurationSnapshot
    let configurationStore: ReplacementConfigurationStore
    let keyStore: ReplacementKeyStore
    let settings: AIProviderSettingsStore
    let events: ReplacementEvents

    init() {
        var original = AIProviderKind.openAI.defaultConfiguration
        original.name = "Customized provider"
        original.model = "custom-model"
        original.requestTimeout = 180
        original.maximumOutputTokens = 8_192
        original.isWebSearchEnabled = true
        original.remoteMCPServers = [AIRemoteMCPServer(
            label: "research",
            serverURL: URL(string: "https://mcp.example.com/research")!
        )]
        self.original = original
        originalScope = AIAPIKeyScope(configuration: original)
        originalSnapshot = AIProviderConfigurationSnapshot(
            configurations: [original, AIProviderKind.gemini.defaultConfiguration],
            selectedProvider: .gemini
        )
        events = ReplacementEvents()
        configurationStore = ReplacementConfigurationStore(snapshot: originalSnapshot, events: events)
        keyStore = ReplacementKeyStore(originalScope: originalScope, events: events)
        settings = AIProviderSettingsStore(configurationStore: configurationStore, keyStore: keyStore)
    }
}

private final class ReplacementConfigurationStore: AIProviderConfigurationStoring {
    var snapshot: AIProviderConfigurationSnapshot
    var rejectReplacement = false
    private let originalID: UUID
    private let events: ReplacementEvents

    init(snapshot: AIProviderConfigurationSnapshot, events: ReplacementEvents) {
        self.snapshot = snapshot
        originalID = snapshot.configurations[0].id
        self.events = events
    }

    func loadSnapshot() -> AIProviderConfigurationSnapshot { snapshot }

    func saveSnapshot(_ snapshot: AIProviderConfigurationSnapshot) throws {
        let isReplacement = snapshot.configurations[0].id != originalID
        if rejectReplacement && isReplacement {
            throw ReplacementTestError.configurationSaveFailed
        }
        self.snapshot = snapshot
        if isReplacement { events.values.append("commit-replacement") }
    }
}

private final class ReplacementKeyStore: SecureAIAPIKeyStoring {
    var keys: [AIAPIKeyScope: String]
    var saveScopes: [AIAPIKeyScope] = []
    var deleteScopes: [AIAPIKeyScope] = []
    var rejectOriginalSave = true
    var rejectOriginalRead = false
    var replacementSaveError: ReplacementTestError?
    var rejectOriginalCleanup = false
    var rejectReplacementCleanup = false
    private let originalScope: AIAPIKeyScope
    private let events: ReplacementEvents

    init(originalScope: AIAPIKeyScope, events: ReplacementEvents) {
        self.originalScope = originalScope
        self.events = events
        keys = [originalScope: "original-key"]
    }

    func loadAPIKey(for scope: AIAPIKeyScope) throws -> String? {
        if scope == originalScope && rejectOriginalRead {
            throw SecureAIAPIKeyStoreError.authenticationRequired
        }
        return keys[scope]
    }

    func saveAPIKey(_ apiKey: String, for scope: AIAPIKeyScope) throws {
        saveScopes.append(scope)
        events.values.append(scope == originalScope ? "save-original" : "save-replacement")
        if scope == originalScope && rejectOriginalSave {
            throw SecureAIAPIKeyStoreError.authenticationRequired
        }
        if scope != originalScope, let replacementSaveError { throw replacementSaveError }
        keys[scope] = apiKey
    }

    func deleteAPIKey(for scope: AIAPIKeyScope) throws {
        deleteScopes.append(scope)
        events.values.append(scope == originalScope ? "delete-original" : "delete-replacement")
        if (scope == originalScope && rejectOriginalCleanup)
            || (scope != originalScope && rejectReplacementCleanup) {
            throw SecureAIAPIKeyStoreError.authenticationRequired
        }
        keys.removeValue(forKey: scope)
    }

    func containsAPIKey(for scope: AIAPIKeyScope) throws -> Bool { keys[scope] != nil }
}
