// SPDX-License-Identifier: MPL-2.0
import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFRemoteNavigationPreserverTests: XCTestCase {
    private let opaqueOriginalURI = "http://www.python<2010>scraping.com/pages/page3.html"

    func testLocalGoToActionChainAsyncSaveFailsBeforeLosingNativeAction() async throws {
        try await assertUnsupportedLocalActionFails(actionExtra: "/Next << /S /Named /N /NextPage >>", key: "Next")
    }

    func testLocalGoToActionExtensionAsyncSaveFailsBeforeLosingNativeAction() async throws {
        try await assertUnsupportedLocalActionFails(actionExtra: "/EmberExtension true", key: "EmberExtension")
    }

    func testUnsupportedLocalGoToExplicitReplacementWinsAcrossSnapshotCopy() async throws {
        for extra in ["/Next << /S /Named /N /NextPage >>", "/EmberExtension true"] {
            let (workspace, source) = try fixture(actionExtra: extra, localGoTo: true)
            defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
            let document = try XCTUnwrap(workspace.document), target = try XCTUnwrap(document.page(at: 1))
            for index in 0..<document.pageCount {
                let annotation = try XCTUnwrap(document.page(at: index)?.annotations.first)
                let previous = try XCTUnwrap((annotation.action as? PDFActionGoTo)?.destination)
                let replacement = PDFDestination(page: target, at: previous.point)
                replacement.zoom = previous.zoom
                annotation.action = PDFActionGoTo(destination: replacement)
            }
            // A second capture after authoring must never bless/re-baseline an
            // edited action or reattach the old unsupported native payload.
            PDFRemoteNavigationPreserver.captureOriginalActions(in: document)
            let bytes = try Data(contentsOf: source)
            let output = source.deletingLastPathComponent().appendingPathComponent("local-replaced.pdf")
            let saved = await workspace.saveAsynchronously(as: output)
            XCTAssertTrue(saved, workspace.presentedError ?? "Save failed")
            XCTAssertFalse(try nativeActionHasKey("Next", in: output))
            XCTAssertFalse(try nativeActionHasKey("EmberExtension", in: output))
            let reopened = try XCTUnwrap(PDFDocument(url: output))
            for index in 0..<reopened.pageCount {
                let action = try XCTUnwrap(reopened.page(at: index)?.annotations.first?.action as? PDFActionGoTo)
                XCTAssertTrue(action.destination.page === reopened.page(at: 1))
            }
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testUnsupportedLocalGoToExplicitRemovalWinsAcrossSnapshotCopy() async throws {
        let (workspace, source) = try fixture(actionExtra: "/Next << /S /Named /N /NextPage >>", localGoTo: true)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        for index in 0..<document.pageCount {
            let annotation = try XCTUnwrap(document.page(at: index)?.annotations.first)
            // PDFKit's action=nil alone leaves a valid destination/action
            // visible even in direct serialization. Match the existing full
            // navigation-removal operation and prove authoring took effect.
            annotation.destination = nil
            annotation.action = nil
            annotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/Dest"))
            annotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/A"))
            XCTAssertNil(annotation.destination); XCTAssertNil(annotation.action)
            XCTAssertNil(annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Dest")))
            XCTAssertNil(annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/A")))
        }
        PDFRemoteNavigationPreserver.captureOriginalActions(in: document)
        let output = source.deletingLastPathComponent().appendingPathComponent("local-removed.pdf")
        let saved = await workspace.saveAsynchronously(as: output)
        XCTAssertTrue(saved, workspace.presentedError ?? "Save failed")
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        for index in 0..<reopened.pageCount { XCTAssertNil(reopened.page(at: index)?.annotations.first?.action) }
    }

    func testUnsupportedLocalGoToRejectionSurvivesBodyPageReplacement() async throws {
        let (workspace, source) = try fixture(actionExtra: "/Next << /S /Named /N /NextPage >>", localGoTo: true)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document), oldPage = try XCTUnwrap(document.page(at: 0))
        let otherPage = try XCTUnwrap(document.page(at: 1))
        otherPage.removeAnnotation(try XCTUnwrap(otherPage.annotations.first))
        try edit(workspace, text: "Updated body")
        XCTAssertFalse(document.page(at: 0) === oldPage)
        PDFRemoteNavigationPreserver.captureOriginalActions(in: document)
        let original = try Data(contentsOf: source)
        XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: document))
        let saved = await workspace.saveAsynchronously()
        XCTAssertFalse(saved)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private func assertUnsupportedLocalActionFails(actionExtra: String, key: String) async throws {
        let (workspace, source) = try fixture(actionExtra: actionExtra, localGoTo: true)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let bytes = try Data(contentsOf: source)
        XCTAssertTrue(try nativeActionHasKey(key, in: source))
        workspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(workspace.isDirty)
        let document = try XCTUnwrap(workspace.document)
        XCTAssertTrue(PDFRemoteNavigationPreserver.hasOriginalActions(document))
        XCTAssertThrowsError(try PDFPageOperations.extract(from: document, indexes: [0]))
        let destination = PDFDocument(), sentinel = PDFPage(); destination.insert(sentinel, at: 0)
        XCTAssertThrowsError(try PDFPageOperations.append(contentsOf: document, to: destination))
        XCTAssertEqual(destination.pageCount, 1); XCTAssertTrue(destination.page(at: 0) === sentinel)
        let output = source.deletingLastPathComponent().appendingPathComponent("local-unsupported-save.pdf")
        let saved = await workspace.saveAsynchronously(as: output)
        if saved {
            // Retained in the red-test log to distinguish actual silent field
            // loss from a generic rejected save or a fixture parsing failure.
            print("LOCAL_GOTO_UNSUPPORTED_EVIDENCE key=\(key) source=true saved=true outputHasKey=\(try nativeActionHasKey(key, in: output))")
        }
        XCTAssertFalse(saved)
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    private func nativeActionHasKey(_ key: String, in url: URL, page: Int = 0) throws -> Bool {
        let native = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let dictionary = try XCTUnwrap(native.page(at: page + 1)?.dictionary)
        let annotations = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "Annots"))
        var annotation: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(annotations, 0, &annotation))
        let action = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(try XCTUnwrap(annotation), "A"))
        return PDFCatalogStructurePreserver.object(action, key) != nil
    }

    func testOpaqueOriginalURIOrdinarySavePreservesNativeStringBytes() throws {
        let (workspace, source) = try fixture(opaqueURI: opaqueOriginalURI)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        XCTAssertNil(URL(string: opaqueOriginalURI))
        let document = try XCTUnwrap(workspace.document)
        try assertUnparsedURIAction(XCTUnwrap(document.page(at: 0)?.annotations.first))
        XCTAssertTrue(PDFRemoteNavigationPreserver.hasOriginalActions(document))
        try assertOpaqueURIPayload(source)
        let output = source.deletingLastPathComponent().appendingPathComponent("uri-saved.pdf")
        XCTAssertTrue(workspace.saveSynchronously(as: output), workspace.presentedError ?? "Save failed")
        try assertOpaqueURIPayload(output)
    }

    func testOpaqueOriginalURISurvivesBodyReplacementReopenReeditAndExtraction() throws {
        let (workspace, source) = try fixture(opaqueURI: opaqueOriginalURI)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let oldPage = try XCTUnwrap(workspace.document?.page(at: 0))
        try edit(workspace, text: "Updated body")
        XCTAssertFalse(workspace.document?.page(at: 0) === oldPage)
        let first = source.deletingLastPathComponent().appendingPathComponent("uri-first.pdf")
        XCTAssertTrue(workspace.saveSynchronously(as: first), workspace.presentedError ?? "Save failed")
        try assertOpaqueURIPayload(first)
        let reopened = PDFWorkspaceState(); XCTAssertTrue(reopened.open(url: first)); reopened.setMode(.editing)
        try edit(reopened, text: "Another body")
        let second = source.deletingLastPathComponent().appendingPathComponent("uri-second.pdf")
        XCTAssertTrue(reopened.saveSynchronously(as: second), reopened.presentedError ?? "Save failed")
        try assertOpaqueURIPayload(second)
        let extracted = try PDFPageOperations.extract(from: XCTUnwrap(reopened.document), indexes: [0, 1])
        let output = source.deletingLastPathComponent().appendingPathComponent("uri-extracted.pdf")
        try AtomicPDFWriter.write(extracted, to: output)
        try assertOpaqueURIPayload(output)
    }

    func testOpaqueOriginalURIMergeThroughFreshLoadPreservesRawAction() throws {
        let (workspace, source) = try fixture(opaqueURI: opaqueOriginalURI)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        workspace.merge(urls: [source])
        XCTAssertNil(workspace.presentedError)
        XCTAssertEqual(workspace.pageCount, 4)
        let output = source.deletingLastPathComponent().appendingPathComponent("uri-merged.pdf")
        XCTAssertTrue(workspace.saveSynchronously(as: output), workspace.presentedError ?? "Save failed")
        try assertOpaqueURIPayload(output, pages: [0, 1, 2, 3])
    }

    func testOpaqueOriginalURIExplicitReplacementActionWinsAcrossBodyCopy() throws {
        let (workspace, source) = try fixture(opaqueURI: opaqueOriginalURI)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let annotation = try XCTUnwrap(workspace.document?.page(at: 0)?.annotations.first)
        let replacement = try XCTUnwrap(URL(string: "https://example.com/explicit-replacement"))
        annotation.action = PDFActionURL(url: replacement)
        try edit(workspace, text: "Updated body")
        let output = source.deletingLastPathComponent().appendingPathComponent("uri-replaced.pdf")
        XCTAssertTrue(workspace.saveSynchronously(as: output), workspace.presentedError ?? "Save failed")
        let saved = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual((saved.page(at: 0)?.annotations.first?.action as? PDFActionURL)?.url, replacement)
        try assertOpaqueURIPayload(output, pages: [1])
    }

    func testOpaqueOriginalURIDeletedAnnotationIsNotResurrected() throws {
        let (workspace, source) = try fixture(opaqueURI: opaqueOriginalURI)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        page.removeAnnotation(try XCTUnwrap(page.annotations.first))
        try edit(workspace, text: "Updated body")
        let output = source.deletingLastPathComponent().appendingPathComponent("uri-deleted.pdf")
        XCTAssertTrue(workspace.saveSynchronously(as: output), workspace.presentedError ?? "Save failed")
        XCTAssertEqual(PDFDocument(url: output)?.page(at: 0)?.annotations.count, 0)
        try assertOpaqueURIPayload(output, pages: [1])
    }

    func testOpaqueOriginalURIMutatingOriginalActionURLWins() throws {
        let (workspace, source) = try fixture(opaqueURI: opaqueOriginalURI)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let annotation = try XCTUnwrap(workspace.document?.page(at: 0)?.annotations.first)
        let originalAction = try XCTUnwrap(annotation.action as? PDFActionURL)
        let replacement = try XCTUnwrap(URL(string: "https://example.com/mutated-original-action"))
        originalAction.url = replacement
        try edit(workspace, text: "Updated body")
        let output = source.deletingLastPathComponent().appendingPathComponent("uri-mutated.pdf")
        XCTAssertTrue(workspace.saveSynchronously(as: output), workspace.presentedError ?? "Save failed")
        let saved = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual((saved.page(at: 0)?.annotations.first?.action as? PDFActionURL)?.url, replacement)
        try assertOpaqueURIPayload(output, pages: [1])
    }

    func testOpaqueOriginalURINewNilURLActionIdentityCannotInheritOriginalPayload() throws {
        let (workspace, source) = try fixture(opaqueURI: opaqueOriginalURI)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let annotation = try XCTUnwrap(workspace.document?.page(at: 0)?.annotations.first)
        let original = try XCTUnwrap(annotation.action as? PDFActionURL)
        let replacement = try XCTUnwrap(original.copy() as? PDFActionURL)
        XCTAssertFalse(original === replacement)
        annotation.action = replacement
        try assertUnparsedURIAction(annotation)
        try edit(workspace, text: "Updated body")
        let output = source.deletingLastPathComponent().appendingPathComponent("uri-new-empty-action.pdf")
        XCTAssertTrue(workspace.saveSynchronously(as: output), workspace.presentedError ?? "Save failed")
        try assertNoOriginalOpaqueURI(output, page: 0)
        try assertOpaqueURIPayload(output, pages: [1])
    }

    func testOpaqueOriginalURIClearingOriginalEmptyURLActionIsNotResurrected() throws {
        let (workspace, source) = try fixture(opaqueURI: opaqueOriginalURI)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let annotation = try XCTUnwrap(workspace.document?.page(at: 0)?.annotations.first)
        XCTAssertNotNil(annotation.action)
        annotation.action = nil
        try edit(workspace, text: "Updated body")
        let output = source.deletingLastPathComponent().appendingPathComponent("uri-cleared-action.pdf")
        XCTAssertTrue(workspace.saveSynchronously(as: output), workspace.presentedError ?? "Save failed")
        try assertNoOriginalOpaqueURI(output, page: 0)
        try assertOpaqueURIPayload(output, pages: [1])
    }

    func testOpaqueOriginalURIAlsoPreservesAnUnparsedNilActionBaseline() throws {
        let (_, source) = try fixture(opaqueURI: opaqueOriginalURI)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        // Model PDFKit returning no action object for the same unsupported
        // original string, instead of its current empty-URL action object.
        for index in 0..<document.pageCount { document.page(at: index)?.annotations.first?.action = nil }
        PDFRemoteNavigationPreserver.captureOriginalActions(in: document)
        let output = source.deletingLastPathComponent().appendingPathComponent("uri-nil-baseline.pdf")
        try AtomicPDFWriter.write(document, to: output)
        try assertOpaqueURIPayload(output)
    }

    func testOpaqueOriginalURIQualifiedPinsReleaseDocumentPagesAndAnnotations() throws {
        weak var document: PDFDocument?, page: PDFPage?, annotation: PDFAnnotation?
        var directory: URL?
        try autoreleasepool {
            let (workspace, source) = try fixture(opaqueURI: opaqueOriginalURI); directory = source.deletingLastPathComponent()
            document = workspace.document; page = workspace.document?.page(at: 0); annotation = page?.annotations.first
            XCTAssertTrue(PDFRemoteNavigationPreserver.hasOriginalActions(try XCTUnwrap(document)))
            workspace.close()
        }
        defer { if let directory { try? FileManager.default.removeItem(at: directory) } }
        XCTAssertNil(document); XCTAssertNil(page); XCTAssertNil(annotation)
    }

    func testOpaqueOriginalURIActionChainFailsClosedOnSaveAndImport() throws {
        let (workspace, source) = try fixture(actionExtra: "/Next << /S /Named /N /NextPage >>", opaqueURI: opaqueOriginalURI)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let before = try Data(contentsOf: source), document = try XCTUnwrap(workspace.document)
        try assertUnparsedURIAction(XCTUnwrap(document.page(at: 0)?.annotations.first))
        XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: document))
        XCTAssertFalse(workspace.saveSynchronously())
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertThrowsError(try PDFPageOperations.extract(from: document, indexes: [0]))
        let destination = PDFDocument(); let sentinel = PDFPage(); destination.insert(sentinel, at: 0)
        XCTAssertThrowsError(try PDFPageOperations.append(contentsOf: document, to: destination))
        XCTAssertEqual(destination.pageCount, 1); XCTAssertTrue(destination.page(at: 0) === sentinel)
    }

    func testValidOriginalURIDoesNotQualifyForOpaquePreservation() throws {
        let (workspace, source) = try fixture(opaqueURI: "https://example.com/valid-original")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        XCTAssertNotNil(document.page(at: 0)?.annotations.first?.action as? PDFActionURL)
        XCTAssertFalse(PDFRemoteNavigationPreserver.hasOriginalActions(document))
    }

    func testOrdinarySaveAsPreservesRawRemoteFileAndDestination() throws {
        let (workspace, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let output = source.deletingLastPathComponent().appendingPathComponent("saved.pdf")
        XCTAssertTrue(workspace.saveSynchronously(as: output), workspace.presentedError ?? "Save failed")
        try assertRemotePayload(output)
        XCTAssertNotNil(try Data(contentsOf: source).range(of: Data("/NewWindow true".utf8)))
    }

    func testBodySaveReopenReeditAndDetachedExtractionPreservePayload() throws {
        let (workspace, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try edit(workspace, text: "Updated body")
        let first = source.deletingLastPathComponent().appendingPathComponent("first.pdf")
        XCTAssertTrue(workspace.saveSynchronously(as: first), workspace.presentedError ?? "Save failed")
        try assertRemotePayload(first)
        let reopened = PDFWorkspaceState(); XCTAssertTrue(reopened.open(url: first)); reopened.setMode(.editing)
        try edit(reopened, text: "Another body")
        let second = source.deletingLastPathComponent().appendingPathComponent("second.pdf")
        XCTAssertTrue(reopened.saveSynchronously(as: second), reopened.presentedError ?? "Save failed")
        try assertRemotePayload(second)
        let extracted = try PDFPageOperations.extract(from: XCTUnwrap(reopened.document), indexes: [0, 1])
        let output = source.deletingLastPathComponent().appendingPathComponent("extracted.pdf")
        try AtomicPDFWriter.write(extracted, to: output)
        try assertRemotePayload(output)
    }

    func testChangedURLFailsWithoutOverwritingOriginalOrClearingDirtyState() throws {
        try assertChangedActionFails { $0.url = URL(fileURLWithPath: "/tmp/explicit-new-target.pdf") }
    }
    func testChangedRemotePageFailsWithoutOverwritingOriginalOrClearingDirtyState() throws {
        try assertChangedActionFails { $0.pageIndex += 1 }
    }
    func testChangedPointFailsWithoutOverwritingOriginalOrClearingDirtyState() throws {
        try assertChangedActionFails { $0.point = CGPoint(x: 19, y: 71) }
    }

    func testExplicitNewActionAtSamePublicCoordinatesDoesNotRestoreOldHiddenMode() throws {
        let (workspace, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try edit(workspace, text: "Updated body")
        let document = try XCTUnwrap(workspace.document), annotation = try XCTUnwrap(document.page(at: 1)?.annotations.first)
        let before = try XCTUnwrap(annotation.action as? PDFActionRemoteGoTo)
        let sameURL = try XCTUnwrap((before.perform(#selector(getter: PDFActionRemoteGoTo.url))?.takeUnretainedValue() as? NSURL).map { $0 as URL })
        annotation.action = PDFActionRemoteGoTo(pageIndex: before.pageIndex, at: before.point, fileURL: sameURL)
        let bytes = try Data(contentsOf: source)
        XCTAssertFalse(workspace.saveSynchronously())
        XCTAssertTrue(workspace.isDirty); XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: document))
    }

    func testExplicitRemovalSavesNormallyWithoutResurrectingRemoteAction() throws {
        let (workspace, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        document.page(at: 1)?.annotations.first?.action = nil
        let output = source.deletingLastPathComponent().appendingPathComponent("removed.pdf")
        XCTAssertTrue(workspace.saveSynchronously(as: output), workspace.presentedError ?? "Save failed")
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertNil(reopened.page(at: 1)?.annotations.first?.action)
        try assertRemotePayload(output, pages: [0])
    }

    func testMergeFromTrustedFreshLoadPreservesExternalPageNumbersAndRawFilespec() throws {
        let (workspace, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let destination = try XCTUnwrap(PDFDocument(url: source))
        destination.removePage(at: 1)
        let sentinel = try XCTUnwrap(destination.page(at: 0))
        for annotation in sentinel.annotations { sentinel.removeAnnotation(annotation) }
        XCTAssertEqual(try PDFPageOperations.append(contentsOf: XCTUnwrap(workspace.document), to: destination), 2)
        let output = source.deletingLastPathComponent().appendingPathComponent("merged.pdf")
        try AtomicPDFWriter.write(destination, to: output)
        try assertRemotePayload(output, pages: [1, 2])
    }

    func testQualifiedPagePinsReleaseDocumentPagesAndAnnotations() throws {
        weak var document: PDFDocument?, page: PDFPage?, annotation: PDFAnnotation?
        var directory: URL?
        try autoreleasepool {
            let (workspace, source) = try fixture(); directory = source.deletingLastPathComponent()
            document = workspace.document; page = workspace.document?.page(at: 1)
            annotation = page?.annotations.first
            XCTAssertTrue(PDFRemoteNavigationPreserver.hasOriginalActions(try XCTUnwrap(document)))
            workspace.close()
        }
        defer { if let directory { try? FileManager.default.removeItem(at: directory) } }
        XCTAssertNil(document); XCTAssertNil(page); XCTAssertNil(annotation)
    }

    func testUnsupportedActionChainDoesNotBlockViewingAndFailsClosedOnSave() throws {
        let (workspace, source) = try fixture(actionExtra: "/Next << /S /Named /N /NextPage >>")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        XCTAssertEqual(document.pageCount, 2)
        let bytes = try Data(contentsOf: source)
        XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: document))
        XCTAssertFalse(workspace.saveSynchronously())
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testMissingRemoteDestinationDoesNotBlockViewingAndFailsClosedOnSave() throws {
        let (workspace, source) = try fixture(includeDestination: false)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        XCTAssertEqual(workspace.document?.pageCount, 2)
        XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: XCTUnwrap(workspace.document)))
        XCTAssertFalse(workspace.saveSynchronously())
    }

    func testIncompleteMetadataScanDoesNotBlockViewingAndCannotMaterialize() throws {
        let (workspace, source) = try fixture(repeatedSecondPageAnnotations: 100_001)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(PDFCatalogStructurePreserver.needsMaterialization(document))
        XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: document)) {
            XCTAssertEqual($0 as? PDFPageStructurePreserver.Failure, .tooComplex)
        }
    }

    func testMissingDestinationRejectsExtractionAndAppendBeforeDestinationMutation() throws {
        let (workspace, source) = try fixture(includeDestination: false)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document), original = try Data(contentsOf: source)
        XCTAssertThrowsError(try PDFPageOperations.extract(from: document, indexes: [0]))
        let target = PDFDocument(), sentinel = PDFPage(); target.insert(sentinel, at: 0)
        XCTAssertThrowsError(try PDFPageOperations.append(contentsOf: document, to: target))
        XCTAssertEqual(target.pageCount, 1); XCTAssertTrue(target.page(at: 0) === sentinel)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testUnsupportedActionRemainsRejectedAfterItsBodyPageIsReplaced() throws {
        let (workspace, source) = try fixture(includeDestination: false)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document), oldPage = try XCTUnwrap(document.page(at: 0))
        let original = try Data(contentsOf: source)
        // Remove the other page, so only the replaced page can carry rejection.
        document.removePage(at: 1)
        try edit(workspace, text: "Updated body")
        XCTAssertFalse(document.page(at: 0) === oldPage)
        XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: document))
        XCTAssertFalse(workspace.saveSynchronously()); XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testMixedSupportedAndUnparsedMalformedRemoteActionsFailClosed() throws {
        let (_, source) = try fixture(mixedUnsupported: true)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        let annotations = try XCTUnwrap(document.page(at: 1)).annotations
        XCTAssertEqual(annotations.count, 2)
        // Model PDFKit refusing to parse one malformed action while parsing the
        // valid sibling. The immutable native dictionaries remain unchanged.
        annotations[1].action = nil
        PDFRemoteNavigationPreserver.captureOriginalActions(in: document)
        XCTAssertNotNil(annotations[0].action as? PDFActionRemoteGoTo)
        XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: document))
        XCTAssertThrowsError(try PDFPageOperations.extract(from: document, indexes: [1]))
        let target = PDFDocument(); target.insert(PDFPage(), at: 0)
        XCTAssertThrowsError(try PDFPageOperations.append(contentsOf: document, to: target))
        XCTAssertEqual(target.pageCount, 1)
    }

    func testIncompleteScanCannotBeImportedAsAnApparentlySafeDocument() throws {
        let (workspace, source) = try fixture(repeatedSecondPageAnnotations: 100_001)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        XCTAssertThrowsError(try PDFPageOperations.extract(from: XCTUnwrap(workspace.document), indexes: [0])) {
            XCTAssertEqual($0 as? PDFPageStructurePreserver.Failure, .tooComplex)
        }
    }

    private func assertChangedActionFails(_ mutate: (PDFActionRemoteGoTo) -> Void) throws {
        let (workspace, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try edit(workspace, text: "Updated body")
        let document = try XCTUnwrap(workspace.document)
        let action = try XCTUnwrap(document.page(at: 1)?.annotations.first?.action as? PDFActionRemoteGoTo)
        mutate(action)
        // Capture is idempotent even when invoked again after authoring.
        PDFRemoteNavigationPreserver.captureOriginalActions(in: document)
        let bytes = try Data(contentsOf: source)
        XCTAssertFalse(workspace.saveSynchronously())
        XCTAssertTrue(workspace.isDirty)
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: document))
    }

    private func edit(_ workspace: PDFWorkspaceState, text: String) throws {
        XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.commitPendingInlineText(id: draft.id, text: text, style: draft.style, bounds: draft.bounds)
        XCTAssertNil(workspace.presentedError); XCTAssertNil(workspace.pendingInlineTextEdit)
    }

    private func assertRemotePayload(_ url: URL, pages: [Int] = [0, 1]) throws {
        let document = try XCTUnwrap(PDFDocument(url: url)), native = try XCTUnwrap(document.documentRef)
        for index in pages {
            let page = try XCTUnwrap(native.page(at: index + 1)?.dictionary)
            let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
            var annotation: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &annotation))
            let action = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(try XCTUnwrap(annotation), "A"))
            let file = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(action, "F"))
            var path: CGPDFStringRef?, unicode: CGPDFStringRef?, window: CGPDFBoolean = 0
            XCTAssertTrue(CGPDFDictionaryGetString(file, "F", &path))
            XCTAssertTrue(CGPDFDictionaryGetString(file, "UF", &unicode))
            func bytes(_ value: CGPDFStringRef?) throws -> Data {
                let value = try XCTUnwrap(value)
                return Data(bytes: try XCTUnwrap(CGPDFStringGetBytePtr(value)), count: CGPDFStringGetLength(value))
            }
            XCTAssertEqual(try bytes(path), Data([0x72, 0x65, 0x6D, 0x6F, 0x74, 0x65, 0xB0, 0xC5, 0x2E, 0x70, 0x64, 0x66]))
            XCTAssertEqual(try bytes(unicode), Data([0xFE, 0xFF, 0x00, 0x72, 0x00, 0x65, 0x00, 0x6D, 0x00, 0x6F, 0x00, 0x74, 0x00, 0x65, 0x00, 0x2E, 0x00, 0x70, 0x00, 0x64, 0x00, 0x66]))
            XCTAssertTrue(CGPDFDictionaryGetBoolean(action, "NewWindow", &window)); XCTAssertNotEqual(window, 0)
            let destination = try XCTUnwrap(PDFCatalogStructurePreserver.array(action, "D"))
            var target: CGPDFInteger = 0, mode: UnsafePointer<CChar>?, top: CGPDFReal = 0, zoom: CGPDFReal = 0
            XCTAssertEqual(CGPDFArrayGetCount(destination), 5)
            XCTAssertTrue(CGPDFArrayGetInteger(destination, 0, &target)); XCTAssertEqual(target, 12)
            XCTAssertTrue(CGPDFArrayGetName(destination, 1, &mode)); XCTAssertEqual(String(cString: try XCTUnwrap(mode)), "XYZ")
            var left: CGPDFObjectRef?
            XCTAssertTrue(CGPDFArrayGetObject(destination, 2, &left)); XCTAssertEqual(CGPDFObjectGetType(try XCTUnwrap(left)), .null)
            XCTAssertTrue(CGPDFArrayGetNumber(destination, 3, &top)); XCTAssertEqual(top, 88)
            XCTAssertTrue(CGPDFArrayGetNumber(destination, 4, &zoom)); XCTAssertEqual(zoom, 1.5)
        }
    }

    private func assertOpaqueURIPayload(_ url: URL, pages: [Int] = [0, 1]) throws {
        let native = try XCTUnwrap(CGPDFDocument(url as CFURL))
        for index in pages {
            let page = try XCTUnwrap(native.page(at: index + 1)?.dictionary)
            let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
            var annotation: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &annotation))
            let action = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(try XCTUnwrap(annotation), "A"))
            var uri: CGPDFStringRef?, kind: UnsafePointer<CChar>?, isMap: CGPDFBoolean = 0
            XCTAssertTrue(CGPDFDictionaryGetName(action, "S", &kind))
            XCTAssertEqual(String(cString: try XCTUnwrap(kind)), "URI")
            XCTAssertTrue(CGPDFDictionaryGetString(action, "URI", &uri))
            let value = try XCTUnwrap(uri)
            XCTAssertEqual(Data(bytes: try XCTUnwrap(CGPDFStringGetBytePtr(value)), count: CGPDFStringGetLength(value)), Data(opaqueOriginalURI.utf8))
            XCTAssertTrue(CGPDFDictionaryGetBoolean(action, "IsMap", &isMap)); XCTAssertNotEqual(isMap, 0)
        }
    }

    private func assertUnparsedURIAction(_ annotation: PDFAnnotation) throws {
        if let action = annotation.action {
            let urlAction = try XCTUnwrap(action as? PDFActionURL)
            XCTAssertNil(urlAction.perform(#selector(getter: PDFActionURL.url))?.takeUnretainedValue() as? NSURL)
        }
    }

    private func assertNoOriginalOpaqueURI(_ url: URL, page: Int) throws {
        let native = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let dictionary = try XCTUnwrap(native.page(at: page + 1)?.dictionary)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "Annots"))
        var annotation: CGPDFDictionaryRef?, string: CGPDFStringRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &annotation))
        if let action = PDFCatalogStructurePreserver.dictionary(try XCTUnwrap(annotation), "A"),
           CGPDFDictionaryGetString(action, "URI", &string), let string {
            XCTAssertNotEqual(Data(bytes: try XCTUnwrap(CGPDFStringGetBytePtr(string)), count: CGPDFStringGetLength(string)), Data(opaqueOriginalURI.utf8))
        }
    }

    private func fixture(actionExtra: String = "", includeDestination: Bool = true, repeatedSecondPageAnnotations: Int = 1, mixedUnsupported: Bool = false, opaqueURI: String? = nil, localGoTo: Bool = false) throws -> (PDFWorkspaceState, URL) {
        let content = "BT /F1 20 Tf 40 300 Td (Original body) Tj ET"
        let action = localGoTo ? "<< /Type /Action /S /GoTo /D [4 0 R /FitH 300] \(actionExtra) >>" : opaqueURI.map { "<< /Type /Action /S /URI /URI (\($0)) /IsMap true \(actionExtra) >>" }
            ?? "<< /S /GoToR /F << /Type /Filespec /F <72656D6F7465B0C52E706466> /UF <FEFF00720065006D006F00740065002E007000640066> >> \(includeDestination ? "/D [12 /XYZ null 88 1.5]" : "") /NewWindow true \(actionExtra) >>"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 420] /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R /Annots [7 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 420] /Resources << >> /Annots [\(Array(repeating: "8 0 R", count: repeatedSecondPageAnnotations).joined(separator: " ")) \(mixedUnsupported ? "10 0 R" : "")] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Annot /Subtype /Link /Rect [10 20 90 40] /A 9 0 R >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 20 90 40] /A 9 0 R >>",
            action
        ]
        if mixedUnsupported {
            objects.append("<< /Type /Annot /Subtype /Link /Rect [100 20 180 40] /A 11 0 R >>")
            objects.append("<< /S /GoToR /F (remote.pdf) >>")
        }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-remote-actions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("original.pdf"); try data.write(to: source)
        let workspace = PDFWorkspaceState(); XCTAssertTrue(workspace.open(url: source)); workspace.setMode(.editing)
        return (workspace, source)
    }
}
