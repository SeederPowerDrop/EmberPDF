// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

/// Measures the on-disk product of the actual workspace save path. Reopening
/// each version also exposes resource retention that an in-memory-only edit
/// test would miss. The untouched source is always kept beside a working copy.
@MainActor
final class PDFBodyTextFileSizeTests: XCTestCase {
    func testTwentyBodyReplacementsAndReopenedSavesKeepFileSizeBounded() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = try openWorkspace(fixture.workingURL)
        var measurements: [Measurement] = []
        try record(step: 0, workspace: workspace, fixture: fixture,
                   scenario: "repeated-body-text", measurements: &measurements)
        var oldText = "Original body"
        for step in 1...20 {
            let nextText = step.isMultiple(of: 2) ? "Updated body" : "Revised body"
            try replaceBody(oldText, with: nextText, in: workspace)
            try saveAndReopen(workspace, at: fixture.workingURL)
            let document = try XCTUnwrap(workspace.document)
            XCTAssertEqual(document.findString(nextText, withOptions: []).count, 1)
            XCTAssertTrue(document.findString(oldText, withOptions: []).isEmpty)
            XCTAssertEqual(document.findString("Unchanged nearby", withOptions: []).count, 1)
            XCTAssertEqual(document.pageCount, 1)
            XCTAssertEqual(document.page(at: 0)?.annotations.count, 0)
            try record(step: step, workspace: workspace, fixture: fixture,
                       scenario: "repeated-body-text", measurements: &measurements)
            oldText = nextText
        }
        let firstEdit = try XCTUnwrap(measurements.first(where: { $0.step == 1 }))
        let final = try XCTUnwrap(measurements.last)
        // The first replacement can legitimately embed a new font subset.
        // Later equal-length replacements must not retain one subset per edit.
        XCTAssertLessThanOrEqual(final.savedBytes, firstEdit.savedBytes * 3 / 2 + 8_192,
            "Repeated replacements retained old resources: \(measurements.map(\.savedBytes))")
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.originalBytes)
    }

    func testTinyBodyEditPreservesCompressedImageAndBoundedSavedSize() throws {
        let fixture = try makeFixture(includingCompressibleImage: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = try openWorkspace(fixture.workingURL)
        let originalPage = try XCTUnwrap(workspace.document?.page(at: 0))
        XCTAssertTrue(hasFlateImage(originalPage), "Fixture must contain a losslessly compressed image.")
        XCTAssertLessThan(fixture.originalBytes.count, 100_000,
            "The 1536-square fixture image must actually be compressed before editing.")
        let originalPixels = try imageRegionPixels(originalPage)
        let originalImageSamples = try decodedImageSamples(originalPage)
        var measurements: [Measurement] = []
        try record(step: 0, workspace: workspace, fixture: fixture,
                   scenario: "body-edit-compressed-image", measurements: &measurements)
        try replaceBody("Original body", with: "Updated body", in: workspace)
        try saveAndReopen(workspace, at: fixture.workingURL)
        try record(step: 1, workspace: workspace, fixture: fixture,
                   scenario: "body-edit-compressed-image", measurements: &measurements)
        let document = try XCTUnwrap(workspace.document)
        XCTAssertEqual(document.findString("Updated body", withOptions: []).count, 1)
        XCTAssertTrue(document.findString("Original body", withOptions: []).isEmpty)
        XCTAssertEqual(document.findString("Unchanged nearby", withOptions: []).count, 1)
        let editedPage = try XCTUnwrap(document.page(at: 0))
        let editedPixels = try imageRegionPixels(editedPage)
        XCTAssertEqual(try decodedImageSamples(editedPage), originalImageSamples,
            "Native editing must preserve every decoded sample of an unrelated image.")
        if let directory = ProcessInfo.processInfo.environment["EMBER_SIZE_AUDIT_DIRECTORY"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try fixture.originalBytes.write(to: folder.appendingPathComponent("body-compressed-before.pdf"))
            try Data(contentsOf: fixture.workingURL).write(to: folder.appendingPathComponent("body-compressed-after.pdf"))
        }
        XCTAssertEqual(editedPixels, originalPixels,
            "Fixed-sampling rendering must preserve image color, placement, and crop.")
        let final = try XCTUnwrap(measurements.last)
        // Account for normal font embedding/serialization overhead while
        // catching accidental expansion to the seven-megabyte raw image.
        XCTAssertLessThanOrEqual(final.savedBytes, fixture.originalBytes.count * 3 + 65_536,
            "A tiny text edit expanded unrelated compressed resources: \(measurements.map(\.savedBytes))")
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.originalBytes)
    }

    func testTwentyFreeTextUpdatesAndReopenedSavesKeepOneAnnotationAndBoundedSize() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = try openWorkspace(fixture.workingURL)
        var measurements: [Measurement] = []
        try record(step: 0, workspace: workspace, fixture: fixture,
                   scenario: "repeated-free-text", measurements: &measurements)
        XCTAssertTrue(workspace.requestInlineTextEdit(pageIndex: 0,
            point: CGPoint(x: 40, y: 180), annotation: nil))
        let firstDraft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.commitPendingInlineText(id: firstDraft.id, text: "Original note",
            style: firstDraft.style, bounds: firstDraft.bounds)
        XCTAssertNil(workspace.pendingInlineTextEdit)
        try saveAndReopen(workspace, at: fixture.workingURL)
        try record(step: 1, workspace: workspace, fixture: fixture,
                   scenario: "repeated-free-text", measurements: &measurements)
        for step in 2...21 {
            let page = try XCTUnwrap(workspace.document?.page(at: 0))
            let annotation = try XCTUnwrap(page.annotations.first)
            XCTAssertEqual(page.annotations.count, 1)
            // Reopening deliberately drops runtime trust; the explicit review
            // path is the production way to edit/adopt a saved FreeText note.
            workspace.requestTextEdit(pageIndex: 0, point: .zero, annotation: annotation)
            XCTAssertNotNil(workspace.pendingTextEdit)
            let text = step.isMultiple(of: 2) ? "Updated note" : "Revised note"
            workspace.commitPendingText(text)
            XCTAssertNil(workspace.pendingTextEdit)
            XCTAssertNil(workspace.presentedError)
            try saveAndReopen(workspace, at: fixture.workingURL)
            let reopenedPage = try XCTUnwrap(workspace.document?.page(at: 0))
            XCTAssertEqual(reopenedPage.annotations.count, 1)
            XCTAssertEqual(reopenedPage.annotations.first?.contents, text)
            XCTAssertEqual(workspace.document?.findString("Original body", withOptions: []).count, 1)
            try record(step: step, workspace: workspace, fixture: fixture,
                       scenario: "repeated-free-text", measurements: &measurements)
        }
        let firstSave = try XCTUnwrap(measurements.first(where: { $0.step == 1 }))
        let final = try XCTUnwrap(measurements.last)
        XCTAssertLessThanOrEqual(final.savedBytes, firstSave.savedBytes * 3 / 2 + 8_192,
            "Updating one annotation retained previous appearances: \(measurements.map(\.savedBytes))")
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.originalBytes)
    }

    private struct Fixture {
        let directory: URL
        let sourceURL: URL
        let workingURL: URL
        let originalBytes: Data
    }

    private struct Measurement: Codable {
        let step: Int
        let savedBytes: Int
        let nativePageSnapshotBytes: Int
        let pageCount: Int
        let annotationCount: Int
    }

    private func record(step: Int, workspace: PDFWorkspaceState, fixture: Fixture,
                        scenario: String, measurements: inout [Measurement]) throws {
        let document = try XCTUnwrap(workspace.document)
        let page = try XCTUnwrap(document.page(at: 0))
        measurements.append(Measurement(step: step,
            savedBytes: try Data(contentsOf: fixture.workingURL).count,
            nativePageSnapshotBytes: try PDFBodyTextPageSnapshot.data(for: page).count,
            pageCount: document.pageCount, annotationCount: page.annotations.count))
        if let directory = ProcessInfo.processInfo.environment["EMBER_SIZE_AUDIT_DIRECTORY"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(measurements).write(to: folder.appendingPathComponent(scenario + ".json"))
        }
        print("PDF size audit \(scenario), step \(step): \(measurements.last!.savedBytes) bytes")
    }

    private func openWorkspace(_ url: URL) throws -> PDFWorkspaceState {
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.editing)
        _ = try XCTUnwrap(workspace.document)
        return workspace
    }

    private func saveAndReopen(_ workspace: PDFWorkspaceState, at url: URL) throws {
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertTrue(workspace.saveSynchronously(), workspace.presentedError ?? "Save failed")
        XCTAssertFalse(workspace.isDirty)
        XCTAssertTrue(workspace.open(url: url), workspace.presentedError ?? "Reopen failed")
        workspace.setMode(.editing)
        _ = try XCTUnwrap(workspace.document)
    }

    private func replaceBody(_ oldText: String, with newText: String,
                             in workspace: PDFWorkspaceState) throws {
        let document = try XCTUnwrap(workspace.document)
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString(oldText, withOptions: []).first)
        let bounds = selection.bounds(for: page)
        XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0,
            point: CGPoint(x: bounds.midX, y: bounds.midY), allowsInsertion: false),
            workspace.presentedError ?? "Native text edit failed to open")
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        XCTAssertEqual(draft.text, oldText)
        workspace.commitPendingInlineText(id: draft.id, text: newText,
            style: draft.style, bounds: draft.bounds)
        XCTAssertNil(workspace.pendingInlineTextEdit, workspace.presentedError ?? "Native text commit failed")
        XCTAssertNil(workspace.presentedError)
    }

    private func makeFixture(includingCompressibleImage: Bool = false) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberPDF-TextSize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("original.pdf")
        let workingURL = directory.appendingPathComponent("edited.pdf")
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 420)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        for (text, y) in [("Original body", 320.0), ("Unchanged nearby", 280.0)] {
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 40, y: y)
            let line = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTLigatureAttributeName as String): 0
            ])
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
        }
        if includingCompressibleImage {
            let side = 1_536
            var pixels = [UInt8](repeating: 255, count: side * side * 3)
            // Broad colored bands compress strongly but make unintended
            // color, placement, crop, or resampling changes visible to checks.
            for y in 0..<side {
                for x in 0..<side {
                    let offset = (y * side + x) * 3
                    pixels[offset] = x < side / 2 ? 32 : 224
                    pixels[offset + 1] = y < side / 2 ? 176 : 64
                    pixels[offset + 2] = 112
                }
            }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
            let image = try XCTUnwrap(CGImage(width: side, height: side, bitsPerComponent: 8,
                bitsPerPixel: 24, bytesPerRow: side * 3, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            context.draw(image, in: CGRect(x: 30, y: 30, width: 320, height: 190))
        }
        context.endPDFPage()
        context.closePDF()
        let original = data as Data
        try original.write(to: sourceURL)
        try original.write(to: workingURL)
        return Fixture(directory: directory, sourceURL: sourceURL,
                       workingURL: workingURL, originalBytes: original)
    }

    private func hasFlateImage(_ page: PDFPage) -> Bool {
        guard let dictionary = page.pageRef?.dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return false }
        var found = false
        CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            var filter: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
               String(cString: subtype) == "Image",
               CGPDFDictionaryGetName(dictionary, "Filter", &filter), let filter,
               String(cString: filter) == "FlateDecode" {
                found = true
            }
            return true
        }, nil)
        return found
    }

    private func decodedImageSamples(_ page: PDFPage) throws -> [Data] {
        let dictionary = try XCTUnwrap(page.pageRef?.dictionary)
        var resources: CGPDFDictionaryRef?
        var xobjects: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &xobjects))
        var samples: [Data] = []
        CGPDFDictionaryApplyBlock(try XCTUnwrap(xobjects), { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Image" else { return true }
            var format = CGPDFDataFormat.raw
            if let bytes = CGPDFStreamCopyData(stream, &format), format == .raw {
                samples.append(bytes as Data)
            }
            return true
        }, nil)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.count, 1_536 * 1_536 * 3)
        return samples
    }

    private func imageRegionPixels(_ page: PDFPage) throws -> Data {
        let width = 400, height = 420
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
                width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // PDFKit serialization can change an image's optional Interpolate
            // hint. Fixed sampling isolates its pixel content and placement
            // from that renderer preference; decoded samples are also checked
            // exactly above, so this is not a visual-difference tolerance.
            context.interpolationQuality = .none
            context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        // Compare only the unchanged image, excluding the edited text above.
        var region = Data()
        for y in 30..<220 {
            let row = (height - 1 - y) * width * 4
            region.append(contentsOf: pixels[(row + 30 * 4)..<(row + 350 * 4)])
        }
        return region
    }
}
