// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFGallerySearchPreviewTests: XCTestCase {
    @MainActor
    func testExplicitResultPageAndMarkerDoNotMutateReaderOrOriginalPixels() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        let document = try XCTUnwrap(workspace.document)
        workspace.selectedPages = [0, 1]
        workspace.recordPDFViewport(autoScales: false, scaleFactor: 1.5,
                                    scrollProgress: PDFScrollProgress(horizontal: 0.2, vertical: 0.6))
        let selection = try XCTUnwrap(document.page(at: 0)?.selection(for: NSRange(location: 0, length: 5)))
        workspace.currentSelection = selection
        let revision = workspace.revision
        let viewport = workspace.pdfViewportState
        let sourceBytes = try Data(contentsOf: fixture.url)
        let result = try hit(in: document, pageIndex: 1)
        let service = PDFDocumentGalleryPreviewService(debounceNanoseconds: 0)

        let currentValue = await service.preview(for: workspace, width: 320)
        let current = try XCTUnwrap(currentValue)
        let plainValue = await service.preview(for: workspace, pageIndex: 1, width: 320)
        let plain = try XCTUnwrap(plainValue)
        let markedValue = await service.preview(for: workspace, pageIndex: 1, highlight: result, width: 320)
        let marked = try XCTUnwrap(markedValue)
        XCTAssertEqual(marked.pageIndex, 1)
        XCTAssertEqual(marked.pageCount, 2)
        XCTAssertNotNil(try changedPixelBounds(plain.image, marked.image))
        let currentAgainValue = await service.preview(for: workspace, width: 320)
        let currentAgain = try XCTUnwrap(currentAgainValue)
        let plainAgainValue = await service.preview(for: workspace, pageIndex: 1, width: 320)
        let plainAgain = try XCTUnwrap(plainAgainValue)
        XCTAssertNil(try changedPixelBounds(current.image, currentAgain.image))
        XCTAssertNil(try changedPixelBounds(plain.image, plainAgain.image))

        XCTAssertEqual(workspace.currentPageIndex, 0)
        XCTAssertEqual(workspace.selectedPages, [0, 1])
        XCTAssertTrue(workspace.currentSelection === selection)
        XCTAssertNil(workspace.activeSearchSelection)
        XCTAssertTrue(workspace.searchResults.isEmpty)
        XCTAssertEqual(workspace.pdfViewportState, viewport)
        XCTAssertEqual(workspace.revision, revision)
        XCTAssertTrue(workspace.document === document)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertTrue(document.page(at: 1)?.annotations.isEmpty == true)
        XCTAssertEqual(try Data(contentsOf: fixture.url), sourceBytes)

        // Owner unlock permits the same marker as the gallery search backend,
        // even when the PDF's user permission bits prohibit text extraction.
        let protectedURL = fixture.directory.appendingPathComponent("owner-only.pdf")
        XCTAssertTrue(document.write(to: protectedURL, withOptions: [
            .ownerPasswordOption: "Owner9", .userPasswordOption: "Reader9",
            .accessPermissionsOption: NSNumber(value: 0),
            PDFDocumentWriteOption(rawValue: kCGPDFContextEncryptionKeyLength as String): 128
        ]))
        let protectedBytes = try Data(contentsOf: protectedURL)
        for owner in [true, false] {
            let protected = PDFWorkspaceState(passwordProvider: { _, _ in owner ? "Owner9" : "Reader9" })
            XCTAssertTrue(protected.open(url: protectedURL))
            let protectedDocument = try XCTUnwrap(protected.document)
            XCTAssertEqual(protectedDocument.permissionsStatus, owner ? .owner : .user)
            let protectedHit = try hit(in: protectedDocument, pageIndex: 1)
            let plainValue = await service.preview(for: protected, pageIndex: 1, width: 320)
            let plain = try XCTUnwrap(plainValue)
            let markedValue = await service.preview(for: protected, pageIndex: 1, highlight: protectedHit, width: 320)
            let marked = try XCTUnwrap(markedValue)
            let markerBounds = try changedPixelBounds(plain.image, marked.image)
            if owner {
                XCTAssertNotNil(markerBounds, "An owner-authorized search result must have its preview marker.")
            } else {
                XCTAssertFalse(protectedDocument.allowsCopying)
                XCTAssertNil(markerBounds, "User copy restrictions must still suppress extracted-text markers.")
            }
            XCTAssertEqual(protected.currentPageIndex, 0)
            XCTAssertFalse(protected.isDirty)
        }
        XCTAssertEqual(try Data(contentsOf: protectedURL), protectedBytes)
    }

    @MainActor
    func testExplicitLazyPageDoesNotResumeTabOrChangeSavedPosition() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let sourceDocument = try XCTUnwrap(PDFDocument(url: fixture.url))
        let result = try hit(in: sourceDocument, pageIndex: 1)
        let workspace = PDFWorkspaceState()
        workspace.restoreHibernated(url: fixture.url, pageCount: 2, currentPageIndex: 0)
        workspace.selectedPages = [0]
        let revision = workspace.revision
        let sourceBytes = try Data(contentsOf: fixture.url)
        let service = PDFDocumentGalleryPreviewService(debounceNanoseconds: 0)
        let value = await service.preview(for: workspace, pageIndex: 1, highlight: result, width: 320)
        let preview = try XCTUnwrap(value)
        XCTAssertEqual(preview.pageIndex, 1)
        XCTAssertTrue(workspace.isHibernated)
        XCTAssertNil(workspace.document)
        XCTAssertEqual(workspace.currentPageIndex, 0)
        XCTAssertEqual(workspace.selectedPages, [0])
        XCTAssertEqual(workspace.revision, revision)
        XCTAssertNil(workspace.currentSelection)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertNil(workspace.presentedError)
        XCTAssertEqual(try Data(contentsOf: fixture.url), sourceBytes)
    }

    @MainActor
    func testInvalidStaleAndWrongPageMarkersLeavePreviewUnhighlighted() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        let document = try XCTUnwrap(workspace.document)
        let valid = try hit(in: document, pageIndex: 1)
        let service = PDFDocumentGalleryPreviewService(debounceNanoseconds: 0)
        let plainValue = await service.preview(for: workspace, pageIndex: 1, width: 320)
        let plain = try XCTUnwrap(plainValue)
        let variants: [(Int, NSRange, String)] = [
            (1, NSRange(location: NSNotFound, length: 1), "needle"),
            (1, NSRange(location: 0, length: Int.max), "needle"),
            (1, NSRange(location: -1, length: 1), "needle"),
            (1, valid.sourceRange, "changed"),
            (0, valid.sourceRange, valid.matchedText)
        ]
        for (page, range, text) in variants {
            let result = PDFSearchResult(pageIndex: page, pageLabel: "2", snippet: text,
                                         snippetMatchRanges: [], sourceRange: range, matchedText: text)
            let value = await service.preview(for: workspace, pageIndex: 1, highlight: result, width: 320)
            let preview = try XCTUnwrap(value)
            XCTAssertNil(try changedPixelBounds(plain.image, preview.image), "Rejected marker: \(page), \(range)")
        }
        let invalidPage = await service.preview(for: workspace, pageIndex: Int.max, highlight: valid)
        XCTAssertNil(invalidPage)
        XCTAssertEqual(workspace.currentPageIndex, 0)
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    func testSearchMarkerFollowsRotatedCroppedTextGeometry() async throws {
        for rotation in [0, 90, 180, 270] {
            let fixture = try makeFixture(rotation: rotation)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let workspace = PDFWorkspaceState()
            XCTAssertTrue(workspace.open(url: fixture.url))
            let document = try XCTUnwrap(workspace.document)
            let page = try XCTUnwrap(document.page(at: 1))
            let result = try hit(in: document, pageIndex: 1)
            let selection = try XCTUnwrap(page.selection(for: result.sourceRange))
            let service = PDFDocumentGalleryPreviewService(debounceNanoseconds: 0)
            let plainValue = await service.preview(for: workspace, pageIndex: 1, width: 320)
            let plain = try XCTUnwrap(plainValue)
            let markedValue = await service.preview(for: workspace, pageIndex: 1, highlight: result, width: 320)
            let marked = try XCTUnwrap(markedValue)
            let changed = try XCTUnwrap(changedPixelBounds(plain.image, marked.image))

            // Core Graphics independently maps PDF coordinates (including crop
            // origin and /Rotate) into the displayed raster; bitmap rows run
            // from its top edge rather than PDF's bottom edge.
            let pageRef = try XCTUnwrap(page.pageRef)
            let target = CGRect(origin: .zero, size: marked.pixelSize)
            // getDrawingTransform does not upscale into a larger target.
            // Normalize first so this oracle also covers Retina-size rasters.
            let unitTransform = pageRef.getDrawingTransform(
                .cropBox, rect: CGRect(x: 0, y: 0, width: 1, height: 1),
                rotate: 0, preserveAspectRatio: false
            )
            let transform = unitTransform.concatenating(
                CGAffineTransform(scaleX: marked.pixelSize.width, y: marked.pixelSize.height)
            )
            var expected = selection.bounds(for: page).insetBy(dx: -1, dy: -1).applying(transform)
            expected.origin.y = marked.pixelSize.height - expected.maxY
            XCTAssertEqual(changed.minX, expected.minX, accuracy: 3, "rotation \(rotation)")
            XCTAssertEqual(changed.minY, expected.minY, accuracy: 3, "rotation \(rotation)")
            XCTAssertEqual(changed.maxX, expected.maxX, accuracy: 3, "rotation \(rotation)")
            XCTAssertEqual(changed.maxY, expected.maxY, accuracy: 3, "rotation \(rotation)")
            XCTAssertLessThan(changed.width * changed.height, target.width * target.height * 0.10)
            XCTAssertTrue(page.annotations.isEmpty)
        }
    }

    @MainActor
    private func hit(in document: PDFDocument, pageIndex: Int) throws -> PDFSearchResult {
        let text = try XCTUnwrap(document.page(at: pageIndex)?.string)
        let range = (text as NSString).range(of: "needle")
        XCTAssertNotEqual(range.location, NSNotFound)
        return PDFSearchResult(pageIndex: pageIndex, pageLabel: String(pageIndex + 1), snippet: text,
                               snippetMatchRanges: [range], sourceRange: range, matchedText: "needle")
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private func pixels(_ image: NSImage) throws -> Pixels {
        var rect = CGRect(origin: .zero, size: image.size)
        let source = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let buffer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Pixels(width: source.width, height: source.height,
                      bytes: Array(UnsafeBufferPointer(start: buffer, count: source.width * source.height * 4)))
    }

    private func changedPixelBounds(_ first: NSImage, _ second: NSImage) throws -> CGRect? {
        let lhs = try pixels(first)
        let rhs = try pixels(second)
        XCTAssertEqual(lhs.width, rhs.width)
        XCTAssertEqual(lhs.height, rhs.height)
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return nil }
        var minX = lhs.width, minY = lhs.height, maxX = -1, maxY = -1
        for y in 0..<lhs.height {
            for x in 0..<lhs.width {
                let offset = (y * lhs.width + x) * 4
                let changed = (0..<3).contains { abs(Int(lhs.bytes[offset + $0]) - Int(rhs.bytes[offset + $0])) > 3 }
                if changed {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @MainActor
    private func makeFixture(rotation: Int = 0) throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberPDF-GallerySearchPreview-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("search-pages.pdf")
        var media = CGRect(x: 0, y: 0, width: 400, height: 500)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &media, nil))
        for index in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(media)
            let text = NSAttributedString(string: "Page \(index + 1): needle in context.", attributes: [
                .font: NSFont(name: "Helvetica", size: 18)!, .foregroundColor: NSColor.black
            ])
            context.textPosition = CGPoint(x: 70, y: 350)
            CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
            context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(url: url))
        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            page.setBounds(CGRect(x: 30, y: 60, width: 300, height: 380), for: .cropBox)
            page.rotation = rotation
        }
        XCTAssertTrue(document.write(to: url))
        return (directory, url)
    }
}
