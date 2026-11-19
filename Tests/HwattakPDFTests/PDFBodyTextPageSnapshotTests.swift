// SPDX-License-Identifier: MPL-2.0
import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextPageSnapshotTests: XCTestCase {
    func testVerifiedPaintingSurvivesSnapshotWithoutCurrentPageReference() throws {
        let original = try rawPDF(contents: ["BT /F1 20 Tf 40 100 Td (Retained painting) Tj ET"])
        let originalPage = try XCTUnwrap(original.page(at: 0))
        let native = try XCTUnwrap(original.documentRef)
        let reference = try XCTUnwrap(originalPage.pageRef)
        let detached = PDFDocument()
        let page = SnapshotWithoutReferencePage()
        page.geometrySource = originalPage
        detached.insert(page, at: 0)
        XCTAssertNil(page.pageRef)
        let serialized = try XCTUnwrap(original.dataRepresentation())
        var plan = PDFCatalogGraphPlan()
        // Production supplies this only for contentUnchanged provenance.
        // Model that existing plan independently of the copied page's reader.
        plan.retainedDocuments = [native]
        plan.paintingSources[0] = reference
        plan.pageGeometry[0] = try PDFPageGeometryPreserver.capture(originalPage, reference: reference)
        let data = try PDFBodyTextPageSnapshot.preservingCatalog(in: serialized, from: detached, plan: plan)
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        let savedPage = try XCTUnwrap(reopened.page(at: 0))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: savedPage),
                       try PDFBodyTextPageSnapshot.contentData(for: originalPage))
        XCTAssertEqual(render(savedPage), render(originalPage))
        XCTAssertEqual(reopened.string, original.string)
        // Without a verified unchanged painting, an absent current reference
        // must still refuse; never borrow arbitrary original page content.
        plan.paintingSources = [:]
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.preservingCatalog(
            in: serialized, from: detached, plan: plan))
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.preservingPageContents(in: serialized, from: detached))
    }

    func testTemporaryFontAliasesPreservePixelsProgramsAndRestoreExactNames() throws {
        let source = try textPDF("Embedded font identity", y: 100)
        let original = try XCTUnwrap(source.page(at: 0))
        let originalFonts = try fonts(on: original)
        XCTAssertFalse(originalFonts.isEmpty)
        let editing = try XCTUnwrap(PDFDocument(data: PDFBodyTextPageSnapshot.data(for: original)))
        let editingPage = try XCTUnwrap(editing.page(at: 0))
        let protectedFonts = try fonts(on: editingPage)
        XCTAssertTrue(protectedFonts.allSatisfy { $0.name.hasPrefix("EmberBodyFont") })
        XCTAssertEqual(protectedFonts.map(\.program), originalFonts.map(\.program))
        XCTAssertEqual(render(editingPage), render(original))
        let restored = try XCTUnwrap(PDFDocument(data: PDFBodyTextPageSnapshot.restoringFontNames(
            in: PDFBodyTextPageSnapshot.data(for: original))))
        let restoredPage = try XCTUnwrap(restored.page(at: 0))
        let restoredFonts = try fonts(on: restoredPage)
        XCTAssertEqual(restoredFonts.map(\.name), originalFonts.map(\.name))
        XCTAssertEqual(restoredFonts.map(\.descriptorName), originalFonts.map(\.descriptorName))
        XCTAssertEqual(restoredFonts.map(\.program), originalFonts.map(\.program))
        XCTAssertTrue(restoredFonts.allSatisfy { !$0.hasMarker })
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: restoredPage),
                       try PDFBodyTextPageSnapshot.contentData(for: original))
        XCTAssertEqual(render(restoredPage), render(original))
    }

    func testUnembeddedFontNameCannotBeReplacedByAnInputMarker() throws {
        let source = try rawPDF(contents: ["BT /F1 20 Tf 40 100 Td (Standard font) Tj ET"],
                                fontExtra: "/EmberPDFBodyOriginalBaseFont /Courier")
        let page = try XCTUnwrap(source.page(at: 0))
        let editingData = try PDFBodyTextPageSnapshot.data(for: page)
        let restored = try XCTUnwrap(PDFDocument(data: PDFBodyTextPageSnapshot.restoringFontNames(in: editingData)))
        let found = try fonts(on: XCTUnwrap(restored.page(at: 0)))
        XCTAssertEqual(found.map(\.name), ["Helvetica"])
        XCTAssertFalse(found[0].hasMarker)
        XCTAssertNil(found[0].program)
    }

    func testRawContentOverridePreservesCMYKAndOriginalResources() throws {
        let pieces = ["q .2 .7 .1 0 k 10 400 80 50 re f Q", "BT /F1 20 Tf 40 100 Td (Original text) Tj ET"]
        let source = try rawPDF(contents: pieces)
        let page = try XCTUnwrap(source.page(at: 0))
        let content = try PDFBodyTextPageSnapshot.contentData(for: page)
        XCTAssertEqual(String(decoding: content, as: UTF8.self), pieces.joined(separator: " "))
        let copy = try XCTUnwrap(PDFDocument(data: PDFBodyTextPageSnapshot.data(for: page,
            contentOverride: content + Data("\n% unchanged drawing\n".utf8))))
        let result = try XCTUnwrap(copy.page(at: 0))
        XCTAssertEqual(render(result), render(page))
        XCTAssertEqual(try fonts(on: result).map(\.name), ["Helvetica"])
        XCTAssertEqual(copy.string, source.string)
    }

    func testDonorFormResetsInvisibleInheritedPaintAndTextState() throws {
        let source = try rawPDF(contents: ["/Hidden gs BT 8 Tc 4 Tw 40 Tz 3 Tr 30 Ts ET"],
                                extraResources: "/ExtGState << /Hidden << /ca 0 /CA 0 /BM /Multiply >> >>")
        let page = try XCTUnwrap(source.page(at: 0))
        let donor = try textPDF("Visible inserted text", y: 100)
        let donorData = try XCTUnwrap(donor.dataRepresentation())
        let serializedDonor = try XCTUnwrap(PDFDocument(data: donorData))
        let donorName = try PDFBodyTextPageSnapshot.unusedXObjectName(for: page)
        let content = try PDFBodyTextPageSnapshot.contentData(for: page)
            + Data("\nq /\(donorName) Do Q\n".utf8)
        let result = try XCTUnwrap(PDFDocument(data: PDFBodyTextPageSnapshot.data(for: page,
            contentOverride: content, donorPDF: donorData, donorName: donorName)))
        let resultPage = try XCTUnwrap(result.page(at: 0))
        let actual = render(resultPage)
        let expected = render(try XCTUnwrap(serializedDonor.page(at: 0)))
        // CoreGraphics' Form compositing can round antialiased edge channels
        // by one level; invisible, moved, or inherited-spaced text cannot pass.
        XCTAssertLessThanOrEqual(zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0, 1)
        XCTAssertTrue((result.string ?? "").contains("Visible inserted text"))
        XCTAssertTrue(PDFBodyTextPageSnapshot.isBodyTextXObject(named: donorName, on: resultPage))
        XCTAssertNotEqual(try PDFBodyTextPageSnapshot.unusedXObjectName(for: resultPage), donorName)
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.data(for: resultPage, contentOverride: content,
            donorPDF: donorData, donorName: donorName))
    }

    func testReplacingOwnedFormDoesNotAccumulateOldEmbeddedFonts() throws {
        var document = try rawPDF(contents: ["BT /F1 12 Tf 40 500 Td (Unchanged) Tj ET"])
        let donorData = try XCTUnwrap(textPDF("Replacement", y: 100).dataRepresentation())
        let originalContent = try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(document.page(at: 0)))
        var previousName: String?
        var firstSize = 0
        for iteration in 0..<8 {
            let page = try XCTUnwrap(document.page(at: 0))
            let name = try PDFBodyTextPageSnapshot.unusedXObjectName(for: page)
            let content = originalContent + Data("\nq /\(name) Do Q\n".utf8)
            let result = try PDFBodyTextPageSnapshot.data(for: page, contentOverride: content,
                donorPDF: donorData, donorName: name, droppingXObjectNames: Set(previousName.map { [$0] } ?? []))
            if iteration == 0 { firstSize = result.count }
            XCTAssertLessThan(result.count, firstSize + 128)
            document = try XCTUnwrap(PDFDocument(data: result))
            if let previousName {
                XCTAssertFalse(PDFBodyTextPageSnapshot.isBodyTextXObject(named: previousName, on: try XCTUnwrap(document.page(at: 0))))
            }
            previousName = name
        }
        XCTAssertTrue((document.string ?? "").contains("Unchanged"))
        XCTAssertTrue((document.string ?? "").contains("Replacement"))
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.data(for: XCTUnwrap(document.page(at: 0)),
            contentOverride: originalContent, droppingXObjectNames: ["UntrustedName"]))
    }

    private struct Font {
        let name: String
        let descriptorName: String?
        let program: Data?
        let hasMarker: Bool
    }

    private func fonts(on page: PDFPage) throws -> [Font] {
        let dictionary = try XCTUnwrap(page.pageRef?.dictionary)
        var resources: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources))
        var fontDictionary: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "Font", &fontDictionary))
        var entries: [(String, Font)] = []
        CGPDFDictionaryApplyBlock(try XCTUnwrap(fontDictionary), { key, value, _ in
            var font: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(value, .dictionary, &font), let font else { return false }
            var descriptor: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor)
            var program: Data?
            if let descriptor {
                for key in ["FontFile", "FontFile2", "FontFile3"] {
                    var stream: CGPDFStreamRef?
                    if CGPDFDictionaryGetStream(descriptor, key, &stream), let stream {
                        var format = CGPDFDataFormat.raw
                        program = CGPDFStreamCopyData(stream, &format) as Data?
                    }
                }
            }
            var marker: CGPDFObjectRef?
            entries.append((String(cString: key), Font(name: self.name("BaseFont", in: font) ?? "",
                descriptorName: descriptor.flatMap { self.name("FontName", in: $0) }, program: program,
                hasMarker: CGPDFDictionaryGetObject(font, "EmberPDFBodyOriginalBaseFont", &marker))))
            return true
        }, nil)
        return entries.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func name(_ key: String, in dictionary: CGPDFDictionaryRef) -> String? {
        var pointer: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &pointer), let pointer else { return nil }
        return String(cString: pointer)
    }

    private func textPDF(_ text: String, y: CGFloat) throws -> PDFDocument {
        let bytes = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 40, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [.font: NSFont(name: "Helvetica", size: 20)!])), context)
        context.endPDFPage()
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: bytes as Data))
    }

    private func rawPDF(contents: [String], fontExtra: String = "", extraResources: String = "") throws -> PDFDocument {
        let references = contents.indices.map { "\($0 + 5) 0 R" }.joined(separator: " ")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] /Resources << /Font << /F1 4 0 R >> \(extraResources) >> /Contents [\(references)] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica \(fontExtra) >>"
        ]
        objects += contents.map { "<< /Length \($0.utf8.count) >>\nstream\n\($0)\nendstream" }
        var data = Data("%PDF-1.7\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func render(_ page: PDFPage) -> Data {
        let context = CGContext(data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 1600,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        if let reference = page.pageRef { context.drawPDFPage(reference) }
        return Data(bytes: context.data!, count: 1600 * 600)
    }
}

private final class SnapshotWithoutReferencePage: PDFPage {
    var geometrySource: PDFPage?
    override var pageRef: CGPDFPage? { nil }
    override func bounds(for box: PDFDisplayBox) -> CGRect { geometrySource?.bounds(for: box) ?? .zero }
}
