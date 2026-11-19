// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit
import XCTest
import zlib
@testable import HwattakPDF

/// Proposed regressions for the assembly-only native-copy gate. No opt-in skip.
@MainActor
final class PDFIndexedNativeCopyTests: XCTestCase {
    func testExactFactoryNativeCopyIsAdmittedWhileForeignAndLegacyFactoriesAreNot() throws {
        let bytes = try Self.fixture(), source = try Self.open(bytes)
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let page = try XCTUnwrap(source.page(at: 0)), copied = try Self.copy(page)
        XCTAssertEqual(page.pageRef?.dictionary, copied.pageRef?.dictionary)
        XCTAssertTrue(page.pageRef?.document === copied.pageRef?.document)
        XCTAssertTrue(try PDFCatalogStructurePreserver.canReuseIndexedNativeCopy(from: page, to: copied))

        let foreign = try Self.open(bytes), foreignCopy = try Self.copy(XCTUnwrap(foreign.page(at: 0)))
        XCTAssertFalse(try PDFCatalogStructurePreserver.canReuseIndexedNativeCopy(from: page, to: foreignCopy))
        let legacy = try XCTUnwrap(PDFDocument(data: bytes))
        PDFRawStreamProvenance.bindCreated(legacy, data: bytes)
        PDFCatalogStructurePreserver.mark(legacy) // A bare marker grants no factory authority.
        try PDFCatalogStructurePreserver.prepare(legacy, force: true)
        let legacyPage = try XCTUnwrap(legacy.page(at: 0))
        XCTAssertFalse(try PDFCatalogStructurePreserver.canReuseIndexedNativeCopy(from: legacyPage, to: Self.copy(legacyPage)))
    }

    func testBodyReplacementAndDifferentCurrentMetadataOwnerCannotBorrowOriginalPainting() throws {
        let source = try Self.open(Self.fixture()), changed = try Self.open(Self.fixture(changedPainting: true))
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let original = try XCTUnwrap(source.page(at: 0)), replacement = try XCTUnwrap(changed.page(at: 0))
        PDFCatalogStructurePreserver.inheritMetadata(from: original, to: replacement)
        source.removePage(at: 0); source.insert(replacement, at: 0)
        XCTAssertFalse(try PDFCatalogStructurePreserver.canReuseIndexedNativeCopy(from: replacement, to: Self.copy(replacement)))

        // A content-replacement lineage remains ineligible even when its
        // current native dictionary happens to be the exact original one.
        let lineageSource = try Self.open(Self.fixture())
        try PDFCatalogStructurePreserver.prepare(lineageSource, force: true)
        let lineageOriginal = try XCTUnwrap(lineageSource.page(at: 0)), lineageReplacement = try Self.copy(lineageOriginal)
        XCTAssertEqual(lineageOriginal.pageRef?.dictionary, lineageReplacement.pageRef?.dictionary)
        PDFCatalogStructurePreserver.inheritMetadata(from: lineageOriginal, to: lineageReplacement)
        lineageSource.removePage(at: 0); lineageSource.insert(lineageReplacement, at: 0)
        XCTAssertFalse(try PDFCatalogStructurePreserver.canReuseIndexedNativeCopy(from: lineageReplacement, to: Self.copy(lineageReplacement)))

        let fresh = try Self.open(Self.fixture()), other = try Self.open(Self.fixture())
        try PDFCatalogStructurePreserver.prepare(fresh, force: true)
        try PDFCatalogStructurePreserver.prepare(other, force: true)
        let page = try XCTUnwrap(fresh.page(at: 0)), copied = try Self.copy(page)
        XCTAssertTrue(try PDFCatalogStructurePreserver.canReuseIndexedNativeCopy(from: page, to: copied))
        PDFCatalogStructurePreserver.inheritDocumentMetadata(from: other, to: fresh)
        XCTAssertFalse(try PDFCatalogStructurePreserver.canReuseIndexedNativeCopy(from: page, to: copied))
    }

    func testChangedCopyGeometryAndBorrowedOriginalAnnotationAreRefused() throws {
        let source = try Self.open(Self.fixture(annotations: true))
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let page = try XCTUnwrap(source.page(at: 0)), copied = try Self.copy(page)
        XCTAssertTrue(try PDFCatalogStructurePreserver.canReuseIndexedNativeCopy(from: page, to: copied))
        let originalBounds = page.bounds(for: .mediaBox)
        copied.setBounds(CGRect(x: 0, y: 0, width: 65, height: 64), for: .mediaBox)
        XCTAssertFalse(try PDFCatalogStructurePreserver.canReuseIndexedNativeCopy(from: page, to: copied))
        XCTAssertEqual(page.bounds(for: .mediaBox), originalBounds)
        let borrowed = BorrowedIndexedAnnotationPage(source: page)
        XCTAssertEqual(borrowed.pageRef?.dictionary, page.pageRef?.dictionary)
        XCTAssertTrue(borrowed.annotations.first === page.annotations.first)
        XCTAssertFalse(try PDFCatalogStructurePreserver.canReuseIndexedNativeCopy(from: page, to: borrowed))
        XCTAssertTrue(page.annotations.allSatisfy { $0.page === page })
    }

    func testCancellationEscapesEligibilityInsteadOfEnteringSnapshotFallback() throws {
        let source = try Self.open(Self.fixture())
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let page = try XCTUnwrap(source.page(at: 0)), copied = try Self.copy(page)
        let token = PDFSaveCancellation(); token.cancel()
        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(token) {
            try PDFCatalogStructurePreserver.canReuseIndexedNativeCopy(from: page, to: copied)
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(token) {
            try PDFPageOperations.extract(from: source, indexes: [0, 1])
        }) { XCTAssertTrue($0 is CancellationError) }
    }

    func testInsertedIndexedCopyKeepsOriginalAuthorityForASecondImport() throws {
        let source = try Self.open(Self.fixture())
        let first = try PDFPageOperations.extract(from: source, indexes: [0, 1])
        let page = try XCTUnwrap(first.page(at: 0)), copied = try Self.copy(page)
        XCTAssertTrue(try PDFCatalogStructurePreserver.canReuseIndexedNativeCopy(from: page, to: copied))
        let second = try PDFPageOperations.extract(from: first, indexes: [0, 1])
        XCTAssertEqual(second.pageCount, 2)
        XCTAssertEqual(try Self.pixels(XCTUnwrap(source.page(at: 0))), try Self.pixels(XCTUnwrap(second.page(at: 0))))
    }

    func testHighlyCompressedLargeFlateAndPaletteSurviveTwoWorkerSavesWithCurrentAnnotations() async throws {
        // Each encoded stream is small. Never allocate its >64 MiB sample plane.
        let rgb = try Self.zeroFlate(count: 8_192 * 8_193 * 3)
        let gray = try Self.zeroFlate(count: 8_192 * 8_193)
        XCTAssertLessThan(rgb.count + gray.count, 2 * 1_024 * 1_024)
        for interpolation in [nil, false, true] as [Bool?] {
            let bytes = try Self.fixture(annotations: true, nested: true, interpolation: interpolation, largeRGB: rgb, largeGray: gray)
            let source = try Self.open(bytes), page = try XCTUnwrap(source.page(at: 0))
            let sourcePixels = try Self.pixels(page), sourceNote = try Self.note(page)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-IndexedNativeCopy-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            try PDFCatalogStructurePreserver.prepare(source, force: true)
            XCTAssertTrue(try PDFCatalogStructurePreserver.canReuseIndexedNativeCopy(from: page, to: Self.copy(page)))
            let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 1])
            let copiedPage = try XCTUnwrap(extracted.page(at: 0)), copiedNote = try Self.note(copiedPage)
            XCTAssertFalse(copiedNote === sourceNote)
            copiedNote.contents = "Current detached note"
            XCTAssertEqual(sourceNote.contents, "Kept note")
            let firstURL = folder.appendingPathComponent("first.pdf")
            let first = try await Self.save(extracted, to: firstURL)
            try await Task.detached {
                try Self.assertPainting(first, page: 0, interpolation: interpolation, rgb: rgb, gray: gray, expectedPixels: sourcePixels)
            }.value
            let reopened = try PDFSourceFileAccess.loadDocument(at: firstURL).document
            XCTAssertEqual(try Self.note(XCTUnwrap(reopened.page(at: 0))).contents, "Current detached note")
            let anchor = try Self.anchor(), imported = try PDFPageStructurePreserver.prepareImport(from: reopened, indexes: [0, 1])
            let transaction = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: anchor, at: 1)
            try transaction.apply(); try transaction.undo(); XCTAssertEqual(anchor.pageCount, 1); try transaction.redo()
            let mergedNote = try Self.note(XCTUnwrap(anchor.page(at: 1)))
            XCTAssertFalse(mergedNote === reopened.page(at: 0)?.annotations.first { $0.type == "Text" })
            mergedNote.contents = "Second current note"
            let second = try await Self.save(anchor, to: folder.appendingPathComponent("second.pdf"))
            try await Task.detached {
                try Self.assertPainting(second, page: 1, interpolation: interpolation, rgb: rgb, gray: gray, expectedPixels: sourcePixels)
            }.value
            let saved = try XCTUnwrap(PDFDocument(data: second))
            XCTAssertEqual(saved.pageCount, 3)
            XCTAssertEqual(try Self.note(XCTUnwrap(saved.page(at: 1))).contents, "Second current note")
            XCTAssertEqual(try Self.note(XCTUnwrap(reopened.page(at: 0))).contents, "Current detached note")
            XCTAssertEqual(sourceNote.contents, "Kept note")
            XCTAssertEqual(source.pageCount, 2)
            XCTAssertEqual(try Self.pixels(page), sourcePixels)
            for document in [reopened, saved] {
                let offset = document.pageCount == 2 ? 0 : 1
                let link = try XCTUnwrap(document.page(at: offset)?.annotations.first { $0.type == "Link" })
                let destination = link.destination ?? (link.action as? PDFActionGoTo)?.destination
                XCTAssertTrue(destination?.page === document.page(at: offset + 1))
                XCTAssertEqual(destination?.point, CGPoint(x: 12, y: 45))
                XCTAssertEqual(destination?.zoom, 1.25)
            }
        }
    }

    func testReopenedAPTextUsesEncodedAssemblyWithoutMaterializingSourcePopup() async throws {
        let original = try Self.open(Self.fixture(annotations: true, nested: true))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-ReopenedAPText-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try PDFPageOperations.extract(from: original, indexes: [0, 1])
        let firstURL = folder.appendingPathComponent("first.pdf")
        let firstBytes = try await Self.save(first, to: firstURL)
        let source = try PDFSourceFileAccess.loadDocument(at: firstURL).document
        let page = try XCTUnwrap(source.page(at: 0)), note = try Self.note(page)
        let expectedPixels = try Self.pixels(page), originalAnnotations = page.annotations
        XCTAssertEqual(originalAnnotations.count, 2)
        let originalIDs = originalAnnotations.map(ObjectIdentifier.init)
        let dictionary = try XCTUnwrap(page.pageRef?.dictionary)
        var nativeAnnotations: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "Annots", &nativeAnnotations))
        let list = try XCTUnwrap(nativeAnnotations)
        XCTAssertEqual(CGPDFArrayGetCount(list), 2)
        var nativeNote: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 1, &nativeNote))
        let rawNote = try XCTUnwrap(nativeNote), appearance = try Self.dictionary(rawNote, "AP")
        let originalNormal = try Self.stream(appearance, "N")
        // The exact current source AP and page/annotation identity must survive
        // both import and the later independent save, not just the input file.
        func assertSourceUnchanged() throws {
            XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), originalIDs)
            XCTAssertEqual(note.contents, "Kept note")
            XCTAssertEqual(page.pageRef?.dictionary, dictionary)
            let currentDictionary = try XCTUnwrap(page.pageRef?.dictionary)
            var currentAnnotations: CGPDFArrayRef?, currentNote: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFDictionaryGetArray(currentDictionary, "Annots", &currentAnnotations))
            let currentList = try XCTUnwrap(currentAnnotations)
            XCTAssertEqual(CGPDFArrayGetCount(currentList), originalAnnotations.count)
            XCTAssertTrue(CGPDFArrayGetDictionary(currentList, 1, &currentNote))
            let currentAppearance = try Self.dictionary(XCTUnwrap(currentNote), "AP")
            XCTAssertEqual(try Self.stream(currentAppearance, "N"), originalNormal)
        }
        let popup = PDFCatalogStructurePreserver.object(rawNote, "Popup")
        XCTAssertTrue(popup == nil || popup.map(CGPDFObjectGetType) == .null)
        let imported = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0, 1])
        let importedPage = try XCTUnwrap(imported.pages.first), importedNote = try Self.note(importedPage)
        try assertSourceUnchanged()
        XCTAssertEqual(importedPage.annotations.count, originalAnnotations.count)
        XCTAssertTrue(Set(importedPage.annotations.map(ObjectIdentifier.init)).isDisjoint(with: Set(originalIDs)))
        XCTAssertEqual(note.contents, "Kept note")
        XCTAssertEqual(importedNote.contents, "Kept note")
        XCTAssertEqual(try Self.pixels(importedPage), expectedPixels)
        let anchor = try Self.anchor()
        let transaction = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: anchor, at: 1)
        try transaction.apply()
        importedNote.contents = "Current reopened AP note"
        let second = try await Self.save(anchor, to: folder.appendingPathComponent("second.pdf"))
        let reopened = try Self.open(second)
        XCTAssertEqual(try Self.note(XCTUnwrap(reopened.page(at: 1))).contents, "Current reopened AP note")
        XCTAssertEqual(try Self.pixels(XCTUnwrap(reopened.page(at: 1))), expectedPixels)
        try assertSourceUnchanged()
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
    }

    func testEncodedAssemblySnapshotKeepsVisiblePaintingAndCanonicalSnapshotsDeterministic() throws {
        let source = try Self.open(Self.fixture(nested: true)), page = try XCTUnwrap(source.page(at: 0))
        let canonical = try PDFBodyTextPageSnapshot.originalPageData(for: page)
        let editing = try PDFBodyTextPageSnapshot.data(for: page)
        let encoded = try XCTUnwrap(PDFBodyTextPageSnapshot.encodedAssemblyPageData(for: page))
        let assembled = try Self.open(encoded), copied = try XCTUnwrap(assembled.page(at: 0))
        XCTAssertEqual(assembled.pageCount, 1)
        XCTAssertEqual(try Self.pixels(copied), try Self.pixels(page))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.originalPageData(for: page), canonical)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), editing)
    }

    func testEncodedAssemblySnapshotRefusesLegacyFactoryAndForeignBodyLineage() throws {
        let bytes = try Self.fixture(), legacy = try XCTUnwrap(PDFDocument(data: bytes))
        PDFRawStreamProvenance.bindCreated(legacy, data: bytes)
        XCTAssertNil(try PDFBodyTextPageSnapshot.encodedAssemblyPageData(for: XCTUnwrap(legacy.page(at: 0))))
        let source = try Self.open(bytes), changed = try Self.open(Self.fixture(changedPainting: true))
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let original = try XCTUnwrap(source.page(at: 0)), replacement = try XCTUnwrap(changed.page(at: 0))
        // Even a separately factory-bound current page cannot borrow the
        // other document's original painting through metadata inheritance.
        XCTAssertNotNil(PDFRawStreamProvenance.source(for: replacement))
        PDFCatalogStructurePreserver.inheritMetadata(from: original, to: replacement)
        source.removePage(at: 0); source.insert(replacement, at: 0)
        XCTAssertNil(try PDFBodyTextPageSnapshot.encodedAssemblyPageData(for: replacement))
    }

    func testEncodedAssemblySnapshotStillRejectsCatalogResourceBackedges() throws {
        let source = try Self.open(Self.fixture(resourceBackedge: true))
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.encodedAssemblyPageData(for: XCTUnwrap(source.page(at: 0))))
    }

    func testManualLegacyNonIndexedSnapshotKeepsCurrentOutlineGeometryAndAbsentOrNullPopup() async throws {
        for originalNull in [false, true] {
            let original = try Self.open(Self.fixture(annotations: true, indexed: false, popupNull: originalNull))
            try PDFCatalogStructurePreserver.prepare(original, force: true)
            // Establish the same controlled encoded/manual annotation boundary
            // on a non-indexed page; the durable snapshot must not fall back
            // to document.copy and promote the unlisted SDK Popup.
            let assembled = try PDFPageStructurePreserver.manualRecoverySnapshotCopy(from: original)
            PDFCatalogStructurePreserver.forward(from: original, to: assembled, force: true)
            let page = try XCTUnwrap(assembled.page(at: 0)), current = try Self.note(page)
            XCTAssertTrue(try PDFAnnotationRelationshipPreserver.requiresManualCopy(on: page))
            current.contents = "Current non-indexed note"
            page.rotation = 90
            page.setBounds(CGRect(x: 1, y: 2, width: 60, height: 59), for: .cropBox)
            assembled.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Current recovery title"]
            let root = PDFOutline(), inactive = PDFOutline(), active = PDFOutline()
            root.label = "Current root"; inactive.label = "Inactive child"; inactive.isOpen = true
            active.label = "Current destination"
            active.destination = PDFDestination(page: try XCTUnwrap(assembled.page(at: 1)), at: CGPoint(x: 9, y: 14))
            root.insertChild(inactive, at: 0); root.insertChild(active, at: 1); assembled.outlineRoot = root
            let currentIDs = page.annotations.map(ObjectIdentifier.init)
            let snapshot = try PDFRecoverySnapshot(capturing: assembled)
            let copy = try snapshot.takeDocument(), copiedPage = try XCTUnwrap(copy.page(at: 0))
            XCTAssertEqual(copy.pageCount, 2)
            XCTAssertEqual(copiedPage.rotation, 90)
            XCTAssertEqual(copiedPage.bounds(for: .cropBox), page.bounds(for: .cropBox))
            XCTAssertEqual(try Self.note(copiedPage).contents, "Current non-indexed note")
            XCTAssertEqual(copy.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Current recovery title")
            XCTAssertEqual(copy.outlineRoot?.label, "Current root")
            XCTAssertEqual(copy.outlineRoot?.numberOfChildren, 2)
            XCTAssertEqual(copy.outlineRoot?.child(at: 0)?.label, "Inactive child")
            XCTAssertEqual(copy.outlineRoot?.child(at: 0)?.isOpen, true)
            XCTAssertTrue(copy.outlineRoot?.child(at: 1)?.destination?.page === copy.page(at: 1))
            XCTAssertEqual(copy.outlineRoot?.child(at: 1)?.destination?.point, CGPoint(x: 9, y: 14))
            XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), currentIDs)
            XCTAssertTrue(Set(currentIDs).isDisjoint(with: Set(copiedPage.annotations.map(ObjectIdentifier.init))))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-ManualLegacy-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("saved.pdf")
            _ = try await Self.save(copy, to: url)
            let saved = try PDFSourceFileAccess.loadDocument(at: url).document
            XCTAssertEqual(saved.pageCount, 2)
            XCTAssertEqual(try Self.note(XCTUnwrap(saved.page(at: 0))).contents, "Current non-indexed note")
            let savedDictionary = try XCTUnwrap(saved.documentRef?.page(at: 1)?.dictionary)
            let savedAnnotations = try XCTUnwrap(PDFCatalogStructurePreserver.array(savedDictionary, "Annots"))
            XCTAssertEqual(CGPDFArrayGetCount(savedAnnotations), 2)
            var savedNativeNote: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(savedAnnotations, 1, &savedNativeNote))
            let savedPopup = PDFCatalogStructurePreserver.object(try XCTUnwrap(savedNativeNote), "Popup")
            XCTAssertEqual(savedPopup.map(CGPDFObjectGetType), originalNull ? .null : nil)
            XCTAssertEqual(try Self.note(XCTUnwrap(original.page(at: 0))).contents, "Kept note")
            let sourceDictionary = try XCTUnwrap(original.documentRef?.page(at: 1)?.dictionary)
            let originalAnnotations = try XCTUnwrap(PDFCatalogStructurePreserver.array(sourceDictionary, "Annots"))
            var nativeNote: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(originalAnnotations, 1, &nativeNote))
            let rawPopup = PDFCatalogStructurePreserver.object(try XCTUnwrap(nativeNote), "Popup")
            XCTAssertEqual(rawPopup.map(CGPDFObjectGetType), originalNull ? .null : nil)
        }
    }

    func testRecoveryEncodedOriginRejectsForeignCurrentGeometryBodyReplacementAndCancellation() throws {
        let source = try Self.open(Self.fixture()), foreign = try Self.open(Self.fixture())
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let page = try XCTUnwrap(source.page(at: 0)), other = try XCTUnwrap(foreign.page(at: 0))
        let witness = try XCTUnwrap(PDFCatalogStructurePreserver.encodedAssemblyOrigin(for: page))
        XCTAssertTrue(try witness.matches(page, reference: witness.reference, raw: witness.raw))
        XCTAssertFalse(try witness.matches(other, reference: witness.reference, raw: witness.raw))
        page.rotation = 90
        XCTAssertFalse(try witness.matches(page, reference: witness.reference, raw: witness.raw))
        let current = try XCTUnwrap(PDFCatalogStructurePreserver.encodedAssemblyOrigin(for: page))
        XCTAssertTrue(try current.matches(page, reference: current.reference, raw: current.raw))
        let replacement = try Self.copy(page)
        PDFCatalogStructurePreserver.inheritMetadata(from: page, to: replacement)
        source.removePage(at: 0); source.insert(replacement, at: 0)
        XCTAssertNil(try PDFCatalogStructurePreserver.encodedAssemblyOrigin(for: replacement))
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.encodedRecoveryAssemblyPageData(for: replacement))
        let unbound = try XCTUnwrap(PDFDocument(data: Self.fixture()))
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.encodedRecoveryAssemblyPageData(for: XCTUnwrap(unbound.page(at: 0))))
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(cancellation) {
            try PDFBodyTextPageSnapshot.encodedRecoveryAssemblyPageData(for: other)
        }) { XCTAssertTrue($0 is CancellationError) }
    }

    private static func copy(_ page: PDFPage) throws -> PDFPage { try XCTUnwrap(page.copy() as? PDFPage) }
    private static func open(_ bytes: Data) throws -> PDFDocument { try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes)) }
    private static func note(_ page: PDFPage) throws -> PDFAnnotation { try XCTUnwrap(page.annotations.first { $0.type == "Text" }) }
    private static func save(_ document: PDFDocument, to url: URL) async throws -> Data {
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        return try await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            try AtomicPDFWriter.write(snapshot.takeDocument(), to: url)
            return try Data(contentsOf: url)
        }.value
    }
    private static func anchor() throws -> PDFDocument {
        let storage = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: storage))
        var box = CGRect(x: 0, y: 0, width: 64, height: 64)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        return try open(storage as Data)
    }

    // This fixture uses the existing PageStructurePreserver palette, sample,
    // Link/Text geometry and nested Form pattern. Large planes remain unused
    // painting resources: serialization must preserve them without decoding.
    nonisolated private static func fixture(annotations: Bool = false, nested: Bool = false,
        interpolation: Bool? = nil, largeRGB: Data? = nil, largeGray: Data? = nil,
        changedPainting: Bool = false, resourceBackedge: Bool = false,
        indexed: Bool = true, popupNull: Bool = false) throws -> Data {
        func stream(_ dictionary: String, _ bytes: Data) -> Data {
            var data = Data("<< \(dictionary) /Length \(bytes.count) >>\nstream\n".utf8)
            data.append(bytes); data.append(Data("\nendstream".utf8)); return data
        }
        let policy = interpolation.map { "/Interpolate \($0 ? "true" : "false")" } ?? ""
        let painting = Data(("q 54 0 0 54 5 5 cm /Picture Do Q\n" + (changedPainting ? "0 0 1 rg 24 24 12 12 re f\n" : "")).utf8)
        let extra = largeRGB == nil ? "" : "/Backdrop 10 0 R /BackdropAlias 10 0 R"
        let backedge = resourceBackedge ? " /Backedge 1 0 R" : ""
        var objects = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 64 64] /Resources << /XObject << /Picture \(nested ? 8 : 5) 0 R \(extra) >>\(backedge) >> /Contents 9 0 R \(annotations ? "/Annots [6 0 R 7 0 R]" : "") >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 64 64] /Resources << >> >>".utf8),
            stream("/Type /XObject /Subtype /Image /Width 4 /Height 4 /BitsPerComponent 8 /ColorSpace \(indexed ? "[/Indexed /DeviceRGB 3 <000000FF000000FF00FFFFFF>]" : "/DeviceGray") \(policy)", Data([0,3,1,2,3,0,2,1,1,2,0,3,2,1,3,0])),
            Data("<< /Type /Annot /Subtype /Link /Rect [2 2 20 8] /Border [0 0 0] /Contents (Kept link) /Dest [4 0 R /XYZ 12 45 1.25] >>".utf8),
            Data("<< /Type /Annot /Subtype /Text /Rect [2 52 12 62] /Contents (Kept note)\(popupNull ? " /Popup null" : "") >>".utf8),
            stream("/Type /XObject /Subtype /Form /BBox [0 0 64 64] /Resources << /XObject << /Picture 5 0 R >> >>", painting),
            stream("", nested ? Data("q /Picture Do Q\n".utf8) : painting)
        ]
        if let largeRGB, let largeGray {
            let image = "/Type /XObject /Subtype /Image /Width 8192 /Height 8193 /BitsPerComponent 8 /Filter /FlateDecode /DecodeParms << /Predictor 1 >>"
            objects.append(stream(image + " /ColorSpace /DeviceRGB /SMask 11 0 R", largeRGB))
            objects.append(stream(image + " /ColorSpace /DeviceGray", largeGray))
        } else { XCTAssertNil(largeRGB); XCTAssertNil(largeGray) }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n".utf8)); data.append(object); data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)); return data
    }

    nonisolated private static func zeroFlate(count: Int) throws -> Data {
        var state = z_stream()
        guard deflateInit_(&state, Z_BEST_SPEED, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw TestFailure.compression }
        defer { _ = deflateEnd(&state) }
        let input = [UInt8](repeating: 0, count: 65_536)
        var remaining = count, result = Data()
        while remaining > 0 {
            let take = min(remaining, input.count)
            let flush: Int32 = remaining == take ? Z_FINISH : Z_NO_FLUSH
            try input.withUnsafeBytes { bytes in
                state.next_in = UnsafeMutablePointer(mutating: bytes.baseAddress!.assumingMemoryBound(to: Bytef.self)); state.avail_in = uInt(take)
                var status: Int32 = Z_OK
                repeat {
                    var output = [UInt8](repeating: 0, count: 4_096)
                    status = output.withUnsafeMutableBytes { buffer in
                        state.next_out = buffer.baseAddress!.assumingMemoryBound(to: Bytef.self); state.avail_out = uInt(buffer.count)
                        return deflate(&state, flush)
                    }
                    guard status == Z_OK || status == Z_STREAM_END else { throw TestFailure.compression }
                    result.append(contentsOf: output.prefix(output.count - Int(state.avail_out)))
                    guard result.count < 2 * 1_024 * 1_024 else { throw TestFailure.compression }
                } while state.avail_in > 0 || (flush == Z_FINISH && status != Z_STREAM_END)
            }
            remaining -= take
        }
        return result
    }

    nonisolated private static func assertPainting(_ bytes: Data, page index: Int, interpolation: Bool?, rgb: Data, gray: Data, expectedPixels: Data) throws {
        let native = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: bytes as CFData)!)), page = try XCTUnwrap(native.page(at: index + 1))
        let raw = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: bytes))
        try raw.preparePaintingResources(for: [page])
        let resources = try dictionary(XCTUnwrap(page.dictionary), "Resources"), xobjects = try dictionary(resources, "XObject")
        let large = try stream(xobjects, "Backdrop"), alias = try stream(xobjects, "BackdropAlias")
        XCTAssertEqual(large, alias)
        let largeDictionary = try XCTUnwrap(CGPDFStreamGetDictionary(large)), mask = try stream(largeDictionary, "SMask")
        XCTAssertEqual(try raw.payload(for: large), rgb)
        XCTAssertEqual(try raw.payload(for: mask), gray)
        for (index, image) in [large, mask].enumerated() {
            let dictionary = try XCTUnwrap(CGPDFStreamGetDictionary(image))
            var filter: UnsafePointer<CChar>?, predictor: CGPDFInteger = 0
            XCTAssertTrue(CGPDFDictionaryGetName(dictionary, "Filter", &filter)); XCTAssertEqual(filter.map(String.init(cString:)), "FlateDecode")
            XCTAssertTrue(CGPDFDictionaryGetInteger(try Self.dictionary(dictionary, "DecodeParms"), "Predictor", &predictor)); XCTAssertEqual(predictor, 1)
            var color: UnsafePointer<CChar>?, subtype: UnsafePointer<CChar>?, interpolationValue: CGPDFBoolean = 0
            XCTAssertTrue(CGPDFDictionaryGetName(dictionary, "ColorSpace", &color))
            XCTAssertEqual(color.map(String.init(cString:)), index == 0 ? "DeviceRGB" : "DeviceGray")
            XCTAssertTrue(CGPDFDictionaryGetName(dictionary, "Subtype", &subtype)); XCTAssertEqual(subtype.map(String.init(cString:)), "Image")
            XCTAssertFalse(CGPDFDictionaryGetBoolean(dictionary, "Interpolate", &interpolationValue))
            for (key, expected) in [("Width", 8_192), ("Height", 8_193), ("BitsPerComponent", 8)] {
                var value: CGPDFInteger = 0
                XCTAssertTrue(CGPDFDictionaryGetInteger(dictionary, key, &value)); XCTAssertEqual(value, CGPDFInteger(expected))
            }
        }
        let form = try stream(xobjects, "Picture"), formDictionary = try XCTUnwrap(CGPDFStreamGetDictionary(form))
        let palette = try stream(dictionary(dictionary(formDictionary, "Resources"), "XObject"), "Picture")
        let paletteDictionary = try XCTUnwrap(CGPDFStreamGetDictionary(palette))
        var actual: CGPDFBoolean = 0
        XCTAssertEqual(CGPDFDictionaryGetBoolean(paletteDictionary, "Interpolate", &actual), interpolation != nil)
        if let interpolation { XCTAssertEqual(actual != 0, interpolation) }
        XCTAssertEqual(try raw.payload(for: palette), Data([0,3,1,2,3,0,2,1,1,2,0,3,2,1,3,0]))
        var colorSpace: CGPDFArrayRef?, lookup: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(paletteDictionary, "ColorSpace", &colorSpace))
        let paletteSpace = try XCTUnwrap(colorSpace)
        XCTAssertEqual(CGPDFArrayGetCount(paletteSpace), 4)
        var kind: UnsafePointer<CChar>?, base: UnsafePointer<CChar>?, high: CGPDFInteger = 0
        XCTAssertTrue(CGPDFArrayGetName(paletteSpace, 0, &kind)); XCTAssertEqual(kind.map(String.init(cString:)), "Indexed")
        XCTAssertTrue(CGPDFArrayGetName(paletteSpace, 1, &base)); XCTAssertEqual(base.map(String.init(cString:)), "DeviceRGB")
        XCTAssertTrue(CGPDFArrayGetInteger(paletteSpace, 2, &high)); XCTAssertEqual(high, 3)
        XCTAssertTrue(CGPDFArrayGetString(paletteSpace, 3, &lookup))
        let string = try XCTUnwrap(lookup)
        XCTAssertEqual(Data(bytes: try XCTUnwrap(CGPDFStringGetBytePtr(string)), count: CGPDFStringGetLength(string)), Data([0,0,0,255,0,0,0,255,0,255,255,255]))
        XCTAssertEqual(try pixels(page), expectedPixels)
    }
    nonisolated private static func dictionary(_ parent: CGPDFDictionaryRef, _ key: String) throws -> CGPDFDictionaryRef {
        var value: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFDictionaryGetDictionary(parent, key, &value)); return try XCTUnwrap(value)
    }
    nonisolated private static func stream(_ parent: CGPDFDictionaryRef, _ key: String) throws -> CGPDFStreamRef {
        var value: CGPDFStreamRef?; XCTAssertTrue(CGPDFDictionaryGetStream(parent, key, &value)); return try XCTUnwrap(value)
    }
    private static func pixels(_ page: PDFPage) throws -> Data { try pixels(XCTUnwrap(page.pageRef)) }
    nonisolated private static func pixels(_ page: CGPDFPage) throws -> Data {
        var bytes = Data(count: 192 * 192 * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 192, height: 192, bitsPerComponent: 8,
                bytesPerRow: 192 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 192, height: 192))
            context.scaleBy(x: 3, y: 3); context.drawPDFPage(page)
        }
        return bytes
    }
    private enum TestFailure: Error { case compression }
}

/// Adversarial object only: shares native painting but exposes source-owned
/// annotations without mutating/reparenting any actual source annotation.
private final class BorrowedIndexedAnnotationPage: PDFPage {
    private let original: PDFPage
    init(source: PDFPage) { original = source; super.init(); rotation = source.rotation }
    override var pageRef: CGPDFPage? { original.pageRef }
    override var annotations: [PDFAnnotation] { original.annotations }
    override func bounds(for box: PDFDisplayBox) -> CGRect { original.bounds(for: box) }
}
