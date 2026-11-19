// SPDX-License-Identifier: MPL-2.0
import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextDocumentGraphTests: XCTestCase {
    func testLongFlatOutlineKeepsEverySiblingAndPageDestination() throws {
        let live = try XCTUnwrap(PDFDocument(data: rawPDF(text: "Original", outlineCount: 160)))
        let staged = rawPDF(text: "Staged", outlineCount: 160)
        let saved = try PDFBodyTextPageSnapshot.preservingPageContents(in: staged, from: live)
        let result = try XCTUnwrap(PDFDocument(data: saved))
        XCTAssertEqual(result.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Original")
        let outline = try XCTUnwrap(result.outlineRoot)
        XCTAssertEqual(outline.numberOfChildren, 160)
        for index in 0..<160 {
            let child = try XCTUnwrap(outline.child(at: index))
            XCTAssertEqual(child.label, "Section \(index)")
            XCTAssertTrue(child.destination?.page === result.page(at: 0))
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(result.page(at: 0))),
                       try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(live.page(at: 0))))
    }

    func testPDFKitNormalizedOriginKeepsPaintingAndStagedAnnotationCoordinates() throws {
        let live = try XCTUnwrap(PDFDocument(data: rawPDF(text: "Original", origin: CGPoint(x: 10, y: 15))))
        let originalPage = try XCTUnwrap(live.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 55, y: 66, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = "Retain staged position"
        originalPage.addAnnotation(note)
        let stagedData = try XCTUnwrap(live.dataRepresentation())
        let staged = try XCTUnwrap(PDFDocument(data: stagedData))
        let stagedPage = try XCTUnwrap(staged.page(at: 0))
        // This fixture exercises PDFKit's actual nonzero-origin normalization.
        XCTAssertEqual(stagedPage.bounds(for: .mediaBox).origin, .zero)
        let saved = try PDFBodyTextPageSnapshot.preservingPageContents(in: stagedData, from: live)
        let result = try XCTUnwrap(PDFDocument(data: saved))
        let savedPage = try XCTUnwrap(result.page(at: 0))
        XCTAssertEqual(savedPage.bounds(for: .mediaBox), stagedPage.bounds(for: .mediaBox))
        XCTAssertEqual(savedPage.annotations.first?.bounds, stagedPage.annotations.first?.bounds)
        XCTAssertEqual(savedPage.annotations.first?.contents, "Retain staged position")
        XCTAssertEqual(try render(savedPage), try render(originalPage))
        let originalText = try XCTUnwrap(live.findString("Original", withOptions: []).first).bounds(for: originalPage)
        let savedText = try XCTUnwrap(result.findString("Original", withOptions: []).first).bounds(for: savedPage)
        XCTAssertEqual(savedText.minX, originalText.minX - 10, accuracy: 0.0001)
        XCTAssertEqual(savedText.minY, originalText.minY - 15, accuracy: 0.0001)
    }

    func testIncompatiblePageGeometryIsRejected() throws {
        let live = try XCTUnwrap(PDFDocument(data: rawPDF(text: "Original", origin: CGPoint(x: 10, y: 15))))
        // A shifted CropBox alone, scaling, a different rotation, and a changed
        // UserUnit cannot share one safe content translation with the MediaBox.
        for pageExtra in ["/CropBox [1 0 400 600]", "/Rotate 90", "/UserUnit 2"] {
            XCTAssertThrowsError(try PDFBodyTextPageSnapshot.preservingPageContents(
                in: rawPDF(text: "Staged", pageExtra: pageExtra), from: live), pageExtra)
        }
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.preservingPageContents(
            in: rawPDF(text: "Staged", width: 500), from: live))
    }

    func testCurrentLiveGeometryEditsKeepStagedPaintingAndBoxes() throws {
        for edit in ["crop", "mediaOrigin", "mediaSize", "rotation"] {
            let live = try XCTUnwrap(PDFDocument(data: rawPDF(text: "Original", origin: CGPoint(x: 10, y: 15))))
            let page = try XCTUnwrap(live.page(at: 0))
            switch edit {
            case "crop": page.setBounds(CGRect(x: 15, y: 23, width: 390, height: 580), for: .cropBox)
            case "mediaOrigin": page.setBounds(CGRect(x: 15, y: 23, width: 400, height: 600), for: .mediaBox)
            case "mediaSize": page.setBounds(CGRect(x: 10, y: 15, width: 420, height: 620), for: .mediaBox)
            default: page.rotation = 90
            }
            // setBounds changes PDFPage geometry while its original CGPDFPage
            // boxes may remain unchanged. Saving must use current live boxes.
            let stagedData = try XCTUnwrap(live.dataRepresentation())
            let staged = try XCTUnwrap(PDFDocument(data: stagedData))
            let stagedPage = try XCTUnwrap(staged.page(at: 0))
            let saved = try PDFBodyTextPageSnapshot.preservingPageContents(in: stagedData, from: live)
            let result = try XCTUnwrap(PDFDocument(data: saved))
            let savedPage = try XCTUnwrap(result.page(at: 0))
            for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                XCTAssertEqual(savedPage.bounds(for: box), stagedPage.bounds(for: box), edit)
            }
            XCTAssertEqual(savedPage.rotation, stagedPage.rotation, edit)
            XCTAssertEqual(try render(savedPage), try render(stagedPage), edit)
        }
    }

    private func rawPDF(text: String, origin: CGPoint = .zero, outlineCount: Int = 0,
                        pageExtra: String = "", width: Int = 400) -> Data {
        let x = Int(origin.x), y = Int(origin.y)
        let content = "q .2 .7 .1 0 k \(x + 12) \(y + 400) 80 50 re f Q\nBT /F1 20 Tf \(x + 40) \(y + 100) Td (\(text)) Tj ET"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R \(outlineCount > 0 ? "/Outlines 6 0 R" : "") >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [\(x) \(y) \(x + width) \(y + 600)] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R \(pageExtra) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ]
        if outlineCount > 0 {
            objects.append("<< /Type /Outlines /First 7 0 R /Last \(6 + outlineCount) 0 R /Count \(outlineCount) >>")
            for index in 0..<outlineCount {
                let previous = index > 0 ? "/Prev \(index + 6) 0 R" : ""
                let next = index + 1 < outlineCount ? "/Next \(index + 8) 0 R" : ""
                objects.append("<< /Title (Section \(index)) /Parent 6 0 R \(previous) \(next) /Dest [3 0 R /Fit] >>")
            }
        }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    private func render(_ page: PDFPage) throws -> Data {
        let reference = try XCTUnwrap(page.pageRef), bounds = reference.getBoxRect(.mediaBox)
        let width = Int(bounds.width), height = Int(bounds.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(origin: .zero, size: bounds.size))
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.drawPDFPage(reference)
        return Data(bytes: try XCTUnwrap(context.data), count: width * height * 4)
    }
}
