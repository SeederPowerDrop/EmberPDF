// SPDX-License-Identifier: MPL-2.0
import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextSavePreservationTests: XCTestCase {
    func testRawContentsKeepStagedAnnotationsOutlineAndMetadata() throws {
        let live = try document(["Original first", "Original second"])
        let page = try XCTUnwrap(live.page(at: 0))
        let markedData = try PDFBodyTextPageSnapshot.data(for: page,
            contentOverride: PDFBodyTextPageSnapshot.contentData(for: page), preservePageContent: true)
        let marked = try XCTUnwrap(PDFDocument(data: markedData))
        live.removePage(at: 0); live.insert(try XCTUnwrap(marked.page(at: 0)), at: 0)
        XCTAssertTrue(PDFBodyTextPageSnapshot.requiresPageContentPreservation(live))
        let staged = try document(["Staged first", "Staged second"])
        staged.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Retained title"]
        let note = PDFAnnotation(bounds: CGRect(x: 20, y: 30, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = "Retained note"
        staged.page(at: 0)?.addAnnotation(note)
        let root = PDFOutline(), child = PDFOutline()
        child.label = "Second page"
        child.destination = PDFDestination(page: try XCTUnwrap(staged.page(at: 1)), at: CGPoint(x: 30, y: 180))
        root.insertChild(child, at: 0); staged.outlineRoot = root
        let bytes = try PDFBodyTextPageSnapshot.preservingPageContents(
            in: XCTUnwrap(staged.dataRepresentation()), from: live)
        let result = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.findString("Original first", withOptions: []).count, 1)
        XCTAssertEqual(result.findString("Original second", withOptions: []).count, 1)
        XCTAssertTrue(result.findString("Staged", withOptions: []).isEmpty)
        XCTAssertEqual(result.page(at: 0)?.annotations.first?.contents, "Retained note")
        XCTAssertEqual(result.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Retained title")
        let destination = try XCTUnwrap(result.outlineRoot?.child(at: 0)?.destination)
        XCTAssertTrue(destination.page === result.page(at: 1))
        XCTAssertTrue(PDFBodyTextPageSnapshot.requiresPageContentPreservation(result))
    }

    func testEncryptedStagingIsRejectedBeforeReplacingDestination() throws {
        let live = try document(["Protected source"]), page = try XCTUnwrap(live.page(at: 0))
        let data = try PDFBodyTextPageSnapshot.data(for: page,
            contentOverride: PDFBodyTextPageSnapshot.contentData(for: page), preservePageContent: true)
        let marked = try XCTUnwrap(PDFDocument(data: data))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.pdf")
        let before = try XCTUnwrap(live.dataRepresentation()); try before.write(to: destination)
        XCTAssertThrowsError(try AtomicPDFWriter.write(marked, to: destination,
            writeOptions: [.ownerPasswordOption: "owner-pass", .userPasswordOption: "reader-pass"]))
        XCTAssertEqual(try Data(contentsOf: destination), before)
        XCTAssertThrowsError(try AtomicPDFWriter.write(marked, to: destination,
            writeOptions: [.burnInAnnotationsOption: true]))
        XCTAssertEqual(try Data(contentsOf: destination), before)
    }


    func testOriginalWidgetCopiesCannotAuthorizeAnUnrequestedBodyTextChange() throws {
        let live = try annotationContextDocument(), page = try XCTUnwrap(live.page(at: 0))
        let before = try XCTUnwrap(page.string), source = try PDFBodyTextPageSnapshot.data(for: page)
        let content = try PDFBodyTextPageSnapshot.contentData(for: page)
        let token = Data("RIGHT preserved".utf8), changed = Data("RIGHT corrupted".utf8)
        let found = try XCTUnwrap(content.range(of: token))
        var modified = content; modified.replaceSubrange(found, with: changed)
        let raw = try PDFBodyTextPageSnapshot.data(for: page, contentOverride: modified)
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: raw))
        let result = try XCTUnwrap(XCTUnwrap(document.page(at: 0)).copy() as? PDFPage)
        for annotation in page.annotations {
            result.addAnnotation(try XCTUnwrap(annotation.copy() as? PDFAnnotation))
        }
        XCTAssertEqual(result.annotations.count, page.annotations.count)
        XCTAssertTrue((result.string ?? "").contains("RIGHT corrupted"),
            "The negative must observe a real unrequested body change after restoring widget context.")
        XCTAssertFalse(PDFBodyTextEditor.preservesTextSequence(before: before, after: result.string ?? "",
            original: "LEFT original", replacement: "LEFT original"),
            "An unchanged requested span cannot excuse any unrelated final sequence change.")
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), source)
    }

    private func annotationContextDocument() throws -> PDFDocument {
        let commands = "BT /F1 10 Tf 1 0 0 1 20 160 Tm (LEFT original) Tj ET\n"
            + "BT /F1 10 Tf 1 0 0 1 170 160 Tm (RIGHT preserved) Tj ET\n"
            + "BT /F1 10 Tf 1 0 0 1 20 140 Tm (LEFT second) Tj ET\n"
            + "BT /F1 10 Tf 1 0 0 1 170 140 Tm (RIGHT second) Tj ET\n"
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 320 220] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Length \(commands.utf8.count) >>\nstream\n\(commands)endstream"]
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index+1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count; bytes.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
        let page = try XCTUnwrap(document.page(at: 0))
        for (index, rectangle) in [CGRect(x: 18,y: 148,width: 130,height: 25),
            CGRect(x: 168,y: 148,width: 130,height: 25), CGRect(x: 18,y: 128,width: 130,height: 15)].enumerated() {
            let widget = PDFAnnotation(bounds: rectangle, forType: .widget, withProperties: nil)
            widget.widgetFieldType = .text
            widget.fieldName = "OwnedWidget\(index)"; widget.widgetStringValue = "Owned value \(index)"
            widget.font = NSFont(name: "Helvetica", size: 10); widget.fontColor = .black
            page.addAnnotation(widget)
        }
        XCTAssertEqual(page.annotations.count, 3)
        return document
    }

    private func document(_ lines: [String]) throws -> PDFDocument {
        let data = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for text in lines {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 30, y: 160)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 14)])), context)
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }
}
