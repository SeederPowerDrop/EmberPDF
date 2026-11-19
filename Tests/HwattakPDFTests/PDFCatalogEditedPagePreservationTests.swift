// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFCatalogEditedPagePreservationTests: XCTestCase {
    func testBodyEditRetainsLabelsAttachmentAndOpeningDestinationWithoutOldPainting() throws {
        let fixture = try workspaceFixture(firstTagged: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let document = try XCTUnwrap(fixture.workspace.document)
        let original = try XCTUnwrap(document.page(at: 0))
        let untouched = try XCTUnwrap(document.page(at: 1))
        let annotation = try XCTUnwrap(original.annotations.first)
        try edit("Original first", to: "Changed first", in: fixture.workspace)
        XCTAssertFalse(document.page(at: 0) === original)
        XCTAssertTrue(document.page(at: 1) === untouched)
        XCTAssertTrue(document.page(at: 0)?.annotations.first === annotation)
        let saved = try savedDocument(document, in: fixture.directory, name: "changed")
        try assertCatalog(saved, labels: ["iv", "v"])
        XCTAssertEqual(saved.findString("Changed first", withOptions: []).count, 1)
        XCTAssertTrue(saved.findString("Original first", withOptions: []).isEmpty)
        XCTAssertEqual(saved.findString("Original second", withOptions: []).count, 1)
        XCTAssertEqual(try taggedPageIndexes(saved), [1])
        try assertNoStaleTagKeys(on: XCTUnwrap(saved.page(at: 0)))
        // The retained Form paints an unrelated colored rectangle.
        XCTAssertEqual(try rectanglePixels(XCTUnwrap(saved.page(at: 0))), try rectanglePixels(original))
        let native = try XCTUnwrap(saved.documentRef)
        var action: CGPDFArrayRef?, target: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(native.catalog), "OpenAction", &action))
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(action), 0, &target))
        XCTAssertEqual(pdfReferenceIdentity(try XCTUnwrap(target)), pdfReferenceIdentity(try XCTUnwrap(native.page(at: 1)?.dictionary)))
        XCTAssertTrue(fixture.workspace.isDirty)
        XCTAssertNil(fixture.workspace.presentedError)
    }

    func testUndoAndRedoRestoreOriginalTagsAndContentWhileRetainingCatalog() throws {
        let fixture = try workspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let document = try XCTUnwrap(workspace.document)
        let original = try XCTUnwrap(document.page(at: 0))
        try edit("Original first", to: "Changed first", in: workspace)
        let edited = try XCTUnwrap(document.page(at: 0))
        try assertSaveRefused(document, in: fixture.directory, name: "before-undo")
        workspace.undo()
        XCTAssertTrue(document.page(at: 0) === original)
        XCTAssertFalse(workspace.isDirty)
        let undone = try savedDocument(document, in: fixture.directory, name: "undone")
        try assertCatalog(undone, labels: ["iv", "v"])
        XCTAssertEqual(undone.findString("Original first", withOptions: []).count, 1)
        XCTAssertTrue(undone.findString("Changed first", withOptions: []).isEmpty)
        XCTAssertEqual(try taggedPageIndexes(undone), [0, 1])
        workspace.redo()
        XCTAssertTrue(document.page(at: 0) === edited)
        XCTAssertTrue(workspace.isDirty)
        try assertSaveRefused(document, in: fixture.directory, name: "redone")
        XCTAssertEqual(document.findString("Changed first", withOptions: []).count, 1)
        XCTAssertTrue(document.findString("Original first", withOptions: []).isEmpty)
        XCTAssertNil(workspace.presentedError)
    }

    func testReplacingEveryTaggedPageRefusesAnIncompleteSave() throws {
        let fixture = try workspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try edit("Original first", to: "Changed first", in: fixture.workspace)
        try edit("Original second", to: "Changed second", in: fixture.workspace)
        let document = try XCTUnwrap(fixture.workspace.document)
        try assertSaveRefused(document, in: fixture.directory, name: "all-edited")
        for page in ["first", "second"] {
            XCTAssertEqual(document.findString("Changed " + page, withOptions: []).count, 1)
            XCTAssertTrue(document.findString("Original " + page, withOptions: []).isEmpty)
        }
        XCTAssertNil(fixture.workspace.presentedError)
    }

    func testRepeatedEditAndExtractionKeepMetadataWithoutRevivingSourceContent() throws {
        let fixture = try workspaceFixture(firstTagged: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try edit("Original first", to: "Changed first", in: fixture.workspace)
        try edit("Changed first", to: "Final first", in: fixture.workspace)
        let source = try XCTUnwrap(fixture.workspace.document)
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
        let saved = try savedDocument(extracted, in: fixture.directory, name: "extracted-edited")
        try assertCatalog(saved, labels: ["iv"])
        XCTAssertEqual(saved.findString("Final first", withOptions: []).count, 1)
        XCTAssertTrue(saved.findString("Original first", withOptions: []).isEmpty)
        XCTAssertTrue(saved.findString("Changed first", withOptions: []).isEmpty)
        XCTAssertEqual(try taggedPageIndexes(saved), [])
        try assertNoStaleTagKeys(on: XCTUnwrap(saved.page(at: 0)))
        XCTAssertEqual(source.pageCount, 2)
    }

    private func edit(_ phrase: String, to text: String, in workspace: PDFWorkspaceState) throws {
        let document = try XCTUnwrap(workspace.document)
        let selection = try XCTUnwrap(document.findString(phrase, withOptions: []).first)
        XCTAssertTrue(workspace.requestBodyTextEdit(selection: selection), workspace.presentedError ?? "Body editing did not start")
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.commitPendingInlineText(id: draft.id, text: text, style: draft.style, bounds: draft.bounds)
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertNil(workspace.presentedError)
    }

    private func savedDocument(_ document: PDFDocument, in directory: URL, name: String) throws -> PDFDocument {
        let url = directory.appendingPathComponent(name + ".pdf")
        try AtomicPDFWriter.write(document, to: url)
        return try XCTUnwrap(PDFDocument(url: url))
    }

    private func assertSaveRefused(_ document: PDFDocument, in directory: URL, name: String) throws {
        let url = directory.appendingPathComponent(name + ".pdf")
        XCTAssertThrowsError(try AtomicPDFWriter.write(document, to: url)) { error in
            XCTAssertEqual((error as? PDFCatalogStructurePreserver.EditedPageTagSaveFailure)?.pageNumber, 1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func assertCatalog(_ document: PDFDocument, labels: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual((0..<document.pageCount).map { document.page(at: $0)?.label }, labels.map(Optional.some), file: file, line: line)
        let catalog = try XCTUnwrap(document.documentRef?.catalog)
        var names: CGPDFDictionaryRef?, files: CGPDFDictionaryRef?, entries: CGPDFArrayRef?, specification: CGPDFDictionaryRef?, embedded: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "Names", &names), file: file, line: line)
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(names), "EmbeddedFiles", &files), file: file, line: line)
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(files), "Names", &entries), file: file, line: line)
        XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(entries)), 2, file: file, line: line)
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(entries), 1, &specification), file: file, line: line)
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(specification), "EF", &embedded), file: file, line: line)
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(embedded), "F", &stream), file: file, line: line)
        var format = CGPDFDataFormat.raw
        let bytes = try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(stream), &format)) as Data
        XCTAssertEqual(bytes, Data("catalog attachment survives body edits".utf8), file: file, line: line)
    }

    /// Walks only /K and explicit /Pg references; /P would cycle back to root.
    private func taggedPageIndexes(_ document: PDFDocument) throws -> [Int] {
        let native = try XCTUnwrap(document.documentRef)
        var root: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(try XCTUnwrap(native.catalog), "StructTreeRoot", &root), let root else { return [] }
        var pages: [UInt: Int] = [:]
        for index in 0..<document.pageCount {
            pages[pdfReferenceIdentity(try XCTUnwrap(native.page(at: index + 1)?.dictionary))] = index
        }
        var seen = Set<UInt>(), found = Set<Int>(), visits = 0
        func visit(_ value: CGPDFObjectRef, inherited: Int?, depth: Int) throws {
            visits += 1
            guard depth < 64, visits < 1_000 else { throw NSError(domain: "EditedPageTests", code: 1) }
            switch CGPDFObjectGetType(value) {
            case .array:
                var array: CGPDFArrayRef?
                guard CGPDFObjectGetValue(value, .array, &array), let array else { return XCTFail("Invalid tag array") }
                for index in 0..<CGPDFArrayGetCount(array) {
                    var child: CGPDFObjectRef?
                    if CGPDFArrayGetObject(array, index, &child), let child { try visit(child, inherited: inherited, depth: depth + 1) }
                }
            case .dictionary:
                var dictionary: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary else { return XCTFail("Invalid tag dictionary") }
                guard seen.insert(pdfReferenceIdentity(dictionary)).inserted else { return }
                var page: CGPDFDictionaryRef?, child: CGPDFObjectRef?, mcid: CGPDFObjectRef?, target: CGPDFObjectRef?
                let current = CGPDFDictionaryGetDictionary(dictionary, "Pg", &page) ? page.flatMap { pages[pdfReferenceIdentity($0)] } : inherited
                if (CGPDFDictionaryGetObject(dictionary, "MCID", &mcid) || CGPDFDictionaryGetObject(dictionary, "Obj", &target)), let current { found.insert(current) }
                if CGPDFDictionaryGetObject(dictionary, "K", &child), let child { try visit(child, inherited: current, depth: depth + 1) }
            case .integer:
                if let inherited { found.insert(inherited) }
            default: break
            }
        }
        var children: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(root, "K", &children), let children { try visit(children, inherited: nil, depth: 0) }
        return found.sorted()
    }

    private func assertNoStaleTagKeys(on page: PDFPage) throws {
        let dictionary = try XCTUnwrap(page.pageRef?.dictionary)
        func absent(_ dictionary: CGPDFDictionaryRef, _ key: String) {
            var value: CGPDFObjectRef?
            XCTAssertFalse(CGPDFDictionaryGetObject(dictionary, key, &value), "Edited content retains obsolete /" + key)
        }
        absent(dictionary, "StructParents")
        var annotations: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations {
            for index in 0..<CGPDFArrayGetCount(annotations) {
                var annotation: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation { absent(annotation, "StructParent") }
            }
        }
        var resources: CGPDFDictionaryRef?, forms: CGPDFDictionaryRef?, form: CGPDFStreamRef?
        if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
           CGPDFDictionaryGetDictionary(resources, "XObject", &forms), let forms,
           CGPDFDictionaryGetStream(forms, "Fm", &form), let form, let formDictionary = CGPDFStreamGetDictionary(form) {
            absent(formDictionary, "StructParents")
            absent(formDictionary, "StructParent")
        }
    }

    private func rectanglePixels(_ page: PDFPage) throws -> Data {
        let width = 70, height = 50
        var bytes = Data(count: width * height * 4)
        let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: -280, y: -20)
            page.draw(with: .mediaBox, to: context)
            return true
        }
        XCTAssertTrue(success)
        return bytes
    }

    private func workspaceFixture(firstTagged: Bool = true) throws -> (workspace: PDFWorkspaceState, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-edited-catalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let attachment = "catalog attachment survives body edits"
        func stream(_ contents: String, entries: String = "") -> String {
            "<< /Length \(contents.utf8.count) \(entries) >>\nstream\n\(contents)\nendstream"
        }
        let firstText = "BT /F1 20 Tf 1 0 0 1 40 300 Tm (Original first) Tj ET"
        let first = (firstTagged ? "/P << /MCID 0 >> BDC \(firstText) EMC" : firstText) + " q /Fm Do Q"
        let second = "/P << /MCID 0 >> BDC BT /F1 20 Tf 1 0 0 1 40 300 Tm (Original second) Tj ET EMC"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /r /St 4 >>] >> /StructTreeRoot 8 0 R /MarkInfo << /Marked true >> /Lang (en) /Names << /EmbeddedFiles << /Names [(notes.txt) 17 0 R] >> >> /AF [17 0 R] /OpenAction [3 0 R /Fit] >>",
            "<< /Type /Pages /Count 2 /Kids [3 0 R 4 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 420] /Resources << /Font << /F1 7 0 R >> /XObject << /Fm 14 0 R >> >> /Contents 5 0 R \(firstTagged ? "/StructParents 0" : "") /Annots [12 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 420] /Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R /StructParents 1 >>",
            stream(first), stream(second),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /StructTreeRoot /K [\(firstTagged ? "9 0 R 10 0 R 11 0 R 13 0 R" : "10 0 R")] /ParentTree 15 0 R /ParentTreeNextKey 4 >>",
            "<< /Type /StructElem /S /P /P 8 0 R /Pg 3 0 R /K 0 >>",
            "<< /Type /StructElem /S /P /P 8 0 R /Pg 4 0 R /K 0 >>",
            "<< /Type /StructElem /S /Annot /P 8 0 R /Pg 3 0 R /K << /Type /OBJR /Pg 3 0 R /Obj 12 0 R >> >>",
            "<< /Type /Annot /Subtype /Square /Rect [20 20 70 60] /C [1 0 0] /F 4 \(firstTagged ? "/StructParent 3" : "") /Contents (Kept note) >>",
            "<< /Type /StructElem /S /Figure /P 8 0 R /Pg 3 0 R /K << /Type /MCR /Pg 3 0 R /Stm 14 0 R /MCID 0 >> >>",
            stream(firstTagged ? "/Figure << /MCID 0 >> BDC 0.1 0.2 0.8 rg 280 20 70 50 re f EMC" : "0.1 0.2 0.8 rg 280 20 70 50 re f", entries: "/Type /XObject /Subtype /Form /BBox [0 0 400 420] /Resources << >> \(firstTagged ? "/StructParents 2" : "")"),
            "<< /Nums [\(firstTagged ? "0 [9 0 R] 1 [10 0 R] 2 [13 0 R] 3 11 0 R" : "1 [10 0 R]")] >>",
            stream(attachment, entries: "/Type /EmbeddedFile"),
            "<< /Type /Filespec /F (notes.txt) /UF (notes.txt) /AFRelationship /Data /EF << /F 16 0 R >> >>"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let source = directory.appendingPathComponent("source.pdf")
        try data.write(to: source)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: source))
        workspace.setMode(.editing)
        return (workspace, directory)
    }
}
