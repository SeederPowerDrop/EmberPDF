// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

/// Integer-only intent controls. These do not assert or simulate SDK ULP drift.
@MainActor
final class PDFInkGeometryEditPriorityTests: XCTestCase {
    func testPreparedNamedInkGeometryEditSurvivesSnapshotWorkerAndPageExtraction() async throws {
        let source = try fixture()
        let page = try XCTUnwrap(source.page(at: 0))
        let ink = try XCTUnwrap(page.annotations.first)
        let sourceContents = ink.contents
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let before = try PDFPageGeometryPreserver.liveAnnotation(ink)
        try edit(ink, bounds: CGRect(x: 100, y: 120, width: 60, height: 60),
                 localPoints: [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 40), CGPoint(x: 60, y: 60)])
        let intended = try PDFPageGeometryPreserver.liveAnnotation(ink)
        XCTAssertNotEqual(intended, before, "The test must perform an observable geometry edit after capture.")
        let expectedRect: [Double] = [100, 120, 160, 180]
        let expectedInk: [Double] = [100, 120, 120, 160, 160, 180]

        let direct = try await writtenOnWorker(source)
        try assertRaw(direct, rectangle: expectedRect, ink: expectedInk)
        XCTAssertEqual(try PDFPageGeometryPreserver.liveAnnotation(ink), intended)
        XCTAssertTrue(page.annotations.first === ink)
        XCTAssertEqual(ink.value(forAnnotationKey: .init(rawValue: "/NM")) as? String, inkName)

        let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
        XCTAssertEqual(extracted.pageCount, 1)
        let extractedInk = try XCTUnwrap(extracted.page(at: 0)?.annotations.first)
        XCTAssertFalse(extractedInk === ink)
        XCTAssertEqual(try PDFPageGeometryPreserver.liveAnnotation(extractedInk), intended)
        let extractedBytes = try await writtenOnWorker(extracted)
        try assertRaw(extractedBytes, rectangle: expectedRect, ink: expectedInk)
        XCTAssertEqual(try PDFPageGeometryPreserver.liveAnnotation(ink), intended)
        XCTAssertEqual(source.pageCount, 1)
        XCTAssertTrue(source.page(at: 0) === page)
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertEqual(ink.contents, sourceContents)
        // The immutable input oracle remains the original program, rather than
        // acquiring the live edit through a shared parser or copied page.
        try assertRaw(fixtureData(), rectangle: [10, 20, 50, 60], ink: [10, 20, 30, 40, 50, 60])
    }

    func testCopyTargetInkEditBeforeInheritOrForwardWinsOverOriginalGeometry() async throws {
        for mode in ["page-copy", "document-copy"] {
            let source = try fixture()
            let originalPage = try XCTUnwrap(source.page(at: 0))
            let originalInk = try XCTUnwrap(originalPage.annotations.first)
            let sourceContents = originalInk.contents
            try PDFCatalogStructurePreserver.prepare(source, force: true)
            let unchangedSource = try PDFPageGeometryPreserver.liveAnnotation(originalInk)
            let target: PDFDocument
            let copiedPage: PDFPage
            if mode == "page-copy" {
                copiedPage = try XCTUnwrap(originalPage.copy() as? PDFPage)
                target = PDFDocument()
            } else {
                target = try XCTUnwrap(source.copy() as? PDFDocument)
                copiedPage = try XCTUnwrap(target.page(at: 0))
                XCTAssertFalse(target === source)
            }
            XCTAssertFalse(copiedPage === originalPage)
            let copiedInk = try XCTUnwrap(copiedPage.annotations.first)
            XCTAssertFalse(copiedInk === originalInk)
            // Keep the original rectangle, so the ordinary exact copy lineage
            // guards remain applicable. The three-point InkList still changes
            // observably before generic inherit/forward sees the target.
            try edit(copiedInk, bounds: CGRect(x: 10, y: 20, width: 40, height: 40),
                     localPoints: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 30), CGPoint(x: 40, y: 40)])
            let intended = try PDFPageGeometryPreserver.liveAnnotation(copiedInk)
            XCTAssertNotEqual(intended, unchangedSource, mode)
            XCTAssertEqual(try PDFPageGeometryPreserver.liveAnnotation(originalInk), unchangedSource, mode)
            if mode == "page-copy" {
                PDFCatalogStructurePreserver.inherit(from: originalPage, to: copiedPage)
                target.insert(copiedPage, at: 0)
            } else {
                PDFCatalogStructurePreserver.forward(from: source, to: target, force: true)
            }
            XCTAssertEqual(try PDFPageGeometryPreserver.liveAnnotation(copiedInk), intended, mode)
            let bytes = try await writtenOnWorker(target)
            try assertRaw(bytes, rectangle: [10, 20, 50, 60], ink: [10, 20, 20, 50, 50, 60])
            XCTAssertEqual(try PDFPageGeometryPreserver.liveAnnotation(copiedInk), intended, mode)
            XCTAssertEqual(try PDFPageGeometryPreserver.liveAnnotation(originalInk), unchangedSource, mode)
            XCTAssertTrue(source.page(at: 0) === originalPage, mode)
            XCTAssertTrue(originalPage.annotations.first === originalInk, mode)
            XCTAssertEqual(originalPage.annotations.count, 1, mode)
            XCTAssertEqual(originalInk.contents, sourceContents, mode)
            XCTAssertEqual(originalInk.value(forAnnotationKey: .init(rawValue: "/NM")) as? String, inkName, mode)
        }
    }

    private var inkName: String { "Named-geometry-intent" }

    private func edit(_ annotation: PDFAnnotation, bounds: CGRect, localPoints: [CGPoint]) throws {
        XCTAssertEqual(annotation.type, "Ink")
        let paths = try XCTUnwrap(annotation.paths)
        XCTAssertEqual(paths.count, 1)
        for path in paths { annotation.remove(path) }
        annotation.bounds = bounds
        let path = NSBezierPath()
        path.move(to: localPoints[0])
        for point in localPoints.dropFirst() { path.line(to: point) }
        annotation.add(path)
        XCTAssertEqual(annotation.bounds, bounds)
        XCTAssertEqual(annotation.paths?.count, 1)
        XCTAssertEqual(annotation.value(forAnnotationKey: .init(rawValue: "/NM")) as? String, inkName)
    }

    private func writtenOnWorker(_ document: PDFDocument) async throws -> Data {
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-Ink-Intent-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("saved.pdf")
        return try await Task.detached {
            guard !Thread.isMainThread else { throw PDFPageStructurePreserver.Failure.invalidCopy }
            try AtomicPDFWriter.write(snapshot.takeDocument(), to: output)
            return try Data(contentsOf: output)
        }.value
    }

    private func assertRaw(_ data: Data, rectangle: [Double], ink: [Double], file: StaticString = #filePath,
                           line: UInt = #line) throws {
        guard data.count < 1024 * 1024 else {
            XCTFail("The one-page synthetic output exceeded the explicit parser bound.", file: file, line: line)
            throw PDFPageStructurePreserver.Failure.tooComplex
        }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData), file: file, line: line)
        let document = try XCTUnwrap(CGPDFDocument(provider), file: file, line: line)
        XCTAssertEqual(document.numberOfPages, 1, file: file, line: line)
        let page = try XCTUnwrap(document.page(at: 1)?.dictionary, file: file, line: line)
        var annotations: CGPDFArrayRef?, dictionary: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(page, "Annots", &annotations), file: file, line: line)
        let list = try XCTUnwrap(annotations, file: file, line: line)
        XCTAssertEqual(CGPDFArrayGetCount(list), 1, file: file, line: line)
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &dictionary), file: file, line: line)
        let annotation = try XCTUnwrap(dictionary, file: file, line: line)
        var rawRect: CGPDFArrayRef?, rawInk: CGPDFArrayRef?, stroke: CGPDFArrayRef?, rawName: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(annotation, "Rect", &rawRect), file: file, line: line)
        XCTAssertTrue(CGPDFDictionaryGetArray(annotation, "InkList", &rawInk), file: file, line: line)
        XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(rawInk, file: file, line: line)), 1, file: file, line: line)
        XCTAssertTrue(CGPDFArrayGetArray(try XCTUnwrap(rawInk, file: file, line: line), 0, &stroke), file: file, line: line)
        try assertNumbers(XCTUnwrap(rawRect, file: file, line: line), equals: rectangle, file: file, line: line)
        try assertNumbers(XCTUnwrap(stroke, file: file, line: line), equals: ink, file: file, line: line)
        XCTAssertTrue(CGPDFDictionaryGetString(annotation, "NM", &rawName), file: file, line: line)
        let string = try XCTUnwrap(rawName, file: file, line: line)
        let expected = Data(inkName.utf8)
        let stringBytes = CGPDFStringGetLength(string)
        guard stringBytes <= 65_536 else { throw PDFPageStructurePreserver.Failure.tooComplex }
        XCTAssertEqual(stringBytes, expected.count, file: file, line: line)
        XCTAssertEqual(Data(bytes: try XCTUnwrap(CGPDFStringGetBytePtr(string), file: file, line: line),
                            count: stringBytes), expected, file: file, line: line)
    }

    private func assertNumbers(_ array: CGPDFArrayRef, equals expected: [Double], file: StaticString,
                               line: UInt) throws {
        XCTAssertEqual(CGPDFArrayGetCount(array), expected.count, file: file, line: line)
        for index in expected.indices {
            var value: CGPDFReal = 0
            XCTAssertTrue(CGPDFArrayGetNumber(array, index, &value), file: file, line: line)
            XCTAssertEqual(Double(value), expected[index], file: file, line: line)
        }
    }

    private func fixture() throws -> PDFDocument {
        let data = fixtureData()
        let document = try XCTUnwrap(PDFDocument(data: data))
        PDFRawStreamProvenance.bindCreated(document, data: data)
        XCTAssertTrue(PDFRawStreamProvenance.hasKnownNativeInput(document))
        return document
    }

    private func fixtureData() -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /D >>] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << >> /Contents 4 0 R /Annots [5 0 R] >>",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Type /Annot /Subtype /Ink /Rect [10 20 50 60] /InkList [[10 20 30 40 50 60]] /Contents (Synthetic geometry intent) /C [1 0 0] /BS << /W 1 >> /NM (Named-geometry-intent) >>"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
}
