// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class StudyLinkStoreTests: XCTestCase {
    func testPreviousEndpointDataWithoutBookmarkTitleStillDecodes() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["documentID": id.uuidString, "pageIndex": 11])
        let endpoint = try JSONDecoder().decode(StudyLinkEndpoint.self, from: data)
        XCTAssertEqual(endpoint.documentID, id)
        XCTAssertEqual(endpoint.pageIndex, 11)
        XCTAssertNil(endpoint.bookmarkTitle)
        XCTAssertNil(endpoint.note)
    }

    @MainActor
    func testBookmarkPageTitlePersistsAndStillMatchesPageConnections() throws {
        let pair = try makePair()
        let memory = LinkTestPersistence()
        let store = StudyLinkStore(persistence: memory, bookmarkCoder: LinkTestBookmarks())
        let link = try store.add(from: pair.0, to: pair.1, targetPage: 1, targetBookmarkTitle: "Chapter two")
        let pageEndpoint = try XCTUnwrap(store.endpoint(workspace: pair.1, pageIndex: 1))
        XCTAssertEqual(store.connections(to: pageEndpoint).map(\.id), [link.id])
        let restored = StudyLinkStore(persistence: memory, bookmarkCoder: LinkTestBookmarks())
        XCTAssertEqual(restored.links.first?.second.bookmarkTitle, "Chapter two")
        XCTAssertEqual(restored.links.first?.second.pageIndex, 1)
    }

    @MainActor
    func testBidirectionalConnectionPersistsWithoutChangingPDFs() throws {
        let pair = try makePair()
        let memory = LinkTestPersistence()
        let coder = LinkTestBookmarks()
        let store = StudyLinkStore(persistence: memory, bookmarkCoder: coder)
        let firstNote = try note(in: pair.0, page: 0)
        let secondNote = try note(in: pair.1, page: 1)
        let link = try store.add(from: pair.0, sourceNote: firstNote, to: pair.1,
                                 targetPage: 1, targetNote: secondNote)
        let first = try XCTUnwrap(store.endpoint(workspace: pair.0, note: firstNote))
        let second = try XCTUnwrap(store.endpoint(workspace: pair.1, note: secondNote))
        XCTAssertEqual(store.connections(to: first).map(\.id), [link.id])
        XCTAssertEqual(store.connections(to: second).map(\.id), [link.id])
        XCTAssertEqual(link.destination(from: second), first)
        XCTAssertFalse(pair.0.isDirty)
        XCTAssertFalse(pair.1.isDirty)

        let restored = StudyLinkStore(persistence: memory, bookmarkCoder: coder)
        XCTAssertEqual(restored.links, [link])
        XCTAssertEqual(restored.connections(to: first).count, 1)
        try restored.remove(link)
        XCTAssertTrue(restored.links.isEmpty)
        XCTAssertTrue(restored.documents.isEmpty, "unused bookmarks should not remain after removing the last relation")
        XCTAssertTrue(StudyLinkStore(persistence: memory, bookmarkCoder: coder).links.isEmpty)
    }

    @MainActor
    func testReversedDuplicateAndSelfLinkAreRejectedAtomically() throws {
        let pair = try makePair()
        let memory = LinkTestPersistence()
        let store = StudyLinkStore(persistence: memory, bookmarkCoder: LinkTestBookmarks())
        _ = try store.add(from: pair.0, to: pair.1, targetPage: 0)
        let snapshot = memory.data
        XCTAssertThrowsError(try store.add(from: pair.1, to: pair.0, targetPage: 0))
        XCTAssertThrowsError(try store.add(from: pair.0, to: pair.0, targetPage: 0))
        XCTAssertEqual(memory.data, snapshot)
        XCTAssertEqual(store.links.count, 1)
    }

    @MainActor
    func testSecondBookmarkFailureLeavesNoPartialGraph() throws {
        let pair = try makePair()
        let coder = LinkTestBookmarks()
        coder.failingCreationPath = pair.1.documentURL?.path
        let memory = LinkTestPersistence()
        let store = StudyLinkStore(persistence: memory, bookmarkCoder: coder)
        XCTAssertThrowsError(try store.add(from: pair.0, to: pair.1, targetPage: 0))
        XCTAssertNil(memory.data)
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertTrue(store.links.isEmpty)
    }

    @MainActor
    func testForeignOrDetachedNoteCannotCreateConnection() throws {
        let pair = try makePair()
        let store = StudyLinkStore(persistence: LinkTestPersistence(), bookmarkCoder: LinkTestBookmarks())
        let wrongNote = try note(in: pair.1, page: 0)
        XCTAssertThrowsError(try store.add(from: pair.0, sourceNote: wrongNote, to: pair.1, targetPage: 1))
        let detached = try note(in: pair.0, page: 0)
        detached.annotation.page?.removeAnnotation(detached.annotation)
        XCTAssertThrowsError(try store.add(from: pair.0, sourceNote: detached, to: pair.1, targetPage: 1))
        XCTAssertTrue(store.links.isEmpty)
    }

    @MainActor
    func testNamedNoteStillResolvesAfterContentAndBoundsChangeAndRoundTrip() throws {
        let pair = try makePair()
        let item = try note(in: pair.0, page: 0)
        let locator = StudyLinkNoteLocator(annotation: item.annotation)
        item.annotation.contents = "An edited explanation"
        item.annotation.bounds = CGRect(x: 40, y: 40, width: 130, height: 60)
        let bytes = try XCTUnwrap(pair.0.document?.dataRepresentation())
        let reloaded = try XCTUnwrap(PDFDocument(data: bytes))
        let resolved = try XCTUnwrap(locator.resolve(on: try XCTUnwrap(reloaded.page(at: 0))))
        XCTAssertEqual(resolved.contents, "An edited explanation")
        XCTAssertEqual(resolved.bounds.width, 130, accuracy: 0.1)
    }

    @MainActor
    func testLegacyNoteConnectionAddsDurableIdentityOnlyAfterValidation() throws {
        let pair = try makePair()
        pair.0.setMode(.study)
        pair.1.setMode(.study)
        let first = try note(in: pair.0, page: 0)
        let second = try note(in: pair.1, page: 1)
        first.annotation.removeValue(forAnnotationKey: StudyLinkNoteIdentity.key)
        second.annotation.removeValue(forAnnotationKey: StudyLinkNoteIdentity.key)
        let coder = LinkTestBookmarks()
        coder.failingCreationPath = pair.1.documentURL?.path
        let store = StudyLinkStore(persistence: LinkTestPersistence(), bookmarkCoder: coder)
        XCTAssertThrowsError(try store.add(from: pair.0, sourceNote: first, to: pair.1,
                                          targetPage: 1, targetNote: second))
        XCTAssertNil(StudyLinkNoteIdentity.identifier(in: first.annotation))
        XCTAssertFalse(pair.0.isDirty)
        coder.failingCreationPath = nil
        let link = try store.add(from: pair.0, sourceNote: first, to: pair.1,
                                 targetPage: 1, targetNote: second)
        XCTAssertTrue(pair.0.isDirty)
        XCTAssertTrue(pair.1.isDirty)
        XCTAssertNotNil(StudyLinkNoteIdentity.identifier(in: first.annotation))
        second.annotation.contents = "Changed after connecting"
        let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(pair.1.document?.dataRepresentation())))
        XCTAssertEqual(link.second.note?.resolve(on: try XCTUnwrap(reopened.page(at: 1)))?.contents,
                       "Changed after connecting")
    }

    @MainActor
    func testLegacyNoteWithoutEditingCapabilityDoesNotPartlyAdoptSource() throws {
        let pair = try makePair(protectedSecond: true)
        pair.0.setMode(.study)
        pair.1.setMode(.study)
        let first = try note(in: pair.0, page: 0)
        let second = try note(in: pair.1, page: 1)
        first.annotation.removeValue(forAnnotationKey: StudyLinkNoteIdentity.key)
        second.annotation.removeValue(forAnnotationKey: StudyLinkNoteIdentity.key)
        let store = StudyLinkStore(persistence: LinkTestPersistence(), bookmarkCoder: LinkTestBookmarks())
        XCTAssertThrowsError(try store.add(from: pair.0, sourceNote: first, to: pair.1,
                                          targetPage: 1, targetNote: second))
        XCTAssertNil(StudyLinkNoteIdentity.identifier(in: first.annotation))
        XCTAssertFalse(pair.0.isDirty)
        XCTAssertTrue(store.links.isEmpty)
        XCTAssertNoThrow(try store.add(from: pair.0, to: pair.1, targetPage: 1),
                         "page connections need no PDF metadata mutation")
    }

    @MainActor
    func testAmbiguousExternalNotesAreNotGuessed() throws {
        let pair = try makePair()
        let page = try XCTUnwrap(pair.0.document?.page(at: 0))
        page.annotations.forEach(page.removeAnnotation)
        let first = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 90, height: 30), forType: .freeText,
                                  withProperties: nil)
        first.contents = "Same phrase"
        page.addAnnotation(first)
        let locator = StudyLinkNoteLocator(annotation: first)
        let second = PDFAnnotation(bounds: first.bounds, forType: .freeText, withProperties: nil)
        second.contents = first.contents
        page.addAnnotation(second)
        XCTAssertNil(locator.resolve(on: page))
        page.removeAnnotation(second)
        XCTAssertTrue(locator.resolve(on: page) === first)
    }

    @MainActor
    func testCorruptArchiveIsPreservedAndCannotBeSilentlyOverwritten() throws {
        let pair = try makePair()
        let memory = LinkTestPersistence()
        memory.data = Data("not a link archive".utf8)
        let original = memory.data
        let store = StudyLinkStore(persistence: memory, bookmarkCoder: LinkTestBookmarks())
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.add(from: pair.0, to: pair.1, targetPage: 0))
        XCTAssertEqual(memory.data, original)
    }

    @MainActor
    func testResidentDestinationUsesExistingTabEvenWhenBookmarkExpired() async throws {
        let pair = try makePair()
        let coder = LinkTestBookmarks()
        let store = StudyLinkStore(persistence: LinkTestPersistence(), bookmarkCoder: coder)
        let link = try store.add(from: pair.0, to: pair.1, targetPage: 1)
        coder.failResolution = true
        let container = MultiDocumentWorkspaceState(initialSession: PDFTabSession(workspace: pair.1))
        let tabID = container.activeTabID
        let opened = try await store.open(link.second, in: container)
        XCTAssertTrue(opened)
        XCTAssertEqual(container.activeTabID, tabID)
        XCTAssertEqual(container.allTabs.count, 1)
        XCTAssertEqual(pair.1.currentPageIndex, 1)
        XCTAssertEqual(coder.resolutionCount, 0)
    }

    @MainActor
    func testExpiredBookmarkDoesNotFallBackToReadableStoredPath() async throws {
        let pair = try makePair()
        let coder = LinkTestBookmarks()
        let store = StudyLinkStore(persistence: LinkTestPersistence(), bookmarkCoder: coder)
        let link = try store.add(from: pair.0, to: pair.1, targetPage: 1)
        coder.failResolution = true
        let container = MultiDocumentWorkspaceState(initialSession: PDFTabSession(workspace: pair.0))
        do {
            _ = try await store.open(link.second, in: container)
            XCTFail("A readable path is not a replacement for an expired file grant")
        } catch { XCTAssertEqual(container.allTabs.count, 1) }
        XCTAssertTrue(container.activeWorkspace === pair.0)
        XCTAssertEqual(coder.resolutionCount, 1)
    }

    @MainActor
    func testMissingNoteOpensItsPageWithoutPickingAnotherAnnotation() async throws {
        let pair = try makePair()
        let store = StudyLinkStore(persistence: LinkTestPersistence(), bookmarkCoder: LinkTestBookmarks())
        let item = try note(in: pair.1, page: 1)
        let link = try store.add(from: pair.0, to: pair.1, targetPage: 1, targetNote: item)
        item.annotation.page?.removeAnnotation(item.annotation)
        let container = MultiDocumentWorkspaceState(initialSession: PDFTabSession(workspace: pair.1))
        let foundNote = try await store.open(link.second, in: container)
        XCTAssertFalse(foundNote)
        XCTAssertEqual(pair.1.currentPageIndex, 1)
        XCTAssertNil(pair.1.studyNoteRevealRequest)
    }

    @MainActor
    func testBookmarkTracksMovedSourceAndRecognizesOnlyOnce() throws {
        let pair = try makePair()
        let coder = LinkTestBookmarks()
        let store = StudyLinkStore(persistence: LinkTestPersistence(), bookmarkCoder: coder)
        let link = try store.add(from: pair.0, to: pair.1, targetPage: 1)
        let sourceURL = try XCTUnwrap(pair.0.documentURL)
        let movedURL = sourceURL.deletingLastPathComponent().appendingPathComponent("moved.pdf")
        coder.relocations[sourceURL.path] = movedURL
        store.recognizeOpenedDocument(movedURL)
        XCTAssertEqual(store.document(id: link.first.documentID)?.path, movedURL.path)
        let count = coder.resolutionCount
        store.recognizeOpenedDocument(movedURL)
        XCTAssertEqual(coder.resolutionCount, count)
        XCTAssertEqual(store.links.count, 1)
    }

    @MainActor
    func testExplicitReconnectRefreshesGrantAndPersistsSameEndpointIdentity() async throws {
        let pair = try makePair()
        let memory = LinkTestPersistence()
        let coder = LinkTestBookmarks()
        let store = StudyLinkStore(persistence: memory, bookmarkCoder: coder)
        let link = try store.add(from: pair.0, to: pair.1, targetPage: 1)
        let targetURL = try XCTUnwrap(pair.1.documentURL)
        let movedURL = targetURL.deletingLastPathComponent().appendingPathComponent("renamed.pdf")
        try FileManager.default.copyItem(at: targetURL, to: movedURL)
        let container = MultiDocumentWorkspaceState(initialSession: PDFTabSession(workspace: pair.0))
        let reconnected = try await store.reconnect(link.second, authorizedURL: movedURL, in: container)
        XCTAssertTrue(reconnected)
        XCTAssertEqual(store.document(id: link.second.documentID)?.path, movedURL.path)
        XCTAssertEqual(container.activeWorkspace?.currentPageIndex, 1)
        XCTAssertEqual(store.links, [link])
        let restored = StudyLinkStore(persistence: memory, bookmarkCoder: coder)
        XCTAssertEqual(restored.document(id: link.second.documentID)?.path, movedURL.path)
    }

    @MainActor
    private func note(in workspace: PDFWorkspaceState, page: Int) throws -> StudyNoteItem {
        try XCTUnwrap(workspace.studyNotes(on: page).first)
    }

    @MainActor
    private func makePair(protectedSecond: Bool = false) throws -> (PDFWorkspaceState, PDFWorkspaceState) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-StudyLinks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var workspaces: [PDFWorkspaceState] = []
        for name in ["A.pdf", "B.pdf"] {
            let document = PDFDocument()
            for index in 0..<2 {
                let image = NSImage(size: CGSize(width: 200, height: 260), flipped: false) { rect in
                    NSColor.white.setFill(); rect.fill(); return true
                }
                let page = try XCTUnwrap(PDFPage(image: image))
                let annotation = PDFAnnotation(bounds: CGRect(x: 15, y: 160, width: 150, height: 60),
                                               forType: .freeText, withProperties: nil)
                annotation.contents = "\(name) note \(index)"
                annotation.font = .systemFont(ofSize: 12)
                annotation.setValue("EmberPDF-Test-\(UUID())", forAnnotationKey: .name)
                StudyLinkNoteIdentity.assignIfNeeded(to: annotation)
                page.addAnnotation(annotation)
                document.insert(page, at: index)
            }
            let url = directory.appendingPathComponent(name)
            if protectedSecond && name == "B.pdf" {
                XCTAssertTrue(document.write(to: url, withOptions: [
                    .ownerPasswordOption: "OwnerPass9", .userPasswordOption: "ReaderPass9",
                    .accessPermissionsOption: NSNumber(value: 0),
                    PDFDocumentWriteOption(rawValue: kCGPDFContextEncryptionKeyLength as String): 128
                ]))
            } else { XCTAssertTrue(document.write(to: url)) }
            let workspace = PDFWorkspaceState(passwordProvider: { _, _ in "ReaderPass9" })
            XCTAssertTrue(workspace.open(url: url))
            workspaces.append(workspace)
        }
        return (workspaces[0], workspaces[1])
    }
}

private final class LinkTestPersistence: RecentDocumentsPersisting { var data: Data? }

private final class LinkTestBookmarks: RecentDocumentBookmarkCoding {
    var failingCreationPath: String?
    var failResolution = false
    var resolutionCount = 0
    var relocations: [String: URL] = [:]

    func makeBookmark(for url: URL) throws -> Data {
        if url.path == failingCreationPath { throw CocoaError(.fileReadNoPermission) }
        return Data(url.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        resolutionCount += 1
        if failResolution { throw CocoaError(.fileReadNoPermission) }
        guard let path = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        if let moved = relocations[path] { return (moved, true) }
        return (URL(fileURLWithPath: path), false)
    }
}
