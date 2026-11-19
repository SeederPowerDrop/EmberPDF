// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import CPDFium
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFScannedBodyTextRecognitionGeometryTests: XCTestCase {
    func testOwnedScanAncestorWitnessEndsWithItsExactNativeScopeAndRestoresNestedScopes() throws {
        let original = try fixture(),page = try XCTUnwrap(original.page(at:0))
        let before = try PDFBodyTextPageSnapshot.data(for:page)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on:page,selection:selectedRows(on:page)))
        let text = target.text.replacingOccurrences(of:"alpha",with:"alpho")
        let edited = try PDFBodyTextEditor.replacementPage(for:page,target:target,text:text,
            style:target.style,bounds:target.bounds)
        let owned = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(
            data:PDFBodyTextPageSnapshot.data(for:edited)))
        let cold = try XCTUnwrap(owned.page(at:0))
        let checks = try PDFBodyTextEditor.scannedAncestorScopeChecksForTesting(on:cold,unrelated:page)
        XCTAssertEqual(checks,[true,true,true,true,true,true,true,true],
            "A real admitted owned Form must not authorize another native page, root or expired/nested scope.")
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for:page),before)
    }

    func testMeasuredScanCorridorKeepsFourEdgesAndExactTouchingUnion() throws {
        let area = CGRect(x:10,y:10,width:20,height:10)
        func offsets(_ box: CGRect,_ areas: [CGRect] = []) throws -> [ClosedRange<CGFloat>]? {
            try PDFScannedInkPlacement.corridor(.init(geometry:[box],paintedRows:[box]),
                erasedRects:areas.isEmpty ? [area] : areas)
        }
        XCTAssertEqual(try offsets(CGRect(x:11,y:9.5,width:18,height:10)),[0.5...0.5])
        XCTAssertEqual(try offsets(CGRect(x:11,y:10.5,width:18,height:10)),[-0.5...(-0.5)])
        XCTAssertNil(try offsets(CGRect(x:9.5,y:11,width:20,height:8)),"No vertical adjustment can authorize ink across the left edge.")
        XCTAssertNil(try offsets(CGRect(x:10.5,y:11,width:20,height:8)),"No vertical adjustment can authorize ink across the right edge.")
        let glyph = CGRect(x:11,y:11,width:18,height:8)
        XCTAssertTrue(try XCTUnwrap(offsets(glyph,[CGRect(x:10,y:10,width:20,height:5),
            CGRect(x:10,y:15,width:20,height:5)])).contains { $0.contains(0) })
        XCTAssertNil(try offsets(glyph,[CGRect(x:10,y:10,width:20,height:4.999),
            CGRect(x:10,y:15,width:20,height:5)]),"A nonzero hole cannot be bridged by a fit tolerance.")
        XCTAssertNil(try offsets(glyph,[CGRect(x:10,y:10,width:10,height:5),
            CGRect(x:10,y:15,width:20,height:5)]),"A shorter row cannot grant its missing suffix.")
    }

    func testMeasuredScanCorridorUsesOneTranslationForEveryRow() throws {
        let rows = [CGRect(x:10,y:10,width:20,height:10),CGRect(x:10,y:30,width:20,height:10)]
        let lowerNeedsUp = CGRect(x:11,y:9.5,width:18,height:10)
        let upperNeedsDown = CGRect(x:11,y:30.5,width:18,height:10)
        XCTAssertNil(try PDFScannedInkPlacement.corridor(.init(geometry:[lowerNeedsUp,upperNeedsDown],
            paintedRows:[lowerNeedsUp,upperNeedsDown]),erasedRects:rows),
            "Independent per-line shifts would silently change the source baseline grid.")
        let upperNeedsUp = CGRect(x:11,y:29.5,width:18,height:10)
        let allowed = try XCTUnwrap(PDFScannedInkPlacement.corridor(.init(geometry:[lowerNeedsUp,upperNeedsUp],
            paintedRows:[lowerNeedsUp,upperNeedsUp]),erasedRects:rows))
        XCTAssertEqual(allowed,[0.5...0.5])
    }

    func testGeneratedScanDonorMeasuresActualAlphaAndRefusesEachOutsideEdge() throws {
        let bootstrap = try fixture(),page = try XCTUnwrap(bootstrap.page(at:0))
        _ = try XCTUnwrap(PDFBodyTextEditor.target(on:page,selection:selectedRows(on:page)))
        let style = InlineTextStyle(fontName:"Helvetica",fontSize:12,textColor:.black,
            backgroundColor:.clear,alignment:.left)
        let donor = try PDFBodyTextEditor.scannedSourceDonor("HH",style:style,
            bounds:CGRect(x:40,y:110,width:40,height:20),mediaBox:CGRect(x:0,y:0,width:300,height:200),
            visibleBox:CGRect(x:0,y:0,width:300,height:200),baseline:CGPoint(x:40,y:120),
            lineHeight:nil,firstLineIndent:0,sourceRuns:[])
        let measured = try PDFScannedInkPlacement.measure(donor)
        let support = (measured.geometry+measured.paintedRows).reduce(CGRect.null) { $0.union($1) }
        XCTAssertFalse(measured.paintedRows.isEmpty)
        let padded = support.insetBy(dx:-0.5,dy:-0.5)
        XCTAssertTrue(try PDFScannedInkPlacement.fits(donor,erasedRects:[padded]))
        let cuts = [CGRect(x:support.minX+0.001,y:padded.minY,width:padded.maxX-support.minX-0.001,height:padded.height),
            CGRect(x:padded.minX,y:padded.minY,width:support.maxX-padded.minX-0.001,height:padded.height),
            CGRect(x:padded.minX,y:support.minY+0.001,width:padded.width,height:padded.maxY-support.minY-0.001),
            CGRect(x:padded.minX,y:padded.minY,width:padded.width,height:support.maxY-padded.minY-0.001)]
        for cut in cuts { XCTAssertFalse(try PDFScannedInkPlacement.fits(donor,erasedRects:[cut])) }
    }

    func testZeroRimScanKeepsExactOutsideAcrossTwoAtomicColdEditsAndScales() async throws {
        for upper in [false,true] {
            do {
            let value = try sourceComponentPrecisionFixture(upper:upper,crossing:false)
            let original = try XCTUnwrap(value.fixture.document.page(at:0))
            try assertSourceComponentPrecisionPreconditions(value,page:original)
            guard try sourceComponentAssertHeightPrerequisite(original,ocr:value.fixture.ocrBounds,
                fontSize:value.fontSize,text:"HHH",upper:upper) else { continue }
            let originalData = try PDFBodyTextPageSnapshot.data(for:original)
            var current = value.fixture.document
            var target = try sourceComponentTarget(original,text:"HHH")
            let extent = target.paintBounds,initialFontSize = target.style.fontSize
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EmberScanCorridor-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            var complete = false
            defer { if complete { try? FileManager.default.removeItem(at:folder) } else { print("EMBER_SCAN_CORRIDOR_FAILED_OUTPUTS",folder.path) } }
            for (cycle,newText) in ["H","HH"].enumerated() {
                let page = try XCTUnwrap(current.page(at:0))
                let edited = try PDFBodyTextEditor.replacementPage(for:page,target:target,text:newText,
                    style:target.style,bounds:target.bounds)
                let live = PDFDocument();live.insert(edited,at:0)
                let snapshot = try PDFRecoverySnapshot(capturing:live)
                let path = folder.appendingPathComponent("cycle-\(cycle).pdf")
                _ = try await Task.detached { try AtomicPDFWriter.write(snapshot.takeDocument(),to:path) }.value
                PDFBodyTextDocumentFonts.invalidate(current);PDFBodyTextDocumentFonts.invalidate(live)
                current = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data:Data(contentsOf:path)))
                let reopened = try XCTUnwrap(current.page(at:0))
                XCTAssertEqual(reopened.string?.trimmingCharacters(in:.whitespacesAndNewlines),newText)
                target = try sourceComponentTarget(reopened,text:newText)
                XCTAssertNotNil(target.previewPaperColor,"A cold owned Form must retain the independently verified erasure route.")
                XCTAssertEqual(target.paintBounds,extent)
                XCTAssertEqual(target.style.fontSize,initialFontSize,accuracy:0.001)
                for scale: CGFloat in [0.5,1,2,4] {
                    sourceComponentAssertExact(try corridorOutsidePixels(original,extent:extent,scale:scale),
                        try corridorOutsidePixels(reopened,extent:extent,scale:scale))
                }
            }
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for:original),originalData)
            complete = (testRun?.totalFailureCount ?? 0) == 0
            } catch {
                XCTFail("The cold measured scan case must complete both saves; upper=\(upper),errorType=\(type(of:error)).")
            }
        }
    }

    func testMeasuredMultirowScanRetainsOneBaselineGridThroughTwoAtomicColdEdits() async throws {
        let originalDocument = try fixture(),original = try XCTUnwrap(originalDocument.page(at:0))
        let originalData = try PDFBodyTextPageSnapshot.data(for:original)
        var current = originalDocument
        var target = try XCTUnwrap(PDFBodyTextEditor.target(on:original,selection:selectedRows(on:original)))
        let extent = target.paintBounds,spacing = try XCTUnwrap(target.lineHeight)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EmberScanRows-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var complete = false
        defer { if complete { try? FileManager.default.removeItem(at:folder) } else { print("EMBER_SCAN_ROWS_FAILED_OUTPUTS",folder.path) } }
        let firstText = target.text.replacingOccurrences(of:"alpha",with:"alpho")
        let texts = [firstText,target.text]
        for (cycle,text) in texts.enumerated() {
            let edited = try PDFBodyTextEditor.replacementPage(for:XCTUnwrap(current.page(at:0)),target:target,
                text:text,style:target.style,bounds:target.bounds)
            let live = PDFDocument();live.insert(edited,at:0)
            let snapshot = try PDFRecoverySnapshot(capturing:live),path = folder.appendingPathComponent("cycle-\(cycle).pdf")
            _ = try await Task.detached { try AtomicPDFWriter.write(snapshot.takeDocument(),to:path) }.value
            PDFBodyTextDocumentFonts.invalidate(current);PDFBodyTextDocumentFonts.invalidate(live)
            current = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data:Data(contentsOf:path)))
            let page = try XCTUnwrap(current.page(at:0)),string = try XCTUnwrap(page.string)
            let exactRange = (string as NSString).range(of:text)
            let rangeFound = exactRange.location != NSNotFound
            let unselected = rangeFound ? (string as NSString).replacingCharacters(in:exactRange,with:"") : string
            let selectionRecord: [String:Any] = ["cycle":cycle,"rangeFound":rangeFound,
                "pageScalars":string.unicodeScalars.count,"expectedScalars":text.unicodeScalars.count,
                "unselectedNonWhitespace":unselected.filter { !$0.isWhitespace }.count]
            print("SCAN_COLD_SELECTION "+String(decoding:try JSONSerialization.data(withJSONObject:selectionRecord,options:[.sortedKeys]),as:UTF8.self))
            XCTAssertTrue(rangeFound,"The exact modified four-row text must be present before qualifying a cold selection.")
            guard rangeFound else { throw PDFScannedBodyTextEditor.Failure.unsupported }
            XCTAssertTrue(unselected.allSatisfy { $0.isWhitespace },"The owned fixture has no unselected non-whitespace text.")
            let selection = try XCTUnwrap(page.selection(for:exactRange))
            XCTAssertEqual(selection.string,text,"Cold selection must cover only the precise committed text, not the whole page.")
            try corridorColdEvidence(page)
            target = try XCTUnwrap(PDFBodyTextEditor.target(on:page,selection:selection))
            XCTAssertEqual(target.text.filter { !$0.isWhitespace },text.filter { !$0.isWhitespace })
            XCTAssertNotNil(target.previewPaperColor);XCTAssertEqual(target.paintBounds,extent)
            XCTAssertEqual(try XCTUnwrap(target.lineHeight),spacing,accuracy:0.001)
            sourceComponentAssertExact(try corridorOutsidePixels(original,extent:extent,scale:2),
                try corridorOutsidePixels(page,extent:extent,scale:2))
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for:original),originalData)
        complete = (testRun?.totalFailureCount ?? 0) == 0
    }

    /// WORK numeric observation only; this conditional helper result is not
    /// product admission or a replacement for the private raw/resource audit.
    private func corridorColdEvidence(_ page: PDFPage) throws {
        let content = try PDFBodyTextPageSnapshot.contentData(for:page)
        let stream = try PDFBodyTextContentStream.parse(content)
        let candidates = stream.forms.compactMap { form -> (PDFBodyTextContentStream.FormRecord,PDFScannedErasureMetadata)? in
            guard let raw = PDFBodyTextPageSnapshot.scannedErasureMetadata(named:form.name,on:page),
                  let metadata = try? PDFScannedErasureMetadata.decode(raw) else { return nil }
            return (form,metadata)
        }
        var report: [String:Any] = ["metadataForms":candidates.count]
        guard candidates.count == 1,let (form,metadata) = candidates.first else {
            print("SCAN_COLD_FORM "+String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self));return
        }
        report["erasureRows"] = metadata.erasedRects.count
        report["parentProgramProof"] = try metadata.provesCurrentProgram(content,mediaBox:page.bounds(for:.mediaBox),
            donorName:form.name,donorRange:form.showRange)
        let snapshot = try PDFBodyTextPageSnapshot.data(for:page)
        try snapshot.withUnsafeBytes { bytes in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress,snapshot.count,nil))
            defer { FPDF_CloseDocument(document) }
            let native = try XCTUnwrap(FPDF_LoadPage(document,0));defer { FPDF_ClosePage(native) }
            let forms = (0..<FPDFPage_CountObjects(native)).compactMap { FPDFPage_GetObject(native,$0) }
                .filter { FPDFPageObj_GetType($0) == FPDF_PAGEOBJ_FORM }
            report["nativeForms"] = forms.count
            guard forms.count == 1,let object = forms.first else { return }
            let count = FPDFFormObj_CountObjects(object)
            var children: [[String:Any]] = []
            for index in 0..<min(count,64) {
                guard let child = FPDFFormObj_GetObject(object,UInt(index)) else { continue }
                var l:Float=0,b:Float=0,r:Float=0,t:Float=0
                let hasBounds = FPDFPageObj_GetBounds(child,&l,&b,&r,&t) != 0
                var row: [String:Any] = ["type":FPDFPageObj_GetType(child),"hasBounds":hasBounds]
                if hasBounds { row["bounds"] = [Double(l),Double(b),Double(r),Double(t)] }
                if let clip = FPDFPageObj_GetClipPath(child) { row["clipPaths"] = FPDFClipPath_CountPaths(clip) }
                else { row["clipAbsent"] = true }
                children.append(row)
            }
            report["children"] = children
            let envelope = PDFScannedBodyTextEditor.Source(snapshot:Data(),rootIndices:[],
                erasedRects:metadata.erasedRects,paperColor:metadata.paperColor)
            report["conditionalNativeFitsAssumingRawUnclipped"] = try PDFScannedBodyTextEditor.currentTextFormFits(object,
                on:native,source:envelope,independentlyUnclipped:true)
        }
        print("SCAN_COLD_FORM "+String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
    }

    private func corridorOutsidePixels(_ page: PDFPage,extent: CGRect,scale: CGFloat) throws -> Data {
        let width = Int(300*scale),height = Int(200*scale)
        var bytes = Data(repeating:255,count:width*height*4),mask = Data(repeating:0,count:width*height)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))
            context.scaleBy(x:scale,y:scale);context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        // This masks only pixels intersecting the original declared region.
        // It never changes that PDF-space authority or the original 2x oracle.
        let cells = CGRect(x:floor(extent.minX*scale)/scale,y:floor(extent.minY*scale)/scale,
            width:(ceil(extent.maxX*scale)-floor(extent.minX*scale))/scale,
            height:(ceil(extent.maxY*scale)-floor(extent.minY*scale))/scale)
        try mask.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue))
            context.setShouldAntialias(false);context.scaleBy(x:scale,y:scale)
            context.setFillColor(gray:1,alpha:1);context.fill(cells)
        }
        for index in mask.indices where mask[index] != 0 { bytes.replaceSubrange(index*4..<index*4+4,with:[255,255,255,255]) }
        return bytes
    }

    func testTightScannedRowsWithShortOCRCellsRemainEditable() throws {
        let document = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let selection = try selectedRows(on: page)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        XCTAssertEqual((target.text as NSString).substring(with: try XCTUnwrap(target.initialSelectedRange)), selection.string)
        XCTAssertEqual(target.sourceRuns.count, 4)
        XCTAssertEqual(target.lineHeight ?? 0, 11.2, accuracy: 0.05)
        XCTAssertNotNil(target.previewPaperColor)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before,
                       "Opening the editor must leave the scan and recognition layer unchanged.")
    }

    func testIllustrationBetweenRecognizedWordsStillRejectsWithoutMutatingSource() throws {
        for illustration in [Illustration.ink, .photo, .detachedGlyphMarginMark] {
            let document = try fixture(illustration: illustration)
            let page = try XCTUnwrap(document.page(at: 0))
            let before = try PDFBodyTextPageSnapshot.data(for: page)
            XCTAssertThrowsError(try PDFBodyTextEditor.target(on: page, selection: selectedRows(on: page)))
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
        }
    }

    func testDonorGlyphMayCrossSelectedRowBoundaryButCannotCrossHoleOrShortLastRow() throws {
        // Initialize the product's confined PDFium lifetime using its normal
        // target route before probing a one-character donor's actual bounds.
        let control = try fixture(), controlPage = try XCTUnwrap(control.page(at: 0))
        _ = try XCTUnwrap(PDFBodyTextEditor.target(on: controlPage, selection: selectedRows(on: controlPage)))
        let data = NSMutableData()
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: nil, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 40, y: 100)
        let font = try XCTUnwrap(NSFont(name: "Helvetica", size: 12))
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "g",
            attributes: [.font: font, .foregroundColor: NSColor.black])), context)
        context.endPDFPage(); context.closePDF()
        try (data as Data).withUnsafeBytes { raw in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(raw.baseAddress, data.length, nil))
            defer { FPDF_CloseDocument(document) }
            let page = try XCTUnwrap(FPDF_LoadPage(document, 0))
            defer { FPDF_ClosePage(page) }
            let text = try XCTUnwrap(FPDFText_LoadPage(page))
            defer { FPDFText_ClosePage(text) }
            var left=0.0,right=0.0,bottom=0.0,top=0.0
            XCTAssertNotEqual(FPDFText_GetCharBox(text, 0, &left, &right, &bottom, &top), 0)
            let box = CGRect(x: left, y: bottom, width: right-left, height: top-bottom)
            @MainActor func fits(_ rectangles: [CGRect]) -> Bool {
                PDFScannedBodyTextEditor.replacementFits(page, source: .init(snapshot: Data(),
                    rootIndices: [], erasedRects: rectangles, paperColor: .clear))
            }
            let lower = CGRect(x: box.minX-1, y: box.minY-1, width: box.width+2, height: box.height/2+1)
            let upper = CGRect(x: box.minX-1, y: box.midY, width: box.width+2, height: box.height/2+1)
            XCTAssertTrue(fits([lower, upper]), "A glyph may span two touching selected rows.")
            XCTAssertFalse(fits([lower.insetBy(dx: 0, dy: 0.4), upper.offsetBy(dx: 0, dy: 0.4)]),
                           "The union must preserve a real gap between erasures.")
            XCTAssertFalse(fits([CGRect(x: lower.minX, y: lower.minY, width: lower.width/2,
                height: lower.height), upper]), "A shorter final selected row must keep its unselected suffix protected.")
        }
    }

    func testLineEndHyphenRetainsPrintedUnicodeInsteadOfPDFiumControlCharacter() throws {
        let document = try fixture(hyphen: true)
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try selectedRows(on: page)
        XCTAssertTrue(selection.string?.contains("bravo-") == true)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        XCTAssertTrue(target.text.contains("bravo-\ncharlie"))
        XCTAssertFalse(target.text.unicodeScalars.contains(where: { $0.value == 2 }))
        XCTAssertEqual((target.text as NSString).substring(with: try XCTUnwrap(target.initialSelectedRange)), selection.string)
    }

    func testFractionalPageEdgeAndNeighboringScanPixelsSurviveTextReplacement() throws {
        let document = try fixture(fractionalPage: true)
        let page = try XCTUnwrap(document.page(at: 0))
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selectedRows(on: page)))
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: target.text.replacingOccurrences(of: "alpha", with: "a"), style: target.style, bounds: target.bounds)
        XCTAssertFalse(edited.string?.contains("alpha") == true)
        XCTAssertTrue(edited.string?.contains("bravo") == true)
        let excluded = target.bounds.insetBy(dx: -6, dy: -6)
        XCTAssertEqual(try pixels(page, excluding: excluded), try pixels(edited, excluding: excluded),
                       "Adding an erasure clip must not redraw or lighten any unselected page edge.")
    }

    private func pixels(_ page: PDFPage, excluding region: CGRect) throws -> Data {
        let box=page.bounds(for:.mediaBox),scale:CGFloat=3
        let width=Int(ceil(box.width*scale)),height=Int(ceil(box.height*scale))
        var bytes=Data(repeating:255,count:width*height*4)
        try bytes.withUnsafeMutableBytes {raw in
            let context=try XCTUnwrap(CGContext(data:raw.baseAddress,width:width,height:height,
                bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x:scale,y:scale)
            context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        for y in 0..<height {for x in 0..<width {
            if region.contains(CGPoint(x:(CGFloat(x)+0.5)/scale,y:(CGFloat(height-y)-0.5)/scale)) {
                let offset=(y*width+x)*4
                bytes.replaceSubrange(offset..<offset+4,with:[255,255,255,255])
            }
        }}
        return bytes
    }

    private enum Illustration { case none, ink, photo, detachedGlyphMarginMark }

    private func selectedRows(on page: PDFPage) throws -> PDFSelection {
        let text = try XCTUnwrap(page.string) as NSString
        let first = text.range(of: "alpha"), last = text.range(of: "hotel")
        XCTAssertNotEqual(first.location, NSNotFound)
        XCTAssertNotEqual(last.location, NSNotFound)
        return try XCTUnwrap(page.selection(for: NSRange(location: first.location,
            length: NSMaxRange(last)-first.location)))
    }

    private func fixture(illustration: Illustration = .none, hyphen: Bool = false,
                         fractionalPage: Bool = false) throws -> PDFDocument {
        let width = 600, height = 400
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor(white: 0.92, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A deterministic mild scanner texture, kept well below ink contrast.
        for y in stride(from: 0, to: height, by: 3) {
            for x in stride(from: 0, to: width, by: 3) {
                context.setFillColor(NSColor(white: 0.91+CGFloat((x+y)%3)/200, alpha: 1).cgColor)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        context.scaleBy(x: 2, y: 2)
        context.textMatrix = .identity
        let font = try XCTUnwrap(NSFont(name: "Helvetica", size: 10))
        let pageWidth=fractionalPage ? "300.199976" : "300",pageHeight=fractionalPage ? "200.199976" : "200"
        var commands = "q \(pageWidth) 0 0 \(pageHeight) 0 0 cm /Scan Do Q\n"
        let rows = [["alpha", hyphen ? "bravo-" : "bravo"], ["charlie", "delta"],
                    ["echo", "foxtrot"], ["golf", "hotel"]]
        var gap: CGRect = .zero
        var marginMark: CGRect = .zero
        for (row, words) in rows.enumerated() {
            let baseline = 160-CGFloat(row)*11.2
            var x: CGFloat = 30
            for (column, word) in words.enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: word,
                    attributes: [.font: font, .foregroundColor: NSColor(white: 0.2, alpha: 1)]))
                context.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(line, context)
                let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                commands += "BT /F1 10 Tf 3 Tr 0.90 0 0 1 \(x) \(baseline) Tm (\(word)) Tj ET\n"
                if row == 0, column == 0 { gap = CGRect(x: x+advance+7, y: baseline+1, width: 8, height: 4) }
                if row == 0, column == 0 { marginMark = CGRect(x: x+advance+1.2, y: baseline+2, width: 1.5, height: 2) }
                // Include the short OCR-cell error in the product's bounded
                // 24pt word-gap limit; this fixture is one paragraph.
                x += advance+18
            }
        }
        if illustration != .none {
            context.setFillColor(NSColor(white: 0.15, alpha: 1).cgColor)
            context.fill(illustration == .detachedGlyphMarginMark ? marginMark : gap)
            if illustration == .photo {
                for index in 0..<8 {
                    context.setFillColor(NSColor(calibratedRed: CGFloat(index%3)/3,
                        green: CGFloat(index%4)/4, blue: CGFloat(index%5)/5, alpha: 1).cgColor)
                    context.fill(CGRect(x: gap.minX+CGFloat(index), y: gap.minY, width: 1, height: 4))
                }
            }
        }
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 1.0]))
        var image = Data("<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /DCTDecode /Length \(jpeg.count) >>\nstream\n".utf8)
        image.append(jpeg); image.append(Data("\nendstream".utf8))
        let objects = [Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(pageWidth) \(pageHeight)] /Resources << /Font << /F1 4 0 R >> /XObject << /Scan 6 0 R >> >> /Contents 5 0 R >>".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
            Data("<< /Length \(commands.utf8.count) >>\nstream\n\(commands)endstream".utf8), image]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index+1) 0 obj\n".utf8)); data.append(object); data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }

    func testConnectedSourceVerticalInkOutsideNominalOCRPaddingIsCompletelyErased() throws {
        for kind in [SourceComponentKind.connectedDescender, .upperConnectedDescender] {
            let fixture = try sourceComponentFixture(kind)
            let page = try XCTUnwrap(fixture.document.page(at: 0))
            let source = try PDFBodyTextPageSnapshot.data(for: page)
            let before = try sourceComponentPixels(page)
            let oldTail = try sourceComponentSelectedPixels(before, rectangle: fixture.tail)
            XCTAssertGreaterThan(oldTail.filter { $0 < 64 }.count, 8,
                "The fixed source-owned terminal ROI must contain actual printed ink.")
            if kind == .upperConnectedDescender {
                XCTAssertGreaterThan(fixture.tail.minY, fixture.ocrBounds.maxY + 1.8)
                XCTAssertLessThan(fixture.tail.maxY, fixture.ocrBounds.maxY + 5 - 1)
            } else {
                XCTAssertLessThan(fixture.tail.maxY, fixture.ocrBounds.minY - 1.8)
                XCTAssertGreaterThan(fixture.tail.minY, fixture.ocrBounds.minY - 5 + 1)
            }
            let target = try sourceComponentTarget(page)
            XCTAssertNotNil(target.previewPaperColor, "This positive must reach the scan route.")
            XCTAssertTrue(target.paintBounds.contains(fixture.tail),
                "The immutable pre-edit declaration must include the proven connected source descender.")
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: "n", style: target.style, bounds: target.bounds)
            let after = try sourceComponentPixels(edited)
            let remaining = try sourceComponentSelectedPixels(after, rectangle: fixture.tail)
            // The known white fixture permits one 8-bit level of paper-estimator
            // rounding from antialiased edge samples. This independent fixed ROI
            // must lose its black source ink; outside pixels remain byte-exact.
            XCTAssertTrue(remaining.enumerated().allSatisfy { offset, value in
                offset % 4 == 3 ? value == 255 : value >= 254
            }, "A shorter replacement must erase this specific old source component to within one level of the known white paper. RGBA=\(Array(remaining))")
            sourceComponentAssertExact(try sourceComponentSelectedPixels(before, rectangle: fixture.neighbor),
                try sourceComponentSelectedPixels(after, rectangle: fixture.neighbor))
            sourceComponentAssertExact(try sourceComponentOutsidePixels(before, declaration: target.paintBounds),
                try sourceComponentOutsidePixels(after, declaration: target.paintBounds))
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), source)
        }
    }

    func testClosedConnectedSourceWithOnePaperRasterRowStillErasesOnlyItsOwnedInk() throws {
        for kind in [SourceComponentKind.lowerSinglePaperRim, .upperSinglePaperRim] {
            do {
                let fixture = try sourceComponentFixture(kind)
                let page = try XCTUnwrap(fixture.document.page(at: 0))
                let source = try PDFBodyTextPageSnapshot.data(for: page)
                let before = try sourceComponentPixels(page)
                let oldTail = try sourceComponentSelectedPixels(before, rectangle: fixture.tail)
                XCTAssertGreaterThan(oldTail.filter { $0 < 64 }.count, 8)
                let distance = kind == .upperSinglePaperRim
                    ? fixture.ocrBounds.maxY + 5 - fixture.tail.maxY
                    : fixture.tail.minY - (fixture.ocrBounds.minY - 5)
                XCTAssertGreaterThan(distance, 0)
                XCTAssertLessThan(distance, 1,
                    "The known connected ink ends inside the search boundary with less than two 2x raster rows of paper.")
                guard try sourceComponentAssertHeightPrerequisite(page, ocr: fixture.ocrBounds, fontSize: 10, text: "HHH", upper: kind == .upperSinglePaperRim) else { continue }
                let target = try sourceComponentTarget(page, text: "HHH")
                XCTAssertNotNil(target.previewPaperColor)
                XCTAssertTrue(target.paintBounds.contains(fixture.tail))
                let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                    text: "H", style: target.style, bounds: target.bounds)
                let after = try sourceComponentPixels(edited)
                let remaining = try sourceComponentSelectedPixels(after, rectangle: fixture.tail)
                XCTAssertTrue(remaining.enumerated().allSatisfy { offset, value in
                    offset % 4 == 3 ? value == 255 : value >= 254
                })
                sourceComponentAssertExact(try sourceComponentSelectedPixels(before, rectangle: fixture.neighbor),
                    try sourceComponentSelectedPixels(after, rectangle: fixture.neighbor))
                sourceComponentAssertExact(try sourceComponentOutsidePixels(before, declaration: target.paintBounds),
                    try sourceComponentOutsidePixels(after, declaration: target.paintBounds))
                XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), source)
            } catch {
                XCTFail("The controlled positive must admit and erase on every symmetric side; error type=\(type(of: error)).")
            }
        }
    }


    func testClosedSourceCellsAtZeroPaperRimRemainInsideInspectionAndEraseCompletely() throws {
        for upper in [false, true] {
            do {
                let precision = try sourceComponentPrecisionFixture(upper: upper, crossing: false)
                let fixture = precision.fixture, page = try XCTUnwrap(fixture.document.page(at: 0))
                try assertSourceComponentPrecisionPreconditions(precision, page: page)
                let source = try PDFBodyTextPageSnapshot.data(for: page)
                let before = try sourceComponentPixels(page)
                XCTAssertGreaterThan(try sourceComponentSelectedPixels(before, rectangle: fixture.tail)
                    .filter { $0 < 64 }.count, 8)
                guard try sourceComponentAssertHeightPrerequisite(page, ocr: fixture.ocrBounds, fontSize: precision.fontSize, text: "HHH", upper: upper) else { continue }
                let target = try sourceComponentTarget(page, text: "HHH")
                XCTAssertNotNil(target.previewPaperColor)
                XCTAssertTrue(target.paintBounds.contains(fixture.tail))
                let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                    text: "H", style: target.style, bounds: target.bounds)
                let after = try sourceComponentPixels(edited)
                let remaining = try sourceComponentSelectedPixels(after, rectangle: fixture.tail)
                XCTAssertTrue(remaining.enumerated().allSatisfy { offset, value in
                    offset % 4 == 3 ? value == 255 : value >= 254
                }, "The specific closed source cell must become the known white paper, not remain old ink.")
                sourceComponentAssertExact(try sourceComponentSelectedPixels(before, rectangle: fixture.neighbor),
                    try sourceComponentSelectedPixels(after, rectangle: fixture.neighbor))
                sourceComponentAssertExact(try sourceComponentOutsidePixels(before, declaration: target.paintBounds),
                    try sourceComponentOutsidePixels(after, declaration: target.paintBounds))
                XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), source)
            } catch {
                XCTFail("The controlled positive must admit and erase on every symmetric side; error type=\(type(of: error)).")
            }
        }
    }

    func testSourceCellCenterInsideButFootprintCrossingInspectionCapRefusesBothSides() throws {
        // A separately accepted ordinary scan control prevents an unrelated
        // bootstrap or all-scan refusal from qualifying these negative cases.
        let control = try sourceComponentFixture(.detachedNeighbor)
        XCTAssertNotNil(try sourceComponentTarget(XCTUnwrap(control.document.page(at: 0))).previewPaperColor)
        for upper in [false, true] {
            let precision = try sourceComponentPrecisionFixture(upper: upper, crossing: true)
            let fixture = precision.fixture, page = try XCTUnwrap(fixture.document.page(at: 0))
            try assertSourceComponentPrecisionPreconditions(precision, page: page)
            let source = try PDFBodyTextPageSnapshot.data(for: page)
            let before = try sourceComponentPixels(page)
            do {
                _ = try sourceComponentTarget(page)
                XCTFail("An ink-cell center inside the cap cannot authorize its outside fractional footprint.")
            } catch let error as PDFScannedBodyTextEditor.Failure {
                guard case .unsupported = error else {
                    XCTFail("Expected the scan geometry refusal, received a different scan error.")
                    continue
                }
            }
            sourceComponentAssertExact(before, try sourceComponentPixels(page))
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), source)
        }
    }

    func testDetachedNeighborAtTheSameVerticalMarginSurvivesAnAcceptedScanEdit() throws {
        for kind in [SourceComponentKind.detachedNeighbor, .upperDetachedNeighbor] {
            let fixture = try sourceComponentFixture(kind)
            let page = try XCTUnwrap(fixture.document.page(at: 0))
            let source = try PDFBodyTextPageSnapshot.data(for: page)
            let before = try sourceComponentPixels(page)
            let oldNeighbor = try sourceComponentSelectedPixels(before, rectangle: fixture.tail)
            XCTAssertGreaterThan(oldNeighbor.filter { $0 < 64 }.count, 8)
            let target = try sourceComponentTarget(page)
            XCTAssertNotNil(target.previewPaperColor)
            XCTAssertFalse(target.paintBounds.intersects(fixture.tail),
                "The same-margin detached neighbor cannot become erasure authority merely because it is nearby.")
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: "n", style: target.style, bounds: target.bounds)
            let after = try sourceComponentPixels(edited)
            sourceComponentAssertExact(oldNeighbor, try sourceComponentSelectedPixels(after, rectangle: fixture.tail))
            sourceComponentAssertExact(try sourceComponentSelectedPixels(before, rectangle: fixture.neighbor),
                try sourceComponentSelectedPixels(after, rectangle: fixture.neighbor))
            sourceComponentAssertExact(try sourceComponentOutsidePixels(before, declaration: target.paintBounds),
                try sourceComponentOutsidePixels(after, declaration: target.paintBounds))
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), source)
        }
    }

    func testConnectedSourceDescenderCannotCrossProtectedOCROrTheSearchBoundary() throws {
        // A real accepted positive is required first; an unrelated target nil
        // or fixture setup failure must not qualify these two refusal controls.
        let control = try sourceComponentFixture(.detachedNeighbor)
        XCTAssertNotNil(try sourceComponentTarget(XCTUnwrap(control.document.page(at: 0))).previewPaperColor)
        for kind in [SourceComponentKind.protectedOCR, .searchBoundary, .upperSearchBoundary] {
            let fixture = try sourceComponentFixture(kind)
            let page = try XCTUnwrap(fixture.document.page(at: 0))
            let source = try PDFBodyTextPageSnapshot.data(for: page)
            let before = try sourceComponentPixels(page)
            XCTAssertGreaterThan(try sourceComponentSelectedPixels(before, rectangle: fixture.tail)
                .filter { $0 < 200 }.count, 8,
                "The protected blue control is ink too; white paper channels remain255.")
            if let protected = fixture.protectedOCR {
                XCTAssertTrue(protected.intersects(fixture.tail))
                let selection = try sourceComponentSelection(page)
                XCTAssertFalse(selection.bounds(for: page).insetBy(dx: -0.2, dy: -0.2)
                    .contains(CGPoint(x: protected.midX, y: protected.midY)),
                    "The protected recognition cell must not be part of the selected OCR run.")
            } else if kind == .upperSearchBoundary {
                XCTAssertGreaterThan(fixture.tail.maxY, fixture.ocrBounds.maxY + 5)
            } else {
                XCTAssertLessThan(fixture.tail.minY, fixture.ocrBounds.minY - 5,
                    "The connected component crosses the independent half-em search cap.")
            }
            do {
                _ = try sourceComponentTarget(page)
                XCTFail("An unresolved connected component at a protected/search boundary must refuse before any edit.")
            } catch let failure as PDFScannedBodyTextEditor.Failure {
                guard case .unsupported = failure else {
                    XCTFail("Expected the scan-background refusal, received another scan error.")
                    continue
                }
            }
            sourceComponentAssertExact(before, try sourceComponentPixels(page))
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), source)
        }
    }

    private enum SourceComponentKind { case connectedDescender, detachedNeighbor, protectedOCR, searchBoundary
        case upperConnectedDescender, upperDetachedNeighbor, upperSearchBoundary
        case lowerSinglePaperRim, upperSinglePaperRim
    }
    private struct SourceComponentFixture {
        let document: PDFDocument
        let ocrBounds: CGRect
        let tail: CGRect
        let neighbor: CGRect
        let protectedOCR: CGRect?
    }

    private func sourceComponentSelection(_ page: PDFPage, text expected: String = "nnn") throws -> PDFSelection {
        let text = try XCTUnwrap(page.string) as NSString
        let range = text.range(of: expected)
        XCTAssertNotEqual(range.location, NSNotFound)
        let selection = try XCTUnwrap(page.selection(for: range))
        XCTAssertEqual(selection.string, expected)
        return selection
    }
    private func sourceComponentTarget(_ page: PDFPage, text: String = "nnn") throws -> PDFBodyTextTarget {
        let target = try PDFBodyTextEditor.target(on: page, selection: sourceComponentSelection(page, text: text))
        return try XCTUnwrap(target)
    }

    private func sourceComponentFixture(_ kind: SourceComponentKind) throws -> SourceComponentFixture {
        // Reuse the existing product lifetime bootstrap rather than repeatedly
        // invoking FPDF_InitLibrary from a test helper.
        let bootstrap = try fixture(), bootstrapPage = try XCTUnwrap(bootstrap.page(at: 0))
        _ = try XCTUnwrap(PDFBodyTextEditor.target(on: bootstrapPage, selection: selectedRows(on: bootstrapPage)))
        let hPositive = kind == .lowerSinglePaperRim || kind == .upperSinglePaperRim
        let sourceText = hPositive ? "HHH" : "nnn"
        let prefix = "q 300 0 0 200 0 0 cm /Scan Do Q\nBT /F1 10 Tf 3 Tr 1 0 0 1 40 120 Tm (\(sourceText)) Tj ET\n"
        let blank = sourceComponentPDF(commands: prefix, image: Data(repeating: 255, count: 600*400*3))
        let ocr = try sourceComponentNativeBounds(blank, objectIndex: 1)
        let upper = [SourceComponentKind.upperConnectedDescender, .upperDetachedNeighbor, .upperSearchBoundary, .upperSinglePaperRim].contains(kind)
        let edge: CGFloat
        if upper {
            edge = ceil((ocr.maxY + (kind == .upperSearchBoundary ? 4.25 : (kind == .upperSinglePaperRim ? 3.25 : 2.25)))*2)/2
        } else {
            edge = floor((ocr.minY - (kind == .searchBoundary ? 5.25 : (kind == .lowerSinglePaperRim ? 4.25 : 3.25)))*2)/2
        }
        let tail = CGRect(x: floor((ocr.maxX-2.0)*2)/2, y: edge, width: 1.5, height: 1)
        let neighbor = CGRect(x: ceil((ocr.maxX+7)*2)/2, y: floor(ocr.minY*2)/2, width: 2, height: 3)
        var commands = prefix
        var protected: CGRect?
        if kind == .protectedOCR {
            commands += "BT /F1 4 Tf 3 Tr 1 0 0 1 \(tail.minX) \(ocr.minY-4) Tm (x) Tj ET\n"
            protected = try sourceComponentNativeBounds(sourceComponentPDF(commands: commands,
                image: Data(repeating: 255, count: 600*400*3)), objectIndex: 2)
        }
        var image = Data(repeating: 255, count: 600*400*3)
        func paint(_ rectangle: CGRect, color: [UInt8]) {
            image.withUnsafeMutableBytes { raw in
                let pixels = raw.bindMemory(to: UInt8.self)
                for y in 0..<400 { for x in 0..<600 {
                    if rectangle.contains(CGPoint(x: (CGFloat(x)+0.5)/2, y: (CGFloat(y)+0.5)/2)) {
                        let offset = ((399-y)*600+x)*3
                        for channel in 0..<3 { pixels[offset+channel] = color[channel] }
                    }
                }}
            }
        }
        let body = ocr.insetBy(dx: 0.25, dy: 0.25), advance = body.width/3
        for index in 0..<3 {
            let x = body.minX+CGFloat(index)*advance
            paint(CGRect(x: x, y: body.minY, width: 0.75, height: body.height), color: [0,0,0])
            paint(CGRect(x: x+advance*0.75-0.75, y: body.minY, width: 0.75, height: body.height), color: [0,0,0])
            paint(CGRect(x: x, y: hPositive ? body.midY-0.375 : body.maxY-0.75, width: advance*0.75, height: 0.75), color: [0,0,0])
        }
        // Fixture provenance is constructive: the selected glyph's terminal
        // stem is extended into the fixed lower ROI. The detached control uses
        // the identical ROI/color without this connecting path.
        paint(tail, color: [0,0,0])
        if kind != .detachedNeighbor && kind != .upperDetachedNeighbor {
            let connectionBottom = min(body.minY, tail.minY)
            let connectionTop = max(body.maxY, tail.maxY)
            paint(CGRect(x: tail.minX, y: connectionBottom, width: 0.75,
                height: connectionTop-connectionBottom), color: [0,0,0])
            paint(CGRect(x: body.maxX-advance*0.25-0.75,
                y: upper ? body.maxY-0.75 : body.minY, width: 2.5, height: 0.75), color: [0,0,0])
        }
        if let protected { paint(protected.insetBy(dx: 0.1, dy: 0.1), color: [25,80,130]) }
        paint(neighbor, color: [25,80,130])
        return SourceComponentFixture(document: try XCTUnwrap(PDFDocument(data:
            sourceComponentPDF(commands: commands, image: image))), ocrBounds: ocr,
            tail: tail, neighbor: neighbor, protectedOCR: protected)
    }


    private struct SourceComponentPrecisionFixture {
        let fixture: SourceComponentFixture
        let region: CGRect
        let inspection: CGRect
        let inkCell: CGRect
        let upper: Bool
        let crossing: Bool
        let fontSize: CGFloat
        let row: Int
        let column: Int
        let allowedBottom: Int
        let allowedTop: Int
    }

    private func sourceComponentPrecisionFixture(upper: Bool, crossing: Bool) throws -> SourceComponentPrecisionFixture {
        let bootstrap = try fixture(), bootstrapPage = try XCTUnwrap(bootstrap.page(at: 0))
        _ = try XCTUnwrap(PDFBodyTextEditor.target(on: bootstrapPage, selection: selectedRows(on: bootstrapPage)))
        // These closed geometry probes choose a pixel phase, never an accepted
        // edit. No target/replacement result is consulted while selecting it.
        let sourceText = crossing ? "nnn" : "HHH"
        for size in [CGFloat(10), 12, 14, 16] {
            let text = "BT /F1 \(size) Tf 3 Tr 1 0 0 1 40 120 Tm (\(sourceText)) Tj ET\n"
            let initial = "q 300 0 0 200 0 0 cm /Scan Do Q\n" + text
            let ocr = try sourceComponentNativeBounds(sourceComponentPDF(commands: initial,
                image: Data(repeating: 255, count: 600*400*3)), objectIndex: 1)
            let media = CGRect(x: 0, y: 0, width: 300, height: 200)
            let horizontal = max(1.5, size*0.55), vertical = max(1.5, size*0.18)
            let search = max(vertical, size*0.5), extra = ceil(search-vertical)
            let nominal = ocr.insetBy(dx: -horizontal-0.5, dy: -vertical-0.5).intersection(media)
            let below = max(0, min(extra, floor(nominal.minY-media.minY)))
            let above = max(0, min(extra, floor(media.maxY-nominal.maxY)))
            let region = CGRect(x: nominal.minX, y: nominal.minY-below,
                width: nominal.width, height: nominal.height+below+above)
            let inspection = CGRect(x: ocr.minX-horizontal, y: ocr.minY-search,
                width: ocr.width+2*horizontal, height: ocr.height+2*search).intersection(region).intersection(media)
            let width = Int(ceil(region.width*2)), height = Int(ceil(region.height*2))
            let bottom = max(0, Int(ceil((inspection.minY-region.minY)*2-0.5)))
            let top = min(height-1, Int(ceil((inspection.maxY-region.minY)*2-0.5))-1)
            guard top > bottom else { continue }
            let row = upper ? top : bottom
            let column = Int(floor((ocr.maxX-2-region.minX)*2))
            let cell = CGRect(x: region.minX+CGFloat(column)/2,
                y: region.minY+CGFloat(row)/2, width: 0.5, height: 0.5)
            let centerInside = inspection.contains(CGPoint(x: cell.midX, y: cell.midY))
            let fullInside = cell.minY >= inspection.minY && cell.maxY <= inspection.maxY
            guard centerInside && fullInside != crossing, column >= 0, column+3 < width,
                  row > 0, row+1 < height else { continue }
            let tail = CGRect(x: cell.minX, y: cell.minY, width: 1.5, height: 0.5)
            let neighbor = CGRect(x: ceil((ocr.maxX+7)*2)/2, y: floor(ocr.minY*2)/2, width: 2, height: 3)
            // Align the immutable source image with the independently calculated
            // inspection raster. The actual rendered cell is asserted below.
            let origin = CGPoint(x: region.minX-floor(region.minX*2)/2,
                y: region.minY-floor(region.minY*2)/2)
            let commands = "q 300 0 0 200 \(origin.x) \(origin.y) cm /Scan Do Q\n" + text
            var image = Data(repeating: 255, count: 600*400*3)
            func paint(_ rectangle: CGRect, _ color: [UInt8]) {
                image.withUnsafeMutableBytes { raw in
                    let pixels = raw.bindMemory(to: UInt8.self)
                    for y in 0..<400 { for x in 0..<600 {
                        let point = CGPoint(x: origin.x+(CGFloat(x)+0.5)/2,
                            y: origin.y+(CGFloat(y)+0.5)/2)
                        if rectangle.contains(point) {
                            let offset = ((399-y)*600+x)*3
                            for channel in 0..<3 { pixels[offset+channel] = color[channel] }
                        }
                    }}
                }
            }
            let body = ocr.insetBy(dx: 0.25, dy: 0.25), advance = body.width/3
            for index in 0..<3 {
                let x = body.minX+CGFloat(index)*advance
                paint(CGRect(x: x, y: body.minY, width: 0.75, height: body.height), [0,0,0])
                paint(CGRect(x: x+advance*0.75-0.75, y: body.minY, width: 0.75, height: body.height), [0,0,0])
                paint(CGRect(x: x, y: crossing ? body.maxY-0.75 : body.midY-0.375, width: advance*0.75, height: 0.75), [0,0,0])
            }
            paint(tail, [0,0,0])
            paint(CGRect(x: tail.minX, y: min(body.minY, tail.minY), width: 0.75,
                height: max(body.maxY, tail.maxY)-min(body.minY, tail.minY)), [0,0,0])
            paint(CGRect(x: body.maxX-advance*0.25-0.75,
                y: upper ? body.maxY-0.75 : body.minY, width: 2.5, height: 0.75), [0,0,0])
            paint(neighbor, [25,80,130])
            let document = try XCTUnwrap(PDFDocument(data: sourceComponentPDF(commands: commands, image: image)))
            return SourceComponentPrecisionFixture(fixture: SourceComponentFixture(document: document,
                ocrBounds: ocr, tail: tail, neighbor: neighbor, protectedOCR: nil), region: region,
                inspection: inspection, inkCell: cell, upper: upper, crossing: crossing,
                fontSize: size, row: row, column: column, allowedBottom: bottom, allowedTop: top)
        }
        XCTFail("The finite source-only geometry set did not construct the requested exact-cell fixture.")
        throw PDFScannedBodyTextEditor.Failure.unsupported
    }

    private func assertSourceComponentPrecisionPreconditions(_ value: SourceComponentPrecisionFixture,
        page: PDFPage, file: StaticString = #filePath, line: UInt = #line) throws {
        let actualOCR = try sourceComponentNativeBounds(PDFBodyTextPageSnapshot.data(for: page), objectIndex: 1)
        XCTAssertEqual(actualOCR, value.fixture.ocrBounds, "The actual product snapshot must retain the native OCR geometry used for the cap construction.", file: file, line: line)
        let width = Int(ceil(value.region.width*2)), height = Int(ceil(value.region.height*2))
        var pixels = Data(repeating: 255, count: width*height*4)
        try pixels.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: 2, y: 2); context.translateBy(x: -value.region.minX, y: -value.region.minY)
            context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        func rgb(_ row: Int) -> [UInt8] {
            let start = ((height-row-1)*width+value.column)*4
            return Array(pixels[start..<start+4])
        }
        XCTAssertTrue(value.inspection.contains(CGPoint(x: value.inkCell.midX, y: value.inkCell.midY)), file: file, line: line)
        XCTAssertEqual(value.inkCell.minY >= value.inspection.minY && value.inkCell.maxY <= value.inspection.maxY,
            !value.crossing, file: file, line: line)
        let rim = value.upper ? value.allowedTop-value.row : value.row-value.allowedBottom
        XCTAssertEqual(rim, 0, "The connected terminal is at the center-selected inspection edge, with zero spare paper rows.", file: file, line: line)
        XCTAssertEqual(rgb(value.row), [0,0,0,255], "The actual inspection renderer must observe the fixed terminal ink cell.", file: file, line: line)
        let outward = value.upper ? value.row+1 : value.row-1
        XCTAssertEqual(rgb(outward), [255,255,255,255], "The outer read halo is paper, not an unresolved connected component.", file: file, line: line)
        let record: [String: Any] = ["upper": value.upper, "crossing": value.crossing, "fontSize": Double(value.fontSize),
            "ocrMinY": Double(actualOCR.minY), "ocrMaxY": Double(actualOCR.maxY),
            "regionMinY": Double(value.region.minY), "regionMaxY": Double(value.region.maxY), "inspectionMinY": Double(value.inspection.minY),
            "inspectionMaxY": Double(value.inspection.maxY), "cellMinY": Double(value.inkCell.minY),
            "cellMaxY": Double(value.inkCell.maxY), "row": value.row, "rimRows": rim,
            "centerInside": true, "actualCellRGBA": rgb(value.row), "outwardRGBA": rgb(outward)]
        let encoded = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("SCAN_CELL_GEOMETRY " + String(decoding: encoded, as: UTF8.self))
    }


    /// Measured independently from the source raster before asking the product
    /// for an edit. A tall synthetic component must not accidentally turn this
    /// boundary fixture into an unrelated ink/font-size correction rejection.
    private func sourceComponentAssertHeightPrerequisite(_ page: PDFPage, ocr: CGRect,
        fontSize: CGFloat, text: String, upper: Bool, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let media = page.bounds(for: .mediaBox)
        let horizontal = max(1.5, fontSize*0.55), vertical = max(1.5, fontSize*0.18)
        let search = max(vertical, fontSize*0.5), extra = ceil(search-vertical)
        let nominal = ocr.insetBy(dx: -horizontal-0.5, dy: -vertical-0.5).intersection(media)
        let below = max(0, min(extra, floor(nominal.minY-media.minY)))
        let above = max(0, min(extra, floor(media.maxY-nominal.maxY)))
        let region = CGRect(x: nominal.minX, y: nominal.minY-below,
            width: nominal.width, height: nominal.height+below+above)
        let width = Int(ceil(region.width*2)), height = Int(ceil(region.height*2))
        var pixels = Data(repeating: 255, count: width*height*4)
        try pixels.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: 2, y: 2); context.translateBy(x: -region.minX, y: -region.minY)
            context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        var rows = [Int](repeating: 0, count: height)
        for y in 0..<height { for x in 0..<width {
            let offset = ((height-y-1)*width+x)*4
            // The owned ink is black and its independent protected neighbor is
            // blue. This measurement does not reinterpret paper as source ink.
            if pixels[offset] < 64 && pixels[offset+1] < 64 && pixels[offset+2] < 64 { rows[y] += 1 }
        }}
        guard let first = rows.firstIndex(where: { $0 >= 2 }), let last = rows.lastIndex(where: { $0 >= 2 }) else {
            XCTFail("FIXTURE_PRECONDITION: no measured connected source ink rows.", file: file, line: line)
            return false
        }
        let measuredInkHeight = CGFloat(last-first+1)/2
        let font = NSFont(name: "AppleSDGothicNeo-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize)
        let measuredLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let renderedHHeight = CTLineGetBoundsWithOptions(measuredLine, .useGlyphPathBounds).height
        let ratio = measuredInkHeight/renderedHHeight
        let receipt: [String: Any] = ["upper": upper, "fontSize": Double(fontSize), "sourceScalars": text.unicodeScalars.count,
            "measuredSourceInkHeight": Double(measuredInkHeight), "renderedHHeight": Double(renderedHHeight),
            "heightRatio": Double(ratio), "firstInkRow": first, "lastInkRow": last]
        if ratio.isFinite {
            let encoded = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            print("SCAN_POSITIVE_HEIGHT " + String(decoding: encoded, as: UTF8.self))
        }
        guard measuredInkHeight > 0, renderedHHeight > 0, ratio.isFinite, (0.75...1.8).contains(ratio) else {
            XCTFail("FIXTURE_PRECONDITION: connected H ink/font height must satisfy the unchanged0.75...1.8 rule before product admission.", file: file, line: line)
            return false
        }
        return true
    }

    private func sourceComponentNativeBounds(_ data: Data, objectIndex: Int32) throws -> CGRect {
        try data.withUnsafeBytes { bytes in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(document) }
            let page = try XCTUnwrap(FPDF_LoadPage(document, 0)); defer { FPDF_ClosePage(page) }
            let object = try XCTUnwrap(FPDFPage_GetObject(page, objectIndex))
            XCTAssertEqual(FPDFPageObj_GetType(object), FPDF_PAGEOBJ_TEXT)
            XCTAssertEqual(FPDFTextObj_GetTextRenderMode(object), FPDF_TEXTRENDERMODE_INVISIBLE)
            let text = try XCTUnwrap(FPDFText_LoadPage(page)); defer { FPDFText_ClosePage(text) }
            var result = CGRect.null
            for index in Int32(0)..<FPDFText_CountChars(text) where FPDFText_GetTextObject(text, index) == object {
                var l=0.0,r=0.0,b=0.0,t=0.0
                XCTAssertNotEqual(FPDFText_GetCharBox(text,index,&l,&r,&b,&t),0)
                result = result.union(CGRect(x:l,y:b,width:r-l,height:t-b))
            }
            XCTAssertFalse(result.isNull)
            XCTAssertGreaterThan(result.height, 1)
            return result
        }
    }

    private func sourceComponentPDF(commands: String, image: Data) -> Data {
        var stream=Data("<< /Type /XObject /Subtype /Image /Width 600 /Height 400 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Interpolate false /Length \(image.count) >>\nstream\n".utf8)
        stream.append(image);stream.append(Data("\nendstream".utf8))
        let objects=[Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> /XObject << /Scan 6 0 R >> >> /Contents 5 0 R >>".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8),
            Data("<< /Length \(commands.utf8.count) >>\nstream\n\(commands)endstream".utf8),stream]
        var result=Data("%PDF-1.7\n".utf8),offsets=[0]
        for(index,object)in objects.enumerated(){offsets.append(result.count);result.append(Data("\(index+1) 0 obj\n".utf8));result.append(object);result.append(Data("\nendobj\n".utf8))}
        let xref=result.count
        result.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst(){result.append(Data(String(format:"%010d 00000 n \n",offset).utf8))}
        result.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return result
    }

    private func sourceComponentPixels(_ page: PDFPage) throws -> Data {
        var data=Data(repeating:255,count:600*400*4)
        try data.withUnsafeMutableBytes { raw in
            let context=try XCTUnwrap(CGContext(data:raw.baseAddress,width:600,height:400,bitsPerComponent:8,
                bytesPerRow:2400,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:600,height:400))
            context.scaleBy(x:2,y:2);context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        return data
    }
    private func sourceComponentMask(_ rectangle: CGRect) throws -> Data {
        var data=Data(repeating:0,count:600*400)
        try data.withUnsafeMutableBytes { raw in
            let context=try XCTUnwrap(CGContext(data:raw.baseAddress,width:600,height:400,bitsPerComponent:8,
                bytesPerRow:600,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue))
            context.setShouldAntialias(false);context.scaleBy(x:2,y:2)
            context.setFillColor(gray:1,alpha:1);context.fill(rectangle)
        }
        return data
    }
    private func sourceComponentSelectedPixels(_ pixels: Data, rectangle: CGRect) throws -> Data {
        let mask=try sourceComponentMask(rectangle);var result=Data()
        for index in mask.indices where mask[index] != 0 { result.append(pixels.subdata(in:index*4..<index*4+4)) }
        XCTAssertFalse(result.isEmpty);return result
    }
    private func sourceComponentOutsidePixels(_ pixels: Data, declaration: CGRect) throws -> Data {
        let footprint=CGRect(x:floor(declaration.minX*2)/2,y:floor(declaration.minY*2)/2,
            width:(ceil(declaration.maxX*2)-floor(declaration.minX*2))/2,
            height:(ceil(declaration.maxY*2)-floor(declaration.minY*2))/2)
        let mask=try sourceComponentMask(footprint);var result=pixels
        for index in mask.indices where mask[index] != 0 { result.replaceSubrange(index*4..<index*4+4,with:[255,255,255,255]) }
        return result
    }
    private func sourceComponentAssertExact(_ before: Data, _ after: Data,
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(before.count,after.count,file:file,line:line)
        var mismatches=0,first:[Int]=[]
        for index in 0..<min(before.count,after.count) where before[index] != after[index] {
            mismatches += 1;if first.count<8 { first.append(index) }
        }
        XCTAssertEqual(mismatches,0,"First differing byte offsets: \(first)",file:file,line:line)
    }

}
