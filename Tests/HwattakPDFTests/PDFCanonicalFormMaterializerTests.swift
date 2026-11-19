// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFCanonicalFormMaterializerTests: XCTestCase {
    func testOrphanWidgetGetsCanonicalFieldsWithoutChangingOriginalObjectBytesOrPixels() throws {
        let source = fixture()
        let output = try PDFCanonicalFormMaterializer.materialize(source)
        XCTAssertTrue(output.starts(with: source), "Materialization must append to the complete original bytes.")
        XCTAssertGreaterThan(output.count, source.count)
        let fields = try canonicalFields(output)
        XCTAssertEqual(fields, ["student": "Ada"])
        XCTAssertEqual(try pixels(source), try pixels(output))
        XCTAssertEqual(try PDFCanonicalFormMaterializer.materialize(output), output,
                       "An already canonical incremental result must be idempotent.")
        let reopened = try XCTUnwrap(PDFDocument(data: output))
        XCTAssertEqual(reopened.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Canonical form fixture")
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.widgetStringValue, "Ada")
    }

    func testOriginalCanonicalRawFixtureIsRecognizedAndRemainsByteIdentical() throws {
        let source = fixture(canonical: true)
        XCTAssertEqual(try canonicalFields(source), ["student": "Ada"])
        XCTAssertEqual(try PDFCanonicalFormMaterializer.materialize(source), source)
        let document = try XCTUnwrap(PDFDocument(data: source))
        XCTAssertTrue(PDFCanonicalFormMaterializer.shouldMaterialize(document))
    }

    func testExistingHierarchicalCanonicalFormIsPreservedButContradictoryWidgetValueFails() throws {
        let source = fixture(canonical: true, hierarchical: true)
        XCTAssertEqual(try PDFCanonicalFormMaterializer.materialize(source), source)
        let inconsistent = fixture(canonical: true, extraFieldEntries: "/V (Bob)", hierarchical: true)
        XCTAssertThrowsError(try PDFCanonicalFormMaterializer.materialize(inconsistent))
    }

    func testHierarchicalParentAndWidgetValuesCanUseDifferentPDFStringEncodings() throws {
        let source = fixture(canonical: true, extraFieldEntries: "/V <FEFF004100640061>", hierarchical: true)
        XCTAssertEqual(try PDFCanonicalFormMaterializer.materialize(source), source,
                       "PDFDocEncoding Ada and UTF-16 Ada are the same canonical field value.")
    }

    func testUnicodeFieldNamesRemainCanonicalAfterMaterialization() throws {
        let source = fixture(nameToken: "<FEFFD559C0DD>")
        XCTAssertEqual(try canonicalFields(PDFCanonicalFormMaterializer.materialize(source)), ["학생": "Ada"])
    }

    func testPDFKitReserializedCanonicalFormReconnectsItsActualPageWidget() throws {
        let document = try XCTUnwrap(PDFDocument(data: fixture(canonical: true)))
        let serialized = try XCTUnwrap(document.dataRepresentation())
        let repaired = try PDFCanonicalFormMaterializer.materialize(serialized)
        XCTAssertTrue(repaired.starts(with: serialized))
        XCTAssertEqual(try canonicalFields(repaired), ["student": "Ada"])
        try assertCanonicalWidgetIsActualPageAnnotation(repaired)
        XCTAssertEqual(try PDFCanonicalFormMaterializer.materialize(repaired), repaired)
    }

    func testDetachedFlatCanonicalCopiesRequireCompleteMatchingDictionaries() throws {
        let source = fixture(canonical: true, detachedFieldCopy: true)
        let repaired = try PDFCanonicalFormMaterializer.materialize(source)
        XCTAssertGreaterThan(repaired.count, source.count)
        try assertCanonicalWidgetIsActualPageAnnotation(repaired)
        XCTAssertThrowsError(try PDFCanonicalFormMaterializer.materialize(
            fixture(canonical: true, detachedFieldCopy: true, detachedFieldValue: "Bob")))
    }

    func testEquivalentIndirectGeometryArraysReconnectWithoutRelaxingAppearanceIdentity() throws {
        let source = indirectGeometryFixture()
        let repaired = try PDFCanonicalFormMaterializer.materialize(source)
        XCTAssertTrue(repaired.starts(with: source))
        XCTAssertEqual(try canonicalFields(repaired), ["student": "Ada"])
        try assertCanonicalWidgetIsActualPageAnnotation(repaired)
        XCTAssertThrowsError(try PDFCanonicalFormMaterializer.materialize(indirectGeometryFixture(rectangle: "[30 100 181 125]")))
        XCTAssertThrowsError(try PDFCanonicalFormMaterializer.materialize(indirectGeometryFixture(border: "[0 0 1]")))
        XCTAssertThrowsError(try PDFCanonicalFormMaterializer.materialize(indirectGeometryFixture(differentAppearance: true)),
            "Equal stream bytes at a different appearance reference are outside the scalar-array exception.")
    }

    func testGeometryDecimalSpellingsReconnectWithExactNumericEquality() throws {
        for (annotation, field) in [
            ("[30 100 180 125]", "[30.0 100.0 180.0 125.0]"),
            ("[+00030 100. 00180.000 +125]", "[30.000 +0100.0 180 125.000]"),
            ("[0 100 180 125]", "[-000.000 100.0 180.00 125.0]"),
            ("[.5 100 180 125]", "[00.5000 100.0 180 125]"),
            ("[-.5 100 180 125]", "[-00.5000 100 180.0 125]"),
            ("[9007199254740993 100 180 125]", "[9007199254740993.000 100 180 125]")
        ] {
            let source = indirectGeometryFixture(rectangle: field, annotationRectangle: annotation,
                border: "[-0.0 +000.000 00.0]")
            let repaired = try PDFCanonicalFormMaterializer.materialize(source)
            XCTAssertTrue(repaired.starts(with: source), "Only append a canonical Fields identity repair.")
            try assertCanonicalWidgetIsActualPageAnnotation(repaired)
        }
    }

    func testGeometryDecimalComparisonRejectsTinyDifferencesAndDoublePrecisionCollapse() throws {
        for (annotation, field) in [
            ("[30 100 180 125]", "[30.000000000000000000000000000001 100 180 125]"),
            ("[0 100 180 125]", "[-0.000000000000000000000000000001 100 180 125]"),
            ("[9007199254740992 100 180 125]", "[9007199254740993.0 100 180 125]"),
            ("[9007199254740993.0 100 180 125]", "[9007199254740992 100 180 125]")
        ] {
            XCTAssertThrowsError(try PDFCanonicalFormMaterializer.materialize(
                indirectGeometryFixture(rectangle: field, annotationRectangle: annotation)))
        }
        XCTAssertThrowsError(try PDFCanonicalFormMaterializer.materialize(
            indirectGeometryFixture(border: "[0 0 0.000000000000000000000000000001]")))
    }

    func testGeometryDecimalExceptionCannotNormalizeChoiceIndicesOrFieldValueArrays() throws {
        for key in ["Opt", "I", "V", "DV"] {
            XCTAssertThrowsError(try PDFCanonicalFormMaterializer.materialize(
                indirectGeometryFixture(scalarArrayKey: key)), "\(key) retains the existing scalar-array comparison.")
        }
        XCTAssertThrowsError(try PDFCanonicalFormMaterializer.materialize(
            indirectGeometryFixture(rectangle: "[30.0 100.0 180.0 125.0]", differentAppearance: true)),
            "Equivalent geometry cannot authorize a distinct appearance/resource reference.")
    }

    func testIndirectChoiceArrayDAGAmplificationFailsWithinTheSharedComparisonBudget() throws {
        XCTAssertThrowsError(try PDFCanonicalFormMaterializer.materialize(indirectGeometryFixture(amplifyingChoiceArrays: true))) { error in
            guard let failure = error as? PDFCanonicalFormMaterializer.Failure, case .tooLarge = failure else {
                return XCTFail("A compact shared array graph must stop at its aggregate comparison budget: \(error)")
            }
        }
    }

    func testPartialFlatCanonicalTreeIncludesValidatedOrphanWidgets() throws {
        let source = fixture(canonical: true, secondName: "teacher", omitSecondCanonicalField: true)
        let repaired = try PDFCanonicalFormMaterializer.materialize(source)
        XCTAssertTrue(repaired.starts(with: source))
        XCTAssertEqual(try canonicalFields(repaired), ["student": "Ada", "teacher": "Ada"])
        try assertCanonicalWidgetIsActualPageAnnotation(repaired)
        XCTAssertEqual(try PDFCanonicalFormMaterializer.materialize(repaired), repaired)
    }

    func testDuplicateNamesParentRelationshipsAndInvalidXrefAreRejected() throws {
        for source in [fixture(secondName: "student"), fixture(canonical: true, secondName: "student"),
                       fixture(extraFieldEntries: "/Parent 8 0 R"), fixture(corruptXref: true)] {
            XCTAssertThrowsError(try PDFCanonicalFormMaterializer.materialize(source))
        }
    }

    func testOrdinaryDocumentNeedsNoMaterializationUntilExplicitlyMarked() throws {
        let source = try XCTUnwrap(PDFDocument(data: fixture(includeWidget: false)))
        XCTAssertFalse(PDFCanonicalFormMaterializer.shouldMaterialize(source))
        PDFCanonicalFormMaterializer.mark(source)
        XCTAssertTrue(PDFCanonicalFormMaterializer.shouldMaterialize(source))
    }

    func testEncryptedSerializedBytesRemainUnchangedWithoutRawRewriting() throws {
        let document = try XCTUnwrap(PDFDocument(data: fixture(canonical: true)))
        let data = try XCTUnwrap(document.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner-pass", PDFDocumentWriteOption.userPasswordOption: "reader-pass"]))
        XCTAssertEqual(try PDFCanonicalFormMaterializer.materialize(data), data)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: data)).isEncrypted)
    }

    func testExtractionAndMergeMarkFlatFormsAndAtomicSaveCreatesCanonicalFields() throws {
        let source = try boundDocument(fixture(canonical: true))
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
        XCTAssertTrue(PDFCanonicalFormMaterializer.shouldMaterialize(extracted))
        let merged = PDFDocument()
        XCTAssertEqual(try PDFPageOperations.append(contentsOf: source, to: merged), 1)
        XCTAssertTrue(PDFCanonicalFormMaterializer.shouldMaterialize(merged))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-canonical-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, document) in [("source", source), ("extracted", extracted), ("merged", merged)] {
            let destination = directory.appendingPathComponent(name + ".pdf")
            try AtomicPDFWriter.write(document, to: destination)
            XCTAssertEqual(try canonicalFields(Data(contentsOf: destination)), ["student": "Ada"], name)
        }
        XCTAssertEqual(source.pageCount, 1)
        XCTAssertEqual(source.page(at: 0)?.annotations.first?.widgetStringValue, "Ada")
    }

    @MainActor
    func testRecoverySerializedSnapshotPreservesCanonicalFieldsAcrossDataBoundary() throws {
        let source = try boundDocument(fixture())
        PDFCanonicalFormMaterializer.mark(source)
        let snapshot = try PDFRecoverySnapshot(capturing: source)
        let data = try snapshot.serializedData()
        XCTAssertEqual(try canonicalFields(data), ["student": "Ada"])
        XCTAssertTrue(PDFCanonicalFormMaterializer.shouldMaterialize(try XCTUnwrap(PDFDocument(data: data))))
        XCTAssertEqual(source.page(at: 0)?.annotations.first?.widgetStringValue, "Ada")
    }

    func testMarkedAmbiguousFormCannotOverwriteExistingFile() throws {
        let source = try boundDocument(fixture(secondName: "student"))
        PDFCanonicalFormMaterializer.mark(source)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-canonical-refusal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.pdf")
        let original = fixture(includeWidget: false)
        try original.write(to: destination)
        XCTAssertThrowsError(try AtomicPDFWriter.write(source, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    private func canonicalFields(_ data: Data) throws -> [String: String] {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        let catalog = try XCTUnwrap(document.catalog)
        var form: CGPDFDictionaryRef?, fields: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form))
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(form), "Fields", &fields))
        let array = try XCTUnwrap(fields)
        var result: [String: String] = [:]
        for index in 0..<CGPDFArrayGetCount(array) {
            var field: CGPDFDictionaryRef?, name: CGPDFStringRef?, value: CGPDFStringRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(array, index, &field))
            XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(field), "T", &name))
            XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(field), "V", &value))
            let decodedName = try XCTUnwrap(CGPDFStringCopyTextString(try XCTUnwrap(name))) as String
            let decodedValue = try XCTUnwrap(CGPDFStringCopyTextString(try XCTUnwrap(value))) as String
            XCTAssertNil(result[decodedName], "Canonical /Fields must contain each name once.")
            result[decodedName] = decodedValue
        }
        return result
    }

    /// Editable factories know these exact immutable bytes. Reader-only SDK
    /// controls above intentionally keep their original unbound reader route.
    private func boundDocument(_ data: Data) throws -> PDFDocument {
        let document = try XCTUnwrap(PDFDocument(data: data))
        PDFRawStreamProvenance.bindCreated(document, data: data)
        let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        // These legacy synchronous writer tests run on main. Fixture setup
        // publishes only independently read scalar data from a real worker;
        // it never transfers a live fixture page/font/annotation to that worker.
        let completion = DispatchSemaphore(value: 0), result = BaselineResult()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { completion.signal() }
            do {
                _ = try source.originalWidgetStates(onPage: 0)
                _ = try source.originalWidgetFormDefaults()
            }
            catch { result.record(error) }
        }
        XCTAssertEqual(completion.wait(timeout: .now() + 10), .success)
        try result.check()
        return document
    }

    private final class BaselineResult: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?
        func record(_ error: Error) { lock.lock(); self.error = error; lock.unlock() }
        func check() throws { lock.lock(); defer { lock.unlock() }; if let error { throw error } }
    }

    private func assertCanonicalWidgetIsActualPageAnnotation(_ data: Data) throws {
        let document = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
        let catalog = try XCTUnwrap(document.catalog)
        let page = try XCTUnwrap(document.page(at: 1)?.dictionary)
        var form: CGPDFDictionaryRef?, fields: CGPDFArrayRef?, annotations: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form))
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(form), "Fields", &fields))
        XCTAssertTrue(CGPDFDictionaryGetArray(page, "Annots", &annotations))
        var field: CGPDFDictionaryRef?, widget: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(fields), 0, &field))
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annotations), 0, &widget))
        XCTAssertEqual(field, widget, "The canonical field must be the actual page widget, not a detached duplicate.")
    }

    private func pixels(_ data: Data) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        var pixels = Data(count: 300 * 300 * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 300, height: 300,
                bitsPerComponent: 8, bytesPerRow: 300 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
            context.drawPDFPage(try XCTUnwrap(document.page(at: 1)))
        }
        return pixels
    }

    /// A real flat canonical /Fields source is included separately from
    /// PDFKit-generated orphan widgets, so round-trip checks cannot mistake
    /// PDFKit's annotation property getter for canonical form interoperability.
    private func indirectGeometryFixture(rectangle: String = "[30 100 180 125]", annotationRectangle: String = "[30 100 180 125]",
                                         border: String = "[0 0 0]", differentAppearance: Bool = false,
                                         amplifyingChoiceArrays: Bool = false, scalarArrayKey: String? = nil) -> Data {
        let appearance = "<< /Type /XObject /Subtype /Form /BBox [0 0 150 25] /Resources << >> /Length 0 >>\nstream\n\nendstream"
        let fieldType = amplifyingChoiceArrays || scalarArrayKey == "Opt" || scalarArrayKey == "I" ? "Ch" : "Tx"
        let annotationValue = scalarArrayKey == "V" ? "[30]" : "(Ada)"
        let fieldValue = scalarArrayKey == "V" ? "[30.0]" : "(Ada)"
        let annotationExtra = scalarArrayKey.flatMap { $0 == "V" ? nil : "/\($0) [30]" } ?? ""
        let fieldExtra = scalarArrayKey.flatMap { $0 == "V" ? nil : "/\($0) [30.0]" } ?? ""
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 6 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << >> /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /\(fieldType) /T (student) /V \(annotationValue) /Rect 8 0 R /Border 10 0 R /AP << /N 5 0 R >> \(amplifyingChoiceArrays ? "/Opt 13 0 R" : "") \(annotationExtra) >>",
            appearance,
            "<< /Fields [7 0 R] /NeedAppearances false >>",
            "<< /Type /Annot /Subtype /Widget /FT /\(fieldType) /T (student) /V \(fieldValue) /Rect 9 0 R /Border 11 0 R /AP << /N \(differentAppearance ? 12 : 5) 0 R >> \(amplifyingChoiceArrays ? "/Opt 14 0 R" : "") \(fieldExtra) >>",
            annotationRectangle, rectangle, "[0 0 0]", border, appearance
        ]
        if amplifyingChoiceArrays {
            // Only ten indirect array objects encode 32^5 leaf comparisons.
            // Distinct left/right references prevent identity short-circuits.
            for level in 0..<5 {
                for side in 0..<2 {
                    let child = level == 4 ? "(Choice)" : "\(15 + level * 2 + side) 0 R"
                    objects.append("[" + Array(repeating: child, count: 32).joined(separator: " ") + "]")
                }
            }
        }
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

    private func fixture(canonical: Bool = false, nameToken: String = "(student)", secondName: String? = nil,
                         includeWidget: Bool = true, extraFieldEntries: String = "", corruptXref: Bool = false, hierarchical: Bool = false,
                         detachedFieldCopy: Bool = false, detachedFieldValue: String? = nil, omitSecondCanonicalField: Bool = false) -> Data {
        let text = "BT /F1 16 Tf 30 240 Td (Independent form fixture) Tj ET"
        let appearance = "BT /Helv 12 Tf 3 6 Td (Ada) Tj ET"
        let second = secondName == nil ? "" : "10 0 R"
        let fieldEntries = hierarchical ? "/Parent 11 0 R" : "/FT /Tx /T \(nameToken) /V (Ada)"
        let annotation = "<< /Type /Annot /Subtype /Widget \(fieldEntries) /Rect [30 100 180 125] /DA (/Helv 12 Tf 0 g) /AP << /N 7 0 R >> \(extraFieldEntries) >>"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R \(canonical ? "/AcroForm 8 0 R" : "") >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R \(includeWidget ? "/Annots [6 0 R \(second)]" : "") >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream",
            annotation,
            "<< /Type /XObject /Subtype /Form /BBox [0 0 150 25] /Resources << /Font << /Helv 4 0 R >> >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)\nendstream",
            "<< /Fields [\(hierarchical ? "11 0 R" : detachedFieldCopy ? "10 0 R" : "6 0 R \(omitSecondCanonicalField ? "" : second)")] /NeedAppearances false /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >>",
            "<< /Title (Canonical form fixture) >>",
            annotation.replacingOccurrences(of: nameToken, with: detachedFieldCopy ? nameToken : "(\(secondName ?? "unused"))")
                .replacingOccurrences(of: "/V (Ada)", with: "/V (\(detachedFieldValue ?? "Ada"))")
        ]
        if hierarchical { objects.append("<< /FT /Tx /T (student) /V (Ada) /Kids [6 0 R] >>") }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 9 0 R >>\nstartxref\n\(corruptXref ? 0 : xref)\n%%EOF\n".utf8))
        return data
    }
}
