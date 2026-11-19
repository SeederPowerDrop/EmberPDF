// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PageThumbnailRenderingTests: XCTestCase {
    func testVectorPageHasEnoughBitmapPixelsForOneAndTwoTimesDisplaysInBothModes() throws {
        for efficient in [true, false] {
            let document = try vectorDocument()
            let page = try XCTUnwrap(document.page(at: 0))
            let revision = UUID()
            let one = thumbnail(page, width: 320, scale: 1, revision: revision, efficient: efficient)
            let two = thumbnail(page, width: 320, scale: 2, revision: revision, efficient: efficient)
            let onePixels = try bitmapSize(of: one)
            let twoPixels = try bitmapSize(of: two)

            // Inspect the actual raster rather than NSImage's logical size.
            // PDFKit can round a 640 px request down to 639 px on this OS.
            XCTAssertEqual(onePixels.width, 320, accuracy: 2)
            XCTAssertEqual(twoPixels.width, 640, accuracy: 2)
            XCTAssertEqual(onePixels.height, 320 * 792 / 612, accuracy: 3)
            XCTAssertEqual(twoPixels.height, 640 * 792 / 612, accuracy: 3)
            XCTAssertGreaterThan(twoPixels.width, onePixels.width * 1.95)
            XCTAssertGreaterThan(twoPixels.height, onePixels.height * 1.95)
        }
    }

    func testCacheSeparatesBackingResolutionsAndReusesAnIdenticalRequest() throws {
        for efficient in [true, false] {
            let document = try vectorDocument()
            let page = try XCTUnwrap(document.page(at: 0))
            let revision = UUID()
            let one = thumbnail(page, width: 320, scale: 1, revision: revision, efficient: efficient)
            let two = thumbnail(page, width: 320, scale: 2, revision: revision, efficient: efficient)
            let repeated = thumbnail(page, width: 320, scale: 2, revision: revision, efficient: efficient)
            let oneAgain = thumbnail(page, width: 320, scale: 1, revision: revision, efficient: efficient)

            XCTAssertFalse(one === two, "A Retina request must not reuse the lower-resolution raster.")
            XCTAssertTrue(two === repeated, "Repeated visible cells should reuse the same raster.")
            XCTAssertTrue(one === oneAgain)
            XCTAssertGreaterThan(try bitmapSize(of: repeated).width, try bitmapSize(of: oneAgain).width)
        }
    }

    func testRotatingAPageRerendersTheCorrectLandscapeAndPortraitAspect() throws {
        for efficient in [true, false] {
            let document = try vectorDocument()
            let page = try XCTUnwrap(document.page(at: 0))
            let revision = UUID()
            let portrait = thumbnail(page, width: 320, scale: 2, revision: revision, efficient: efficient)
            page.rotation = 90
            let landscape = thumbnail(page, width: 320, scale: 2, revision: revision, efficient: efficient)
            let landscapePixels = try bitmapSize(of: landscape)
            XCTAssertFalse(portrait === landscape)
            XCTAssertEqual(landscapePixels.width, 640, accuracy: 2)
            XCTAssertEqual(landscapePixels.height, 640 * 612 / 792, accuracy: 3)
            XCTAssertGreaterThan(landscapePixels.width, landscapePixels.height)

            page.rotation = 180
            let inverted = thumbnail(page, width: 320, scale: 2, revision: revision, efficient: efficient)
            XCTAssertFalse(landscape === inverted)
            XCTAssertFalse(portrait === inverted)
            let invertedPixels = try bitmapSize(of: inverted)
            XCTAssertEqual(invertedPixels.width, 640, accuracy: 2)
            XCTAssertEqual(invertedPixels.height, 640 * 792 / 612, accuracy: 3)
        }
    }

    func testThreeHundredPercentRetinaRequestKeepsItsActualBitmapWithinTheBudget() throws {
        for efficient in [true, false] {
            let policy = PDFThumbnailRenderingPolicy(efficientRenderingEnabled: efficient)
            let document = try vectorDocument()
            let page = try XCTUnwrap(document.page(at: 0))
            let image = thumbnail(page, width: 320 * 3, scale: 2, revision: UUID(), efficient: efficient)
            let pixels = try bitmapSize(of: image)
            XCTAssertGreaterThan(pixels.width, 640, "Enlarged thumbnails should gain usable detail.")
            XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), policy.maximumDimension + 2)
            XCTAssertLessThanOrEqual(pixels.width * pixels.height, policy.maximumPixelCount + policy.maximumDimension * 4)
        }
    }

    func testInvalidBackingScalesFallBackSafelyAndExtremeRequestsRemainBounded() {
        for efficient in [true, false] {
            let policy = PDFThumbnailRenderingPolicy(efficientRenderingEnabled: efficient)
            let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
            let fallback = policy.targetSize(pageBounds: bounds, rotation: 0, requestedWidth: 320, displayScale: 1)
            for invalidScale in [CGFloat.nan, .infinity, -.infinity, -2, 0] {
                XCTAssertEqual(
                    policy.targetSize(pageBounds: bounds, rotation: 0, requestedWidth: 320, displayScale: invalidScale),
                    fallback
                )
            }
            for pageBounds in [bounds, CGRect(x: 0, y: 0, width: 1, height: 1_000_000),
                               CGRect(x: 0, y: 0, width: CGFloat.infinity, height: CGFloat.nan)] {
                for rotation in [0, 90, 180, 270] {
                    for width in [CGFloat(320 * 3), .greatestFiniteMagnitude, .nan, -1] {
                        let size = policy.targetSize(pageBounds: pageBounds, rotation: rotation,
                                                     requestedWidth: width, displayScale: .greatestFiniteMagnitude)
                        XCTAssertTrue(size.width.isFinite && size.height.isFinite)
                        XCTAssertGreaterThanOrEqual(min(size.width, size.height), 1)
                        XCTAssertLessThanOrEqual(max(size.width, size.height), policy.maximumDimension)
                        XCTAssertLessThanOrEqual(size.width * size.height, policy.maximumPixelCount)
                        XCTAssertGreaterThan(policy.estimatedBitmapCost(for: size), 0)
                        XCTAssertLessThanOrEqual(policy.estimatedBitmapCost(for: size), policy.cacheCostLimit)
                    }
                }
            }
        }
    }

    func testLiveResizeReusesExistingImageWithoutRasterizingIntermediateSizes() async throws {
        for efficient in [true, false] {
            let document = try vectorDocument()
            let page = try XCTUnwrap(document.page(at: 0))
            let revision = UUID()
            let cache = PageImageCache.shared
            let initial = thumbnail(page, width: 320, scale: 2,
                                    revision: revision, efficient: efficient)
            let initialRequest = request(page, width: 320, revision: revision, efficient: efficient)
            let cachedWhileResizing = await cache.loadImage(for: page, request: initialRequest, isResizing: true)
            XCTAssertTrue(cachedWhileResizing === initial)

            for width in [CGFloat(321), 330, 365, 410, 479, 600] {
                let transient = request(page, width: width, revision: revision, efficient: efficient)
                let image = await cache.loadImage(for: page, request: transient, isResizing: true)
                XCTAssertNil(image, "A live divider must stretch the retained raster instead of blocking on PDFKit.")
                XCTAssertNil(cache.cachedImage(for: transient))
            }

            let finalRequest = request(page, width: 600, revision: revision, efficient: efficient)
            let finalImage = await cache.loadImage(for: page, request: finalRequest, isResizing: false)
            let sharpImage = try XCTUnwrap(finalImage)
            XCTAssertFalse(sharpImage === initial)
            XCTAssertEqual(try bitmapSize(of: sharpImage).width, 1_200, accuracy: 2)
            XCTAssertTrue(cache.cachedImage(for: finalRequest) === sharpImage)
        }
    }

    func testCancelledSizeRequestDoesNotPopulateCacheAndLatestSizeStillRenders() async throws {
        let document = try vectorDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let revision = UUID()
        let stale = request(page, width: 350, revision: revision, efficient: true)
        let latest = request(page, width: 420, revision: revision, efficient: true)
        let task = Task { @MainActor in
            await PageImageCache.shared.loadImage(for: page, request: stale, isResizing: false)
        }
        await Task.yield()
        task.cancel()
        let cancelledImage = await task.value
        XCTAssertNil(cancelledImage)
        XCTAssertNil(PageImageCache.shared.cachedImage(for: stale))

        let latestImage = await PageImageCache.shared.loadImage(for: page, request: latest, isResizing: false)
        XCTAssertEqual(try bitmapSize(of: XCTUnwrap(latestImage)).width, 840, accuracy: 2)
        XCTAssertNil(PageImageCache.shared.cachedImage(for: stale))
    }

    private func request(_ page: PDFPage, width: CGFloat, revision: UUID,
                         efficient: Bool) -> PageThumbnailImageRequest {
        PageThumbnailImageRequest(pageBounds: page.bounds(for: .cropBox), rotation: page.rotation,
                                  pageIndex: 0, width: width, displayScale: 2,
                                  revision: revision, efficientRenderingEnabled: efficient)
    }

    private func thumbnail(_ page: PDFPage, width: CGFloat, scale: CGFloat,
                           revision: UUID, efficient: Bool) -> NSImage {
        PageImageCache.shared.image(for: page, pageIndex: 0, width: width, displayScale: scale,
                                    revision: revision, efficientRenderingEnabled: efficient)
    }

    private func bitmapSize(of image: NSImage) throws -> CGSize {
        var proposed = CGRect(origin: .zero, size: image.size)
        let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: &proposed, context: nil, hints: nil))
        return CGSize(width: CGFloat(bitmap.width), height: CGFloat(bitmap.height))
    }

    private func vectorDocument() throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(box)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "Retina thumbnail — \(UUID().uuidString)",
            attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]
        ))
        context.textPosition = CGPoint(x: 30, y: 740)
        CTLineDraw(line, context)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(0.5)
        for index in 0..<30 {
            let x = 30 + CGFloat(index) * 6
            context.move(to: CGPoint(x: x, y: 80))
            context.addLine(to: CGPoint(x: x, y: 680))
        }
        context.strokePath()
        context.endPDFPage()
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }
}
