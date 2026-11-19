// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextContentTemplateTests: XCTestCase {
    func testThirtyEightPrefixesReuseResourcesAndMatchFreshUnicodeImageSnapshots() throws {
        let document = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let content = try PDFBodyTextPageSnapshot.contentData(for: page)
        let shows = try PDFScannedContentStream.parse(content).shows
        XCTAssertGreaterThanOrEqual(shows.count, 19)
        var resourceEncodes = 0
        let template = try PDFBodyTextPageSnapshot.contentTemplate(for: page) { resourceEncodes += 1 }
        let encodedOnce = resourceEncodes
        XCTAssertGreaterThan(encodedOnce, 0, "The fixture must exercise actual image/font stream encoding.")
        let expectedPixels = try pixels(page)
        var prefixes = 0
        for show in shows.prefix(19) {
            for offset in [show.range.lowerBound, show.range.upperBound] {
                var prefix = Data(content.prefix(offset))
                prefix.append(Data("\nET\n".utf8))
                let reused = try template.data(contentOverride: prefix)
                let fresh = try PDFBodyTextPageSnapshot.data(for: page, contentOverride: prefix)
                XCTAssertEqual(reused, fresh, "Resources, geometry, object references and xref must match the existing writer.")
                let reopened = try XCTUnwrap(PDFDocument(data: reused))
                let candidate = try XCTUnwrap(reopened.page(at: 0))
                XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: candidate), prefix)
                XCTAssertEqual(try pixels(candidate), expectedPixels,
                               "Removing only invisible OCR must retain the alpha image and all visible painting.")
                prefixes += 1
            }
        }
        XCTAssertEqual(prefixes, 38)
        XCTAssertEqual(resourceEncodes, encodedOnce,
                       "Generating all38 prefix variants must not re-encode any resource stream.")
        print("BODY_CONTENT_TEMPLATE_METRICS resourceStreamsEncoded=\(encodedOnce) prefixVariants=\(prefixes) extraResourceEncodes=\(resourceEncodes - encodedOnce)")
        let complete = try XCTUnwrap(PDFDocument(data: template.data(contentOverride: content)))
        XCTAssertEqual(complete.string, document.string)
        XCTAssertTrue(complete.string?.contains("한글") == true,
                      "The embedded Unicode font and ToUnicode mapping must remain usable.")
        XCTAssertEqual(try pixels(XCTUnwrap(complete.page(at: 0))), expectedPixels)
    }

    func testTemplateKeepsItsValidatedGeometryWhenSourceLaterChanges() throws {
        let document = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let content = try PDFBodyTextPageSnapshot.contentData(for: page)
        let originalBounds = page.bounds(for: .cropBox)
        let template = try PDFBodyTextPageSnapshot.contentTemplate(for: page)
        let frozen = try template.data(contentOverride: content)
        page.setBounds(CGRect(x: 20, y: 20, width: 200, height: 150), for: .cropBox)
        page.rotation = 90
        XCTAssertEqual(try template.data(contentOverride: content), frozen)
        let reopened = try XCTUnwrap(PDFDocument(data: frozen))
        let result = try XCTUnwrap(reopened.page(at: 0))
        XCTAssertEqual(result.bounds(for: .cropBox), originalBounds)
        XCTAssertEqual(result.rotation, 0)
        XCTAssertNotEqual(try PDFBodyTextPageSnapshot.data(for: page, contentOverride: content), frozen)
    }

    func testOversizedPrefixIsRejectedWithoutPoisoningLaterVariants() throws {
        let document = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let content = try PDFBodyTextPageSnapshot.contentData(for: page)
        let template = try PDFBodyTextPageSnapshot.contentTemplate(for: page)
        let before = try template.data(contentOverride: content)
        XCTAssertThrowsError(try template.data(contentOverride: Data(count: 64 * 1_024 * 1_024 + 1)))
        XCTAssertEqual(try template.data(contentOverride: content), before)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: page), content)
    }

    func testInvalidGeometryIsRejectedBeforeEncodingResources() throws {
        let document = try fixture()
        for bounds in [CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                       CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)] {
            let page = ContentTemplateGeometryProbePage()
            page.source = document
            page.suppliedBounds = bounds
            var resourceEncodes = 0
            XCTAssertThrowsError(try PDFBodyTextPageSnapshot.contentTemplate(for: page) { resourceEncodes += 1 })
            XCTAssertEqual(resourceEncodes, 0)
        }
    }

    func testReaderPasswordDoesNotAuthorizeAContentTemplate() throws {
        let original = try fixture()
        let options: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: "Owner-template-86", .userPasswordOption: "Reader-template-86",
            .accessPermissionsOption: NSNumber(value: PDFAccessPermissions.allowsCommenting.rawValue)
        ]
        let encrypted = try XCTUnwrap(original.dataRepresentation(options: options))
        let document = try XCTUnwrap(PDFDocument(data: encrypted))
        XCTAssertTrue(document.unlock(withPassword: "Reader-template-86"))
        XCTAssertEqual(document.permissionsStatus, .user)
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.contentTemplate(for: page))
    }

    private func fixture() throws -> PDFDocument {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8,
            bytesPerRow: 48 * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(NSColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 0.7).cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 40, height: 32))
        bitmap.setFillColor(NSColor(srgbRed: 0.8, green: 0.1, blue: 0.3, alpha: 0.5).cgColor)
        bitmap.fill(CGRect(x: 10, y: 6, width: 38, height: 20))
        let image = try XCTUnwrap(bitmap.makeImage())
        let bytes = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 320, height: 300)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.draw(image, in: CGRect(x: 10, y: 8, width: 96, height: 64))
        context.setTextDrawingMode(.invisible)
        let font = try XCTUnwrap(NSFont(name: "AppleSDGothicNeo-Regular", size: 10))
        for index in 0..<19 {
            context.textPosition = CGPoint(x: 20, y: 280 - CGFloat(index) * 10)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: String(format: "row%02d 한글", index), attributes: [.font: font]))
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: bytes as Data))
    }

    private func pixels(_ page: PDFPage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 300, bitsPerComponent: 8,
            bytesPerRow: 320 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 300))
        context.drawPDFPage(try XCTUnwrap(page.pageRef))
        return Data(bytes: try XCTUnwrap(context.data), count: 320 * 300 * 4)
    }
}

private final class ContentTemplateGeometryProbePage: PDFPage {
    var source: PDFDocument?
    var suppliedBounds = CGRect.zero
    override var pageRef: CGPDFPage? { source?.page(at: 0)?.pageRef }
    override func bounds(for box: PDFDisplayBox) -> CGRect { suppliedBounds }
}
