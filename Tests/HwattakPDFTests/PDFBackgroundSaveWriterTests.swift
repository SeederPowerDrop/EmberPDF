// SPDX-License-Identifier: MPL-2.0
import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBackgroundSaveWriterTests: XCTestCase {
    private let invalidURI = "http://www.python<2010>scraping.com/pages/page3.html"
    private let views = ["/Fit", "/FitH 300", "/FitV 21", "/FitR 10 20 80 90",
                         "/FitB", "/FitBH null", "/FitBV 35.5", "/XYZ null 288 1.5"]

    func testWorkerUsesDetachedGraphAndKeepsRemoteURIBookmarkViewsAfterSourceMutation() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        PDFRemoteNavigationPreserver.captureOriginalActions(in: document)
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let first = try XCTUnwrap(document.page(at: 0))
        first.annotations.forEach(first.removeAnnotation)
        document.outlineRoot = nil; document.removePage(at: 1)
        let output = source.deletingLastPathComponent().appendingPathComponent("detached.pdf")
        let request = try PDFBackgroundSaveRequest(destinationURL: output, originalURL: source, overwritingOriginal: false)
        let result = try await PDFBackgroundSaveWriter.write(snapshot: snapshot, request: request,
            cancellation: PDFSaveCancellation(), beforeWriting: { XCTAssertFalse(Thread.isMainThread) })
        XCTAssertEqual(result.url, output)
        try assertNavigation(output)
        XCTAssertEqual(document.pageCount, 1); XCTAssertTrue(first.annotations.isEmpty)
    }

    func testDetachedWorkerPreservesNativeBodyContentsAndReeditingAgainstSynchronousSave() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let workspace = PDFWorkspaceState()
        defer { workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: source)); workspace.setMode(.editing)
        XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.commitPendingInlineText(id: draft.id, text: "Updated body", style: draft.style, bounds: draft.bounds)
        let document = try XCTUnwrap(workspace.document)
        let content = try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(document.page(at: 0)))
        let marker = PDFBodyTextPageSnapshot.requiresPageContentPreservation(document)
        let inspected = try PDFRecoverySnapshot(capturing: document).takeDocument()
        XCTAssertEqual(PDFBodyTextPageSnapshot.requiresPageContentPreservation(inspected), marker)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(inspected.page(at: 0))), content)
        let baseline = source.deletingLastPathComponent().appendingPathComponent("synchronous-body.pdf")
        try AtomicPDFWriter.write(document, to: baseline)
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let output = source.deletingLastPathComponent().appendingPathComponent("body.pdf")
        let request = try PDFBackgroundSaveRequest(destinationURL: output, originalURL: source, overwritingOriginal: false)
        _ = try await PDFBackgroundSaveWriter.write(snapshot: snapshot, request: request, cancellation: PDFSaveCancellation())
        let saved = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertTrue(saved.page(at: 0)?.string?.contains("Updated body") == true)
        XCTAssertEqual(PDFBodyTextPageSnapshot.requiresPageContentPreservation(saved), marker)
        let synchronous = try XCTUnwrap(PDFDocument(url: baseline))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(saved.page(at: 0))), content)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(synchronous.page(at: 0))), content)
        let reopened = PDFWorkspaceState()
        defer { reopened.closeDiscardingChanges() }
        XCTAssertTrue(reopened.open(url: output)); reopened.setMode(.editing)
        XCTAssertTrue(reopened.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        XCTAssertEqual(reopened.pendingInlineTextEdit?.text, "Updated body")
        try assertNavigation(output)
    }

    func testMarkedBodyPageRetainsMarkerAndExactContentsOnWorker() async throws {
        let source = try fixture(preservePageContent: true)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        PDFRemoteNavigationPreserver.captureOriginalActions(in: document)
        XCTAssertTrue(PDFBodyTextPageSnapshot.requiresPageContentPreservation(document))
        let content = try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(document.page(at: 0)))
        let inspected = try PDFRecoverySnapshot(capturing: document).takeDocument()
        XCTAssertTrue(PDFBodyTextPageSnapshot.requiresPageContentPreservation(inspected))
        let output = source.deletingLastPathComponent().appendingPathComponent("marked-body.pdf")
        _ = try await PDFBackgroundSaveWriter.write(snapshot: PDFRecoverySnapshot(capturing: document),
            request: PDFBackgroundSaveRequest(destinationURL: output, originalURL: source, overwritingOriginal: false),
            cancellation: PDFSaveCancellation())
        let saved = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertTrue(PDFBodyTextPageSnapshot.requiresPageContentPreservation(saved))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(saved.page(at: 0))), content)
        try assertNavigation(output)
    }

    func testAllLocalAnnotationViewModesAndOperandsSurvivePlainSnapshotWithoutCatalogFeatures() async throws {
        for view in views {
            let source = try fixture(localView: view, plainLocal: true)
            defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
            let document = try XCTUnwrap(PDFDocument(url: source))
            XCTAssertNil(document.outlineRoot)
            let snapshot = try PDFRecoverySnapshot(capturing: document)
            document.removePage(at: 1)
            let output = source.deletingLastPathComponent().appendingPathComponent("local.pdf")
            _ = try await PDFBackgroundSaveWriter.write(snapshot: snapshot,
                request: PDFBackgroundSaveRequest(destinationURL: output, originalURL: source, overwritingOriginal: false),
                cancellation: PDFSaveCancellation())
            let native = try XCTUnwrap(CGPDFDocument(output as CFURL))
            let annotations = try XCTUnwrap(PDFCatalogStructurePreserver.array(XCTUnwrap(native.page(at: 1)?.dictionary), "Annots"))
            var annotation: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(annotations, 0, &annotation))
            let action = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(XCTUnwrap(annotation), "A"))
            try assertDestination(XCTUnwrap(PDFCatalogStructurePreserver.array(action, "D")), view: view,
                                  target: XCTUnwrap(native.page(at: 2)?.dictionary))
        }
    }

    func testExplicitSamePointLocalDestinationReplacementWinsAfterSnapshotCapture() throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        PDFRemoteNavigationPreserver.captureOriginalActions(in: document)
        let detached = try PDFRecoverySnapshot(capturing: document).takeDocument()
        let annotation = try XCTUnwrap(detached.page(at: 0)?.annotations.last)
        let previous = try XCTUnwrap((annotation.action as? PDFActionGoTo)?.destination)
        let replacement = PDFDestination(page: try XCTUnwrap(detached.page(at: 1)), at: previous.point)
        replacement.zoom = previous.zoom
        annotation.action = PDFActionGoTo(destination: replacement)
        let output = source.deletingLastPathComponent().appendingPathComponent("replaced-local.pdf")
        try AtomicPDFWriter.write(detached, to: output)
        try assertNavigation(output, localView: "/XYZ null null null")
    }

    func testPlainNativeImagePaintingAndFractionalGeometrySurviveBackgroundSave() async throws {
        let source = try imageFixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        let original = try XCTUnwrap(document.page(at: 0))
        XCTAssertFalse(PDFCatalogStructurePreserver.shouldPreserve(document))
        let content = try PDFBodyTextPageSnapshot.contentData(for: original)
        let expectedPixels = try pixels(original)
        let boxes = allBoxes(original)
        XCTAssertEqual(boxes[0].maxY, 3071.9999999999995)
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        // A snapshot's provenance must not opt the live document into a new
        // catalog-save policy merely because the copy needs native painting.
        XCTAssertFalse(PDFCatalogStructurePreserver.needsMaterialization(document))
        original.rotation = 180
        let output = source.deletingLastPathComponent().appendingPathComponent("native-image.pdf")
        _ = try await PDFBackgroundSaveWriter.write(snapshot: snapshot,
            request: PDFBackgroundSaveRequest(destinationURL: output, originalURL: source, overwritingOriginal: false),
            cancellation: PDFSaveCancellation())
        let page = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
        XCTAssertEqual(page.rotation, 270)
        XCTAssertEqual(allBoxes(page), boxes)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: page), content)
        XCTAssertEqual(try pixels(page), expectedPixels)
        var unit: CGPDFReal = 0
        XCTAssertTrue(CGPDFDictionaryGetNumber(try XCTUnwrap(page.pageRef?.dictionary), "UserUnit", &unit))
        XCTAssertEqual(unit, 1.25)
    }

    func testSnapshotUsesCurrentIntentionalPageBoxesAndRotation() async throws {
        let source = try imageFixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(PDFDocument(url: source)), original = try XCTUnwrap(document.page(at: 0))
        original.setBounds(CGRect(x: -10.125, y: 15.25, width: 2250.75, height: 3000.125), for: .cropBox)
        original.setBounds(CGRect(x: -8.5, y: 18.875, width: 2240.125, height: 2990.5), for: .trimBox)
        original.rotation = 90
        let boxes = allBoxes(original), content = try PDFBodyTextPageSnapshot.contentData(for: original)
        let expectedPixels = try pixels(original)
        let output = source.deletingLastPathComponent().appendingPathComponent("current-boxes.pdf")
        _ = try await PDFBackgroundSaveWriter.write(snapshot: PDFRecoverySnapshot(capturing: document),
            request: PDFBackgroundSaveRequest(destinationURL: output, originalURL: source, overwritingOriginal: false),
            cancellation: PDFSaveCancellation())
        let page = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
        XCTAssertEqual(page.rotation, 90)
        XCTAssertEqual(allBoxes(page), boxes)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: page), content)
        XCTAssertEqual(try pixels(page), expectedPixels)
    }

    func testForcedSnapshotNativePaintingKeepsCurrentCanonicalWidgetValues() async throws {
        let source = try nativeFixture(objects: [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /NeedAppearances true /DR << /Font << /Helv 5 0 R >> >> /DA (/Helv 12 Tf 0 g) >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << >> /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (student) /V (Ada) /DA (/Helv 12 Tf 0 g) /Rect [20 30 180 60] /P 3 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try PDFSourceFileAccess.loadDocument(at: source).document
        let widget = try XCTUnwrap(document.page(at: 0)?.annotations.first)
        widget.widgetStringValue = "Updated value"
        let output = source.deletingLastPathComponent().appendingPathComponent("current-form.pdf")
        _ = try await PDFBackgroundSaveWriter.write(snapshot: PDFRecoverySnapshot(capturing: document),
            request: PDFBackgroundSaveRequest(destinationURL: output, originalURL: source, overwritingOriginal: false),
            cancellation: PDFSaveCancellation())
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.widgetStringValue, "Updated value")
        let native = try XCTUnwrap(CGPDFDocument(output as CFURL))
        let form = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(XCTUnwrap(native.catalog), "AcroForm"))
        let fields = try XCTUnwrap(PDFCatalogStructurePreserver.array(form, "Fields"))
        let annotations = try XCTUnwrap(PDFCatalogStructurePreserver.array(XCTUnwrap(native.page(at: 1)?.dictionary), "Annots"))
        var field: CGPDFDictionaryRef?, annotation: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(fields, 0, &field))
        XCTAssertTrue(CGPDFArrayGetDictionary(annotations, 0, &annotation))
        XCTAssertEqual(pdfReferenceIdentity(try XCTUnwrap(field)), pdfReferenceIdentity(try XCTUnwrap(annotation)))
    }

    func testCatalogNativeUnitRepairRequiresCoherentAnnotationFreePainting() throws {
        let source = try unitFixture(unit: "1.25", annotations: false)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try PDFSourceFileAccess.loadDocument(at: source).document
        let page = try XCTUnwrap(document.page(at: 0)), sourcePixels = try pixels(page)
        let snapshot = try PDFRecoverySnapshot(capturing: document).takeDocument()
        let plan = try PDFCatalogStructurePreserver.plan(for: snapshot)
        XCTAssertNotNil(plan.paintingSources[0]); XCTAssertNotNil(plan.pageGeometry[0])
        let stage = try unitFixture(unit: nil, annotations: false)
        defer { try? FileManager.default.removeItem(at: stage.deletingLastPathComponent()) }
        let repaired = try PDFBodyTextPageSnapshot.preservingCatalog(in: Data(contentsOf: stage), from: snapshot, plan: plan)
        let reopened = try XCTUnwrap(PDFDocument(data: repaired)), repairedPage = try XCTUnwrap(reopened.page(at: 0))
        var unit: CGPDFReal = 0
        XCTAssertTrue(CGPDFDictionaryGetNumber(try XCTUnwrap(repairedPage.pageRef?.dictionary), "UserUnit", &unit))
        XCTAssertEqual(unit, 1.25); XCTAssertEqual(try pixels(repairedPage), sourcePixels)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: repairedPage), try PDFBodyTextPageSnapshot.contentData(for: page))

        // A different explicit scale is not an SDK omission and cannot borrow
        // this permission merely because a native painting exists.
        let explicit = try unitFixture(unit: "2", annotations: false)
        defer { try? FileManager.default.removeItem(at: explicit.deletingLastPathComponent()) }
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.preservingCatalog(in: Data(contentsOf: explicit), from: snapshot, plan: plan))
        let rotated = try unitFixture(unit: nil, annotations: false, rotation: 90)
        defer { try? FileManager.default.removeItem(at: rotated.deletingLastPathComponent()) }
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.preservingCatalog(in: Data(contentsOf: rotated), from: snapshot, plan: plan))
        let extraAnnotation = try unitFixture(unit: nil, annotations: true)
        defer { try? FileManager.default.removeItem(at: extraAnnotation.deletingLastPathComponent()) }
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.preservingCatalog(in: Data(contentsOf: extraAnnotation), from: snapshot, plan: plan))
    }

    func testCatalogNativeUnitRepairRejectsAnnotatedAndInvalidUnitPrograms() throws {
        for hasAnnotation in [false, true] {
            let source = try unitFixture(unit: "1.25", annotations: hasAnnotation)
            defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
            let document = try PDFSourceFileAccess.loadDocument(at: source).document
            let snapshot = try PDFRecoverySnapshot(capturing: document).takeDocument()
            let plan = try PDFCatalogStructurePreserver.plan(for: snapshot)
            let tokens: [String?] = hasAnnotation ? [nil, "0", "-1", "/BadUnit", "[1]"] : ["0", "-1", "/BadUnit", "[1]"]
            for token in tokens {
                let stage = try unitFixture(unit: token, annotations: hasAnnotation)
                defer { try? FileManager.default.removeItem(at: stage.deletingLastPathComponent()) }
                XCTAssertThrowsError(try PDFBodyTextPageSnapshot.preservingCatalog(in: Data(contentsOf: stage), from: snapshot, plan: plan))
            }
        }
    }

    func testUnknownWidgetDefaultBaselineRefusesBackgroundSaveWithoutOutput() async throws {
        let source = try nativeFixture(objects: [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /NeedAppearances true /DR << /Font << /Helv 5 0 R >> >> /DA (/Helv 12 Tf 0 g) >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << >> /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (student) /V (Ada) /DA (/Helv 12 Tf 0 g) /Rect [20 30 180 60] /P 3 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let before = try Data(contentsOf: source), document = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertNil(PDFRawStreamProvenance.source(for: document))
        let widget = try XCTUnwrap(document.page(at: 0)?.annotations.first)
        widget.widgetStringValue = "Updated value"
        let output = source.deletingLastPathComponent().appendingPathComponent("unknown-default.pdf")
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        do {
            _ = try await PDFBackgroundSaveWriter.write(snapshot: snapshot,
                request: PDFBackgroundSaveRequest(destinationURL: output, originalURL: source, overwritingOriginal: false),
                cancellation: PDFSaveCancellation())
            XCTFail("An unknown source cannot infer absent default intent from PDFKit's fallback string.")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try Data(contentsOf: source), before)
            XCTAssertEqual(widget.widgetStringValue, "Updated value")
        }
    }

    func testCancelledBeforeWorkerLeavesOriginalAndDestinationUntouched() async throws {
        let source = try fixture(), original = try Data(contentsOf: source)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let snapshot = try PDFRecoverySnapshot(capturing: XCTUnwrap(PDFDocument(url: source)))
        let output = source.deletingLastPathComponent().appendingPathComponent("cancelled.pdf")
        let request = try PDFBackgroundSaveRequest(destinationURL: output, originalURL: source, overwritingOriginal: false)
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        do {
            _ = try await PDFBackgroundSaveWriter.write(snapshot: snapshot, request: request, cancellation: cancellation)
            XCTFail("Cancelled staging must not commit.")
        } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testRequestTimeCopyDestinationConflictIsNotRebasedAtWorkerStart() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let bytes = try Data(contentsOf: source)
        let output = source.deletingLastPathComponent().appendingPathComponent("external.pdf")
        let request = try PDFBackgroundSaveRequest(destinationURL: output, originalURL: source, overwritingOriginal: false)
        let snapshot = try PDFRecoverySnapshot(capturing: XCTUnwrap(PDFDocument(url: source)))
        let external = bytes + Data("\n% external-arrival".utf8)
        do {
            _ = try await PDFBackgroundSaveWriter.write(snapshot: snapshot, request: request,
                cancellation: PDFSaveCancellation(), beforeWriting: { try external.write(to: output) })
            XCTFail("A file arriving after request capture must be retained.")
        } catch let error as WorkspaceError {
            guard case .externalModification = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: output), external)
    }

    func testQueuedOverwriteRejectsChangedOriginalVersion() async throws {
        let source = try fixture(), bytes = try Data(contentsOf: source)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let request = try PDFBackgroundSaveRequest(destinationURL: source, originalURL: source,
            expectedSourceVersion: PDFSourceFileVersion.capture(at: source), overwritingOriginal: true)
        let snapshot = try PDFRecoverySnapshot(capturing: XCTUnwrap(PDFDocument(url: source)))
        let external = bytes + Data("\n% external-edit".utf8)
        do {
            _ = try await PDFBackgroundSaveWriter.write(snapshot: snapshot, request: request,
                cancellation: PDFSaveCancellation(), beforeWriting: { try external.write(to: source) })
            XCTFail("The original changed after snapshot capture.")
        } catch let error as WorkspaceError {
            guard case .externalModification = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: source), external)
    }

    func testCancellationAfterFlushCannotReachDirectOverwriteFallback() throws {
        let source = try fixture(), bytes = try Data(contentsOf: source)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let cancellation = PDFSaveCancellation()
        let document = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertThrowsError(try AtomicPDFWriter.write(document, to: source,
            onDirectWriteFallback: { XCTFail("Cancellation must never truncate the source.") },
            synchronizeStagedFile: { _ in cancellation.cancel() }, checkCancellation: cancellation.check)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let temporary = try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(temporary.isEmpty)
    }

    func testCancellationContextRestoresPreviousTokenAfterThrowingNestedScope() throws {
        let outer = PDFSaveCancellation(), inner = PDFSaveCancellation(); inner.cancel()
        try PDFSaveCancellation.withCurrent(outer) {
            XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(inner) { try PDFSaveCancellation.checkCurrent() })
            try PDFSaveCancellation.checkCurrent()
        }
        XCTAssertNoThrow(try PDFSaveCancellation.checkCurrent())
    }

    func testRequestRejectsCopyAliasAndImageSourceWithoutWriting() throws {
        let source = try fixture(), bytes = try Data(contentsOf: source)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        XCTAssertThrowsError(try PDFBackgroundSaveRequest(destinationURL: source, originalURL: source, overwritingOriginal: false))
        XCTAssertThrowsError(try PDFBackgroundSaveRequest(destinationURL: source, originalURL: nil,
            imageSourceURL: source, overwritingOriginal: false))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    private func assertNavigation(_ url: URL, localView: String = "/FitH 300") throws {
        let native = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(native.numberOfPages, 2)
        let page = try XCTUnwrap(native.page(at: 1)?.dictionary)
        let annotations = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
        XCTAssertEqual(CGPDFArrayGetCount(annotations), 3)
        func action(_ index: Int) throws -> CGPDFDictionaryRef {
            var annotation: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(annotations, index, &annotation))
            return try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(try XCTUnwrap(annotation), "A"))
        }
        let remote = try action(0)
        XCTAssertNotNil(PDFCatalogStructurePreserver.object(remote, "F"))
        let destination = try XCTUnwrap(PDFCatalogStructurePreserver.array(remote, "D"))
        var index: CGPDFInteger = -1
        XCTAssertTrue(CGPDFArrayGetInteger(destination, 0, &index)); XCTAssertEqual(index, 12)
        var uri: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetString(try action(1), "URI", &uri))
        let string = try XCTUnwrap(uri)
        XCTAssertEqual(Data(bytes: try XCTUnwrap(CGPDFStringGetBytePtr(string)), count: CGPDFStringGetLength(string)), Data(invalidURI.utf8))
        let local = try XCTUnwrap(PDFCatalogStructurePreserver.array(try action(2), "D"))
        try assertDestination(local, view: localView, target: XCTUnwrap(native.page(at: 2)?.dictionary))
        let outlines = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(try XCTUnwrap(native.catalog), "Outlines"))
        var child = PDFCatalogStructurePreserver.dictionary(outlines, "First")
        for view in views {
            let node = try XCTUnwrap(child)
            let value = try XCTUnwrap(PDFCatalogStructurePreserver.array(node, "Dest")
                ?? PDFCatalogStructurePreserver.dictionary(node, "A").flatMap { PDFCatalogStructurePreserver.array($0, "D") })
            try assertDestination(value, view: view, target: XCTUnwrap(native.page(at: 2)?.dictionary))
            child = PDFCatalogStructurePreserver.dictionary(node, "Next")
        }
        XCTAssertNil(child)
    }

    private func assertDestination(_ value: CGPDFArrayRef, view: String, target: CGPDFDictionaryRef) throws {
        var page: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(value, 0, &page))
        XCTAssertEqual(pdfReferenceIdentity(try XCTUnwrap(page)), pdfReferenceIdentity(target))
        let tokens = view.split(separator: " ")
        XCTAssertEqual(CGPDFArrayGetCount(value), tokens.count + 1)
        var mode: UnsafePointer<CChar>?
        XCTAssertTrue(CGPDFArrayGetName(value, 1, &mode))
        XCTAssertEqual("/" + String(cString: try XCTUnwrap(mode)), String(tokens[0]))
        for (offset, token) in tokens.dropFirst().enumerated() {
            if token == "null" {
                var operand: CGPDFObjectRef?
                XCTAssertTrue(CGPDFArrayGetObject(value, offset + 2, &operand))
                XCTAssertEqual(CGPDFObjectGetType(try XCTUnwrap(operand)), .null)
            } else {
                var operand: CGPDFReal = 0
                XCTAssertTrue(CGPDFArrayGetNumber(value, offset + 2, &operand))
                XCTAssertEqual(Double(operand), try XCTUnwrap(Double(token)), accuracy: 0.0001)
            }
        }
    }

    private func allBoxes(_ page: PDFPage) -> [CGRect] {
        [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox].map { page.bounds(for: $0) }
    }

    private func pixels(_ page: PDFPage) throws -> Data {
        let reference = try XCTUnwrap(page.pageRef), crop = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        let width = rotation == 90 || rotation == 270 ? crop.height : crop.width
        let height = rotation == 90 || rotation == 270 ? crop.width : crop.height
        let scale = min(128 / width, 128 / height)
        var data = Data(count: 128 * 128 * 4)
        try data.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 128, height: 128,
                bitsPerComponent: 8, bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            // Apply the current live geometry explicitly. A native pageRef
            // may still carry the original boxes/rotation after user edits.
            context.translateBy(x: 64, y: 64)
            context.scaleBy(x: scale, y: scale)
            context.rotate(by: -CGFloat(rotation) * .pi / 180)
            context.translateBy(x: -crop.midX, y: -crop.midY)
            context.clip(to: crop)
            context.drawPDFPage(reference)
        }
        return data
    }

    private func unitFixture(unit: String?, annotations: Bool, rotation: Int = 0) throws -> URL {
        let content = "0.25 0.5 0.75 rg 10 20 100 80 re f"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Rotate \(rotation) \(unit.map { "/UserUnit " + $0 } ?? "") /Resources << >> /Contents 4 0 R \(annotations ? "/Annots [5 0 R]" : "") >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ]
        if annotations { objects.append("<< /Type /Annot /Subtype /Square /Rect [20 30 80 90] /C [1 0 0] /Contents (unit control) >>") }
        return try nativeFixture(objects: objects)
    }

    private func imageFixture() throws -> URL {
        let content = "0.5670000000000001 w\n0 G\nq\n2304. 0 0 3071.9999999999995453 0. 0. cm\n/I0 Do\nQ"
        let image = "FF000000FF000000FFFFFFFF>"
        return try nativeFixture(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [-18.125 7.75 2304 3071.9999999999995] /CropBox [-15.875 9.250000000000002 2290.25 3060.125] /BleedBox [-17.000000000000004 8.75 2300.875 3069.5] /TrimBox [-14.500000000000002 10.25 2289.125 3058.75] /ArtBox [1.1250000000000002 20.875 2240.5 3001.625] /Rotate 270 /UserUnit 1.25 /Resources << /XObject << /I0 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length \(image.utf8.count) >>\nstream\n\(image)\nendstream"
        ])
    }

    private func nativeFixture(objects: [String]) throws -> URL {
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-native-snapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.pdf"); try data.write(to: source)
        return source
    }

    private func fixture(localView: String = "/FitH 300", plainLocal: Bool = false,
                         preservePageContent: Bool = false) throws -> URL {
        let content = "BT /F1 20 Tf 40 300 Td (Original body) Tj ET"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R \(plainLocal ? "" : "/Outlines 10 0 R") >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 420] /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R /Annots [\(plainLocal ? "9 0 R" : "7 0 R 8 0 R 9 0 R")] \(preservePageContent ? "/EmberPDFPreservePageContent true" : "") >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 420] /Resources << >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Annot /Subtype /Link /Rect [10 20 90 40] /A << /S /GoToR /F (remote.pdf) /D [12 /XYZ null 88 1.5] /NewWindow true >> >>",
            "<< /Type /Annot /Subtype /Link /Rect [100 20 180 40] /A << /S /URI /URI (\(invalidURI)) >> >>",
            "<< /Type /Annot /Subtype /Link /Rect [190 20 270 40] /A << /S /GoTo /D [4 0 R \(localView)] >> >>",
            "<< /Type /Outlines /First 11 0 R /Last 18 0 R /Count 8 >>"
        ]
        for (index, view) in views.enumerated() {
            objects.append("<< /Title (view\(index)) /Parent 10 0 R \(index == 0 ? "" : "/Prev \(10 + index) 0 R") \(index == 7 ? "" : "/Next \(12 + index) 0 R") /Dest [4 0 R \(view)] >>")
        }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-background-save-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.pdf"); try data.write(to: source)
        return source
    }
}
