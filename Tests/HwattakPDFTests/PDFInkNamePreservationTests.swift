// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFInkNamePreservationTests: XCTestCase {
    func testSDKStageDropsNamedInkAndWorkerGraphRestoresOriginalStringBytes() async throws {
        let names = [Data("Named-ink-ascii".utf8), utf16("원본 잉크 이름")]
        // The control uses a distinct graph. A warmed failed save is never the
        // positive preservation test's input.
        let control = try fixture(names: names)
        let controlExtract = try PDFPageOperations.extract(from: control, indexes: [0])
        let isolated = try PDFRecoverySnapshot(capturing: controlExtract)
        let stage = try await Task.detached {
            guard !Thread.isMainThread else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            return try XCTUnwrap(isolated.takeDocument().dataRepresentation())
        }.value
        XCTAssertNil(try rawNameType(stage, page: 0, annotation: 0))
        XCTAssertNil(try rawNameType(stage, page: 0, annotation: 1))

        let source = try fixture(names: names)
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
        let result = try await writtenOnWorker(extracted)
        XCTAssertEqual(try rawName(result, page: 0, annotation: 0), names[0])
        XCTAssertEqual(try rawName(result, page: 0, annotation: 1), names[1])
    }

    func testExtractMergeUndoRedoKeepsNamedInkAndOriginalSource() async throws {
        let names = [Data("Named-one".utf8), Data("Named-two".utf8)]
        let source = try fixture(names: names)
        let before = try XCTUnwrap(source.page(at: 0)).annotations.map { $0.value(forAnnotationKey: .init(rawValue: "/NM")) as? String }
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
        let target = try fixture(names: [])
        let imported = try PDFPageStructurePreserver.prepareImport(from: extracted, indexes: [0])
        let transaction = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: target, at: 1)
        try transaction.apply(); try transaction.undo(); XCTAssertEqual(target.pageCount, 1)
        try transaction.redo(); XCTAssertEqual(target.pageCount, 2)
        let result = try await writtenOnWorker(target)
        for index in names.indices { XCTAssertEqual(try rawName(result, page: 1, annotation: index), names[index]) }
        XCTAssertEqual(source.pageCount, 1)
        XCTAssertEqual(try XCTUnwrap(source.page(at: 0)).annotations.map { $0.value(forAnnotationKey: .init(rawValue: "/NM")) as? String }, before)
    }

    func testCurrentNameChangeWinsOverOriginalRawBytes() async throws {
        let source = try fixture(names: [Data("Original-name".utf8)])
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let ink = try XCTUnwrap(source.page(at: 0)?.annotations.first)
        XCTAssertTrue(ink.setValue("현재 이름", forAnnotationKey: .init(rawValue: "/NM")))
        XCTAssertEqual(ink.value(forAnnotationKey: .init(rawValue: "/NM")) as? String, "현재 이름")
        let result = try await writtenOnWorker(source)
        XCTAssertEqual(try rawName(result, page: 0, annotation: 0), utf16("현재 이름"))
    }

    func testObservableCurrentNameClearDoesNotRestoreOriginal() async throws {
        let source = try fixture(names: [Data("Original-name".utf8)])
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let ink = try XCTUnwrap(source.page(at: 0)?.annotations.first)
        ink.removeValue(forAnnotationKey: .init(rawValue: "/NM"))
        XCTAssertNil(ink.value(forAnnotationKey: .init(rawValue: "/NM")))
        let result = try await writtenOnWorker(source)
        XCTAssertNil(try rawNameType(result, page: 0, annotation: 0))
    }

    func testIdenticalUnnamedProgramsCannotSelectBetweenDistinctNames() throws {
        let source = try fixture(names: [Data("One".utf8), Data("Two".utf8)], duplicateGeometry: true)
        let staged = try fixture(names: [nil, nil], duplicateGeometry: true)
        XCTAssertThrowsError(try proofs(source: source, staged: staged))
    }

    func testReorderedStagedInkIsRefusedInsteadOfChangingAnnotationIndices() throws {
        let source = try fixture(names: [Data("One".utf8), Data("Two".utf8)])
        let staged = try fixture(names: [nil, nil], reverse: true)
        XCTAssertThrowsError(try proofs(source: source, staged: staged))
    }

    func testWrongStagedInkProgramCannotUseMissingNameRepair() throws {
        let source = try fixture(names: [Data("One".utf8)])
        let staged = try fixture(names: [nil], changedProgram: true)
        XCTAssertThrowsError(try proofs(source: source, staged: staged))
    }

    func testPresentForeignAndWrongTypedNamesStayRejected() throws {
        for raw in ["(Foreign-name)", "/NotATextString", "[1 2]", "null"] {
            let source = try fixture(names: [Data("Expected-name".utf8)])
            let staged = try fixture(names: [nil], firstRawName: raw)
            XCTAssertThrowsError(try proofs(source: source, staged: staged), raw)
        }
        let source = try fixture(names: [Data("Expected-name".utf8)])
        let staged = try fixture(names: [Data("Expected-name".utf8)])
        XCTAssertTrue(try proofs(source: source, staged: staged).isEmpty)
    }

    func testUnsupportedLongCurrentNameIsRefusedBeforeGraphStringCopy() throws {
        let source = try fixture(names: [Data("Expected-name".utf8)])
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let ink = try XCTUnwrap(source.page(at: 0)?.annotations.first)
        XCTAssertTrue(ink.setValue(String(repeating: "x", count: 65_537), forAnnotationKey: .init(rawValue: "/NM")))
        XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: source))
    }

    func testUnboundNativeDocumentDoesNotGainMissingNameAuthority() throws {
        let source = try fixture(names: [Data("Expected-name".utf8)], bind: false)
        XCTAssertFalse(PDFRawStreamProvenance.hasKnownNativeInput(source))
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let plan = try PDFCatalogStructurePreserver.plan(for: source)
        XCTAssertTrue(plan.annotationNames.isEmpty)
        let staged = try fixture(names: [nil])
        let dictionary = try XCTUnwrap(staged.documentRef?.page(at: 1)?.dictionary)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "Annots"))
        var raw: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &raw))
        XCTAssertThrowsError(try PDFPageGeometryPreserver.stagedAnnotation(XCTUnwrap(raw),
            matches: XCTUnwrap(source.page(at: 0)?.annotations.first)))
    }

    func testCanonicallyEquivalentRenameUsesCurrentUTF8InsteadOfOldBytes() async throws {
        let old = "e\u{301}", current = "\u{e9}"
        XCTAssertEqual(old, current) // Swift text equality is intentionally insufficient here.
        XCTAssertNotEqual(Data(old.utf8), Data(current.utf8))
        let source = try fixture(names: [utf16(old)])
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let ink = try XCTUnwrap(source.page(at: 0)?.annotations.first)
        XCTAssertTrue(ink.setValue(current, forAnnotationKey: .init(rawValue: "/NM")))
        XCTAssertEqual(Data(try XCTUnwrap(ink.value(forAnnotationKey: .init(rawValue: "/NM")) as? String).utf8), Data(current.utf8))
        let result = try await writtenOnWorker(source)
        XCTAssertEqual(try rawName(result, page: 0, annotation: 0), utf16(current))
        XCTAssertNotEqual(try rawName(result, page: 0, annotation: 0), utf16(old))
    }

    func testCanonicallyEquivalentForeignStagedNameIsStillRejected() throws {
        let source = try fixture(names: [utf16("e\u{301}")])
        let staged = try fixture(names: [utf16("\u{e9}")])
        XCTAssertThrowsError(try proofs(source: source, staged: staged))
    }

    func testCanonicallyDifferentContentsCannotSupplyMissingNameIdentity() throws {
        let source = try fixture(names: [Data("Named-one".utf8)], contents: "e\u{301}")
        let staged = try fixture(names: [nil], contents: "\u{e9}")
        XCTAssertEqual(Data(try XCTUnwrap(source.page(at: 0)?.annotations.first?.contents).utf8), Data("e\u{301}".utf8))
        XCTAssertThrowsError(try proofs(source: source, staged: staged))
    }

    func testOriginallyUnnamedInkKeepsExistingPathWithoutNameIntentOrDrop() throws {
        let source = try fixture(names: [nil])
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let plan = try PDFCatalogStructurePreserver.plan(for: source)
        XCTAssertTrue(plan.annotationNames.isEmpty)
        XCTAssertNil(plan.annotationEntries[0]?[0]?["NM"])
        XCTAssertFalse(plan.annotationDrops[0]?[0]?.contains("NM") == true)
        // Existing unnamed behavior is not turned into a foreign-name refusal.
        let staged = try fixture(names: [Data("Stage-only-name".utf8)])
        let dictionary = try XCTUnwrap(staged.documentRef?.page(at: 1)?.dictionary)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "Annots"))
        var raw: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &raw))
        XCTAssertNoThrow(try PDFPageGeometryPreserver.stagedAnnotation(XCTUnwrap(raw),
            matches: XCTUnwrap(source.page(at: 0)?.annotations.first)))
    }

    private func proofs(source: PDFDocument, staged: PDFDocument) throws -> [Int: PDFPageGeometryPreserver.MissingNameProof] {
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let plan = try PDFCatalogStructurePreserver.plan(for: source)
        let annotations = try XCTUnwrap(source.page(at: 0)).annotations
        let dictionary = try XCTUnwrap(staged.documentRef?.page(at: 1)?.dictionary)
        var bytes = 8 * 1024 * 1024, numbers = 2_000_000
        let result = try PDFPageGeometryPreserver.missingNameProofs(
            staged: PDFCatalogStructurePreserver.array(dictionary, "Annots"), live: annotations,
            names: plan.annotationNames[0] ?? [:], geometries: plan.annotationGeometry[0] ?? [:], remainingBytes: &bytes, remainingNumbers: &numbers)
        XCTAssertEqual(plan.annotationNames[0]?.count, annotations.count)
        return result
    }

    private func writtenOnWorker(_ document: PDFDocument) async throws -> Data {
        let isolated = try PDFRecoverySnapshot(capturing: document)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-Ink-NM-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("saved.pdf")
        return try await Task.detached {
            guard !Thread.isMainThread else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            try AtomicPDFWriter.write(isolated.takeDocument(), to: output)
            return try Data(contentsOf: output)
        }.value
    }

    private func rawNameType(_ data: Data, page: Int, annotation: Int) throws -> CGPDFObjectType? {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let pdf = try XCTUnwrap(CGPDFDocument(provider))
        let dictionary = try XCTUnwrap(pdf.page(at: page + 1)?.dictionary)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "Annots"))
        var item: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, annotation, &item))
        guard let object = PDFCatalogStructurePreserver.object(try XCTUnwrap(item), "NM") else { return nil }
        return CGPDFObjectGetType(object)
    }

    private func rawName(_ data: Data, page: Int, annotation: Int) throws -> Data? {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let pdf = try XCTUnwrap(CGPDFDocument(provider))
        let dictionary = try XCTUnwrap(pdf.page(at: page + 1)?.dictionary)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "Annots"))
        var item: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, annotation, &item))
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(try XCTUnwrap(item), "NM", &value), let value else { return nil }
        let count = CGPDFStringGetLength(value)
        guard count > 0 else { return Data() }
        return Data(bytes: try XCTUnwrap(CGPDFStringGetBytePtr(value)), count: count)
    }

    private func utf16(_ value: String) -> Data {
        var data = Data([0xFE, 0xFF]); data.append(value.data(using: .utf16BigEndian)!); return data
    }
    private func fixture(names: [Data?], duplicateGeometry: Bool = false, reverse: Bool = false,
                         changedProgram: Bool = false, firstRawName: String? = nil, bind: Bool = true,
                         contents: String = "Synthetic ink") throws -> PDFDocument {
        let references = Array(names.indices).map { "\($0 + 5) 0 R" }
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /D >>] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> /Contents 4 0 R /Annots [\((reverse ? references.reversed().map { $0 } : references).joined(separator: " "))] >>",
            "<< /Length 0 >>\nstream\n\nendstream"
        ]
        for (index, name) in names.enumerated() {
            let origin = duplicateGeometry ? 10 : 10 + index * 80
            let end = origin + (changedProgram ? 39 : 40)
            let nm: String
            if index == 0, let firstRawName { nm = "/NM \(firstRawName)" }
            else if let name { nm = "/NM <\(name.map { String(format: "%02x", $0) }.joined())>" }
            else { nm = "" }
            objects.append("<< /Type /Annot /Subtype /Ink /Rect [\(origin) 20 \(origin + 40) 60] /InkList [[\(origin) 20 \(end) 60]] /Contents <\(utf16(contents).map { String(format: "%02x", $0) }.joined())> /C [1 0 0] /BS << /W 1 >> \(nm) >>")
        }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let result = try XCTUnwrap(PDFDocument(data: data))
        if bind { PDFRawStreamProvenance.bindCreated(result, data: data) }
        return result
    }
}
