// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFCatalogAnnotationLineageTests: XCTestCase {
    func testDeletingTaggedLinkDoesNotAttachItsTagOrLayerToTheRemainingNote() throws {
        let source = try fixture()
        let assembled = try PDFPageOperations.extract(from: source, indexes: [0])
        let page = try XCTUnwrap(assembled.page(at: 0))
        let link = try XCTUnwrap(page.annotations.first { $0.type == "Link" })
        page.removeAnnotation(link)
        XCTAssertEqual(page.annotations.map(\.contents), ["Kept note"])
        let plan = try PDFCatalogStructurePreserver.plan(for: assembled)
        XCTAssertNil(plan.annotationEntries[0]?[0]?["OC"])
        let saved = try reopen(assembled)
        try assertAnnotations(saved, taggedLinkIndex: nil, expectedCount: 1)
        try assertRawNames(saved, expected: [Data("source-note".utf8)])
        XCTAssertEqual(saved.page(at: 0)?.annotations.first?.contents, "Kept note")
        XCTAssertEqual(source.page(at: 0)?.annotations.count, 2)
    }

    func testReorderingAndAddingAnnotationsRetainsOnlyTheOriginalLinkLineage() throws {
        let assembled = try PDFPageOperations.extract(from: fixture(), indexes: [0])
        try reorderAndAddNote(on: XCTUnwrap(assembled.page(at: 0)))
        let plan = try PDFCatalogStructurePreserver.plan(for: assembled)
        XCTAssertNil(plan.annotationEntries[0]?[0]?["OC"])
        XCTAssertNotNil(plan.annotationEntries[0]?[1]?["OC"])
        XCTAssertNil(plan.annotationEntries[0]?[2]?["OC"])
        let saved = try reopen(assembled)
        try assertAnnotations(saved, taggedLinkIndex: 1, expectedCount: 3)
        try assertRawNames(saved, expected: [Data("source-note".utf8), Data("source-link".utf8), nil])
    }

    func testPageAndDocumentCopiesPropagateTheCurrentVerifiedAnnotationMapping() throws {
        let assembled = try PDFPageOperations.extract(from: fixture(), indexes: [0])
        try reorderAndAddNote(on: XCTUnwrap(assembled.page(at: 0)))
        let extractedAgain = try PDFPageOperations.extract(from: assembled, indexes: [0])
        let extractedSaved = try reopen(extractedAgain)
        try assertAnnotations(extractedSaved, taggedLinkIndex: 1, expectedCount: 3)
        try assertRawNames(extractedSaved, expected: [Data("source-note".utf8), Data("source-link".utf8), nil])
        let detached = try XCTUnwrap(assembled.copy() as? PDFDocument)
        PDFCatalogStructurePreserver.forward(from: assembled, to: detached)
        let detachedSaved = try reopen(detached)
        try assertAnnotations(detachedSaved, taggedLinkIndex: 1, expectedCount: 3)
        try assertRawNames(detachedSaved, expected: [Data("source-note".utf8), Data("source-link".utf8), nil])
    }

    func testLateCaptureAfterDeletionDoesNotGuessAnOriginalAnnotationByOrdinal() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        page.removeAnnotation(try XCTUnwrap(page.annotations.first { $0.type == "Link" }))
        let assembled = try PDFPageOperations.extract(from: source, indexes: [0])
        let plan = try PDFCatalogStructurePreserver.plan(for: assembled)
        let name = try XCTUnwrap(plan.annotationNames[0]?[0])
        // Deletion before the first capture intentionally prevents original
        // annotation lineage. Preserve the current ID without borrowing the
        // original NM string's encoding or tagged-link authority by ordinal.
        XCTAssertNil(name.originalDecoded)
        XCTAssertEqual(name.current, "source-note")
        if case .string(let bytes)? = name.value { XCTAssertEqual(bytes, utf16("source-note")) }
        else { XCTFail("A current-only name must use its explicit bounded string encoding.") }
        XCTAssertNil(plan.annotationEntries[0]?[0]?["OC"])
        let saved = try reopen(assembled)
        try assertAnnotations(saved, taggedLinkIndex: nil, expectedCount: 1)
        try assertRawNames(saved, expected: [utf16("source-note")])
        XCTAssertEqual(saved.page(at: 0)?.annotations.first?.value(forAnnotationKey: .init(rawValue: "/NM")) as? String, "source-note")
        XCTAssertEqual(source.page(at: 0)?.annotations.count, 1)
        XCTAssertEqual(source.page(at: 0)?.annotations.first?.contents, "Kept note")
    }

    @MainActor
    func testCurrentRenamedClearedAndNewSquareNamesSurviveWorkerAndExtraction() async throws {
        for clear in [false, true] {
            let source = try fixture()
            let assembled = try PDFPageOperations.extract(from: source, indexes: [0])
            let page = try XCTUnwrap(assembled.page(at: 0))
            let note = try XCTUnwrap(page.annotations.first { $0.type == "Square" })
            let edited = "User-e\u{0301}-name"
            if clear { note.removeValue(forAnnotationKey: .init(rawValue: "/NM")) }
            else { XCTAssertTrue(note.setValue(edited, forAnnotationKey: .init(rawValue: "/NM"))) }
            let fresh = PDFAnnotation(bounds: CGRect(x: 12, y: 35, width: 16, height: 18), forType: .square, withProperties: nil)
            fresh.contents = "Distinct new note"
            XCTAssertTrue(fresh.setValue("New-name", forAnnotationKey: .init(rawValue: "/NM")))
            page.addAnnotation(fresh)
            let intended: Data? = clear ? nil : utf16(edited)
            let plan = try PDFCatalogStructurePreserver.plan(for: assembled)
            XCTAssertEqual(plan.annotationNames[0]?.count, 3)
            if clear { XCTAssertTrue(plan.annotationDrops[0]?[1]?.contains("NM") == true) }
            let bytes = try await writtenOnWorker(assembled)
            let saved = try XCTUnwrap(PDFDocument(data: bytes))
            try assertRawNames(saved, expected: [Data("source-link".utf8), intended, utf16("New-name")])
            try assertAnnotations(saved, taggedLinkIndex: 0, expectedCount: 3)
            let extractedAgain = try PDFPageOperations.extract(from: assembled, indexes: [0])
            let extractedBytes = try await writtenOnWorker(extractedAgain)
            let extractedSaved = try XCTUnwrap(PDFDocument(data: extractedBytes))
            try assertRawNames(extractedSaved, expected: [Data("source-link".utf8), intended, utf16("New-name")])
            try assertRawNames(source, expected: [Data("source-link".utf8), Data("source-note".utf8)])
            XCTAssertEqual(source.page(at: 0)?.annotations.count, 2)
            XCTAssertTrue(page.annotations[1] === note)
            XCTAssertTrue(page.annotations[2] === fresh)
        }
    }

    func testFractionalNonzeroOriginOrdinaryNamesUseTheWholeChosenGeometryProgram() throws {
        // A normal SDK-written source, rather than only hand-authored integer
        // rectangles, exercises its real page-copy/serialization boundary.
        let source = try fixture(noteRect: "60.125 60.375 80.625 81.875", tagged: false)
        let sdkBytes = try XCTUnwrap(source.dataRepresentation())
        let normalized = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: sdkBytes))
        let extracted = try PDFPageOperations.extract(from: normalized, indexes: [0])
        let page = try XCTUnwrap(extracted.page(at: 0))
        let square = try XCTUnwrap(page.annotations.first { $0.type == "Square" })
        XCTAssertNotEqual(square.bounds.minX, 0)
        XCTAssertNotEqual(square.bounds.minX.rounded(), square.bounds.minX)
        XCTAssertTrue(square.setValue("fractional-current", forAnnotationKey: .init(rawValue: "/NM")))
        let plan = try PDFCatalogStructurePreserver.plan(for: extracted)
        XCTAssertNotNil(plan.annotationNames[0]?[1])
        let output = try reopen(extracted)
        let names = try rawNames(output)
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(names[1], utf16("fractional-current"))
        XCTAssertEqual(output.page(at: 0)?.annotations[1].bounds, square.bounds)
    }

    func testGenericMissingNameProofRejectsForeignWrongTypedNullAndReorderedNames() throws {
        let source = try fixture()
        let missing = try fixture(linkName: nil, noteName: nil)
        XCTAssertEqual(try genericProofs(source: source, staged: missing).count, 2)
        for token in ["(foreign-note)", "/WrongKind", "null"] {
            let contradicted = try fixture(linkName: nil, noteName: token)
            XCTAssertThrowsError(try genericProofs(source: source, staged: contradicted), token)
        }
        let reordered = try fixture(linkName: nil, noteName: nil, order: [8, 7])
        XCTAssertThrowsError(try genericProofs(source: source, staged: reordered))
        // Exact UTF-8 identity must not equate canonically equivalent strings.
        let page = try XCTUnwrap(source.page(at: 0))
        XCTAssertTrue(page.annotations[1].setValue("e\u{0301}", forAnnotationKey: .init(rawValue: "/NM")))
        XCTAssertThrowsError(try genericProofs(source: source, staged: fixture(linkName: nil, noteName: "<FEFF00E9>")))
    }

    func testGenericMissingNameProofIncludesUnnamedDuplicatesAndHonorsBudgets() throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        let duplicate = PDFAnnotation(bounds: page.annotations[1].bounds, forType: .square, withProperties: nil)
        duplicate.contents = "Kept note"
        page.addAnnotation(duplicate)
        XCTAssertNil(duplicate.value(forAnnotationKey: .init(rawValue: "/NM")))
        XCTAssertThrowsError(try genericProofs(source: source,
            staged: fixture(linkName: nil, noteName: nil, order: [7, 8, 10], duplicateNote: true)))
        let unique = try fixture(), missing = try fixture(linkName: nil, noteName: nil)
        XCTAssertThrowsError(try genericProofs(source: unique, staged: missing, byteBudget: 0))
        XCTAssertThrowsError(try genericProofs(source: unique, staged: missing, numberBudget: 3))
        let stale = try fixture()
        try PDFCatalogStructurePreserver.prepare(stale, force: true)
        let plan = try PDFCatalogStructurePreserver.plan(for: stale)
        let live = try XCTUnwrap(stale.page(at: 0)).annotations
        live[1].bounds.origin.x += 1
        XCTAssertThrowsError(try genericProofs(source: stale, staged: missing, capturedPlan: plan))
    }

    func testUnboundOrdinaryNamesDoNotGainMissingNameRepairAuthority() throws {
        let source = try fixture(bound: false)
        XCTAssertFalse(PDFRawStreamProvenance.hasKnownNativeInput(source))
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let plan = try PDFCatalogStructurePreserver.plan(for: source)
        XCTAssertTrue(plan.annotationNames[0]?.isEmpty ?? true)
        let staged = try fixture(linkName: nil, noteName: nil)
        let dictionary = try XCTUnwrap(staged.documentRef?.page(at: 1)?.dictionary)
        var item: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "Annots")), 1, &item))
        XCTAssertThrowsError(try PDFPageGeometryPreserver.stagedAnnotation(XCTUnwrap(item), matches: XCTUnwrap(source.page(at: 0)).annotations[1]))
        // Exercise the catalog writer integration, not only the internal name
        // factory. A deterministic staged omission cannot mint late authority.
        let stagedBytes = try XCTUnwrap(staged.dataRepresentation())
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.preservingCatalog(in: stagedBytes, from: source, plan: plan))
        try assertRawNames(source, expected: [Data("source-link".utf8), Data("source-note".utf8)])
    }

    private func genericProofs(source: PDFDocument, staged: PDFDocument, byteBudget: Int = 8 * 1024 * 1024,
        numberBudget: Int = 2_000_000, capturedPlan: PDFCatalogGraphPlan? = nil) throws -> [Int: PDFPageGeometryPreserver.MissingNameProof] {
        let plan: PDFCatalogGraphPlan
        if let capturedPlan { plan = capturedPlan }
        else {
            try PDFCatalogStructurePreserver.prepare(source, force: true)
            plan = try PDFCatalogStructurePreserver.plan(for: source)
        }
        let page = try XCTUnwrap(source.page(at: 0))
        let dictionary = try XCTUnwrap(staged.documentRef?.page(at: 1)?.dictionary)
        var bytes = byteBudget, numbers = numberBudget
        return try PDFPageGeometryPreserver.missingNameProofs(
            staged: PDFCatalogStructurePreserver.array(dictionary, "Annots"), live: page.annotations,
            names: plan.annotationNames[0] ?? [:], geometries: plan.annotationGeometry[0] ?? [:],
            remainingBytes: &bytes, remainingNumbers: &numbers)
    }

    @MainActor private func writtenOnWorker(_ document: PDFDocument) async throws -> Data {
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-NM-ordinary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("saved.pdf")
        return try await Task.detached {
            guard !Thread.isMainThread else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            try AtomicPDFWriter.write(snapshot.takeDocument(), to: output)
            return try Data(contentsOf: output)
        }.value
    }

    private func utf16(_ value: String) -> Data {
        var bytes = Data([0xFE, 0xFF]); bytes.append(value.data(using: .utf16BigEndian)!)
        return bytes
    }

    private func assertRawNames(_ document: PDFDocument, expected: [Data?], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try rawNames(document), expected, file: file, line: line)
    }

    private func rawNames(_ document: PDFDocument) throws -> [Data?] {
        let native = try XCTUnwrap(document.documentRef)
        let page = try XCTUnwrap(native.page(at: 1)?.dictionary)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
        guard CGPDFArrayGetCount(list) <= 16 else { throw PDFPageStructurePreserver.Failure.tooComplex }
        return try (0..<CGPDFArrayGetCount(list)).map { index in
            var item: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(list, index, &item))
            guard let object = PDFCatalogStructurePreserver.object(try XCTUnwrap(item), "NM") else { return nil }
            var value: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &value), let value else {
                XCTFail("The saved ordinary annotation name must be absent or a string.")
                throw PDFPageGeometryPreserver.Failure.invalidGeometry
            }
            let count = CGPDFStringGetLength(value)
            guard count <= 65_536 else { throw PDFPageStructurePreserver.Failure.tooComplex }
            if count == 0 { return Data() }
            return Data(bytes: try XCTUnwrap(CGPDFStringGetBytePtr(value)), count: count)
        }
    }

    @MainActor
    func testUneditedFactoryLinkControlsSurviveBodyReplacementAndSelectedWorkerSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-Link-body-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("original.pdf")
        try simpleLinkControlsData().write(to: input)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: input)); workspace.setMode(.editing)
        let source = try XCTUnwrap(workspace.document)
        let original = try XCTUnwrap(source.page(at: 0))
        let originalLink = try XCTUnwrap(original.annotations.first)
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
        let baselineStateCount = try await Task.detached {
            try raw.originalLinkControlStates(onPages: [0, 1])?.values.reduce(0) { $0 + $1.count }
        }.value
        XCTAssertEqual(baselineStateCount, 2, "Both known PDFBorder observations must form complete bounded baselines.")
        let capacityRefused = try await Task.detached {
            try raw.originalLinkControlStates(onPages: [0, 1], maximumStateBytes: 1) == nil
        }.value
        XCTAssertTrue(capacityRefused, "Capacity refusal must not publish a partial baseline or poison a later save.")
        let originalText = try XCTUnwrap(original.string)
        let selection = try XCTUnwrap(original.selection(for: (originalText as NSString).range(of: "Body one")))
        XCTAssertTrue(workspace.requestBodyTextEdit(selection: selection))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.commitPendingInlineText(id: draft.id, text: "Body two", style: draft.style, bounds: draft.bounds)
        XCTAssertNil(workspace.pendingInlineTextEdit); XCTAssertNil(workspace.presentedError)
        let replacement = try XCTUnwrap(source.page(at: 0))
        XCTAssertFalse(replacement === original)
        XCTAssertTrue(replacement.annotations.first === originalLink, "The actual production transaction retains the live annotation identity and destination.")
        let currentDestination = (originalLink.action as? PDFActionGoTo)?.destination ?? originalLink.destination
        XCTAssertTrue(currentDestination?.page === source.page(at: 1))
        let wholeBytes = try await writtenOnWorker(source)
        let whole = try XCTUnwrap(PDFDocument(data: wholeBytes))
        XCTAssertTrue(whole.page(at: 0)?.string?.contains("Body two") == true)
        XCTAssertTrue(whole.page(at: 1)?.string?.contains("Untouched") == true)
        try assertOriginalLinkControls(whole)
        let selected = try PDFPageOperations.extract(from: source, indexes: [0, 1])
        let selectedBytes = try await writtenOnWorker(selected)
        let selectedSaved = try XCTUnwrap(PDFDocument(data: selectedBytes))
        try assertOriginalLinkControls(selectedSaved)
        // Reopening the produced bytes is another fresh factory baseline, not
        // a mutable observation retroactively stamped onto the source.
        let second = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: selectedBytes))
        try PDFCatalogStructurePreserver.prepare(second, force: true)
        PDFCatalogStructurePreserver.mark(second)
        let secondBytes = try await writtenOnWorker(second)
        try assertOriginalLinkControls(try XCTUnwrap(PDFDocument(data: secondBytes)))
    }

    @MainActor
    func testExplicitLinkPrintAndStyleIntentOptsOutBeforeAndAfterOriginCapture() async throws {
        for beforeCapture in [true, false] {
            let source = try simpleLinkControlsFixture()
            let page = try XCTUnwrap(source.page(at: 0)), link = try XCTUnwrap(page.annotations.first)
            let nativeOwner = try XCTUnwrap(source.documentRef)
            let nativeBefore = try nativeLink(source, page: 0)
            if !beforeCapture { try PDFCatalogStructurePreserver.prepare(source, force: true) }
            PDFCatalogStructurePreserver.recordExplicitAnnotationEdit(in: source)
            // Even a same-value public print assignment is explicit intent;
            // PDFKit's normalized getter need not describe raw F absence.
            link.shouldPrint = true
            link.color = .red
            let border = PDFBorder(); border.lineWidth = 2; link.border = border
            try PDFCatalogStructurePreserver.prepare(source, force: true)
            PDFCatalogStructurePreserver.mark(source)
            let copied = try PDFPageOperations.extract(from: source, indexes: [0, 1])
            let savedBytes = try await writtenOnWorker(copied)
            let saved = try XCTUnwrap(PDFDocument(data: savedBytes))
            let native = try nativeLink(saved, page: 0)
            var flags: CGPDFInteger = 0
            XCTAssertTrue(CGPDFDictionaryGetInteger(native, "F", &flags))
            XCTAssertEqual(flags & 4, 4, "A user print intent must not be replaced by original absent F.")
            let current = try XCTUnwrap(saved.page(at: 0)?.annotations.first)
            XCTAssertTrue(current.shouldPrint)
            XCTAssertEqual(current.border?.lineWidth, 2)
            let color = try XCTUnwrap(current.color.usingColorSpace(.extendedSRGB))
            XCTAssertEqual(color.redComponent, 1, accuracy: 0.000001)
            XCTAssertEqual(color.greenComponent, 0, accuracy: 0.000001)
            // The original native source's F remains absent throughout.
            withExtendedLifetime(nativeOwner) { XCTAssertNil(PDFCatalogStructurePreserver.object(nativeBefore, "F")) }
        }
    }

    @MainActor
    func testUnchangedLinkBaselineNeverAuthorizesAnExplicitAPOrUnknownNativeKey() async throws {
        for extra in ["/AP << /N 8 0 R >>", "/UnrecognizedLinkControl true", "/F [4]", "/DA 999 0 R"] {
            let source = try simpleLinkControlsFixture(extra: extra)
            try PDFCatalogStructurePreserver.prepare(source, force: true)
            PDFCatalogStructurePreserver.mark(source)
            let box = LinkControlsTransfer(source)
            let refused = try await Task.detached {
                let plan = try PDFCatalogStructurePreserver.plan(for: box.document)
                return plan.annotationDrops[0]?[0]?.contains("F") != true
                    && plan.annotationEntries[0]?[0]?["AP"] == nil
            }.value
            XCTAssertTrue(refused, "This lane cannot restore AP programs or admit unknown source keys.")
        }
    }

    private final class LinkControlsTransfer: @unchecked Sendable {
        let document: PDFDocument
        init(_ document: PDFDocument) { self.document = document }
    }

    private func nativeLink(_ document: PDFDocument, page index: Int) throws -> CGPDFDictionaryRef {
        let page = try XCTUnwrap(document.documentRef?.page(at: index + 1)?.dictionary)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
        XCTAssertEqual(CGPDFArrayGetCount(list), 1)
        var annotation: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &annotation))
        return try XCTUnwrap(annotation)
    }

    private func assertOriginalLinkControls(_ document: PDFDocument) throws {
        XCTAssertEqual(document.pageCount, 2)
        let absent = try nativeLink(document, page: 0), explicit = try nativeLink(document, page: 1)
        for key in ["F", "AP", "DA", "BS"] { XCTAssertNil(PDFCatalogStructurePreserver.object(absent, key), key) }
        var flags: CGPDFInteger = -1
        XCTAssertTrue(CGPDFDictionaryGetInteger(explicit, "F", &flags)); XCTAssertEqual(flags, 0)
        XCTAssertEqual(PDFCatalogStructurePreserver.object(explicit, "AP").map(CGPDFObjectGetType), .null)
        XCTAssertEqual(PDFCatalogStructurePreserver.object(explicit, "DA").map(CGPDFObjectGetType), .string)
        let style = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(explicit, "BS"))
        var width: CGPDFReal = -1
        XCTAssertTrue(CGPDFDictionaryGetNumber(style, "W", &width)); XCTAssertEqual(width, 0)
    }

    private func simpleLinkControlsFixture(extra: String = "") throws -> PDFDocument {
        try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: simpleLinkControlsData(extra: extra)))
    }

    private func simpleLinkControlsData(extra: String = "") -> Data {
        let first = "BT /F1 12 Tf 20 140 Td (Body one) Tj ET\n"
        let second = "BT /F1 12 Tf 20 140 Td (Untouched) Tj ET\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 2 /Kids [3 0 R 4 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 9 0 R >> >> /Contents 10 0 R /Annots [5 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 9 0 R >> >> /Contents 11 0 R /Annots [6 0 R] >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 10 70 25] /Border [0 0 0] /NM (first-link) /Dest [4 0 R /Fit] \(extra) >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 10 70 25] /Border [0 0 0] /NM (second-link) /Dest [4 0 R /Fit] /F 0 /AP null /DA (/Helvetica 9 Tf 0 g) /BS << /W 0 /S /S >> >>",
            "null",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << >> /Length 0 >>\nstream\n\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(first.utf8.count) >>\nstream\n\(first)endstream",
            "<< /Length \(second.utf8.count) >>\nstream\n\(second)endstream"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    private func reorderAndAddNote(on page: PDFPage) throws {
        let link = try XCTUnwrap(page.annotations.first { $0.type == "Link" })
        page.removeAnnotation(link); page.addAnnotation(link)
        let fresh = PDFAnnotation(bounds: CGRect(x: 10, y: 65, width: 18, height: 18), forType: .square, withProperties: nil)
        fresh.contents = "New note"
        page.addAnnotation(fresh)
        XCTAssertEqual(page.annotations.map(\.type), ["Square", "Link", "Square"])
    }

    private func reopen(_ document: PDFDocument) throws -> PDFDocument {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-annotation-lineage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("result.pdf")
        try AtomicPDFWriter.write(document, to: url)
        return try XCTUnwrap(PDFDocument(data: Data(contentsOf: url)))
    }

    private func assertAnnotations(_ document: PDFDocument, taggedLinkIndex: Int?, expectedCount: Int) throws {
        let native = try XCTUnwrap(document.documentRef), catalog = try XCTUnwrap(native.catalog)
        let page = try XCTUnwrap(native.page(at: 1)?.dictionary)
        var list: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(page, "Annots", &list))
        let annotations = try XCTUnwrap(list)
        XCTAssertEqual(CGPDFArrayGetCount(annotations), expectedCount)
        var dictionaries: [CGPDFDictionaryRef] = []
        for index in 0..<CGPDFArrayGetCount(annotations) {
            var annotation: CGPDFDictionaryRef?, parent: CGPDFObjectRef?, layer: CGPDFObjectRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(annotations, index, &annotation))
            let dictionary = try XCTUnwrap(annotation); dictionaries.append(dictionary)
            let hasParent = CGPDFDictionaryGetObject(dictionary, "StructParent", &parent)
            let hasLayer = CGPDFDictionaryGetObject(dictionary, "OC", &layer)
            XCTAssertEqual(hasParent, index == taggedLinkIndex)
            XCTAssertEqual(hasLayer, index == taggedLinkIndex)
        }
        var structure: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "StructTreeRoot", &structure))
        let root = try XCTUnwrap(structure)
        var children: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(root, "K", &children))
        let kids = try XCTUnwrap(children)
        XCTAssertEqual(CGPDFArrayGetCount(kids), taggedLinkIndex == nil ? 0 : 1)
        if let taggedLinkIndex {
            var element: CGPDFDictionaryRef?, childArray: CGPDFArrayRef?, objr: CGPDFDictionaryRef?, target: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(kids, 0, &element))
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(element), "K", &childArray))
            XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(childArray), 0, &objr))
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(objr), "Obj", &target))
            XCTAssertEqual(pdfReferenceIdentity(try XCTUnwrap(target)), pdfReferenceIdentity(dictionaries[taggedLinkIndex]))
        } else {
            var parents: CGPDFObjectRef?
            XCTAssertFalse(CGPDFDictionaryGetObject(root, "ParentTree", &parents))
        }
    }

    private func fixture(linkName: String? = "(source-link)", noteName: String? = "(source-note)",
                         order: [Int] = [7, 8], duplicateNote: Bool = false,
                         bound: Bool = true, noteRect: String = "60 60 80 80", tagged: Bool = true) throws -> PDFDocument {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 4 0 R /MarkInfo << /Marked true >> /OCProperties << /OCGs [9 0 R] /D << /BaseState /ON >> >> >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Annots [\(order.map { "\($0) 0 R" }.joined(separator: " "))] >>",
            "<< /Type /StructTreeRoot /K [5 0 R] /ParentTree 6 0 R /ParentTreeNextKey 1 >>",
            "<< /Type /StructElem /S /Link /P 4 0 R /Pg 3 0 R /K << /Type /OBJR /Pg 3 0 R /Obj 7 0 R >> >>",
            "<< /Nums [0 5 0 R] >>",
            "<< /Type /Annot /Subtype /Link /Rect [5 5 40 20] \(linkName.map { "/NM " + $0 } ?? "") /Dest [3 0 R /Fit] /StructParent 0 /OC 9 0 R >>",
            "<< /Type /Annot /Subtype /Square /Rect [\(noteRect)] \(noteName.map { "/NM " + $0 } ?? "") /Contents (Kept note) /C [1 0 0] >>",
            "<< /Type /OCG /Name (Link layer) >>"
        ]
        if !tagged {
            objects[0] = "<< /Type /Catalog /Pages 2 0 R >>"
            objects[6] = objects[6].replacingOccurrences(of: " /StructParent 0 /OC 9 0 R", with: "")
        }
        if duplicateNote { objects.append("<< /Type /Annot /Subtype /Square /Rect [\(noteRect)] /Contents (Kept note) /C [1 0 0] >>") }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let document = try XCTUnwrap(bound ? PDFRawStreamProvenance.createdDocument(data: data) : PDFDocument(data: data))
        XCTAssertEqual(PDFRawStreamProvenance.hasKnownNativeInput(document), bound)
        return document
    }
}
