// SPDX-License-Identifier: MPL-2.0
import CEmberPDFRawStreams
import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFInertOutlineParentTests: XCTestCase {
    func testFixedReaderRejectsIndirectNullArraysTailsNamesRealsAndInvalidHandles() throws {
        let atoms = "[[null 0 0 1] [10 0 R 0 0 1] 11 0 R [null 0.0 0 1] [null 0 0 2] [null 0 0] [null 0 0 1 2] [null /XYZ 0 1] /dead null (null) [null 12 0 R 0 1]]"
        let reader = try Reader(fixture(extraCatalog: "/Atoms " + atoms))
        let values = try reader.value(reader.catalog, "Atoms")
        for index in 0..<12 {
            var match: Int32 = 9
            XCTAssertEqual(ember_raw_pdf_exact_inert_outline_destination(reader.context, try reader.item(values, index), &match), 0)
            XCTAssertEqual(match, index == 0 ? 1 : 0, "atom \(index)")
        }
        for invalid in [EmberRawPDFObject(0), EmberRawPDFObject.max] {
            var match: Int32 = 9
            XCTAssertNotEqual(ember_raw_pdf_exact_inert_outline_destination(reader.context, invalid, &match), 0)
            XCTAssertEqual(match, 0)
        }
        var match: Int32 = 9
        XCTAssertNotEqual(ember_raw_pdf_exact_inert_outline_destination(nil, try reader.item(values, 0), &match), 0)
        XCTAssertEqual(match, 0)
        XCTAssertNotEqual(ember_raw_pdf_exact_inert_outline_destination(reader.context, try reader.item(values, 0), nil), 0)
    }

    @MainActor
    func testColdMainImportAndSnapshotDeferProofThenWorkerExtractMergeAndResaveKeepRawParentAndChildren() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = fixture(), sourceURL = directory.appendingPathComponent("original.pdf")
        try bytes.write(to: sourceURL)
        let source = try PDFSourceFileAccess.loadDocument(at: sourceURL).document
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
        let before = raw.widgetInputFootprint
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 2])
        let plan = try PDFCatalogStructurePreserver.plan(for: extracted)
        XCTAssertEqual(plan.pendingInertOutlineDestinations.count, 1)
        XCTAssertNil(plan.outlineDestinations[[0]])
        let candidate = try XCTUnwrap(plan.pendingInertOutlineDestinations[[0]])
        XCTAssertNil(try candidate.provenValue(), "Cold Main must not initialize the independent reader")
        XCTAssertEqual(raw.widgetInputFootprint.storage, before.storage)
        XCTAssertEqual(raw.widgetInputFootprint.ownedDataBytes, before.ownedDataBytes)
        let snapshot = try PDFRecoverySnapshot(capturing: extracted)
        XCTAssertEqual(raw.widgetInputFootprint.storage, before.storage)
        let selectedURL = directory.appendingPathComponent("selected.pdf")
        let selected = try await saved(snapshot, to: selectedURL)
        try assertParent(selected, path: [0], label: "Group", childPages: [0, 1])
        let reopened = try PDFSourceFileAccess.loadDocument(at: selectedURL).document
        let target = try bound(fixture(outlines: false))
        let imported = try PDFPageStructurePreserver.prepareImport(from: reopened, indexes: [0, 1])
        let merge = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: target, at: 1)
        try merge.apply(); try merge.undo(); try merge.redo()
        let mergedURL = directory.appendingPathComponent("merged.pdf")
        let merged = try await saved(PDFRecoverySnapshot(capturing: target), to: mergedURL)
        try assertParent(merged, path: [0, 0], label: "Group", childPages: [1, 2])
        let finalDocument = try PDFSourceFileAccess.loadDocument(at: mergedURL).document
        let final = try await saved(PDFRecoverySnapshot(capturing: finalDocument), to: directory.appendingPathComponent("resaved.pdf"))
        try assertParent(final, path: [0, 0], label: "Group", childPages: [1, 2])
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
    }

    @MainActor
    func testCurrentTitleChildOrderURIAndValidDestinationRemainAuthoritative() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        for change in ["title-order", "uri", "target"] {
            let source = try bound(fixture())
            try PDFCatalogStructurePreserver.prepare(source, force: true)
            let parent = try XCTUnwrap(source.outlineRoot?.child(at: 0))
            XCTAssertNotNil(PDFCatalogStructurePreserver.pendingInertOutlineCandidate(parent))
            switch change {
            case "title-order":
                parent.label = "Current title"
                let first = try XCTUnwrap(parent.child(at: 0)); first.removeFromParent(); parent.insertChild(first, at: 1)
            case "uri": parent.action = PDFActionURL(url: URL(string: "https://example.com/current")!)
            default:
                parent.action = nil
                let destination = PDFDestination(page: try XCTUnwrap(source.page(at: 1)), at: CGPoint(x: 31, y: 41)); destination.zoom = 2
                parent.destination = destination
            }
            print("INERT081_CURRENT_STAGE", change, "before-extract")
            let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 1, 2])
            print("INERT081_CURRENT_STAGE", change, "before-snapshot")
            let output = try await saved(PDFRecoverySnapshot(capturing: extracted), to: directory.appendingPathComponent(change + ".pdf"))
            let reader = try Reader(output)
            let stored = try reader.outline([0])
            switch change {
            case "title-order": try assertParent(output, path: [0], label: "Current title", childPages: [2, 0])
            case "uri":
                XCTAssertFalse(try reader.keys(stored).contains(Data("/Dest".utf8)))
                let action = try reader.value(stored, "A")
                XCTAssertEqual(try reader.name(reader.value(action, "S")), Data("/URI".utf8))
                XCTAssertEqual(try reader.string(reader.value(action, "URI")), Data("https://example.com/current".utf8))
            default:
                let destination = try reader.value(stored, "Dest")
                XCTAssertEqual(try reader.item(destination, 0), reader.page(1))
                XCTAssertEqual(try reader.name(reader.item(destination, 1)), Data("/XYZ".utf8))
                XCTAssertEqual(try reader.number(reader.item(destination, 2)), 31)
                XCTAssertEqual(try reader.number(reader.item(destination, 3)), 41)
                XCTAssertEqual(try reader.number(reader.item(destination, 4)), 2)
                // Clear the newly active copied target; no old inert metadata
                // may be reintroduced into this assembled edited outline.
                let copiedParent = try XCTUnwrap(extracted.outlineRoot?.child(at: 0))
                copiedParent.action = nil; copiedParent.destination = nil
                print("INERT081_CLEAR_ORDER", copiedParent.action?.type ?? "nil", copiedParent.destination == nil)
                // PDFKit's destination setter can synthesize an empty GoTo.
                // Clear the action last and prove the intended nil/nil state.
                copiedParent.destination = nil; copiedParent.action = nil
                XCTAssertNil(copiedParent.action)
                XCTAssertNil(copiedParent.destination)
                print("INERT081_CURRENT_STAGE", change, "before-cleared-snapshot")
                let cleared = try await saved(PDFRecoverySnapshot(capturing: extracted), to: directory.appendingPathComponent("cleared.pdf"))
                let clearReader = try Reader(cleared)
                XCTAssertFalse(try clearReader.keys(clearReader.outline([0])).contains(Data("/Dest".utf8)))
            }
        }
    }

    @MainActor
    func testOnlyFactoryOwnerExactNativeNodeAndPathCanMintPendingCandidate() async throws {
        let bytes = fixture(), source = try bound(bytes), foreign = try bound(bytes)
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
        let native = try XCTUnwrap(source.documentRef), node = try nativeParent(source)
        let before = raw.widgetInputFootprint
        let candidate = try XCTUnwrap(raw.pendingOriginalInertOutlineParent(in: native, node: node, path: [0]))
        XCTAssertNil(try raw.pendingOriginalInertOutlineParent(in: try XCTUnwrap(foreign.documentRef), node: node, path: [0]))
        XCTAssertNil(try raw.pendingOriginalInertOutlineParent(in: native, node: nativeParent(foreign), path: [0]))
        for path in [[], [1], [-1], Array(repeating: 0, count: 64)] {
            XCTAssertNil(try raw.pendingOriginalInertOutlineParent(in: native, node: node, path: path))
        }
        let generic = try XCTUnwrap(PDFDocument(data: bytes)); PDFRawStreamProvenance.bindCreated(generic, data: bytes)
        let unbound = try XCTUnwrap(PDFRawStreamProvenance.source(for: generic))
        XCTAssertNil(try unbound.pendingOriginalInertOutlineParent(in: try XCTUnwrap(generic.documentRef), node: nativeParent(generic), path: [0]))
        XCTAssertNil(try candidate.provenValue())
        XCTAssertEqual(raw.widgetInputFootprint.storage, before.storage)
        XCTAssertEqual(raw.widgetInputFootprint.ownedDataBytes, before.ownedDataBytes)
        let positive = try await Task.detached { try candidate.provenValue() != nil }.value
        XCTAssertTrue(positive)
        XCTAssertNotNil(try candidate.provenValue(), "Only a completed worker proof may be reused on Main")
    }

    @MainActor
    func testAliasesWrongShapesExtraActionAndLeafCannotProduceOutput() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(String, String, Bool)] = [
            ("[10 0 R 0 0 1]", "", true), ("11 0 R", "", true),
            ("[null 12 0 R 0 1]", "", true), ("[null 0.0 0 1]", "", true),
            ("[null 0 0 2]", "", true), ("[null 0 0]", "", true),
            ("[null 0 0 1 2]", "", true), ("[null /Wrong 0 1]", "", true),
            ("[null 0 0 1]", "/A null", true), ("[null 0 0 1]", "/Extra null", true),
            ("[null 0 0 1]", "", false)
        ]
        for (index, item) in cases.enumerated() {
            let bytes = fixture(destination: item.0, parentExtra: item.1, children: item.2)
            _ = try Reader(bytes) // All premises must be valid for the strict reader.
            let source = try bound(bytes), url = directory.appendingPathComponent("blocked-\(index).pdf")
            do {
                let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 2])
                _ = try await saved(PDFRecoverySnapshot(capturing: extracted), to: url)
                XCTFail("Unsupported source shape produced output: \(index)")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(index)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(index)")
        }
    }

    @MainActor
    func testCancelledDeferredProofDoesNotPublishAndCanBeRetried() async throws {
        let source = try bound(fixture()), raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
        let candidate = try XCTUnwrap(raw.pendingOriginalInertOutlineParent(in: try XCTUnwrap(source.documentRef), node: nativeParent(source), path: [0]))
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        let cancelled = await Task.detached { () -> Bool in
            do { _ = try PDFSaveCancellation.withCurrent(cancellation) { try candidate.provenValue() }; return false }
            catch { return error is CancellationError }
        }.value
        XCTAssertTrue(cancelled)
        XCTAssertNil(try candidate.provenValue(), "Cancellation must not publish a positive proof")
        let positive = try await Task.detached { try candidate.provenValue() != nil }.value
        XCTAssertTrue(positive)
    }

    @MainActor private func saved(_ snapshot: PDFRecoverySnapshot, to url: URL) async throws -> Data {
        let request = try PDFBackgroundSaveRequest(destinationURL: url, originalURL: nil, overwritingOriginal: false)
        _ = try await PDFBackgroundSaveWriter.write(snapshot: snapshot, request: request, cancellation: PDFSaveCancellation())
        return try Data(contentsOf: url)
    }
    private func bound(_ bytes: Data) throws -> PDFDocument { try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes)) }
    private func nativeParent(_ document: PDFDocument) throws -> CGPDFDictionaryRef {
        try XCTUnwrap(document.documentRef?.catalog.flatMap { PDFCatalogStructurePreserver.dictionary($0, "Outlines") }.flatMap { PDFCatalogStructurePreserver.dictionary($0, "First") })
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-inert-outline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func assertParent(_ bytes: Data, path: [Int], label: String, childPages: [Int]) throws {
        let reader = try Reader(bytes), node = try reader.outline(path)
        var matches: Int32 = 9
        XCTAssertEqual(ember_raw_pdf_exact_inert_outline_destination(reader.context, try reader.value(node, "Dest"), &matches), 0)
        XCTAssertEqual(matches, 1)
        XCTAssertEqual(try reader.text(reader.value(node, "Title")), label)
        XCTAssertFalse(try reader.keys(node).contains(Data("/A".utf8)))
        var child = try reader.value(node, "First")
        for index in childPages.indices {
            let destination = try reader.value(child, "Dest")
            XCTAssertEqual(try reader.item(destination, 0), reader.page(childPages[index]))
            let view = try reader.name(reader.item(destination, 1))
            XCTAssertEqual(view, Data((try reader.text(reader.value(child, "Title")) == "First" ? "/Fit" : "/XYZ").utf8))
            if index + 1 < childPages.count { child = try reader.value(child, "Next") }
        }
        XCTAssertEqual(try reader.kind(reader.value(child, "Next")), Int32(EMBER_RAW_PDF_NULL.rawValue))
    }
    private func fixture(destination: String = "[null 0 0 1]", parentExtra: String = "", children: Bool = true,
                         outlines: Bool = true, extraCatalog: String = "") -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R \(outlines ? "/Outlines 6 0 R" : "") \(extraCatalog) >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>",
            "<< /Type /Outlines /First 7 0 R /Last 7 0 R /Count 3 >>",
            "<< /Title (Group) /Parent 6 0 R /Dest \(destination) \(children ? "/First 8 0 R /Last 9 0 R /Count 2" : "") \(parentExtra) >>",
            "<< /Title (First) /Parent 7 0 R /Dest [3 0 R /Fit] /Next 9 0 R >>",
            "<< /Title (Last) /Parent 7 0 R /Dest [5 0 R /XYZ 10 20 1] /Prev 8 0 R >>",
            "null", "[null 0 0 1]", "0"
        ]
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)); return bytes
    }

    private final class Reader {
        let context: EmberRawPDFRef, catalog: EmberRawPDFObject
        init(_ bytes: Data) throws {
            var status: Int32 = 9
            let pointer = bytes.withUnsafeBytes { ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, bytes.count, 4 * 1024 * 1024, 10_000, &status) }
            guard status == 0, let pointer else { throw NSError(domain: "InertOutlineFixture", code: Int(status)) }
            context = pointer; var root: EmberRawPDFObject = 0
            guard ember_raw_pdf_catalog(pointer, &root) == 0 else { ember_raw_pdf_destroy(pointer); throw NSError(domain: "InertOutlineRoot", code: 1) }; catalog = root
        }
        deinit { ember_raw_pdf_destroy(context) }
        func value(_ object: EmberRawPDFObject, _ key: String) throws -> EmberRawPDFObject {
            var result: EmberRawPDFObject = 0
            let status = Array(("/" + key).utf8).withUnsafeBufferPointer { ember_raw_pdf_dictionary_get(context, object, $0.baseAddress, $0.count, &result) }
            guard status == 0 else { throw NSError(domain: "InertOutlineKey", code: Int(status)) }; return result
        }
        func item(_ object: EmberRawPDFObject, _ index: Int) throws -> EmberRawPDFObject {
            var result: EmberRawPDFObject = 0
            guard ember_raw_pdf_array_item(context, object, UInt32(index), &result) == 0 else { throw NSError(domain: "InertOutlineSlot", code: index) }; return result
        }
        func page(_ index: Int) -> EmberRawPDFObject {
            var result: EmberRawPDFObject = 0; XCTAssertEqual(ember_raw_pdf_page(context, UInt32(index), &result), 0); return result
        }
        func kind(_ object: EmberRawPDFObject) throws -> Int32 {
            var value: Int32 = -1; guard ember_raw_pdf_kind(context, object, &value) == 0 else { throw NSError(domain: "InertOutlineKind", code: 1) }; return value
        }
        func number(_ object: EmberRawPDFObject) throws -> Double {
            if try kind(object) == Int32(EMBER_RAW_PDF_INTEGER.rawValue) {
                var integer: Int64 = 0
                guard ember_raw_pdf_integer(context, object, &integer) == 0 else { throw NSError(domain: "InertOutlineInteger", code: 1) }
                return Double(integer)
            }
            var value: Double = .nan; guard ember_raw_pdf_real(context, object, &value) == 0 else { throw NSError(domain: "InertOutlineNumber", code: 1) }; return value
        }
        func text(_ object: EmberRawPDFObject) throws -> String {
            let bytes = try string(object)
            return try XCTUnwrap(bytes.starts(with: [0xfe, 0xff]) ? String(data: bytes.dropFirst(2), encoding: .utf16BigEndian) : String(data: bytes, encoding: .utf8))
        }
        func name(_ object: EmberRawPDFObject) throws -> Data { try copied(object, isName: true) }
        func string(_ object: EmberRawPDFObject) throws -> Data { try copied(object, isName: false) }
        private func copied(_ object: EmberRawPDFObject, isName: Bool) throws -> Data {
            var pointer: UnsafeMutablePointer<UInt8>?, count = 0
            let status = isName ? ember_raw_pdf_name_copy(context, object, &pointer, &count) : ember_raw_pdf_string_copy(context, object, &pointer, &count)
            defer { if let pointer { ember_raw_pdf_free(pointer) } }
            guard status == 0, count <= 4096, count == 0 || pointer != nil else { throw NSError(domain: "InertOutlineBytes", code: Int(status)) }
            return pointer.map { Data(bytes: $0, count: count) } ?? Data()
        }
        func keys(_ object: EmberRawPDFObject) throws -> Set<Data> {
            var count: UInt32 = 0; guard ember_raw_pdf_dictionary_count(context, object, &count) == 0, count <= 64 else { throw NSError(domain: "InertOutlineKeys", code: 1) }
            var result = Set<Data>()
            for index in 0..<count {
                var pointer: UnsafeMutablePointer<UInt8>?, length = 0
                let status = ember_raw_pdf_dictionary_key_copy(context, object, index, &pointer, &length)
                defer { if let pointer { ember_raw_pdf_free(pointer) } }
                guard status == 0, length <= 4096, length == 0 || pointer != nil else { throw NSError(domain: "InertOutlineKeyBytes", code: Int(status)) }
                result.insert(pointer.map { Data(bytes: $0, count: length) } ?? Data())
            }
            return result
        }
        func outline(_ path: [Int]) throws -> EmberRawPDFObject {
            var parent = try value(catalog, "Outlines")
            for index in path {
                var child = try value(parent, "First")
                for _ in 0..<index { child = try value(child, "Next") }
                parent = child
            }
            return parent
        }
    }
}
