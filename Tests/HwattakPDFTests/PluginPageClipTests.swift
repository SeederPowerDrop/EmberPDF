// SPDX-License-Identifier: MPL-2.0

import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import HwattakPDF

final class PluginPageClipTests: XCTestCase {
    @MainActor
    func testRotatedCropUsesDisplayedCoordinatesAndPreservesSource() throws {
        for rotation in [0, 90, 180, 270] {
            let fixture = try makeFixture(rotation: rotation)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let workspace = PDFWorkspaceState()
            XCTAssertTrue(workspace.open(url: fixture.url))
            let document = try XCTUnwrap(workspace.document)
            let page = try XCTUnwrap(document.page(at: 0))
            let bytes = try Data(contentsOf: fixture.url)
            let revision = workspace.revision
            workspace.recordPDFViewport(autoScales: false, scaleFactor: 1.5,
                                        scrollProgress: PDFScrollProgress(horizontal: 0.25, vertical: 0.6))
            let viewport = workspace.pdfViewportState
            let snapshot = try PluginPageClipService.capture(workspace: workspace, documentRevision: revision, isAuthorized: { true })
            let size = snapshot.pixelSize
            XCTAssertEqual(size, rotation % 180 == 0 ? CGSize(width: 600, height: 760) : CGSize(width: 760, height: 600))

            // CGPDF's fitting transform does not upscale a small page to a
            // larger destination: using the 2x raster rectangle centers a 1x
            // page and is not an oracle for a full-size Retina rendering.
            // Obtain an independent transform at the fixture's display size
            // in points, then convert those coordinates into raster pixels.
            let pageRef = try XCTUnwrap(page.pageRef)
            let displayPoints = rotation % 180 == 0 ? CGSize(width: 300, height: 380) : CGSize(width: 380, height: 300)
            let transform = pageRef.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: displayPoints), rotate: 0, preserveAspectRatio: false)
            var displayed = CGRect(x: 80, y: 300, width: 60, height: 50).applying(transform)
            displayed.origin.y = displayPoints.height - displayed.maxY
            displayed = displayed.applying(CGAffineTransform(scaleX: size.width / displayPoints.width,
                                                             y: size.height / displayPoints.height))
            let normalized = CGRect(x: displayed.minX / size.width, y: displayed.minY / size.height,
                                    width: displayed.width / size.width, height: displayed.height / size.height)
            let png = try PluginPageClipService.pngData(snapshot, normalizedRect: normalized, workspace: workspace, isAuthorized: { true })
            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let center = try centerPixel(image)
            XCTAssertGreaterThan(center.0, 220, "rotation \(rotation)")
            XCTAssertLessThan(center.1, 30, "rotation \(rotation)")
            XCTAssertLessThan(center.2, 30, "rotation \(rotation)")
            XCTAssertLessThanOrEqual(abs(CGFloat(image.width) - displayed.width), 2)
            XCTAssertLessThanOrEqual(abs(CGFloat(image.height) - displayed.height), 2)
            XCTAssertEqual(workspace.currentPageIndex, 0)
            XCTAssertEqual(workspace.revision, revision)
            XCTAssertEqual(workspace.pdfViewportState, viewport)
            XCTAssertFalse(workspace.isDirty)
            XCTAssertTrue(page.annotations.isEmpty)
            XCTAssertEqual(try Data(contentsOf: fixture.url), bytes)
        }
    }

    @MainActor
    func testInvalidGeometryAndHugePagesAreBoundedBeforeAllocation() throws {
        let malformed: [CGRect] = [.zero, CGRect(x: 0, y: 0, width: -1, height: 10),
            CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1), CGRect(x: 0, y: 0, width: CGFloat.nan, height: 2),
            CGRect(x: 0, y: 0, width: 100_001, height: 20)]
        for bounds in malformed {
            XCTAssertThrowsError(try PluginPageClipService.targetSize(pageBounds: bounds, rotation: 0))
        }
        XCTAssertThrowsError(try PluginPageClipService.targetSize(pageBounds: CGRect(x: 0, y: 0, width: 100, height: 200), rotation: 45))
        for rotation in [0, 90, -90, 720] {
            let size = try PluginPageClipService.targetSize(pageBounds: CGRect(x: 5, y: 8, width: 100_000, height: 80_000), rotation: rotation)
            XCTAssertLessThanOrEqual(size.width * size.height, CGFloat(PluginPageClipService.maximumPixelCount))
            XCTAssertLessThanOrEqual(max(size.width, size.height), CGFloat(PluginPageClipService.maximumPixelEdge))
        }
        let invalidRegions: [CGRect] = [.zero, CGRect(x: -0.1, y: 0, width: 0.5, height: 0.5),
            CGRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5), CGRect(x: 0, y: 0, width: .infinity, height: 0.5),
            CGRect(x: 0, y: 0, width: -0.5, height: 0.5)]
        for region in invalidRegions {
            XCTAssertThrowsError(try PluginPageClipService.pixelRect(region, pixelSize: CGSize(width: 200, height: 300)))
        }
    }

    @MainActor
    func testCopyPermissionsIncludeOwnerUnlockAndNeverModifyEncryptedSource() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try XCTUnwrap(PDFDocument(url: fixture.url))
        let protectedURL = fixture.directory.appendingPathComponent("restricted.pdf")
        XCTAssertTrue(source.write(to: protectedURL, withOptions: [
            .ownerPasswordOption: "Owner9", .userPasswordOption: "Reader9", .accessPermissionsOption: NSNumber(value: 0),
            PDFDocumentWriteOption(rawValue: kCGPDFContextEncryptionKeyLength as String): 128
        ]))
        let bytes = try Data(contentsOf: protectedURL)
        for owner in [false, true] {
            let workspace = PDFWorkspaceState(passwordProvider: { _, _ in owner ? "Owner9" : "Reader9" })
            XCTAssertTrue(workspace.open(url: protectedURL))
            XCTAssertEqual(workspace.document?.permissionsStatus, owner ? .owner : .user)
            if owner {
                XCTAssertNoThrow(try PluginPageClipService.capture(workspace: workspace, documentRevision: workspace.revision, isAuthorized: { true }))
            } else {
                XCTAssertThrowsError(try PluginPageClipService.capture(workspace: workspace, documentRevision: workspace.revision, isAuthorized: { true })) {
                    XCTAssertEqual($0 as? PluginPageClipService.ClipError, .copyRestricted)
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: protectedURL), bytes)
    }

    @MainActor
    func testRevocationPreventsCopySaveAndDelayedDragWithoutSideEffects() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        let snapshot = try PluginPageClipService.capture(workspace: workspace, documentRevision: workspace.revision, isAuthorized: { true })
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("EmberPDF-clip-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("untouched", forType: .string)
        let destination = fixture.directory.appendingPathComponent("must-not-exist.png")
        let permission = MutablePermission()
        let provider = try PluginPageClipService.dragProvider(snapshot, normalizedRect: full, workspace: workspace, isAuthorized: { permission.allowed })
        XCTAssertEqual(provider.registeredTypeIdentifiers, [UTType.png.identifier])
        permission.allowed = false
        XCTAssertThrowsError(try PluginPageClipService.copy(snapshot, normalizedRect: full, workspace: workspace, isAuthorized: { false }, pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
        XCTAssertThrowsError(try PluginPageClipService.save(snapshot, normalizedRect: full, to: destination, workspace: workspace, isAuthorized: { false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertThrowsError(try PluginPageClipService.dragProvider(snapshot, normalizedRect: full, workspace: workspace, isAuthorized: { false }))
        do { _ = try await loadPNG(provider); XCTFail("A revoked drag must not transfer data later.") } catch { }
    }

    @MainActor
    func testClipboardSaveAndDragExportOnlyPNGAndRejectSourceAliases() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let bytes = try Data(contentsOf: fixture.url)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        let snapshot = try PluginPageClipService.capture(workspace: workspace, documentRevision: workspace.revision, isAuthorized: { true })
        let region = CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.3)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("EmberPDF-clip-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        try PluginPageClipService.copy(snapshot, normalizedRect: region, workspace: workspace, isAuthorized: { true }, pasteboard: pasteboard)
        let copied = try XCTUnwrap(pasteboard.data(forType: .png))
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertNil(pasteboard.string(forType: .fileURL))
        let saved = fixture.directory.appendingPathComponent("clip.png")
        try PluginPageClipService.save(snapshot, normalizedRect: region, to: saved, workspace: workspace, isAuthorized: { true })
        XCTAssertEqual(try Data(contentsOf: saved), copied)
        let provider = try PluginPageClipService.dragProvider(snapshot, normalizedRect: region, workspace: workspace, isAuthorized: { true })
        let dragged = try await loadPNG(provider)
        XCTAssertEqual(dragged, copied)
        for symbolic in [false, true] {
            let alias = fixture.directory.appendingPathComponent(symbolic ? "symlink.png" : "hardlink.png")
            if symbolic { try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.url) }
            else { try FileManager.default.linkItem(at: fixture.url, to: alias) }
            XCTAssertThrowsError(try PluginPageClipService.save(snapshot, normalizedRect: region, to: alias, workspace: workspace, isAuthorized: { true }))
        }
        XCTAssertThrowsError(try PluginPageClipService.save(snapshot, normalizedRect: region, to: fixture.url, workspace: workspace, isAuthorized: { true }))
        XCTAssertThrowsError(try PluginPageClipService.save(snapshot, normalizedRect: region, to: URL(string: "https://example.com/clip.png")!, workspace: workspace, isAuthorized: { true }))
        XCTAssertEqual(try Data(contentsOf: fixture.url), bytes)
    }

    @MainActor
    func testReplacedDocumentInvalidatesPreparedImage() throws {
        let first = try makeFixture()
        let second = try makeFixture(rotation: 90)
        defer { try? FileManager.default.removeItem(at: first.directory); try? FileManager.default.removeItem(at: second.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: first.url))
        let snapshot = try PluginPageClipService.capture(workspace: workspace, documentRevision: workspace.revision, isAuthorized: { true })
        XCTAssertTrue(workspace.open(url: second.url))
        XCTAssertThrowsError(try PluginPageClipService.pngData(snapshot, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), workspace: workspace, isAuthorized: { true })) {
            XCTAssertEqual($0 as? PluginPageClipService.ClipError, .stale)
        }
    }

    @MainActor private final class MutablePermission { var allowed = true }

    private func loadPNG(_ provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? PluginPageClipService.ClipError.renderFailed) }
            }
        }
    }

    private func centerPixel(_ image: CGImage) throws -> (UInt8, UInt8, UInt8) {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = ((image.height / 2) * image.width + image.width / 2) * 4
        return (data[offset], data[offset + 1], data[offset + 2])
    }

    @MainActor
    private func makeFixture(rotation: Int = 0) throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-clip-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.pdf")
        var media = CGRect(x: 0, y: 0, width: 400, height: 500)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(media)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 80, y: 300, width: 60, height: 50))
        context.endPDFPage()
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(CGRect(x: 30, y: 60, width: 300, height: 380), for: .cropBox)
        page.rotation = rotation
        XCTAssertTrue(document.write(to: url))
        return (directory, url)
    }
}
