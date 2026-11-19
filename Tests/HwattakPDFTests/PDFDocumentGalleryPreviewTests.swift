// SPDX-License-Identifier: MPL-2.0

import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import HwattakPDF

final class PDFDocumentGalleryPreviewTests: XCTestCase {
    @MainActor
    func testSevenDocumentsRenderTheirCurrentPagesWithoutActivatingLazyTabs() async throws {
        let directory = try temporaryDirectory()
        let urls = try (0..<7).map { try makePDF(in: directory, name: "document-\($0).pdf") }
        let window = MultiDocumentWorkspaceState()
        let tabIDs = window.openPDFsInTabs(urls: urls)
        XCTAssertEqual(tabIDs.count, 7)
        let tabs = window.tabs.filter { tabIDs.contains($0.id) }
        for (index, tab) in tabs.enumerated() {
            tab.workspace.currentPageIndex = index + 1
            tab.workspace.selectedPages = [0, index + 1]
            tab.workspace.recordPDFViewport(autoScales: false, scaleFactor: 1.37,
                scrollProgress: PDFScrollProgress(horizontal: 0.23, vertical: 0.67))
            if index < 6 {
                if tab.workspace.document != nil { XCTAssertTrue(tab.workspace.hibernateIfPossible()) }
                XCTAssertTrue(tab.workspace.isHibernated)
            }
        }
        let activeTab = window.activeTabID
        let activeWorkspace = window.activeWorkspaceID
        let snapshots = tabs.map { Snapshot($0.workspace) }
        let service = PDFDocumentGalleryPreviewService(debounceNanoseconds: 0)
        let tasks = tabs.map { tab in Task { @MainActor in await service.preview(for: tab.workspace, width: 200) } }
        for (index, task) in tasks.enumerated() {
            let result = await task.value
            let preview = try XCTUnwrap(result)
            XCTAssertEqual(preview.pageIndex, index + 1, "Each card must show its saved current page, not page 1")
            XCTAssertEqual(preview.pageCount, 8)
            XCTAssertEqual(preview.revision, snapshots[index].revision)
            // Each page has a distinct, color-profile-independent count of
            // white swatches. The cover has one; current pages have 2...8.
            XCTAssertEqual(try whiteSwatchCount(preview.image), index + 2)
            snapshots[index].assertUnchanged(tabs[index].workspace)
        }
        XCTAssertEqual(window.activeTabID, activeTab)
        XCTAssertEqual(window.activeWorkspaceID, activeWorkspace)
        XCTAssertEqual(tabs.filter { $0.workspace.document != nil }.count, 1)
        XCTAssertEqual(service.renderCount, 7)
    }

    @MainActor
    func testResidentUnsavedRotationUsesLivePageAndInvalidatesPriorPreview() async throws {
        let directory = try temporaryDirectory()
        let url = try makePDF(in: directory)
        let originalBytes = try Data(contentsOf: url)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setCurrentPage(3)
        workspace.selectedPages = [3]
        let service = PDFDocumentGalleryPreviewService(debounceNanoseconds: 0)
        let originalResult = await service.preview(for: workspace, width: 240)
        let original = try XCTUnwrap(originalResult)
        XCTAssertLessThan(original.pixelSize.width, original.pixelSize.height)
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(workspace.isDirty)
        let edited = Snapshot(workspace)
        let editedResult = await service.preview(for: workspace, width: 240)
        let preview = try XCTUnwrap(editedResult)
        XCTAssertGreaterThan(preview.pixelSize.width, preview.pixelSize.height)
        XCTAssertNotEqual(preview.revision, original.revision)
        XCTAssertEqual(try whiteSwatchCount(preview.image, rotated: true), 4)
        edited.assertUnchanged(workspace)
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
        XCTAssertEqual(service.renderCount, 2)
        XCTAssertEqual(service.cachedPreviewCount, 1)
    }

    @MainActor
    func testLazyFileReplacementInvalidatesCachedPixelsWithoutChangingWorkspace() async throws {
        let directory = try temporaryDirectory()
        let url = try makePDF(in: directory)
        let workspace = PDFWorkspaceState()
        workspace.restoreHibernated(url: url, pageCount: 8, currentPageIndex: 4)
        let snapshot = Snapshot(workspace)
        let service = PDFDocumentGalleryPreviewService(debounceNanoseconds: 0)
        let firstResult = await service.preview(for: workspace)
        let first = try XCTUnwrap(firstResult)
        XCTAssertEqual(try whiteSwatchCount(first.image), 5)
        _ = try makePDF(in: directory, colorOverride: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: url.path)
        let replacementResult = await service.preview(for: workspace)
        let replacement = try XCTUnwrap(replacementResult)
        XCTAssertEqual(try whiteSwatchCount(replacement.image), 8)
        XCTAssertNotEqual(try whiteSwatchCount(replacement.image), try whiteSwatchCount(first.image))
        XCTAssertEqual(service.renderCount, 2)
        XCTAssertEqual(service.cachedPreviewCount, 1)
        snapshot.assertUnchanged(workspace)
    }

    @MainActor
    func testLockedAndMissingLazyFilesDoNotPromptOrMutateWorkspaceErrors() async throws {
        let directory = try temporaryDirectory()
        let source = try makePDF(in: directory)
        let document = try XCTUnwrap(PDFDocument(url: source))
        let lockedURL = directory.appendingPathComponent("locked.pdf")
        XCTAssertTrue(document.write(to: lockedURL, withOptions: [.ownerPasswordOption: "Owner9", .userPasswordOption: "Reader9"]))
        var passwordPromptCount = 0
        let service = PDFDocumentGalleryPreviewService(debounceNanoseconds: 0)
        for url in [lockedURL, directory.appendingPathComponent("missing.pdf")] {
            let workspace = PDFWorkspaceState(passwordProvider: { _, _ in passwordPromptCount += 1; return "Reader9" })
            workspace.restoreHibernated(url: url, pageCount: 8, currentPageIndex: 2)
            let snapshot = Snapshot(workspace)
            let result = await service.preview(for: workspace)
            XCTAssertNil(result)
            snapshot.assertUnchanged(workspace)
            XCTAssertNil(workspace.presentedError)
        }
        XCTAssertEqual(passwordPromptCount, 0)
        XCTAssertEqual(service.cachedPreviewCount, 0)
    }

    @MainActor
    func testOffscreenCancellationSkipsRenderingAndCacheInsertion() async throws {
        let directory = try temporaryDirectory()
        let url = try makePDF(in: directory)
        let workspace = PDFWorkspaceState()
        workspace.restoreHibernated(url: url, pageCount: 8, currentPageIndex: 5)
        let snapshot = Snapshot(workspace)
        let service = PDFDocumentGalleryPreviewService(debounceNanoseconds: 80_000_000)
        let task = Task { @MainActor in await service.preview(for: workspace) }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(service.renderCount, 0)
        XCTAssertEqual(service.cachedByteCount, 0)
        snapshot.assertUnchanged(workspace)
    }

    @MainActor
    func testPageChangeWhileQueuedCannotPublishOldCurrentPage() async throws {
        let directory = try temporaryDirectory()
        let url = try makePDF(in: directory)
        let workspace = PDFWorkspaceState()
        workspace.restoreHibernated(url: url, pageCount: 8, currentPageIndex: 2)
        let service = PDFDocumentGalleryPreviewService(debounceNanoseconds: 80_000_000)
        let task = Task { @MainActor in await service.preview(for: workspace) }
        try await Task.sleep(nanoseconds: 10_000_000)
        workspace.currentPageIndex = 7
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(service.renderCount, 0)
        XCTAssertEqual(workspace.currentPageIndex, 7)
        XCTAssertNil(workspace.document)
    }

    @MainActor
    func testCacheAndPixelBudgetsStayBoundedAcrossManyDocumentsAndResizes() async throws {
        let directory = try temporaryDirectory()
        let service = PDFDocumentGalleryPreviewService(maximumCachedPreviews: 2,
                                                       maximumCacheBytes: 200_000, debounceNanoseconds: 0)
        var workspaces: [PDFWorkspaceState] = []
        for index in 0..<7 {
            let url = try makePDF(in: directory, name: "cache-\(index).pdf")
            let workspace = PDFWorkspaceState()
            workspace.restoreHibernated(url: url, pageCount: 8, currentPageIndex: index + 1)
            workspaces.append(workspace)
            let preview = await service.preview(for: workspace, width: 160)
            XCTAssertNotNil(preview)
            XCTAssertLessThanOrEqual(service.cachedPreviewCount, 2)
            XCTAssertLessThanOrEqual(service.cachedByteCount, 200_000)
        }
        let workspace = try XCTUnwrap(workspaces.last)
        let renders = service.renderCount
        _ = await service.preview(for: workspace, width: 160)
        XCTAssertEqual(service.renderCount, renders, "The same current page reuses bounded pixels")
        let hugeResult = await service.preview(for: workspace, width: .greatestFiniteMagnitude)
        let huge = try XCTUnwrap(hugeResult)
        XCTAssertLessThanOrEqual(max(huge.pixelSize.width, huge.pixelSize.height), 1_200)
        XCTAssertLessThanOrEqual(huge.pixelSize.width * huge.pixelSize.height, 1_000_000)
        XCTAssertLessThanOrEqual(service.cachedByteCount, 200_000)
        XCTAssertTrue(workspaces.allSatisfy { $0.document == nil })
        service.removeAllCachedPreviews()
        XCTAssertEqual(service.cachedPreviewCount, 0)
        XCTAssertEqual(service.cachedByteCount, 0)
    }

    @MainActor
    func testDirectBitmapKeepsLegacyPNGAppearanceAcrossCropAndRotation() async throws {
        let directory = try temporaryDirectory()
        let url = try makePDF(in: directory)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        let page = try XCTUnwrap(workspace.document?.page(at: 3))
        page.setBounds(CGRect(x: 7, y: 13, width: 79, height: 131), for: .cropBox)
        let service = PDFDocumentGalleryPreviewService(debounceNanoseconds: 0)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            // The fixture deliberately changes PDFKit in place, so clear the
            // cache instead of making this transport oracle depend on undo.
            service.removeAllCachedPreviews()
            let value = await service.preview(for: workspace, pageIndex: 3, width: 319)
            let preview = try XCTUnwrap(value)
            var rectangle = CGRect(origin: .zero, size: preview.image.size)
            let bitmap = try XCTUnwrap(preview.image.cgImage(forProposedRect: &rectangle, context: nil, hints: nil))
            let encoded = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, bitmap, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let legacyImage = try XCTUnwrap(NSImage(data: encoded as Data))
            XCTAssertEqual(try normalizedPixels(preview.image), try normalizedPixels(legacyImage),
                           "Removing the in-process PNG transport must preserve displayed pixels at rotation \(rotation).")
        }
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    func testCacheChargesRetainedBitmapStrideAndEvictsBeforeItsByteLimit() async throws {
        let directory = try temporaryDirectory()
        let firstURL = try makePDF(in: directory, name: "stride-first.pdf")
        let secondURL = try makePDF(in: directory, name: "stride-second.pdf")
        let first = PDFWorkspaceState()
        let second = PDFWorkspaceState()
        first.restoreHibernated(url: firstURL, pageCount: 8, currentPageIndex: 2)
        second.restoreHibernated(url: secondURL, pageCount: 8, currentPageIndex: 2)
        let service = PDFDocumentGalleryPreviewService(debounceNanoseconds: 0)
        let value = await service.preview(for: first, width: 200)
        let preview = try XCTUnwrap(value)
        var rectangle = CGRect(origin: .zero, size: preview.image.size)
        let bitmap = try XCTUnwrap(preview.image.cgImage(forProposedRect: &rectangle, context: nil, hints: nil))
        let retainedBytes = bitmap.bytesPerRow * bitmap.height
        XCTAssertEqual(service.cachedByteCount, retainedBytes,
                       "The cache must charge the actual retained row stride without an additional PNG population.")

        let bounded = PDFDocumentGalleryPreviewService(maximumCachedPreviews: 32,
            maximumCacheBytes: retainedBytes * 2 - 1, debounceNanoseconds: 0)
        let firstBounded = await bounded.preview(for: first, width: 200)
        let secondBounded = await bounded.preview(for: second, width: 200)
        XCTAssertNotNil(firstBounded)
        XCTAssertNotNil(secondBounded)
        XCTAssertEqual(bounded.cachedPreviewCount, 1)
        XCTAssertEqual(bounded.cachedByteCount, retainedBytes)
        XCTAssertNil(first.document)
        XCTAssertNil(second.document)
    }

    func testRenderingPolicyRejectsUnboundedDimensionsBeforeAllocating() {
        for bounds in [CGRect(x: 0, y: 0, width: 1e200, height: 1),
                       CGRect(x: 0, y: 0, width: 1, height: 1e200),
                       CGRect(x: 0, y: 0, width: CGFloat.infinity, height: CGFloat.nan)] {
            for width: CGFloat in [.infinity, .nan, -10, .greatestFiniteMagnitude] {
                let size = PDFDocumentGalleryRenderingPolicy.targetSize(pageBounds: bounds, rotation: 90, width: width)
                XCTAssertTrue(size.width.isFinite && size.height.isFinite)
                XCTAssertGreaterThanOrEqual(min(size.width, size.height), 1)
                XCTAssertLessThanOrEqual(max(size.width, size.height), 1_200)
                XCTAssertLessThanOrEqual(size.width * size.height, 1_000_000)
            }
        }
    }

    @MainActor
    private struct Snapshot {
        let revision: UUID
        let page: Int
        let selection: Set<Int>
        let viewport: PDFViewerViewportState
        let dirty: Bool
        let documentID: ObjectIdentifier?
        let pageCount: Int
        let url: URL?

        init(_ workspace: PDFWorkspaceState) {
            revision = workspace.revision
            page = workspace.currentPageIndex
            selection = workspace.selectedPages
            viewport = workspace.pdfViewportState
            dirty = workspace.isDirty
            documentID = workspace.document.map(ObjectIdentifier.init)
            pageCount = workspace.pageCount
            url = workspace.documentURL
        }

        func assertUnchanged(_ workspace: PDFWorkspaceState, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(workspace.revision, revision, file: file, line: line)
            XCTAssertEqual(workspace.currentPageIndex, page, file: file, line: line)
            XCTAssertEqual(workspace.selectedPages, selection, file: file, line: line)
            XCTAssertEqual(workspace.pdfViewportState, viewport, file: file, line: line)
            XCTAssertEqual(workspace.isDirty, dirty, file: file, line: line)
            XCTAssertEqual(workspace.document.map(ObjectIdentifier.init), documentID, file: file, line: line)
            XCTAssertEqual(workspace.pageCount, pageCount, file: file, line: line)
            XCTAssertEqual(workspace.documentURL, url, file: file, line: line)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-Gallery-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makePDF(in directory: URL, name: String = "pages.pdf", colorOverride: NSColor? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 100, height: 160)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        for page in 0..<8 {
            context.beginPDFPage(nil)
            // Explicit sRGB makes the color swatches independent of this Mac's
            // display profile; DeviceRGB is not an absolute numeric color space.
            let color = colorOverride ?? NSColor(srgbRed: CGFloat(page) / 8, green: 0.3, blue: 0.7, alpha: 1)
            context.setFillColor(color.cgColor)
            context.fill(box)
            // PDFKit thumbnails and the gallery's bounded CGContext have
            // different output profiles. Exact black/white fingerprints test
            // page identity without comparing unrelated calibrated midtones.
            context.setFillColorSpace(sRGB)
            for swatch in 0..<8 {
                let component: CGFloat = colorOverride != nil || swatch <= page ? 1 : 0
                context.setFillColor([component, component, component, 1])
                context.fill(CGRect(x: CGFloat(swatch) * 12.5 + 1, y: 60, width: 10.5, height: 40))
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func whiteSwatchCount(_ image: NSImage, rotated: Bool = false) throws -> Int {
        var rectangle = CGRect(origin: .zero, size: image.size)
        let source = try XCTUnwrap(image.cgImage(forProposedRect: &rectangle, context: nil, hints: nil))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        var whiteCount = 0
        for swatch in 0..<8 {
            let position = (CGFloat(swatch) + 0.5) / 8
            let x = Int(CGFloat(bitmap.pixelsWide) * (rotated ? 0.5 : position))
            let y = Int(CGFloat(bitmap.pixelsHigh) * (rotated ? position : 0.5))
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let expected: CGFloat = color.redComponent > 0.5 ? 1 : 0
            XCTAssertEqual(color.redComponent, expected, accuracy: 0.015)
            XCTAssertEqual(color.greenComponent, expected, accuracy: 0.015)
            XCTAssertEqual(color.blueComponent, expected, accuracy: 0.015)
            if expected == 1 { whiteCount += 1 }
        }
        return whiteCount
    }

    private func normalizedPixels(_ image: NSImage) throws -> Data {
        var rectangle = CGRect(origin: .zero, size: image.size)
        let source = try XCTUnwrap(image.cgImage(forProposedRect: &rectangle, context: nil, hints: nil))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return Data(bytes: try XCTUnwrap(context.data), count: source.width * source.height * 4)
    }
}
