// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit
import XCTest
@testable import HwattakPDF

final class RecentDocumentsStoreTests: XCTestCase {
    @MainActor
    func testRecordKeepsSevenNewestDocumentsAndMovesDuplicateToFront() throws {
        let fixture = try makeFiles(count: 8)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = MemoryRecentDocumentsPersistence()
        let coder = FakeRecentDocumentBookmarkCoder()
        var timestamp: TimeInterval = 100
        let store = RecentDocumentsStore(
            persistence: persistence,
            bookmarkCoder: coder,
            now: {
                defer { timestamp += 1 }
                return Date(timeIntervalSince1970: timestamp)
            }
        )

        for url in fixture.urls {
            try store.record(url: url)
        }

        XCTAssertEqual(store.documents.count, 7)
        XCTAssertEqual(store.documents.map(\.displayName), fixture.urls.dropFirst().reversed().map(\.lastPathComponent))
        let duplicateURL = fixture.urls[3]
        let originalID = try XCTUnwrap(
            store.documents.first(where: { $0.displayName == duplicateURL.lastPathComponent })?.id
        )

        let duplicate = try store.record(url: duplicateURL)

        XCTAssertEqual(store.documents.count, 7)
        XCTAssertEqual(store.documents.first?.id, originalID)
        XCTAssertEqual(duplicate.id, originalID)
        XCTAssertEqual(store.documents.first?.displayName, duplicateURL.lastPathComponent)

        let reloaded = RecentDocumentsStore(
            persistence: persistence,
            bookmarkCoder: coder
        )
        XCTAssertEqual(reloaded.documents, store.documents)
    }

    @MainActor
    func testRemoveAndClearPersistImmediately() throws {
        let fixture = try makeFiles(count: 3)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = MemoryRecentDocumentsPersistence()
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        try fixture.urls.forEach { try store.record(url: $0) }
        let removedID = try XCTUnwrap(store.documents.dropFirst().first?.id)

        store.remove(id: removedID)

        XCTAssertEqual(store.documents.count, 2)
        XCTAssertFalse(store.documents.contains(where: { $0.id == removedID }))
        XCTAssertEqual(
            RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder).documents,
            store.documents
        )

        store.clear()

        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertNil(persistence.data)
    }

    @MainActor
    func testResolvingStaleBookmarkRefreshesPersistedBookmark() throws {
        let fixture = try makeFiles(count: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = MemoryRecentDocumentsPersistence()
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        let recent = try store.record(url: fixture.urls[0])
        coder.staleGenerations.insert(1)

        let access = try store.resolve(id: recent.id)

        XCTAssertEqual(access.url.standardizedFileURL, fixture.urls[0].standardizedFileURL)
        XCTAssertEqual(coder.bookmarkCreationCount, 2)
        XCTAssertNil(store.lastError)

        let reloaded = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        _ = try reloaded.resolve(id: recent.id)
        XCTAssertEqual(coder.bookmarkCreationCount, 2, "refreshed bookmark should no longer be stale")
    }

    @MainActor
    func testStaleBookmarkRefreshFailureDoesNotBlockValidResolvedFile() throws {
        let fixture = try makeFiles(count: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(
            persistence: MemoryRecentDocumentsPersistence(),
            bookmarkCoder: coder
        )
        let recent = try store.record(url: fixture.urls[0])
        coder.staleGenerations.insert(1)
        coder.failBookmarkCreation = true

        let access = try store.resolve(id: recent.id)

        XCTAssertEqual(access.url.standardizedFileURL, fixture.urls[0].standardizedFileURL)
        guard case .bookmarkCreationFailed = store.lastError else {
            return XCTFail("expected a non-blocking stale bookmark refresh warning")
        }
    }

    @MainActor
    func testResolveReportsMissingAndUnresolvableBookmarks() throws {
        let missingFixture = try makeFiles(count: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: missingFixture.directory) }
        let missingCoder = FakeRecentDocumentBookmarkCoder()
        let missingStore = RecentDocumentsStore(
            persistence: MemoryRecentDocumentsPersistence(),
            bookmarkCoder: missingCoder
        )
        let missing = try missingStore.record(url: missingFixture.urls[0])
        try FileManager.default.removeItem(at: missingFixture.urls[0])

        XCTAssertThrowsError(try missingStore.resolve(id: missing.id)) { error in
            guard case .fileMissing = error as? RecentDocumentsError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let invalidFixture = try makeFiles(count: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: invalidFixture.directory) }
        let invalidCoder = FakeRecentDocumentBookmarkCoder()
        let invalidStore = RecentDocumentsStore(
            persistence: MemoryRecentDocumentsPersistence(),
            bookmarkCoder: invalidCoder
        )
        let invalid = try invalidStore.record(url: invalidFixture.urls[0])
        invalidCoder.failResolution = true

        XCTAssertThrowsError(try invalidStore.resolve(id: invalid.id)) { error in
            guard case .bookmarkResolutionFailed = error as? RecentDocumentsError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testMultiDocumentWorkspaceRecordsOpensAndForwardsStoreChanges() throws {
        let fixture = try makePDFFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RecentDocumentsStore(
            persistence: MemoryRecentDocumentsPersistence(),
            bookmarkCoder: FakeRecentDocumentBookmarkCoder()
        )
        let workspace = MultiDocumentWorkspaceState(recentDocumentsStore: store)
        var notificationCount = 0
        let observer = workspace.objectWillChange.sink {
            notificationCount += 1
        }

        let openedID = try XCTUnwrap(workspace.openPDFsInTabs(urls: [fixture.url]).first)

        XCTAssertEqual(workspace.recentDocuments.count, 1)
        XCTAssertGreaterThan(notificationCount, 0)
        let recentID = try XCTUnwrap(workspace.recentDocuments.first?.id)
        XCTAssertEqual(workspace.openRecentDocument(id: recentID), openedID)

        workspace.removeRecentDocument(id: recentID)
        XCTAssertTrue(workspace.recentDocuments.isEmpty)
        _ = observer
    }

    @MainActor
    func testInvalidBookmarkOffersRecoveryWithoutOpeningExistingPathAndCancelKeepsHistory() throws {
        let fixture = try makePDFFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = MemoryRecentDocumentsPersistence()
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        let recent = try store.record(url: fixture.url)
        let savedHistory = persistence.data
        let originalBytes = try Data(contentsOf: fixture.url)
        coder.failResolution = true
        let collection = MultiDocumentWorkspaceState(recentDocumentsStore: store)
        let initialTabIDs = collection.tabs.map(\.id)
        let initialActiveID = collection.activeTabID

        // A path hint is not a grant to bypass a broken security bookmark.
        XCTAssertEqual(store.fileURLHint(id: recent.id)?.resolvingSymlinksInPath(),
                       fixture.url.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertNil(store.fileURLHint(id: UUID()))
        XCTAssertEqual(coder.resolutionCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url.path))
        XCTAssertNil(collection.openRecentDocument(id: recent.id))

        let recovery = try XCTUnwrap(collection.recentDocumentRecovery)
        XCTAssertEqual(recovery.recentID, recent.id)
        XCTAssertEqual(recovery.displayName, fixture.url.lastPathComponent)
        XCTAssertEqual(recovery.suggestedURL?.resolvingSymlinksInPath(),
                       fixture.url.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertFalse(recovery.reason.isEmpty)
        XCTAssertEqual(coder.resolutionCount, 1)
        XCTAssertEqual(collection.tabs.map(\.id), initialTabIDs)
        XCTAssertEqual(collection.activeTabID, initialActiveID)
        XCTAssertFalse(collection.tabs.contains { $0.workspace.hasOpenDocument })
        XCTAssertNil(collection.activeWorkspace?.presentedError)
        XCTAssertEqual(store.documents, [recent])
        XCTAssertEqual(persistence.data, savedHistory)

        // Dismissing the recovery sheet must neither erase the record nor
        // try opening the remembered path without a new user selection.
        collection.recentDocumentRecovery = nil

        XCTAssertNil(collection.recentDocumentRecovery)
        XCTAssertEqual(coder.resolutionCount, 1)
        XCTAssertEqual(collection.tabs.map(\.id), initialTabIDs)
        XCTAssertEqual(collection.activeTabID, initialActiveID)
        XCTAssertFalse(collection.tabs.contains { $0.workspace.hasOpenDocument })
        XCTAssertEqual(store.documents, [recent])
        XCTAssertEqual(persistence.data, savedHistory)
        XCTAssertEqual(try Data(contentsOf: fixture.url), originalBytes)
    }

    @MainActor
    func testInvalidBookmarkSelectsResidentDirtyTabWithoutReopeningOrResolving() throws {
        let fixture = try makePDFFixture(pageCount: 2)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let originalBytes = try Data(contentsOf: fixture.url)
        let persistence = MemoryRecentDocumentsPersistence()
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        let collection = MultiDocumentWorkspaceState(recentDocumentsStore: store)
        let documentTabID = try XCTUnwrap(collection.openPDFsInTabs(urls: [fixture.url]).first)
        let documentWorkspace = try XCTUnwrap(collection.activeWorkspace)
        let document = try XCTUnwrap(documentWorkspace.document)
        let recentID = try XCTUnwrap(store.documents.first?.id)
        documentWorkspace.setMode(.editing)
        documentWorkspace.currentPageIndex = 1
        documentWorkspace.selectedPages = [1]
        documentWorkspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(documentWorkspace.isDirty)
        let homeTabID = collection.newTab()
        let savedHistory = persistence.data
        let createdBookmarks = coder.bookmarkCreationCount
        coder.failResolution = true

        XCTAssertEqual(collection.openRecentDocument(id: recentID), documentTabID)

        XCTAssertEqual(collection.activeTabID, documentTabID)
        XCTAssertEqual(collection.tabs.map(\.id), [documentTabID, homeTabID])
        XCTAssertTrue(collection.activeWorkspace === documentWorkspace)
        XCTAssertTrue(documentWorkspace.document === document)
        XCTAssertTrue(documentWorkspace.isDirty)
        XCTAssertEqual(documentWorkspace.currentPageIndex, 1)
        XCTAssertEqual(documentWorkspace.selectedPages, [1])
        XCTAssertEqual(document.page(at: 1)?.rotation, 90)
        XCTAssertNil(collection.recentDocumentRecovery)
        XCTAssertNil(documentWorkspace.presentedError)
        XCTAssertEqual(coder.resolutionCount, 0, "A loaded document does not need a fresh file-access grant")
        XCTAssertEqual(coder.bookmarkCreationCount, createdBookmarks)
        XCTAssertEqual(persistence.data, savedHistory)
        XCTAssertEqual(try Data(contentsOf: fixture.url), originalBytes)
    }

    @MainActor
    func testExplicitReselectionRepairsBookmarkForNextPersistedResolve() throws {
        let fixture = try makePDFFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = MemoryRecentDocumentsPersistence()
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        let recent = try store.record(url: fixture.url)
        coder.failedGenerations.insert(1)
        let collection = MultiDocumentWorkspaceState(recentDocumentsStore: store)
        XCTAssertNil(collection.openRecentDocument(id: recent.id))
        XCTAssertEqual(collection.recentDocumentRecovery?.recentID, recent.id)

        let openedID = try XCTUnwrap(collection.reopenRecentDocument(id: recent.id, from: fixture.url))

        XCTAssertEqual(collection.activeTabID, openedID)
        XCTAssertNotNil(collection.activeWorkspace?.document)
        XCTAssertNil(collection.recentDocumentRecovery)
        XCTAssertEqual(store.documents.map(\.id), [recent.id], "Reselecting the same file repairs its existing record")
        XCTAssertGreaterThan(coder.bookmarkCreationCount, 1)
        XCTAssertTrue(coder.failedGenerations.contains(1), "The original bookmark remains invalid")
        let reloaded = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        let access = try reloaded.resolve(id: recent.id)
        XCTAssertEqual(access.url.standardizedFileURL.resolvingSymlinksInPath(),
                       fixture.url.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertNil(reloaded.lastError)
    }

    @MainActor
    func testExplicitReselectionOfResidentDirtyPDFKeepsLiveDocumentAndRepairsAccess() throws {
        let fixture = try makePDFFixture(pageCount: 2)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let originalBytes = try Data(contentsOf: fixture.url)
        let persistence = MemoryRecentDocumentsPersistence()
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        let collection = MultiDocumentWorkspaceState(recentDocumentsStore: store)
        let documentTabID = try XCTUnwrap(collection.openPDFsInTabs(urls: [fixture.url]).first)
        let documentWorkspace = try XCTUnwrap(collection.activeWorkspace)
        let document = try XCTUnwrap(documentWorkspace.document)
        let recentID = try XCTUnwrap(store.documents.first?.id)
        coder.failedGenerations.insert(1)
        documentWorkspace.setMode(.editing)
        documentWorkspace.currentPageIndex = 1
        documentWorkspace.selectedPages = [1]
        documentWorkspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(documentWorkspace.isDirty)
        let homeTabID = collection.newTab()

        XCTAssertEqual(collection.reopenRecentDocument(id: recentID, from: fixture.url), documentTabID)

        XCTAssertEqual(collection.activeTabID, documentTabID)
        XCTAssertEqual(collection.tabs.map(\.id), [documentTabID, homeTabID])
        XCTAssertTrue(collection.activeWorkspace === documentWorkspace)
        XCTAssertTrue(documentWorkspace.document === document)
        XCTAssertTrue(documentWorkspace.isDirty)
        XCTAssertEqual(documentWorkspace.currentPageIndex, 1)
        XCTAssertEqual(documentWorkspace.selectedPages, [1])
        XCTAssertEqual(document.page(at: 1)?.rotation, 90)
        XCTAssertEqual(documentWorkspace.documentURL?.standardizedFileURL, fixture.url.standardizedFileURL)
        XCTAssertNil(documentWorkspace.presentedError)
        XCTAssertEqual(store.documents.map(\.id), [recentID])
        XCTAssertEqual(coder.resolutionCount, 0)
        let reloaded = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        XCTAssertEqual(try reloaded.resolve(id: recentID).url.standardizedFileURL, fixture.url.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: fixture.url), originalBytes)
    }

    @MainActor
    func testExplicitMovedFileRecoveryReplacesStalePathWithoutEvictingUnrelatedHistory() throws {
        let fixture = try makePDFFixture(pageCount: 2)
        let otherFiles = try makeFiles(count: 6)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        addTeardownBlock { try? FileManager.default.removeItem(at: otherFiles.directory) }
        let persistence = MemoryRecentDocumentsPersistence()
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        try otherFiles.urls.forEach { try store.record(url: $0) }
        let unrelatedRecords = store.documents
        // Put the broken entry first, so inserting a new eighth entry before
        // removing it would evict an unrelated document from the history.
        let recent = try store.record(url: fixture.url)
        let movedURL = fixture.directory.appendingPathComponent("relocated.pdf")
        try FileManager.default.moveItem(at: fixture.url, to: movedURL)
        let originalBytes = try Data(contentsOf: movedURL)
        let collection = MultiDocumentWorkspaceState(recentDocumentsStore: store)

        XCTAssertNil(collection.openRecentDocument(id: recent.id))
        XCTAssertEqual(collection.recentDocumentRecovery?.recentID, recent.id)
        XCTAssertEqual(store.documents, [recent] + unrelatedRecords)
        let openedID = try XCTUnwrap(collection.reopenRecentDocument(id: recent.id, from: movedURL))

        XCTAssertEqual(collection.activeTabID, openedID)
        XCTAssertEqual(collection.activeWorkspace?.document?.pageCount, 2)
        XCTAssertNil(collection.recentDocumentRecovery)
        let replacement = try XCTUnwrap(store.documents.first)
        XCTAssertEqual(store.documents.count, 7)
        XCTAssertEqual(replacement.id, recent.id)
        XCTAssertEqual(replacement.displayName, movedURL.lastPathComponent)
        XCTAssertEqual(Array(store.documents.dropFirst()), unrelatedRecords)
        XCTAssertEqual(store.fileURLHint(id: recent.id)?.resolvingSymlinksInPath(),
                       movedURL.standardizedFileURL.resolvingSymlinksInPath())
        let reloaded = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        XCTAssertEqual(reloaded.documents, [replacement] + unrelatedRecords)
        XCTAssertEqual(try reloaded.resolve(id: replacement.id).url.standardizedFileURL,
                       movedURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: movedURL), originalBytes)
    }

    @MainActor
    func testInvalidReselectedPDFDoesNotEvictOrRewriteFullRecentHistory() throws {
        let fixture = try makePDFFixture()
        let otherFiles = try makeFiles(count: 6)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        addTeardownBlock { try? FileManager.default.removeItem(at: otherFiles.directory) }
        let persistence = MemoryRecentDocumentsPersistence()
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        let recent = try store.record(url: fixture.url)
        try otherFiles.urls.forEach { try store.record(url: $0) }
        let originalRecords = store.documents
        let originalPersistence = persistence.data
        let originalBytes = try Data(contentsOf: fixture.url)
        let invalidURL = fixture.directory.appendingPathComponent("not-a-valid.pdf")
        try Data("This file is not a PDF.".utf8).write(to: invalidURL)
        coder.failedGenerations.insert(1)
        let collection = MultiDocumentWorkspaceState(recentDocumentsStore: store)
        XCTAssertNil(collection.openRecentDocument(id: recent.id))
        XCTAssertEqual(collection.recentDocumentRecovery?.recentID, recent.id)

        XCTAssertNil(collection.reopenRecentDocument(id: recent.id, from: invalidURL))

        XCTAssertFalse(collection.tabs.contains { $0.workspace.hasOpenDocument })
        XCTAssertEqual(store.documents.count, 7)
        XCTAssertEqual(store.documents, originalRecords)
        XCTAssertEqual(persistence.data, originalPersistence)
        XCTAssertEqual(RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder).documents,
                       originalRecords)
        XCTAssertNotNil(store.fileURLHint(id: recent.id))
        XCTAssertEqual(try Data(contentsOf: fixture.url), originalBytes)
    }

    @MainActor
    func testNewHomeAndClearingHistoryPreserveDirtyDocumentAndSourceFile() throws {
        let fixture = try makePDFFixture(pageCount: 2)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let originalBytes = try Data(contentsOf: fixture.url)
        let persistence = MemoryRecentDocumentsPersistence()
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        let workspace = MultiDocumentWorkspaceState(recentDocumentsStore: store)
        let documentTabID = try XCTUnwrap(workspace.openPDFsInTabs(urls: [fixture.url]).first)
        let documentWorkspace = try XCTUnwrap(workspace.activeWorkspace)
        let document = try XCTUnwrap(documentWorkspace.document)
        documentWorkspace.setMode(.editing)
        documentWorkspace.currentPageIndex = 1
        documentWorkspace.selectedPages = [1]
        documentWorkspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(documentWorkspace.isDirty)
        XCTAssertEqual(document.page(at: 1)?.rotation, 90)

        let homeTabID = workspace.newTab()

        XCTAssertNotEqual(homeTabID, documentTabID)
        XCTAssertEqual(workspace.activeTabID, homeTabID)
        XCTAssertFalse(try XCTUnwrap(workspace.activeWorkspace).hasOpenDocument)
        XCTAssertFalse(workspace.activeWorkspace?.isDirty ?? true)

        func assertDocumentPreserved(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(workspace.tabs.map(\.id), [documentTabID, homeTabID], file: file, line: line)
            XCTAssertEqual(workspace.activeTabID, homeTabID, file: file, line: line)
            XCTAssertTrue(workspace.tabs[0].workspace === documentWorkspace, file: file, line: line)
            XCTAssertTrue(documentWorkspace.document === document, file: file, line: line)
            XCTAssertTrue(documentWorkspace.isDirty, file: file, line: line)
            XCTAssertEqual(documentWorkspace.currentPageIndex, 1, file: file, line: line)
            XCTAssertEqual(document.page(at: 1)?.rotation, 90, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: fixture.url), originalBytes, file: file, line: line)
        }
        try assertDocumentPreserved()

        let recentID = try XCTUnwrap(workspace.recentDocuments.first?.id)
        workspace.removeRecentDocument(id: recentID)
        XCTAssertTrue(workspace.recentDocuments.isEmpty)
        try assertDocumentPreserved()

        workspace.recordRecentDocument(url: fixture.url)
        XCTAssertEqual(workspace.recentDocuments.count, 1)
        workspace.clearRecentDocuments()

        XCTAssertTrue(workspace.recentDocuments.isEmpty)
        XCTAssertNil(persistence.data)
        XCTAssertTrue(RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder).documents.isEmpty)
        try assertDocumentPreserved()
    }

    @MainActor
    func testAsyncBatchRecordsEachUniqueSuccessfulDocumentOnce() async throws {
        let fixture = try makePDFFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RecentDocumentsStore(
            persistence: MemoryRecentDocumentsPersistence(),
            bookmarkCoder: FakeRecentDocumentBookmarkCoder()
        )
        let workspace = MultiDocumentWorkspaceState(recentDocumentsStore: store)

        let opened = await workspace.openPDFsInTabsAsync(
            urls: [fixture.url, fixture.url]
        )

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(workspace.recentDocuments.count, 1)
        XCTAssertEqual(workspace.recentDocuments.first?.displayName, fixture.url.lastPathComponent)
        XCTAssertEqual(workspace.activeTabID, opened.last)
    }

    @MainActor
    func testEightBookmarkFailuresProduceOneWarningAndKeepOpenedTabsAndHistory() throws {
        let fixture = try makePDFFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let urls = try makePDFCopies(of: fixture.url, count: 8)
        let persistence = MemoryRecentDocumentsPersistence()
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        let previous = try store.record(url: fixture.url)
        let originalHistory = persistence.data
        coder.failBookmarkCreation = true
        let collection = MultiDocumentWorkspaceState(recentDocumentsStore: store)

        let opened = collection.openPDFsInTabs(urls: urls)

        XCTAssertEqual(opened.count, 8)
        XCTAssertEqual(Set(collection.tabs.map(\.id)), Set(opened))
        XCTAssertEqual(collection.activeTabID, opened.last)
        XCTAssertEqual(Set(collection.tabs.compactMap { $0.workspace.documentURL?.lastPathComponent }),
                       Set(urls.map(\.lastPathComponent)))
        XCTAssertNotNil(collection.activeWorkspace?.document)
        let warning = try XCTUnwrap(collection.activeWorkspace?.presentedError)
        assertSingleRecentWarning(warning)
        XCTAssertEqual(store.documents, [previous])
        XCTAssertEqual(persistence.data, originalHistory)
    }

    @MainActor
    func testAsyncMixedBatchKeepsOpenFailureAlongsideOneRecentRecordWarning() async throws {
        let fixture = try makePDFFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let urls = try makePDFCopies(of: fixture.url, count: 8)
        let invalidURL = fixture.directory.appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: invalidURL)
        let coder = FakeRecentDocumentBookmarkCoder()
        coder.failBookmarkCreation = true
        let store = RecentDocumentsStore(
            persistence: MemoryRecentDocumentsPersistence(), bookmarkCoder: coder
        )
        let collection = MultiDocumentWorkspaceState(recentDocumentsStore: store)

        let opened = await collection.openPDFsInTabsAsync(urls: urls + [invalidURL])

        XCTAssertEqual(opened.count, 8)
        let warning = try XCTUnwrap(collection.activeWorkspace?.presentedError)
        assertSingleRecentWarning(warning)
        XCTAssertTrue(warning.contains(L10n.format("status.open_failed", "‘invalid.pdf’")))
        XCTAssertTrue(store.documents.isEmpty)
    }

    @MainActor
    func testRecordWarningPreservesExistingErrorAndCanReappearAfterDismissal() throws {
        let fixture = try makePDFFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(
            persistence: MemoryRecentDocumentsPersistence(), bookmarkCoder: coder
        )
        let collection = MultiDocumentWorkspaceState(recentDocumentsStore: store)
        _ = collection.openPDFsInTabs(urls: [fixture.url])
        let workspace = try XCTUnwrap(collection.activeWorkspace)
        workspace.presentedError = "An unrelated document warning"
        coder.failBookmarkCreation = true

        collection.recordRecentDocument(url: fixture.url)
        let firstWarning = try XCTUnwrap(workspace.presentedError)
        collection.recordRecentDocument(url: fixture.url)

        XCTAssertEqual(workspace.presentedError, firstWarning)
        XCTAssertTrue(firstWarning.hasPrefix("An unrelated document warning\n\n"))
        assertSingleRecentWarning(firstWarning)
        workspace.presentedError = nil
        collection.recordRecentDocument(url: fixture.url)
        let nextWarning = try XCTUnwrap(workspace.presentedError)
        assertSingleRecentWarning(nextWarning)
        XCTAssertFalse(nextWarning.contains("An unrelated document warning"))
    }

    @MainActor
    func testRepeatedReconnectBookmarkFailureKeepsOriginalHistoryAndLiveDocument() throws {
        let fixture = try makePDFFixture(pageCount: 2)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let originalBytes = try Data(contentsOf: fixture.url)
        let persistence = MemoryRecentDocumentsPersistence()
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        let collection = MultiDocumentWorkspaceState(recentDocumentsStore: store)
        let tabID = try XCTUnwrap(collection.openPDFsInTabs(urls: [fixture.url]).first)
        let workspace = try XCTUnwrap(collection.activeWorkspace)
        let document = try XCTUnwrap(workspace.document)
        let recent = try XCTUnwrap(store.documents.first)
        let history = persistence.data
        workspace.setMode(.editing)
        workspace.selectedPages = [1]
        workspace.rotateSelectedPages(clockwise: true)
        workspace.presentedError = "An unrelated document warning"
        coder.failBookmarkCreation = true

        for _ in 0..<8 {
            XCTAssertEqual(collection.reopenRecentDocument(id: recent.id, from: fixture.url), tabID)
        }

        XCTAssertEqual(collection.tabs.count, 1)
        XCTAssertTrue(workspace.document === document)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(document.page(at: 1)?.rotation, 90)
        XCTAssertEqual(store.documents, [recent])
        XCTAssertEqual(persistence.data, history)
        XCTAssertEqual(try Data(contentsOf: fixture.url), originalBytes)
        let warning = try XCTUnwrap(workspace.presentedError)
        assertSingleRecentWarning(warning)
        XCTAssertTrue(warning.hasPrefix("An unrelated document warning\n\n"))
    }

    private func assertSingleRecentWarning(
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let heading = L10n.string("status.recent_record_failed")
        XCTAssertEqual(message.components(separatedBy: heading).count - 1, 1, file: file, line: line)
        XCTAssertEqual(message.components(separatedBy: "bookmark creation failed").count - 1,
                       1, file: file, line: line)
    }

    private func makePDFCopies(of source: URL, count: Int) throws -> [URL] {
        try (0..<count).map { index in
            let url = source.deletingLastPathComponent().appendingPathComponent("copy-\(index).pdf")
            try FileManager.default.copyItem(at: source, to: url)
            return url
        }
    }

    private func makeFiles(count: Int) throws -> (directory: URL, urls: [URL]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Recents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try (0..<count).map { index in
            let url = directory.appendingPathComponent("document-\(index).pdf")
            try Data("fixture-\(index)".utf8).write(to: url)
            return url
        }
        return (directory, urls)
    }

    private func makePDFFixture(pageCount: Int = 1) throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Recent-PDF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("recent.pdf")
        let document = PDFDocument()
        let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        for _ in 0..<pageCount {
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: document.pageCount)
        }
        XCTAssertTrue(document.write(to: url))
        return (directory, url)
    }
}

private final class MemoryRecentDocumentsPersistence: RecentDocumentsPersisting {
    var data: Data?
}

private final class FakeRecentDocumentBookmarkCoder: RecentDocumentBookmarkCoding {
    private struct Payload: Codable {
        let url: URL
        let generation: Int
    }

    enum Failure: LocalizedError {
        case creation
        case resolution

        var errorDescription: String? {
            switch self {
            case .creation: "bookmark creation failed"
            case .resolution: "bookmark resolution failed"
            }
        }
    }

    var staleGenerations: Set<Int> = []
    var failedGenerations: Set<Int> = []
    var failBookmarkCreation = false
    var failResolution = false
    private(set) var bookmarkCreationCount = 0
    private(set) var resolutionCount = 0

    func makeBookmark(for url: URL) throws -> Data {
        if failBookmarkCreation { throw Failure.creation }
        bookmarkCreationCount += 1
        return try JSONEncoder().encode(
            Payload(url: url, generation: bookmarkCreationCount)
        )
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        resolutionCount += 1
        if failResolution { throw Failure.resolution }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        if failedGenerations.contains(payload.generation) { throw Failure.resolution }
        return (payload.url, staleGenerations.contains(payload.generation))
    }
}
