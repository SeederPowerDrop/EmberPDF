// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextDirectSaveTests: XCTestCase {
    func testDetachedSnapshotBodySaveUsesTheProvenOriginalNativeGraph() throws {
        let live = try editedDocument()
        let snapshot = try PDFRecoverySnapshot(capturing: live).takeDocument()
        let data = try XCTUnwrap(PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(snapshot))
        let saved = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(saved.pageCount, 2)
        XCTAssertEqual(saved.findString("Changed first", withOptions: []).count, 1)
        XCTAssertTrue(saved.findString("Original first", withOptions: []).isEmpty)
        XCTAssertEqual(saved.findString("Original second", withOptions: []).count, 1)
        XCTAssertEqual((0..<2).map { saved.page(at: $0)?.label }, ["iv", "v"])
        XCTAssertEqual(saved.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Native body fixture")
        for index in 0..<snapshot.pageCount {
            XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(saved.page(at: index))),
                           try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(snapshot.page(at: index))))
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        try AtomicPDFWriter.write(snapshot, to: output)
        XCTAssertEqual(PDFDocument(url: output)?.findString("Changed first", withOptions: []).count, 1)
    }

    func testDetachedSnapshotCannotReuseTheOriginalAfterUnprovenLiveChanges() throws {
        for mutation in ["annotation", "metadata", "reorder", "rotation", "box", "outline"] {
            let snapshot = try PDFRecoverySnapshot(capturing: editedDocument()).takeDocument()
            let first = try XCTUnwrap(snapshot.page(at: 0))
            switch mutation {
            case "annotation":
                first.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
                                                   forType: .text, withProperties: nil))
            case "metadata":
                snapshot.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Explicit new title"]
            case "reorder":
                let second = try XCTUnwrap(snapshot.page(at: 1))
                snapshot.removePage(at: 1); snapshot.removePage(at: 0)
                snapshot.insert(second, at: 0); snapshot.insert(first, at: 1)
            case "rotation": first.rotation = 90
            case "box": first.setBounds(CGRect(x: 2, y: 3, width: 100, height: 120), for: .cropBox)
            default:
                let root = PDFOutline(), child = PDFOutline(); child.label = "Explicit new bookmark"
                child.destination = PDFDestination(page: first, at: .zero)
                root.insertChild(child, at: 0); snapshot.outlineRoot = root
            }
            XCTAssertNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(snapshot), mutation)
        }
    }

    func testBodyOnlySaveRetainsCatalogAndCurrentPaintingWithoutPDFKitRedrawing() throws {
        let document = try editedDocument()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(document))
        document.writeAttempts = 0
        try AtomicPDFWriter.write(document, to: url)
        XCTAssertEqual(document.writeAttempts, 0)
        let saved = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(saved.pageCount, 2)
        XCTAssertEqual(saved.findString("Changed first", withOptions: []).count, 1)
        XCTAssertTrue(saved.findString("Original first", withOptions: []).isEmpty)
        XCTAssertEqual(saved.findString("Original second", withOptions: []).count, 1)
        XCTAssertEqual((0..<2).map { saved.page(at: $0)?.label }, ["iv", "v"])
        XCTAssertEqual(saved.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Native body fixture")
        let native = try XCTUnwrap(saved.documentRef)
        var names: CGPDFDictionaryRef?, destinations: CGPDFDictionaryRef?, entries: CGPDFArrayRef?, target: CGPDFArrayRef?, page: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(native.catalog), "Names", &names))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(names), "Dests", &destinations))
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(destinations), "Names", &entries))
        XCTAssertTrue(CGPDFArrayGetArray(try XCTUnwrap(entries), 1, &target))
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(target), 0, &page))
        XCTAssertEqual(pdfReferenceIdentity(try XCTUnwrap(page)), pdfReferenceIdentity(try XCTUnwrap(native.page(at: 1)?.dictionary)))
    }

    func testUnmarkedOrChangedPageStructureDoesNotUseTheDirectRoute() throws {
        XCTAssertNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(try fixture()))
        let reordered = try editedDocument()
        let first = try XCTUnwrap(reordered.page(at: 0)), second = try XCTUnwrap(reordered.page(at: 1))
        reordered.removePage(at: 1); reordered.removePage(at: 0)
        reordered.insert(second, at: 0); reordered.insert(first, at: 1)
        XCTAssertNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(reordered))
        let removed = try editedDocument()
        removed.removePage(at: 1)
        XCTAssertNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(removed))
        let inserted = try editedDocument()
        inserted.insert(try XCTUnwrap(try fixture().page(at: 0)?.copy() as? PDFPage), at: 1)
        XCTAssertNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(inserted))
        let unproven = try editedDocument()
        unproven.removePage(at: 1)
        unproven.insert(try XCTUnwrap(try fixture().page(at: 0)?.copy() as? PDFPage), at: 1)
        XCTAssertNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(unproven))
    }

    func testLiveOrOriginalAnnotationsAndOutlinesKeepTheExistingSaveRoute() throws {
        let annotated = try editedDocument()
        annotated.page(at: 1)?.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
                                                          forType: .text, withProperties: nil))
        XCTAssertNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(annotated))
        let removedAnnotation = try editedDocument(nativeAnnotation: true)
        let page = try XCTUnwrap(removedAnnotation.page(at: 0))
        for annotation in page.annotations { page.removeAnnotation(annotation) }
        XCTAssertNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(removedAnnotation))
        let outlined = try editedDocument()
        let root = PDFOutline(), child = PDFOutline()
        child.label = "Current bookmark"
        child.destination = PDFDestination(page: try XCTUnwrap(outlined.page(at: 0)), at: .zero)
        root.insertChild(child, at: 0); outlined.outlineRoot = root
        XCTAssertNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(outlined))
        let removedOutline = try editedDocument(nativeOutline: true)
        removedOutline.outlineRoot = nil
        XCTAssertNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(removedOutline))
    }

    func testMetadataGeometryFormsAndExplicitWriteOptionsAreNeverBypassed() throws {
        let metadata = try editedDocument()
        var attributes = metadata.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = "Current changed title"
        metadata.documentAttributes = attributes
        XCTAssertNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(metadata))
        let rotated = try editedDocument()
        rotated.page(at: 1)?.rotation = 90
        XCTAssertNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(rotated))
        let cropped = try editedDocument()
        cropped.page(at: 1)?.setBounds(CGRect(x: 5, y: 5, width: 380, height: 280), for: .cropBox)
        XCTAssertNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(cropped))
        XCTAssertNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(try editedDocument(nativeForm: true)))
        let document = try editedDocument()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try AtomicPDFWriter.write(document, to: url, writeOptions: [.userPasswordOption: "test"]))
        XCTAssertEqual(document.writeAttempts, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOriginalInheritedRotationCanBeRetainedButALiveChangeUsesNormalSaving() throws {
        let document = try fixture(preservedBody: true, inheritedRotation: 90)
        try PDFCatalogStructurePreserver.prepare(document, force: true)
        PDFCatalogStructurePreserver.refreshMarker(document)
        let bytes = try XCTUnwrap(PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(document))
        let saved = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertEqual(saved.page(at: 0)?.rotation, 90)
        XCTAssertEqual(saved.page(at: 1)?.rotation, 90)
        document.page(at: 1)?.rotation = 180
        XCTAssertNil(try PDFBodyTextPageSnapshot.directlyPreservingBodyContentsIfEligible(document))
    }

    private func editedDocument(nativeAnnotation: Bool = false, nativeOutline: Bool = false,
                                nativeForm: Bool = false) throws -> WriteTrackingDocument {
        let document = try fixture(nativeAnnotation: nativeAnnotation, nativeOutline: nativeOutline,
                                   nativeForm: nativeForm, preservedBody: true)
        let original = try XCTUnwrap(document.page(at: 0))
        let selected = try XCTUnwrap(document.findString("Original first", withOptions: []).first)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: original, selection: selected))
        let replacement = try PDFBodyTextEditor.replacementPage(for: original, target: target,
            text: "Changed first", style: target.style, bounds: target.bounds)
        try PDFCatalogStructurePreserver.prepare(document, force: true)
        PDFCatalogStructurePreserver.inheritMetadata(from: original, to: replacement)
        for annotation in replacement.annotations { replacement.removeAnnotation(annotation) }
        let annotations = original.annotations
        for annotation in annotations { original.removeAnnotation(annotation); replacement.addAnnotation(annotation) }
        document.removePage(at: 0); document.insert(replacement, at: 0)
        PDFCatalogStructurePreserver.refreshMarker(document)
        return document
    }

    private func fixture(nativeAnnotation: Bool = false, nativeOutline: Bool = false,
                         nativeForm: Bool = false, preservedBody: Bool = false,
                         inheritedRotation: Int? = nil) throws -> WriteTrackingDocument {
        let catalog = "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /r /St 4 >>] >>"
            + " /Names << /Dests << /Names [(start) [3 0 R /Fit]] >> >>"
            + (nativeOutline ? " /Outlines 10 0 R" : "") + (nativeForm ? " /AcroForm << /Fields [] >>" : "") + " >>"
        let objects = [Data(catalog.utf8),
            Data(("<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2"
                + (inheritedRotation.map { " /Rotate \($0)" } ?? "") + " >>").utf8),
            Data(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 6 0 R"
                + (nativeAnnotation ? " /Annots [9 0 R]" : "")
                + (preservedBody ? " /EmberPDFPreservePageContent true" : "") + " >>").utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 7 0 R >>".utf8),
            stream("BT /F1 16 Tf 1 0 0 1 40 230 Tm (Original first) Tj ET"),
            stream("BT /F1 16 Tf 1 0 0 1 40 230 Tm (Original second) Tj ET"),
            Data("<< /Title (Native body fixture) /Author (EmberPDF QA) /Keywords (preserve; body) /CreationDate (D:20261017090000+02'00') >>".utf8),
            Data("<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (Original annotation) >>".utf8),
            Data("<< /Type /Outlines /First 11 0 R /Last 11 0 R /Count 1 >>".utf8),
            Data("<< /Title (Original bookmark) /Parent 10 0 R /Dest [3 0 R /Fit] >>".utf8)]
        var data = Data("%PDF-1.7\n".utf8), offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n".utf8))
            data.append(object); data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 8 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(WriteTrackingDocument(data: data))
    }

    private func stream(_ text: String) -> Data {
        Data("<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream".utf8)
    }
}

private final class WriteTrackingDocument: PDFDocument {
    var writeAttempts = 0
    override func write(to url: URL) -> Bool { writeAttempts += 1; return super.write(to: url) }
    override func write(to url: URL, withOptions options: [PDFDocumentWriteOption: Any]? = nil) -> Bool {
        writeAttempts += 1; return super.write(to: url, withOptions: options)
    }
}
