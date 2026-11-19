// SPDX-License-Identifier: MPL-2.0

import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import HwattakPDF

@MainActor
final class ImageInsertionApprovalTests: XCTestCase {
    func testRequestPreparationAndCancelDoNotChangeDocumentOrUndoHistory() throws {
        try withFixture { workspace, directory, urls in
            let source = try Data(contentsOf: directory.appendingPathComponent("source.pdf"))
            let revision = workspace.revision
            workspace.insertImage(url: urls[0])
            let request = try XCTUnwrap(workspace.pendingImageInsertion)
            let prepared = try ImageInsertionPreparation.prepare(urls: request.urls, option: .small)
            XCTAssertEqual(prepared.count, 1)
            assertUnchanged(workspace)
            XCTAssertEqual(workspace.revision, revision)
            workspace.cancelImageInsertion()
            XCTAssertNil(workspace.pendingImageInsertion)
            assertUnchanged(workspace)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("source.pdf")), source)
            XCTAssertFalse(workspace.approveImageInsertion(request, images: prepared))
            assertUnchanged(workspace)
        }
    }

    func testApprovedBatchCreatesExactlyOneUndoCommand() throws {
        try withFixture { workspace, _, urls in
            workspace.requestImageInsertion(urls: urls)
            let request = try XCTUnwrap(workspace.pendingImageInsertion)
            let prepared = try ImageInsertionPreparation.prepare(urls: request.urls, option: .original)
            assertUnchanged(workspace)
            XCTAssertTrue(workspace.approveImageInsertion(request, images: prepared))
            XCTAssertNil(workspace.pendingImageInsertion)
            XCTAssertEqual(workspace.document?.page(at: 0)?.annotations.count, 2)
            XCTAssertTrue(workspace.isDirty)
            workspace.undo()
            assertUnchanged(workspace)
            XCTAssertTrue(workspace.canRedo)
            workspace.redo()
            XCTAssertEqual(workspace.document?.page(at: 0)?.annotations.count, 2)
            XCTAssertTrue(workspace.isDirty)
        }
    }

    func testDocumentReplacementRejectsPreparedImagesForOldDocument() throws {
        try withFixture { workspace, directory, urls in
            workspace.requestImageInsertion(urls: urls)
            let request = try XCTUnwrap(workspace.pendingImageInsertion)
            let prepared = try ImageInsertionPreparation.prepare(urls: request.urls, option: .original)
            let replacement = directory.appendingPathComponent("replacement.pdf")
            try blankPDF().write(to: replacement)
            XCTAssertTrue(workspace.open(url: replacement))
            workspace.setMode(.editing)
            XCTAssertFalse(workspace.approveImageInsertion(request, images: prepared))
            assertUnchanged(workspace)
        }
    }

    func testRevisionChangeRejectsPreparedImagesWithoutAddingUndoStep() throws {
        try withFixture { workspace, _, urls in
            workspace.requestImageInsertion(urls: urls)
            let request = try XCTUnwrap(workspace.pendingImageInsertion)
            let prepared = try ImageInsertionPreparation.prepare(urls: request.urls, option: .original)
            workspace.selectedPages = [0]
            workspace.rotateSelectedPages(clockwise: true)
            XCTAssertNotEqual(workspace.revision, request.documentRevision)
            XCTAssertFalse(workspace.approveImageInsertion(request, images: prepared))
            XCTAssertEqual(workspace.document?.page(at: 0)?.annotations.count, 0)
            XCTAssertEqual(workspace.document?.page(at: 0)?.rotation, 90)
            workspace.undo()
            XCTAssertEqual(workspace.document?.page(at: 0)?.rotation, 0)
            assertUnchanged(workspace)
        }
    }

    func testModeChangeRejectsPreviouslyPreparedImages() throws {
        try withFixture { workspace, _, urls in
            workspace.requestImageInsertion(urls: urls)
            let request = try XCTUnwrap(workspace.pendingImageInsertion)
            let prepared = try ImageInsertionPreparation.prepare(urls: request.urls, option: .original)
            workspace.setMode(.viewer)
            XCTAssertNil(workspace.pendingImageInsertion)
            XCTAssertFalse(workspace.approveImageInsertion(request, images: prepared))
            assertUnchanged(workspace)
        }
    }

    func testApprovalUsesCapturedTargetPageAfterNavigation() throws {
        try withFixture { workspace, _, urls in
            workspace.currentPageIndex = 0
            workspace.requestImageInsertion(urls: urls)
            let request = try XCTUnwrap(workspace.pendingImageInsertion)
            let prepared = try ImageInsertionPreparation.prepare(urls: request.urls, option: .original)
            workspace.currentPageIndex = 1
            XCTAssertTrue(workspace.approveImageInsertion(request, images: prepared))
            XCTAssertEqual(workspace.document?.page(at: 0)?.annotations.count, 2)
            XCTAssertEqual(workspace.document?.page(at: 1)?.annotations.count, 0)
        }
    }

    func testTargetPageIdentityChangeRejectsImagesEvenWithoutRevisionChange() throws {
        try withFixture { workspace, _, urls in
            workspace.requestImageInsertion(urls: urls)
            let request = try XCTUnwrap(workspace.pendingImageInsertion)
            let prepared = try ImageInsertionPreparation.prepare(urls: request.urls, option: .original)
            let replacementDocument = try XCTUnwrap(PDFDocument(data: blankPDF()))
            let replacementPage = try XCTUnwrap(replacementDocument.page(at: 0))
            let document = try XCTUnwrap(workspace.document)
            document.removePage(at: 0)
            document.insert(replacementPage, at: 0)
            XCTAssertEqual(workspace.revision, request.documentRevision)
            XCTAssertFalse(workspace.approveImageInsertion(request, images: prepared))
            assertUnchanged(workspace)
        }
    }

    func testMissingOrReorderedPreparedBatchDoesNotPartiallyApply() throws {
        try withFixture { workspace, _, urls in
            for reorder in [false, true] {
                workspace.requestImageInsertion(urls: urls)
                let request = try XCTUnwrap(workspace.pendingImageInsertion)
                let prepared = try ImageInsertionPreparation.prepare(urls: request.urls, option: .original)
                let mismatched = reorder ? Array(prepared.reversed()) : Array(prepared.prefix(1))
                XCTAssertFalse(workspace.approveImageInsertion(request, images: mismatched))
                assertUnchanged(workspace)
                workspace.cancelImageInsertion()
            }
        }
    }

    func testInvalidSecondImageDoesNotPartiallyInsertFirstImage() throws {
        try withFixture { workspace, _, urls in
            workspace.requestImageInsertion(urls: urls)
            let request = try XCTUnwrap(workspace.pendingImageInsertion)
            let prepared = try ImageInsertionPreparation.prepare(urls: request.urls, option: .original)
            let second = prepared[1]
            let invalid = PreparedImageInsertion(sourceURL: second.sourceURL, image: NSImage(size: .zero),
                originalJPEG: nil, sourceBytes: second.sourceBytes, estimatedAddedBytes: second.estimatedAddedBytes,
                sourcePixelSize: second.sourcePixelSize, pixelSize: .zero, isResized: false,
                preservesTransparency: false, isRecompressed: false, option: .original)
            XCTAssertFalse(workspace.approveImageInsertion(request, images: [prepared[0], invalid]))
            assertUnchanged(workspace)
        }
    }

    func testApprovalUsesPreparedPixelsWhenSourceFileChangesAfterPreview() throws {
        try withFixture { workspace, _, urls in
            workspace.insertImage(url: urls[0])
            let request = try XCTUnwrap(workspace.pendingImageInsertion)
            let prepared = try ImageInsertionPreparation.prepare(urls: request.urls, option: .original)
            let expectedStamp = ImageStampAnnotation(image: prepared[0].image,
                bounds: CGRect(x: 0, y: 0, width: 120, height: 80), originalJPEG: prepared[0].originalJPEG)
            let expectedPixels = try stampPixels(expectedStamp)
            try Data("this file was replaced after preparation".utf8).write(to: urls[0])
            XCTAssertTrue(workspace.approveImageInsertion(request, images: prepared))
            let annotation = try XCTUnwrap(workspace.document?.page(at: 0)?.annotations.first as? ImageStampAnnotation)
            XCTAssertEqual(try stampPixels(annotation), expectedPixels)
        }
    }

    private func assertUnchanged(_ workspace: PDFWorkspaceState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(workspace.document?.page(at: 0)?.annotations.count, 0, file: file, line: line)
        XCTAssertEqual(workspace.document?.page(at: 1)?.annotations.count, 0, file: file, line: line)
        XCTAssertFalse(workspace.isDirty, file: file, line: line)
        XCTAssertFalse(workspace.canUndo, file: file, line: line)
    }

    private func withFixture(_ body: (PDFWorkspaceState, URL, [URL]) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdfURL = directory.appendingPathComponent("source.pdf")
        try blankPDF().write(to: pdfURL)
        let imageURLs = [directory.appendingPathComponent("first.jpg"), directory.appendingPathComponent("second.jpg")]
        for (index, url) in imageURLs.enumerated() {
            let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8,
                bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(red: index == 0 ? 0.8 : 0.2, green: 0.3, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            let encoded = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            try (encoded as Data).write(to: url)
        }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: pdfURL))
        workspace.setMode(.editing)
        try body(workspace, directory, imageURLs)
    }

    private func blankPDF() throws -> Data {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 500, height: 600)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func stampPixels(_ stamp: ImageStampAnnotation) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8,
            bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 120 / stamp.bounds.width, y: 80 / stamp.bounds.height)
        context.translateBy(x: -stamp.bounds.minX, y: -stamp.bounds.minY)
        stamp.draw(with: .mediaBox, in: context)
        return Data(bytes: try XCTUnwrap(context.data), count: 120 * 80 * 4)
    }
}
