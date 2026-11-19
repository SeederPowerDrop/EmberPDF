// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

final class PageTranslationLayoutTests: XCTestCase {
    @MainActor
    func testCapturePreservesTextAndSeparateColumnsWithExactEngineBlocks() throws {
        let document = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let layout = try PageTranslationLayout.capture(page: page, pageNumber: 7)
        XCTAssertEqual(layout.pageNumber, 7)
        XCTAssertEqual(layout.pageSize, CGSize(width: 500, height: 600))
        XCTAssertEqual(try PageTranslationInput(sourceText: layout.sourceText, targetLanguageCode: "ko").blocks(), layout.blocks)
        XCTAssertEqual(nonWhitespace(layout.sourceText), nonWhitespace(try XCTUnwrap(page.string)))
        XCTAssertTrue(layout.regions.allSatisfy { $0.source.utf16.count <= 1_200 })
        XCTAssertLessThanOrEqual(layout.regions.count, 256)
        XCTAssertFalse(layout.regions.contains { $0.source.contains("Left") && $0.source.contains("Right") })
        XCTAssertTrue(layout.regions.contains { $0.source.contains("Left one") && $0.source.contains("Left two") })
        let image = try XCTUnwrap(NSBitmapImageRep(data: layout.backgroundPNG))
        XCTAssertLessThanOrEqual(max(image.pixelsWide, image.pixelsHigh), 2_400)
        XCTAssertLessThanOrEqual(image.pixelsWide * image.pixelsHigh, 6_000_000)
        let original = try PageTranslationLayoutRenderer.originalPDFData(layout: layout)
        let translated = try PageTranslationLayoutRenderer.pdfData(layout: layout, result: result(for: layout))
        let translatedDocument = try XCTUnwrap(PDFDocument(data: translated))
        XCTAssertEqual(translatedDocument.pageCount, 1, "These ordinary translated paragraphs should fit on their original page")
        XCTAssertTrue(try XCTUnwrap(translatedDocument.string).contains("더 따뜻한 문서"))
        XCTAssertTrue(try XCTUnwrap(translatedDocument.string).contains("원문의 마지막 표시"))
        XCTAssertFalse(try XCTUnwrap(translatedDocument.string).contains("Left one"))
        try savePreview(original, name: "original")
        try savePreview(translated, name: "translated")
        try savePreview(XCTUnwrap(document.dataRepresentation()), name: "source")
    }

    @MainActor
    func testLiveQuarterTurnsAndNonzeroCropNormalizeTextAndArtworkTogether() throws {
        let document = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let original = try PageTranslationLayout.capture(page: page, pageNumber: 1)
        let crop = page.bounds(for: .cropBox)
        XCTAssertEqual(crop.origin, CGPoint(x: 30, y: 40))
        for rotation in [90, 180, 270] {
            page.rotation = rotation
            let layout = try PageTranslationLayout.capture(page: page, pageNumber: 1)
            XCTAssertEqual(layout.blocks, original.blocks)
            XCTAssertEqual(layout.pageSize, rotation == 180 ? original.pageSize : CGSize(width: 600, height: 500))
            for (before, after) in zip(original.regions, layout.regions) {
                let expected: CGRect
                switch rotation {
                case 90: expected = CGRect(x: before.bounds.minY, y: 500 - before.bounds.maxX,
                                          width: before.bounds.height, height: before.bounds.width)
                case 180: expected = CGRect(x: 500 - before.bounds.maxX, y: 600 - before.bounds.maxY,
                                           width: before.bounds.width, height: before.bounds.height)
                default: expected = CGRect(x: 600 - before.bounds.maxY, y: before.bounds.minX,
                                           width: before.bounds.height, height: before.bounds.width)
                }
                assertEqual(after.bounds, expected)
            }
            // The asymmetric blue artwork is at native (420, 115). It must
            // rotate with text geometry, not disappear or remain unrotated.
            let point: CGPoint
            switch rotation {
            case 90: point = CGPoint(x: 75, y: 110)
            case 180: point = CGPoint(x: 110, y: 525)
            default: point = CGPoint(x: 525, y: 390)
            }
            try assertBluePixel(in: layout, point: point)
            let rendered = try PageTranslationLayoutRenderer.pdfData(layout: layout, result: result(for: layout))
            let renderedPage = try XCTUnwrap(PDFDocument(data: rendered)?.page(at: 0))
            XCTAssertEqual(renderedPage.bounds(for: .mediaBox).size, layout.pageSize)
            if rotation == 90 { try savePreview(rendered, name: "rotated90") }
        }
    }

    @MainActor
    func testLongTranslationUsesNumberedContinuationAndPreservesEverySuffix() throws {
        let document = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let layout = try PageTranslationLayout.capture(page: page, pageNumber: 1)
        let translated = layout.regions.enumerated().map { index, region in
            TranslatedPageBlock(id: region.id, source: region.source,
                translated: String(repeating: "긴 번역문은 원문보다 길어져도 사라지면 안 됩니다. ", count: 90)
                    + "COMPLETE-REGION-\(index + 1)")
        }
        let result = PageTranslationResult(blocks: translated, sourceLanguageCode: "en", targetLanguageCode: "ko", engineTitle: "Fixture")
        let data = try PageTranslationLayoutRenderer.pdfData(layout: layout, result: result)
        let output = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(output.pageCount, 1)
        let firstPage = try XCTUnwrap(output.page(at: 0)?.string)
        for index in layout.regions.indices {
            XCTAssertTrue(firstPage.contains("[\(index + 1)]"))
            XCTAssertTrue(try XCTUnwrap(output.string).contains("COMPLETE-REGION-\(index + 1)"))
        }
        XCTAssertFalse(firstPage.contains("긴 번역문"), "An unreadable clipped prefix is not presented as a complete translation")
        try savePreview(data, name: "overflow")
    }

    @MainActor
    func testRejectsIncompleteDuplicateAndSourceMismatchedResults() throws {
        let document = try fixture()
        let layout = try PageTranslationLayout.capture(page: XCTUnwrap(document.page(at: 0)), pageNumber: 1)
        let good = result(for: layout)
        var duplicate = good.blocks
        duplicate[duplicate.count - 1] = duplicate[0]
        var mismatched = good.blocks
        mismatched[0] = TranslatedPageBlock(id: mismatched[0].id, source: "Wrong page", translated: "다른 페이지")
        for blocks in [Array(good.blocks.dropLast()), duplicate, mismatched] {
            XCTAssertThrowsError(try PageTranslationLayoutRenderer.pdfData(layout: layout,
                result: PageTranslationResult(blocks: blocks, sourceLanguageCode: "en", targetLanguageCode: "ko", engineTitle: "Fixture"))) {
                XCTAssertEqual($0 as? PageTranslationLayoutError, .invalidMapping)
            }
        }
    }

    @MainActor
    func testOverlappingTextRegionsFailInsteadOfDrawingUnreadableTranslations() throws {
        let document = try fixture()
        let base = try PageTranslationLayout.capture(page: XCTUnwrap(document.page(at: 0)), pageNumber: 1)
        let rect = CGRect(x: 50, y: 300, width: 200, height: 50)
        let layout = PageTranslationLayout(pageNumber: 1, pageSize: base.pageSize, backgroundPNG: base.backgroundPNG,
            regions: [.init(id: "b1", source: "First", bounds: rect),
                      .init(id: "b2", source: "Second", bounds: rect.offsetBy(dx: 0, dy: 4))])
        XCTAssertThrowsError(try PageTranslationLayoutRenderer.pdfData(layout: layout, result: result(for: layout))) {
            XCTAssertEqual($0 as? PageTranslationLayoutError, .unavailableGeometry)
        }
    }

    @MainActor
    func testDenseMixedFitAndOverflowCannotCoverNeighborWithContinuationBadge() throws {
        let document = try fixture()
        let base = try PageTranslationLayout.capture(page: XCTUnwrap(document.page(at: 0)), pageNumber: 1)
        let regions = (0..<5).map { index in
            PageTranslationLayout.Region(id: "b\(index + 1)", source: "Line \(index + 1)",
                bounds: CGRect(x: 0, y: CGFloat(index * 13), width: 200, height: 12))
        }
        let layout = PageTranslationLayout(pageNumber: 1, pageSize: CGSize(width: 200, height: 64),
            backgroundPNG: base.backgroundPNG, regions: regions)
        let blocks = regions.enumerated().map { index, region in
            TranslatedPageBlock(id: region.id, source: region.source,
                translated: index == 2 ? String(repeating: "This translation needs a continuation. ", count: 50) : ".")
        }
        let result = PageTranslationResult(blocks: blocks, sourceLanguageCode: "en", targetLanguageCode: "ko", engineTitle: "Fixture")
        XCTAssertThrowsError(try PageTranslationLayoutRenderer.pdfData(layout: layout, result: result)) {
            XCTAssertEqual($0 as? PageTranslationLayoutError, .renderingFailed)
        }
    }

    @MainActor
    func testCaptureAndRenderDoNotModifyOriginalBytesRotationCropOrAnnotations() throws {
        let document = try fixture()
        let source = try XCTUnwrap(document.dataRepresentation())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberTranslation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.pdf")
        try source.write(to: url)
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(reopened.page(at: 0))
        let crop = page.bounds(for: .cropBox)
        let rotation = page.rotation
        let annotationCount = page.annotations.count
        let layout = try PageTranslationLayout.capture(page: page, pageNumber: 1)
        _ = try PageTranslationLayoutRenderer.pdfData(layout: layout, result: result(for: layout))
        XCTAssertEqual(try Data(contentsOf: url), source)
        XCTAssertEqual(page.bounds(for: .cropBox), crop)
        XCTAssertEqual(page.rotation, rotation)
        XCTAssertEqual(page.annotations.count, annotationCount)
        XCTAssertEqual(reopened.pageCount, 1)
    }

    @MainActor
    func testKoreanSourceAndEmptyPageHandling() throws {
        let document = try fixture(korean: true)
        let layout = try PageTranslationLayout.capture(page: XCTUnwrap(document.page(at: 0)), pageNumber: 1)
        XCTAssertTrue(layout.sourceText.contains("문서"))
        let data = try PageTranslationLayoutRenderer.pdfData(layout: layout, result: result(for: layout))
        XCTAssertNotNil(PDFDocument(data: data))
        XCTAssertThrowsError(try PageTranslationLayout.capture(page: PDFPage(), pageNumber: 1)) {
            XCTAssertEqual($0 as? PageTranslationError, .emptySource)
        }
    }

    @MainActor
    private func fixture(korean: Bool = false) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 560, height: 700)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(box)
        func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black
            ]) as CFAttributedString)
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
        text(korean ? "문서를 따뜻하게" : "A warmer document", x: 55, y: 585, size: 20)
        text(korean ? "문서 첫째 줄입니다." : "Left one: a clear page.", x: 55, y: 520, size: 12)
        text(korean ? "문서 둘째 줄입니다." : "Left two: a lasting tool.", x: 55, y: 504, size: 12)
        text(korean ? "오른쪽 문단입니다." : "Right: a separate column.", x: 310, y: 520, size: 12)
        text(korean ? "모든 글자를 보존합니다." : "Final source marker.", x: 55, y: 400, size: 12)
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 380, y: 90, width: 80, height: 50))
        context.endPDFPage()
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        try XCTUnwrap(document.page(at: 0)).setBounds(CGRect(x: 30, y: 40, width: 500, height: 600), for: .cropBox)
        return document
    }

    private func result(for layout: PageTranslationLayout) -> PageTranslationResult {
        PageTranslationResult(blocks: layout.regions.map { region in
            let translated: String
            switch region.source {
            case "A warmer document": translated = "더 따뜻한 문서"
            case let source where source.contains("Left one"):
                translated = "첫째: 선명한 페이지.\n둘째: 오래 쓰는 도구."
            case let source where source.contains("Right:"): translated = "오른쪽: 별도의 문단."
            case "Final source marker.": translated = "원문의 마지막 표시."
            case "문서를 따뜻하게": translated = "Warmth for documents"
            case let source where source.contains("문서 첫째"): translated = "First line of the document.\nSecond line of the document."
            case "오른쪽 문단입니다.": translated = "A paragraph on the right."
            case "모든 글자를 보존합니다.": translated = "Every character is preserved."
            default: translated = "Translation of this region."
            }
            return TranslatedPageBlock(id: region.id, source: region.source, translated: translated)
        }, sourceLanguageCode: "en", targetLanguageCode: "ko", engineTitle: "Fixture")
    }

    private func nonWhitespace(_ string: String) -> String {
        String(string.filter { !$0.isWhitespace })
    }

    private func assertEqual(_ lhs: CGRect, _ rhs: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.minX, rhs.minX, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(lhs.minY, rhs.minY, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, accuracy: 0.01, file: file, line: line)
    }

    private func assertBluePixel(in layout: PageTranslationLayout, point: CGPoint, file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(NSBitmapImageRep(data: layout.backgroundPNG))
        let x = Int(point.x / layout.pageSize.width * CGFloat(image.pixelsWide))
        let y = Int((1 - point.y / layout.pageSize.height) * CGFloat(image.pixelsHigh))
        let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.blueComponent, color.redComponent + 0.4, file: file, line: line)
    }

    @MainActor
    private func savePreview(_ data: Data, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["EMBER_TRANSLATION_QA_OUTPUT"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".pdf"), options: .atomic)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 0))
        let thumbnail = page.thumbnail(of: CGSize(width: 1_000, height: 1_200), for: .cropBox)
        let tiff = try XCTUnwrap(thumbnail.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
