// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFThumbnailPaintingCacheTests: XCTestCase {
    func testUnchangedPaintingReusesOneBitmapAcrossDirtyRevisionsWithoutRasterizing() async throws {
        let document = try fixture([.blue])
        let page = try XCTUnwrap(document.page(at: 0))
        let cache = PageImageCache()
        let initial = cache.image(for: page, pageIndex: 0, width: 100, displayScale: 2,
                                  revision: UUID(), efficientRenderingEnabled: true)
        for _ in 0..<12 {
            let next = request(page, revision: UUID())
            // A cache miss during live resize cannot rasterize at all. The
            // retained bitmap therefore proves reuse without timing guesses.
            let reused = await cache.loadImage(for: page, request: next, isResizing: true)
            XCTAssertTrue(reused === initial)
            XCTAssertTrue(cache.cachedImage(for: next) === initial)
        }
        XCTAssertTrue(document.page(at: 0) === page)
    }

    func testAnnotationAdditionAndStyleChangesCannotReusePlainOrEarlierRevisionPixels() async throws {
        let document = try fixture([.blue])
        let page = try XCTUnwrap(document.page(at: 0))
        let cache = PageImageCache()
        let revision = UUID()
        let initial = cache.image(for: page, pageIndex: 0, width: 100, displayScale: 2,
                                  revision: revision, efficientRenderingEnabled: true)
        let annotation = PDFAnnotation(bounds: CGRect(x: 40, y: 50, width: 160, height: 180),
                                       forType: .square, withProperties: nil)
        annotation.color = .red
        annotation.interiorColor = .red
        page.addAnnotation(annotation)
        // Even before a revision publication, adding an annotation invalidates
        // the witness of the annotation-free painting.
        let plainRequest = request(page, revision: revision)
        let stale = await cache.loadImage(for: page, request: plainRequest, isResizing: true)
        XCTAssertNil(stale)
        let red = cache.image(for: page, pageIndex: 0, width: 100, displayScale: 2,
                              revision: UUID(), efficientRenderingEnabled: true)
        XCTAssertNotEqual(try pixels(red), try pixels(initial))
        annotation.color = .green
        annotation.interiorColor = .green
        let styledRequest = request(page, revision: UUID())
        let oldStyle = await cache.loadImage(for: page, request: styledRequest, isResizing: true)
        XCTAssertNil(oldStyle, "Annotated pages must not use a guessed cross-revision appearance fingerprint.")
        let green = cache.image(for: page, pageIndex: 0, width: 100, displayScale: 2,
                                revision: styledRequest.revision, efficientRenderingEnabled: true)
        XCTAssertNotEqual(try pixels(green), try pixels(red))
        XCTAssertEqual(try pixels(green), try pixels(page.thumbnail(of: styledRequest.targetSize, for: .cropBox)))
        XCTAssertTrue(document.page(at: 0) === page)
    }

    func testCropOriginRotationAndQualityChangesInvalidateReuse() async throws {
        let document = try fixture([.blue])
        let page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(CGRect(x: 0, y: 0, width: 220, height: 300), for: .cropBox)
        let cache = PageImageCache()
        _ = cache.image(for: page, pageIndex: 0, width: 100, displayScale: 2,
                        revision: UUID(), efficientRenderingEnabled: true)
        let oldSize = request(page).targetSize
        page.setBounds(CGRect(x: 30, y: 25, width: 220, height: 300), for: .cropBox)
        let moved = request(page)
        XCTAssertEqual(moved.targetSize, oldSize, "Origin changes can preserve every cache pixel-size scalar.")
        let uncached1 = await cache.loadImage(for: page, request: moved, isResizing: true)
        XCTAssertNil(uncached1)
        _ = cache.image(for: page, pageIndex: 0, width: 100, displayScale: 2,
                        revision: moved.revision, efficientRenderingEnabled: true)
        page.rotation = 90
        let uncached2 = await cache.loadImage(for: page, request: request(page), isResizing: true)
        XCTAssertNil(uncached2)
        _ = cache.image(for: page, pageIndex: 0, width: 100, displayScale: 2,
                        revision: UUID(), efficientRenderingEnabled: true)
        let uncached3 = await cache.loadImage(for: page, request: request(page, efficient: false), isResizing: true)
        XCTAssertNil(uncached3)
        XCTAssertTrue(document.page(at: 0) === page)
    }

    func testReorderingReusesOnlyTheIdenticalPageAndReplacementUndoKeepsCorrectPainting() async throws {
        let document = try fixture([.blue, .red])
        let bluePage = try XCTUnwrap(document.page(at: 0))
        let redPage = try XCTUnwrap(document.page(at: 1))
        let cache = PageImageCache()
        let blue = cache.image(for: bluePage, pageIndex: 0, width: 100, displayScale: 2,
                               revision: UUID(), efficientRenderingEnabled: true)
        let red = cache.image(for: redPage, pageIndex: 1, width: 100, displayScale: 2,
                              revision: UUID(), efficientRenderingEnabled: true)
        document.removePage(at: 1)
        document.insert(redPage, at: 0)
        let reused4 = await cache.loadImage(for: bluePage, request: request(bluePage, index: 1), isResizing: true)
        XCTAssertTrue(reused4 === blue)
        let reused5 = await cache.loadImage(for: redPage, request: request(redPage, index: 0), isResizing: true)
        XCTAssertTrue(reused5 === red)

        let replacementSource = try fixture([.green])
        let replacement = try XCTUnwrap(replacementSource.page(at: 0)?.copy() as? PDFPage)
        document.removePage(at: 1)
        document.insert(replacement, at: 1)
        let uncached6 = await cache.loadImage(for: replacement, request: request(replacement, index: 1), isResizing: true)
        XCTAssertNil(uncached6)
        let green = cache.image(for: replacement, pageIndex: 1, width: 100, displayScale: 2,
                                revision: UUID(), efficientRenderingEnabled: true)
        XCTAssertNotEqual(try pixels(green), try pixels(blue))
        document.removePage(at: 1)
        document.insert(bluePage, at: 1)
        let reused7 = await cache.loadImage(for: bluePage, request: request(bluePage, index: 1), isResizing: true)
        XCTAssertTrue(reused7 === blue)
        document.removePage(at: 1)
        document.insert(replacement, at: 1)
        let reused8 = await cache.loadImage(for: replacement, request: request(replacement, index: 1), isResizing: true)
        XCTAssertTrue(reused8 === green)
        XCTAssertEqual(replacementSource.pageCount, 1)
    }

    func testEqualRequestFromAnotherDocumentCannotBorrowAnOldPainting() async throws {
        let first = try fixture([.blue])
        let second = try fixture([.red])
        let bluePage = try XCTUnwrap(first.page(at: 0))
        let redPage = try XCTUnwrap(second.page(at: 0))
        let revision = UUID()
        let cache = PageImageCache()
        let blue = cache.image(for: bluePage, pageIndex: 0, width: 100, displayScale: 2,
                               revision: revision, efficientRenderingEnabled: true)
        let redRequest = request(redPage, revision: revision)
        XCTAssertEqual(redRequest, request(bluePage, revision: revision))
        let uncached9 = await cache.loadImage(for: redPage, request: redRequest, isResizing: true)
        XCTAssertNil(uncached9)
        let red = cache.image(for: redPage, pageIndex: 0, width: 100, displayScale: 2,
                              revision: revision, efficientRenderingEnabled: true)
        XCTAssertNotEqual(try pixels(red), try pixels(blue))
        let reused10 = await cache.loadImage(for: bluePage, request: request(bluePage, revision: revision), isResizing: true)
        XCTAssertTrue(reused10 === blue)
        XCTAssertEqual(first.pageCount + second.pageCount, 2)
    }

    func testCacheDoesNotRetainAClosedDocumentOrItsPage() throws {
        let cache = PageImageCache()
        weak var weakDocument: PDFDocument?
        weak var weakPage: PDFPage?
        var lastRequest: PageThumbnailImageRequest?
        try autoreleasepool {
            let document = try fixture([.blue])
            let page = try XCTUnwrap(document.page(at: 0))
            weakDocument = document
            weakPage = page
            let value = request(page)
            lastRequest = value
            _ = cache.image(for: page, pageIndex: 0, width: 100, displayScale: 2,
                            revision: value.revision, efficientRenderingEnabled: true)
        }
        XCTAssertNil(weakDocument)
        XCTAssertNil(weakPage)
        XCTAssertNil(cache.cachedImage(for: try XCTUnwrap(lastRequest)))
    }

    func testRemovingOneLiveDocumentEvictsItsPixelsWithoutClearingAnotherDocument() throws {
        let first = try fixture([.blue]), second = try fixture([.red])
        let firstPage = try XCTUnwrap(first.page(at: 0)), secondPage = try XCTUnwrap(second.page(at: 0))
        let firstRequest = request(firstPage), secondRequest = request(secondPage)
        let cache = PageImageCache()
        let firstImage = cache.image(for: firstPage, pageIndex: 0, width: 100, displayScale: 2,
                                    revision: firstRequest.revision, efficientRenderingEnabled: true)
        let secondImage = cache.image(for: secondPage, pageIndex: 0, width: 100, displayScale: 2,
                                     revision: secondRequest.revision, efficientRenderingEnabled: true)
        XCTAssertTrue(cache.cachedImage(for: firstRequest) === firstImage)
        XCTAssertTrue(cache.cachedImage(for: secondRequest) === secondImage)
        cache.removeImages(for: first)
        // Keep both documents/pages alive: nil must prove eviction, not a
        // failed weak-page identity check after deallocation.
        XCTAssertTrue(first.page(at: 0) === firstPage)
        XCTAssertNil(cache.cachedImage(for: firstRequest))
        XCTAssertTrue(cache.cachedImage(for: secondRequest) === secondImage)
        let renderedAgain = cache.image(for: firstPage, pageIndex: 0, width: 100, displayScale: 2,
                                        revision: firstRequest.revision, efficientRenderingEnabled: true)
        XCTAssertEqual(try pixels(renderedAgain), try pixels(firstImage))
        XCTAssertTrue(cache.cachedImage(for: secondRequest) === secondImage)
    }

    func testWorkspaceReplacementHibernationAndCloseRetireOnlyTheOldDocumentCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.pdf")
        let secondURL = directory.appendingPathComponent("second.pdf")
        try XCTUnwrap(fixture([.blue]).dataRepresentation()).write(to: firstURL)
        try XCTUnwrap(fixture([.green]).dataRepresentation()).write(to: secondURL)
        let workspace = PDFWorkspaceState(), cache = PageImageCache.shared
        let other = try fixture([.red]), otherPage = try XCTUnwrap(other.page(at: 0))
        defer { cache.removeImages(for: other) }
        let otherRequest = request(otherPage)
        let otherImage = cache.image(for: otherPage, pageIndex: 0, width: 100, displayScale: 2,
                                    revision: otherRequest.revision, efficientRenderingEnabled: true)
        XCTAssertTrue(workspace.open(url: firstURL))
        let oldDocument = try XCTUnwrap(workspace.document), oldPage = try XCTUnwrap(oldDocument.page(at: 0))
        let oldRequest = request(oldPage)
        _ = cache.image(for: oldPage, pageIndex: 0, width: 100, displayScale: 2,
                        revision: oldRequest.revision, efficientRenderingEnabled: true)
        XCTAssertNotNil(cache.cachedImage(for: oldRequest))
        XCTAssertTrue(workspace.open(url: secondURL))
        XCTAssertTrue(oldDocument.page(at: 0) === oldPage)
        XCTAssertNil(cache.cachedImage(for: oldRequest))
        XCTAssertTrue(cache.cachedImage(for: otherRequest) === otherImage)

        let activeDocument = try XCTUnwrap(workspace.document), activePage = try XCTUnwrap(activeDocument.page(at: 0))
        let activeRequest = request(activePage)
        _ = cache.image(for: activePage, pageIndex: 0, width: 100, displayScale: 2,
                        revision: activeRequest.revision, efficientRenderingEnabled: true)
        XCTAssertNotNil(cache.cachedImage(for: activeRequest))
        XCTAssertTrue(workspace.hibernateIfPossible())
        XCTAssertTrue(activeDocument.page(at: 0) === activePage)
        XCTAssertNil(cache.cachedImage(for: activeRequest))
        XCTAssertTrue(cache.cachedImage(for: otherRequest) === otherImage)

        XCTAssertTrue(workspace.resumeIfNeeded())
        let resumedDocument = try XCTUnwrap(workspace.document), resumedPage = try XCTUnwrap(resumedDocument.page(at: 0))
        let resumedRequest = request(resumedPage)
        _ = cache.image(for: resumedPage, pageIndex: 0, width: 100, displayScale: 2,
                        revision: resumedRequest.revision, efficientRenderingEnabled: true)
        XCTAssertNotNil(cache.cachedImage(for: resumedRequest))
        workspace.close()
        XCTAssertNil(workspace.document)
        XCTAssertTrue(resumedDocument.page(at: 0) === resumedPage)
        XCTAssertNil(cache.cachedImage(for: resumedRequest))
        XCTAssertTrue(cache.cachedImage(for: otherRequest) === otherImage)
    }

    private func request(_ page: PDFPage, index: Int = 0, revision: UUID = UUID(),
                         efficient: Bool = true) -> PageThumbnailImageRequest {
        PageThumbnailImageRequest(pageBounds: page.bounds(for: .cropBox), rotation: page.rotation,
            pageIndex: index, width: 100, displayScale: 2, revision: revision,
            efficientRenderingEnabled: efficient)
    }

    private func fixture(_ colors: [NSColor]) throws -> PDFDocument {
        let bytes = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 420)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for color in colors {
            context.beginPDFPage(nil)
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 10, y: 20, width: 270, height: 380))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 5, y: 10, width: 80, height: 40))
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: bytes as Data))
    }

    private func pixels(_ image: NSImage) throws -> Data {
        var bounds = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &bounds, context: nil, hints: nil))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: cgImage.width, height: cgImage.height,
            bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return Data(bytes: try XCTUnwrap(bitmap.data), count: cgImage.width * cgImage.height * 4)
    }
}
