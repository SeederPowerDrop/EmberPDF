// SPDX-License-Identifier: MPL-2.0
import AppKit
import PDFKit
import XCTest
import zlib
@testable import HwattakPDF

/// The SDK staging graph is not the painting authority. These deliberately
/// different source/staged namespaces make retained shadowed resources visible.
@MainActor
final class PDFStagedInheritedResourceTests: XCTestCase {
    func testEmptySourceLeavesDoNotRetainSDKOnlyParentResources() async throws {
        let source = try Self.open(Self.fixture(source: true, empty: true))
        let before = try (0..<2).map { try Self.pixels(XCTUnwrap(source.page(at: $0))) }
        let bytes = try await Self.rewrite(source, staged: Self.fixture(source: false))
        let saved = try Self.open(bytes)
        XCTAssertEqual(saved.pageCount, 2)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("SDKOnlyGhost"))
        for index in 0..<2 {
            let page = try XCTUnwrap(saved.page(at: index)), dictionary = try XCTUnwrap(page.pageRef?.dictionary)
            let resources = try Self.dictionary(dictionary, "Resources")
            XCTAssertEqual(CGPDFDictionaryGetCount(resources), 0)
            XCTAssertFalse(Self.has(try Self.dictionary(dictionary, "Parent"), "Resources"))
            XCTAssertEqual(try Self.pixels(page), before[index])
        }
        for index in 0..<2 {
            let original = try XCTUnwrap(source.page(at: index)?.pageRef?.dictionary)
            XCTAssertEqual(CGPDFDictionaryGetCount(try Self.dictionary(original, "Resources")), 0)
            XCTAssertNil(try Self.optionalDictionary(try Self.dictionary(original, "Parent"), "Resources"))
        }
    }

    func testEveryLeafKeepsInheritedOriginalResourcesAndSharedEncodedStream() async throws {
        let source = try Self.open(Self.fixture(source: true))
        let before = try (0..<2).map { try Self.pixels(XCTUnwrap(source.page(at: $0))) }
        let sourceParent = try Self.dictionary(XCTUnwrap(source.page(at: 0)?.pageRef?.dictionary), "Parent")
        XCTAssertTrue(Self.has(sourceParent, "Resources"))
        let bytes = try await Self.rewrite(source, staged: Self.fixture(source: false))
        let saved = try Self.open(bytes)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("SDKOnlyGhost"))
        for index in 0..<2 {
            let page = try XCTUnwrap(saved.page(at: index)), dictionary = try XCTUnwrap(page.pageRef?.dictionary)
            XCTAssertTrue(Self.has(dictionary, "Resources")) // Explicit on every leaf, including page2.
            XCTAssertFalse(Self.has(try Self.dictionary(dictionary, "Parent"), "Resources"))
            XCTAssertEqual(try Self.pixels(page), before[index])
        }
        let expected = try Self.flate(Self.sourceSamples)
        try await Task.detached {
            let native = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: bytes as CFData)!))
            let first = try XCTUnwrap(native.page(at: 1)), second = try XCTUnwrap(native.page(at: 2))
            let a = try Self.dictionary(Self.dictionary(XCTUnwrap(first.dictionary), "Resources"), "XObject")
            let b = try Self.dictionary(Self.dictionary(XCTUnwrap(second.dictionary), "Resources"), "XObject")
            let picture = try Self.stream(a, "Picture")
            XCTAssertEqual(picture, try Self.stream(a, "Alias"))
            XCTAssertEqual(picture, try Self.stream(b, "Picture"))
            let raw = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: bytes))
            try raw.preparePaintingResources(for: [first, second])
            XCTAssertEqual(try raw.payload(for: picture), expected)
        }.value
        XCTAssertTrue(Self.has(sourceParent, "Resources")) // Source dictionaries are never mutated.
    }

    func testCurrentTextNoteAndIndependentlyReferencedAppearanceResourcesRemain() async throws {
        let source = try Self.open(Self.fixture(source: true, note: false))
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let livePage = try XCTUnwrap(source.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 2, y: 52, width: 10, height: 10),
            forType: .text, withProperties: nil)
        note.setValue("qa-note", forAnnotationKey: PDFAnnotationKey(rawValue: "/NM"))
        livePage.addAnnotation(note)
        // A newly created PDFKit Text annotation owns a synthesized Popup.
        // This fixture deliberately stages one standalone Text annotation.
        if let popup = note.popup {
            note.popup = nil
            if popup.page === livePage { livePage.removeAnnotation(popup) }
        }
        // Popup detachment can reset its owning Text annotation contents.
        // Establish the standalone fixture value only after that SDK operation.
        note.contents = "Current detached note"
        XCTAssertEqual(note.contents, "Current detached note")
        XCTAssertNil(note.popup)
        XCTAssertEqual(livePage.annotations.count, 1)
        XCTAssertTrue(note.page === livePage)
        // The original factory page had no annotation/AP origin. Only this
        // newly added current note owns the staged carrier appearance below.
        let appearanceProgram = Data("q 10 0 0 10 0 0 cm /SDKOnlyGhost Do Q\n".utf8)
        let bytes = try await Self.rewrite(source, staged: Self.fixture(source: false, note: true))
        let saved = try Self.open(bytes), page = try XCTUnwrap(saved.page(at: 0))
        XCTAssertEqual(page.annotations.filter { $0.type == "Text" }.count, 1)
        XCTAssertEqual(page.annotations.first { $0.type == "Text" }?.contents, "Current detached note")
        XCTAssertEqual(note.contents, "Current detached note")
        let dictionary = try XCTUnwrap(page.pageRef?.dictionary)
        XCTAssertFalse(Self.has(try Self.dictionary(dictionary, "Parent"), "Resources"))
        // The very same namespace remains reachable through the current AP.
        // A global unused-resource or stream deletion would incorrectly lose it.
        var annotations: CGPDFArrayRef?, annotation: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "Annots", &annotations))
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), 0, &annotation))
        let appearance = try Self.stream(Self.dictionary(XCTUnwrap(annotation), "AP"), "N")
        let appearanceResources = try Self.dictionary(XCTUnwrap(CGPDFStreamGetDictionary(appearance)), "Resources")
        let objects = try Self.dictionary(appearanceResources, "XObject")
        XCTAssertEqual(try Self.stream(objects, "SDKOnlyGhost"), try Self.stream(objects, "SDKAlias"))
        var format = CGPDFDataFormat.raw
        XCTAssertEqual(try XCTUnwrap(CGPDFStreamCopyData(appearance, &format)) as Data, appearanceProgram)
        XCTAssertEqual(format, .raw)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("SDKOnlyGhost"))
        let sourceObjects = try Self.dictionary(Self.dictionary(dictionary, "Resources"), "XObject")
        XCTAssertTrue(Self.has(sourceObjects, "Picture"))
        XCTAssertFalse(Self.has(sourceObjects, "SDKOnlyGhost"))
    }

    func testSinglePageCanonicalSnapshotStaysDeterministicAcrossDocumentRewrite() async throws {
        let source = try Self.open(Self.fixture(source: true)), page = try XCTUnwrap(source.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.originalPageData(for: page)
        _ = try await Self.rewrite(source, staged: Self.fixture(source: false))
        let after = try PDFBodyTextPageSnapshot.originalPageData(for: page)
        XCTAssertEqual(before, after)
        let canonical = try Self.open(after)
        XCTAssertEqual(canonical.pageCount, 1)
        XCTAssertEqual(try Self.pixels(XCTUnwrap(canonical.page(at: 0))), try Self.pixels(page))
    }

    private static func rewrite(_ source: PDFDocument, staged: Data) async throws -> Data {
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        return try await Task.detached {
            let plan = try PDFCatalogStructurePreserver.plan(for: source)
            return try PDFBodyTextPageSnapshot.preservingCatalog(in: staged, from: source, plan: plan)
        }.value
    }

    private static func open(_ bytes: Data) throws -> PDFDocument {
        try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
    }

    nonisolated private static let sourceSamples = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])

    nonisolated private static func fixture(source: Bool, empty: Bool = false, note: Bool = false) throws -> Data {
        func stream(_ dictionary: String, _ bytes: Data) -> Data {
            var result = Data("<< \(dictionary) /Length \(bytes.count) >>\nstream\n".utf8)
            result.append(bytes); result.append(Data("\nendstream".utf8)); return result
        }
        let name = source ? "Picture" : "SDKOnlyGhost", alias = source ? "Alias" : "SDKAlias"
        let parentResources = source && empty ? "" : "/Resources 5 0 R"
        let leafResources = source && empty ? "/Resources << >>" : ""
        let program = source && empty ? Data("0.1 0.2 0.3 rg 8 8 48 48 re f\n".utf8)
            : Data("q 48 0 0 48 8 8 cm /\(name) Do Q\n".utf8)
        let image = try flate(source ? sourceSamples : Data(repeating: 17, count: 12))
        let appearance = Data("q 10 0 0 10 0 0 cm /\(name) Do Q\n".utf8)
        let objects = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 \(parentResources) >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 64 64] \(leafResources) /Contents 7 0 R \(note ? "/Annots [9 0 R]" : "") >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 64 64] \(leafResources) /Contents 8 0 R >>".utf8),
            Data("<< /XObject << /\(name) 6 0 R /\(alias) 6 0 R >> >>".utf8),
            stream("/Type /XObject /Subtype /Image /Width 2 /Height 2 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /FlateDecode", image),
            stream("", program), stream("", program),
            Data("<< /Type /Annot /Subtype /Text /Rect [2 52 12 62] /NM (qa-note) /Contents (\(source ? "Kept note" : "Current detached note")) /AP << /N 10 0 R >> >>".utf8),
            stream("/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources 5 0 R", appearance)
        ]
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n".utf8)); bytes.append(object); bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }

    nonisolated private static func flate(_ bytes: Data) throws -> Data {
        var count = compressBound(uLong(bytes.count)), result = Data(count: Int(compressBound(uLong(bytes.count))))
        let status = result.withUnsafeMutableBytes { output in
            bytes.withUnsafeBytes { input in
                compress2(output.baseAddress!.assumingMemoryBound(to: Bytef.self), &count,
                    input.baseAddress!.assumingMemoryBound(to: Bytef.self), uLong(bytes.count), Z_BEST_SPEED)
            }
        }
        XCTAssertEqual(status, Z_OK); result.count = Int(count); return result
    }

    nonisolated private static func optionalDictionary(_ object: CGPDFDictionaryRef, _ key: String) throws -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        if !CGPDFDictionaryGetDictionary(object, key, &value) { return nil }
        return try XCTUnwrap(value)
    }
    nonisolated private static func dictionary(_ object: CGPDFDictionaryRef, _ key: String) throws -> CGPDFDictionaryRef {
        try XCTUnwrap(optionalDictionary(object, key))
    }
    nonisolated private static func stream(_ object: CGPDFDictionaryRef, _ key: String) throws -> CGPDFStreamRef {
        var value: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetStream(object, key, &value)); return try XCTUnwrap(value)
    }
    nonisolated private static func has(_ object: CGPDFDictionaryRef, _ key: String) -> Bool {
        var value: CGPDFObjectRef?; return CGPDFDictionaryGetObject(object, key, &value)
    }
    private static func pixels(_ page: PDFPage) throws -> Data {
        let native = try XCTUnwrap(page.pageRef), width = 64, height = 64
        var bytes = Data(count: width * height * 4)
        try bytes.withUnsafeMutableBytes { output in
            let context = try XCTUnwrap(CGContext(data: output.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            context.drawPDFPage(native)
        }
        return bytes
    }
}
