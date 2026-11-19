// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFCatalogGeometryPreservationTests: XCTestCase {
    func testConvenienceQuadAndLocalInkKeepPageCoordinatesAndCurveAppearance() throws {
        let source = try coordinateFixture()
        let page = try XCTUnwrap(source.page(at: 0))
        let highlight = PDFAnnotation(bounds: CGRect(x: 75, y: 140, width: 80, height: 25), forType: .highlight, withProperties: nil)
        highlight.quadrilateralPoints = [CGPoint(x: 0, y: 25), CGPoint(x: 80, y: 25), .zero, CGPoint(x: 80, y: 0)]
            .map { NSValue(point: $0) }
        page.addAnnotation(highlight)
        for curved in [false, true] {
            let ink = PDFAnnotation(bounds: CGRect(x: 70, y: 120, width: 100, height: 80), forType: .ink, withProperties: nil)
            let path = NSBezierPath(); path.move(to: .zero)
            if curved { path.curve(to: CGPoint(x: 50, y: 20), controlPoint1: CGPoint(x: 15, y: 40), controlPoint2: CGPoint(x: 35, y: -10)) }
            else { path.line(to: CGPoint(x: 50, y: 20)) }
            ink.add(path); page.addAnnotation(ink)
        }
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
        let staged = try XCTUnwrap(PDFDocument(data: XCTUnwrap(extracted.dataRepresentation())))
        let appearance = try appearanceData(XCTUnwrap(staged.page(at: 0)), annotation: 3)
        let result = try written(extracted)
        let saved = try XCTUnwrap(result.page(at: 0))
        let annotations = try rawAnnotationArrays(saved)
        XCTAssertEqual(annotations.count, 4)
        XCTAssertEqual(annotations[1]["QuadPoints"], [75, 165, 155, 165, 75, 140, 155, 140])
        for index in [2, 3] {
            let dictionary = try annotationDictionary(saved, index: index)
            var list: CGPDFArrayRef?, stroke: CGPDFArrayRef?
            XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "InkList", &list))
            XCTAssertTrue(CGPDFArrayGetArray(try XCTUnwrap(list), 0, &stroke))
            XCTAssertEqual(try values(XCTUnwrap(stroke)), [70, 120, 120, 140])
            XCTAssertEqual(saved.annotations[index].bounds, CGRect(x: 70, y: 120, width: 100, height: 80))
        }
        // InkList records PDFKit's endpoint semantics; AP keeps the actual
        // cubic curve. Geometry repair must not flatten or rewrite that AP.
        XCTAssertEqual(try appearanceData(saved, annotation: 3), appearance)
    }

    func testNullOptionalBoxesKeepTheirDefaultMeaning() throws {
        let source = try document(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 354 485.4] >>",
            "<< /Type /Page /Parent 2 0 R /CropBox null /BleedBox null /TrimBox null /ArtBox null /Rotate null /Resources << >> /Contents 4 0 R >>",
            "<< /Length 0 >>\nstream\n\nendstream"
        ])
        let page = try XCTUnwrap(source.page(at: 0))
        for box: PDFDisplayBox in [.cropBox, .bleedBox, .trimBox, .artBox] {
            XCTAssertEqual(page.bounds(for: box), page.bounds(for: .mediaBox))
        }
        let output = try written(PDFPageOperations.extract(from: source, indexes: [0]))
        let result = try XCTUnwrap(output.page(at: 0))
        for box: PDFDisplayBox in [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
            XCTAssertEqual(result.bounds(for: box), page.bounds(for: box))
        }
        XCTAssertEqual(result.rotation, 0)
    }

    func testReversedBoxDiagonalsKeepRawNumbersAndTheirDisplayedRectangle() throws {
        let source = try document(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [354 485.4 0 0] /CropBox [300 450 12 24] /BleedBox [432 648 -10 -20] /Resources << >> /Contents 4 0 R >>",
            "<< /Length 0 >>\nstream\n\nendstream"
        ])
        let page = try XCTUnwrap(source.page(at: 0))
        XCTAssertGreaterThan(page.bounds(for: .mediaBox).width, 0)
        XCTAssertGreaterThan(page.bounds(for: .mediaBox).height, 0)
        let original = try geometryArrays(page)
        let output = try written(PDFPageOperations.extract(from: source, indexes: [0]))
        let result = try XCTUnwrap(output.page(at: 0))
        XCTAssertEqual(try geometryArrays(result), original)
        for box: PDFDisplayBox in [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
            XCTAssertEqual(result.bounds(for: box), page.bounds(for: box))
        }
    }

    func testAnnotatedAssemblyKeepsFractionalBoxesAndPageSpaceAnnotationProgram() throws {
        for rotation in [0, 90, 180, 270] {
            let source = try coordinateFixture(rotation: rotation)
            let original = try XCTUnwrap(source.page(at: 0))
            let before = try geometryArrays(original)
            let sourceContent = try PDFBodyTextPageSnapshot.contentData(for: original)
            let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
            let result = try written(extracted)
            let page = try XCTUnwrap(result.page(at: 0))
            XCTAssertEqual(try geometryArrays(page), before)
            XCTAssertEqual(page.rotation, rotation)
            XCTAssertEqual(try rawAnnotationArrays(page), try rawAnnotationArrays(original))
            XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: page), sourceContent)
            XCTAssertTrue((page.annotations[0].action as? PDFActionGoTo)?.destination.page === page
                || page.annotations[0].destination?.page === page)
            let merged = try fixture()
            let imported = try PDFPageStructurePreserver.prepareImport(from: extracted, indexes: [0])
            let transaction = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: merged, at: 1)
            try transaction.apply(); try transaction.undo(); XCTAssertEqual(merged.pageCount, 1)
            try transaction.redo()
            let final = try written(merged)
            XCTAssertEqual(try geometryArrays(XCTUnwrap(final.page(at: 1))), before)
            XCTAssertEqual(try rawAnnotationArrays(XCTUnwrap(final.page(at: 1))), try rawAnnotationArrays(original))
            XCTAssertEqual(try geometryArrays(original), before)
        }
    }

    func testEditedAndNewAnnotationCoordinatesWinOverOriginalCapture() throws {
        let source = try coordinateFixture()
        let page = try XCTUnwrap(source.page(at: 0))
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let link = try XCTUnwrap(page.annotations.first)
        link.bounds = CGRect(x: 93.123456789, y: 151.234567891, width: 62.345678912, height: 21.456789123)
        let quad: [Double] = [94.123456789, 171.234567891, 150.345678912, 171.234567891,
                              94.123456789, 153.456789123, 150.345678912, 153.456789123]
        XCTAssertTrue(link.setValue(quad, forAnnotationKey: PDFAnnotationKey(rawValue: "/QuadPoints")))
        let line = PDFAnnotation(bounds: CGRect(x: 100.123456789, y: 210.234567891, width: 90.345678912, height: 40.456789123),
                                 forType: .line, withProperties: nil)
        XCTAssertTrue(line.setValue([102.123456789, 212.234567891, 188.345678912, 248.456789123],
                                    forAnnotationKey: PDFAnnotationKey(rawValue: "/L")))
        page.addAnnotation(line)
        let lineCoordinates = [102.123456789, 212.234567891, 188.345678912, 248.456789123]
        let expected: [[String: [Double]]] = [
            ["Rect": rectangleNumbers(link.bounds), "QuadPoints": quad],
            ["Rect": rectangleNumbers(line.bounds), "L": lineCoordinates]
        ]
        let result = try written(PDFPageOperations.extract(from: source, indexes: [0]))
        let actual = try rawAnnotationArrays(XCTUnwrap(result.page(at: 0)))
        XCTAssertEqual(actual.count, expected.count)
        for (saved, current) in zip(actual, expected) {
            XCTAssertEqual(Set(saved.keys), Set(current.keys))
            for (key, coordinates) in current {
                let values = try XCTUnwrap(saved[key]); XCTAssertEqual(values.count, coordinates.count)
                for (a, b) in zip(values, coordinates) { XCTAssertEqual(a, b, accuracy: 1e-10, key) }
            }
        }
        XCTAssertEqual(link.bounds, CGRect(x: 93.123456789, y: 151.234567891, width: 62.345678912, height: 21.456789123))
        XCTAssertEqual(page.annotations.count, 2)
    }

    func testIntentionalCropAndRotationRemainCurrentAfterGeometryCapture() throws {
        let source = try coordinateFixture()
        let page = try XCTUnwrap(source.page(at: 0))
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let crop = CGRect(x: 55.25, y: 90.5, width: 180.75, height: 210.125)
        page.setBounds(crop, for: .cropBox); page.rotation = 90
        let result = try written(PDFPageOperations.extract(from: source, indexes: [0]))
        let saved = try XCTUnwrap(result.page(at: 0))
        XCTAssertEqual(saved.bounds(for: .cropBox), crop)
        XCTAssertEqual(saved.rotation, 90)
        XCTAssertEqual(page.bounds(for: .cropBox), crop)
        XCTAssertEqual(page.rotation, 90)
        XCTAssertEqual(try rawAnnotationArrays(saved), try rawAnnotationArrays(page))
    }

    func testRawDecimalAndAbsentBoxesSurviveWithoutReconstructingMaxY() throws {
        let source = try document(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 354 485.4] /Resources << >> /Contents 4 0 R >>",
            "<< /Length 0 >>\nstream\n\nendstream"
        ])
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
        let bytes = try PDFBodyTextPageSnapshot.preservingCatalog(in: XCTUnwrap(extracted.dataRepresentation()),
            from: extracted, plan: PDFCatalogStructurePreserver.plan(for: extracted))
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertNotNil(text.range(of: #"/MediaBox\s*\[0 0 354 485\.4\]"#, options: .regularExpression))
        let result = try XCTUnwrap(PDFDocument(data: bytes))
        let dictionary = try XCTUnwrap(result.page(at: 0)?.pageRef?.dictionary)
        for key in ["CropBox", "BleedBox", "TrimBox", "ArtBox", "Rotate"] {
            XCTAssertNil(PDFCatalogStructurePreserver.object(dictionary, key), key)
        }
    }

    func testUnannotatedAssemblyRetainsOriginalBoxesAndDoublePrecision() throws {
        let source = try fixture()
        let original = try XCTUnwrap(source.page(at: 0))
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
        let bytes = try PDFBodyTextPageSnapshot.preservingCatalog(
            in: XCTUnwrap(extracted.dataRepresentation()), from: extracted,
            plan: PDFCatalogStructurePreserver.plan(for: extracted))
        let result = try XCTUnwrap(PDFDocument(data: bytes))
        let page = try XCTUnwrap(result.page(at: 0))
        for box: PDFDisplayBox in [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
            XCTAssertEqual(page.bounds(for: box), original.bounds(for: box))
        }
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 3071.9999999999995)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: page),
                       try PDFBodyTextPageSnapshot.contentData(for: original))
    }

    func testImportedDictionaryNumbersRetainSmallNonzeroValuesWithoutExponents() throws {
        let source = try fixture()
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
        let bytes = try PDFBodyTextPageSnapshot.preservingCatalog(
            in: XCTUnwrap(extracted.dataRepresentation()), from: extracted,
            plan: PDFCatalogStructurePreserver.plan(for: extracted))
        let document = try XCTUnwrap(PDFDocument(data: bytes))
        let page = try XCTUnwrap(document.page(at: 0)?.pageRef?.dictionary)
        let piece = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(page, "PieceInfo"))
        var small: CGPDFReal = 0, large: CGPDFReal = 0
        XCTAssertTrue(CGPDFDictionaryGetNumber(piece, "Small", &small))
        XCTAssertTrue(CGPDFDictionaryGetNumber(piece, "Large", &large))
        XCTAssertEqual(small, 1e-12)
        XCTAssertEqual(large, 1e18)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("/Small 0.000000000001"))
        XCTAssertFalse(text.contains("1e-12"))
        XCTAssertFalse(text.contains("1e+18"))
    }

    private func fixture() throws -> PDFDocument {
        let content = "q 0.25 0.5 0.75 rg 20 30 80 90 re f Q"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /r >>] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2304 3071.9999999999995] /CropBox [2 7.7801 2300 3060] /TrimBox [3 9 2290 3050] /BleedBox [0 0 2304 3071.9999999999995] /ArtBox [5 12 2280 3040] /Resources << >> /Contents 4 0 R /PieceInfo << /Small 0.000000000001 /Large 1000000000000000000.5 >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ]
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: bytes))
    }

    private func written(_ document: PDFDocument) throws -> PDFDocument {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-Geometry-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("saved.pdf")
        try AtomicPDFWriter.write(document, to: url)
        return try XCTUnwrap(PDFDocument(data: Data(contentsOf: url)))
    }

    private func coordinateFixture(rotation: Int = 0) throws -> PDFDocument {
        let content = "q 0.25 0.5 0.75 rg 70 130 80 35 re f Q"
        return try document(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [13.144 29.72 323.144 389.72] /CropBox [43.144 71.72 283.144 331.72] /BleedBox [0 0 432 648] /TrimBox [3 7 350 430] /ArtBox [5 9 340 420] /Rotate \(rotation) /Resources << >> /Contents 4 0 R /Annots [5 0 R] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Annot /Subtype /Link /Rect [75.1234567 140.2345678 155.1234567 165.2345678] /Border [0 0 0] /QuadPoints [75.1234567 165.2345678 155.1234567 165.2345678 75.1234567 140.2345678 155.1234567 140.2345678] /Dest [3 0 R /FitR 43.144 71.72 283.144 331.72] >>"
        ])
    }

    private func document(objects: [String]) throws -> PDFDocument {
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let result = try XCTUnwrap(PDFDocument(data: bytes))
        PDFRawStreamProvenance.bindCreated(result, data: bytes)
        return result
    }

    private func geometryArrays(_ page: PDFPage) throws -> [String: [Double]] {
        let dictionary = try XCTUnwrap(page.pageRef?.dictionary)
        var result: [String: [Double]] = [:]
        for key in ["MediaBox", "CropBox", "BleedBox", "TrimBox", "ArtBox"] {
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, key, &array), let array { result[key] = try values(array) }
        }
        return result
    }

    private func rectangleNumbers(_ rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.maxX, rect.maxY].map(Double.init)
    }

    private func rawAnnotationArrays(_ page: PDFPage) throws -> [[String: [Double]]] {
        let dictionary = try XCTUnwrap(page.pageRef?.dictionary)
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { return [] }
        return try (0..<CGPDFArrayGetCount(annotations)).map { index in
            var annotation: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(annotations, index, &annotation))
            let node = try XCTUnwrap(annotation)
            var row: [String: [Double]] = [:]
            for key in ["Rect", "L", "QuadPoints", "Vertices", "CL"] {
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(node, key, &array), let array { row[key] = try values(array) }
            }
            return row
        }
    }

    private func values(_ array: CGPDFArrayRef) throws -> [Double] {
        try (0..<CGPDFArrayGetCount(array)).map { index in
            var value: CGPDFReal = 0
            XCTAssertTrue(CGPDFArrayGetNumber(array, index, &value))
            return Double(value)
        }
    }

    private func annotationDictionary(_ page: PDFPage, index: Int) throws -> CGPDFDictionaryRef {
        let dictionary = try XCTUnwrap(page.pageRef?.dictionary)
        var list: CGPDFArrayRef?, annotation: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "Annots", &list))
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(list), index, &annotation))
        return try XCTUnwrap(annotation)
    }

    private func appearanceData(_ page: PDFPage, annotation index: Int) throws -> Data {
        let annotation = try annotationDictionary(page, index: index)
        var appearance: CGPDFDictionaryRef?, normal: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(annotation, "AP", &appearance))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(appearance), "N", &normal))
        var format = CGPDFDataFormat.raw
        return try XCTUnwrap(CGPDFStreamCopyData(XCTUnwrap(normal), &format)) as Data
    }
}
