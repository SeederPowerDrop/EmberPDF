// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import CPDFium
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFScannedBodyTextSafetyTests: XCTestCase {
    func testScanRejectsTwoColumnsInsideOneOCRObjectWithoutChangingSource() throws {
        // The control has the same image/OCR structure, but an ordinary word
        // gap. It must enter the scan editor, rather than returning nil because
        // the fixture has no scanned image or no selectable recognition layer.
        let control = try scanFixture(gap: 600)
        let controlPage = try XCTUnwrap(control.page(at: 0))
        let controlSelection = try leftSelection(on: controlPage)
        let controlTarget = try XCTUnwrap(PDFBodyTextEditor.target(on: controlPage, selection: controlSelection))
        XCTAssertEqual((controlTarget.text as NSString).substring(with: try XCTUnwrap(controlTarget.initialSelectedRange)), "LEFT")

        // A single TJ show is one PDFium text object even when its positioning
        // adjustment crosses a column gutter. Selecting LEFT must not promote
        // that whole object into a replacement covering the unrelated RIGHT.
        let source = try scanFixture(gap: 12_000)
        let page = try XCTUnwrap(source.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let originalText = page.string
        let selection = try leftSelection(on: page)
        try assertOneOCRObjectAndFullPageImage(in: before)

        XCTAssertThrowsError(try PDFBodyTextEditor.target(on: page, selection: selection)) { error in
            XCTAssertTrue(error is PDFScannedBodyTextEditor.Failure,
                          "The scan boundary must reject the cross-column object explicitly: \(error)")
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
        XCTAssertEqual(page.string, originalText)
        XCTAssertTrue(page.string?.contains("RIGHT") == true)
    }

    private func leftSelection(on page: PDFPage) throws -> PDFSelection {
        let text = try XCTUnwrap(page.string) as NSString
        let range = text.range(of: "LEFT")
        XCTAssertNotEqual(range.location, NSNotFound)
        let selection = try XCTUnwrap(page.selection(for: range))
        XCTAssertEqual(selection.string, "LEFT")
        return selection
    }

    private func assertOneOCRObjectAndFullPageImage(in data: Data) throws {
        // The earlier target lookup initialized PDFium on the main actor.
        try data.withUnsafeBytes { bytes in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(document) }
            let page = try XCTUnwrap(FPDF_LoadPage(document, 0))
            defer { FPDF_ClosePage(page) }
            XCTAssertEqual(FPDFPage_CountObjects(page), 2)
            let image = try XCTUnwrap(FPDFPage_GetObject(page, 0))
            let text = try XCTUnwrap(FPDFPage_GetObject(page, 1))
            XCTAssertEqual(FPDFPageObj_GetType(image), FPDF_PAGEOBJ_IMAGE)
            XCTAssertEqual(FPDFPageObj_GetType(text), FPDF_PAGEOBJ_TEXT)
            XCTAssertEqual(FPDFTextObj_GetTextRenderMode(text), FPDF_TEXTRENDERMODE_INVISIBLE)
            var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
            XCTAssertNotEqual(FPDFPageObj_GetBounds(image, &left, &bottom, &right, &top), 0)
            XCTAssertEqual(CGRect(x: CGFloat(left), y: CGFloat(bottom),
                                  width: CGFloat(right-left), height: CGFloat(top-bottom)),
                           CGRect(x: 0, y: 0, width: 300, height: 200))
            let textPage = try XCTUnwrap(FPDFText_LoadPage(page))
            defer { FPDFText_ClosePage(textPage) }
            let count = FPDFText_CountChars(textPage)
            XCTAssertGreaterThan(count, 4)
            XCTAssertEqual(FPDFText_GetTextObject(textPage, 0), text)
            XCTAssertEqual(FPDFText_GetTextObject(textPage, count-1), text)
        }
    }

    private func scanFixture(gap: Int) throws -> PDFDocument {
        let width = 600, height = 400
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 2, y: 2)
        context.textMatrix = .identity
        let font = try XCTUnwrap(NSFont(name: "Helvetica", size: 12))
        func line(_ text: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [.font: font, .foregroundColor: NSColor.black]))
        }
        let left = line("LEFT")
        context.textPosition = CGPoint(x: 30, y: 160)
        CTLineDraw(left, context)
        let advance = CGFloat(CTLineGetTypographicBounds(left, nil, nil, nil))
        context.textPosition = CGPoint(x: 30 + advance + CGFloat(gap)*12/1000, y: 160)
        CTLineDraw(line("RIGHT"), context)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 1.0]))

        let commands = "q 300 0 0 200 0 0 cm /Scan Do Q\nBT /F1 12 Tf 3 Tr 1 0 0 1 30 160 Tm [(LEFT) -\(gap) (RIGHT)] TJ ET\n"
        var image = Data("<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /DCTDecode /Length \(jpeg.count) >>\nstream\n".utf8)
        image.append(jpeg)
        image.append(Data("\nendstream".utf8))
        let objects = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> /XObject << /Scan 6 0 R >> >> /Contents 5 0 R >>".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
            Data("<< /Length \(commands.utf8.count) >>\nstream\n\(commands)endstream".utf8), image
        ]
        var data = Data("%PDF-1.7\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index+1) 0 obj\n".utf8))
            data.append(object)
            data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }
}
