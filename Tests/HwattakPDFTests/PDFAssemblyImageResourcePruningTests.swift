// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFAssemblyImageResourcePruningTests: XCTestCase {
    func testTextPagesKeepTheirOriginalBackingAndOrderAfterPreparationScope() throws {
        let bytes = fixture(extraResources: "/Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >>",
            extraContent: "BT /F1 8 Tf 5 90 Td (first OCR line) Tj 0 -10 Td (second OCR line) Tj ET")
        var originalText: [String?] = []
        var originalContent: [Data] = []
        let imported = try autoreleasepool {
            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
            let first = try XCTUnwrap(source.page(at: 0))
            first.setBounds(CGRect(x: 2, y: 3, width: 94, height: 93), for: .cropBox)
            first.rotation = 90
            originalText = try [0, 2].map { try XCTUnwrap(source.page(at: $0)).string }
            originalContent = try [0, 2].map { try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(source.page(at: $0))) }
            XCTAssertTrue(try XCTUnwrap(originalText[0]).contains("first OCR line"))
            let result = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0, 2])
            for index in 0..<3 { try assertImageNames(in: source, page: index, equal: allNames) }
            return result
        }
        // Independent ordinary SDK control: the same source lifetime and
        // getter order matter. PDFKit changes inferred live line/space layout
        // after copy/insertion even when the source painting is unchanged.
        let controlPages = try autoreleasepool {
            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
            let first = try XCTUnwrap(source.page(at: 0))
            first.setBounds(CGRect(x: 2, y: 3, width: 94, height: 93), for: .cropBox)
            first.rotation = 90
            XCTAssertEqual(try [0, 2].map { try XCTUnwrap(source.page(at: $0)).string }, originalText)
            return try [0, 2].map { try XCTUnwrap(source.page(at: $0)?.copy() as? PDFPage) }
        }
        let control = PDFDocument()
        for page in controlPages { control.insert(page, at: control.pageCount) }
        let assembled = PDFDocument()
        for page in imported.pages { assembled.insert(page, at: assembled.pageCount) }
        for (index, name) in ["ImA", "ImC"].enumerated() {
            try assertImageNames(in: assembled, page: index, equal: allNames)
            try assertImageBytes(in: assembled, page: index, names: [name])
            let page = try XCTUnwrap(assembled.page(at: index))
            XCTAssertEqual(page.string, control.page(at: index)?.string)
            XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: page), originalContent[index])
            let cold = try XCTUnwrap(PDFDocument(data: PDFBodyTextPageSnapshot.originalPageData(for: page)))
            XCTAssertEqual(cold.page(at: 0)?.string, originalText[index])
        }
        XCTAssertEqual(assembled.page(at: 0)?.bounds(for: .cropBox), CGRect(x: 2, y: 3, width: 94, height: 93))
        XCTAssertEqual(assembled.page(at: 0)?.rotation, 90)
    }

    func testImageOnlyBackingIsCompactAndRetainsGeometryAfterPreparationScope() throws {
        let imported = try autoreleasepool {
            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
            let first = try XCTUnwrap(source.page(at: 0))
            first.setBounds(CGRect(x: 2, y: 3, width: 94, height: 93), for: .cropBox)
            first.rotation = 90
            let result = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0, 2])
            for index in 0..<3 { try assertImageNames(in: source, page: index, equal: allNames) }
            return result
        }
        let assembled = PDFDocument()
        for page in imported.pages { assembled.insert(page, at: assembled.pageCount) }
        for (index, name) in ["ImA", "ImC"].enumerated() {
            try assertImageNames(in: assembled, page: index, equal: [name])
            try assertImageBytes(in: assembled, page: index, names: [name])
        }
        XCTAssertEqual(assembled.page(at: 0)?.bounds(for: .cropBox), CGRect(x: 2, y: 3, width: 94, height: 93))
        XCTAssertEqual(assembled.page(at: 0)?.rotation, 90)
    }

    func testCompactBackingKeepsLiveAnnotationsAndPropagatesCancellation() throws {
        let marked = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data:
            fixture(extraContent: "/Span << /ActualText (semantic image text) >> BDC /ImA Do EMC")))
        let markedPage = try XCTUnwrap(marked.page(at: 0))
        XCTAssertNil(try PDFPageOperations.compactAssemblyCopy(of: markedPage, remainingBytes: 64 * 1_024 * 1_024))
        var ordinaryPlan = PDFCatalogGraphPlan()
        try PDFCatalogImageResourcePruner.addPrunedImageResources(pages: [XCTUnwrap(markedPage.pageRef)], to: &ordinaryPlan)
        XCTAssertFalse(ordinaryPlan.dictionaryDrops.isEmpty, "Ordinary save pruning keeps its existing marked-content policy.")

        let compressed = fixture(compressedImages: true)
        let unowned = try XCTUnwrap(PDFDocument(data: compressed))
        XCTAssertNil(try PDFPageOperations.compactAssemblyCopy(of: XCTUnwrap(unowned.page(at: 0)), remainingBytes: 64 * 1_024 * 1_024))
        let owned = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: compressed))
        let compact = try XCTUnwrap(PDFPageOperations.compactAssemblyCopy(of: XCTUnwrap(owned.page(at: 0)), remainingBytes: 64 * 1_024 * 1_024))
        let assembled = PDFDocument(); assembled.insert(compact.page, at: 0)
        try assertImageNames(in: assembled, page: 0, equal: ["ImA"])
        XCTAssertEqual(try pixels(XCTUnwrap(assembled.page(at: 0)?.pageRef)), try pixels(XCTUnwrap(owned.page(at: 0)?.pageRef)))

        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
        let page = try XCTUnwrap(source.page(at: 0))
        XCTAssertNil(try PDFPageOperations.compactAssemblyCopy(of: page, remainingBytes: 1))
        let annotation = PDFAnnotation(bounds: CGRect(x: 4, y: 4, width: 7, height: 7), forType: .square, withProperties: nil)
        annotation.contents = "keep this annotation"
        page.addAnnotation(annotation)
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
        try assertImageNames(in: extracted, page: 0, equal: allNames)
        XCTAssertEqual(extracted.page(at: 0)?.annotations.first?.contents, annotation.contents)
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(cancellation) {
            try PDFPageStructurePreserver.prepareImport(from: source, indexes: [1])
        }) { error in XCTAssertTrue(error is CancellationError) }
        try assertImageNames(in: source, page: 1, equal: allNames)
    }

    func testExtractedAtomicOutputPrunesUnusedImagesWhileOriginalSaveKeepsEveryName() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = fixture()
        let originalURL = directory.appendingPathComponent("owned-source.pdf")
        try bytes.write(to: originalURL)
        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
        let originalNative = try XCTUnwrap(source.documentRef)
        let before = directory.appendingPathComponent("ordinary-before.pdf")
        // Ordinary UI saves capture/forward the original painting provenance
        // before serialization. A bare unprepared Atomic call may use PDFKit.
        let ordinaryBefore = try PDFRecoverySnapshot(capturing: source).takeDocument()
        try AtomicPDFWriter.write(ordinaryBefore, to: before)
        try assertImageNames(in: reopened(before), page: 0, equal: allNames)

        let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 2])
        let output = directory.appendingPathComponent("selected.pdf")
        try AtomicPDFWriter.write(extracted, to: output)
        let saved = try reopened(output)
        XCTAssertEqual(saved.pageCount, 2)
        for (outputIndex, sourceIndex) in [(0, 0), (1, 2)] {
            try assertImageNames(in: saved, page: outputIndex, equal: ["ImA", "ImC"])
            try assertImageBytes(in: saved, page: outputIndex, names: ["ImA", "ImC"])
            XCTAssertEqual(try pixels(XCTUnwrap(saved.documentRef?.page(at: outputIndex + 1))),
                           try pixels(XCTUnwrap(originalNative.page(at: sourceIndex + 1))))
        }
        XCTAssertLessThan(try Data(contentsOf: output).count, bytes.count)
        let after = directory.appendingPathComponent("ordinary-after.pdf")
        let ordinaryAfter = try PDFRecoverySnapshot(capturing: source).takeDocument()
        try AtomicPDFWriter.write(ordinaryAfter, to: after)
        for index in 0..<3 {
            try assertImageNames(in: reopened(after), page: index, equal: allNames)
            try assertImageNames(in: source, page: index, equal: allNames)
        }
        XCTAssertEqual(try Data(contentsOf: originalURL), bytes)
    }

    func testMergeUnionsAllFinalPagesAndUndoRestoresOriginalSavePolicy() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
        let destination = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture(contents: ["ImC"])))
        let before = try pixels(XCTUnwrap(destination.documentRef?.page(at: 1)))
        let imported = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0, 1])
        let merge = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: destination, at: 1)
        try merge.apply()
        let firstURL = directory.appendingPathComponent("merged-first.pdf")
        try AtomicPDFWriter.write(destination, to: firstURL)
        try assertMerged(try reopened(firstURL), source: source, destinationPixels: before)

        try merge.undo()
        let undoURL = directory.appendingPathComponent("undo.pdf")
        try AtomicPDFWriter.write(destination, to: undoURL)
        let undone = try reopened(undoURL)
        XCTAssertEqual(undone.pageCount, 1)
        try assertImageNames(in: undone, page: 0, equal: allNames)
        XCTAssertEqual(try pixels(XCTUnwrap(undone.documentRef?.page(at: 1))), before)

        try merge.redo()
        let redoURL = directory.appendingPathComponent("redo.pdf")
        try AtomicPDFWriter.write(destination, to: redoURL)
        try assertMerged(try reopened(redoURL), source: source, destinationPixels: before)
        for index in 0..<3 { try assertImageNames(in: source, page: index, equal: allNames) }
    }

    func testRecoveryBackgroundSaveCarriesAssemblyIntentWithoutChangingTheSource() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = fixture()
        let originalURL = directory.appendingPathComponent("owned-source.pdf")
        try bytes.write(to: originalURL)
        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
        let native = try XCTUnwrap(source.documentRef)
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 2])
        let snapshot = try PDFRecoverySnapshot(capturing: extracted)
        let output = directory.appendingPathComponent("background-selected.pdf")
        let request = try PDFBackgroundSaveRequest(destinationURL: output, originalURL: nil, overwritingOriginal: false)
        _ = try await PDFBackgroundSaveWriter.write(snapshot: snapshot, request: request, cancellation: PDFSaveCancellation())
        let saved = try reopened(output)
        XCTAssertEqual(saved.pageCount, 2)
        for (outputIndex, sourceIndex) in [(0, 0), (1, 2)] {
            try assertImageNames(in: saved, page: outputIndex, equal: ["ImA", "ImC"])
            try assertImageBytes(in: saved, page: outputIndex, names: ["ImA", "ImC"])
            XCTAssertEqual(try pixels(XCTUnwrap(saved.documentRef?.page(at: outputIndex + 1))),
                           try pixels(XCTUnwrap(native.page(at: sourceIndex + 1))))
        }
        XCTAssertEqual(try Data(contentsOf: originalURL), bytes)
        try assertImageNames(in: source, page: 0, equal: allNames)
    }

    func testLiveAnnotationAndUnknownResourceKeepTheCompleteNamespace() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for hasAnnotation in [true, false] {
            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(
                data: fixture(extraResources: hasAnnotation ? "" : "/Properties << >>")))
            let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 2])
            if hasAnnotation {
                let annotation = PDFAnnotation(bounds: CGRect(x: 4, y: 4, width: 7, height: 7), forType: .square, withProperties: nil)
                annotation.color = .blue
                try XCTUnwrap(extracted.page(at: 0)).addAnnotation(annotation)
            }
            let output = directory.appendingPathComponent(hasAnnotation ? "live-annotation.pdf" : "unknown-resource.pdf")
            try AtomicPDFWriter.write(extracted, to: output)
            let saved = try reopened(output)
            XCTAssertEqual(saved.pageCount, 2)
            XCTAssertEqual(saved.page(at: 0)?.annotations.count, hasAnnotation ? 1 : 0)
            for index in 0..<2 { try assertImageNames(in: saved, page: index, equal: allNames) }
            try assertImageNames(in: source, page: 0, equal: allNames)
        }
        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
        let native = try XCTUnwrap(source.documentRef)
        let pages = try [1, 3].map { try XCTUnwrap(native.page(at: $0)) }
        var plan = PDFCatalogGraphPlan()
        plan.dictionaryDrops[UInt.max] = ["sentinel"]
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(cancellation) {
            try PDFCatalogImageResourcePruner.addPrunedImageResources(pages: pages, to: &plan)
        }) { error in XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(plan.dictionaryDrops, [UInt.max: ["sentinel"]])
        try assertImageNames(in: source, page: 0, equal: allNames)
    }

    private let allNames: Set<String> = ["ImA", "ImB", "ImC", "ImUnused"]

    private func assertMerged(_ saved: PDFDocument, source: PDFDocument, destinationPixels: [UInt8]) throws {
        XCTAssertEqual(saved.pageCount, 3)
        try assertImageNames(in: saved, page: 0, equal: ["ImC"])
        XCTAssertEqual(try pixels(XCTUnwrap(saved.documentRef?.page(at: 1))), destinationPixels)
        for index in 0..<2 {
            try assertImageNames(in: saved, page: index + 1, equal: ["ImA", "ImB"])
            try assertImageBytes(in: saved, page: index + 1, names: ["ImA", "ImB"])
            XCTAssertEqual(try pixels(XCTUnwrap(saved.documentRef?.page(at: index + 2))),
                           try pixels(XCTUnwrap(source.documentRef?.page(at: index + 1))))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-Assembly-Image-Pruning-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    private func reopened(_ url: URL) throws -> PDFDocument { try XCTUnwrap(PDFDocument(url: url)) }

    private func namespace(in document: PDFDocument, page index: Int) throws -> CGPDFDictionaryRef {
        var node: CGPDFDictionaryRef? = try XCTUnwrap(document.page(at: index)?.pageRef?.dictionary)
        for _ in 0..<64 {
            let current = try XCTUnwrap(node)
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources {
                var xobjects: CGPDFDictionaryRef?
                XCTAssertTrue(CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects))
                return try XCTUnwrap(xobjects)
            }
            var parent: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(current, "Parent", &parent))
            node = parent
        }
        throw NSError(domain: "OwnedImageFixture", code: 1)
    }

    private func assertImageNames(in document: PDFDocument, page: Int, equal expected: Set<String>) throws {
        let objects = try namespace(in: document, page: page)
        var names = Set<String>()
        CGPDFDictionaryApplyBlock(objects, { rawName, _, _ in names.insert(String(cString: rawName)); return true }, nil)
        XCTAssertEqual(names, expected)
    }

    private func assertImageBytes(in document: PDFDocument, page: Int, names: [String]) throws {
        let objects = try namespace(in: document, page: page)
        for name in names {
            var image: CGPDFStreamRef?
            XCTAssertTrue(CGPDFDictionaryGetStream(objects, name, &image))
            var format = CGPDFDataFormat.raw
            let data = try XCTUnwrap(CGPDFStreamCopyData(XCTUnwrap(image), &format))
            XCTAssertEqual(format, .raw)
            let index = try XCTUnwrap(["ImA", "ImB", "ImC", "ImUnused"].firstIndex(of: name))
            XCTAssertEqual(data as Data, imageBytes(index))
        }
    }

    private func pixels(_ page: CGPDFPage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 100 * 100 * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 100, height: 100, bitsPerComponent: 8,
                bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            context.drawPDFPage(page)
        }
        return bytes
    }

    private func imageBytes(_ image: Int) -> Data {
        var data = Data(repeating: 0, count: 64 * 64 * 3)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for pixel in 0..<(64 * 64) {
                bytes[pixel * 3] = UInt8((pixel * 11 + image * 41) % 256)
                bytes[pixel * 3 + 1] = UInt8((pixel * 7 + image * 59) % 256)
                bytes[pixel * 3 + 2] = UInt8((pixel * 3 + image * 83) % 256)
            }
        }
        return data
    }

    private func fixture(contents: [String] = ["ImA", "ImB", "ImC"], extraResources: String = "", extraContent: String = "", compressedImages: Bool = false) -> Data {
        func stream(_ bytes: Data, _ entries: String = "") -> Data {
            var value = Data("<< /Length \(bytes.count) \(entries) >>\nstream\n".utf8)
            value.append(bytes); value.append(Data("\nendstream".utf8)); return value
        }
        let resourcesID = 3 + contents.count, namespaceID = resourcesID + 1
        let firstContentID = namespaceID + 1, firstImageID = firstContentID + contents.count
        let kids = contents.indices.map { "\(3 + $0) 0 R" }.joined(separator: " ")
        var objects = [Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [\(kids)] /Count \(contents.count) /Resources \(resourcesID) 0 R /MediaBox [0 0 100 100] >>".utf8)]
        objects += contents.indices.map { Data("<< /Type /Page /Parent 2 0 R /Contents \(firstContentID + $0) 0 R >>".utf8) }
        objects.append(Data("<< /XObject \(namespaceID) 0 R \(extraResources) >>".utf8))
        let names = ["ImA", "ImB", "ImC", "ImUnused"].enumerated().map { "/\($0.element) \(firstImageID + $0.offset) 0 R" }.joined(separator: " ")
        objects.append(Data("<< \(names) >>".utf8))
        objects += contents.map { stream(Data("q 70 0 0 70 15 15 cm /\($0) Do Q \(extraContent)".utf8)) }
        objects += (0..<4).map {
            let bytes = compressedImages ? Data(base64Encoded: "eJztwTEBAAAAwqD1T20ND6AAAAAAAAAAAAAAAIB3AzAAAAE=")! : imageBytes($0)
            return stream(bytes, "/Type /XObject /Subtype /Image /Width 64 /Height 64 /ColorSpace /DeviceRGB /BitsPerComponent 8" + (compressedImages ? " /Filter /FlateDecode" : ""))
        }
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n".utf8)); bytes.append(object); bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }
}
