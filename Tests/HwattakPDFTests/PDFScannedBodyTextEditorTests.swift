// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFScannedBodyTextEditorTests: XCTestCase {
    func testSecondRepeatedWordKeepsOriginalSelectionOffset() throws {
        let document=try fixture(),page=try XCTUnwrap(document.page(at:0))
        let selected=try XCTUnwrap(document.findString("repeat",withOptions:[]).last)
        let target=try XCTUnwrap(PDFBodyTextEditor.target(on:page,selection:selected))
        XCTAssertEqual(target.text,"repeat repeat next")
        XCTAssertEqual(target.initialSelectedRange,NSRange(location:7,length:6))
        XCTAssertTrue(page.annotations.isEmpty)
    }

    func testColoredScanEditPreservesOutsidePixelsAndCanBeEditedAfterSaving() throws {
        let document=try fixture(inlineMask:true),page=try XCTUnwrap(document.page(at:0))
        let original=try PDFBodyTextPageSnapshot.data(for:page)
        let selected=try XCTUnwrap(document.findString("repeat repeat next",withOptions:[]).first)
        let target=try XCTUnwrap(PDFBodyTextEditor.target(on:page,selection:selected))
        let edited=try PDFBodyTextEditor.replacementPage(for:page,target:target,
            text:"repeat repeat test",style:target.style,bounds:target.bounds)
        let exclusion=target.bounds.insetBy(dx:-8,dy:-8)
        XCTAssertEqual(try pixels(page,excluding:exclusion),try pixels(edited,excluding:exclusion))
        XCTAssertTrue(edited.annotations.isEmpty)
        XCTAssertEqual(try inkHeight(page),try inkHeight(edited),accuracy:2,
            "OCR's synthetic font size must not shrink the printed letters")
        let result=PDFDocument();result.insert(edited,at:0)
        XCTAssertEqual(result.findString("repeat repeat test",withOptions:[]).count,1)
        XCTAssertTrue(result.findString("repeat repeat next",withOptions:[]).isEmpty)
        XCTAssertEqual(result.findString("나머지 문장은 그대로",withOptions:[]).count,1)
        let saved=try XCTUnwrap(PDFDocument(data:PDFBodyTextPageSnapshot.data(for:edited)))
        let reopened=try XCTUnwrap(saved.page(at:0))
        let again=try XCTUnwrap(saved.findString("test",withOptions:[]).first)
        let next=try XCTUnwrap(PDFBodyTextEditor.target(on:reopened,selection:again))
        let changed=try PDFBodyTextEditor.replacementPage(for:reopened,target:next,
            text:next.text.replacingOccurrences(of:"test",with:"next"),style:next.style,bounds:next.bounds)
        let twice=PDFDocument();twice.insert(changed,at:0)
        XCTAssertEqual(twice.findString("repeat repeat next",withOptions:[]).count,1)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for:page),original)
    }

    func testSourceScanErasureIsDeclaredBeforeReplacementWithoutExtraMaskPadding() throws {
        let document = try fixture(inlineMask: true)
        let page = try XCTUnwrap(document.page(at: 0))
        let original = try PDFBodyTextPageSnapshot.data(for: page)
        let selected = try XCTUnwrap(document.findString("repeat repeat next", withOptions: []).first)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selected))
        let declared = target.paintBounds
        XCTAssertTrue(declared.contains(target.bounds))
        XCTAssertGreaterThan(declared.height, target.bounds.height)
        // Convert the predeclared rectangle to the exact intersecting raster
        // cells, as the existing declared-extent comparator does. No padding.
        let left = floor(declared.minX * 2), right = ceil(declared.maxX * 2)
        let bottom = floor(declared.minY * 2), top = ceil(declared.maxY * 2)
        let pixelFootprints = CGRect(x: left / 2, y: bottom / 2,
            width: (right - left) / 2, height: (top - bottom) / 2)
        let outsideBefore = try pixels(page, excluding: pixelFootprints)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "repeat repeat test", style: target.style, bounds: target.bounds)
        XCTAssertEqual(try pixels(edited, excluding: pixelFootprints), outsideBefore)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), original)
    }

    func testNormalScanErasureProofRequiresCurrentGeneratedPaperAndEveryPaintClip() throws {
        let original = Data(("q 400 0 0 300 0 0 cm /Scan Do Q\n"
            + "BT /F 18 Tf 3 Tr 1 0 0 1 40 200 Tm [] TJ ET\n").utf8)
        let media = CGRect(x: 0, y: 0, width: 400, height: 300)
        let rectangles = [CGRect(x: 35, y: 195, width: 180, height: 25)]
        let paper = PDFTextColor(red: 0.88, green: 0.94, blue: 0.91, alpha: 1)
        let emptyShow = try XCTUnwrap(original.range(of: Data("[]".utf8)))
        let program = try PDFScannedReadOrderContent.render(original, erasedRects: rectangles,
            mediaBox: media, paperColor: paper, insertionOffset: emptyShow.lowerBound, donorName: "Owned")
        func proves(_ candidate: Data, rows: [CGRect]? = nil) throws -> Bool {
            let metadata = try PDFScannedErasureMetadata(erasedRects: rows ?? rectangles,
                paperColor: paper, program: candidate)
            let parsed = try PDFBodyTextContentStream.parse(candidate)
            let donor = try XCTUnwrap(parsed.forms.first(where: { $0.name == "Owned" }))
            return try metadata.provesCurrentProgram(candidate, mediaBox: media,
                donorName: donor.name, donorRange: donor.showRange)
        }
        let before = program
        XCTAssertTrue(try proves(program))
        // Recompute the digest for every negative: a self-consistent marker
        // must not authorize an image without the exact exclusion geometry.
        let text = try XCTUnwrap(String(data: program, encoding: .utf8))
        XCTAssertFalse(try proves(Data(text.replacingOccurrences(of: "W* n", with: "W n").utf8)))
        XCTAssertFalse(try proves(program + Data("\n/Scan Do\n".utf8)))
        XCTAssertFalse(try proves(program + Data("\n0 0 5 5 re f\n".utf8)))
        XCTAssertFalse(try proves(Data(text.replacingOccurrences(of: "3 Tr", with: "7 Tr").utf8)))
        XCTAssertFalse(try proves(program + Data("\n/Owned Do\n".utf8)))
        XCTAssertFalse(try proves(program, rows: [rectangles[0].insetBy(dx: -1, dy: -1)]))
        XCTAssertEqual(program, before)
    }

    func testNormalScanErasureMetadataRejectsOversizedAndInvalidRowDescriptions() throws {
        let color = PDFTextColor(red: 1, green: 1, blue: 1, alpha: 1)
        XCTAssertThrowsError(try PDFScannedErasureMetadata(erasedRects: [],
            paperColor: color, program: Data()))
        XCTAssertThrowsError(try PDFScannedErasureMetadata(
            erasedRects: (0..<65).map { CGRect(x: CGFloat($0 * 2), y: 0, width: 1, height: 1) },
            paperColor: color, program: Data()))
        XCTAssertThrowsError(try PDFScannedErasureMetadata.decode(
            Data(repeating: 32, count: PDFScannedErasureMetadata.maximumBytes + 1)))
    }

    func testMovedCurrentDonorCannotBorrowUnchangedParentErasureDigest() throws {
        let safe = try generatedNormalDonor(x: 50)
        let moved = try generatedNormalDonor(x: 260)
        XCTAssertEqual(safe.program, moved.program, "Only the current Form text position is altered")
        XCTAssertEqual(safe.metadata, moved.metadata, "The original parent digest is retained")
        XCTAssertTrue(try generatedNormalDonorUsesErasure(safe.data, bounds: safe.bounds))
        XCTAssertFalse(try generatedNormalDonorUsesErasure(moved.data, bounds: moved.bounds))
    }

    func testNormalDonorErasureRejectsHiddenType3AndUnsafeInheritedGraphicsState() throws {
        let safe = try generatedNormalDonor(x: 50)
        XCTAssertTrue(try generatedNormalDonorUsesErasure(safe.data, bounds: safe.bounds))
        for candidate in [try generatedNormalDonor(x: 50, hiddenType3: true),
                          try generatedNormalDonor(x: 50, unsafeGS: true),
                          try generatedNormalDonor(x: 50, donorClip: true),
                          try generatedNormalDonor(x: 50, donorGroup: true),
                          try generatedNormalDonor(x: 50, resetControls: "/AIS true /TK true /SA false"),
                          try generatedNormalDonor(x: 50, resetControls: "/AIS false /TK false /SA false"),
                          try generatedNormalDonor(x: 50, resetControls: "/AIS false /TK true /SA true")] {
            // These have internally consistent marker/program digests; the
            // resource-bound native proof, rather than a checksum, must refuse.
            XCTAssertFalse(try generatedNormalDonorUsesErasure(candidate.data, bounds: candidate.bounds))
        }
    }

    private func generatedNormalDonorUsesErasure(_ data: Data, bounds: CGRect) throws -> Bool {
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString("OWNED", withOptions: []).first)
        // Refusal or the ordinary non-expanding obstacle route is safe. It
        // must never grant the old erasure rectangle to changed current ink.
        return (try? PDFBodyTextEditor.target(on: page, selection: selection))?.paintBounds == bounds
    }

    private func generatedNormalDonor(x: Int, hiddenType3: Bool = false, unsafeGS: Bool = false,
                                     donorClip: Bool = false, donorGroup: Bool = false,
                                     resetControls: String = "/AIS false /TK true /SA false")
        throws -> (data: Data, program: Data, metadata: Data, bounds: CGRect) {
        let source = Data(("q 400 0 0 300 0 0 cm /Scan Do Q\n"
            + (unsafeGS ? "/Unsafe gs\n" : "")
            + "BT /Hidden 10 Tf 3 Tr 1 0 0 1 50 200 Tm [] TJ\n"
            + "1 0 0 1 15 20 Tm (X) Tj ET\n").utf8)
        // The renderer consumes the removal planner's exact empty TJ slot.
        // A separate retained show keeps the Type3+Tr3 hazard reachable.
        let show = try XCTUnwrap(source.range(of: Data("[]".utf8)))
        let media = CGRect(x: 0, y: 0, width: 400, height: 300)
        let rows = [CGRect(x: 35, y: 190, width: 180, height: 35)]
        let paper = PDFTextColor(red: 1, green: 1, blue: 1, alpha: 1)
        let program = try PDFScannedReadOrderContent.render(source, erasedRects: rows,
            mediaBox: media, paperColor: paper, insertionOffset: show.lowerBound, donorName: "Owned")
        let hint = try PDFScannedErasureMetadata(erasedRects: rows, paperColor: paper, program: program)
        let parsed = try PDFBodyTextContentStream.parse(program)
        let invocation = try XCTUnwrap(parsed.forms.first(where: { $0.name == "Owned" }))
        XCTAssertTrue(try hint.provesCurrentProgram(program, mediaBox: media,
            donorName: invocation.name, donorRange: invocation.showRange),
            "Every variant must reach the independently current donor/resource checks, not fail fixture construction.")
        XCTAssertNotNil(program.range(of: Data("(X) Tj".utf8)), "The hidden-font hazard must remain a real show.")
        let metadata = try hint.encoded()
        let marker = metadata.map { String(format: "%02x", $0) }.joined()
        let donor = "/Reset gs " + (donorClip ? "q 0 0 400 300 re W n " : "")
            + "BT /F1 18 Tf 0 Tr 1 0 0 1 \(x) 200 Tm (OWNED) Tj ET"
            + (donorClip ? " Q" : "")
        let group = donorGroup ? " /Group << /S /Transparency /CS /DeviceRGB >>" : ""
        let reset = "<< /Type /ExtGState /CA 1 /ca 1 /BM /Normal /SMask /None /TR /Identity /TR2 /Identity /op false /OP false /OPM 0 \(resetControls) >>"
        let type3 = "500 0 0 0 500 700 d1 0 0 500 700 re f"
        let hidden = hiddenType3
            ? "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 500 700] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /X 9 0 R >> /Encoding << /Type /Encoding /Differences [88 /X] >> /FirstChar 88 /LastChar 88 /Widths [500] /Resources << >> >>"
            : "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /Hidden 8 0 R >> /ExtGState << /Unsafe << /BM /Multiply >> >> /XObject << /Scan 6 0 R /Owned 7 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(program.count) >>\nstream\n\(String(decoding: program, as: UTF8.self))\nendstream",
            "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Length 1 >>\nstream\nx\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 400 300] /EmberPDFBodyText true /EmberPDFScannedErasure <\(marker)>\(group) /Resources << /Font << /F1 4 0 R >> /ExtGState << /Reset \(reset) >> >> /Length \(donor.utf8.count) >>\nstream\n\(donor)\nendstream",
            hidden,
            "<< /Length \(type3.utf8.count) >>\nstream\n\(type3)\nendstream"
        ]
        return (PDFMalformedSelectionTestFixture.pdfData(objects: objects), program, metadata, rows[0])
    }

    func testPictureBetweenOCRWordsIsRejectedWithoutChangingThePage() throws {
        let document=try fixture(picture:true),page=try XCTUnwrap(document.page(at:0))
        let original=try PDFBodyTextPageSnapshot.data(for:page)
        let selected=try XCTUnwrap(page.selection(for:CGRect(x:35,y:195,width:300,height:30)))
        XCTAssertThrowsError(try PDFBodyTextEditor.target(on:page,selection:selected))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for:page),original)
    }

    func testLongReplacementCannotCoverUnselectedScanContent() throws {
        let document=try fixture(),page=try XCTUnwrap(document.page(at:0))
        let selected=try XCTUnwrap(document.findString("repeat",withOptions:[]).first)
        let target=try XCTUnwrap(PDFBodyTextEditor.target(on:page,selection:selected))
        XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for:page,target:target,
            text:String(repeating:"longer ",count:20),style:target.style,bounds:target.bounds))
    }

    private func inkHeight(_ page:PDFPage)throws->Double {
        let width=800,height=600
        var pixels=[UInt8](repeating:255,count:width*height*4)
        try pixels.withUnsafeMutableBytes {raw in
            let context=try XCTUnwrap(CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))
            context.scaleBy(x:2,y:2);context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        var rows:[Int]=[]
        for y in 380..<450 {
            let dark=(70..<500).filter {x in let i=((height-y-1)*width+x)*4;return pixels[i]<120 && pixels[i+1]<120 && pixels[i+2]<120}.count
            if dark>=2 {rows.append(y)}
        }
        return Double(try XCTUnwrap(rows.last)-XCTUnwrap(rows.first)+1)
    }

    private func fixture(picture:Bool=false,inlineMask:Bool=false)throws->PDFDocument {
        let bounds=CGRect(x:0,y:0,width:400,height:300)
        let rgb=CGColorSpaceCreateDeviceRGB()
        let bitmap=try XCTUnwrap(CGContext(data:nil,width:800,height:600,bitsPerComponent:8,
            bytesPerRow:0,space:rgb,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.scaleBy(x:2,y:2)
        bitmap.setFillColor(NSColor(srgbRed:0.88,green:0.94,blue:0.91,alpha:1).cgColor);bitmap.fill(bounds)
        let font=NSFont(name:"Helvetica",size:20)!
        let text=picture ? "repeat    next" : "repeat repeat next"
        let line=CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[.font:font,.foregroundColor:NSColor.black]))
        bitmap.textPosition=CGPoint(x:40,y:200);CTLineDraw(line,bitmap)
        if picture {bitmap.setFillColor(NSColor.red.cgColor);bitmap.fill(CGRect(x:105,y:202,width:10,height:10))}
        // A second line verifies that removing the first recognition object
        // cannot change the appearance or searchability of other content.
        let lower=CTLineCreateWithAttributedString(NSAttributedString(string:"나머지 문장은 그대로",attributes:[.font:NSFont(name:"AppleSDGothicNeo-Regular",size:20)!, .foregroundColor:NSColor.black]))
        bitmap.textPosition=CGPoint(x:40,y:130);CTLineDraw(lower,bitmap)
        let image=try XCTUnwrap(bitmap.makeImage()),data=NSMutableData()
        let consumer=try XCTUnwrap(CGDataConsumer(data:data as CFMutableData));var box=bounds
        let pdf=try XCTUnwrap(CGContext(consumer:consumer,mediaBox:&box,nil))
        pdf.beginPDFPage(nil);pdf.draw(image,in:bounds)
        pdf.setTextDrawingMode(.invisible)
        pdf.textPosition=CGPoint(x:40,y:200);CTLineDraw(line,pdf)
        pdf.textPosition=CGPoint(x:40,y:130);CTLineDraw(lower,pdf)
        pdf.endPDFPage();pdf.closePDF()
        let document=try XCTUnwrap(PDFDocument(data:data as Data))
        guard inlineMask else{return document}
        let page=try XCTUnwrap(document.page(at:0))
        var content=Data("q BI /W 1 /H 1 /IM true /BPC 1 ID ".utf8)
        content.append(0);content.append(Data(" EI Q\n".utf8))
        content.append(try PDFBodyTextPageSnapshot.contentData(for:page))
        return try XCTUnwrap(PDFDocument(data:PDFBodyTextPageSnapshot.data(for:page,contentOverride:content)))
    }

    private func pixels(_ page:PDFPage,excluding rectangle:CGRect)throws->Data {
        let w=800,h=600
        var bytes=[UInt8](repeating:255,count:w*h*4)
        try bytes.withUnsafeMutableBytes {raw in
            let context=try XCTUnwrap(CGContext(data:raw.baseAddress,width:w,height:h,bitsPerComponent:8,
                bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:w,height:h))
            context.scaleBy(x:2,y:2);context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        var result=Data()
        for y in 0..<h {for x in 0..<w where !rectangle.contains(CGPoint(x:Double(x)/2,y:Double(y)/2)) {
            let offset=((h-y-1)*w+x)*4;result.append(contentsOf:bytes[offset..<offset+4])
        }}
        return result
    }
}
