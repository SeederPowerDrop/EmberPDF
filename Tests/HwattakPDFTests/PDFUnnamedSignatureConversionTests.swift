// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import CEmberPDFRawStreams
import CoreGraphics
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFUnnamedSignatureConversionTests: XCTestCase {
    func testUnnamedSignatureBecomesInactiveStampThroughWorkerSaveAndReopen() async throws {
        for hidden in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-signature-subtype-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let bytes = signatureBytes(hidden: hidden)
            let sourceURL = directory.appendingPathComponent("source.pdf")
            try bytes.write(to: sourceURL, options: .withoutOverwriting)
            let source = try PDFSourceFileAccess.loadDocument(at: sourceURL).document
            let signaturePage = hidden ? 0 : 1
            let sourcePage = try XCTUnwrap(source.page(at: signaturePage))
            let originalWidget = try annotationDictionary(sourcePage, index: 0)
            XCTAssertEqual(try nativeName(originalWidget, "Subtype"), "Widget")
            XCTAssertEqual(try nativeName(originalWidget, "FT"), "Sig")
            print("QE_SIG_PUBLIC_AP_GETTER", "source", sourcePage.annotations.first?.value(forAnnotationKey: .init(rawValue: "/AP")).map { String(reflecting: type(of: $0)) } ?? "nil")
            let originalAppearance = try appearance(originalWidget)
            let originalAppearanceGraph = try appearanceGraph(originalWidget)
            let originalPixels = try appearancePixels(originalWidget)
            XCTAssertGreaterThan(coloredPixels(originalPixels), 0, "The original red Form must produce a positive colored raster.")
            let originalPainting = try (0..<2).map { try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(source.page(at: $0))) }
            let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 1])
            let stamp = try XCTUnwrap(extracted.page(at: signaturePage)?.annotations.first)
            XCTAssertEqual(stamp.type, "Stamp")
            print("QE_SIG_PUBLIC_AP_GETTER", "converted", stamp.value(forAnnotationKey: .init(rawValue: "/AP")).map { String(reflecting: type(of: $0)) } ?? "nil")
            for key in ["/NM", "/FT", "/T", "/V"] { XCTAssertNil(stamp.value(forAnnotationKey: .init(rawValue: key))) }
            let plan = try PDFCatalogStructurePreserver.plan(for: extracted)
            XCTAssertTrue((plan.annotationNames[signaturePage] ?? [:]).isEmpty)
            XCTAssertNil(plan.annotationEntries[signaturePage]?[0]?["NM"])
            XCTAssertFalse(plan.annotationDrops[signaturePage]?[0]?.contains("NM") == true)
            // The narrow nil return never turns the original Widget into a
            // valid current/staged Stamp or grants an annotation-name proof.
            XCTAssertThrowsError(try PDFPageGeometryPreserver.stagedAnnotation(originalWidget, matches: stamp))
            let firstURL = directory.appendingPathComponent("saved.pdf")
            let first = try await savedOnWorker(extracted, at: firstURL)
            try assertInactive(first, at: signaturePage, originalAppearance: originalAppearance, originalGraph: originalAppearanceGraph, originalPixels: originalPixels)
            for index in 0..<2 {
                let saved = try XCTUnwrap(first.page(at: index)), original = try XCTUnwrap(source.page(at: index))
                XCTAssertEqual(saved.rotation, hidden ? 0 : 270)
                for (_, box) in PDFPageGeometryPreserver.boxes { XCTAssertEqual(saved.bounds(for: box), original.bounds(for: box)) }
                XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: saved), originalPainting[index])
            }
            XCTAssertEqual(try embeddedSignedOriginal(first), bytes)
            let reopened = try PDFSourceFileAccess.loadDocument(at: firstURL).document
            let extractedAgain = try PDFPageOperations.extract(from: reopened, indexes: [0, 1])
            let second = try await savedOnWorker(extractedAgain, at: directory.appendingPathComponent("saved-again.pdf"))
            try assertInactive(second, at: signaturePage, originalAppearance: originalAppearance, originalGraph: originalAppearanceGraph, originalPixels: originalPixels)
            XCTAssertEqual(try embeddedSignedOriginal(second), bytes)
            XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
            XCTAssertEqual(sourcePage.annotations.first?.type, "Widget")
            XCTAssertEqual(try nativeName(originalWidget, "FT"), "Sig")
        }
    }

    func testNonSignatureUnnamedSubtypeChangeStillRejectsNameAuthority() throws {
        for (subtype, fieldType) in [("Square", nil), ("Widget", "Tx")] as [(String, String?)] {
            let source = try ordinary(name: nil, subtype: subtype, fieldType: fieldType)
            let page = try XCTUnwrap(source.page(at: 0)), annotation = try XCTUnwrap(page.annotations.first)
            let original = try annotationDictionary(page, index: 0)
            XCTAssertTrue(annotation.setValue("Stamp", forAnnotationKey: .init(rawValue: "/Subtype")))
            for key in ["/FT", "/T", "/V"] { annotation.removeValue(forAnnotationKey: .init(rawValue: key)) }
            XCTAssertThrowsError(try name(annotation, original: original))
        }
    }

    func testPresentNullWrongTypedOrChangedNamesCannotBorrowSignatureException() throws {
        for literal in ["(original)", "null", "42", "/WrongType"] {
            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: signatureBytes(hidden: false, name: literal, signed: false)))
            let original = try annotationDictionary(XCTUnwrap(source.page(at: 1)), index: 0)
            // Malformed NM inputs are exercised directly at the narrow
            // helper boundary; earlier extraction refusal is also legitimate.
            let stamp = PDFAnnotation(bounds: CGRect(x: 20, y: 30, width: 40, height: 50), forType: .stamp, withProperties: nil)
            XCTAssertThrowsError(try name(stamp, original: original))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-signature-negative-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.pdf")
        try signatureBytes(hidden: false, signed: true).write(to: sourceURL, options: .withoutOverwriting)
        let source = try PDFSourceFileAccess.loadDocument(at: sourceURL).document
        let original = try annotationDictionary(XCTUnwrap(source.page(at: 1)), index: 0)
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 1])
        let stamp = try XCTUnwrap(extracted.page(at: 1)?.annotations.first)
        XCTAssertEqual(stamp.type, "Stamp")
        for key in ["/NM", "/FT", "/T", "/V"] { XCTAssertNil(stamp.value(forAnnotationKey: .init(rawValue: key))) }
        XCTAssertNil(try name(stamp, original: original))
        XCTAssertTrue(stamp.setValue("edited", forAnnotationKey: .init(rawValue: "/NM")))
        XCTAssertThrowsError(try name(stamp, original: original))
        stamp.removeValue(forAnnotationKey: .init(rawValue: "/NM"))
        let nullAccepted = stamp.setValue(NSNull(), forAnnotationKey: .init(rawValue: "/NM"))
        print("QE_SIG_NULL_SETTER_ACCEPTED", nullAccepted)
        if nullAccepted {
            XCTAssertTrue(stamp.value(forAnnotationKey: .init(rawValue: "/NM")) is NSNull)
            XCTAssertThrowsError(try name(stamp, original: original))
        } else {
            // PDFKit rejects this setter on the current SDK. Original explicit
            // native /NM null is still covered by the malformed fixture above.
            XCTAssertNil(stamp.value(forAnnotationKey: .init(rawValue: "/NM")))
            XCTAssertNil(try name(stamp, original: original))
        }
        stamp.removeValue(forAnnotationKey: .init(rawValue: "/NM"))
        for key in ["/FT", "/T", "/V"] {
            let accepted = stamp.setValue("residual", forAnnotationKey: .init(rawValue: key))
            print("QE_SIG_RESIDUAL_SETTER", key, accepted)
            if accepted {
                XCTAssertNotNil(stamp.value(forAnnotationKey: .init(rawValue: key)))
                XCTAssertThrowsError(try name(stamp, original: original))
                stamp.removeValue(forAnnotationKey: .init(rawValue: key))
            } else {
                XCTAssertNil(stamp.value(forAnnotationKey: .init(rawValue: key)))
                // Unsupported setters do not create a malformed current value.
                // Exercise a genuinely native-present scalar instead.
                let token = key == "/FT" ? "/Sig" : "(residual)"
                let rawStamp = pdf(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
                    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Annots [4 0 R] >>",
                    "<< /Type /Annot /Subtype /Stamp /Rect [20 30 60 80] \(key) \(token) >>"])
                let current = try XCTUnwrap(PDFDocument(data: rawStamp)), currentStamp = try XCTUnwrap(current.page(at: 0)?.annotations.first)
                if let exposed = currentStamp.value(forAnnotationKey: .init(rawValue: key)) {
                    print("QE_SIG_NATIVE_RESIDUAL_EXPOSED", key, String(reflecting: type(of: exposed)))
                    XCTAssertThrowsError(try name(currentStamp, original: original))
                } else {
                    // Current PDFKit hides FT for Stamp even when its native
                    // dictionary has the name. Observe that bridge boundary;
                    // do not claim a rejected setter exercised a present getter.
                    XCTAssertEqual(key, "/FT")
                    XCTAssertEqual(try nativeName(annotationDictionary(XCTUnwrap(current.page(at: 0)), index: 0), "FT"), "Sig")
                    XCTAssertNil(try name(currentStamp, original: original))
                    print("QE_SIG_NATIVE_FT_PRESENT_PUBLIC_GETTER_ABSENT")
                }
            }
        }
    }

    func testOrdinaryCurrentRenamedAndClearedNamesStillWin() throws {
        for clear in [false, true] {
            let source = try ordinary(name: "(original)")
            let page = try XCTUnwrap(source.page(at: 0)), annotation = try XCTUnwrap(page.annotations.first)
            let original = try annotationDictionary(page, index: 0)
            if clear { annotation.removeValue(forAnnotationKey: .init(rawValue: "/NM")) }
            else { XCTAssertTrue(annotation.setValue("User-e\u{0301}", forAnnotationKey: .init(rawValue: "/NM"))) }
            let saved = try XCTUnwrap(name(annotation, original: original))
            XCTAssertEqual(saved.current, clear ? nil : "User-e\u{0301}")
            if clear { XCTAssertNil(saved.value) }
            else if case .string(let data)? = saved.value { XCTAssertEqual(data, Data([0xFE, 0xFF]) + (try XCTUnwrap("User-e\u{0301}".data(using: .utf16BigEndian)))) }
            else { XCTFail("Current name must keep its explicit UTF16 encoding.") }
        }
    }

    func testChangedConvertedStampDrawingStateNeverReusesSignatureAP() async throws {
        for edit in ["color", "bounds", "contents", "AP"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-sig-edited-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let input = directory.appendingPathComponent("source.pdf")
            try signatureBytes(hidden: false).write(to: input, options: .withoutOverwriting)
            let source = try PDFSourceFileAccess.loadDocument(at: input).document
            let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 1])
            let stamp = try XCTUnwrap(extracted.page(at: 1)?.annotations.first)
            switch edit {
            case "color": stamp.color = .green
            case "bounds": stamp.bounds = CGRect(x: 100, y: 100, width: 75, height: 125)
            case "contents": stamp.contents = "current edited Stamp"
            default:
                XCTAssertTrue(stamp.setValue(["N": "current appearance"], forAnnotationKey: .init(rawValue: "/AP")))
                XCTAssertNotNil(stamp.value(forAnnotationKey: .init(rawValue: "/AP")))
            }
            let snapshot = try PDFRecoverySnapshot(capturing: extracted)
            let imported = try await Task.detached { () throws -> Bool in
                let document = try snapshot.takeDocument()
                let plan = try PDFCatalogStructurePreserver.plan(for: document)
                return plan.annotationEntries[1]?[0]?["AP"] != nil || plan.annotationEntries[1]?[0]?[PDFSignatureAppearancePreserver.markerKey] != nil
            }.value
            XCTAssertFalse(imported, edit)
            if edit != "AP" {
                let saved = try await savedOnWorker(extracted, at: directory.appendingPathComponent("saved.pdf"))
                let current = try XCTUnwrap(saved.page(at: 1)?.annotations.first)
                XCTAssertNil(PDFSignatureAppearancePreserver.Record(try annotationDictionary(XCTUnwrap(saved.page(at: 1)), index: 0)))
                if edit == "contents" { XCTAssertEqual(current.contents, "current edited Stamp") }
                if edit == "bounds" { XCTAssertEqual(current.bounds, stamp.bounds) }
                if edit == "color" { XCTAssertEqual(current.color.usingColorSpace(.deviceRGB), stamp.color.usingColorSpace(.deviceRGB)) }
            }
        }
    }

    func testMarkerOnlyNativeStampCannotBorrowOriginalAppearance() async throws {
        let program = "q 0 g Q\n"
        let bytes = pdf(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Stamp /Rect [10 10 30 30] /AP << /N 5 0 R >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Resources << >> /Length \(program.utf8.count) >>\nstream\n\(program)endstream"])
        let result = try await Task.detached { () throws -> Bool in
            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes)), owner = try XCTUnwrap(source.documentRef)
            let nativePage = try XCTUnwrap(owner.page(at: 1)?.dictionary), annotations = try XCTUnwrap(PDFCatalogStructurePreserver.array(nativePage, "Annots"))
            var annotation: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(annotations, 0, &annotation))
            let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
            let appearance = try XCTUnwrap(raw.exactAnnotationAppearance(in: owner, pageIndex: 0, annotationIndex: 0, annotation: XCTUnwrap(annotation)))
            var setup = PDFCatalogGraphPlan()
            setup.retainedDocuments = [owner]; setup.rawStreamSources = [raw]
            setup.annotationEntries[0] = [0: ["AP": .original(appearance.appearance), PDFSignatureAppearancePreserver.markerKey:
                PDFSignatureAppearancePreserver.Record(input: Data(repeating: 1, count: 32), appearance: appearance.digest,
                    state: Data(repeating: 0, count: 32), page: 0, annotation: 0).value]]
            let marked = try PDFBodyTextPageSnapshot.preservingCatalog(in: bytes, from: source, plan: setup)
            let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: marked))
            let page = try XCTUnwrap(document.documentRef?.page(at: 1)?.dictionary), list = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
            var native: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &native))
            let nativeAnnotation = try XCTUnwrap(native)
            let record = try XCTUnwrap(PDFSignatureAppearancePreserver.Record(nativeAnnotation))
            XCTAssertEqual(record.appearance, appearance.digest)
            XCTAssertEqual(record.state, try PDFSignatureAppearancePreserver.storedDrawingDigest(nativeAnnotation))
            XCTAssertNil(PDFCatalogStructurePreserver.array(try XCTUnwrap(document.documentRef?.catalog), "AF"))
            let extracted = try PDFPageOperations.extract(from: document, indexes: [0])
            let plan = try PDFCatalogStructurePreserver.plan(for: extracted)
            return plan.annotationEntries[0]?[0]?["AP"] != nil || plan.annotationEntries[0]?[0]?[PDFSignatureAppearancePreserver.markerKey] != nil
        }.value
        XCTAssertFalse(result)
    }

    func testTamperedEmbeddedOriginalAndRecordRefuseReopenAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-sig-tamper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = signatureBytes(hidden: true), input = directory.appendingPathComponent("source.pdf")
        try bytes.write(to: input, options: .withoutOverwriting)
        let source = try PDFSourceFileAccess.loadDocument(at: input).document
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 1])
        let savedURL = directory.appendingPathComponent("saved.pdf")
        let saved = try await savedOnWorker(extracted, at: savedURL)
        XCTAssertNotNil(PDFSignatureAppearancePreserver.Record(try annotationDictionary(XCTUnwrap(saved.page(at: 0)), index: 0)))
        let savedBytes = try Data(contentsOf: savedURL)
        var damagedAF = savedBytes
        let range = try XCTUnwrap(damagedAF.range(of: bytes))
        let red = try XCTUnwrap(bytes.range(of: Data("1 0 0 rg".utf8)))
        damagedAF[range.lowerBound + red.lowerBound] = Character("0").asciiValue!
        let storedInput = Data(SHA256.hash(data: bytes)).map { String(format: "%02X", $0) }.joined()
        var damagedRecord = savedBytes
        let recordRange = try XCTUnwrap(damagedRecord.range(of: Data(storedInput.utf8)))
        damagedRecord[recordRange.lowerBound] = damagedRecord[recordRange.lowerBound] == 65 ? 66 : 65
        for damaged in [damagedAF, damagedRecord] {
            XCTAssertEqual(damaged.count, savedBytes.count)
            let result = try await Task.detached { () throws -> Bool in
                let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: damaged))
                let extracted = try PDFPageOperations.extract(from: document, indexes: [0, 1])
                let plan = try PDFCatalogStructurePreserver.plan(for: extracted)
                return plan.annotationEntries[0]?[0]?["AP"] != nil || plan.annotationEntries[0]?[0]?[PDFSignatureAppearancePreserver.markerKey] != nil
            }.value
            XCTAssertFalse(result)
        }
    }

    func testBoundedRawSignatureScalarCopiesRefuseOversizedValues() throws {
        let long = String(repeating: "A", count: 33)
        let bytes = pdf(["<< /Type /Catalog /Pages 2 0 R /Long (\(long)) /LongName /\(long) >>",
                         "<< /Type /Pages /Count 1 /Kids [3 0 R] >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>"])
        var status: Int32 = 0
        let context = bytes.withUnsafeBytes { ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, bytes.count, 1_024 * 1_024, 128, &status) }
        defer { if let context { ember_raw_pdf_destroy(context) } }
        XCTAssertEqual(status, Int32(EMBER_RAW_PDF_OK.rawValue))
        var catalog: EmberRawPDFObject = 0
        XCTAssertEqual(ember_raw_pdf_catalog(context, &catalog), Int32(EMBER_RAW_PDF_OK.rawValue))
        for key in ["/Long", "/LongName"] {
            var value: EmberRawPDFObject = 0
            let keyBytes = Data(key.utf8)
            XCTAssertEqual(keyBytes.withUnsafeBytes { ember_raw_pdf_dictionary_get(context, catalog, $0.bindMemory(to: UInt8.self).baseAddress, keyBytes.count, &value) }, Int32(EMBER_RAW_PDF_OK.rawValue))
            var pointer: UnsafeMutablePointer<UInt8>?, count = 123
            XCTAssertEqual(ember_raw_pdf_bounded_scalar_copy(context, value, 32, &pointer, &count), Int32(EMBER_RAW_PDF_LIMIT.rawValue))
            XCTAssertNil(pointer); XCTAssertEqual(count, 0)
        }
    }

    func testExactAPDigestSeparatesRoundedDecimalCollisionAndIntegerRealTypes() async throws {
        let variants = ["125.067", "125.06700000000000001", "125", "125.0"]
        XCTAssertEqual(Double(variants[0]), Double(variants[1]), "The fixture must collide through Double.")
        var digests: [Data] = []
        for token in variants {
            let bytes = signatureBytes(hidden: true, boxHeight: token)
            let digest = try await Task.detached { () throws -> Data in
                let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes)), owner = try XCTUnwrap(document.documentRef)
                let page = try XCTUnwrap(owner.page(at: 1)?.dictionary), list = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
                var annotation: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &annotation))
                let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
                return try XCTUnwrap(raw.exactAnnotationAppearance(in: owner, pageIndex: 0, annotationIndex: 0, annotation: XCTUnwrap(annotation))).digest
            }.value
            digests.append(digest)
        }
        XCTAssertEqual(Set(digests).count, 4)
    }

    func testLongStoredAPDecimalSurvivesRepeatedWorkerSaveAndTamperingRefusesAuthority() async throws {
        let token = "125.06700000000000001", directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-sig-exact-number-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = signatureBytes(hidden: true, boxHeight: token), input = directory.appendingPathComponent("source.pdf")
        try bytes.write(to: input, options: .withoutOverwriting)
        let source = try PDFSourceFileAccess.loadDocument(at: input).document
        let firstURL = directory.appendingPathComponent("saved.pdf"), secondURL = directory.appendingPathComponent("saved-again.pdf")
        _ = try await savedOnWorker(PDFPageOperations.extract(from: source, indexes: [0, 1]), at: firstURL)
        let reopened = try PDFSourceFileAccess.loadDocument(at: firstURL).document
        _ = try await savedOnWorker(PDFPageOperations.extract(from: reopened, indexes: [0, 1]), at: secondURL)
        let first = try Data(contentsOf: firstURL), second = try Data(contentsOf: secondURL)
        for data in [bytes, first, second] {
            let actual = try await Task.detached { try Self.storedAPHeightToken(data) }.value
            XCTAssertEqual(actual, token)
        }
        let changedBytes = signatureBytes(hidden: true, boxHeight: "125.067")
        let reused = try await Task.detached { () throws -> Bool in
            let saved = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: first))
            let changed = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: changedBytes)), owner = try XCTUnwrap(changed.documentRef)
            let page = try XCTUnwrap(owner.page(at: 1)?.dictionary), list = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
            var annotation: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &annotation))
            let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: changed))
            let ap = try XCTUnwrap(raw.exactAnnotationAppearance(in: owner, pageIndex: 0, annotationIndex: 0, annotation: XCTUnwrap(annotation)))
            var tamper = PDFCatalogGraphPlan()
            tamper.retainedDocuments = [owner]; tamper.rawStreamSources = [raw]
            tamper.annotationEntries[0] = [0: ["AP": .original(ap.appearance)]]
            let changedAP = try PDFBodyTextPageSnapshot.preservingCatalog(in: first, from: saved, plan: tamper)
            XCTAssertEqual(try Self.storedAPHeightToken(changedAP), "125.067")
            let candidate = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: changedAP))
            let extraction = try PDFPageOperations.extract(from: candidate, indexes: [0, 1])
            let plan = try PDFCatalogStructurePreserver.plan(for: extraction)
            return plan.annotationEntries[0]?[0]?["AP"] != nil || plan.annotationEntries[0]?[0]?[PDFSignatureAppearancePreserver.markerKey] != nil
        }.value
        XCTAssertFalse(reused, "A current AP numeric edit must not borrow the embedded original, even when Double collides.")
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }

    nonisolated private static func storedAPHeightToken(_ data: Data) throws -> String {
        var status: Int32 = 0
        let context = data.withUnsafeBytes { ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, data.count, 1_024 * 1_024, 10_000, &status) }
        defer { if let context { ember_raw_pdf_destroy(context) } }
        XCTAssertEqual(status, Int32(EMBER_RAW_PDF_OK.rawValue))
        guard let context else { throw PDFPageStructurePreserver.Failure.invalidCopy }
        func dictionary(_ object: EmberRawPDFObject, _ key: String) throws -> EmberRawPDFObject {
            let bytes = Data(key.utf8); var value: EmberRawPDFObject = 0
            XCTAssertEqual(bytes.withUnsafeBytes { ember_raw_pdf_dictionary_get(context, object, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count, &value) }, Int32(EMBER_RAW_PDF_OK.rawValue))
            return value
        }
        func item(_ object: EmberRawPDFObject, _ index: UInt32) throws -> EmberRawPDFObject {
            var value: EmberRawPDFObject = 0
            XCTAssertEqual(ember_raw_pdf_array_item(context, object, index, &value), Int32(EMBER_RAW_PDF_OK.rawValue)); return value
        }
        var page: EmberRawPDFObject = 0
        XCTAssertEqual(ember_raw_pdf_page(context, 0, &page), Int32(EMBER_RAW_PDF_OK.rawValue))
        let annotation = try item(dictionary(page, "/Annots"), 0)
        let ap = try dictionary(annotation, "/AP"), normal = try dictionary(ap, "/N")
        var streamDictionary: EmberRawPDFObject = 0
        XCTAssertEqual(ember_raw_pdf_stream_dictionary(context, normal, &streamDictionary), Int32(EMBER_RAW_PDF_OK.rawValue))
        let height = try item(dictionary(streamDictionary, "/BBox"), 3)
        var pointer: UnsafeMutablePointer<UInt8>?, count = 0
        XCTAssertEqual(ember_raw_pdf_number_token_copy(context, height, &pointer, &count), Int32(EMBER_RAW_PDF_OK.rawValue))
        defer { if let pointer { ember_raw_pdf_free(pointer) } }
        return try XCTUnwrap(pointer).withMemoryRebound(to: UInt8.self, capacity: count) { String(decoding: UnsafeBufferPointer(start: $0, count: count), as: UTF8.self) }
    }

    func testUnchangedExplicitSignatureWithOverBudgetAPFailsClosedAndKeepsDestination() async throws {
        var nested = "<< /Leaf true >>"
        for _ in 0..<40 { nested = "<< /Next " + nested + " >>" }
        let bytes = signatureBytes(hidden: true, extraResource: "/Deep " + nested)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-sig-budget-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.pdf"), destination = directory.appendingPathComponent("existing.pdf")
        try bytes.write(to: input, options: .withoutOverwriting)
        let existing = signatureBytes(hidden: false)
        try existing.write(to: destination, options: .withoutOverwriting)
        let source = try PDFSourceFileAccess.loadDocument(at: input).document
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 1])
        XCTAssertEqual(extracted.page(at: 0)?.annotations.first?.type, "Stamp")
        let snapshot = try PDFRecoverySnapshot(capturing: extracted)
        do {
            try await Task.detached {
                let document = try snapshot.takeDocument()
                XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: document)) { error in
                    XCTAssertEqual(error as? PDFPageStructurePreserver.Failure, .unsupportedStructure)
                }
                try AtomicPDFWriter.write(document, to: destination, allowDirectOverwriteFallback: false)
            }.value
            XCTFail("An unchanged converted signature must not use a known lossy fallback when its AP proof exceeds depth32.")
        } catch {
            // AtomicPDFWriter wraps the typed preservation error; both source
            // and existing destination byte identity are the commit oracle.
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        XCTAssertEqual(try Data(contentsOf: destination), existing)
        XCTAssertEqual(source.page(at: 0)?.annotations.first?.type, "Widget")
    }

    func testFrozenOriginalCannotEmbedLaterDifferentURLBytesAsItsSignedInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-sig-input-binding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.pdf"), output = directory.appendingPathComponent("output.pdf")
        let old = signatureBytes(hidden: true), replacement = signatureBytes(hidden: true, boxHeight: "126")
        try old.write(to: input, options: .withoutOverwriting)
        let source = try PDFSourceFileAccess.loadDocument(at: input).document
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source)), owner = try XCTUnwrap(source.documentRef)
        let native = try annotationDictionary(XCTUnwrap(source.page(at: 0)), index: 0)
        try await Task.detached {
            XCTAssertNotNil(try raw.signatureInputDigest(in: owner))
            XCTAssertNotNil(try raw.exactAnnotationAppearance(in: owner, pageIndex: 0, annotationIndex: 0, annotation: native))
        }.value
        // This mutation is confined to this generated test fixture. The live
        // reader/raw context still represent the earlier immutable input.
        try replacement.write(to: input, options: .atomic)
        XCTAssertNotEqual(old, replacement)
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 1])
        let snapshot = try PDFRecoverySnapshot(capturing: extracted)
        let refused = try await Task.detached { () throws -> Bool in
            let document = try snapshot.takeDocument()
            do { _ = try PDFCatalogStructurePreserver.plan(for: document); return false }
            catch PDFPageStructurePreserver.Failure.unsupportedStructure { return true }
        }.value
        XCTAssertTrue(refused)
        XCTAssertEqual(try Data(contentsOf: input), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testUnchangedSignatureWithOversizedSignedInputFailsClosedAfterExactAPProof() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-sig-input-budget-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.pdf"), destination = directory.appendingPathComponent("existing.pdf")
        // A fully indexed valid indirect stream, not junk after EOF. It is
        // unused by painting but remains part of the original signed bytes.
        let bytes = signatureBytes(hidden: true, paddingBytes: 64 * 1_024 * 1_024 + 4_096)
        XCTAssertGreaterThan(bytes.count, 64 * 1_024 * 1_024)
        XCTAssertLessThan(bytes.count, 256 * 1_024 * 1_024)
        try bytes.write(to: input, options: .withoutOverwriting)
        let existing = signatureBytes(hidden: false)
        try existing.write(to: destination, options: .withoutOverwriting)
        let source = try PDFSourceFileAccess.loadDocument(at: input).document
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source)), owner = try XCTUnwrap(source.documentRef)
        let native = try annotationDictionary(XCTUnwrap(source.page(at: 0)), index: 0)
        try await Task.detached {
            XCTAssertNotNil(try raw.exactAnnotationAppearance(in: owner, pageIndex: 0, annotationIndex: 0, annotation: native),
                "Strict raw parsing and the small AP proof must succeed before the signed-input budget refusal.")
        }.value
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 1])
        let snapshot = try PDFRecoverySnapshot(capturing: extracted)
        do {
            try await Task.detached {
                let document = try snapshot.takeDocument()
                XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: document)) { error in
                    XCTAssertEqual(error as? PDFPageStructurePreserver.Failure, .unsupportedStructure)
                }
                try AtomicPDFWriter.write(document, to: destination, allowDirectOverwriteFallback: false)
            }.value
            XCTFail("Oversized signed input must not silently choose lossy SDK serialization after exact AP proof.")
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        XCTAssertEqual(try Data(contentsOf: destination), existing)
        XCTAssertEqual(source.page(at: 0)?.annotations.first?.type, "Widget")
    }

    private func name(_ annotation: PDFAnnotation, original: CGPDFDictionaryRef) throws -> PDFPageGeometryPreserver.AnnotationName? {
        let geometry = try PDFPageGeometryPreserver.liveAnnotation(annotation)
        var bytes = 8 * 1024 * 1024, coordinates = 2_000_000
        return try PDFPageGeometryPreserver.annotationName(annotation, original: original, currentGeometry: geometry,
            chosenGeometry: geometry, remainingBytes: &bytes, remainingCurrentCoordinates: &coordinates)
    }
    private func savedOnWorker(_ document: PDFDocument, at url: URL) async throws -> PDFDocument {
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let onMain = try await Task.detached(priority: .userInitiated) {
            let onMain = Thread.isMainThread
            try AtomicPDFWriter.write(snapshot.takeDocument(), to: url, allowDirectOverwriteFallback: false)
            return onMain
        }.value
        XCTAssertFalse(onMain)
        return try XCTUnwrap(PDFDocument(url: url))
    }
    private func assertInactive(_ document: PDFDocument, at index: Int, originalAppearance: Data, originalGraph: [String: Any], originalPixels: Data) throws {
        let page = try XCTUnwrap(document.page(at: index)), annotation = try XCTUnwrap(page.annotations.first)
        XCTAssertEqual(annotation.type, "Stamp")
        let dictionary = try annotationDictionary(page, index: 0)
        for key in ["FT", "V", "DV", "T", "TU", "Parent", "Kids", "Lock", "SV"] { XCTAssertNil(PDFCatalogStructurePreserver.object(dictionary, key), key) }
        XCTAssertNil(PDFCatalogStructurePreserver.object(dictionary, "NM"))
        let savedAppearance = try appearance(dictionary), savedPixels = try appearancePixels(dictionary)
        let observation: [String: Any] = ["originalStreamUTF8": String(data: originalAppearance, encoding: .utf8) ?? "<nonUTF8>",
            "savedStreamUTF8": String(data: savedAppearance, encoding: .utf8) ?? "<nonUTF8>",
            "originalGraph": originalGraph, "savedGraph": try appearanceGraph(dictionary),
            "exactAppearanceFormRGBEqual": originalPixels == savedPixels,
            "originalColoredPixels": coloredPixels(originalPixels), "savedColoredPixels": coloredPixels(savedPixels),
            "annotationRect": [annotation.bounds.minX, annotation.bounds.minY, annotation.bounds.maxX, annotation.bounds.maxY]]
        print("QE_SIG_AP_OBSERVATION", String(data: try JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]), encoding: .utf8)!)
        XCTAssertEqual(savedPixels, originalPixels, "The actual AP Form and its own resource graph must render identically after both saves.")
        XCTAssertEqual(try appearanceGraph(dictionary) as NSDictionary, originalGraph as NSDictionary)
        XCTAssertNotNil(PDFSignatureAppearancePreserver.Record(dictionary))
        XCTAssertEqual(savedAppearance, originalAppearance)
    }
    /// Render the actual native AP Form, including its own BBox/Matrix and
    /// resource graph, through a new plain page. This avoids offscreen/rotated
    /// annotation coordinates yielding a meaningless all-white equality.
    private func appearancePixels(_ annotation: CGPDFDictionaryRef) throws -> Data {
        let ap = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(annotation, "AP"))
        let normal = try XCTUnwrap(PDFCatalogStructurePreserver.object(ap, "N"))
        XCTAssertEqual(CGPDFObjectGetType(normal), .stream)
        let painting = "q /ActualAppearance Do Q\n"
        let wrapper = pdf(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 75 125] /Resources << >> /Contents 4 0 R >>",
            "<< /Length \(painting.utf8.count) >>\nstream\n\(painting)endstream"])
        let plain = try XCTUnwrap(PDFDocument(data: wrapper))
        var plan = PDFCatalogGraphPlan()
        plan.pageEntries[0] = ["Resources": .dictionary(["XObject": .dictionary(["ActualAppearance": .original(normal)])])]
        let owned = try PDFBodyTextPageSnapshot.preservingCatalog(in: wrapper, from: plain, plan: plan)
        let provider = try XCTUnwrap(CGDataProvider(data: owned as CFData)), native = try XCTUnwrap(CGPDFDocument(provider))
        let page = try XCTUnwrap(native.page(at: 1)), width = 150, height = 250
        var pixels = Data(count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
        }
        return pixels
    }
    private func coloredPixels(_ pixels: Data) -> Int {
        pixels.withUnsafeBytes { buffer in
            let values = buffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: values.count, by: 4).reduce(0) { count, i in
                count + ((values[i] < 250 || values[i + 1] < 250 || values[i + 2] < 250) ? 1 : 0)
            }
        }
    }
    private func appearanceGraph(_ annotation: CGPDFDictionaryRef) throws -> [String: Any] {
        let ap = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(annotation, "AP"))
        var stream: CGPDFStreamRef?; XCTAssertTrue(CGPDFDictionaryGetStream(ap, "N", &stream))
        let d = try XCTUnwrap(CGPDFStreamGetDictionary(XCTUnwrap(stream)))
        var result: [String: Any] = ["APDictionaryEntries": CGPDFDictionaryGetCount(ap), "NDictionaryEntries": CGPDFDictionaryGetCount(d)]
        for key in ["BBox", "Matrix"] {
            if let a = PDFCatalogStructurePreserver.array(d, key) {
                let count = CGPDFArrayGetCount(a); XCTAssertLessThanOrEqual(count, 6)
                result[key] = try (0..<count).map { index -> Double in
                    var n: CGPDFReal = 0; XCTAssertTrue(CGPDFArrayGetNumber(a, index, &n)); return Double(n)
                }
            } else { result[key] = NSNull() }
        }
        result["ResourcesCount"] = PDFCatalogStructurePreserver.dictionary(d, "Resources").map { CGPDFDictionaryGetCount($0) as Any } ?? NSNull()
        return result
    }
    private func embeddedSignedOriginal(_ document: PDFDocument) throws -> Data {
        let catalog = try XCTUnwrap(document.documentRef?.catalog)
        let associated = try XCTUnwrap(PDFCatalogStructurePreserver.array(catalog, "AF"))
        var spec: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(associated, 0, &spec))
        let embedded = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(XCTUnwrap(spec), "EF"))
        var stream: CGPDFStreamRef?; XCTAssertTrue(CGPDFDictionaryGetStream(embedded, "F", &stream))
        var format = CGPDFDataFormat.raw
        return try XCTUnwrap(CGPDFStreamCopyData(XCTUnwrap(stream), &format)) as Data
    }
    private func annotationDictionary(_ page: PDFPage, index: Int) throws -> CGPDFDictionaryRef {
        let dictionary = try XCTUnwrap(page.pageRef?.dictionary)
        let array = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "Annots"))
        var value: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(array, index, &value)); return try XCTUnwrap(value)
    }
    private func nativeName(_ dictionary: CGPDFDictionaryRef, _ key: String) throws -> String {
        var value: UnsafePointer<CChar>?; XCTAssertTrue(CGPDFDictionaryGetName(dictionary, key, &value)); return String(cString: try XCTUnwrap(value))
    }
    private func appearance(_ dictionary: CGPDFDictionaryRef) throws -> Data {
        let ap = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(dictionary, "AP"))
        var stream: CGPDFStreamRef?; XCTAssertTrue(CGPDFDictionaryGetStream(ap, "N", &stream))
        var format = CGPDFDataFormat.raw
        return try XCTUnwrap(CGPDFStreamCopyData(XCTUnwrap(stream), &format)) as Data
    }
    private func ordinary(name: String?, subtype: String = "Square", fieldType: String? = nil) throws -> PDFDocument {
        let bytes = pdf(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /\(subtype) /Rect [10 20 40 50] \(fieldType.map { "/FT /" + $0 + " /T (control)" } ?? "") \(name.map { "/NM " + $0 } ?? "") >>"])
        return try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
    }
    private func signatureBytes(hidden: Bool, name: String? = nil, signed: Bool = true, boxHeight: String = "125", extraResource: String = "", paddingBytes: Int = 0) -> Data {
        let rotation = hidden ? 0 : 270, rect = hidden ? "-10 -10 -10 -10" : "767.04 431.2127 842.04 556.2127"
        let page = hidden ? 3 : 4, mark = hidden ? 0 : 1
        let painting = "q 0 0 1 rg 10 20 30 40 re f Q\n", appearance = "q /Alpha gs 1 0 0 rg 0 0 75 125 re f Q\n"
        var objects = ["<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R] /SigFlags 3 >> >>",
            "<< /Type /Pages /Count 2 /Kids [3 0 R 4 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 842.04 595.44] /Rotate \(rotation) /Resources << >> /Contents 5 0 R \(mark == 0 ? "/Annots [6 0 R]" : "") >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 842.04 595.44] /Rotate \(rotation) /Resources << >> /Contents 5 0 R \(mark == 1 ? "/Annots [6 0 R]" : "") >>",
            "<< /Length \(painting.utf8.count) >>\nstream\n\(painting)endstream",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Signature1) /P \(page) 0 R /Rect [\(rect)] /F 4 /AP << /N 7 0 R >> \(name.map { "/NM " + $0 } ?? "") \(signed ? "/V 8 0 R" : "") >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 75 \(boxHeight)] /Matrix [1 0 0 1 0 0] /Resources << /ExtGState << /Alpha << /Type /ExtGState /ca 1 /CA 1 >> >> \(extraResource) >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)endstream",
            // Synthetic signature metadata exercises preservation, never cryptographic validity.
            "<< /Type /Sig /ByteRange [0 0 0 0] /Contents <00> >>"]
        if paddingBytes > 0 {
            objects.append("<< /Length \(paddingBytes) >>\nstream\n" + String(repeating: " ", count: paddingBytes) + "\nendstream")
        }
        return pdf(objects)
    }
    private func pdf(_ objects: [String]) -> Data {
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count; data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8)); return data
    }
}
