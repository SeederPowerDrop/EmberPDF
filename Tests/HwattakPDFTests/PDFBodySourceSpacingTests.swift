// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import CPDFium
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodySourceSpacingTests: XCTestCase {
    func testNativeNominalAdvancesQualifyOnlyWhenDefaultIsMateriallyWorse() throws {
        for word in ["tailWord", "AVATAR"] {
            for size in [10, 14] {
                let doc = try fixture(show: "(\(word)) Tj", size: size)
                let page = try XCTUnwrap(doc.page(at: 0)), selected = try target(word, page)
                let font = try XCTUnwrap(NSFont(name: "Helvetica", size: CGFloat(size)))
                let native = try samples(word, page)
                let evidence = try XCTUnwrap(PDFBodySourceSpacing.evidence(text: word, samples: native, availableFont: font))
                XCTAssertLessThanOrEqual(evidence.unkernedMaximumError, 0.01)
                XCTAssertGreaterThan(evidence.defaultMaximumError, 0.05)
                XCTAssertTrue(selected.sourceRuns.contains(where: \.usesSourceUnkernedAdvances))
            }
        }
    }

    func testGeneratedMissingMappingTransformsAndOriginMismatchDoNotQualify() throws {
        let doc = try fixture(show: "(AVATAR) Tj"), page = try XCTUnwrap(doc.page(at: 0))
        _ = try target("AVATAR", page)
        let font = try XCTUnwrap(NSFont(name: "Helvetica", size: 10)), original = try samples("AVATAR", page)
        XCTAssertNil(PDFBodySourceSpacing.evidence(text: "AVATAR", samples: original, availableFont: nil))
        XCTAssertNil(PDFBodySourceSpacing.evidence(text: "AVATAR", samples: Array(original.dropLast()), availableFont: font))
        for reason in ["generated", "scalar", "geometry", "reverse", "transform"] {
            var changed = original
            let old = original[2]
            changed[2] = .init(scalar: reason == "scalar" ? 0 : old.scalar,
                origin: CGPoint(x: old.origin.x + (reason == "geometry" ? 0.02 : reason == "reverse" ? -100 : 0), y: old.origin.y),
                matrix: reason == "transform" ? CGAffineTransform(a: 1, b: 0.01, c: 0, d: 1, tx: 0, ty: 0) : old.matrix,
                generated: reason == "generated")
            XCTAssertNil(PDFBodySourceSpacing.evidence(text: "AVATAR", samples: changed, availableFont: font), reason)
        }
        let excessive = Array(repeating: original[0], count: 4097)
        XCTAssertNil(PDFBodySourceSpacing.evidence(text: String(repeating: "A", count: 4097), samples: excessive, availableFont: font))
    }

    func testExistingNaturalKerningAndExplicitTJAdjustmentsKeepTheirRoute() throws {
        let adjusted = try fixture(show: "[(AVA) -100 (TAR)] TJ"), page = try XCTUnwrap(adjusted.page(at: 0))
        XCTAssertFalse(try target("AVATAR", page).sourceRuns.contains(where: \.usesSourceUnkernedAdvances))
        let font = try XCTUnwrap(NSFont(name: "Helvetica", size: 10))
        let data = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.textMatrix = .identity; context.textPosition = CGPoint(x: 40, y: 220)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "AVATAR", attributes: [.font: font])), context)
        context.endPDFPage(); context.closePDF()
        let natural = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: data as Data))
        XCTAssertFalse(try target("AVATAR", XCTUnwrap(natural.page(at: 0))).sourceRuns.contains(where: \.usesSourceUnkernedAdvances))
        // A mapping with a supplementary or combining cluster cannot meet the
        // complete one-unit/one-glyph gate, even with a plausible origin list.
        for text in ["A😀", "a\u{301}", "لا"] {
            let pseudo = text.unicodeScalars.enumerated().map { i, scalar in
                PDFBodySourceSpacing.Sample(scalar: scalar.value, origin: CGPoint(x: 40 + i * 6, y: 220),
                    matrix: .identity, generated: false)
            }
            XCTAssertNil(PDFBodySourceSpacing.evidence(text: text, samples: pseudo, availableFont: font))
        }
    }

    func testEditingAndTwoColdAtomicSavesRetainAllNativeOrigins() async throws {
        for size in [10, 14] {
            var document = try fixture(show: "(tailWord) Tj", size: size)
            let source = try XCTUnwrap(document.page(at: 0)); _ = try target("tailWord", source)
            let expected = try origins("tailWord", source)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-spacing-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            for (cycle, edit) in [("tailWord", "tailWard"), ("tailWard", "tailWord")].enumerated() {
                let page = try XCTUnwrap(document.page(at: 0)), selected = try target(edit.0, page)
                XCTAssertTrue(selected.sourceRuns.contains(where: \.usesSourceUnkernedAdvances))
                let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
                    text: edit.1, style: selected.style, bounds: selected.bounds)
                same(try origins(edit.1, edited), expected)
                let live = PDFDocument(); live.insert(edited, at: 0)
                let snapshot = try PDFRecoverySnapshot(capturing: live), output = directory.appendingPathComponent("\(cycle).pdf")
                try await Task.detached { try AtomicPDFWriter.write(snapshot.takeDocument(), to: output) }.value
                PDFBodyTextDocumentFonts.invalidate(document); PDFBodyTextDocumentFonts.invalidate(live)
                document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Data(contentsOf: output)))
                let cold = try XCTUnwrap(document.page(at: 0)); same(try origins(edit.1, cold), expected)
                XCTAssertEqual(document.findString(edit.1, withOptions: []).count, 1)
            }
        }
    }

    func testProvenZeroKerningRetainsLeadingSpaceDrawingAndStyleOptOut() throws {
        let style = InlineTextStyle(fontName: "Helvetica", fontSize: 10, textColor: .black,
            backgroundColor: .clear, alignment: .left)
        let runs = [InlineTextSourceRun(range: NSRange(location: 0, length: 1), style: style,
                        horizontalAdvance: 30, usesSourceUnkernedAdvances: true),
                    InlineTextSourceRun(range: NSRange(location: 1, length: 6), style: style, usesSourceUnkernedAdvances: true)]
        let text = PDFBodyTextAttributedLayout.attributedString(text: " AVATAS", style: style,
            sourceText: " AVATAR", sourceStyle: style, sourceRuns: runs)
        XCTAssertNotNil(try PDFBodyLeadingSpaceDrawing.make(line: CTLineCreateWithAttributedString(text), text: text))
        var changed = style; changed.fontSize = 14
        let explicit = PDFBodyTextAttributedLayout.attributedString(text: " AVATAS", style: changed,
            sourceText: " AVATAR", sourceStyle: style, sourceRuns: runs)
        XCTAssertNil(explicit.attribute(.kern, at: 2, effectiveRange: nil))
        let fallback = PDFBodyTextAttributedLayout.attributedString(text: " 한글", style: style,
            sourceText: " AVATAR", sourceStyle: style, sourceRuns: runs)
        XCTAssertNil(fallback.attribute(.kern, at: 1, effectiveRange: nil), "A different fallback face cannot inherit native spacing proof.")
    }

    private func target(_ phrase: String, _ page: PDFPage) throws -> PDFBodyTextTarget {
        let text = try XCTUnwrap(page.string) as NSString, range = text.range(of: phrase)
        XCTAssertNotEqual(range.location, NSNotFound)
        return try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: XCTUnwrap(page.selection(for: range))))
    }
    private func same(_ actual: [CGPoint], _ expected: [CGPoint], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(a.y, b.y, accuracy: 0.01, file: file, line: line)
        }
    }
    private func origins(_ phrase: String, _ page: PDFPage) throws -> [CGPoint] { try samples(phrase, page).map(\.origin) }
    private func samples(_ phrase: String, _ source: PDFPage) throws -> [PDFBodySourceSpacing.Sample] {
        let data = try PDFBodyTextPageSnapshot.data(for: source)
        return try data.withUnsafeBytes { bytes in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil)); defer { FPDF_CloseDocument(document) }
            let page = try XCTUnwrap(FPDF_LoadPage(document, 0)); defer { FPDF_ClosePage(page) }
            let textPage = try XCTUnwrap(FPDFText_LoadPage(page)); defer { FPDFText_ClosePage(textPage) }
            var text = "", values: [PDFBodySourceSpacing.Sample] = []
            for index in 0..<FPDFText_CountChars(textPage) {
                let scalar = FPDFText_GetUnicode(textPage, index)
                guard let unicode = UnicodeScalar(scalar), scalar != 0 else { continue }
                var x = 0.0, y = 0.0, matrix = FS_MATRIX()
                XCTAssertNotEqual(FPDFText_GetCharOrigin(textPage, index, &x, &y), 0)
                XCTAssertNotEqual(FPDFText_GetMatrix(textPage, index, &matrix), 0)
                text.unicodeScalars.append(unicode)
                let value = PDFBodySourceSpacing.Sample(scalar: scalar, origin: CGPoint(x: x, y: y),
                    matrix: CGAffineTransform(a: CGFloat(matrix.a), b: CGFloat(matrix.b), c: CGFloat(matrix.c), d: CGFloat(matrix.d), tx: 0, ty: 0),
                    generated: FPDFText_IsGenerated(textPage, index) != 0)
                values += Array(repeating: value, count: String(unicode).utf16.count)
            }
            let range = (text as NSString).range(of: phrase); XCTAssertNotEqual(range.location, NSNotFound)
            guard range.location != NSNotFound else { return [] }
            return Array(values[range.location..<NSMaxRange(range)])
        }
    }
    private func fixture(show: String, size: Int = 10) throws -> PDFDocument {
        let content = Data("BT /F1 \(size) Tf 1 0 0 1 40 220 Tm \(show) ET\n".utf8)
        let objects = [Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8),
            Data("<< /Length \(content.count) >>\nstream\n".utf8) + content + Data("endstream".utf8)]
        var pdf = Data("%PDF-1.7\n".utf8), offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count); pdf.append(Data("\(index + 1) 0 obj\n".utf8)); pdf.append(object); pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count; pdf.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        pdf.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: pdf))
    }
}
