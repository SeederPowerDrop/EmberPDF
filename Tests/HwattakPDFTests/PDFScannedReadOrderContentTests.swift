// SPDX-License-Identifier: MPL-2.0

import AppKit
import CPDFium
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFScannedReadOrderContentTests: XCTestCase {
    func testPositiveAncestorClipRequiresTheExactCurrentDeclarationAndSingleInvocation() throws {
        let source = "q 300 0 0 200 0 0 cm /Scan Do Q\nBT /F1 10 Tf 3 Tr [] TJ ET\n"
        let raw = Data(source.utf8),offset = try XCTUnwrap(source.range(of:"[] TJ")).lowerBound.utf16Offset(in:source)
        let rows = [CGRect(x:40,y:115,width:30,height:15)],media = CGRect(x:0,y:0,width:300,height:200)
        func generated(_ positive: Bool) throws -> Data {
            try PDFScannedReadOrderContent.render(raw,erasedRects:rows,mediaBox:media,paperColor:.white,
                insertionOffset:offset,donorName:"Owned",clipDonorToErasure:positive)
        }
        func check(_ program: Data,rectangles: [CGRect] = [],required: Bool = true) throws -> Bool {
            let forms = try PDFBodyTextContentStream.parse(program).forms.filter { $0.name == "Owned" }
            guard let form = forms.first else { return false }
            let metadata = try PDFScannedErasureMetadata(erasedRects:rectangles.isEmpty ? rows : rectangles,
                paperColor:.white,program:program)
            return try metadata.provesCurrentProgram(program,mediaBox:media,donorName:"Owned",donorRange:form.showRange,
                requiringPositiveDonorClip:required)
        }
        let positive = try generated(true),legacy = try generated(false)
        XCTAssertTrue(try check(positive))
        XCTAssertTrue(try check(legacy,required:false))
        XCTAssertFalse(try check(legacy),"Legacy clipping must not mint the new positive ancestor witness.")
        XCTAssertFalse(try check(positive,rectangles:[CGRect(x:40,y:115,width:30,height:14.999)]),
            "Even freshly recomputed metadata cannot change the literal erasure union.")
        var duplicate = positive; duplicate.append(Data("/Owned Do\n".utf8))
        XCTAssertEqual(try PDFBodyTextContentStream.parse(duplicate).forms.filter { $0.name == "Owned" }.count,2)
        XCTAssertFalse(try check(duplicate))
        var sibling = positive; sibling.append(Data("/Other Do\n".utf8))
        XCTAssertEqual(try PDFBodyTextContentStream.parse(sibling).forms.filter { $0.name == "Other" }.count,1)
        XCTAssertFalse(try check(sibling),"A second unwrapped paint must not borrow the sole donor's declaration.")
    }

    func testPositiveErasureClipOwnsOnlyOneGeneratedDonorAcrossRawReedit() throws {
        let source = "q 300 0 0 200 0 0 cm /Scan Do Q\nBT /F1 10 Tf 3 Tr 1 0 0 1 40 120 Tm [] TJ ET\n"
        let raw = Data(source.utf8),offset = try XCTUnwrap(source.range(of:"[] TJ")).lowerBound.utf16Offset(in:source)
        let rows = [CGRect(x:40,y:115,width:30,height:15)],media = CGRect(x:0,y:0,width:300,height:200)
        let corners = [CGPoint(x:40,y:115),CGPoint(x:70,y:115),CGPoint(x:70,y:130),CGPoint(x:40,y:130)]
        var clip = "q\n"
        for (index,point) in corners.enumerated() {
            clip += try PDFDecimalNumber.string(point.x)+" "+PDFDecimalNumber.string(point.y)+" "+(index == 0 ? "m" : "l")+"\n"
        }
        clip += "h\nW n\n"
        func render(clipped: Bool) throws -> Data {
            try PDFScannedReadOrderContent.render(raw,erasedRects:rows,mediaBox:media,paperColor:.white,
                insertionOffset:offset,donorName:"Owned",clipDonorToErasure:clipped)
        }
        func proves(_ program: Data,name: String = "Owned") throws -> Bool {
            let parsed = try PDFBodyTextContentStream.parse(program)
            let forms = parsed.forms.filter { $0.name == name }
            guard forms.count == 1,let form = forms.first else { return false }
            // Recompute the marker digest deliberately: these negatives test
            // the independent grammar, rather than just a stale digest.
            let metadata = try PDFScannedErasureMetadata(erasedRects:rows,paperColor:.white,program:program)
            return try metadata.provesCurrentProgram(program,mediaBox:media,donorName:name,donorRange:form.showRange)
        }
        let generated = try render(clipped:true)
        let generatedString = String(decoding:generated,as:UTF8.self)
        XCTAssertEqual(generatedString.components(separatedBy:clip).count-1,1,
            "The known positive prefix must actually occur once before testing its scope.")
        XCTAssertTrue(try proves(generated))
        let parsed = try PDFBodyTextContentStream.parse(generated)
        let ordinal = try XCTUnwrap(parsed.forms.firstIndex { $0.name == "Owned" })
        let coldRewrite = try parsed.rewritingForms(recordIndices:[ordinal],donorInvocation:"q 1 0 0 1 0 0 cm /Next Do Q")
        XCTAssertTrue(try proves(coldRewrite,name:"Next"),"The existing whole-Form rewrite stays inside its original exact positive union.")
        let legacy = String(decoding:try render(clipped:false),as:UTF8.self)
        XCTAssertTrue(try proves(Data(legacy.utf8)),"Existing un-clipped generated programs retain their independent native proof contract.")
        let paperEnd = try XCTUnwrap(legacy.range(of:"re f\nQ\n")).upperBound
        let paper = String(legacy[..<paperEnd]),body = String(legacy[paperEnd...])
        let forged = [
            paper+clip+body+"Q\n", // original image/exclusion paint inside positive union
            paper+clip+"Q\n"+body, // empty positive union
            legacy.replacingOccurrences(of:"/Owned Do",with:clip+clip+"/Owned Do\nQ\nQ"),
            legacy.replacingOccurrences(of:"/Owned Do",with:clip+"BT /F1 10 Tf 3 Tr (X) Tj ET /Owned Do\nQ"),
            generatedString.replacingOccurrences(of:clip,
                with:clip.replacingOccurrences(of:"40.0 115.0 m",with:"39.0 115.0 m"))
        ]
        XCTAssertEqual(clip.components(separatedBy:"40.0 115.0 m").count-1,1)
        for (index,program) in forged.enumerated() {
            XCTAssertNotEqual(program,index == 4 ? generatedString : legacy,"Every mutation must change its actual source program.")
            if index < 4 { XCTAssertTrue(program.contains(clip),"Scope negatives must use the recognized writer prefix.") }
            XCTAssertFalse(try proves(Data(program.utf8)),"Forged positive-clip scope \(index) cannot grant metadata authority.")
        }
    }

    func testTransformedImagesBeforeAndAfterTheOCRKeepOutsidePixelsAndReplacementInk() throws {
        let content = "q 100 12 -8 100 4 -3 cm /Scan Do Q\n"
            + "q .9 .12 .08 1.05 4 -2 cm BT /OCR 10 Tf 3 Tr 2 Tc 4 Tw 90 Tz 13 TL 3 Ts "
            + "1 .2 -.1 1 10 70 Tm (KeepA) Tj 10 -15 TD [] TJ 0 -15 Td (KeepB) Tj ET Q\n"
            + "q 90 -6 10 95 2 3 cm /Scan Do Q\n"
        let raw = Data(content.utf8)
        let offset = try XCTUnwrap(content.range(of: "[] TJ")).lowerBound.utf16Offset(in: content)
        let erase = CGRect(x: 18, y: 38, width: 40, height: 26)
        let replaced = try PDFScannedReadOrderContent.render(raw, erasedRects: [erase],
            mediaBox: CGRect(x: 0, y: 0, width: 100, height: 100), paperColor: .white,
            insertionOffset: offset, donorName: "NewText")
        let before = try fixture(raw), after = try fixture(replaced)
        XCTAssertEqual(before.findString("KeepB", withOptions: []).first?.bounds(for: before.page(at: 0)!),
                       after.findString("KeepB", withOptions: []).first?.bounds(for: after.page(at: 0)!),
            "ET/BT around the Form must retain the source line matrix, leading and all text state.")
        let original = try pixels(before.page(at: 0)!), output = try pixels(after.page(at: 0)!)
        var changed = 0, outside = 0
        for y in 0..<200 { for x in 0..<200 {
            let index = (y * 200 + x) * 4
            if original[index..<(index + 4)] != output[index..<(index + 4)] {
                changed += 1
                let point = CGPoint(x: (CGFloat(x) + 0.5) / 2, y: 100 - (CGFloat(y) + 0.5) / 2)
                if !erase.contains(point) { outside += 1 }
            }
        } }
        XCTAssertGreaterThan(changed, 100)
        XCTAssertEqual(outside, 0)
        let bluePixel = ((200 - 1 - 90) * 200 + 50) * 4
        XCTAssertEqual(Array(output[bluePixel..<(bluePixel + 3)]), [0, 0, 255],
            "An image painted later in the source must not cover the new text paths.")
        XCTAssertEqual(before.pageCount, 1)
        XCTAssertEqual(after.pageCount, 1)
    }

    func testPendingPathsAndMarkedAnchorsAreRejected() throws {
        for source in ["0 0 m BT /F 12 Tf 3 Tr [] TJ ET",
                       "/Span BMC BT /F 12 Tf 3 Tr [] TJ ET EMC"] {
            let offset = try XCTUnwrap(source.range(of: "[] TJ")).lowerBound.utf16Offset(in: source)
            XCTAssertThrowsError(try PDFScannedReadOrderContent.render(Data(source.utf8),
                erasedRects: [CGRect(x: 10, y: 10, width: 20, height: 10)],
                mediaBox: CGRect(x: 0, y: 0, width: 100, height: 100), paperColor: .white,
                insertionOffset: offset, donorName: "NewText"))
        }
    }

    func testInheritedClipMustContainTheCompleteReplacementArea() throws {
        let text = "BT /F 12 Tf 3 Tr [] TJ ET"
        for (clip, accepted) in [("0 0 100 100 re W n ", true),
                                  ("0 0 15 15 re W n ", false),
                                  ("0 0 0 0 re W n ", false),
                                  ("0 0 m 100 0 l 100 100 l h W n ", false),
                                  ("q 0 0 15 15 re W n Q ", true)] {
            let source = clip + text
            let offset = try XCTUnwrap(source.range(of: "[] TJ")).lowerBound.utf16Offset(in: source)
            do {
                _ = try PDFScannedReadOrderContent.render(Data(source.utf8),
                    erasedRects: [CGRect(x: 20, y: 40, width: 20, height: 10)],
                    mediaBox: CGRect(x: 0, y: 0, width: 100, height: 100), paperColor: .white,
                    insertionOffset: offset, donorName: "NewText")
                XCTAssertTrue(accepted, "A restricted or unproven clip must not silently crop replacement glyphs.")
            } catch { XCTAssertFalse(accepted) }
        }
    }

    func testClippedBackgroundProtectsOnlyItsConservativePaintBounds() throws {
        let source = "q 20 20 30 30 re W n 30 25 10 15 re W n 0 0 100 100 re f Q"
        try withNativePath(source) { object, _ in
            XCTAssertEqual(PDFScannedBodyTextEditor.conservativePaintBounds(of: object),
                CGRect(x: 30, y: 25, width: 10, height: 15))
        }
        let curve = "q 10 10 m 0 30 90 30 80 10 c 10 10 l h W n 0 0 100 100 re f Q"
        try withNativePath(curve) { object, _ in
            XCTAssertEqual(PDFScannedBodyTextEditor.conservativePaintBounds(of: object),
                CGRect(x: 0, y: 10, width: 90, height: 20),
                "All curve control points must protect a conservative bound, even beyond the curve's ink.")
        }
        let transformed = "q 2 0 0 2 0 0 cm 10 10 10 10 re W n 0 0 100 100 re f Q"
        try withNativePath(transformed) { object, _ in
            XCTAssertEqual(PDFScannedBodyTextEditor.conservativePaintBounds(of: object),
                CGRect(x: 0, y: 0, width: 200, height: 200),
                "An unproven clip coordinate system must retain the wider raw protection.")
        }
    }

    func testReplacementValidatesVisibleOutlineClipRatherThanEmptySemanticInk() throws {
        var source = PDFScannedBodyTextEditor.Source(snapshot: Data(), rootIndices: [],
            erasedRects: [CGRect(x: 20, y: 30, width: 15, height: 12)], paperColor: .white)
        source.semanticFontName = "OCR"
        for (clip, accepted) in [("20 30 15 12 re", true), ("20 30 16 12 re", false)] {
            try withNativePath("q \(clip) W n 0 0 100 100 re f Q") { _, page in
                XCTAssertEqual(PDFScannedBodyTextEditor.replacementFits(page, source: source), accepted)
            }
        }
        try withNativePath("q 0 0 100 100 re f Q") { _, page in
            XCTAssertFalse(PDFScannedBodyTextEditor.replacementFits(page, source: source))
        }
    }

    func testPreviouslyVerifiedDisjointFormsKeepTheirInvocationUnclipped() throws {
        let kept = "q 1 0 0 1 0 0 cm\n%keep-start\n/Owned1 Do\n%keep-end\nQ"
        let source = "/Scan Do\n" + kept + "\n/Foreign Do\nBT /F 12 Tf 3 Tr [] TJ ET"
        let offset = try XCTUnwrap(source.range(of: "[] TJ")).lowerBound.utf16Offset(in: source)
        let result = try PDFScannedReadOrderContent.render(Data(source.utf8),
            erasedRects: [CGRect(x: 20, y: 40, width: 20, height: 10)],
            mediaBox: CGRect(x: 0, y: 0, width: 100, height: 100), paperColor: .white,
            insertionOffset: offset, donorName: "NewText", preservedFormNames: ["Owned1"])
        let content = try XCTUnwrap(String(data: result, encoding: .utf8))
        XCTAssertTrue(content.contains(kept))
        XCTAssertEqual(content.components(separatedBy: "W* n").count - 1, 2,
            "The scan and unverified Form still require the erasure clip.")
    }

    private func withNativePath(_ content: String,
                                body: (FPDF_PAGEOBJECT, FPDF_PAGE) throws -> Void) throws {
        let document = try fixture(Data(content.utf8))
        let page = try XCTUnwrap(document.page(at: 0))
        // Initialize PDFium through its main-actor editor owner.
        _ = try PDFBodyTextEditor.target(on: page, at: CGPoint(x: 5, y: 5))
        let data = try PDFBodyTextPageSnapshot.data(for: page)
        try data.withUnsafeBytes { buffer in
            let nativeDocument = try XCTUnwrap(FPDF_LoadMemDocument64(buffer.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(nativeDocument) }
            let nativePage = try XCTUnwrap(FPDF_LoadPage(nativeDocument, 0))
            defer { FPDF_ClosePage(nativePage) }
            XCTAssertEqual(FPDFPage_CountObjects(nativePage), 1)
            let object = try XCTUnwrap(FPDFPage_GetObject(nativePage, 0))
            try body(object, nativePage)
        }
        XCTAssertEqual(document.pageCount, 1)
    }

    private func pixels(_ page: PDFPage) throws -> Data {
        var bytes = Data(repeating: 255, count: 200 * 200 * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 200, height: 200,
                bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            context.scaleBy(x: 2, y: 2)
            context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        return bytes
    }

    private func fixture(_ content: Data) throws -> PDFDocument {
        let donor = Data("q 0 0 1 rg 20 40 12 12 re f Q".utf8)
        let image = Data([240, 90, 30, 30, 200, 60, 60, 80, 220, 180, 170, 30])
        func stream(_ dictionary: String, _ data: Data) -> Data {
            var result = Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)
            result.append(data)
            result.append(Data("\nendstream".utf8))
            return result
        }
        let objects = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Font << /OCR 4 0 R >> /XObject << /Scan 6 0 R /NewText 7 0 R >> >> /Contents 5 0 R >>".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
            stream("", content),
            stream("/Type /XObject /Subtype /Image /Width 2 /Height 2 /BitsPerComponent 8 /ColorSpace /DeviceRGB", image),
            stream("/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources << >>", donor)
        ]
        var result = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(result.count)
            result.append(Data("\(index + 1) 0 obj\n".utf8)); result.append(object)
            result.append(Data("\nendobj\n".utf8))
        }
        let xref = result.count
        result.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { result.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        result.append(Data("trailer << /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: result))
    }
}
