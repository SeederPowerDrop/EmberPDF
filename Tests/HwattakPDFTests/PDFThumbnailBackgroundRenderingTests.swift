// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFThumbnailBackgroundRenderingTests: XCTestCase {
    func testUnchangedFileUsesIdenticalNativePixelsIncludingCropAndRotation() async throws {
        for rotation in [0, 90, 180, 270] {
            let fixture = try makeFixture(rotation: rotation)
            defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
            let page = try XCTUnwrap(fixture.document.page(at: 0))
            let request = imageRequest(page)
            let native = page.thumbnail(of: request.targetSize, for: .cropBox)
            let background = await PDFThumbnailFileRenderer().render(
                source: fixture.source, pageIndex: 0, pageBounds: page.bounds(for: .cropBox),
                rotation: rotation, targetSize: request.targetSize)
            let raster = try XCTUnwrap(background)
            XCTAssertEqual(try bitmapBytes(NSImage(cgImage: raster.image, size: raster.size)),
                           try bitmapBytes(native))
            let image = await PageImageCache().loadImage(
                for: page, request: request, isResizing: false, fileSource: fixture.source
            )
            XCTAssertEqual(try bitmapBytes(XCTUnwrap(image)), try bitmapBytes(native))
        }
    }

    func testSlowBackgroundPreviewDoesNotBlockMainQueueAndReusesCompletedBitmap() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let page = try XCTUnwrap(fixture.document.page(at: 0))
        let request = imageRequest(page)
        let renderer = SlowThumbnailRenderer()
        let cache = PageImageCache(fileRenderer: renderer)
        let task = Task { await cache.loadImage(for: page, request: request,
                                               isResizing: false, fileSource: fixture.source) }
        let heartbeat = expectation(description: "The main queue runs while a native raster is busy")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            XCTAssertFalse(renderer.state.finished)
            heartbeat.fulfill()
        }
        await fulfillment(of: [heartbeat], timeout: 0.2)
        let completed = await task.value
        let image = try XCTUnwrap(completed)
        XCTAssertTrue(cache.cachedImage(for: request) === image)
        let repeated = await cache.loadImage(for: page, request: request,
                                             isResizing: false, fileSource: fixture.source)
        XCTAssertTrue(repeated === image)
        XCTAssertEqual(renderer.state.callCount, 1)
        XCTAssertFalse(renderer.state.ranOnMainThread)
    }

    func testCancelledInFlightBackgroundPreviewDoesNotPopulateCache() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let page = try XCTUnwrap(fixture.document.page(at: 0))
        let request = imageRequest(page)
        let renderer = SlowThumbnailRenderer()
        let cache = PageImageCache(fileRenderer: renderer)
        let task = Task { await cache.loadImage(for: page, request: request,
                                               isResizing: false, fileSource: fixture.source) }
        for _ in 0..<100 where renderer.state.callCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(renderer.state.callCount, 1)
        task.cancel()
        let image = await task.value
        XCTAssertNil(image)
        XCTAssertNil(cache.cachedImage(for: request))
    }

    func testAnnotatedOrInMemoryPagesKeepTheirCurrentOwningPage() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let page = try XCTUnwrap(fixture.document.page(at: 0))
        let annotation = PDFAnnotation(bounds: CGRect(x: 35, y: 42, width: 90, height: 75),
                                       forType: .square, withProperties: nil)
        annotation.color = .red
        annotation.interiorColor = .red
        page.addAnnotation(annotation)
        let renderer = SlowThumbnailRenderer()
        let cache = PageImageCache(fileRenderer: renderer)
        let request = imageRequest(page)
        let image = await cache.loadImage(for: page, request: request,
                                          isResizing: false, fileSource: fixture.source)
        XCTAssertEqual(try bitmapBytes(XCTUnwrap(image)),
                       try bitmapBytes(page.thumbnail(of: request.targetSize, for: .cropBox)))
        XCTAssertEqual(renderer.state.callCount, 0)

        let noSource = await cache.loadImage(for: page, request: imageRequest(page), isResizing: false)
        XCTAssertNotNil(noSource)
        XCTAssertEqual(renderer.state.callCount, 0)
    }

    func testDocumentEvictionDiscardsOnlyItsInFlightBackgroundResultAndAllowsFreshRequests() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let page = try XCTUnwrap(fixture.document.page(at: 0)), request = imageRequest(page)
        let renderer = SlowThumbnailRenderer(), cache = PageImageCache(fileRenderer: renderer)
        let task = Task { await cache.loadImage(for: page, request: request,
                                               isResizing: false, fileSource: fixture.source) }
        for _ in 0..<100 where renderer.state.callCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(renderer.state.callCount, 1)
        cache.removeImages(for: fixture.document)
        let retired = await task.value
        XCTAssertNil(retired)
        XCTAssertNil(cache.cachedImage(for: request))
        XCTAssertTrue(fixture.document.page(at: 0) === page)
        let fresh = await cache.loadImage(for: page, request: request,
                                          isResizing: false, fileSource: fixture.source)
        XCTAssertNotNil(fresh)
        XCTAssertTrue(cache.cachedImage(for: request) === fresh)
        XCTAssertEqual(renderer.state.callCount, 2)
    }

    func testEncryptedPagesKeepTheUnlockedOwningDocument() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let protectedURL = fixture.url.deletingLastPathComponent().appendingPathComponent("protected.pdf")
        XCTAssertTrue(fixture.document.write(to: protectedURL, withOptions: [
            .ownerPasswordOption: "Owner9", .userPasswordOption: "Reader9"
        ]))
        let document = try XCTUnwrap(PDFDocument(url: protectedURL))
        XCTAssertTrue(document.unlock(withPassword: "Reader9"))
        let page = try XCTUnwrap(document.page(at: 0))
        let renderer = SlowThumbnailRenderer()
        let source = PDFThumbnailFileSource(url: protectedURL,
            version: try PDFSourceFileVersion.capture(at: protectedURL))
        let image = await PageImageCache(fileRenderer: renderer).loadImage(
            for: page, request: imageRequest(page), isResizing: false, fileSource: source)
        XCTAssertNotNil(image)
        XCTAssertEqual(renderer.state.callCount, 0)
    }

    func testPageReorderedWhileWorkerIsBusyCannotPublishToOldIndex() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let page = try XCTUnwrap(fixture.document.page(at: 0))
        let request = imageRequest(page)
        let renderer = SlowThumbnailRenderer()
        let cache = PageImageCache(fileRenderer: renderer)
        let task = Task { await cache.loadImage(for: page, request: request,
                                               isResizing: false, fileSource: fixture.source) }
        for _ in 0..<100 where renderer.state.callCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(renderer.state.callCount, 1)
        fixture.document.insert(PDFPage(), at: 0)
        XCTAssertEqual(fixture.document.index(for: page), 1)
        let image = await task.value
        XCTAssertNil(image)
        XCTAssertNil(cache.cachedImage(for: request))
    }

    func testReplacedFileOrMismatchedPageDoesNotAuthorizeSourceRaster() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let page = try XCTUnwrap(fixture.document.page(at: 0))
        let renderer = PDFThumbnailFileRenderer()
        let wrongBounds = await renderer.render(source: fixture.source, pageIndex: 0,
            pageBounds: .zero, rotation: 0, targetSize: CGSize(width: 120, height: 160))
        XCTAssertNil(wrongBounds)
        let invalidSize = await renderer.render(source: fixture.source, pageIndex: 0,
            pageBounds: page.bounds(for: .cropBox), rotation: 0,
            targetSize: CGSize(width: CGFloat.infinity, height: 160))
        XCTAssertNil(invalidSize)
        try Data("changed source".utf8).write(to: fixture.url, options: .atomic)
        let stale = await renderer.render(source: fixture.source, pageIndex: 0,
            pageBounds: page.bounds(for: .cropBox), rotation: 0,
            targetSize: CGSize(width: 120, height: 160))
        XCTAssertNil(stale)
    }

    func testDirtyAndHibernatedWorkspacesCannotReopenTheirFileForCurrentThumbnails() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        XCTAssertNotNil(workspace.thumbnailFileSource)
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertNil(workspace.thumbnailFileSource)
        workspace.undo()
        XCTAssertFalse(workspace.isDirty)
        XCTAssertNotNil(workspace.thumbnailFileSource)
        XCTAssertTrue(workspace.hibernateIfPossible())
        XCTAssertNil(workspace.thumbnailFileSource)
    }

    private func imageRequest(_ page: PDFPage) -> PageThumbnailImageRequest {
        PageThumbnailImageRequest(pageBounds: page.bounds(for: .cropBox), rotation: page.rotation,
            pageIndex: 0, width: 160, displayScale: 2, revision: UUID(), efficientRenderingEnabled: true)
    }

    private func makeFixture(rotation: Int = 0) throws -> (url: URL, source: PDFThumbnailFileSource, document: PDFDocument) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("thumbnail.pdf")
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var box = CGRect(x: 0, y: 0, width: 300, height: 420)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 20, y: 50, width: 220, height: 280))
        context.setFillColor(NSColor.green.cgColor)
        context.fill(CGRect(x: 70, y: 75, width: 140, height: 90))
        context.endPDFPage()
        context.closePDF()
        let original = try XCTUnwrap(PDFDocument(data: data as Data))
        let originalPage = try XCTUnwrap(original.page(at: 0))
        originalPage.setBounds(CGRect(x: 15, y: 30, width: 250, height: 340), for: .cropBox)
        originalPage.rotation = rotation
        XCTAssertTrue(original.write(to: url))
        let document = try XCTUnwrap(PDFDocument(url: url))
        return (url, PDFThumbnailFileSource(url: url, version: try PDFSourceFileVersion.capture(at: url)), document)
    }

    private func bitmapBytes(_ image: NSImage) throws -> Data {
        var proposed = CGRect(origin: .zero, size: image.size)
        let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: &proposed, context: nil, hints: nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: bitmap.width, height: bitmap.height,
            bitsPerComponent: 8, bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        let bytes = try XCTUnwrap(context.data)
        return Data(bytes: bytes, count: bitmap.width * bitmap.height * 4)
    }
}

private final class ThumbnailRenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var finishedValue = false
    private var mainThread = false
    var callCount: Int { lock.withLock { calls } }
    var finished: Bool { lock.withLock { finishedValue } }
    var ranOnMainThread: Bool { lock.withLock { mainThread } }
    func start() { lock.withLock { calls += 1; mainThread = Thread.isMainThread } }
    func finish() { lock.withLock { finishedValue = true } }
}

private actor SlowThumbnailRenderer: PDFThumbnailFileRendering {
    nonisolated let state = ThumbnailRenderState()
    func render(source: PDFThumbnailFileSource, pageIndex: Int, pageBounds: CGRect,
                rotation: Int, targetSize: CGSize) -> PDFThumbnailRaster? {
        state.start()
        Thread.sleep(forTimeInterval: 0.3)
        defer { state.finish() }
        guard let context = CGContext(data: nil, width: Int(targetSize.width), height: Int(targetSize.height),
            bitsPerComponent: 8, bytesPerRow: Int(targetSize.width) * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return nil }
        return PDFThumbnailRaster(image: image, size: targetSize)
    }
}
