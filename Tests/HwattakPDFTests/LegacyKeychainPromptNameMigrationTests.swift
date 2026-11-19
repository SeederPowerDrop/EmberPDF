// SPDX-License-Identifier: MPL-2.0

import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import HwattakPDF

final class LegacyKeychainPromptNameMigrationTests: XCTestCase {
    private let oldName = "HwattakPDF AI Provider Credential"
    private let newName = "EmberPDF AI Provider Credential"

    func testRenameRetainsTrustedApplicationsPromptFlagsAndAuthorizationTags() throws {
        let applications = [NSObject(), NSObject()] as CFArray
        let entries = [
            MigrationTestEntry(description: oldName, applications: applications, flags: 0x00F1),
            MigrationTestEntry(description: oldName, applications: nil, flags: 0x0001),
            MigrationTestEntry(description: oldName, applications: [] as CFArray, flags: 0x0020)
        ]
        let operations = MigrationTestOperator(entries: entries)

        XCTAssertEqual(rename(using: operations), errSecSuccess)

        XCTAssertEqual(operations.writes.count, 3)
        for (original, write) in zip(entries, operations.writes) {
            XCTAssertTrue(write.entry === original)
            XCTAssertEqual(write.contents.description, newName)
            XCTAssertTrue(write.contents.trustedApplications === original.contents.trustedApplications)
            XCTAssertEqual(write.contents.promptSelector.rawValue, original.contents.promptSelector.rawValue)
            XCTAssertEqual(original.authorizations, ["decrypt", "export-clear"])
        }
        XCTAssertEqual(operations.commits.count, 1)
        let commit = try XCTUnwrap(operations.commits.first)
        XCTAssertTrue(commit.item === operations.item)
        XCTAssertTrue(commit.access === operations.access)
    }

    func testNonmatchingAndOpaqueEntriesArePreservedWhileMatchingDescriptionChanges() {
        let unchanged = MigrationTestEntry(description: "Another app credential")
        let absentDescription = MigrationTestEntry(description: nil)
        let opaque = MigrationTestEntry(description: oldName)
        opaque.copyError = errSecACLNotSimple
        let matching = MigrationTestEntry(description: oldName)
        let operations = MigrationTestOperator(entries: [unchanged, absentDescription, opaque, matching])

        XCTAssertEqual(rename(using: operations), errSecSuccess)

        XCTAssertEqual(operations.writes.count, 1)
        XCTAssertTrue(operations.writes.first?.entry === matching)
        XCTAssertEqual(operations.commits.count, 1)
        XCTAssertEqual(unchanged.contents.description, "Another app credential")
        XCTAssertNil(absentDescription.contents.description)
        XCTAssertEqual(opaque.copyError, errSecACLNotSimple)
    }

    func testNoMatchingDescriptionDoesNotApplyAccess() {
        let operations = MigrationTestOperator(entries: [MigrationTestEntry(description: newName)])

        XCTAssertEqual(rename(using: operations), errSecSuccess)

        XCTAssertTrue(operations.writes.isEmpty)
        XCTAssertTrue(operations.commits.isEmpty)
    }

    func testLookupCopiesOnlyTheExistingItemReference() throws {
        let operations = MigrationTestOperator(entries: [])
        var query = silentQuery()
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecReturnAttributes] = kCFBooleanTrue
        query[kSecValueData] = Data("synthetic-disallowed-value".utf8)

        XCTAssertEqual(
            LegacyKeychainPromptNameMigration.rename(query: query, from: oldName, to: newName, using: operations),
            errSecSuccess
        )

        let lookup = try XCTUnwrap(operations.lookupQueries.first)
        XCTAssertNil(lookup[kSecReturnData])
        XCTAssertNil(lookup[kSecReturnAttributes])
        XCTAssertNil(lookup[kSecValueData])
        XCTAssertTrue(CFEqual(try XCTUnwrap(lookup[kSecReturnRef]) as CFTypeRef, kCFBooleanTrue))
        XCTAssertTrue(CFEqual(try XCTUnwrap(lookup[kSecMatchLimit]) as CFTypeRef, kSecMatchLimitOne))
        XCTAssertEqual(lookup[kSecAttrService] as? String, "test.service")
        XCTAssertEqual(lookup[kSecAttrAccount] as? String, "test.account")
        XCTAssertEqual((lookup[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed, true)
    }

    func testMigrationRejectsInteractiveOrDataProtectionCallsBeforeLookup() {
        var queries: [[CFString: Any]] = [[:]]
        let interactive = LAContext()
        queries.append([kSecUseAuthenticationContext: interactive])
        var protectedQuery = silentQuery()
        protectedQuery[kSecUseDataProtectionKeychain] = kCFBooleanTrue
        queries.append(protectedQuery)
        for query in queries {
            let operations = MigrationTestOperator(entries: [])
            XCTAssertEqual(
                LegacyKeychainPromptNameMigration.rename(query: query, from: oldName, to: newName, using: operations),
                errSecParam
            )
            XCTAssertTrue(operations.lookupQueries.isEmpty)
            XCTAssertTrue(operations.writes.isEmpty)
            XCTAssertTrue(operations.commits.isEmpty)
        }
    }

    func testReadFailuresNeverCommitOrEditAnACL() {
        for stage in MigrationTestOperator.FailureStage.allCases {
            let operations = MigrationTestOperator(entries: [MigrationTestEntry(description: oldName)])
            operations.failAt = stage
            XCTAssertEqual(rename(using: operations), errSecAuthFailed)
            XCTAssertTrue(operations.writes.isEmpty)
            XCTAssertTrue(operations.commits.isEmpty)
        }

        let matching = MigrationTestEntry(description: oldName)
        let unreadable = MigrationTestEntry(description: oldName)
        unreadable.copyError = errSecAuthFailed
        let operations = MigrationTestOperator(entries: [matching, unreadable])
        XCTAssertEqual(rename(using: operations), errSecAuthFailed)
        XCTAssertTrue(operations.writes.isEmpty, "Inspect all contents before editing the copied ACL.")
        XCTAssertTrue(operations.commits.isEmpty)
    }

    func testContentsFailureDoesNotApplyPartiallyRenamedAccess() {
        let operations = MigrationTestOperator(entries: [
            MigrationTestEntry(description: oldName),
            MigrationTestEntry(description: oldName)
        ])
        operations.setStatuses = [errSecSuccess, errSecAuthFailed]

        XCTAssertEqual(rename(using: operations), errSecAuthFailed)

        XCTAssertEqual(operations.writes.count, 2)
        XCTAssertTrue(operations.commits.isEmpty)
    }

    func testDeniedAccessCommitIsReturnedWithoutRetryOrPermissionChanges() {
        let operations = MigrationTestOperator(entries: [MigrationTestEntry(description: oldName)])
        operations.commitStatus = errSecInteractionNotAllowed

        XCTAssertEqual(rename(using: operations), errSecInteractionNotAllowed)

        XCTAssertEqual(operations.commits.count, 1)
        XCTAssertEqual(operations.writes.count, 1)
        XCTAssertEqual(operations.access.entries.first?.authorizations, ["decrypt", "export-clear"])
    }

    private func rename(using operations: MigrationTestOperator) -> OSStatus {
        LegacyKeychainPromptNameMigration.rename(
            query: silentQuery(), from: oldName, to: newName, using: operations
        )
    }

    private func silentQuery() -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "test.service",
            kSecAttrAccount: "test.account",
            kSecUseAuthenticationContext: context
        ]
    }
}

private final class MigrationTestItem {}

private final class MigrationTestAccess {
    let entries: [MigrationTestEntry]
    init(entries: [MigrationTestEntry]) { self.entries = entries }
}

private final class MigrationTestEntry {
    let contents: LegacyKeychainACLContents
    let authorizations = ["decrypt", "export-clear"]
    var copyError: OSStatus?

    init(description: String?, applications: CFArray? = nil, flags: UInt16 = 0x0001) {
        contents = LegacyKeychainACLContents(
            trustedApplications: applications,
            description: description,
            promptSelector: SecKeychainPromptSelector(rawValue: flags)
        )
    }
}

private final class MigrationTestOperator: LegacyKeychainPromptNameOperating {
    enum FailureStage: CaseIterable { case item, access, entries }
    let item = MigrationTestItem()
    let access: MigrationTestAccess
    var failAt: FailureStage?
    var setStatuses: [OSStatus] = []
    var commitStatus = errSecSuccess
    var lookupQueries: [[CFString: Any]] = []
    var writes: [(entry: MigrationTestEntry, contents: LegacyKeychainACLContents)] = []
    var commits: [(item: MigrationTestItem, access: MigrationTestAccess)] = []

    init(entries: [MigrationTestEntry]) { access = MigrationTestAccess(entries: entries) }

    func copyItem(_ query: [CFString: Any]) -> Result<MigrationTestItem, LegacyKeychainMigrationError> {
        lookupQueries.append(query)
        return failAt == .item ? .failure(.init(status: errSecAuthFailed)) : .success(item)
    }

    func copyAccess(_ item: MigrationTestItem) -> Result<MigrationTestAccess, LegacyKeychainMigrationError> {
        failAt == .access ? .failure(.init(status: errSecAuthFailed)) : .success(access)
    }

    func copyEntries(_ access: MigrationTestAccess) -> Result<[MigrationTestEntry], LegacyKeychainMigrationError> {
        failAt == .entries ? .failure(.init(status: errSecAuthFailed)) : .success(access.entries)
    }

    func copyContents(_ entry: MigrationTestEntry) -> Result<LegacyKeychainACLContents, LegacyKeychainMigrationError> {
        if let status = entry.copyError { return .failure(.init(status: status)) }
        return .success(entry.contents)
    }

    func setContents(_ contents: LegacyKeychainACLContents, for entry: MigrationTestEntry) -> OSStatus {
        writes.append((entry, contents))
        return setStatuses.isEmpty ? errSecSuccess : setStatuses.removeFirst()
    }

    func setAccess(_ access: MigrationTestAccess, for item: MigrationTestItem) -> OSStatus {
        commits.append((item, access))
        return commitStatus
    }
}
