// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class OCRPageScopeWorkspaceTests: XCTestCase {
    func testCurrentPageProgressUsesSelectedCountAndOriginalPageNumber() async throws {
        let fixture = try makeFixture()
        let workspace = fixture.workspace
        workspace.currentPageIndex = 2
        var configuration = OCRConfiguration()
        configuration.pageIndexes = [2]

        workspace.startOCR(configuration: configuration)

        XCTAssertEqual(workspace.ocrState, .running(completed: 0, total: 1, page: 3))
        try await waitUntil { workspace.canUseCompletedOCRResult }
        XCTAssertEqual(workspace.ocrCheckpoint?.pageCount, 4)
        XCTAssertEqual(Set(workspace.ocrCheckpoint?.pages.keys.map { $0 } ?? []), [2])
        XCTAssertEqual(workspace.ocrState, .finished(recognizedPages: 1, skippedPages: 0))
    }

    func testPartialApplyPreservesOtherPageObjectsAnnotationsOutlineAndUndo() async throws {
        let fixture = try makeFixture()
        let workspace = fixture.workspace
        let document = try XCTUnwrap(workspace.document)
        let before = (0..<4).map { document.page(at: $0)! }
        let note = try XCTUnwrap(before[0].annotations.first)
        let link = try XCTUnwrap(before[0].annotations.first { $0.type == "Link" })
        let bytes = try Data(contentsOf: fixture.source)
        let outlinePoint = try XCTUnwrap(document.outlineRoot?.child(at: 0)?.destination?.point)
        var configuration = OCRConfiguration()
        configuration.pageIndexes = [1]
        workspace.startOCR(configuration: configuration)
        try await waitUntil { workspace.canUseCompletedOCRResult }

        let applied = await workspace.applySearchableOCRToCurrentDocument()

        XCTAssertTrue(applied)
        XCTAssertEqual(document.pageCount, 4)
        for index in [0, 2, 3] {
            XCTAssertTrue(document.page(at: index) === before[index])
            XCTAssertTrue(document.page(at: index)?.string?.contains("Original page \(index + 1)") == true)
        }
        XCTAssertTrue(document.page(at: 0)?.annotations.first === note)
        XCTAssertFalse(document.page(at: 1) === before[1])
        XCTAssertTrue(document.page(at: 1)?.string?.contains("췌장 OCR page 2") == true)
        XCTAssertTrue(link.destination?.page === document.page(at: 1))
        XCTAssertEqual(document.outlineRoot?.child(at: 0)?.destination?.point, outlinePoint)
        XCTAssertTrue(document.outlineRoot?.child(at: 0)?.destination?.page === before[0])
        XCTAssertEqual(try Data(contentsOf: fixture.source), bytes)
        workspace.undo()
        for index in 0..<4 { XCTAssertTrue(document.page(at: index) === before[index]) }
        XCTAssertTrue(link.destination?.page === before[1])
        workspace.redo()
        XCTAssertTrue(document.page(at: 0) === before[0])
        XCTAssertTrue(document.page(at: 1)?.string?.contains("췌장 OCR page 2") == true)
        XCTAssertTrue(link.destination?.page === document.page(at: 1))
    }

    func testPartialSaveKeepsWholeDocumentAndDoesNotMutateOpenPages() async throws {
        let fixture = try makeFixture()
        let workspace = fixture.workspace
        let before = (0..<4).map { workspace.document!.page(at: $0)! }
        let bytes = try Data(contentsOf: fixture.source)
        var configuration = OCRConfiguration()
        configuration.pageIndexes = [3, 1, 3]
        workspace.startOCR(configuration: configuration)
        try await waitUntil { workspace.canUseCompletedOCRResult }
        XCTAssertEqual(workspace.ocrConfiguration.pageIndexes, [1, 3])
        let destination = fixture.directory.appendingPathComponent("source-OCR.pdf")

        let saved = await workspace.exportSearchableOCRCopy(to: destination)

        XCTAssertTrue(saved)
        let result = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(result.pageCount, 4)
        for index in [1, 3] {
            XCTAssertTrue(result.page(at: index)?.string?.contains("췌장 OCR page \(index + 1)") == true)
        }
        for index in [0, 2] {
            XCTAssertTrue(result.page(at: index)?.string?.contains("Original page \(index + 1)") == true)
            XCTAssertEqual(result.page(at: index)?.annotations.first?.contents, "Keep note \(index)")
        }
        for index in 0..<4 { XCTAssertTrue(workspace.document?.page(at: index) === before[index]) }
        XCTAssertEqual(try Data(contentsOf: fixture.source), bytes)
        XCTAssertFalse(workspace.isDirty)
    }

    func testInvalidPageSelectionNeverStartsRecognition() throws {
        var calls = 0
        let fixture = try makeFixture(recognizer: { url, fingerprint, configuration, _ in
            calls += 1
            return try Self.checkpoint(url: url, fingerprint: fingerprint, configuration: configuration)
        })
        for selection in [[], [-1], [4], [0, Int.max]] {
            var configuration = OCRConfiguration()
            configuration.pageIndexes = selection
            fixture.workspace.startOCR(configuration: configuration)
            XCTAssertEqual(fixture.workspace.ocrState, .idle)
            XCTAssertNotNil(fixture.workspace.presentedError)
        }
        XCTAssertEqual(calls, 0)
    }

    func testApplyingEmptyRecognitionDoesNotCreateAnEdit() async throws {
        let fixture = try makeFixture(recognizer: { url, fingerprint, configuration, _ in
            var result = try Self.checkpoint(url: url, fingerprint: fingerprint, configuration: configuration)
            for index in result.pages.keys {
                result.pages[index] = OCRPageResult(pageIndex: index, text: "", observations: [],
                    completedAt: Date(), skippedBecauseTextExists: false)
            }
            return result
        })
        var configuration = OCRConfiguration()
        configuration.pageIndexes = [1]
        let page = fixture.workspace.document?.page(at: 1)
        fixture.workspace.startOCR(configuration: configuration)
        try await waitUntil { fixture.workspace.canUseCompletedOCRResult }

        let applied = await fixture.workspace.applySearchableOCRToCurrentDocument()

        XCTAssertTrue(applied)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)
        XCTAssertTrue(fixture.workspace.document?.page(at: 1) === page)
        XCTAssertEqual(fixture.workspace.statusMessage, L10n.string("status.ocr_no_changes"))
    }

    func testMissingOrExtraPageResultsCannotBeAppliedOrSaved() async throws {
        for returnedPages in [[1], [1, 2, 3]] {
            let fixture = try makeFixture(recognizer: { url, fingerprint, configuration, _ in
                try Self.checkpoint(url: url, fingerprint: fingerprint,
                    configuration: configuration, resultIndexes: returnedPages)
            })
            var configuration = OCRConfiguration()
            configuration.pageIndexes = [1, 3]
            fixture.workspace.startOCR(configuration: configuration)
            try await waitUntil { if case .finished = fixture.workspace.ocrState { return true }; return false }
            XCTAssertFalse(fixture.workspace.canUseCompletedOCRResult)
            let applied = await fixture.workspace.applySearchableOCRToCurrentDocument()
            let saved = await fixture.workspace.exportSearchableOCRCopy(to:
                fixture.directory.appendingPathComponent("invalid.pdf"))
            XCTAssertFalse(applied)
            XCTAssertFalse(saved)
            XCTAssertFalse(fixture.workspace.isDirty)
        }
    }

    func testChangingScopeReplacesCompletedSelectionWithoutReusingOtherPages() async throws {
        let fixture = try makeFixture()
        var configuration = OCRConfiguration()
        configuration.pageIndexes = [0]
        fixture.workspace.startOCR(configuration: configuration)
        try await waitUntil { fixture.workspace.canUseCompletedOCRResult }
        let first = try XCTUnwrap(fixture.workspace.ocrCheckpoint?.configurationFingerprint)
        configuration.pageIndexes = [2, 3]
        fixture.workspace.startOCR(configuration: configuration)
        XCTAssertNil(fixture.workspace.ocrCheckpoint)
        try await waitUntil { fixture.workspace.canUseCompletedOCRResult }
        XCTAssertEqual(Set(fixture.workspace.ocrCheckpoint?.pages.keys.map { $0 } ?? []), [2, 3])
        XCTAssertNotEqual(fixture.workspace.ocrCheckpoint?.configurationFingerprint, first)
    }

    func testOpeningAnotherDocumentClearsPreviousPageScope() async throws {
        let fixture = try makeFixture()
        var configuration = OCRConfiguration()
        configuration.pageIndexes = [2, 3]
        configuration.languages = ["ko-KR"]
        fixture.workspace.startOCR(configuration: configuration)
        try await waitUntil { fixture.workspace.canUseCompletedOCRResult }
        let anotherSource = fixture.directory.appendingPathComponent("another.pdf")
        try FileManager.default.copyItem(at: fixture.source, to: anotherSource)

        XCTAssertTrue(fixture.workspace.open(url: anotherSource))

        XCTAssertNil(fixture.workspace.ocrConfiguration.pageIndexes)
        XCTAssertEqual(fixture.workspace.ocrConfiguration.languages, ["ko-KR"])
        XCTAssertNil(fixture.workspace.ocrCheckpoint)
        XCTAssertFalse(fixture.workspace.canUseCompletedOCRResult)
    }

    func testEmptyRecognitionStillRejectsChangedSourceBeforeReturningNoChange() async throws {
        let fixture = try makeFixture(recognizer: { url, fingerprint, configuration, _ in
            var result = try Self.checkpoint(url: url, fingerprint: fingerprint, configuration: configuration)
            for index in result.pages.keys {
                result.pages[index] = OCRPageResult(pageIndex: index, text: "", observations: [],
                    completedAt: Date(), skippedBecauseTextExists: false)
            }
            return result
        })
        var configuration = OCRConfiguration()
        configuration.pageIndexes = [1]
        fixture.workspace.startOCR(configuration: configuration)
        try await waitUntil { fixture.workspace.canUseCompletedOCRResult }
        let page = fixture.workspace.document?.page(at: 1)
        var changed = try Data(contentsOf: fixture.source)
        changed.append(Data("\n% external source change\n".utf8))
        try changed.write(to: fixture.source)

        let applied = await fixture.workspace.applySearchableOCRToCurrentDocument()
        XCTAssertFalse(applied)
        XCTAssertNotNil(fixture.workspace.presentedError)
        XCTAssertNotEqual(fixture.workspace.statusMessage, L10n.string("status.ocr_no_changes"))
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)
        XCTAssertTrue(fixture.workspace.document?.page(at: 1) === page)
        XCTAssertEqual(try Data(contentsOf: fixture.source), changed)
    }

    func testUnlistedPopupSourceCannotBeSilentlyExportedAsValidPartialOCR() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-OCRInvalidPopup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("invalid-source.pdf")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 260] /Resources << >> /Annots [4 0 R 5 0 R] >>",
            "<< /Type /Annot /Subtype /Text /Rect [20 20 45 45] /Contents (Kept note) /Popup 6 0 R >>",
            "<< /Type /Annot /Subtype /Popup /Rect [20 20 45 45] /Parent 7 0 R >>",
            "<< /Type /Annot /Subtype /Popup /Rect [20 20 45 45] /Parent 4 0 R >>",
            "<< /Type /Annot /Subtype /Text /Rect [20 20 45 45] /Contents (Kept note) /Popup 5 0 R >>"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try data.write(to: source)
        XCTAssertFalse(try listedReciprocalNotes(at: source, expectedPages: 1))
        var recognizerCalls = 0
        let workspace = PDFWorkspaceState(ocrRecognizer: { url, fingerprint, configuration, _ in
            recognizerCalls += 1
            return try Self.checkpoint(url: url, fingerprint: fingerprint, configuration: configuration)
        })
        XCTAssertTrue(workspace.open(url: source))
        workspace.setMode(.editing)
        let document = try XCTUnwrap(workspace.document)
        var configuration = OCRConfiguration()
        configuration.pageIndexes = [0]
        workspace.startOCR(configuration: configuration)
        // The verified snapshot writer rejects this invalid relationship before
        // starting OCR. A completed checkpoint must never be awaited here.
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertEqual(workspace.ocrState, .idle)
        XCTAssertNil(workspace.ocrCheckpoint)
        XCTAssertFalse(workspace.canUseCompletedOCRResult)
        XCTAssertEqual(recognizerCalls, 0)
        let output = directory.appendingPathComponent("must-not-exist.pdf")

        let saved = await workspace.exportSearchableOCRCopy(to: output)
        XCTAssertFalse(saved)
        let applied = await workspace.applySearchableOCRToCurrentDocument()
        XCTAssertFalse(applied)
        XCTAssertEqual(recognizerCalls, 0)
        XCTAssertTrue(workspace.document === document)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: source), data)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
    }

    /// Inspect the immutable file without warming the workspace's PDFPage or
    /// annotation wrappers before its normal guarded open.
    private func listedReciprocalNotes(at url: URL, expectedPages: Int = 4) throws -> Bool {
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        guard document.numberOfPages == expectedPages, expectedPages > 0 else { return false }
        for index in 1...expectedPages {
            let page = try XCTUnwrap(document.page(at: index)?.dictionary)
            var array: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(page, "Annots", &array), let array,
                  CGPDFArrayGetCount(array) <= 8 else { return false }
            var annotations: [CGPDFDictionaryRef] = []
            for offset in 0..<CGPDFArrayGetCount(array) {
                var annotation: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(array, offset, &annotation), let annotation else { return false }
                annotations.append(annotation)
            }
            func subtype(_ dictionary: CGPDFDictionaryRef) -> String? {
                var name: UnsafePointer<CChar>?
                return CGPDFDictionaryGetName(dictionary, "Subtype", &name) ? name.map { String(cString: $0) } : nil
            }
            let notes = annotations.filter { subtype($0) == "Text" }
            let popups = annotations.filter { subtype($0) == "Popup" }
            guard notes.count == 1, popups.count == 1 else { return false }
            var popup: CGPDFDictionaryRef?, parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(notes[0], "Popup", &popup), let popup,
                  CGPDFDictionaryGetDictionary(popups[0], "Parent", &parent), let parent,
                  pdfReferenceIdentity(popup) == pdfReferenceIdentity(popups[0]),
                  pdfReferenceIdentity(parent) == pdfReferenceIdentity(notes[0]) else { return false }
        }
        return true
    }

    private func makeFixture(recognizer: WorkspaceOCRRecognizer? = nil) throws
        -> (directory: URL, source: URL, workspace: PDFWorkspaceState) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-OCRScopeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 260)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &bounds, nil))
        for index in 0..<4 {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(bounds)
            let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
            let text = NSAttributedString(string: "Original page \(index + 1)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ])
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 20, y: 180)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        for index in 0..<4 {
            let note = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 25, height: 25), forType: .text, withProperties: nil)
            note.contents = "Keep note \(index)"
            document.page(at: index)?.addAnnotation(note)
        }
        let outline = PDFOutline()
        let child = PDFOutline()
        child.label = "Unchanged destination"
        child.destination = PDFDestination(page: document.page(at: 0)!, at: CGPoint(x: 17, y: 193))
        outline.insertChild(child, at: 0)
        document.outlineRoot = outline
        let link = PDFAnnotation(bounds: CGRect(x: 30, y: 80, width: 80, height: 20), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: document.page(at: 1)!, at: CGPoint(x: 21, y: 185)))
        document.page(at: 0)?.addAnnotation(link)
        let source = directory.appendingPathComponent("source.pdf")
        try AtomicPDFWriter.write(document, to: source)
        XCTAssertTrue(try listedReciprocalNotes(at: source))
        let workspace = PDFWorkspaceState(ocrRecognizer: recognizer ?? { url, fingerprint, configuration, _ in
            try Self.checkpoint(url: url, fingerprint: fingerprint, configuration: configuration)
        })
        XCTAssertTrue(workspace.open(url: source))
        workspace.setMode(.editing)
        return (directory, source, workspace)
    }

    private static func checkpoint(url: URL, fingerprint: String?, configuration: OCRConfiguration,
                                   resultIndexes: [Int]? = nil) throws -> OCRCheckpoint {
        let document = try XCTUnwrap(PDFDocument(url: url))
        var result = OCRCheckpoint(documentFingerprint: try fingerprint ?? VisionOCRService.fingerprint(for: url),
            pageCount: document.pageCount,
            configurationFingerprint: VisionOCRService.configurationFingerprint(for: configuration))
        for index in try resultIndexes ?? configuration.resolvedPageIndexes(pageCount: document.pageCount) {
            let text = "췌장 OCR page \(index + 1)"
            result.pages[index] = OCRPageResult(pageIndex: index, text: text, observations: [
                OCRWordBox(text: text, confidence: 1, x: 0.1, y: 0.6, width: 0.8, height: 0.1)
            ], completedAt: Date(), skippedBecauseTextExists: false)
        }
        return result
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for OCR result")
    }
}
