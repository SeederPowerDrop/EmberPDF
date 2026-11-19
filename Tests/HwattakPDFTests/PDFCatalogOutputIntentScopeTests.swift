// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFCatalogOutputIntentScopeTests: XCTestCase {
    func testSingleSourceExtractionKeepsItsActiveOutputIntentAndProfileBytes() throws {
        let profile = try profile(CGColorSpace.sRGB)
        let source = try fixture(profile: profile)
        let selected = try PDFPageOperations.extract(from: source, indexes: [1])
        let native = try saved(selected)
        XCTAssertEqual(try activeProfile(native), profile)
        XCTAssertTrue(try archive(native).isEmpty)
    }

    func testMixedProfilesAreInactiveAndScopedWithoutApplyingThemToUnprofiledPages() throws {
        let first = try profile(CGColorSpace.sRGB), second = try profile(CGColorSpace.displayP3)
        let mixed = try assembly(first: first, second: second)
        let native = try saved(mixed)
        XCTAssertNil(try activeProfile(native))
        let scopes = try archive(native)
        XCTAssertEqual(scopes.map(\.pages), [[0, 1], [2, 3]])
        XCTAssertEqual(scopes.map(\.profile), [first, second])
        XCTAssertEqual(native.numberOfPages, 6)
    }

    func testArchivedProfilesSurviveSaveReopenExtractionAndAnotherMergeWithoutReactivation() throws {
        let first = try profile(CGColorSpace.sRGB), second = try profile(CGColorSpace.displayP3)
        let mixed = try assembly(first: first, second: second)
        let reloaded = try reopened(mixed)
        XCTAssertTrue(PDFCatalogStructurePreserver.shouldPreserve(reloaded))
        let selected = try PDFPageOperations.extract(from: reloaded, indexes: [1, 2, 4])
        let selectedNative = try saved(selected)
        XCTAssertNil(try activeProfile(selectedNative))
        XCTAssertEqual(try archive(selectedNative).map(\.pages), [[0], [1]])
        XCTAssertEqual(try archive(selectedNative).map(\.profile), [first, second])
        let anchor = try fixture()
        try PDFPageOperations.append(contentsOf: try reopened(selected), to: anchor)
        let mergedNative = try saved(anchor)
        XCTAssertNil(try activeProfile(mergedNative))
        XCTAssertEqual(try archive(mergedNative).map(\.pages), [[2], [3]])
        XCTAssertEqual(try archive(mergedNative).map(\.profile), [first, second])
        try PDFPageOperations.append(contentsOf: try reopened(selected), to: anchor)
        let repeatedNative = try saved(anchor)
        XCTAssertNil(try activeProfile(repeatedNative))
        XCTAssertEqual(try archive(repeatedNative).map(\.pages), [[2], [3], [5], [6]])
        XCTAssertEqual(try archive(repeatedNative).map(\.profile), [first, second, first, second])
        // Selecting only an archived source still must not turn historical
        // printing provenance back into an active rendering condition.
        let isolated = try PDFPageOperations.extract(from: reloaded, indexes: [0])
        let isolatedNative = try saved(isolated)
        XCTAssertNil(try activeProfile(isolatedNative))
        XCTAssertEqual(try archive(isolatedNative).map(\.pages), [[0]])
        XCTAssertEqual(try archive(isolatedNative).map(\.profile), [first])
        let unprofiled = try PDFPageOperations.extract(from: reloaded, indexes: [4])
        let unprofiledNative = try saved(unprofiled)
        XCTAssertNil(try activeProfile(unprofiledNative))
        XCTAssertTrue(try archive(unprofiledNative).isEmpty)
        XCTAssertNil(PDFCatalogStructurePreserver.object(try XCTUnwrap(unprofiledNative.catalog), "EmberPDFSourceOutputIntents"))
    }

    func testAnUnmatchedCurrentPagePreventsGlobalProfileLeakage() throws {
        let profile = try profile(CGColorSpace.sRGB)
        let selected = try PDFPageOperations.extract(from: fixture(profile: profile), indexes: [0])
        let unprofiled = try fixture()
        selected.insert(try XCTUnwrap(unprofiled.page(at: 0)?.copy() as? PDFPage), at: 0)
        let native = try saved(selected)
        XCTAssertNil(try activeProfile(native))
        XCTAssertEqual(try archive(native).map(\.pages), [[1]])
        XCTAssertEqual(try archive(native).map(\.profile), [profile])
    }

    func testOnlyFactoryBoundBlankPagesPermitTheOneActiveProfileOnWorkerSave() async throws {
        let profile = try profile(CGColorSpace.sRGB)
        let blankBytes = fixtureData(contents: Data("q Q".utf8))
        for bound in [false, true] {
            let output = try document(blankBytes, bound: bound)
            XCTAssertEqual(PDFRawStreamProvenance.source(for: output) != nil, bound)
            try PDFPageOperations.append(contentsOf: fixture(profile: profile), to: output)
            let native = try await backgroundSaved(output)
            if bound {
                XCTAssertEqual(try activeProfile(native), profile)
                XCTAssertTrue(try archive(native).isEmpty)
            } else {
                XCTAssertNil(try activeProfile(native))
                XCTAssertEqual(try archive(native).map(\.pages), [[2, 3]])
                XCTAssertEqual(try archive(native).map(\.profile), [profile])
            }
            XCTAssertEqual(native.numberOfPages, 4)
            XCTAssertEqual(output.pageCount, 4)
        }
    }

    func testFactoryBoundPaintedPagesNeverAcquireAnotherSourcesActiveProfile() async throws {
        let profile = try profile(CGColorSpace.sRGB)
        let output = try fixture(contents: Data("q 0 0 10 10 re f Q".utf8), bound: true)
        try PDFPageOperations.append(contentsOf: fixture(profile: profile), to: output)
        let native = try await backgroundSaved(output)
        XCTAssertNil(try activeProfile(native))
        XCTAssertEqual(try archive(native).map(\.pages), [[2, 3]])
        XCTAssertEqual(try archive(native).map(\.profile), [profile])
    }

    func testCurrentAnnotationPreventsOriginalBlankProofFromExtendingAnActiveProfile() async throws {
        let profile = try profile(CGColorSpace.sRGB)
        let output = try fixture(contents: Data("q Q".utf8), bound: true)
        let page = try XCTUnwrap(output.page(at: 0))
        let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
                                       forType: .text, withProperties: nil)
        annotation.contents = "Current note"
        page.addAnnotation(annotation)
        // PDFKit adds a linked Popup with a Text note on this runtime. Capture
        // the actual pre-save graph instead of assuming it added one object.
        let before = page.annotations
        let beforeIDs = before.map(ObjectIdentifier.init), beforeTypes = before.map(\.type)
        let popup = annotation.popup
        XCTAssertTrue(before.contains { $0 === annotation })
        if let popup {
            XCTAssertTrue(before.contains { $0 === popup })
            XCTAssertEqual(popup.type, "Popup")
            XCTAssertNotNil(annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Popup")))
            XCTAssertNotNil(popup.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")))
        }
        try PDFPageOperations.append(contentsOf: fixture(profile: profile), to: output)
        let native = try await backgroundSaved(output)
        XCTAssertNil(try activeProfile(native))
        XCTAssertEqual(try archive(native).map(\.pages), [[2, 3]])
        XCTAssertEqual(try archive(native).map(\.profile), [profile])
        XCTAssertEqual(output.page(at: 0)?.annotations.first?.contents, "Current note")
        XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), beforeIDs)
        XCTAssertEqual(page.annotations.map(\.type), beforeTypes)
        let savedAnnotations = try XCTUnwrap(PDFCatalogStructurePreserver.array(
            XCTUnwrap(native.page(at: 1)?.dictionary), "Annots"))
        XCTAssertEqual(CGPDFArrayGetCount(savedAnnotations), before.count)
        let noteIndex = try XCTUnwrap(before.firstIndex { $0 === annotation })
        var savedNote: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(savedAnnotations, noteIndex, &savedNote))
        let note = try XCTUnwrap(savedNote)
        var noteType: UnsafePointer<CChar>?, noteContents: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetName(note, "Subtype", &noteType))
        XCTAssertEqual(String(cString: try XCTUnwrap(noteType)), "Text")
        XCTAssertTrue(CGPDFDictionaryGetString(note, "Contents", &noteContents))
        XCTAssertEqual(CGPDFStringCopyTextString(try XCTUnwrap(noteContents)) as String?, "Current note")
        if let popup {
            XCTAssertTrue(annotation.popup === popup)
            XCTAssertNotNil(annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Popup")))
            XCTAssertNotNil(popup.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")))
            let popupIndex = try XCTUnwrap(before.firstIndex { $0 === popup })
            var savedPopup: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(savedAnnotations, popupIndex, &savedPopup))
            let popup = try XCTUnwrap(savedPopup)
            var popupType: UnsafePointer<CChar>?
            XCTAssertTrue(CGPDFDictionaryGetName(popup, "Subtype", &popupType))
            XCTAssertEqual(String(cString: try XCTUnwrap(popupType)), "Popup")
            let forward = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(note, "Popup"))
            let back = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(popup, "Parent"))
            XCTAssertEqual(pdfReferenceIdentity(forward), pdfReferenceIdentity(popup))
            XCTAssertEqual(pdfReferenceIdentity(back), pdfReferenceIdentity(note))
        } else { XCTAssertNil(annotation.popup) }
    }

    func testCurrentContentReplacementPreventsOriginalBlankProofFromExtendingAnActiveProfile() async throws {
        let profile = try profile(CGColorSpace.sRGB)
        let output = try fixture(contents: Data("q Q".utf8), bound: true)
        try PDFCatalogStructurePreserver.prepare(output, force: true)
        let original = try XCTUnwrap(output.page(at: 0))
        let replacementSource = try fixture(contents: Data("q 0 0 10 10 re f Q".utf8))
        let replacement = try XCTUnwrap(replacementSource.page(at: 0)?.copy() as? PDFPage)
        PDFCatalogStructurePreserver.inheritMetadata(from: original, to: replacement)
        output.removePage(at: 0)
        output.insert(replacement, at: 0)
        try PDFPageOperations.append(contentsOf: fixture(profile: profile), to: output)
        let native = try await backgroundSaved(output)
        XCTAssertNil(try activeProfile(native))
        XCTAssertEqual(try archive(native).map(\.pages), [[2, 3]])
        XCTAssertEqual(try archive(native).map(\.profile), [profile])
        XCTAssertTrue(output.page(at: 0) === replacement)
    }

    func testNoActiveEmptyAndConflictingIntentPlansDoNotReadOrPoisonTheColdBlankSource() async throws {
        let first = try profile(CGColorSpace.sRGB), second = try profile(CGColorSpace.displayP3)
        for condition in 0..<3 {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("OutputIntentCold-\(UUID()).pdf")
            let backup = FileManager.default.temporaryDirectory.appendingPathComponent("OutputIntentCold-\(UUID()).pdf")
            defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: backup) }
            let blankBytes = fixtureData(contents: Data("q Q".utf8))
            try blankBytes.write(to: url)
            let loaded = try PDFSourceFileAccess.loadDocument(at: url)
            let probe = OriginalBlankProbe(native: try XCTUnwrap(loaded.document.documentRef),
                                           source: try XCTUnwrap(PDFRawStreamProvenance.source(for: loaded.document)))
            let output = PDFDocument()
            try PDFPageOperations.append(contentsOf: loaded.document, to: output)
            if condition == 1 {
                try PDFPageOperations.append(contentsOf: fixture(emptyIntents: true), to: output)
            } else if condition == 2 {
                try PDFPageOperations.append(contentsOf: fixture(profile: first), to: output)
                try PDFPageOperations.append(contentsOf: fixture(profile: second), to: output)
            }
            let snapshot = try PDFRecoverySnapshot(capturing: output)
            try FileManager.default.moveItem(at: url, to: backup)
            try fixtureData(contents: Data("q 0 0 10 10 re f Q".utf8)).write(to: url)
            let hasActive = try await Task.detached {
                let copy = try snapshot.takeDocument()
                return try PDFCatalogStructurePreserver.plan(for: copy).catalogEntries["OutputIntents"] != nil
            }.value
            XCTAssertFalse(hasActive, "condition \(condition)")
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: backup, to: url)
            XCTAssertEqual(try PDFSourceFileVersion.capture(at: url), loaded.version)
            // A blank-proof read during the plan would permanently quarantine
            // this unavailable original. A later successful proof distinguishes
            // zero lazy reads from an unsuccessful read followed by a fallback.
            let stillUsable = try await Task.detached { try probe.provesBlank() }.value
            XCTAssertTrue(stillUsable, "condition \(condition) must not initialize the cold source")
            XCTAssertEqual(try Data(contentsOf: url), blankBytes)
        }
    }

    func testMainBlankProofMissKeepsConservativeScopeAndWorkerSaveCanRetry() async throws {
        let profile = try profile(CGColorSpace.sRGB)
        let output = try fixture(contents: Data("q Q".utf8), bound: true)
        try PDFPageOperations.append(contentsOf: fixture(profile: profile), to: output)
        let onMain = try saved(output)
        XCTAssertNil(try activeProfile(onMain))
        XCTAssertEqual(try archive(onMain).map(\.pages), [[2, 3]])
        let onWorker = try await backgroundSaved(output)
        XCTAssertEqual(try activeProfile(onWorker), profile)
        XCTAssertTrue(try archive(onWorker).isEmpty)
    }

    func testFactoryBoundBlankPagesNeverReactivateOnlyHistoricalProfiles() async throws {
        let first = try profile(CGColorSpace.sRGB), second = try profile(CGColorSpace.displayP3)
        let historicalBytes = try serialized(assembly(first: first, second: second))
        let historical = try document(historicalBytes, bound: true)
        let output = try fixture(contents: Data("q Q".utf8), bound: true)
        try PDFPageOperations.append(contentsOf: historical, to: output)
        let native = try await backgroundSaved(output)
        XCTAssertNil(try activeProfile(native))
        XCTAssertEqual(try archive(native).map(\.pages), [[2, 3], [4, 5]])
        XCTAssertEqual(try archive(native).map(\.profile), [first, second])
        XCTAssertEqual(native.numberOfPages, 8)
    }

    /// Only immutable CG ownership and its serialized raw-source lock cross
    /// into this probe; the live PDFDocument remains on the main actor.
    private final class OriginalBlankProbe: @unchecked Sendable {
        let native: CGPDFDocument
        let source: PDFRawStreamSource
        init(native: CGPDFDocument, source: PDFRawStreamSource) {
            self.native = native; self.source = source
        }
        func provesBlank() throws -> Bool {
            var remaining = 4_096
            return try source.provesEmptyPageContents(for: XCTUnwrap(native.page(at: 1)),
                                                       remainingEncodedBytes: &remaining)
        }
    }

    private func backgroundSaved(_ document: PDFDocument) async throws -> CGPDFDocument {
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let data = try await Task.detached { try snapshot.serializedData() }.value
        return try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
    }

    private func profile(_ name: CFString) throws -> Data {
        try XCTUnwrap(try XCTUnwrap(CGColorSpace(name: name)).copyICCData()) as Data
    }
    private func assembly(first: Data, second: Data) throws -> PDFDocument {
        let output = PDFDocument()
        for source in [try fixture(profile: first), try fixture(profile: second), try fixture()] {
            try PDFPageOperations.append(contentsOf: source, to: output)
        }
        return output
    }
    private func saved(_ document: PDFDocument) throws -> CGPDFDocument {
        let data = try serialized(document)
        return try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
    }
    private func reopened(_ document: PDFDocument) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: serialized(document)))
    }
    private func serialized(_ document: PDFDocument) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OutputIntentScope-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try AtomicPDFWriter.write(document, to: url)
        return try Data(contentsOf: url)
    }
    private func activeProfile(_ document: CGPDFDocument) throws -> Data? {
        let catalog = try XCTUnwrap(document.catalog)
        guard let intents = PDFCatalogStructurePreserver.array(catalog, "OutputIntents") else { return nil }
        return try bytes(intents)
    }
    private func bytes(_ intents: CGPDFArrayRef) throws -> Data {
        XCTAssertEqual(CGPDFArrayGetCount(intents), 1)
        var intent: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(intents, 0, &intent))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(intent), "DestOutputProfile", &stream))
        var format = CGPDFDataFormat.raw
        return try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(stream), &format)) as Data
    }
    private struct Scope { let pages: [Int]; let profile: Data }
    private func archive(_ document: CGPDFDocument) throws -> [Scope] {
        let catalog = try XCTUnwrap(document.catalog)
        guard let archive = PDFCatalogStructurePreserver.array(catalog, "EmberPDFSourceOutputIntents") else { return [] }
        let pages = try (1...document.numberOfPages).map { try XCTUnwrap(document.page(at: $0)?.dictionary) }
        return try (0..<CGPDFArrayGetCount(archive)).map { index in
            var record: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(archive, index, &record))
            let dictionary = try XCTUnwrap(record)
            let scope = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "Pages"))
            let indexes = try (0..<CGPDFArrayGetCount(scope)).map { slot in
                var page: CGPDFDictionaryRef?
                XCTAssertTrue(CGPDFArrayGetDictionary(scope, slot, &page))
                let native = try XCTUnwrap(page)
                return try XCTUnwrap(pages.firstIndex { pdfReferenceIdentity($0) == pdfReferenceIdentity(native) })
            }
            return Scope(pages: indexes, profile: try bytes(XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "OutputIntents"))))
        }
    }
    private func fixture(profile: Data? = nil, contents: Data = Data(), bound: Bool = false,
                         emptyIntents: Bool = false) throws -> PDFDocument {
        try document(fixtureData(profile: profile, contents: contents, emptyIntents: emptyIntents), bound: bound)
    }
    private func document(_ data: Data, bound: Bool) throws -> PDFDocument {
        let document = try XCTUnwrap(PDFDocument(data: data))
        if bound { PDFRawStreamProvenance.bindCreated(document, data: data) }
        return document
    }
    private func fixtureData(profile: Data? = nil, contents: Data = Data(), emptyIntents: Bool = false) -> Data {
        let intent = emptyIntents ? "/OutputIntents []" : (profile == nil ? "" : "/OutputIntents [<< /Type /OutputIntent /S /GTS_PDFX /OutputConditionIdentifier (fixture) /DestOutputProfile 6 0 R >>]")
        var objects = [
            Data("<< /Type /Catalog /Pages 2 0 R \(intent) >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Contents 5 0 R >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Contents 5 0 R >>".utf8),
            Data("<< /Length \(contents.count) >>\nstream\n".utf8) + contents + Data("\nendstream".utf8)
        ]
        if let profile {
            objects.append(Data("<< /N 3 /Length \(profile.count) >>\nstream\n".utf8) + profile + Data("\nendstream".utf8))
        }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, value) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n".utf8)); data.append(value); data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
}
