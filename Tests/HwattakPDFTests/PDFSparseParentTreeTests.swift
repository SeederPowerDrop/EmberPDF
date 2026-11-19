// SPDX-License-Identifier: MPL-2.0

import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFSparseParentTreeTests: XCTestCase {
    func testBulkParentEnumerationKeepsEmptyAndAllLiteralNullArraysAndCanRetryAfterCancellation() throws {
        for count in [0, 4_096, 100_000] {
            let source = try fixture(count: count, mcids: [100_001, 100_002])
            let native = try XCTUnwrap(source.document.documentRef)
            let raw = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: source.data))
            let parents = try nativeParents(source.document)
            let cancellation = PDFSaveCancellation(); cancellation.cancel()
            XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(cancellation) {
                try raw.parentArrayMemberIndices(for: parents, key: 0, in: native)
            }) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(try raw.parentArrayMemberIndices(for: parents, key: 0, in: native), [])
            XCTAssertEqual(CGPDFArrayGetCount(parents), count, "Trailing nulls must retain their declared positions.")
            XCTAssertEqual(try raw.parentArrayMemberIndices(for: parents, key: 0, in: native), [])
        }
    }

    func testProvenSourceBulkEnumerationMatchesTheCompleteNativeValidationOutput() throws {
        let source = try fixture(count: 4_096, mcids: [17, 3_079])
        let native = try XCTUnwrap(source.document.documentRef)
        let raw = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: source.data))
        let parents = try nativeParents(source.document)
        XCTAssertEqual(try raw.parentArrayMemberIndices(for: parents, key: 0, in: native), [17, 3_079])
        let legacy = try PDFBodyTextPageSnapshot.preservingCatalog(in: source.data,
            from: source.document, plan: preserved(source.document))
        var fastGroup = try group(source.document)
        fastGroup.rawStreamSource = raw
        var fastPlan = PDFCatalogGraphPlan()
        try PDFTaggedStructurePreserver.addPreservedTags(from: [fastGroup], to: &fastPlan)
        let (count, members) = try sparse(parentValue(fastPlan))
        XCTAssertEqual(count, 4_096)
        XCTAssertEqual(Set(members.keys), [17, 3_079])
        let fast = try PDFBodyTextPageSnapshot.preservingCatalog(in: source.data,
            from: source.document, plan: fastPlan)
        // Independent raw-PDF comparison established that even two legacy
        // saves can order Catalog/Page keys differently. Compare all resolved
        // native values and shared-container topology instead of lexical order.
        XCTAssertEqual(try resolvedGraph(XCTUnwrap(PDFDocument(data: fast))),
                       try resolvedGraph(XCTUnwrap(PDFDocument(data: legacy))),
                       "Every hole, owner, reference, resource and tag value must match the established validator.")
    }

    func testBulkParentEnumerationCannotAuthorizeForeignArraysDocumentsOrKeys() throws {
        let source = try fixture(count: 4_096, mcids: [17, 3_079])
        let native = try XCTUnwrap(source.document.documentRef)
        let raw = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: source.data))
        let foreign = try XCTUnwrap(PDFDocument(data: source.data))
        let parents = try nativeParents(source.document)
        XCTAssertNil(try raw.parentArrayMemberIndices(for: parents, key: 0,
            in: XCTUnwrap(foreign.documentRef)))
        XCTAssertNil(try raw.parentArrayMemberIndices(for: nativeParents(foreign), key: 0, in: native))
        XCTAssertNil(try raw.parentArrayMemberIndices(for: parents, key: 1, in: native))
        XCTAssertNil(try raw.parentArrayMemberIndices(for: parents, key: -1, in: native))
        // Failed foreign requests must not poison the legitimate immutable source.
        XCTAssertEqual(try raw.parentArrayMemberIndices(for: parents, key: 0, in: native), [17, 3_079])
    }

    func testResolvedGraphComparisonDetectsChangedMCIDsAndTrailingNullPositions() throws {
        let baseline = try fixture(count: 4_096, mcids: [17, 3_079])
        let extraTrailingHole = try fixture(count: 4_097, mcids: [17, 3_079])
        let movedOwner = try fixture(count: 4_096, mcids: [17, 3_078])
        let expected = try resolvedGraph(baseline.document)
        XCTAssertNotEqual(try resolvedGraph(extraTrailingHole.document), expected)
        XCTAssertNotEqual(try resolvedGraph(movedOwner.document), expected)
    }

    func testBulkEnumerationStillRejectsInvalidUnclaimedSlotsWithoutPublishingAPlan() throws {
        for invalidIndex in [0, 1_997, 4_095] {
            for invalid in ["42", "true", "(invalid)", "[null]", "/Invalid", "999 0 R"] {
                let source = try fixture(count: 4_096, mcids: [17, 3_079], invalid: invalid,
                                         invalidIndex: invalidIndex)
                let native = try XCTUnwrap(source.document.documentRef)
                let raw = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: source.data))
                XCTAssertNil(try raw.parentArrayMemberIndices(for: nativeParents(source.document), key: 0, in: native))
                var fastGroup = try group(source.document); fastGroup.rawStreamSource = raw
                var plan = PDFCatalogGraphPlan(); plan.catalogEntries["Sentinel"] = .integer(7)
                XCTAssertThrowsError(try PDFTaggedStructurePreserver.addPreservedTags(from: [fastGroup], to: &plan))
                XCTAssertEqual(plan.catalogEntries.count, 1)
                XCTAssertTrue(plan.aliases.isEmpty)
                XCTAssertTrue(plan.pageEntries.isEmpty)
            }
        }
    }

    func testLargeParentArrayStoresOnlyItsOwnersWithoutMovingMCIDsOrTrimmingHoles() throws {
        let source = try fixture(count: 100_000, mcids: [17, 99_990])
        let plan = try preserved(source.document)
        let (count, members) = try sparse(parentValue(plan))
        XCTAssertEqual(count, 100_000)
        XCTAssertEqual(Set(members.keys), [17, 99_990])
        XCTAssertEqual(members.count, 2)
        let children = try array(node(plan.catalogEntries["StructTreeRoot"]).entries["K"])
        XCTAssertTrue(try node(members[17]) === node(children[0]))
        XCTAssertTrue(try node(members[99_990]) === node(children[1]))
    }

    func testRoundTripKeepsLeadingInteriorTrailingHolesAndOriginalPainting() throws {
        let source = try fixture(count: 4_096, mcids: [17, 3_079])
        let saved = try PDFBodyTextPageSnapshot.preservingCatalog(in: source.data,
            from: source.document, plan: preserved(source.document))
        let reopened = try XCTUnwrap(PDFDocument(data: saved))
        let slots = try nativeParents(reopened)
        XCTAssertEqual(CGPDFArrayGetCount(slots), 4_096)
        for index in [0, 16, 18, 3_078, 3_080, 4_095] {
            var value: CGPDFObjectRef?
            XCTAssertTrue(CGPDFArrayGetObject(slots, index, &value))
            XCTAssertEqual(CGPDFObjectGetType(try XCTUnwrap(value)), .null)
        }
        for index in [17, 3_079] {
            var owner: CGPDFDictionaryRef?, children: CGPDFArrayRef?, mcr: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(slots, index, &owner))
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(owner), "K", &children))
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(children), 0, &mcr))
            var mcid: CGPDFInteger = -1
            XCTAssertTrue(CGPDFDictionaryGetInteger(try XCTUnwrap(mcr), "MCID", &mcid))
            XCTAssertEqual(mcid, index)
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(reopened.page(at: 0))),
                       try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(source.document.page(at: 0))))
        XCTAssertEqual(reopened.string, source.document.string)
    }

    func testInvalidUnclaimedSlotsStillFailBeforeCommittingAnyPlanChanges() throws {
        for invalidIndex in [0, 1_997, 4_095] {
            for invalid in ["42", "true", "(invalid)", "[null]", "/Invalid", "999 0 R"] {
                let source = try fixture(count: 4_096, mcids: [17, 3_079], invalid: invalid,
                                         invalidIndex: invalidIndex)
                var plan = PDFCatalogGraphPlan()
                plan.catalogEntries["Sentinel"] = .integer(7)
                XCTAssertThrowsError(try PDFTaggedStructurePreserver.addPreservedTags(
                    from: [group(source.document)], to: &plan), invalid)
                XCTAssertEqual(plan.catalogEntries.count, 1)
                XCTAssertTrue(plan.aliases.isEmpty)
                XCTAssertTrue(plan.pageEntries.isEmpty)
            }
        }
    }

    func testMissingReverseArrayUsesTheSameForwardIndicesAndExactRequiredLength() throws {
        let source = try fixture(count: 4_096, mcids: [17, 3_079], missingReverse: true)
        let (count, members) = try sparse(parentValue(preserved(source.document)))
        XCTAssertEqual(count, 3_080)
        XCTAssertEqual(Set(members.keys), [17, 3_079])
    }

    func testWriterRejectsInvalidSparseCountsAndMemberIndices() throws {
        let source = try fixture(count: 8, mcids: [1, 6])
        for value in [PDFCatalogGraphValue.sparseArray(count: -1, members: [:]),
                      .sparseArray(count: 250_001, members: [:]),
                      .sparseArray(count: 2, members: [-1: .integer(7)]),
                      .sparseArray(count: 2, members: [2: .integer(7)])] {
            var plan = PDFCatalogGraphPlan()
            plan.catalogEntries["EmberSparseTest"] = value
            XCTAssertThrowsError(try PDFBodyTextPageSnapshot.preservingCatalog(in: source.data,
                from: source.document, plan: plan))
        }
    }

    func testEmptyAndEntirelyNullSparseArraysKeepTheirDeclaredLength() throws {
        let source = try fixture(count: 8, mcids: [1, 6])
        for count in [0, 4_096] {
            var plan = PDFCatalogGraphPlan()
            plan.catalogEntries["EmberSparseTest"] = .sparseArray(count: count, members: [:])
            let saved = try PDFBodyTextPageSnapshot.preservingCatalog(in: source.data,
                from: source.document, plan: plan)
            let reopened = try XCTUnwrap(PDFDocument(data: saved))
            var array: CGPDFArrayRef?
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(reopened.documentRef?.catalog), "EmberSparseTest", &array))
            XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(array)), count)
            if count > 0 {
                for index in [0, count - 1] {
                    var value: CGPDFObjectRef?
                    XCTAssertTrue(CGPDFArrayGetObject(try XCTUnwrap(array), index, &value))
                    XCTAssertEqual(CGPDFObjectGetType(try XCTUnwrap(value)), .null)
                }
            }
        }
    }

    func testOptInLargeTaggedBookSavePreservesAllPageContentAndSourceFile() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["EMBER_LARGE_TAGGED_PDF"], path.hasPrefix("/"),
              let output = environment["EMBER_LARGE_TAGGED_SAVE_OUTPUT"], output.hasPrefix("/") else {
            throw XCTSkip("Set explicit read-only tagged source and separate QA output paths.")
        }
        let sourceURL = URL(fileURLWithPath: path), outputURL = URL(fileURLWithPath: output)
        XCTAssertFalse(PDFSourceFileVersion.refersToSameLocation(sourceURL, outputURL))
        let before = try PDFSourceFileVersion.capture(at: sourceURL)
        let document = try XCTUnwrap(PDFDocument(url: sourceURL))
        let retainedPages = try (0..<document.pageCount).map { try XCTUnwrap(document.page(at: $0)) }
        defer { withExtendedLifetime(retainedPages) {} }
        let content = try retainedPages.map { try PDFBodyTextPageSnapshot.contentData(for: $0) }
        try PDFCatalogStructurePreserver.prepare(document, force: true)
        PDFCatalogStructurePreserver.mark(document)
        let started = Date()
        try AtomicPDFWriter.write(document, to: outputURL)
        print("SPARSE_TAG_WRITER_SECONDS", Date().timeIntervalSince(started), "PAGES", document.pageCount)
        let reopened = try XCTUnwrap(PDFDocument(url: outputURL))
        XCTAssertEqual(reopened.pageCount, document.pageCount)
        for index in 0..<reopened.pageCount {
            let page = try XCTUnwrap(reopened.page(at: index))
            XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: page), content[index], "page \(index)")
            XCTAssertEqual(page.bounds(for: .mediaBox), document.page(at: index)?.bounds(for: .mediaBox))
            XCTAssertEqual(page.rotation, document.page(at: index)?.rotation)
        }
        XCTAssertEqual(try PDFSourceFileVersion.capture(at: sourceURL), before)
    }

    private func group(_ document: PDFDocument) throws -> PDFCatalogSourceGroup {
        PDFCatalogSourceGroup(document: try XCTUnwrap(document.documentRef), pages: [
            PDFCatalogPageOrigin(sourceIndex: 0, outputIndex: 0, livePage: try XCTUnwrap(document.page(at: 0)))])
    }

    private func preserved(_ document: PDFDocument) throws -> PDFCatalogGraphPlan {
        var plan = PDFCatalogGraphPlan()
        try PDFTaggedStructurePreserver.addPreservedTags(from: [group(document)], to: &plan)
        return plan
    }

    private func node(_ value: PDFCatalogGraphValue?) throws -> PDFCatalogGraphNode {
        guard case .node(let node)? = value else { throw InvalidValue() }; return node
    }

    private func array(_ value: PDFCatalogGraphValue?) throws -> [PDFCatalogGraphValue] {
        guard case .array(let values)? = value else { throw InvalidValue() }; return values
    }

    private func sparse(_ value: PDFCatalogGraphValue) throws -> (Int, [Int: PDFCatalogGraphValue]) {
        guard case .sparseArray(let count, let members) = value else { throw InvalidValue() }; return (count, members)
    }

    private func parentValue(_ plan: PDFCatalogGraphPlan) throws -> PDFCatalogGraphValue {
        let root = try node(plan.catalogEntries["StructTreeRoot"])
        guard case .dictionary(let tree)? = root.entries["ParentTree"] else { throw InvalidValue() }
        let pairs = try array(tree["Nums"])
        return pairs[1]
    }

    private func nativeParents(_ document: PDFDocument) throws -> CGPDFArrayRef {
        var root: CGPDFDictionaryRef?, tree: CGPDFDictionaryRef?, nums: CGPDFArrayRef?, slots: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(document.documentRef?.catalog), "StructTreeRoot", &root))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(root), "ParentTree", &tree))
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(tree), "Nums", &nums))
        XCTAssertTrue(CGPDFArrayGetArray(try XCTUnwrap(nums), 1, &slots))
        return try XCTUnwrap(slots)
    }

    /// Compare the complete native graph in canonical key order, including
    /// cycles/shared containers and every sparse-array position. PDF object
    /// numbering and dictionary serialization order carry no value semantics.
    private func resolvedGraph(_ document: PDFDocument) throws -> String {
        let native = try XCTUnwrap(document.documentRef)
        var identifiers: [String: Int] = [:], nodes: [String] = []
        func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        func record(_ kind: Int, _ identity: UInt, body: () throws -> String) throws -> String {
            let key = "\(kind):\(identity)"
            if let id = identifiers[key] { return "@\(id)" }
            guard nodes.count < 10_000 else { throw InvalidValue() }
            let id = nodes.count; identifiers[key] = id; nodes.append("")
            let result = try body(); nodes[id] = result
            return "@\(id)"
        }
        func dictionary(_ value: CGPDFDictionaryRef, depth: Int) throws -> String {
            try record(7, pdfReferenceIdentity(value)) {
                guard depth < 64, CGPDFDictionaryGetCount(value) < 4_096 else { throw InvalidValue() }
                var entries: [String: CGPDFObjectRef] = [:]
                CGPDFDictionaryApplyBlock(value, { key, object, _ in
                    entries[String(cString: key)] = object; return true
                }, nil)
                return try "dict{" + entries.keys.sorted().map { key in
                    hex(Data(key.utf8)) + ":" + (try signature(XCTUnwrap(entries[key]), depth: depth + 1))
                }.joined(separator: ",") + "}"
            }
        }
        func array(_ value: CGPDFArrayRef, depth: Int) throws -> String {
            try record(6, pdfReferenceIdentity(value)) {
                let count = CGPDFArrayGetCount(value)
                guard depth < 64, count <= 4_097 else { throw InvalidValue() }
                return try "array[" + (0..<count).map { index in
                    var object: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(value, index, &object) else { throw InvalidValue() }
                    return try signature(XCTUnwrap(object), depth: depth + 1)
                }.joined(separator: ",") + "]"
            }
        }
        func signature(_ object: CGPDFObjectRef, depth: Int) throws -> String {
            guard depth < 64 else { throw InvalidValue() }
            switch CGPDFObjectGetType(object) {
            case .null: return "null"
            case .boolean:
                var value: CGPDFBoolean = 0
                guard CGPDFObjectGetValue(object, .boolean, &value) else { throw InvalidValue() }
                return "b\(value)"
            case .integer:
                var value: CGPDFInteger = 0
                guard CGPDFObjectGetValue(object, .integer, &value) else { throw InvalidValue() }
                return "i\(value)"
            case .real:
                var value: CGPDFReal = 0
                guard CGPDFObjectGetValue(object, .real, &value), value.isFinite else { throw InvalidValue() }
                return "r\(value)"
            case .name:
                var value: UnsafePointer<CChar>?
                guard CGPDFObjectGetValue(object, .name, &value) else { throw InvalidValue() }
                return "n" + hex(Data(String(cString: try XCTUnwrap(value)).utf8))
            case .string:
                var value: CGPDFStringRef?
                guard CGPDFObjectGetValue(object, .string, &value) else { throw InvalidValue() }
                let string = try XCTUnwrap(value), count = CGPDFStringGetLength(string)
                guard count <= 1_048_576 else { throw InvalidValue() }
                return "s" + hex(count == 0 ? Data() : Data(bytes: try XCTUnwrap(CGPDFStringGetBytePtr(string)), count: count))
            case .array:
                var value: CGPDFArrayRef?
                guard CGPDFObjectGetValue(object, .array, &value) else { throw InvalidValue() }
                return try array(XCTUnwrap(value), depth: depth)
            case .dictionary:
                var value: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(object, .dictionary, &value) else { throw InvalidValue() }
                return try dictionary(XCTUnwrap(value), depth: depth)
            case .stream:
                var value: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &value) else { throw InvalidValue() }
                let stream = try XCTUnwrap(value)
                return try record(8, pdfReferenceIdentity(stream)) {
                    var format = CGPDFDataFormat.raw
                    let bytes = try XCTUnwrap(CGPDFStreamCopyData(stream, &format)) as Data
                    guard bytes.count <= 1_048_576 else { throw InvalidValue() }
                    return "stream(\(format.rawValue),\(hex(bytes)),"
                        + (try dictionary(XCTUnwrap(CGPDFStreamGetDictionary(stream)), depth: depth + 1)) + ")"
                }
            @unknown default: throw InvalidValue()
            }
        }
        let root = try dictionary(XCTUnwrap(native.catalog), depth: 0)
        let info = try native.info.map { try dictionary($0, depth: 0) } ?? "none"
        let id = try native.fileIdentifier.map { try array($0, depth: 0) } ?? "none"
        return "root=\(root);info=\(info);id=\(id);" + nodes.joined(separator: ";")
    }

    private func fixture(count: Int, mcids: [Int], invalid: String? = nil, invalidIndex: Int = 1_997,
                         missingReverse: Bool = false) throws -> (document: PDFDocument, data: Data) {
        let content = "/P << /MCID \(mcids[0]) >> BDC BT /F1 12 Tf 10 60 Td (First) Tj ET EMC\n"
            + "/P << /MCID \(mcids[1]) >> BDC BT /F1 12 Tf 10 30 Td (Last) Tj ET EMC\n"
        let slots = (0..<count).map { index in
            index == mcids[0] ? "6 0 R" : index == mcids[1] ? "7 0 R"
                : index == invalidIndex ? invalid ?? "null" : "null"
        }.joined(separator: " ")
        let bodies = [
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 4 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /StructParents 0 /Resources << /Font << /F1 9 0 R >> >> /Contents 8 0 R >>",
            "<< /Type /StructTreeRoot /K [6 0 R 7 0 R] /ParentTree 5 0 R >>",
            "<< /Nums [\(missingReverse ? "" : "0 [" + slots + "]")] >>",
            "<< /Type /StructElem /S /P /P 4 0 R /Pg 3 0 R /K \(mcids[0]) >>",
            "<< /Type /StructElem /S /P /P 4 0 R /Pg 3 0 R /K \(mcids[1]) >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, body) in bodies.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(bodies.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return (try XCTUnwrap(PDFDocument(data: data)), data)
    }

    private struct InvalidValue: Error {}
}
