// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFNativeNavigationPreservationTests: XCTestCase {
    func testExplicitlyDeadOutlineLeavesArePrunedAndValidNeighborsRemain() throws {
        let source = try fixture(destination: "[3 0 R /XYZ 12 88 1.5]", deadLeaf: true)
        let originalRoot = try XCTUnwrap(source.outlineRoot)
        XCTAssertEqual(originalRoot.numberOfChildren, 3)
        let imported = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0, 1])
        let copiedRoot = try XCTUnwrap(imported.outline)
        XCTAssertEqual(copiedRoot.numberOfChildren, 2)
        XCTAssertEqual(copiedRoot.child(at: 0)?.label, "First")
        XCTAssertEqual(copiedRoot.child(at: 1)?.label, "Second")
        XCTAssertTrue(copiedRoot.child(at: 0)?.destination?.page === imported.pages[0])
        XCTAssertTrue(copiedRoot.child(at: 1)?.destination?.page === imported.pages[1])
        XCTAssertEqual(originalRoot.numberOfChildren, 3)
        XCTAssertTrue(source.outlineRoot === originalRoot)
        XCTAssertEqual(originalRoot.child(at: 1)?.label, "Dead")
        XCTAssertEqual(source.pageCount, 2)
    }

    func testModernAndLegacyNamedDestinationsMapAndExcludedTargetsArePruned() throws {
        for modern in [false, true] {
            let source = try fixture(destination: modern ? "(chapter)" : "/chapter", names: modern ? .modern : .legacy)
            let original = try XCTUnwrap(source.page(at: 0)?.annotations.first)
            let imported = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0, 1])
            let link = try XCTUnwrap(imported.pages[0].annotations.first)
            XCTAssertTrue(link.destination?.page === imported.pages[1])
            XCTAssertEqual(link.destination?.point, CGPoint(x: 20, y: 90))
            XCTAssertEqual(link.destination?.zoom, 2)
            XCTAssertTrue(imported.outline?.child(at: 0)?.destination?.page === imported.pages[1])
            let firstOnly = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0])
            XCTAssertNil(firstOnly.pages[0].annotations.first?.destination)
            XCTAssertNil(firstOnly.pages[0].annotations.first?.action)
            XCTAssertNil(firstOnly.pages[0].annotations.first?.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Dest")))
            XCTAssertEqual(firstOnly.outline?.numberOfChildren, 0)
            // PDFKit's immutable pageRef can retain an already-pruned donor
            // /Dest. A second assembly must obey the live cleared annotation.
            let liveExtraction = PDFDocument()
            liveExtraction.insert(firstOnly.pages[0], at: 0)
            liveExtraction.outlineRoot = firstOnly.outline
            _ = try XCTUnwrap(liveExtraction.dataRepresentation())
            let repeated = try PDFPageStructurePreserver.prepareImport(from: liveExtraction, indexes: [0])
            XCTAssertNil(repeated.pages[0].annotations.first?.destination)
            XCTAssertNil(repeated.pages[0].annotations.first?.action)
            XCTAssertNil(repeated.pages[0].annotations.first?.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Dest")))
            XCTAssertNotNil(original.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Dest")))
            XCTAssertEqual(source.outlineRoot?.numberOfChildren, 1)
        }
    }

    func testDistinctNativeNameBytesMayShareDecodedDisplayText() throws {
        let source = try fixture(destination: "(chapter)", names: .modernCollision)
        let imported = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0, 1])
        XCTAssertTrue(imported.pages[0].annotations.first?.destination?.page === imported.pages[1])
        XCTAssertTrue(imported.outline?.child(at: 0)?.destination?.page === imported.pages[1])
        XCTAssertEqual(imported.outline?.child(at: 0)?.destination?.point, CGPoint(x: 20, y: 90))
        XCTAssertEqual(source.outlineRoot?.numberOfChildren, 1)
        XCTAssertEqual(source.pageCount, 2)
    }

    func testZeroBasedPageNumberGoToDestinationsResolveWithoutGuessing() throws {
        let source = try fixture(destination: "[1 /XYZ 20 90 2]", action: true)
        let original = try XCTUnwrap(source.page(at: 0)?.annotations.first)
        let imported = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0, 1])
        let link = try XCTUnwrap(imported.pages[0].annotations.first)
        let destination = try XCTUnwrap((link.action as? PDFActionGoTo)?.destination)
        XCTAssertTrue(destination.page === imported.pages[1])
        XCTAssertEqual(destination.point, CGPoint(x: 20, y: 90))
        XCTAssertEqual(destination.zoom, 2)
        XCTAssertTrue(imported.outline?.child(at: 0)?.destination?.page === imported.pages[1])
        let firstOnly = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0])
        XCTAssertNil(firstOnly.pages[0].annotations.first?.action)
        XCTAssertNil(firstOnly.pages[0].annotations.first?.destination)
        XCTAssertNotNil(original.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/A")))
        XCTAssertEqual(source.pageCount, 2)
    }

    func testNativeFallbackUsesCurrentPageIdentityAfterReorderingOrRemovingPages() throws {
        for destination in ["[1 /XYZ 20 90 2]", "/chapter"] {
            let source = try fixture(destination: destination, names: .modern)
            let linkPage = try XCTUnwrap(source.page(at: 0)), target = try XCTUnwrap(source.page(at: 1))
            source.removePage(at: 1); source.insert(target, at: 0)
            let imported = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0, 1])
            let link = try XCTUnwrap(imported.pages[1].annotations.first)
            XCTAssertTrue(link.destination?.page === imported.pages[0])
            XCTAssertEqual(link.destination?.point, CGPoint(x: 20, y: 90))
            XCTAssertTrue(source.page(at: 0) === target)
            XCTAssertTrue(source.page(at: 1) === linkPage)

            let removed = try fixture(destination: destination, names: .modern)
            removed.removePage(at: 1)
            let firstOnly = try PDFPageStructurePreserver.prepareImport(from: removed, indexes: [0])
            XCTAssertNil(firstOnly.pages[0].annotations.first?.destination)
            XCTAssertNil(firstOnly.pages[0].annotations.first?.action)
            XCTAssertEqual(firstOnly.outline?.numberOfChildren, 0)
            XCTAssertEqual(removed.pageCount, 1)
        }
    }

    func testMalformedTargetsFailBeforeChangingSource() throws {
        for destination in ["[7 /Fit]", "[true /Fit]", "[0 /UnknownView]"] {
            let source = try fixture(destination: destination)
            let page = try XCTUnwrap(source.page(at: 0))
            let annotation = try XCTUnwrap(page.annotations.first)
            let outline = try XCTUnwrap(source.outlineRoot)
            let hadDeclaredDestination = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Dest")) != nil
            let destinationPage = annotation.destination?.page
            let destinationPoint = annotation.destination?.point
            XCTAssertThrowsError(try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0, 1])) {
                XCTAssertEqual($0 as? PDFPageStructurePreserver.Failure, .invalidDestination)
            }
            XCTAssertEqual(source.pageCount, 2)
            XCTAssertTrue(source.page(at: 0) === page)
            XCTAssertTrue(page.annotations.first === annotation)
            XCTAssertTrue(source.outlineRoot === outline)
            XCTAssertEqual(outline.numberOfChildren, 1)
            XCTAssertEqual(annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Dest")) != nil, hadDeclaredDestination)
            XCTAssertTrue(annotation.destination?.page === destinationPage)
            XCTAssertEqual(annotation.destination?.point, destinationPoint)
        }
    }

    func testProvenMissingNamesArePrunedWhileValidLinksAndSourceRemainIntact() throws {
        for destination in ["/missing", "(missing)"] {
            for action in [false, true] {
                let source = try fixture(destination: destination, action: action, validNeighbors: true)
                let page = try XCTUnwrap(source.page(at: 0))
                let originalAnnotations = page.annotations
                let outline = try XCTUnwrap(source.outlineRoot)
                let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 1])
                let links = try XCTUnwrap(extracted.page(at: 0)).annotations
                XCTAssertEqual(links.count, 3)
                XCTAssertNil(links[0].destination)
                XCTAssertNil(links[0].action)
                XCTAssertNil(links[0].value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Dest")))
                XCTAssertNil(links[0].value(forAnnotationKey: PDFAnnotationKey(rawValue: "/A")))
                XCTAssertTrue(links[1].destination?.page === extracted.page(at: 1))
                XCTAssertEqual(links[1].destination?.point, CGPoint(x: 20, y: 90))
                XCTAssertEqual((links[2].action as? PDFActionURL)?.url?.absoluteString, "https://example.com/")
                XCTAssertEqual(extracted.outlineRoot?.numberOfChildren, 0)

                // A second live assembly must not resurrect an unresolved name
                // still present in the immutable donor pageRef.
                let repeated = try PDFPageOperations.extract(from: extracted, indexes: [0, 1])
                XCTAssertNil(repeated.page(at: 0)?.annotations.first?.destination)
                XCTAssertNil(repeated.page(at: 0)?.annotations.first?.action)
                XCTAssertTrue(source.page(at: 0) === page)
                XCTAssertTrue(source.outlineRoot === outline)
                XCTAssertEqual(outline.numberOfChildren, 1)
                XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), originalAnnotations.map(ObjectIdentifier.init))
                XCTAssertNotNil(originalAnnotations[0].value(forAnnotationKey: PDFAnnotationKey(rawValue: action ? "/A" : "/Dest")))
            }
        }
    }

    func testAmbiguousDecodedNamesAndCyclicDefinitionsStillFailClosed() throws {
        for names: Names in [.modernCollision, .cyclic, .malformedLegacy, .malformedModern,
                              .malformedLeaf, .malformedKids, .malformedEmpty, .malformedBoth] {
            let source = try fixture(destination: "/chapter", names: names)
            let page = try XCTUnwrap(source.page(at: 0))
            let annotation = try XCTUnwrap(page.annotations.first)
            let hadDeclaredDestination = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Dest")) != nil
            let destinationPage = annotation.destination?.page
            let destinationPoint = annotation.destination?.point
            XCTAssertThrowsError(try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0, 1]))
            XCTAssertTrue(source.page(at: 0) === page)
            XCTAssertTrue(page.annotations.first === annotation)
            XCTAssertEqual(annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Dest")) != nil, hadDeclaredDestination)
            XCTAssertTrue(annotation.destination?.page === destinationPage)
            XCTAssertEqual(annotation.destination?.point, destinationPoint)
        }
    }

    func testReplacingAnUnresolvedNamedLinkWithAnExplicitLiveDestinationKeepsTheEdit() throws {
        let source = try fixture(destination: "/missing")
        let annotation = try XCTUnwrap(source.page(at: 0)?.annotations.first)
        let key = PDFAnnotationKey(rawValue: "/Dest")
        let beforeType = annotation.value(forAnnotationKey: key).map { String(reflecting: type(of: $0)) } ?? "nil"
        let target = try XCTUnwrap(source.page(at: 1))
        annotation.destination = PDFDestination(page: target, at: CGPoint(x: 27, y: 81))
        let afterType = annotation.value(forAnnotationKey: key).map { String(reflecting: type(of: $0)) } ?? "nil"
        print("Synthetic missing-destination declaration types before=\(beforeType), after=\(afterType)")
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 1])
        let copied = try XCTUnwrap(extracted.page(at: 0)?.annotations.first?.destination)
        XCTAssertTrue(copied.page === extracted.page(at: 1))
        XCTAssertEqual(copied.point, CGPoint(x: 27, y: 81))
        XCTAssertTrue(annotation.destination?.page === target)
        XCTAssertEqual(annotation.destination?.point, CGPoint(x: 27, y: 81))
    }

    func testReplacingAnUnresolvedOutlineWithAnExplicitLiveDestinationSurvivesSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-EditedOutline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for raw in ["/missing", "(missing)"] {
            let source = try fixture(destination: raw)
            let outline = try XCTUnwrap(source.outlineRoot?.child(at: 0))
            let target = try XCTUnwrap(source.page(at: 1))
            let current = PDFDestination(page: target, at: CGPoint(x: 14, y: 59))
            current.zoom = 1.25
            outline.destination = current
            let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 1])
            let copied = try XCTUnwrap(extracted.outlineRoot?.child(at: 0)?.destination)
            XCTAssertTrue(copied.page === extracted.page(at: 1))
            XCTAssertEqual(copied.point, current.point)
            XCTAssertEqual(copied.zoom, current.zoom)
            let url = directory.appendingPathComponent(UUID().uuidString + ".pdf")
            try AtomicPDFWriter.write(extracted, to: url)
            let reopened = try XCTUnwrap(PDFDocument(url: url))
            let saved = try XCTUnwrap(reopened.outlineRoot?.child(at: 0)?.destination)
            XCTAssertTrue(saved.page === reopened.page(at: 1))
            XCTAssertEqual(saved.point, current.point)
            XCTAssertEqual(saved.zoom, current.zoom)
            XCTAssertTrue(outline.destination === current)
            XCTAssertTrue(current.page === target)
        }
    }

    func testRepeatedLiveNamedAssemblyUsesMappedTargetsWithoutANativeCatalog() throws {
        for modern in [false, true] {
            let source = try fixture(destination: modern ? "(chapter)" : "/chapter", names: modern ? .modern : .legacy)
            let first = try PDFPageOperations.extract(from: source, indexes: [0, 1])
            XCTAssertNil(first.documentRef)
            let link = try XCTUnwrap(first.page(at: 0)?.annotations.first?.destination)
            XCTAssertTrue(link.page === first.page(at: 1))
            let second = try PDFPageOperations.extract(from: first, indexes: [0, 1])
            let repeated = try XCTUnwrap(second.page(at: 0)?.annotations.first?.destination)
            XCTAssertTrue(repeated.page === second.page(at: 1))
            XCTAssertEqual(repeated.point, CGPoint(x: 20, y: 90))
            XCTAssertEqual(repeated.zoom, 2)
            let outline = try XCTUnwrap(second.outlineRoot?.child(at: 0)?.destination)
            XCTAssertTrue(outline.page === second.page(at: 1))
            XCTAssertEqual(outline.point, repeated.point)
            XCTAssertEqual(outline.zoom, repeated.zoom)
            XCTAssertTrue(link.page === first.page(at: 1))
        }
    }

    func testOutlineViewModesAndArgumentsSurviveSaveAndRepeatedLiveAssembly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-navigation-modes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(String, String, [Double?])] = [
            ("Fit", "", []), ("FitH", "45.5", [45.5]),
            ("FitR", "10 20 80 90", [10, 20, 80, 90]),
            ("XYZ", "null 88 1.5", [nil, 88, 1.5]),
            ("XYZ", "12 88", [12, 88, nil])
        ]
        for (mode, arguments, operands) in cases {
            let source = try fixture(destination: "[4 0 R /" + mode + " " + arguments + "]")
            let first = try PDFPageOperations.extract(from: source, indexes: [0, 1])
            // Exercise live provenance rather than reopening the first result:
            // its immutable page/catalog graph can still describe the donor.
            let second = try PDFPageOperations.extract(from: first, indexes: [0, 1])
            for (iteration, document) in [first, second].enumerated() {
                let url = directory.appendingPathComponent(mode + "-" + String(iteration) + ".pdf")
                try AtomicPDFWriter.write(document, to: url)
                let reopened = try XCTUnwrap(PDFDocument(url: url))
                try assertOutlineView(reopened, mode: mode, operands: operands, target: 1)
                XCTAssertEqual(reopened.outlineRoot?.numberOfChildren, 1)
            }
        }
    }

    private func assertOutlineView(_ document: PDFDocument, mode: String, operands: [Double?], target: Int) throws {
        let native = try XCTUnwrap(document.documentRef)
        var outlines: CGPDFDictionaryRef?, first: CGPDFDictionaryRef?, destination: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(native.catalog), "Outlines", &outlines))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(outlines), "First", &first))
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(first), "Dest", &destination))
        let array = try XCTUnwrap(destination)
        XCTAssertEqual(CGPDFArrayGetCount(array), operands.count + 2)
        var page: CGPDFDictionaryRef?, view: UnsafePointer<CChar>?
        XCTAssertTrue(CGPDFArrayGetDictionary(array, 0, &page))
        XCTAssertEqual(pdfReferenceIdentity(try XCTUnwrap(page)), pdfReferenceIdentity(try XCTUnwrap(native.page(at: target + 1)?.dictionary)))
        XCTAssertTrue(CGPDFArrayGetName(array, 1, &view))
        XCTAssertEqual(String(cString: try XCTUnwrap(view)), mode)
        for (index, expected) in operands.enumerated() {
            if let expected {
                var number: CGPDFReal = 0
                XCTAssertTrue(CGPDFArrayGetNumber(array, index + 2, &number))
                XCTAssertEqual(Double(number), expected, accuracy: 0.000001)
            } else {
                var value: CGPDFObjectRef?
                XCTAssertTrue(CGPDFArrayGetObject(array, index + 2, &value))
                XCTAssertEqual(CGPDFObjectGetType(try XCTUnwrap(value)), .null)
            }
        }
    }

    private enum Names { case modern, legacy, modernCollision, cyclic, malformedLegacy, malformedModern, malformedLeaf, malformedKids, malformedEmpty, malformedBoth }
    private func fixture(destination: String, names: Names? = nil, action: Bool = false, deadLeaf: Bool = false,
                         validNeighbors: Bool = false) throws -> PDFDocument {
        let namesEntry: String
        switch names {
        case .modern, .modernCollision: namesEntry = "/Names << /Dests << /Kids [11 0 R] >> >>"
        case .legacy: namesEntry = "/Dests << /chapter << /D [4 0 R /XYZ 20 90 2] >> >>"
        case .cyclic: namesEntry = "/Dests << /chapter /chapter >>"
        case .malformedLegacy: namesEntry = "/Dests []"
        case .malformedModern: namesEntry = "/Names << /Dests [] >>"
        case .malformedLeaf: namesEntry = "/Names << /Dests << /Names 1 >> >>"
        case .malformedKids: namesEntry = "/Names << /Dests << /Kids 1 >> >>"
        case .malformedEmpty: namesEntry = "/Names << /Dests << >> >>"
        case .malformedBoth: namesEntry = "/Names << /Dests << /Names [] /Kids [] >> >>"
        case nil: namesEntry = ""
        }
        let additionalName: String
        if case .modernCollision = names { additionalName = "<FEFF0063006800610070007400650072> [3 0 R /XYZ 10 80 1]" }
        else { additionalName = "" }
        let navigation = action ? "/A << /S /GoTo /D \(destination) >>" : "/Dest \(destination)"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R \(namesEntry) >>",
            "<< /Type /Pages /Count 2 /Kids [3 0 R 4 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> /Annots [5 0 R \(validNeighbors ? "12 0 R 13 0 R" : "")] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>",
            "<< /Type /Annot /Subtype /Link /Rect [5 5 50 20] \(navigation) >>",
            "<< >>",
            "<< /Type /Outlines /First 8 0 R /Last \(deadLeaf ? 10 : 8) 0 R /Count \(deadLeaf ? 3 : 1) >>",
            "<< /Title (First) /Parent 7 0 R \(deadLeaf ? "/Next 9 0 R" : "") /Dest \(destination) >>",
            "<< /Title (Dead) /Parent 7 0 R /Prev 8 0 R /Next 10 0 R /Dest [null /XYZ null null 0] >>",
            "<< /Title (Second) /Parent 7 0 R /Prev 9 0 R /Dest [4 0 R /Fit] >>",
            "<< /Names [(chapter) << /D [4 0 R /XYZ 20 90 2] >> \(additionalName)] >>",
            "<< /Type /Annot /Subtype /Link /Rect [5 25 50 40] /Dest [4 0 R /XYZ 20 90 2] >>",
            "<< /Type /Annot /Subtype /Link /Rect [5 45 50 60] /A << /S /URI /URI (https://example.com/) >> >>"
        ]
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }
}
