// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFPageStructurePreserverTests: XCTestCase {
    func testExtractionRemapsNamedLinksOutlinesAndInfoAfterReopening() throws {
        let source = try fixture()
        let originalLink = try XCTUnwrap(source.page(at: 0)?.annotations.first)
        let extracted = try PDFPageOperations.extract(from: source, indexes: [2, 0])
        let target = try XCTUnwrap(extracted.page(at: 1))
        let link = try XCTUnwrap(extracted.page(at: 0)?.annotations.first)
        XCTAssertTrue(link.destination?.page === target || (link.action as? PDFActionGoTo)?.destination.page === target)
        XCTAssertTrue(extracted.outlineRoot?.child(at: 0)?.destination?.page === target)
        XCTAssertEqual(extracted.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Preserved title")
        XCTAssertEqual(extracted.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Ember author")
        let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(extracted.dataRepresentation())))
        XCTAssertEqual(reopened.pageCount, 2)
        XCTAssertEqual(reopened.outlineRoot?.child(at: 0)?.label, "Destination")
        XCTAssertEqual(reopened.outlineRoot?.child(at: 0)?.destination?.page.map(reopened.index(for:)), 1)
        let reopenedLink = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
        let destination = reopenedLink.destination ?? (reopenedLink.action as? PDFActionGoTo)?.destination
        XCTAssertEqual(destination?.page.map(reopened.index(for:)), 1)
        XCTAssertEqual(destination?.point, CGPoint(x: 12, y: 145))
        XCTAssertEqual(destination?.zoom, 1.25)
        XCTAssertTrue(originalLink.destination?.page === source.page(at: 2) || (originalLink.action as? PDFActionGoTo)?.destination.page === source.page(at: 2))
        XCTAssertEqual(source.pageCount, 3)
        XCTAssertEqual(source.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Preserved title")
        XCTAssertEqual(source.outlineRoot?.child(at: 0)?.destination?.page.map(source.index(for:)), 2)
    }

    func testLinksOutsideExtractionAreRemovedWithoutRetainingDonorPages() throws {
        for named in [false, true] {
            for action in [false, true] {
                let source = try fixture(named: named, action: action)
                let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
                let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(extracted.dataRepresentation())))
                for output in [extracted, reopened] {
                    let annotation = try XCTUnwrap(output.page(at: 0)?.annotations.first)
                    XCTAssertNil(annotation.destination)
                    XCTAssertNil(annotation.action)
                    XCTAssertNil(annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Dest")))
                    XCTAssertNil(annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/A")))
                    XCTAssertEqual(output.outlineRoot?.numberOfChildren ?? 0, 0)
                    XCTAssertEqual(output.pageCount, 1)
                }
                let original = try XCTUnwrap(source.page(at: 0)?.annotations.first)
                let destination = original.destination ?? (original.action as? PDFActionGoTo)?.destination
                XCTAssertTrue(destination?.page === source.page(at: 2))
                XCTAssertEqual(source.pageCount, 3)
            }
        }
    }

    func testInternalDestinationsAndGoToActionsRemapWithoutDonorReferences() throws {
        for named in [false, true] {
            for action in [false, true] {
                let source = try fixture(named: named, action: action)
                let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 2])
                let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(extracted.dataRepresentation())))
                for output in [extracted, reopened] {
                    let annotation = try XCTUnwrap(output.page(at: 0)?.annotations.first)
                    let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
                    XCTAssertTrue(destination?.page === output.page(at: 1))
                    XCTAssertFalse(destination?.page === source.page(at: 2))
                    XCTAssertEqual(destination?.point, CGPoint(x: 12, y: 145))
                    XCTAssertEqual(destination?.zoom, 1.25)
                }
            }
        }
    }

    func testMergeTransactionPreservesDestinationOutlineAndUndoRedo() throws {
        let donor = try fixture()
        let destination = try fixture(named: false)
        destination.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Target title"]
        let originalPages = (0..<3).compactMap { destination.page(at: $0) }
        let originalOutline = destination.outlineRoot
        let imported = try PDFPageStructurePreserver.prepareImport(from: donor, indexes: [0, 2])
        let merge = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: destination, at: 1)
        XCTAssertEqual(destination.pageCount, 3)
        try merge.apply()
        XCTAssertEqual(destination.pageCount, 5)
        XCTAssertTrue(destination.page(at: 3) === originalPages[1])
        XCTAssertTrue(destination.outlineRoot?.child(at: 0)?.destination?.page === originalPages[2])
        let group = try XCTUnwrap(destination.outlineRoot?.child(at: 1))
        XCTAssertEqual(group.label, "Preserved title")
        XCTAssertTrue(group.child(at: 0)?.destination?.page === destination.page(at: 2))
        XCTAssertEqual(destination.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Target title")
        try merge.undo()
        XCTAssertEqual(destination.pageCount, 3)
        XCTAssertTrue(destination.outlineRoot === originalOutline)
        try merge.redo()
        let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(destination.dataRepresentation())))
        XCTAssertEqual(reopened.pageCount, 5)
        XCTAssertEqual(reopened.outlineRoot?.child(at: 1)?.child(at: 0)?.destination?.page.map(reopened.index(for:)), 2)
        XCTAssertEqual(donor.pageCount, 3)
    }

    func testMergeRejectsFormNameCollisionBeforeChangingEitherDocument() throws {
        let first = try formDocument(name: "customer", value: "Alice")
        let second = try formDocument(name: "customer", value: "Bob")
        let before = first.page(at: 0)
        XCTAssertThrowsError(try PDFPageOperations.append(contentsOf: second, to: first)) {
            XCTAssertEqual($0 as? PDFPageStructurePreserver.Failure, .conflictingFormFields)
        }
        XCTAssertEqual(first.pageCount, 1)
        XCTAssertTrue(first.page(at: 0) === before)
        XCTAssertEqual(first.page(at: 0)?.annotations.first?.widgetStringValue, "Alice")
        XCTAssertEqual(second.page(at: 0)?.annotations.first?.widgetStringValue, "Bob")
    }

    func testDistinctFormFieldsRemainIndependentAfterMergeAndSave() throws {
        let first = try formDocument(name: "customer", value: "Alice")
        let second = try formDocument(name: "address", value: "Paris")
        XCTAssertEqual(try PDFPageOperations.append(contentsOf: second, to: first), 1)
        XCTAssertEqual(first.page(at: 1)?.annotations.first?.fieldName, "address")
        XCTAssertEqual(first.page(at: 1)?.annotations.first?.widgetFieldType, .text)
        let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(first.dataRepresentation())))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.fieldName, "customer")
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.widgetStringValue, "Alice")
        XCTAssertEqual(reopened.page(at: 1)?.annotations.first?.fieldName, "address")
        XCTAssertEqual(reopened.page(at: 1)?.annotations.first?.widgetStringValue, "Paris")
        reopened.page(at: 1)?.annotations.first?.widgetStringValue = "Lyon"
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.widgetStringValue, "Alice")
        XCTAssertEqual(second.page(at: 0)?.annotations.first?.fieldName, "address")
        XCTAssertEqual(second.page(at: 0)?.annotations.first?.widgetStringValue, "Paris")
    }

    func testExtractedFormRestoresNameTypeAndValuesAfterInsertionAndReopening() throws {
        let source = try formDocument(name: "address", value: "Paris", defaultValue: "Fallback")
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
        let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(extracted.dataRepresentation())))
        for output in [extracted, reopened] {
            let widget = try XCTUnwrap(output.page(at: 0)?.annotations.first)
            XCTAssertEqual(widget.fieldName, "address")
            XCTAssertEqual(widget.widgetFieldType, .text)
            XCTAssertEqual(widget.widgetStringValue, "Paris")
            XCTAssertEqual(widget.widgetDefaultStringValue, "Fallback")
        }
        extracted.page(at: 0)?.annotations.first?.widgetStringValue = "Lyon"
        XCTAssertEqual(source.page(at: 0)?.annotations.first?.fieldName, "address")
        XCTAssertEqual(source.page(at: 0)?.annotations.first?.widgetStringValue, "Paris")
        XCTAssertEqual(source.page(at: 0)?.annotations.first?.widgetDefaultStringValue, "Fallback")
    }

    func testFormNamesRestoreAfterMergeUndoAndRedo() throws {
        let target = try formDocument(name: "customer", value: "Alice")
        let donor = try formDocument(name: "address", value: "Paris")
        let imported = try PDFPageStructurePreserver.prepareImport(from: donor, indexes: [0])
        let merge = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: target, at: 1)
        try merge.apply()
        XCTAssertEqual(target.page(at: 1)?.annotations.first?.fieldName, "address")
        try merge.undo()
        XCTAssertEqual(target.pageCount, 1)
        try merge.redo()
        let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(target.dataRepresentation())))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.fieldName, "customer")
        XCTAssertEqual(reopened.page(at: 1)?.annotations.first?.fieldName, "address")
        XCTAssertEqual(reopened.page(at: 1)?.annotations.first?.widgetStringValue, "Paris")
    }

    func testIndexedImageCopyAndAtomicSavePreserveInterpolationPixelsAndAnnotations() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-indexed-copy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for interpolation in [nil, false, true] as [Bool?] {
            let source = try imageFixture(kind: .indexed, interpolation: interpolation)
            let sourcePage = try XCTUnwrap(source.page(at: 0))
            let expectedPixels = try renderedPixels(sourcePage)
            let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 1])
            XCTAssertTrue(PDFBodyTextPageSnapshot.requiresPageContentPreservation(extracted))
            let copiedPage = try XCTUnwrap(extracted.page(at: 0))
            let originalNote = try XCTUnwrap(sourcePage.annotations.first { $0.type == "Text" })
            let copiedNote = try XCTUnwrap(copiedPage.annotations.first { $0.type == "Text" })
            XCTAssertFalse(originalNote === copiedNote)
            XCTAssertEqual(copiedNote.contents, "Kept note")
            copiedNote.contents = "Independent note"
            XCTAssertEqual(originalNote.contents, "Kept note")

            let url = folder.appendingPathComponent("interpolation-\(interpolation.map(String.init) ?? "absent").pdf")
            try AtomicPDFWriter.write(extracted, to: url)
            let reopened = try XCTUnwrap(PDFDocument(url: url))
            for output in [extracted, reopened] {
                let page = try XCTUnwrap(output.page(at: 0))
                let image = try imageStream(on: page, nested: false)
                let dictionary = try XCTUnwrap(CGPDFStreamGetDictionary(image))
                var actual: CGPDFBoolean = 0
                let present = CGPDFDictionaryGetBoolean(dictionary, "Interpolate", &actual)
                XCTAssertEqual(present, interpolation != nil)
                if let interpolation { XCTAssertEqual(actual != 0, interpolation) }
                var colorSpace: CGPDFArrayRef?
                XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "ColorSpace", &colorSpace))
                let palette = try XCTUnwrap(colorSpace)
                var name: UnsafePointer<CChar>?
                XCTAssertTrue(CGPDFArrayGetName(palette, 0, &name))
                XCTAssertEqual(name.map(String.init(cString:)), "Indexed")
                var lookup: CGPDFStringRef?
                XCTAssertTrue(CGPDFArrayGetString(palette, 3, &lookup))
                let string = try XCTUnwrap(lookup)
                let bytes = try XCTUnwrap(CGPDFStringGetBytePtr(string))
                XCTAssertEqual(Data(bytes: bytes, count: CGPDFStringGetLength(string)), imagePalette)
                var format = CGPDFDataFormat.raw
                XCTAssertEqual(CGPDFStreamCopyData(image, &format) as Data?, imageSamples)
                XCTAssertEqual(try renderedPixels(page), expectedPixels)
                XCTAssertEqual(page.annotations.count, 2)
                XCTAssertEqual(page.annotations.first { $0.type == "Text" }?.contents, "Independent note")
                let link = try XCTUnwrap(page.annotations.first { $0.type == "Link" })
                let destination = link.destination ?? (link.action as? PDFActionGoTo)?.destination
                XCTAssertTrue(destination?.page === output.page(at: 1))
                XCTAssertEqual(destination?.point, CGPoint(x: 12, y: 45))
                XCTAssertEqual(destination?.zoom, 1.25)
            }
            XCTAssertEqual(try renderedPixels(sourcePage), expectedPixels)
            XCTAssertEqual(originalNote.contents, "Kept note")
            let originalLink = try XCTUnwrap(sourcePage.annotations.first { $0.type == "Link" })
            let originalDestination = originalLink.destination ?? (originalLink.action as? PDFActionGoTo)?.destination
            XCTAssertTrue(originalDestination?.page === source.page(at: 1))
            let repeated = try PDFPageOperations.extract(from: source, indexes: [0, 1])
            let repeatedPage = try XCTUnwrap(repeated.page(at: 0))
            XCTAssertEqual(repeatedPage.annotations.count, 2)
            XCTAssertEqual(repeatedPage.annotations.first { $0.type == "Text" }?.contents, "Kept note")
            XCTAssertEqual(try renderedPixels(repeatedPage), expectedPixels)
        }
    }

    func testNestedIndexedImagesUsePreservationWhileRGBAndJPEGKeepFastCopyPath() throws {
        for nested in [false, true] {
            for kind in [ImageFixtureKind.indexed, .rgb, .jpeg] {
                let source = try imageFixture(kind: kind, nested: nested, annotations: kind == .indexed)
                XCTAssertFalse(PDFBodyTextPageSnapshot.requiresPageContentPreservation(source))
                let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 1])
                XCTAssertEqual(PDFBodyTextPageSnapshot.requiresPageContentPreservation(extracted), kind == .indexed)
                let page = try XCTUnwrap(extracted.page(at: 0))
                let image = try imageStream(on: page, nested: nested)
                var subtype: UnsafePointer<CChar>?
                XCTAssertTrue(CGPDFDictionaryGetName(try XCTUnwrap(CGPDFStreamGetDictionary(image)), "Subtype", &subtype))
                XCTAssertEqual(subtype.map(String.init(cString:)), "Image")
                if kind == .indexed { XCTAssertEqual(try renderedPixels(page), try renderedPixels(XCTUnwrap(source.page(at: 0)))) }
                if kind == .indexed { XCTAssertEqual(page.annotations.count, 2) }
            }
        }
    }

    func testCustomPageLabelsSurviveExtractionAndMergeOnDisk() throws {
        let source = try fixture(catalog: "/PageLabels << /Nums [0 << /S /r >>] >>")
        XCTAssertEqual(source.page(at: 0)?.label, "i")
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 2])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let extractedURL = folder.appendingPathComponent("extract.pdf")
        try AtomicPDFWriter.write(extracted, to: extractedURL)
        let reopened = try XCTUnwrap(PDFDocument(url: extractedURL))
        XCTAssertEqual((0..<reopened.pageCount).map { reopened.page(at: $0)?.label }, ["i", "iii"])
        let destination = try fixture()
        try PDFPageOperations.append(contentsOf: source, to: destination)
        let mergedURL = folder.appendingPathComponent("merge.pdf")
        try AtomicPDFWriter.write(destination, to: mergedURL)
        let merged = try XCTUnwrap(PDFDocument(url: mergedURL))
        XCTAssertEqual((3..<6).map { merged.page(at: $0)?.label }, ["i", "ii", "iii"])
        XCTAssertEqual(source.pageCount, 3)
        XCTAssertEqual(destination.pageCount, 6)
    }

    func testCatalogStructuresCanBeAssembledAndReopened() throws {
        for special in ["/OCProperties << /OCGs [] >>", "/StructTreeRoot << /Type /StructTreeRoot >>",
                        "/AF []", "/Collection << >>", "/Names << /EmbeddedFiles << /Names [] >> >>",
                        "/Perms << >>"] {
            let source = try fixture(catalog: special, named: false)
            let destination = try fixture()
            try PDFPageOperations.append(contentsOf: source, to: destination)
            let serialized = try XCTUnwrap(destination.dataRepresentation())
            let bytes = try PDFBodyTextPageSnapshot.preservingCatalog(in: serialized, from: destination,
                plan: PDFCatalogStructurePreserver.plan(for: destination))
            XCTAssertEqual(try XCTUnwrap(PDFDocument(data: bytes)).pageCount, 6, special)
            XCTAssertEqual(source.pageCount, 3)
        }
    }

    func testXFAAndCalculationOrderRemainGuardedBeforeMutation() throws {
        for special in ["/AcroForm << /XFA [] >>", "/AcroForm << /CO [] >>"] {
            let source = try fixture(catalog: special, named: false)
            let destination = try fixture()
            XCTAssertThrowsError(try PDFPageOperations.append(contentsOf: source, to: destination), special)
            XCTAssertEqual(destination.pageCount, 3)
        }
    }

    func testEmptyCalculationOrderAllowsAssemblyWithoutChangingSource() throws {
        let source = try fixture(catalog: "/AcroForm << /Fields [] /CO [] >>", named: false)
        let originalPages = (0..<source.pageCount).compactMap { source.page(at: $0) }
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 2])
        XCTAssertEqual(extracted.pageCount, 2)
        let destination = try fixture()
        try PDFPageOperations.append(contentsOf: source, to: destination)
        XCTAssertEqual(destination.pageCount, 6)
        XCTAssertEqual(source.pageCount, 3)
        for (index, page) in originalPages.enumerated() { XCTAssertTrue(source.page(at: index) === page) }
    }

    func testCalculationOrderWithWorkOrMalformedShapeRemainsGuarded() throws {
        for form in ["<< /Fields [] /CO null >>", "<< /Fields [] /CO 0 >>",
                     "<< /Fields [] /CO [null] >>", "<< /Fields [null] /CO [] >>",
                     "<< /CO [] >>", "<< /Fields [] /CO [] /XFA [] >>"] {
            let source = try fixture(catalog: "/AcroForm \(form)", named: false)
            let destination = try fixture()
            XCTAssertThrowsError(try PDFPageOperations.append(contentsOf: source, to: destination), form)
            XCTAssertEqual(destination.pageCount, 3)
        }
    }

    func testIndividualExtractionAlsoPrunesDestinationsAndCopiesMetadata() throws {
        let outputs = try PDFPageOperations.extractIndividually(from: fixture(), indexes: [2, 0])
        XCTAssertEqual(outputs.map(\.sourcePageIndex), [0, 2])
        XCTAssertEqual(outputs[0].document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Ember author")
        XCTAssertNil(outputs[0].document.page(at: 0)?.annotations.first?.destination)
        XCTAssertEqual(outputs[1].document.outlineRoot?.child(at: 0)?.destination?.page.map(outputs[1].document.index(for:)), 0)
    }

    func testUndoRefusesChangedPageOrderWithoutChangingDocument() throws {
        let source = try fixture()
        let target = try formDocument(name: "customer", value: "Alice")
        let imported = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [2])
        let merge = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: target, at: 1)
        try merge.apply()
        let moved = try XCTUnwrap(target.page(at: 0))
        target.removePage(at: 0)
        target.insert(moved, at: 1)
        let first = target.page(at: 0)
        XCTAssertThrowsError(try merge.undo())
        XCTAssertEqual(target.pageCount, 2)
        XCTAssertTrue(target.page(at: 0) === first)
    }

    @MainActor
    func testWorkspaceMergeUndoRestoresOutlineAndSavedCheckpoint() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-page-structure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let baseURL = folder.appendingPathComponent("base.pdf")
        let donorURL = folder.appendingPathComponent("donor.pdf")
        try XCTUnwrap(fixture(named: false).dataRepresentation()).write(to: baseURL)
        try XCTUnwrap(fixture().dataRepresentation()).write(to: donorURL)
        let beforeBase = try Data(contentsOf: baseURL)
        let beforeDonor = try Data(contentsOf: donorURL)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: baseURL))
        workspace.setMode(.editing)
        let document = try XCTUnwrap(workspace.document)
        let oldOutline = document.outlineRoot
        let oldDestination = document.outlineRoot?.child(at: 0)?.destination?.page
        workspace.merge(urls: [donorURL], insertionIndex: 1)
        XCTAssertNil(workspace.presentedError)
        XCTAssertEqual(document.pageCount, 6)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(document.outlineRoot?.child(at: 0)?.destination?.page === oldDestination)
        XCTAssertEqual(document.outlineRoot?.child(at: 1)?.child(at: 0)?.destination?.page.map(document.index(for:)), 3)
        workspace.undo()
        XCTAssertNil(workspace.presentedError)
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertTrue(document.outlineRoot === oldOutline)
        XCTAssertFalse(workspace.isDirty)
        workspace.redo()
        XCTAssertNil(workspace.presentedError)
        XCTAssertEqual(document.pageCount, 6)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(document.outlineRoot?.child(at: 1)?.child(at: 0)?.destination?.page.map(document.index(for:)), 3)
        XCTAssertEqual(try Data(contentsOf: baseURL), beforeBase)
        XCTAssertEqual(try Data(contentsOf: donorURL), beforeDonor)
    }

    private func formDocument(name: String, value: String, defaultValue: String? = nil) throws -> PDFDocument {
        let doc = PDFDocument()
        let image = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            return true
        }
        let page = try XCTUnwrap(PDFPage(image: image))
        let widget = PDFAnnotation(bounds: CGRect(x: 10, y: 20, width: 100, height: 20), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = name
        widget.widgetStringValue = value
        if let defaultValue { widget.widgetDefaultStringValue = defaultValue }
        page.addAnnotation(widget)
        doc.insert(page, at: 0)
        return try XCTUnwrap(PDFDocument(data: try XCTUnwrap(doc.dataRepresentation())))
    }

    private enum ImageFixtureKind { case indexed, rgb, jpeg }
    private var imagePalette: Data { Data([0, 0, 0, 255, 0, 0, 0, 255, 0, 255, 255, 255]) }
    private var imageSamples: Data { Data([0, 3, 1, 2, 3, 0, 2, 1, 1, 2, 0, 3, 2, 1, 3, 0]) }

    private func imageFixture(kind: ImageFixtureKind, nested: Bool = false, interpolation: Bool? = nil,
                              annotations: Bool = true) throws -> PDFDocument {
        let samples = imageSamples
        let palette = Array(imagePalette)
        let rgb = Data(samples.flatMap { index in Array(palette[(Int(index) * 3)..<(Int(index) * 3 + 3)]) })
        let imageData: Data
        let colorSpace: String
        let filter: String
        switch kind {
        case .indexed:
            imageData = samples
            colorSpace = "[/Indexed /DeviceRGB 3 <000000FF000000FF00FFFFFF>]"
            filter = ""
        case .rgb:
            imageData = rgb
            colorSpace = "/DeviceRGB"
            filter = ""
        case .jpeg:
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 12, bitsPerPixel: 24))
            rgb.copyBytes(to: try XCTUnwrap(bitmap.bitmapData), count: rgb.count)
            imageData = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
            colorSpace = "/DeviceRGB"
            filter = "/Filter /DCTDecode"
        }
        func stream(_ dictionary: String, _ bytes: Data) -> Data {
            var output = Data("<< \(dictionary) /Length \(bytes.count) >>\nstream\n".utf8)
            output.append(bytes)
            output.append(Data("\nendstream".utf8))
            return output
        }
        let policy = interpolation.map { "/Interpolate \($0 ? "true" : "false")" } ?? ""
        let painting = Data("q 54 0 0 54 5 5 cm /Picture Do Q\n".utf8)
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 64 64] /Resources << /XObject << /Picture \(nested ? 8 : 5) 0 R >> >> /Contents 9 0 R \(annotations ? "/Annots [6 0 R 7 0 R]" : "") >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 64 64] >>".utf8),
            stream("/Type /XObject /Subtype /Image /Width 4 /Height 4 /BitsPerComponent 8 /ColorSpace \(colorSpace) \(filter) \(policy)", imageData),
            Data("<< /Type /Annot /Subtype /Link /Rect [2 2 20 8] /Border [0 0 0] /Contents (Kept link) /Dest [4 0 R /XYZ 12 45 1.25] >>".utf8),
            Data("<< /Type /Annot /Subtype /Text /Rect [2 52 12 62] /Contents (Kept note) >>".utf8),
            stream("/Type /XObject /Subtype /Form /BBox [0 0 64 64] /Resources << /XObject << /Picture 5 0 R >> >>", painting),
            stream("", nested ? Data("q /Picture Do Q\n".utf8) : painting)
        ]
        var data = Data("%PDF-1.7\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n".utf8))
            data.append(object)
            data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func imageStream(on page: PDFPage, nested: Bool) throws -> CGPDFStreamRef {
        let dictionary = try XCTUnwrap(page.pageRef?.dictionary)
        var resources: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources))
        var xObjects: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &xObjects))
        var stream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(xObjects), "Picture", &stream))
        if nested {
            let form = try XCTUnwrap(CGPDFStreamGetDictionary(try XCTUnwrap(stream)))
            XCTAssertTrue(CGPDFDictionaryGetDictionary(form, "Resources", &resources))
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &xObjects))
            XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(xObjects), "Picture", &stream))
        }
        return try XCTUnwrap(stream)
    }

    private func renderedPixels(_ page: PDFPage) throws -> Data {
        let reference = try XCTUnwrap(page.pageRef)
        var pixels = Data(count: 192 * 192 * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 192, height: 192,
                bitsPerComponent: 8, bytesPerRow: 192 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 192, height: 192))
            context.scaleBy(x: 3, y: 3)
            context.drawPDFPage(reference)
        }
        return pixels
    }

    private func fixture(catalog extra: String = "", named: Bool = true, action: Bool = false) throws -> PDFDocument {
        let names = named ? "/Names << /Dests << /Names [(chapter) [5 0 R /XYZ 12 145 1.25]] >> >>" : ""
        let destination = named ? "(chapter)" : "[5 0 R /XYZ 12 145 1.25]"
        let navigation = action ? "/A << /S /GoTo /D \(destination) >>" : "/Dest \(destination)"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R \(names) \(extra) >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Annots [6 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 240] >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 10 100 30] /Border [0 0 0] \(navigation) >>",
            "<< /Type /Outlines /First 8 0 R /Last 8 0 R /Count 1 >>",
            "<< /Title (Destination) /Parent 7 0 R /Dest \(destination) >>",
            "<< /Title (Preserved title) /Author (Ember author) /Subject (Page assembly) /Keywords (safe) >>"
        ]
        var data = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 9 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }
}
