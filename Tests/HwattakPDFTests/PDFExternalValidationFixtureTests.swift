// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

/// The app writes these fixtures; separate qpdf/Poppler/pypdf processes inspect
/// them in CI. The external processes never run inside the product or test host.
@MainActor
final class PDFExternalValidationFixtureTests: XCTestCase {
    func testExportFixturesForIndependentEngines() async throws {
        let requested = ProcessInfo.processInfo.environment["EMBER_EXTERNAL_FIXTURE_DIRECTORY"]
        let folder = requested.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { if requested == nil { try? FileManager.default.removeItem(at: folder) } }
        let source = try fixture()
        PDFCanonicalFormMaterializer.mark(source)
        try AtomicPDFWriter.write(source, to: folder.appendingPathComponent("source.pdf"))
        let original = try Data(contentsOf: folder.appendingPathComponent("source.pdf"))
        let extracted = try PDFPageOperations.extract(from: source, indexes: [1])
        try AtomicPDFWriter.write(extracted, to: folder.appendingPathComponent("extracted.pdf"))
        let merged = try PDFPageOperations.extract(from: source, indexes: [0])
        _ = try PDFPageOperations.append(contentsOf: extracted, to: merged)
        try AtomicPDFWriter.write(merged, to: folder.appendingPathComponent("merged.pdf"))

        let body = try PDFSourceFileAccess.loadDocument(at: folder.appendingPathComponent("source.pdf")).document
        let page = try XCTUnwrap(body.page(at: 0))
        let match = try XCTUnwrap(body.findString("Original body", withOptions: []).first)
        let selection = try PDFRegionTextSelection(document: body, page: page,
            fragments: [.init(text: "Original body", bounds: match.bounds(for: page))])
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        let changed = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "Changed body", style: target.style, bounds: target.bounds)
        body.removePage(at: 0)
        body.insert(changed, at: 0)
        // Match the app's save boundary. A cold widget's absent default needs
        // the independent original-state reader on the isolated writer; a
        // direct main-thread SDK document cannot supply that proof.
        let snapshot = try PDFRecoverySnapshot(capturing: body)
        _ = try await Task.detached {
            try AtomicPDFWriter.write(snapshot.takeDocument(), to: folder.appendingPathComponent("edited.pdf"))
        }.value

        let entries: [[String: Any]] = [
            ["id": "source", "path": "source.pdf", "page_count": 2,
             "fields": ["student": "Ada"],
             "expected_text": ["Original body", "Second page", "Keep this line"],
             "reading_order": ["Original body", "Keep this line", "Second page"], "pages": [1, 2]],
            ["id": "extract", "path": "extracted.pdf", "page_count": 1,
             "fields": ["student": "Ada"],
             "expected_text": ["Second page"], "absent_text": ["Original body"], "pages": [1],
             "reference": "source.pdf", "compare_pages": [["output": 1, "reference": 2]]],
            ["id": "merge", "path": "merged.pdf", "page_count": 2,
             "fields": ["student": "Ada"],
             "expected_text": ["Original body", "Second page"], "pages": [1, 2],
             "reference": "source.pdf", "compare_text": true,
             "compare_pages": [["output": 1, "reference": 1], ["output": 2, "reference": 2]]],
            ["id": "edit", "path": "edited.pdf", "page_count": 2,
             "fields": ["student": "Ada"],
             "expected_text": ["Changed body", "Keep this line", "Second page"],
             "reading_order": ["Changed body", "Keep this line", "Second page"],
             "absent_text": ["Original body"], "pages": [1, 2],
             "reference": "source.pdf", "compare_pages": [["output": 2, "reference": 2]]]
        ]
        try JSONSerialization.data(withJSONObject: ["schema": 1, "files": entries], options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("manifest.json"))
        XCTAssertEqual(source.pageCount, 2)
        XCTAssertEqual(source.findString("Original body", withOptions: []).count, 1)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("source.pdf")), original)
    }

    private func fixture() throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 360, height: 480)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for title in ["Original body", "Second page"] {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            for (text, y) in [(title, 390.0), ("Keep this line", 300.0)] {
                context.textPosition = CGPoint(x: 36, y: y)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
                    attributes: [.font: NSFont(name: "Helvetica", size: 18)!, .foregroundColor: NSColor.black]))
                CTLineDraw(line, context)
            }
            context.setFillColor(NSColor.systemBlue.cgColor)
            context.fill(CGRect(x: 36, y: 70, width: 100, height: 80))
            context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Ember interoperability fixture"]
        let root = PDFOutline()
        let child = PDFOutline()
        child.label = "Second chapter"
        child.destination = PDFDestination(page: try XCTUnwrap(document.page(at: 1)), at: CGPoint(x: 0, y: 480))
        root.insertChild(child, at: 0)
        document.outlineRoot = root
        let field = PDFAnnotation(bounds: CGRect(x: 180, y: 70, width: 130, height: 25),
                                  forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "student"
        field.widgetStringValue = "Ada"
        field.font = NSFont.systemFont(ofSize: 14)
        field.fontColor = .black
        document.page(at: 1)?.addAnnotation(field)
        return document
    }
}
