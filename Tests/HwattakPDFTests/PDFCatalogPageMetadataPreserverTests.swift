// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFCatalogPageMetadataPreserverTests: XCTestCase {
    func testHierarchicalLabelLookupKeepsSourceDisplayBeyondLeafLimits() throws {
        let source = try fixture(labels: "/Kids [10 0 R]", extraObjects: [
            "<< /Limits [0 1] /Nums [0 << /P (Cover) >> 1 << /S /D >>] >>"
        ])
        XCTAssertEqual(source.page(at: 0)?.label, "Cover")
        XCTAssertEqual(source.page(at: 4)?.label, "5")
        var plan = PDFCatalogGraphPlan()
        try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(source, [(0, 0), (1, 1), (4, 2), (5, 3)])], to: &plan)
        let labels = try labelDictionaries(plan)
        XCTAssertEqual(try bytes(labels[0]?["P"]), Data("Cover".utf8))
        XCTAssertEqual(try integer(labels[1]?["St"]), 1)
        XCTAssertEqual(try integer(labels[2]?["St"]), 5)
        XCTAssertEqual(try integer(labels[3]?["St"]), 6)
        XCTAssertEqual(try name(labels[2]?["S"]), "D")
    }

    func testNestedLabelLookupRetainsPathBoundsAndLeafGapFallback() throws {
        let source = try fixture(labels: "/Kids [10 0 R]", extraObjects: [
            "<< /Limits [0 3] /Kids [11 0 R 12 0 R] >>",
            "<< /Limits [0 0] /Nums [0 << /S /r >>] >>",
            "<< /Limits [3 3] /Nums [3 << /S /D /St 20 >>] >>"
        ])
        XCTAssertEqual(source.page(at: 0)?.label, "i")
        XCTAssertEqual(source.page(at: 1)?.label, "2")
        XCTAssertEqual(source.page(at: 3)?.label, "20")
        XCTAssertEqual(source.page(at: 5)?.label, "6")
        var plan = PDFCatalogGraphPlan()
        try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(source, [(0, 0), (1, 1), (3, 2), (5, 3)])], to: &plan)
        let labels = try labelDictionaries(plan)
        XCTAssertEqual(try name(labels[0]?["S"]), "r")
        XCTAssertEqual(try integer(labels[1]?["St"]), 2)
        XCTAssertEqual(try name(labels[1]?["S"]), "D")
        XCTAssertEqual(try integer(labels[2]?["St"]), 20)
        XCTAssertEqual(try integer(labels[3]?["St"]), 6)
    }

    func testFlatLabelPrefixAndStyleCarryRemainUnchanged() throws {
        let source = try fixture(labels: "/Limits [0 0] /Nums [0 << /S /D /St 10 /P (P) >>]")
        XCTAssertEqual(source.page(at: 5)?.label, "P15")
        var plan = PDFCatalogGraphPlan()
        try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(source, [(5, 0)])], to: &plan)
        let labels = try labelDictionaries(plan)
        XCTAssertEqual(try name(labels[0]?["S"]), "D")
        XCTAssertEqual(try integer(labels[0]?["St"]), 15)
        XCTAssertEqual(try bytes(labels[0]?["P"]), Data("P".utf8))
    }

    func testInvalidHierarchicalLimitsAndDuplicateStartsRejectBeforePublishingLabels() throws {
        for declaration in [
            "<< /Limits [1 0] /Nums [0 << /S /D >>] >>",
            "<< /Limits [-1 1] /Nums [0 << /S /D >>] >>",
            "<< /Limits [0 6] /Nums [0 << /S /D >>] >>",
            "<< /Limits [/Zero 1] /Nums [0 << /S /D >>] >>",
            "<< /Limits [0] /Nums [0 << /S /D >>] >>",
            "<< /Limits [0 1 2] /Nums [0 << /S /D >>] >>",
            "<< /Limits [1 1] /Nums [0 << /S /D >>] >>",
            "<< /Limits [0 1] /Nums [0 << /S /D >> 0 << /S /r >>] >>",
            "<< /Nums [0 << /S /D >>] >>"
        ] {
            assertInvalidMetadataWithoutPartialPlan(try fixture(labels: "/Kids [10 0 R]", extraObjects: [declaration]), context: declaration)
        }
        assertInvalidMetadataWithoutPartialPlan(try fixture(labels: "/Kids [10 0 R]", extraObjects: [
            "<< /Limits [0 1] /Kids [11 0 R] >>", "<< /Limits [0 3] /Nums [0 << /S /D >>] >>"
        ]), context: "Child limits exceed the parent lookup bounds")
        for (context, declarations) in [
            ("Overlapping sibling bounds", [
                "<< /Limits [0 5] /Nums [0 << /S /D /St 10 >>] >>",
                "<< /Limits [3 3] /Nums [3 << /S /D /St 20 >>] >>"
            ]),
            ("Reversed sibling bounds", [
                "<< /Limits [3 3] /Nums [3 << /S /D /St 20 >>] >>",
                "<< /Limits [0 0] /Nums [0 << /S /r >>] >>"
            ])
        ] {
            let source = try fixture(labels: "/Kids [10 0 R 11 0 R]", extraObjects: declarations)
            let before = (0..<source.pageCount).map { source.page(at: $0)?.label }
            print("PageLabels unsupported \(context), original PDFKit labels: \(before)")
            assertInvalidMetadataWithoutPartialPlan(source, context: context)
            XCTAssertEqual((0..<source.pageCount).map { source.page(at: $0)?.label }, before)
        }
        let missingLimits = try fixture(labels: "/Kids [10 0 R]", extraObjects: ["<< /Nums [0 << /S /D /St 10 >>] >>"])
        print("PageLabels unsupported missing child Limits, original PDFKit label: \(String(describing: missingLimits.page(at: 4)?.label))")
        assertInvalidMetadataWithoutPartialPlan(missingLimits, context: "Non-root Limits are required for a bounded lookup")
        let conflictingKinds = try fixture(labels: "/Nums [0 << /P (Flat) >>] /Kids [10 0 R]", extraObjects: [
            "<< /Limits [0 0] /Nums [0 << /S /r >>] >>"
        ])
        print("PageLabels unsupported Nums+Kids, original PDFKit label: \(String(describing: conflictingKinds.page(at: 4)?.label))")
        assertInvalidMetadataWithoutPartialPlan(conflictingKinds, context: "A number-tree node cannot be both a leaf and an intermediate node")
    }

    func testNoncontiguousExtractionPreservesNumberStylesStartsAndPrefixOnlyLabels() throws {
        let source = try fixture(labels: "/Nums [0 << /S /D /St 10 /P (P) >> 2 << /S /r /St 4 >> 4 << /P (Appendix) >>]")
        var plan = PDFCatalogGraphPlan()
        try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(source, [(1, 0), (3, 1), (5, 2)])], to: &plan)
        let labels = try labelDictionaries(plan)
        XCTAssertEqual(try integer(labels[0]?["St"]), 11)
        XCTAssertEqual(try name(labels[0]?["S"]), "D")
        XCTAssertEqual(try bytes(labels[0]?["P"]), Data("P".utf8))
        XCTAssertEqual(try integer(labels[1]?["St"]), 5)
        XCTAssertEqual(try name(labels[1]?["S"]), "r")
        XCTAssertEqual(try bytes(labels[2]?["P"]), Data("Appendix".utf8))
        XCTAssertNil(labels[2]?["S"])
        XCTAssertNil(labels[2]?["St"])
    }

    func testMergeUsesOutputOffsetsAndKeepsUnlabeledSourcePageNumbers() throws {
        let target = try fixture(labels: "/Kids [10 0 R 11 0 R]", extraObjects: [
            "<< /Nums [0 << /S /r >>] /Limits [0 0] >>", "<< /Nums [3 << /S /D /St 20 >>] /Limits [3 3] >>"
        ])
        let donor = try fixture()
        var plan = PDFCatalogGraphPlan()
        try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [
            group(target, [(0, 0), (1, 1), (2, 4), (3, 5)]), group(donor, [(5, 2), (0, 3)])
        ], to: &plan)
        let labels = try labelDictionaries(plan)
        XCTAssertEqual(labels.count, 6)
        XCTAssertEqual(try name(labels[0]?["S"]), "r")
        XCTAssertEqual(try integer(labels[1]?["St"]), 2)
        XCTAssertEqual(try name(labels[2]?["S"]), "D")
        XCTAssertEqual(try integer(labels[2]?["St"]), 6)
        XCTAssertEqual(try integer(labels[3]?["St"]), 1)
        XCTAssertEqual(try integer(labels[4]?["St"]), 3)
        XCTAssertEqual(try integer(labels[5]?["St"]), 20)
    }

    func testInternalArrayAndGoToOpeningActionsRemapFinalPageIdentity() throws {
        for dictionaryAction in [false, true] {
            let destination = "[5 0 R /XYZ null 47 1.25]"
            let action = dictionaryAction ? "<< /S /GoTo /D \(destination) /NewWindow true >>" : destination
            let source = try fixture(openAction: action)
            var plan = PDFCatalogGraphPlan()
            try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(source, [(2, 7), (0, 4)])], to: &plan)
            XCTAssertNil(plan.catalogEntries["PageLabels"])
            let value = try XCTUnwrap(plan.catalogEntries["OpenAction"])
            let mapped: PDFCatalogGraphValue
            if case .dictionary(let entries) = value {
                mapped = try XCTUnwrap(entries["D"])
                XCTAssertNotNil(entries["NewWindow"])
            } else { mapped = value }
            guard case .array(let values) = mapped, case .page(let page) = values.first else { return XCTFail("Expected a mapped destination.") }
            XCTAssertEqual(page, 7)
            XCTAssertEqual(try name(values[1]), "XYZ")
            guard case .original(let top) = values[3] else { return XCTFail("Expected original destination coordinates.") }
            var number: CGPDFInteger = 0
            XCTAssertTrue(CGPDFObjectGetValue(top, .integer, &number))
            XCTAssertEqual(number, 47)
            XCTAssertEqual(values.count, 5)
        }
    }

    func testOpeningActionPriorityAndExcludedTargetsDoNotJumpToAnotherSource() throws {
        let first = try fixture(openAction: "[3 0 R /Fit]")
        let second = try fixture(openAction: "[3 0 R /FitH null]")
        var plan = PDFCatalogGraphPlan()
        try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(first, [(0, 3)]), group(second, [(0, 0)])], to: &plan)
        guard case .array(let values) = plan.catalogEntries["OpenAction"], case .page(let page) = values.first else {
            return XCTFail("Expected the first source's opening action.")
        }
        XCTAssertEqual(page, 3)
        try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(first, [(2, 1)]), group(second, [(0, 0)])], to: &plan)
        XCTAssertNil(plan.catalogEntries["OpenAction"])
    }

    func testUnicodePrefixBytesAndOtherOpeningActionsStayUnmodified() throws {
        let source = try fixture(labels: "/Nums [0 << /S /A /P <FEFFD559C0DD> >>]", openAction: "<< /S /JavaScript /JS (app.alert\\(1\\)) >>")
        var plan = PDFCatalogGraphPlan()
        try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(source, [(1, 0)])], to: &plan)
        XCTAssertEqual(try bytes(labelDictionaries(plan)[0]?["P"]), Data([0xFE, 0xFF, 0xD5, 0x59, 0xC0, 0xDD]))
        guard case .original(let action) = plan.catalogEntries["OpenAction"] else { return XCTFail("Uninterpreted actions should remain original graph values.") }
        XCTAssertEqual(CGPDFObjectGetType(action), .dictionary)
        XCTAssertFalse(plan.retainedDocuments.isEmpty)
    }

    func testNamedDestinationsPruneExcludedPagesAndNamespaceSourceCollisions() throws {
        let first = try fixture(names: "/Names [(chapter) [3 0 R /Fit] (gone) [4 0 R /Fit]]",
                                legacyDests: "/legacy << /D [5 0 R /Fit] >> /removed [4 0 R /Fit]")
        let second = try fixture(names: "/Names [(chapter) << /D [3 0 R /FitH null] >>]", legacyDests: "/legacy [3 0 R /Fit]")
        var plan = PDFCatalogGraphPlan()
        plan.catalogEntries["Names"] = .dictionary(["EmbeddedFiles": .dictionary([:])])
        try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(first, [(0, 0), (2, 2)]), group(second, [(0, 1)])], to: &plan)
        guard case .dictionary(let names) = plan.catalogEntries["Names"],
              case .dictionary(let destinations) = names["Dests"], case .array(let pairs) = destinations["Names"] else {
            return XCTFail("Expected a destination name tree.")
        }
        XCTAssertNotNil(names["EmbeddedFiles"])
        XCTAssertEqual(pairs.count, 4)
        let keys = try stride(from: 0, to: pairs.count, by: 2).map { try bytes(pairs[$0]) }
        XCTAssertTrue(keys.contains(Data("chapter".utf8)))
        XCTAssertFalse(keys.contains(Data("gone".utf8)))
        XCTAssertEqual(Set(keys).count, 2)
        XCTAssertTrue(keys.contains(where: { $0.starts(with: [0xFE, 0xFF]) }))
        guard case .dictionary(let legacy) = plan.catalogEntries["Dests"] else { return XCTFail("Expected legacy destination names.") }
        XCTAssertEqual(legacy.count, 2)
        XCTAssertNil(legacy["removed"])
        guard case .dictionary(let wrapped) = legacy["legacy"], case .array(let target) = wrapped["D"],
              case .page(let index) = target.first else { return XCTFail("Expected a preserved destination dictionary.") }
        XCTAssertEqual(index, 2)
    }

    func testNullOpeningActionIsAbsentAndOtherActionKindsStayOriginal() throws {
        let nullSource = try fixture(openAction: "null")
        var emptyPlan = PDFCatalogGraphPlan()
        try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(nullSource, [(0, 0)])], to: &emptyPlan)
        XCTAssertNil(emptyPlan.catalogEntries["OpenAction"])
        XCTAssertEqual(emptyPlan.retainedDocuments.count, 1)

        for declaration in ["<< /S /URI /URI (https://example.invalid/) >>", "<< /S /Named /N /NextPage >>"] {
            let actionSource = try fixture(openAction: declaration)
            let catalog = try XCTUnwrap(actionSource.documentRef?.catalog)
            var original: CGPDFObjectRef?
            XCTAssertTrue(CGPDFDictionaryGetObject(catalog, "OpenAction", &original))
            var plan = PDFCatalogGraphPlan()
            try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [
                group(nullSource, [(0, 0)]), group(actionSource, [(0, 1)])
            ], to: &plan)
            guard case .original(let preserved) = plan.catalogEntries["OpenAction"] else {
                return XCTFail("Other action dictionaries should remain original graph values.")
            }
            XCTAssertEqual(preserved, try XCTUnwrap(original))
            XCTAssertEqual(CGPDFObjectGetType(preserved), .dictionary)
            XCTAssertEqual(plan.retainedDocuments.count, 2)
        }
    }

    func testNamedOpeningActionsResolveModernAndLegacyNamesBeforePageMapping() throws {
        for modern in [true, false] {
            let source = try fixture(openAction: "<< /S /GoTo /D \(modern ? "(chapter)" : "/chapter") >>",
                names: modern ? "/Names [(chapter) << /D [5 0 R /XYZ 67 112] >>]" : nil,
                legacyDests: modern ? nil : "/chapter [5 0 R /Fit]")
            var plan = PDFCatalogGraphPlan()
            try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(source, [(2, 4)])], to: &plan)
            guard case .dictionary(let action) = plan.catalogEntries["OpenAction"], case .array(let target) = action["D"],
                  case .page(let index) = target.first else { return XCTFail("Expected a resolved named destination.") }
            XCTAssertEqual(index, 4)
            if modern {
                XCTAssertEqual(target.count, 5)
                guard case .null = target.last else { return XCTFail("An omitted XYZ zoom must retain the current zoom.") }
            }
            try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(source, [(0, 0)])], to: &plan)
            XCTAssertNil(plan.catalogEntries["OpenAction"])
        }
    }

    func testInvalidTreesDuplicateOutputsAndOverflowDoNotPartiallyChangePlan() throws {
        let sources = [
            try fixture(labels: "/Nums [0 << /S /D >> 0 << /S /r >>]"),
            try fixture(labels: "/Nums [0 << /S /D /St \(Int.max) >>]"),
            try fixture(labels: "/Nums [0 << /S /Unknown >>]"),
            try fixture(names: "/Names [(duplicate) [3 0 R /Fit] (duplicate) [4 0 R /Fit]]")
        ]
        for source in sources {
            var plan = PDFCatalogGraphPlan()
            plan.catalogEntries["Sentinel"] = .boolean(true)
            XCTAssertThrowsError(try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(source, [(1, 0)])], to: &plan))
            XCTAssertNotNil(plan.catalogEntries["Sentinel"])
            XCTAssertNil(plan.catalogEntries["PageLabels"])
            XCTAssertTrue(plan.retainedDocuments.isEmpty)
        }
        let source = try fixture()
        var plan = PDFCatalogGraphPlan()
        XCTAssertThrowsError(try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(source, [(0, 0), (1, 0)])], to: &plan))
    }

    func testStoredNullNamedDestinationsSurviveExtractMergeSaveAndReopenWithoutInventingPages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-NullDestinations-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for modern in [false, true] {
            let source = try fixture(
                openAction: "<< /S /GoTo /D \(modern ? "(good)" : "/good") >>",
                names: modern ? "/Names [(good) [5 0 R /Fit] (unusedA) [null /XYZ 119.250015 720 0] (unusedB) [null /XYZ 76.500008 720 0]]" : nil,
                legacyDests: modern ? nil : "/good [5 0 R /Fit] /unusedA [null /XYZ 119.250015 720 0] /unusedB [null /XYZ 76.500008 720 0]")
            let expectedTails = try ["unusedA", "unusedB"].map {
                try primitiveSignature(namedDestination(in: source, key: $0, modern: modern))
            }
            let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 2])
            let extractedURL = directory.appendingPathComponent("extract-\(modern).pdf")
            try AtomicPDFWriter.write(extracted, to: extractedURL)
            let reopened = try XCTUnwrap(PDFDocument(url: extractedURL))
            XCTAssertEqual(reopened.pageCount, 2)
            try assertNamedDestinations(in: reopened, modern: modern, validPageIndex: 1, expectedTails: expectedTails)

            let merged = try fixture()
            let imported = try PDFPageStructurePreserver.prepareImport(from: reopened, indexes: [0, 1])
            let transaction = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: merged, at: 1)
            try transaction.apply()
            try transaction.undo()
            XCTAssertEqual(merged.pageCount, 6)
            try transaction.redo()
            let mergedURL = directory.appendingPathComponent("merge-\(modern).pdf")
            try AtomicPDFWriter.write(merged, to: mergedURL)
            let reopenedMerge = try XCTUnwrap(PDFDocument(url: mergedURL))
            XCTAssertEqual(reopenedMerge.pageCount, 8)
            try assertNamedDestinations(in: reopenedMerge, modern: modern, validPageIndex: 2, expectedTails: expectedTails)
            // Source definitions still have their original null targets and
            // primitive types/values after both complete write transactions.
            try assertNamedDestinations(in: source, modern: modern, validPageIndex: 2,
                                        expectedTails: expectedTails, expectsMappedOpeningAction: false)
        }
    }

    func testActiveNullDestinationsAndNullAliasesRemainRejected() throws {
        let sources = [
            ("active array with null target", try fixture(openAction: "[null /XYZ 12 20 0]")),
            ("active GoTo action with null target", try fixture(openAction: "<< /S /GoTo /D [null /Fit] >>")),
            ("invalid bare legacy name OpenAction", try fixture(openAction: "/dead", legacyDests: "/dead [null /XYZ 12 20 0]")),
            ("invalid bare modern string OpenAction", try fixture(openAction: "(dead)", names: "/Names [(dead) [null /XYZ 12 20 0]]")),
            ("legacy alias to null target", try fixture(legacyDests: "/alias /dead /dead [null /XYZ 12 20 0]")),
            ("modern alias to null target", try fixture(names: "/Names [(alias) (dead) (dead) [null /XYZ 12 20 0]]"))
        ]
        for (context, source) in sources { assertInvalidMetadataWithoutPartialPlan(source, context: context) }
    }

    func testStoredNullDestinationsRejectUnknownViewsWrongArityAndNonNumericTails() throws {
        // NaN is not a PDF numeric token. Both named and string spellings must
        // remain invalid operands, alongside booleans and container objects.
        let malformed = [
            "[null /Unknown]", "[null /Fit 1]", "[null /FitR 0 0 10]",
            "[null /XYZ 0 10 0 0]", "[null /XYZ /NaN 20 0]",
            "[null /XYZ (NaN) 20 0]", "[null /XYZ true 20 0]",
            "[null /XYZ << >> 20 0]", "[null /XYZ [] 20 0]",
            "[(not-a-page) /XYZ 0 20 0]"
        ]
        for destination in malformed {
            assertInvalidMetadataWithoutPartialPlan(try fixture(legacyDests: "/dead \(destination)"), context: destination)
        }
    }

    private func assertInvalidMetadataWithoutPartialPlan(_ source: PDFDocument,
                                                        context: String = "",
                                                        file: StaticString = #filePath, line: UInt = #line) {
        var plan = PDFCatalogGraphPlan()
        plan.catalogEntries["Sentinel"] = .boolean(true)
        XCTAssertThrowsError(try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(source, [(0, 0)])], to: &plan),
                             context, file: file, line: line) { error in
            guard let failure = error as? PDFCatalogPageMetadataPreserver.Failure else {
                return XCTFail("\(context): Expected the metadata guard, got \(error)", file: file, line: line)
            }
            if case .tooComplex = failure { XCTFail("\(context): Tiny malformed metadata is not a complexity rejection.", file: file, line: line) }
        }
        XCTAssertNotNil(plan.catalogEntries["Sentinel"], context, file: file, line: line)
        XCTAssertNil(plan.catalogEntries["Dests"], context, file: file, line: line)
        XCTAssertNil(plan.catalogEntries["Names"], context, file: file, line: line)
        XCTAssertNil(plan.catalogEntries["OpenAction"], context, file: file, line: line)
        XCTAssertTrue(plan.retainedDocuments.isEmpty, context, file: file, line: line)
    }

    private func assertNamedDestinations(in document: PDFDocument, modern: Bool, validPageIndex: Int,
                                         expectedTails: [[String]], expectsMappedOpeningAction: Bool = true) throws {
        for (index, key) in ["unusedA", "unusedB"].enumerated() {
            let array = try namedDestination(in: document, key: key, modern: modern)
            XCTAssertEqual(try primitiveSignature(array), expectedTails[index])
        }
        let valid = try namedDestination(in: document, key: "good", modern: modern)
        var target: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(valid, 0, &target))
        XCTAssertEqual(target, document.documentRef?.page(at: validPageIndex + 1)?.dictionary)
        if expectsMappedOpeningAction {
            let catalog = try XCTUnwrap(document.documentRef?.catalog)
            var action: CGPDFDictionaryRef?, destination: CGPDFArrayRef?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "OpenAction", &action))
            let dictionary = try XCTUnwrap(action)
            XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "D", &destination))
            let array = try XCTUnwrap(destination)
            target = nil
            XCTAssertTrue(CGPDFArrayGetDictionary(array, 0, &target))
            XCTAssertEqual(target, document.documentRef?.page(at: validPageIndex + 1)?.dictionary)
        }
    }

    private func namedDestination(in document: PDFDocument, key: String, modern: Bool) throws -> CGPDFArrayRef {
        let catalog = try XCTUnwrap(document.documentRef?.catalog)
        var destinations: CGPDFDictionaryRef?
        if modern {
            var names: CGPDFDictionaryRef?, entries: CGPDFArrayRef?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "Names", &names))
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(names), "Dests", &destinations))
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(destinations), "Names", &entries))
            let pairs = try XCTUnwrap(entries)
            for index in stride(from: 0, to: CGPDFArrayGetCount(pairs), by: 2) {
                var name: CGPDFStringRef?, value: CGPDFArrayRef?
                XCTAssertTrue(CGPDFArrayGetString(pairs, index, &name))
                if let name, (CGPDFStringCopyTextString(name) as String?) == key {
                    XCTAssertTrue(CGPDFArrayGetArray(pairs, index + 1, &value))
                    return try XCTUnwrap(value)
                }
            }
        } else {
            XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "Dests", &destinations))
            var array: CGPDFArrayRef?
            XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(destinations), key, &array))
            return try XCTUnwrap(array)
        }
        throw NSError(domain: "MissingNamedDestination", code: 1)
    }

    private func primitiveSignature(_ array: CGPDFArrayRef) throws -> [String] {
        try (0..<CGPDFArrayGetCount(array)).map { index in
            var value: CGPDFObjectRef?
            XCTAssertTrue(CGPDFArrayGetObject(array, index, &value))
            let object = try XCTUnwrap(value)
            switch CGPDFObjectGetType(object) {
            case .null: return "null"
            case .name:
                var name: UnsafePointer<CChar>?
                XCTAssertTrue(CGPDFObjectGetValue(object, .name, &name))
                return "name:" + String(cString: try XCTUnwrap(name))
            case .integer:
                var integer: CGPDFInteger = 0
                XCTAssertTrue(CGPDFObjectGetValue(object, .integer, &integer))
                return "integer:\(integer)"
            case .real:
                var number: CGPDFReal = 0
                XCTAssertTrue(CGPDFObjectGetValue(object, .real, &number))
                return "realBits:\(Double(number).bitPattern)"
            default: throw NSError(domain: "UnexpectedDestinationOperand", code: index)
            }
        }
    }

    private func group(_ document: PDFDocument, _ indexes: [(Int, Int)]) -> PDFCatalogSourceGroup {
        PDFCatalogSourceGroup(document: document.documentRef!, pages: indexes.map {
            PDFCatalogPageOrigin(sourceIndex: $0.0, outputIndex: $0.1, livePage: document.page(at: $0.0)!)
        })
    }

    private func labelDictionaries(_ plan: PDFCatalogGraphPlan) throws -> [Int: [String: PDFCatalogGraphValue]] {
        guard case .dictionary(let tree) = plan.catalogEntries["PageLabels"], case .array(let numbers) = tree["Nums"] else {
            XCTFail("Expected a page label number tree."); return [:]
        }
        var result: [Int: [String: PDFCatalogGraphValue]] = [:]
        for index in stride(from: 0, to: numbers.count, by: 2) {
            guard case .integer(let page) = numbers[index], case .dictionary(let label) = numbers[index + 1] else {
                XCTFail("Expected an output page and its label."); continue
            }
            result[page] = label
        }
        return result
    }
    private func integer(_ value: PDFCatalogGraphValue?) throws -> Int {
        guard case .integer(let integer) = value else { throw NSError(domain: "PageMetadataTests", code: 1) }
        return integer
    }
    private func name(_ value: PDFCatalogGraphValue?) throws -> String {
        guard case .name(let name) = value else { throw NSError(domain: "PageMetadataTests", code: 2) }
        return name
    }
    private func bytes(_ value: PDFCatalogGraphValue?) throws -> Data {
        guard case .string(let bytes) = value else { throw NSError(domain: "PageMetadataTests", code: 3) }
        return bytes
    }
    private func fixture(labels: String? = nil, openAction: String? = nil, extraObjects: [String] = [],
                         names: String? = nil, legacyDests: String? = nil) throws -> PDFDocument {
        var catalog = "<< /Type /Catalog /Pages 2 0 R"
        if labels != nil { catalog += " /PageLabels 9 0 R" }
        if let openAction { catalog += " /OpenAction \(openAction)" }
        if let names { catalog += " /Names << /Dests << \(names) >> >>" }
        if let legacyDests { catalog += " /Dests << \(legacyDests) >>" }
        catalog += " >>"
        var objects = [catalog, "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 6 0 R 7 0 R 8 0 R] /Count 6 >>"]
        objects += (0..<6).map { _ in "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>" }
        objects.append("<< \(labels ?? "") >>")
        objects += extraObjects
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }
}
