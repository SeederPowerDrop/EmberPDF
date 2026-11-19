// SPDX-License-Identifier: MPL-2.0

import CEmberPDFRawStreams
import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFStoredNavigationMetadataTests: XCTestCase {
    func testFixedEmptyNameAndExactActionReadersKeepTypeAndNulDistinctions() throws {
        let bytes = fixtureData(extra: "/Atoms [/ /chapter (/) null] /Actions [<< /S /GoTo /D / >> << /S /GoTo /D (/) >> << /S /GoTo /D / /Next null >> << /S /URI /D / >> null]")
        let raw = try Reader(bytes)
        let atoms = try raw.value(raw.catalog, "Atoms")
        for index in 0..<4 {
            var result: Int32 = 9
            XCTAssertEqual(ember_raw_pdf_name_is_empty(raw.context, try raw.item(atoms, index), &result), 0)
            XCTAssertEqual(result, index == 0 ? 1 : 0, "name atom \(index)")
        }
        let actions = try raw.value(raw.catalog, "Actions")
        for index in 0..<5 {
            var result: Int32 = 9
            XCTAssertEqual(ember_raw_pdf_exact_empty_goto_action(raw.context, try raw.item(actions, index), &result), 0)
            XCTAssertEqual(result, index == 0 ? 1 : 0, "action atom \(index)")
        }
        for invalid in [EmberRawPDFObject(0), EmberRawPDFObject.max] {
            var result: Int32 = 9
            XCTAssertNotEqual(ember_raw_pdf_name_is_empty(raw.context, invalid, &result), 0)
            XCTAssertEqual(result, 0)
            result = 9
            XCTAssertNotEqual(ember_raw_pdf_exact_empty_goto_action(raw.context, invalid, &result), 0)
            XCTAssertEqual(result, 0)
        }
        var result: Int32 = 9
        XCTAssertNotEqual(ember_raw_pdf_name_is_empty(nil, try raw.item(atoms, 0), &result), 0)
        XCTAssertEqual(result, 0)
        // Strict QPDF rejects NUL in a PDF name before any scalar reader can
        // prove it. Keep these invalid sources separate from the positive PDF.
        for extra in ["/Probe /#00", "/OpenAction << /S /GoTo /D /#00 >>", "/OpenAction << /S /GoTo#00 /D / >>"] {
            let invalid = fixtureData(extra: extra)
            var status: Int32 = 9
            let rejected = invalid.withUnsafeBytes { ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, invalid.count, 4 * 1024 * 1024, 10_000, &status) }
            XCTAssertNil(rejected)
            XCTAssertEqual(status, Int32(EMBER_RAW_PDF_PARSE.rawValue))
            if let rejected { ember_raw_pdf_destroy(rejected) }
        }
    }

    @MainActor
    func testStoredNullScalarsAndSingleDWrappersSurviveWorkerExtractMergeAndResave() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for modern in [false, true] {
            let definitions = modern
                ? "/Names [(good) [5 0 R /Fit] (scalar) null (wrapped) << /D [null /XYZ 125.067 620.92 null] >>]"
                : "/good [5 0 R /Fit] /scalar null /wrapped << /D [null /XYZ 125.067 620.92 null] >>"
            let bytes = fixtureData(modern: modern ? definitions : nil, legacy: modern ? nil : definitions)
            let sourceURL = directory.appendingPathComponent("source-\(modern).pdf")
            try bytes.write(to: sourceURL)
            let source = try PDFSourceFileAccess.loadDocument(at: sourceURL).document
            let expected = try Reader(bytes).storedSignatures(modern: modern, keys: ["scalar", "wrapped"])
            XCTAssertEqual(expected["scalar"], "null")
            XCTAssertEqual(expected["wrapped"], "dict{/D:array[null,name:2f58595a,real:\(125.067.bitPattern),real:\(620.92.bitPattern),null]}")
            let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 2])
            let firstURL = directory.appendingPathComponent("selected-\(modern).pdf")
            let first = try await saved(extracted, to: firstURL)
            try assertStored(first, modern: modern, expected: expected, validPage: 1)
            let reopened = try PDFSourceFileAccess.loadDocument(at: firstURL).document
            let target = try bound(fixtureData())
            let imported = try PDFPageStructurePreserver.prepareImport(from: reopened, indexes: [0, 1])
            let merge = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: target, at: 1)
            try merge.apply(); try merge.undo(); try merge.redo()
            let mergedURL = directory.appendingPathComponent("merged-\(modern).pdf")
            let merged = try await saved(target, to: mergedURL)
            try assertStored(merged, modern: modern, expected: expected, validPage: 2)
            let resave = try PDFSourceFileAccess.loadDocument(at: mergedURL).document
            let final = try await saved(resave, to: directory.appendingPathComponent("resaved-\(modern).pdf"))
            try assertStored(final, modern: modern, expected: expected, validPage: 2)
            XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
        }
    }

    @MainActor
    func testRawVerifiedEmptyOpeningActionSurvivesWorkerExtractMergeAndResave() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = fixtureData(opening: "<< /S /GoTo /D / >>", modern: "/Names [(good) [5 0 R /Fit]]")
        let sourceURL = directory.appendingPathComponent("source.pdf")
        try bytes.write(to: sourceURL)
        let source = try PDFSourceFileAccess.loadDocument(at: sourceURL).document
        let expected = try Reader(bytes).openingSignature()
        XCTAssertEqual(expected, "dict{/D:name:2f,/S:name:2f476f546f}")
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 2])
        let firstURL = directory.appendingPathComponent("selected.pdf")
        let first = try await saved(extracted, to: firstURL)
        XCTAssertEqual(try Reader(first).openingSignature(), expected)
        let reopened = try PDFSourceFileAccess.loadDocument(at: firstURL).document
        let target = try bound(fixtureData())
        let imported = try PDFPageStructurePreserver.prepareImport(from: reopened, indexes: [0, 1])
        let transaction = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: target, at: 1)
        try transaction.apply()
        let mergedURL = directory.appendingPathComponent("merged.pdf")
        let merged = try await saved(target, to: mergedURL)
        XCTAssertEqual(try Reader(merged).openingSignature(), expected)
        let resave = try PDFSourceFileAccess.loadDocument(at: mergedURL).document
        let final = try await saved(resave, to: directory.appendingPathComponent("resaved.pdf"))
        XCTAssertEqual(try Reader(final).openingSignature(), expected)
        XCTAssertFalse(try Reader(final).hasLegacyEmptyName())
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
    }

    @MainActor
    func testRawVerifiedNullFitOpeningActionSurvivesWorkerExtractMergeAndResave() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = fixtureData(opening: "<< /S /GoTo /D [null /Fit] >>")
        let sourceURL = directory.appendingPathComponent("null-fit-source.pdf")
        try bytes.write(to: sourceURL)
        let source = try PDFSourceFileAccess.loadDocument(at: sourceURL).document
        let expected = "dict{/D:array[null,name:2f466974],/S:name:2f476f546f}"
        XCTAssertEqual(try Reader(bytes).openingSignature(), expected)
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 2])
        let firstURL = directory.appendingPathComponent("null-fit-selected.pdf")
        let first = try await saved(extracted, to: firstURL)
        XCTAssertEqual(try Reader(first).openingSignature(), expected)
        let reopened = try PDFSourceFileAccess.loadDocument(at: firstURL).document
        let target = try bound(fixtureData())
        let imported = try PDFPageStructurePreserver.prepareImport(from: reopened, indexes: [0, 1])
        let merge = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: target, at: 1)
        try merge.apply(); try merge.undo(); try merge.redo()
        let mergedURL = directory.appendingPathComponent("null-fit-merged.pdf")
        let merged = try await saved(target, to: mergedURL)
        XCTAssertEqual(try Reader(merged).openingSignature(), expected)
        let resaved = try PDFSourceFileAccess.loadDocument(at: mergedURL).document
        let final = try await saved(resaved, to: directory.appendingPathComponent("null-fit-final.pdf"))
        XCTAssertEqual(try Reader(final).openingSignature(), expected)
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
    }

    @MainActor
    func testNullFitOpeningActionProofIsWorkerBoundCacheOnlyAndCancellationSafe() async throws {
        let bytes = fixtureData(opening: "<< /S /GoTo /D [null /Fit] >>")
        let source = try bound(bytes), raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
        let owner = try XCTUnwrap(source.documentRef), action = try nativeAction(owner)
        let before = raw.widgetInputFootprint
        XCTAssertFalse(try raw.provesOriginalNullFitOpeningAction(in: owner, action: action))
        XCTAssertEqual(raw.widgetInputFootprint.storage, before.storage)
        XCTAssertEqual(raw.widgetInputFootprint.ownedDataBytes, before.ownedDataBytes)
        let foreign = try bound(bytes), foreignOwner = try XCTUnwrap(foreign.documentRef)
        let foreignAction = try nativeAction(foreignOwner)
        XCTAssertFalse(try raw.provesOriginalNullFitOpeningAction(in: foreignOwner, action: foreignAction))
        XCTAssertFalse(try raw.provesOriginalNullFitOpeningAction(in: owner, action: foreignAction))
        let cancelled = PDFSaveCancellation(); cancelled.cancel()
        do {
            _ = try await Task.detached {
                try PDFSaveCancellation.withCurrent(cancelled) { try raw.provesOriginalNullFitOpeningAction(in: owner, action: action) }
            }.value
            XCTFail("Cancelled proof must not publish positive state")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(try raw.provesOriginalNullFitOpeningAction(in: owner, action: action))
        let proved = try await Task.detached { try raw.provesOriginalNullFitOpeningAction(in: owner, action: action) }.value
        XCTAssertTrue(proved)
        XCTAssertTrue(try raw.provesOriginalNullFitOpeningAction(in: owner, action: action))
        let unbound = try XCTUnwrap(PDFDocument(data: bytes))
        PDFRawStreamProvenance.bindCreated(unbound, data: bytes)
        let unboundRaw = try XCTUnwrap(PDFRawStreamProvenance.source(for: unbound))
        let unboundOwner = try XCTUnwrap(unbound.documentRef), unboundAction = try nativeAction(unboundOwner)
        let rejected = try await Task.detached { try unboundRaw.provesOriginalNullFitOpeningAction(in: unboundOwner, action: unboundAction) }.value
        XCTAssertFalse(rejected)
    }

    @MainActor
    func testNullFitOpeningActionProofRejectsOtherTargetsViewsAliasesAndExtraFields() async throws {
        let invalid = [
            "<< /S /GoTo /D [null /Fit] /Next null >>",
            "<< /S /GoTo /D [null /Fit] /Extra null >>",
            "<< /S /GoTo /D [null /Fit 0] >>",
            "<< /S /GoTo /D [null /FitB] >>",
            "<< /S /GoTo /D [null /XYZ 0 0 0] >>",
            "<< /S /GoTo /D [null (Fit)] >>",
            "<< /S /GoTo /D [false /Fit] >>",
            "<< /S /GoTo /D [(null) /Fit] >>",
            "<< /S /GoTo /D [5 0 R /Fit] >>",
            "<< /S /GoTo /D /chapter >>",
            "<< /S /GoTo /D << /D [null /Fit] >> >>",
            "<< /S /URI /D [null /Fit] >>",
            "<< /S (GoTo) /D [null /Fit] >>"
        ]
        for opening in invalid {
            let source = try bound(fixtureData(opening: opening)), raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
            let owner = try XCTUnwrap(source.documentRef), action = try nativeAction(owner)
            let accepted = try await Task.detached { try raw.provesOriginalNullFitOpeningAction(in: owner, action: action) }.value
            XCTAssertFalse(accepted, opening)
        }
    }

    @MainActor
    func testNullFitExceptionDoesNotChangeValidOpeningDestinationRemapping() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try bound(fixtureData(opening: "<< /S /GoTo /D [5 0 R /Fit] >>"))
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0, 2])
        let bytes = try await saved(extracted, to: directory.appendingPathComponent("valid-opening-remapped.pdf"))
        let raw = try Reader(bytes), action = try raw.value(raw.catalog, "OpenAction")
        let destination = try raw.value(action, "D")
        var page: EmberRawPDFObject = 0
        XCTAssertEqual(ember_raw_pdf_page(raw.context, 1, &page), 0)
        XCTAssertEqual(try raw.item(destination, 0), page)
        XCTAssertEqual(try raw.copied(raw.item(destination, 1), name: true), Data("/Fit".utf8))
    }

    @MainActor
    func testEmptyActionProofRejectsColdMainForeignUnboundNulAndCancellation() async throws {
        let bytes = fixtureData(opening: "<< /S /GoTo /D / >>")
        let source = try bound(bytes)
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
        let native = try XCTUnwrap(source.documentRef)
        let action = try nativeAction(native)
        let before = raw.widgetInputFootprint
        XCTAssertFalse(try raw.provesOriginalEmptyOpeningAction(in: native, action: action))
        XCTAssertEqual(raw.widgetInputFootprint.storage, before.storage)
        XCTAssertEqual(raw.widgetInputFootprint.ownedDataBytes, before.ownedDataBytes)
        let foreign = try bound(bytes)
        XCTAssertFalse(try raw.provesOriginalEmptyOpeningAction(in: try XCTUnwrap(foreign.documentRef), action: action))
        let proved = try await Task.detached { try raw.provesOriginalEmptyOpeningAction(in: native, action: action) }.value
        XCTAssertTrue(proved)
        XCTAssertTrue(try raw.provesOriginalEmptyOpeningAction(in: native, action: action))
        let cancelled = PDFSaveCancellation(); cancelled.cancel()
        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(cancelled) {
            try raw.provesOriginalEmptyOpeningAction(in: native, action: action)
        }) { XCTAssertTrue($0 is CancellationError) }
        var unboundPlan = PDFCatalogGraphPlan()
        let unbound = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertThrowsError(try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(unbound, [0])], to: &unboundPlan))
        XCTAssertTrue(unboundPlan.catalogEntries.isEmpty)
        for spelling in ["/#00", "/chapter", "(/)"] {
            let bytes = fixtureData(opening: "<< /S /GoTo /D \(spelling) >>")
            guard let malformed = PDFRawStreamProvenance.createdDocument(data: bytes) else {
                // The system reader may reject an invalid NUL name before
                // provenance exists. Valid nonempty/name-string inputs must load.
                XCTAssertEqual(spelling, "/#00", "Only the invalid NUL-name source may be rejected at construction")
                continue
            }
            let reader = try XCTUnwrap(PDFRawStreamProvenance.source(for: malformed))
            let owner = try XCTUnwrap(malformed.documentRef)
            let candidate = try nativeAction(owner)
            let accepted = try await Task.detached { try reader.provesOriginalEmptyOpeningAction(in: owner, action: candidate) }.value
            XCTAssertFalse(accepted, spelling)
        }
    }

    @MainActor
    func testEmptyOpeningActionCannotResolveThroughAnotherMergedSourcesEmptyName() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try bound(fixtureData(opening: "<< /S /GoTo /D / >>"))
        let donor = try bound(fixtureData(legacy: "/ [3 0 R /Fit]"))
        let imported = try PDFPageStructurePreserver.prepareImport(from: donor, indexes: [0])
        let merge = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: source, at: 1)
        try merge.apply()
        let destination = directory.appendingPathComponent("must-not-exist.pdf")
        do { _ = try await saved(source, to: destination); XCTFail("A foreign empty-name target must not revive the original broken action") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path)) }
        let allowedSource = try bound(fixtureData(opening: "<< /S /GoTo /D / >>"))
        let excludedDonor = try bound(fixtureData(legacy: "/ [3 0 R /Fit]"))
        let excluded = try PDFPageStructurePreserver.prepareImport(from: excludedDonor, indexes: [1])
        let allowedMerge = try PDFPageStructurePreserver.prepareMerge(imports: [excluded], into: allowedSource, at: 1)
        try allowedMerge.apply()
        let output = try await saved(allowedSource, to: directory.appendingPathComponent("excluded-target.pdf"))
        XCTAssertEqual(try Reader(output).openingSignature(), "dict{/D:name:2f,/S:name:2f476f546f}")
        XCTAssertFalse(try Reader(output).hasLegacyEmptyName())
    }

    func testStoredExceptionsKeepActiveAliasesExtraKeysViewsAndTailsStrict() throws {
        let invalid = [
            fixtureData(opening: "<< /S /GoTo /D /chapter >>"),
            fixtureData(opening: "<< /S /GoTo /D / /Next null >>"),
            fixtureData(opening: "<< /S /GoTo /D null >>"),
            fixtureData(opening: "<< /S /GoTo /D [null /XYZ 1 2 0] >>"),
            fixtureData(legacy: "/alias /dead /dead null"),
            fixtureData(modern: "/Names [(alias) (dead) (dead) null]"),
            fixtureData(legacy: "/dead << /D [null /XYZ 1 2 0] /Next null >>"),
            fixtureData(legacy: "/dead << /D << /D [null /XYZ 1 2 0] >> >>"),
            fixtureData(legacy: "/dead << /D [null /Unknown] >>"),
            fixtureData(legacy: "/dead << /D [null /Fit 1] >>"),
            fixtureData(legacy: "/dead << /D [null /XYZ true 2 0] >>"),
            fixtureData(legacy: "/dead << /D [null /XYZ (NaN) 2 0] >>")
        ]
        for bytes in invalid {
            let source = try bound(bytes)
            var plan = PDFCatalogGraphPlan(); plan.catalogEntries["Sentinel"] = .boolean(true)
            XCTAssertThrowsError(try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(source, [0, 2])], to: &plan))
            XCTAssertEqual(plan.catalogEntries.count, 1)
            guard case .boolean(true) = plan.catalogEntries["Sentinel"] else { return XCTFail("Failure partially changed the caller's plan") }
        }
    }

    @MainActor
    func testStoredNumberProofIsWorkerBoundCacheOnlyAndRejectsForeignSlots() async throws {
        let definitions = "/wrapped << /D [null /XYZ 125.067 620.92 null] >>"
        let bytes = fixtureData(legacy: definitions)
        let source = try bound(bytes), raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
        let originalArray = try legacyStoredArray(source)
        let before = raw.widgetInputFootprint
        try raw.prepareStoredDestinationNumbers()
        XCTAssertEqual(raw.widgetInputFootprint.storage, before.storage)
        XCTAssertEqual(raw.widgetInputFootprint.ownedDataBytes, before.ownedDataBytes)
        XCTAssertNil(try raw.numberCorrectionContainers())
        let foreign = try bound(bytes), foreignArray = try legacyStoredArray(foreign)
        try await Task.detached { try raw.prepareStoredDestinationNumbers() }.value
        guard case .real(let value)? = try raw.originalNumber(in: originalArray, index: 2) else {
            return XCTFail("The proven original catalog slot needs its exact raw correction")
        }
        XCTAssertEqual(value.bitPattern, 125.067.bitPattern)
        XCTAssertNil(try raw.originalNumber(in: foreignArray, index: 2))
        let containers = try XCTUnwrap(raw.numberCorrectionContainers())
        XCTAssertEqual(containers.arrays, Set([pdfReferenceIdentity(originalArray)]))
        XCTAssertTrue(containers.dictionaries.isEmpty)
        let prepared = raw.widgetInputFootprint
        try raw.prepareStoredDestinationNumbers()
        XCTAssertEqual(raw.widgetInputFootprint.storage, prepared.storage)
        XCTAssertEqual(raw.widgetInputFootprint.ownedDataBytes, prepared.ownedDataBytes)

        let unbound = try XCTUnwrap(PDFDocument(data: bytes))
        PDFRawStreamProvenance.bindCreated(unbound, data: bytes)
        let unboundRaw = try XCTUnwrap(PDFRawStreamProvenance.source(for: unbound))
        let unboundBefore = unboundRaw.widgetInputFootprint
        try await Task.detached { try unboundRaw.prepareStoredDestinationNumbers() }.value
        XCTAssertNil(try unboundRaw.numberCorrectionContainers())
        XCTAssertEqual(unboundRaw.widgetInputFootprint.storage, unboundBefore.storage)
        let cancelledSource = try bound(bytes), cancelledRaw = try XCTUnwrap(PDFRawStreamProvenance.source(for: cancelledSource))
        let cancelledBefore = cancelledRaw.widgetInputFootprint
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        do {
            try await Task.detached {
                try PDFSaveCancellation.withCurrent(cancellation) { try cancelledRaw.prepareStoredDestinationNumbers() }
            }.value
            XCTFail("Cancelled proof must not publish corrections")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try cancelledRaw.numberCorrectionContainers())
        XCTAssertEqual(cancelledRaw.widgetInputFootprint.storage, cancelledBefore.storage)
        XCTAssertEqual(cancelledRaw.widgetInputFootprint.ownedDataBytes, cancelledBefore.ownedDataBytes)
    }

    @MainActor
    func testWorkerPreservesStoredNumbersForMetadataPlanAlreadyPreparedOnMain() async throws {
        for modern in [false, true] {
            let definitions = modern
                ? "/Kids [<< /Kids [<< /Names [(wrapped) << /D [null /XYZ 125.067 620.92 null] >>] >>] >>]"
                : "/wrapped << /D [null /XYZ 125.067 620.92 null] >>"
            let bytes = fixtureData(modern: modern ? definitions : nil, legacy: modern ? nil : definitions)
            let source = try bound(bytes), raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
            var plan = PDFCatalogGraphPlan()
            try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(source, Array(0..<6))], to: &plan)
            plan.rawStreamSources = [raw]
            XCTAssertNil(try raw.numberCorrectionContainers(), "Main metadata plan must not initialize a raw parser")
            let serialized = try XCTUnwrap(source.dataRepresentation())
            let output = try await Task.detached {
                try PDFBodyTextPageSnapshot.preservingCatalog(in: serialized, from: source, plan: plan)
            }.value
            let actual = try Reader(output).storedSignatures(modern: modern, keys: ["wrapped"])
            XCTAssertEqual(actual["wrapped"], "dict{/D:array[null,name:2f58595a,real:\(125.067.bitPattern),real:\(620.92.bitPattern),null]}")
        }
    }

    @MainActor
    func testManyStoredNullRealDestinationsStayWithinTheCorrectionBudget() async throws {
        // Six thousand real slots fit the unchanged correction budget. The
        // SDK may already parse some scalars exactly, so only discrepancies
        // require retained corrections; every output definition must be exact.
        let keys = (0..<3_000).map { "n\($0)" }
        let definitions = keys.map { "/\($0) [null /XYZ 125.067 620.92 null]" }.joined(separator: " ")
        let bytes = fixtureData(legacy: definitions)
        let source = try bound(bytes)
        let catalog = try XCTUnwrap(source.documentRef?.catalog)
        let stored = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(catalog, "Dests"))
        let originalStoredIdentity = pdfReferenceIdentity(stored)
        XCTAssertEqual(CGPDFDictionaryGetCount(stored), keys.count)
        func nativeCoordinateBits(_ dictionary: CGPDFDictionaryRef) throws -> [UInt64] {
            var result: [UInt64] = []
            result.reserveCapacity(keys.count * 2)
            for key in keys {
                let array = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, key))
                XCTAssertEqual(CGPDFArrayGetCount(array), 5)
                for index in [2, 3] {
                    var value: CGPDFReal = 0
                    XCTAssertTrue(CGPDFArrayGetNumber(array, index, &value))
                    result.append(Double(value).bitPattern)
                }
            }
            return result
        }
        let sourceBefore = try nativeCoordinateBits(stored)
        let sourcePageCount = source.pageCount
        // PDFKit's staging serialization need not retain these null-target
        // definitions: the catalog plan below restores them from the source.
        let serialized = try XCTUnwrap(source.dataRepresentation())
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
        try await Task.detached { try raw.prepareStoredDestinationNumbers() }.value
        XCTAssertLessThanOrEqual(raw.numberCorrectionFootprint.entries, 6_000)
        XCTAssertLessThanOrEqual(raw.numberCorrectionFootprint.accountedBytes, 1_024 * 1_024)
        for key in ["n0", "n1499", "n2999"] {
            let array = try XCTUnwrap(PDFCatalogStructurePreserver.array(stored, key))
            for (index, expected) in [(2, 125.067), (3, 620.92)] {
                if let correction = try raw.originalNumber(in: array, index: index) {
                    guard case .real(let actual) = correction else {
                        return XCTFail("A real destination coordinate needs a real correction")
                    }
                    XCTAssertEqual(actual.bitPattern, expected.bitPattern)
                } else {
                    var actual: CGPDFReal = 0
                    XCTAssertTrue(CGPDFArrayGetNumber(array, index, &actual))
                    XCTAssertEqual(Double(actual).bitPattern, expected.bitPattern)
                }
            }
        }
        // Fresh readers keep each batch below the existing 10,000 native
        // handle ceiling while checking all definitions without raising it.
        func allStoredSignatures(_ data: Data) throws -> [String: String] {
            var result: [String: String] = [:]
            for start in stride(from: 0, to: keys.count, by: 500) {
                let batch = Array(keys[start..<min(start + 500, keys.count)])
                let observed = try Reader(data).storedSignatures(modern: false, keys: batch)
                result.merge(observed) { _, _ in preconditionFailure("Disjoint destination batches must not overlap") }
            }
            return result
        }
        let expected = "array[null,name:2f58595a,real:\(125.067.bitPattern),real:\(620.92.bitPattern),null]"
        let expectedDefinitions = Dictionary(uniqueKeysWithValues: keys.map { ($0, expected) })
        XCTAssertEqual(try allStoredSignatures(bytes), expectedDefinitions)
        var plan = PDFCatalogGraphPlan()
        try PDFCatalogPageMetadataPreserver.addPageMetadata(from: [group(source, Array(0..<6))], to: &plan)
        plan.rawStreamSources = [raw]
        let output = try await Task.detached {
            try PDFBodyTextPageSnapshot.preservingCatalog(in: serialized, from: source, plan: plan)
        }.value
        let outputReader = try Reader(output)
        let outputDefinitions = try outputReader.value(outputReader.catalog, "Dests")
        var outputCount: UInt32 = 0
        XCTAssertEqual(ember_raw_pdf_dictionary_count(outputReader.context, outputDefinitions, &outputCount), 0)
        XCTAssertEqual(Int(outputCount), keys.count)
        XCTAssertEqual(try allStoredSignatures(output), expectedDefinitions)
        XCTAssertEqual(source.pageCount, sourcePageCount)
        let currentCatalog = try XCTUnwrap(source.documentRef?.catalog)
        let currentStored = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(currentCatalog, "Dests"))
        XCTAssertEqual(pdfReferenceIdentity(currentStored), originalStoredIdentity)
        XCTAssertEqual(CGPDFDictionaryGetCount(currentStored), keys.count)
        XCTAssertEqual(try nativeCoordinateBits(currentStored), sourceBefore)
    }

    @MainActor
    func testStoredNumberProofDoesNotPublishPartialCorrectionsWhenBudgetIsExceeded() async throws {
        // Each accepted definition can need two corrections. This exceeds the
        // existing 16,384 correction ceiling while staying below candidate,
        // graph-visit, input and retained-metadata budgets.
        let definitions = (0..<9_000).map { "/n\($0) [null /XYZ 125.067 125.067 null]" }.joined(separator: " ")
        let source = try bound(fixtureData(legacy: definitions))
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
        do {
            try await Task.detached { try raw.prepareStoredDestinationNumbers() }.value
            XCTFail("A bounded proof must refuse before publishing a partial set")
        } catch { XCTAssertFalse(error is CancellationError) }
        let containers = try raw.numberCorrectionContainers()
        XCTAssertTrue(containers?.arrays.isEmpty ?? true)
        XCTAssertTrue(containers?.dictionaries.isEmpty ?? true)
    }

    private func legacyStoredArray(_ document: PDFDocument) throws -> CGPDFArrayRef {
        let catalog = try XCTUnwrap(document.documentRef?.catalog)
        let definitions = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(catalog, "Dests"))
        let wrapper = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(definitions, "wrapped"))
        return try XCTUnwrap(PDFCatalogStructurePreserver.array(wrapper, "D"))
    }

    @MainActor
    private func saved(_ document: PDFDocument, to url: URL) async throws -> Data {
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let request = try PDFBackgroundSaveRequest(destinationURL: url, originalURL: nil, overwritingOriginal: false)
        _ = try await PDFBackgroundSaveWriter.write(snapshot: snapshot, request: request, cancellation: PDFSaveCancellation())
        return try Data(contentsOf: url)
    }
    private func assertStored(_ bytes: Data, modern: Bool, expected: [String: String], validPage: Int) throws {
        let raw = try Reader(bytes)
        XCTAssertEqual(try raw.storedSignatures(modern: modern, keys: ["scalar", "wrapped"]), expected)
        let destination = try raw.named("good", modern: modern)
        var page: EmberRawPDFObject = 0
        XCTAssertEqual(ember_raw_pdf_page(raw.context, UInt32(validPage), &page), 0)
        XCTAssertEqual(try raw.item(destination, 0), page, "Valid destination must still point at the intended remapped page")
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-stored-navigation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func bound(_ bytes: Data) throws -> PDFDocument { try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes)) }
    private func nativeAction(_ document: CGPDFDocument) throws -> CGPDFDictionaryRef {
        let catalog = try XCTUnwrap(document.catalog)
        return try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(catalog, "OpenAction"))
    }
    private func group(_ document: PDFDocument, _ indexes: [Int]) -> PDFCatalogSourceGroup {
        PDFCatalogSourceGroup(document: document.documentRef!, pages: indexes.enumerated().map {
            PDFCatalogPageOrigin(sourceIndex: $0.element, outputIndex: $0.offset, livePage: document.page(at: $0.element)!)
        }, rawStreamSource: PDFRawStreamProvenance.source(for: document))
    }
    private func fixtureData(opening: String? = nil, modern: String? = nil, legacy: String? = nil, extra: String = "") -> Data {
        var catalog = "<< /Type /Catalog /Pages 2 0 R"
        if let opening { catalog += " /OpenAction \(opening)" }
        if let modern { catalog += " /Names << /Dests << \(modern) >> >>" }
        if let legacy { catalog += " /Dests << \(legacy) >>" }
        catalog += " \(extra) >>"
        let objects = [catalog, "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 6 0 R 7 0 R 8 0 R] /Count 6 >>"]
            + (0..<6).map { _ in "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << >> >>" }
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }

    private final class Reader {
        let context: EmberRawPDFRef
        let catalog: EmberRawPDFObject
        init(_ bytes: Data) throws {
            var status: Int32 = 9
            let raw = bytes.withUnsafeBytes { ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, bytes.count, 4 * 1024 * 1024, 10_000, &status) }
            guard status == 0, let raw else { throw NSError(domain: "RawNavigationFixture", code: Int(status)) }
            context = raw
            var root: EmberRawPDFObject = 0
            guard ember_raw_pdf_catalog(raw, &root) == 0 else { ember_raw_pdf_destroy(raw); throw NSError(domain: "RawNavigationCatalog", code: 1) }
            catalog = root
        }
        deinit { ember_raw_pdf_destroy(context) }
        func value(_ object: EmberRawPDFObject, _ key: String) throws -> EmberRawPDFObject {
            var result: EmberRawPDFObject = 0
            let status = Array(("/" + key).utf8).withUnsafeBufferPointer { ember_raw_pdf_dictionary_get(context, object, $0.baseAddress, $0.count, &result) }
            guard status == 0 else { throw NSError(domain: "RawNavigationKey", code: Int(status)) }; return result
        }
        func item(_ object: EmberRawPDFObject, _ index: Int) throws -> EmberRawPDFObject {
            var result: EmberRawPDFObject = 0
            guard ember_raw_pdf_array_item(context, object, UInt32(index), &result) == 0 else { throw NSError(domain: "RawNavigationItem", code: index) }; return result
        }
        func copied(_ object: EmberRawPDFObject, name: Bool) throws -> Data {
            var pointer: UnsafeMutablePointer<UInt8>?, count = 0
            let status = name ? ember_raw_pdf_name_copy(context, object, &pointer, &count) : ember_raw_pdf_string_copy(context, object, &pointer, &count)
            defer { if let pointer { ember_raw_pdf_free(pointer) } }
            guard status == 0, count <= 4096, count == 0 || pointer != nil else { throw NSError(domain: "RawNavigationScalar", code: Int(status)) }
            return pointer.map { Data(bytes: $0, count: count) } ?? Data()
        }
        func named(_ key: String, modern: Bool) throws -> EmberRawPDFObject {
            if !modern { return try value(value(catalog, "Dests"), key) }
            let pairs = try value(value(value(catalog, "Names"), "Dests"), "Names")
            var count: UInt32 = 0
            guard ember_raw_pdf_array_count(context, pairs, &count) == 0, count <= 64, count % 2 == 0 else { throw NSError(domain: "RawNavigationNames", code: 1) }
            for i in stride(from: 0, to: Int(count), by: 2) where try copied(item(pairs, i), name: false) == Data(key.utf8) { return try item(pairs, i + 1) }
            throw NSError(domain: "RawNavigationNameMissing", code: 1)
        }
        func storedSignatures(modern: Bool, keys: [String]) throws -> [String: String] {
            try Dictionary(uniqueKeysWithValues: keys.map { ($0, try signature(named($0, modern: modern))) })
        }
        func openingSignature() throws -> String { try signature(value(catalog, "OpenAction")) }
        func hasLegacyEmptyName() throws -> Bool {
            let destinations = try value(catalog, "Dests")
            var kind: Int32 = 0; XCTAssertEqual(ember_raw_pdf_kind(context, destinations, &kind), 0)
            guard kind == Int32(EMBER_RAW_PDF_DICTIONARY.rawValue) else { return false }
            return try dictionaryKeys(destinations).contains(Data([47]))
        }
        private func dictionaryKeys(_ object: EmberRawPDFObject) throws -> [Data] {
            var count: UInt32 = 0
            guard ember_raw_pdf_dictionary_count(context, object, &count) == 0, count <= 64 else { throw NSError(domain: "RawNavigationKeys", code: 1) }
            return try (0..<count).map { index in
                var pointer: UnsafeMutablePointer<UInt8>?, length = 0
                let status = ember_raw_pdf_dictionary_key_copy(context, object, index, &pointer, &length)
                defer { if let pointer { ember_raw_pdf_free(pointer) } }
                guard status == 0, length <= 4096, length == 0 || pointer != nil else { throw NSError(domain: "RawNavigationKeyBytes", code: 1) }
                return pointer.map { Data(bytes: $0, count: length) } ?? Data()
            }
        }
        private func signature(_ object: EmberRawPDFObject, depth: Int = 0) throws -> String {
            guard depth <= 8 else { throw NSError(domain: "RawNavigationDepth", code: 1) }
            var kind: Int32 = 0; XCTAssertEqual(ember_raw_pdf_kind(context, object, &kind), 0)
            switch kind {
            case Int32(EMBER_RAW_PDF_NULL.rawValue): return "null"
            case Int32(EMBER_RAW_PDF_NAME.rawValue): return "name:" + hex(try copied(object, name: true))
            case Int32(EMBER_RAW_PDF_STRING.rawValue): return "string:" + hex(try copied(object, name: false))
            case Int32(EMBER_RAW_PDF_INTEGER.rawValue):
                var n: Int64 = 0; XCTAssertEqual(ember_raw_pdf_integer(context, object, &n), 0); return "integer:\(n)"
            case Int32(EMBER_RAW_PDF_REAL.rawValue):
                var n: Double = 0; XCTAssertEqual(ember_raw_pdf_real(context, object, &n), 0); return "real:\(n.bitPattern)"
            case Int32(EMBER_RAW_PDF_ARRAY.rawValue):
                var count: UInt32 = 0; XCTAssertEqual(ember_raw_pdf_array_count(context, object, &count), 0)
                guard count <= 64 else { throw NSError(domain: "RawNavigationArray", code: 1) }
                return try "array[" + (0..<count).map { try signature(item(object, Int($0)), depth: depth + 1) }.joined(separator: ",") + "]"
            case Int32(EMBER_RAW_PDF_DICTIONARY.rawValue):
                return try "dict{" + dictionaryKeys(object).sorted { $0.lexicographicallyPrecedes($1) }.map { key in
                    let text = String(data: key, encoding: .utf8)!
                    return text + ":" + (try signature(value(object, String(text.dropFirst())), depth: depth + 1))
                }.joined(separator: ",") + "}"
            default: throw NSError(domain: "RawNavigationUnexpectedKind", code: Int(kind))
            }
        }
        private func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    }
}
