// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

/// WORK proposal. Compile and execution are pending the Root native lease.
@MainActor
final class PDFEmptyAcroFormPreservationTests: XCTestCase {
    func testOrdinaryMissingCarrierRestoresOriginallyEmptyDefaultsAndResources() async throws {
        let data = try await Task.detached { () throws -> Data in
            let source = try Self.open(Self.fixture())
            let plan = try PDFCatalogStructurePreserver.plan(for: source)
            XCTAssertNotNil(plan.emptyFormSource)
            return try PDFBodyTextPageSnapshot.preservingCatalog(in: Self.fixture(form: nil), from: source, plan: plan)
        }.value
        try Self.assertOriginalEmptyForm(data)
    }

    func testEmptyCalculationOrderIsPreservedByExistingExactEmptyFormAuthority() async throws {
        try await Task.detached {
            let source = try Self.open(Self.fixture(form: "<< /Fields [] /CO [] /DA (/Helv 0 Tf 0 g ) >>"))
            let plan = try PDFCatalogStructurePreserver.plan(for: source)
            XCTAssertNotNil(plan.emptyFormSource)
            let data = try PDFBodyTextPageSnapshot.preservingCatalog(in: Self.fixture(form: nil), from: source, plan: plan)
            let owner = try Self.native(data)
            try withExtendedLifetime(owner) {
                let catalog = try XCTUnwrap(owner.catalog)
                let form = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(catalog, "AcroForm"))
                let fields = try XCTUnwrap(PDFCatalogStructurePreserver.array(form, "Fields"))
                let order = try XCTUnwrap(PDFCatalogStructurePreserver.array(form, "CO"))
                XCTAssertEqual(CGPDFArrayGetCount(fields), 0)
                XCTAssertEqual(CGPDFArrayGetCount(order), 0)
                XCTAssertEqual(try Self.string(form, "DA"), Data("/Helv 0 Tf 0 g ".utf8))
            }
        }.value
    }

    func testAnyPresentStagedFormIncludingNullAndChangedDefaultsIsCurrent() async throws {
        try await Task.detached {
            let source = try Self.open(Self.fixture())
            let proof = try XCTUnwrap(PDFCatalogStructurePreserver.plan(for: source).emptyFormSource)
            for form in ["null", "<< /Fields [] /DA (Changed 19 Tf) >>", "<< /Fields [] >>"] {
                let staged = try Self.native(Self.fixture(form: form))
                XCTAssertNil(try PDFCatalogStructurePreserver.originalEmptyForm(proof, for: source, staged: staged))
            }
            let current = Self.fixture(form: "<< /Fields [] /DA (Changed 19 Tf) >>")
            let data = try PDFBodyTextPageSnapshot.preservingCatalog(in: current, from: source,
                plan: PDFCatalogStructurePreserver.plan(for: source))
            XCTAssertEqual(try Self.stringInForm(data, "DA"), Data("Changed 19 Tf".utf8))
        }.value
    }

    func testOriginalNonemptyOrUnknownExecutableOrWrongTypedFormHasNoAuthority() async throws {
        try await Task.detached {
            for form in ["<< /Fields [7 0 R] /DA (Original) >>", "<< /Fields [] /XFA (opaque) >>",
                         "<< /Fields [] /CO [null] >>", "<< /Fields [] /CO null >>", "<< /Fields [] /CO 0 >>",
                         "<< /Fields [] /AA << /WC << /S /JavaScript /JS (opaque) >> >> >>",
                         "<< /DA (No fields) >>", "<< /Fields (malformed) >>", "<< /Fields << >> >>",
                         "<< /Fields null >>", "<< /Fields [] /DA 12 >>", "<< /Fields [] /DR [] >>",
                         "<< /Fields [] /Q 1.0 >>", "<< /Fields [] /NeedAppearances /True >>", "null"] {
                let source = try Self.open(Self.fixture(form: form))
                XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: source).emptyFormSource, form)
            }
        }.value
    }

    func testLiveOrStagedWidgetAddedAfterPlanCannotRestoreOldDefaults() async throws {
        try await Task.detached {
            let source = try Self.open(Self.fixture())
            let proof = try XCTUnwrap(PDFCatalogStructurePreserver.plan(for: source).emptyFormSource)
            XCTAssertNil(try PDFCatalogStructurePreserver.originalEmptyForm(proof, for: source,
                staged: Self.native(Self.fixture(form: nil, widget: true))))
            let widget = PDFAnnotation(bounds: CGRect(x: 30, y: 20, width: 60, height: 20), forType: .widget, withProperties: nil)
            widget.widgetFieldType = .text; widget.fieldName = "NewCurrentField"
            source.page(at: 0)?.addAnnotation(widget)
            XCTAssertNil(try PDFCatalogStructurePreserver.originalEmptyForm(proof, for: source,
                staged: Self.native(Self.fixture(form: nil))))
        }.value
    }

    func testDifferentMetadataOwnerMixedSourcesAndSyntheticPageHaveNoAuthority() async throws {
        try await Task.detached {
            let source = try Self.open(Self.fixture())
            let proof = try XCTUnwrap(PDFCatalogStructurePreserver.plan(for: source).emptyFormSource)
            let other = try Self.open(Self.fixture())
            XCTAssertNil(try PDFCatalogStructurePreserver.originalEmptyForm(proof, for: other,
                staged: Self.native(Self.fixture(form: nil))))
            _ = try PDFPageOperations.append(contentsOf: other, to: source)
            XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: source).emptyFormSource)
            let single = try Self.open(Self.fixture())
            single.insert(PDFPage(), at: single.pageCount)
            XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: single).emptyFormSource)
        }.value
    }

    func testGenericForeignBinderAndSignedDocMDPOwnerDoNotGrantEmptyFormAuthority() async throws {
        try await Task.detached {
            let bytes = Self.fixture()
            let foreign = try XCTUnwrap(PDFDocument(data: bytes))
            PDFRawStreamProvenance.bindCreated(foreign, data: bytes)
            try PDFCatalogStructurePreserver.prepare(foreign, force: true)
            XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: foreign).emptyFormSource)

            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-empty-form-signed-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let input = folder.appendingPathComponent("signed-empty.pdf")
            // Synthetic signature metadata tests preservation policy only;
            // it makes no cryptographic-validity claim.
            try Self.fixture(catalogExtra: " /Perms << /DocMDP << /Type /Sig /ByteRange [0 0 0 0] /Contents <00> >> >>").write(to: input)
            let version = try PDFSourceFileVersion.capture(at: input)
            let signed = try XCTUnwrap(PDFRawStreamProvenance.documentForGuardedLoader(at: input, before: version))
            PDFRawStreamProvenance.bindOpened(signed, url: input, version: version)
            try PDFCatalogStructurePreserver.prepare(signed, force: true)
            XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: signed).emptyFormSource)
        }.value
    }

    func testEncryptedOrLockedCarrierNeverAcquiresUnencryptedSourceAuthority() async throws {
        try await Task.detached {
            let source = try Self.open(Self.fixture())
            let proof = try XCTUnwrap(PDFCatalogStructurePreserver.plan(for: source).emptyFormSource)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-empty-form-encrypted-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let input = folder.appendingPathComponent("encrypted.pdf")
            XCTAssertTrue(source.write(to: input, withOptions: [.ownerPasswordOption: "EmptyFormOwner9", .userPasswordOption: "EmptyFormReader9"]))
            let bytes = try Data(contentsOf: input), locked = try Self.native(bytes)
            XCTAssertTrue(locked.isEncrypted); XCTAssertFalse(locked.isUnlocked)
            XCTAssertNil(try PDFCatalogStructurePreserver.originalEmptyForm(proof, for: source, staged: locked))
            XCTAssertTrue(locked.unlockWithPassword("EmptyFormReader9"))
            XCTAssertTrue(locked.isEncrypted); XCTAssertTrue(locked.isUnlocked)
            XCTAssertNil(try PDFCatalogStructurePreserver.originalEmptyForm(proof, for: source, staged: locked))
            let current = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
            XCTAssertTrue(current.isLocked)
            XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: current).emptyFormSource)
            XCTAssertTrue(current.unlock(withPassword: "EmptyFormReader9"))
            try PDFCatalogStructurePreserver.prepare(current, force: true)
            XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: current).emptyFormSource)
        }.value
    }

    func testCancellationDoesNotPublishOriginalForm() async throws {
        try await Task.detached {
            let source = try Self.open(Self.fixture())
            let proof = try XCTUnwrap(PDFCatalogStructurePreserver.plan(for: source).emptyFormSource)
            let staged = try Self.native(Self.fixture(form: nil)), token = PDFSaveCancellation()
            token.cancel()
            XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(token) {
                try PDFCatalogStructurePreserver.originalEmptyForm(proof, for: source, staged: staged)
            }) { XCTAssertTrue($0 is CancellationError) }
        }.value
    }

    func testNativeCarrierAndAtomicRecoverySnapshotRetainEmptyFormAcrossReopen() async throws {
        let direct = try await Task.detached { try XCTUnwrap(PDFNativeStagingWriter.dataIfEligible(Self.open(Self.fixture()))) }.value
        try Self.assertOriginalEmptyForm(direct)
        var current = try Self.open(Self.fixture())
        for _ in 0..<2 {
            let snapshot = try PDFRecoverySnapshot(capturing: current)
            let data = try await Task.detached { () throws -> Data in
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-empty-form-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let output = folder.appendingPathComponent("saved.pdf")
                try AtomicPDFWriter.write(snapshot.takeDocument(), to: output)
                return try Data(contentsOf: output)
            }.value
            try Self.assertOriginalEmptyForm(data)
            current = try Self.open(data)
        }
    }

    func testOwnedRecoveryCopyNonceSupportsTwoExactCopyGenerations() throws {
        var source = try Self.open(Self.fixture())
        for _ in 0..<2 {
            let copy = try XCTUnwrap(PDFCatalogStructurePreserver.recoverySnapshotCopy(of: source, capturedWidgetCount: 0))
            XCTAssertFalse(copy === source)
            PDFCatalogStructurePreserver.forward(from: source, to: copy, force: true)
            XCTAssertNotNil(try PDFCatalogStructurePreserver.plan(for: copy).emptyFormSource)
            source = copy
        }
    }

    func testGenericCopyForwardCannotMintOrTransferOwnedSnapshotNonce() throws {
        let source = try Self.open(Self.fixture())
        let owned = try XCTUnwrap(PDFCatalogStructurePreserver.recoverySnapshotCopy(of: source, capturedWidgetCount: 0))
        PDFCatalogStructurePreserver.forward(from: source, to: owned, force: true)
        XCTAssertNotNil(try PDFCatalogStructurePreserver.plan(for: owned).emptyFormSource)
        let generic = try XCTUnwrap(owned.copy() as? PDFDocument)
        PDFCatalogStructurePreserver.forward(from: owned, to: generic, force: true)
        XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: generic).emptyFormSource)

        let current = try Self.open(Self.fixture(form: "<< /Fields [] /DA (Current changed form) >>"))
        PDFCatalogStructurePreserver.forward(from: source, to: current, force: true)
        XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: current).emptyFormSource)
        let copied = try XCTUnwrap(PDFCatalogStructurePreserver.recoverySnapshotCopy(of: current, capturedWidgetCount: 0))
        PDFCatalogStructurePreserver.forward(from: current, to: copied, force: true)
        XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: copied).emptyFormSource)
    }

    func testOwnedSnapshotNonceDoesNotSurviveWidgetOrMetadataProvenanceChange() throws {
        let source = try Self.open(Self.fixture()), other = try Self.open(Self.fixture(form: "<< /Fields [] /DA (Other metadata) >>"))
        let widgetCopy = try XCTUnwrap(PDFCatalogStructurePreserver.recoverySnapshotCopy(of: source, capturedWidgetCount: 0))
        PDFCatalogStructurePreserver.forward(from: source, to: widgetCopy, force: true)
        let widget = PDFAnnotation(bounds: CGRect(x: 30, y: 20, width: 60, height: 20), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text; widget.fieldName = "Current added widget"
        widgetCopy.page(at: 0)?.addAnnotation(widget)
        XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: widgetCopy).emptyFormSource)

        let metadataCopy = try XCTUnwrap(PDFCatalogStructurePreserver.recoverySnapshotCopy(of: source, capturedWidgetCount: 0))
        PDFCatalogStructurePreserver.forward(from: source, to: metadataCopy, force: true)
        PDFCatalogStructurePreserver.inheritDocumentMetadata(from: other, to: metadataCopy)
        XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: metadataCopy).emptyFormSource)
    }

    func testOptionalEmptyFormRefusalsKeepNormalSDKCopyAndOnlyCancellationThrows() throws {
        for form in ["<< /Fields [] /XFA (unsupported) >>", "<< /DA (Missing fields) >>", "<< /Fields [] /Q 1.0 >>"] {
            let source = try Self.open(Self.fixture(form: form))
            let copy = try XCTUnwrap(PDFCatalogStructurePreserver.recoverySnapshotCopy(of: source, capturedWidgetCount: 0))
            XCTAssertFalse(copy === source)
            PDFCatalogStructurePreserver.forward(from: source, to: copy, force: true)
            XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: copy).emptyFormSource)
        }
        let source = try Self.open(Self.fixture())
        let liveWidget = PDFAnnotation(bounds: CGRect(x: 30, y: 20, width: 60, height: 20), forType: .widget, withProperties: nil)
        liveWidget.widgetFieldType = .text; liveWidget.fieldName = "Actual captured widget"
        source.page(at: 0)?.addAnnotation(liveWidget)
        let countRefusal = try XCTUnwrap(PDFCatalogStructurePreserver.recoverySnapshotCopy(of: source, capturedWidgetCount: 1))
        PDFCatalogStructurePreserver.forward(from: source, to: countRefusal, force: true)
        XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: countRefusal).emptyFormSource)
        let token = PDFSaveCancellation(); token.cancel()
        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(token) {
            try PDFCatalogStructurePreserver.recoverySnapshotCopy(of: source, capturedWidgetCount: 0)
        }) { XCTAssertTrue($0 is CancellationError) }
    }

    nonisolated private static func open(_ data: Data) throws -> PDFDocument {
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: data))
        try PDFCatalogStructurePreserver.prepare(document, force: true)
        return document
    }
    nonisolated private static func native(_ data: Data) throws -> CGPDFDocument {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGPDFDocument(provider))
    }
    nonisolated private static func stringInForm(_ data: Data, _ key: String) throws -> Data {
        let owner = try native(data)
        return try withExtendedLifetime(owner) {
            let catalog = try XCTUnwrap(owner.catalog)
            var value: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "AcroForm", &value))
            return try string(XCTUnwrap(value), key)
        }
    }
    nonisolated private static func string(_ dictionary: CGPDFDictionaryRef, _ key: String) throws -> Data {
        var value: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetString(dictionary, key, &value))
        let text = try XCTUnwrap(value), pointer = try XCTUnwrap(CGPDFStringGetBytePtr(text))
        return Data(bytes: pointer, count: CGPDFStringGetLength(text))
    }
    nonisolated private static func assertOriginalEmptyForm(_ data: Data) throws {
        let owner = try native(data), catalog = try XCTUnwrap(owner.catalog)
        var form: CGPDFDictionaryRef?, fields: CGPDFArrayRef?, resources: CGPDFDictionaryRef?, fonts: CGPDFDictionaryRef?, helvetica: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form))
        let current = try XCTUnwrap(form)
        XCTAssertTrue(CGPDFDictionaryGetArray(current, "Fields", &fields)); XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(fields)), 0)
        XCTAssertEqual(try string(current, "DA"), Data("/Helv 0 Tf 0 g ".utf8))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(current, "DR", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "Font", &fonts))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(fonts), "Helv", &helvetica))
        XCTAssertNotNil(helvetica)
        withExtendedLifetime(owner) {}
    }
    nonisolated private static func fixture(form: String? = "<< /Fields [] /DA (/Helv 0 Tf 0 g ) /DR << /Font << /Helv 4 0 R >> >> /Q 0 /NeedAppearances false >>", widget: Bool = false, catalogExtra: String = "") -> Data {
        let paint = "BT /Helv 14 Tf 1 0 0 1 30 200 Tm (Original live body) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R" + (form == nil ? "" : " /AcroForm 6 0 R") + catalogExtra + " >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /Helv 4 0 R >> >> /Contents 5 0 R" + (widget ? " /Annots [7 0 R]" : "") + " >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(paint.utf8.count) >>\nstream\n\(paint)\nendstream",
            form ?? "null",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (ExistingField) /Rect [30 20 90 40] /P 3 0 R >>"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets: [Int] = []
        for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
}
