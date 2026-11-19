// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFCompressionWorkspaceTests: XCTestCase {
    @MainActor
    func testPreviewIncludesUnsavedAnnotationAndExactSavedCopyPreservesWorkspaceHistory() async throws {
        let fixture = try makeFixture()
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.source))
        workspace.setMode(.editing)
        let document = try XCTUnwrap(workspace.document)
        let note = try addNote("Unsaved note in compressed copy", to: workspace)
        let revision = workspace.revision
        let undoName = workspace.undoActionName
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.canUndo)

        let request = try await prepare(workspace)
        let preview = try XCTUnwrap(PDFDocument(data: request.documentData))
        XCTAssertEqual(preview.page(at: 0)?.annotations.first?.contents, note.contents)
        XCTAssertEqual(request.originalBytes, request.documentData.count)
        let result = try PDFCompressionService.compress(data: request.documentData, quality: .balanced)
        XCTAssertTrue(result.didReduce)
        let destination = fixture.directory.appendingPathComponent("compressed.pdf")
        XCTAssertTrue(workspace.saveCompressedCopy(result.data, request: request, to: destination))

        XCTAssertEqual(try Data(contentsOf: destination), result.data)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
        XCTAssertEqual(PDFDocument(url: destination)?.page(at: 0)?.annotations.first?.contents, note.contents)
        XCTAssertTrue(workspace.document === document)
        XCTAssertEqual(workspace.documentURL, fixture.source)
        XCTAssertEqual(workspace.revision, revision)
        XCTAssertEqual(workspace.undoActionName, undoName)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.canUndo)
        XCTAssertNil(workspace.pendingPDFCompression)
        XCTAssertNil(workspace.presentedError)
        workspace.undo()
        XCTAssertEqual(document.page(at: 0)?.annotations.count, 0)
        XCTAssertFalse(workspace.isDirty, "Exporting a copy must not add a document edit or change the save checkpoint.")
    }

    @MainActor
    func testCleanDocumentPreviewUsesOriginalStoredSizeAsCeiling() async throws {
        let fixture = try makeFixture()
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.source))
        let request = try await prepare(workspace)
        XCTAssertEqual(request.originalBytes, min(fixture.original.count, request.documentData.count))
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
    }

    @MainActor
    func testCancellingPreparationCannotReopenItsSheet() async throws {
        let fixture = try makeFixture()
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.source))
        let revision = workspace.revision
        workspace.requestPDFCompression()
        let task = try XCTUnwrap(workspace.compressionPreparationTask)
        workspace.cancelPDFCompression()
        await task.value
        XCTAssertNil(workspace.pendingPDFCompression)
        XCTAssertNil(workspace.compressionPreparationTask)
        XCTAssertFalse(workspace.isPreparingPDFCompression)
        XCTAssertEqual(workspace.revision, revision)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
    }

    @MainActor
    func testAnotherEditInvalidatesPreparedCopyWithoutWritingDestination() async throws {
        let fixture = try makeFixture()
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.source))
        let request = try await prepare(workspace)
        let result = try PDFCompressionService.compress(data: request.documentData, quality: .balanced)
        XCTAssertTrue(result.didReduce)
        try addNote("Later edit must not be silently omitted", to: workspace)
        let destination = fixture.directory.appendingPathComponent("stale.pdf")
        XCTAssertFalse(workspace.saveCompressedCopy(result.data, request: request, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
    }

    @MainActor
    func testSwitchingDocumentsRejectsOldPreview() async throws {
        let fixture = try makeFixture()
        let other = fixture.directory.appendingPathComponent("other.pdf")
        try fixture.original.write(to: other)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.source))
        let request = try await prepare(workspace)
        let result = try PDFCompressionService.compress(data: request.documentData, quality: .balanced)
        XCTAssertTrue(workspace.open(url: other))
        let destination = fixture.directory.appendingPathComponent("wrong-document.pdf")
        XCTAssertFalse(workspace.saveCompressedCopy(result.data, request: request, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(workspace.documentURL, other)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
        XCTAssertEqual(try Data(contentsOf: other), fixture.original)
    }

    @MainActor
    func testSourcePathSymbolicLinkAndHardLinkCannotBeOverwritten() async throws {
        let fixture = try makeFixture()
        let symbolic = fixture.directory.appendingPathComponent("symbolic.pdf")
        let hard = fixture.directory.appendingPathComponent("hard.pdf")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: fixture.source)
        try FileManager.default.linkItem(at: fixture.source, to: hard)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.source))
        let request = try await prepare(workspace)
        let result = try PDFCompressionService.compress(data: request.documentData, quality: .balanced)
        XCTAssertTrue(result.didReduce)
        for destination in [fixture.source, symbolic, hard] {
            XCTAssertFalse(workspace.saveCompressedCopy(result.data, request: request, to: destination))
            XCTAssertEqual(try Data(contentsOf: destination), fixture.original)
            XCTAssertEqual(workspace.pendingPDFCompression?.id, request.id)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
    }

    @MainActor
    func testExportDoesNotOverwriteSourceChangedByAnotherApplication() async throws {
        let fixture = try makeFixture()
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.source))
        let request = try await prepare(workspace)
        let result = try PDFCompressionService.compress(data: request.documentData, quality: .balanced)
        let external = try XCTUnwrap(PDFDocument(data: fixture.original))
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 120, height: 40), forType: .freeText, withProperties: nil)
        note.contents = "Changed in another application"
        external.page(at: 0)?.addAnnotation(note)
        let externalBytes = try XCTUnwrap(external.dataRepresentation())
        try externalBytes.write(to: fixture.source, options: .atomic)

        let destination = fixture.directory.appendingPathComponent("loaded-version-copy.pdf")
        XCTAssertTrue(workspace.saveCompressedCopy(result.data, request: request, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), result.data)
        XCTAssertEqual(try Data(contentsOf: fixture.source), externalBytes)
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    func testNonReducingOrMalformedOutputCannotReplaceExistingDestination() async throws {
        let fixture = try makeFixture()
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.source))
        let request = try await prepare(workspace)
        let destination = fixture.directory.appendingPathComponent("existing.pdf")
        try fixture.original.write(to: destination)
        XCTAssertFalse(workspace.saveCompressedCopy(request.documentData, request: request, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), fixture.original)
        XCTAssertFalse(workspace.saveCompressedCopy(Data("invalid PDF".utf8), request: request, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), fixture.original)
        XCTAssertEqual(workspace.pendingPDFCompression?.id, request.id)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.original)
    }

    @MainActor
    func testOwnerUnlockedEncryptedPDFIsRejectedBeforePreparingSnapshot() async throws {
        let fixture = try makeFixture()
        let document = try XCTUnwrap(PDFDocument(data: fixture.original))
        let encrypted = try XCTUnwrap(document.dataRepresentation(options: [
            PDFDocumentWriteOption.userPasswordOption: "Owner123",
            PDFDocumentWriteOption.ownerPasswordOption: "Owner123"
        ]))
        let source = fixture.directory.appendingPathComponent("protected.pdf")
        try encrypted.write(to: source)
        let workspace = PDFWorkspaceState(passwordProvider: { _, _ in "Owner123" })
        XCTAssertTrue(workspace.open(url: source))
        XCTAssertTrue(workspace.document?.isEncrypted == true)
        XCTAssertFalse(workspace.document?.isLocked ?? true)
        XCTAssertFalse(workspace.canRequestPDFCompression)
        workspace.requestPDFCompression()
        XCTAssertNil(workspace.pendingPDFCompression)
        XCTAssertNil(workspace.compressionPreparationTask)
        XCTAssertFalse(workspace.isPreparingPDFCompression)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(try Data(contentsOf: source), encrypted)
    }

    @MainActor
    private func prepare(_ workspace: PDFWorkspaceState) async throws -> PDFCompressionRequest {
        workspace.requestPDFCompression()
        let task = try XCTUnwrap(workspace.compressionPreparationTask, workspace.presentedError ?? "Missing preparation task")
        await task.value
        XCTAssertFalse(workspace.isPreparingPDFCompression)
        return try XCTUnwrap(workspace.pendingPDFCompression, workspace.presentedError ?? "Missing compression preview")
    }

    @MainActor
    @discardableResult
    private func addNote(_ contents: String, to workspace: PDFWorkspaceState) throws -> PDFAnnotation {
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let annotation = PDFAnnotation(bounds: CGRect(x: 40, y: 600, width: 350, height: 35), forType: .freeText, withProperties: nil)
        annotation.contents = contents
        annotation.font = NSFont.systemFont(ofSize: 12)
        annotation.fontColor = .black
        annotation.color = .clear
        page.addAnnotation(annotation)
        workspace.registerAddedAnnotation(annotation, on: page, message: "Insert test note")
        return annotation
    }

    private func makeFixture() throws -> (directory: URL, source: URL, original: Data) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-compression-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let width = 1_024, height = 768
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        var noise: UInt32 = 9
        for y in 0..<height {
            for x in 0..<width {
                noise = noise &* 1_664_525 &+ 1_013_904_223
                let grain = Int((noise >> 24) & 31)
                let offset = (y * width + x) * 3
                pixels[offset] = UInt8((x / 5 + grain) % 256)
                pixels[offset + 1] = UInt8((y / 4 + grain) % 256)
                pixels[offset + 2] = UInt8((x / 13 + y / 9 + grain) % 256)
            }
        }
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: [],
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let bytes = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: CGDataConsumer(data: bytes)!, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.draw(image, in: CGRect(x: 50, y: 100, width: 500, height: 375))
        context.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Searchable compression workspace fixture",
            attributes: [.font: NSFont.systemFont(ofSize: 16)])), context)
        context.endPDFPage()
        context.closePDF()
        let original = bytes as Data
        let source = directory.appendingPathComponent("source.pdf")
        try original.write(to: source)
        return (directory, source, original)
    }
}
