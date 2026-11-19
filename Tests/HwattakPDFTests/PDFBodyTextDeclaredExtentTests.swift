// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import CPDFium
import CryptoKit
import PDFKit
import XCTest
@testable import HwattakPDF

/// All masks are captured from the source target, before any replacement.
/// Opt-in original fixtures supplement the small deterministic regressions.
@MainActor
final class PDFBodyTextDeclaredExtentTests: XCTestCase {

    func testTransformedRootClipKeepsDeclaredSlackAcrossTwoAtomicColdSaves() throws {
        let source = try transformedRoundTripUnderlayFixture()
        let original = try XCTUnwrap(source.page(at: 0))
        let initial = try target("iii", on: original)
        let originalBytes = try PDFBodyTextPageSnapshot.data(for: original)
        // Fixed before any output: both short words and their antialiasing
        // fit here, independently of the result's marker or declaration.
        let editedRegion = CGRect(x: 45, y: 170, width: 100, height: 40)
        XCTAssertTrue(initial.paintBounds.contains(editedRegion))
        XCTAssertGreaterThan(initial.paintBounds.width, 140)
        let outside = try pixelsOutside(editedRegion, on: original)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-Transformed-Underlay-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var completed = false
        defer {
            if completed { try? FileManager.default.removeItem(at: folder) }
            else { print("BODY_UNDERLAY_ROUNDTRIP_FAILED_OUTPUTS", folder.path) }
        }
        try originalBytes.write(to: folder.appendingPathComponent("before.pdf"))
        var current = source
        for (cycle, pair) in [("iii", "ii"), ("ii", "iii")].enumerated() {
            let page = try XCTUnwrap(current.page(at: 0))
            if cycle > 0 { try recordTransformedUnderlayMarker(on: page, initial: initial.paintBounds) }
            let selected = try target(pair.0, on: page)
            XCTAssertTrue(initial.paintBounds.contains(selected.paintBounds),
                "A saved marker must never expand the original declaration.")
            XCTAssertTrue(selected.paintBounds.contains(editedRegion),
                "An inverse/serialized marker roundtrip cannot turn a proved broad underlay into source-only clearance.")
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
                text: pair.1, style: selected.style, bounds: selected.bounds)
            XCTAssertEqual(try pixelsOutside(editedRegion, on: edited), outside)
            let wrapper = PDFDocument(); wrapper.insert(edited, at: 0)
            let url = folder.appendingPathComponent("cold-\(cycle).pdf")
            try saveSnapshot(wrapper, to: url)
            current = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Data(contentsOf: url)))
            let cold = try XCTUnwrap(current.page(at: 0))
            XCTAssertTrue(cold.string?.contains(pair.1) == true)
            XCTAssertEqual(try pixelsOutside(editedRegion, on: cold), outside)
            let content = try PDFBodyTextPageSnapshot.contentData(for: cold)
            XCTAssertTrue(content.starts(with: Data(Self.transformedRoundTripUnderlayPrefix.utf8)),
                "The root CTM, exact clip and opaque painting prefix remain immutable.")
        }
        let finalPage = try XCTUnwrap(current.page(at: 0))
        try recordTransformedUnderlayMarker(on: finalPage, initial: initial.paintBounds)
        let finalTarget = try target("iii", on: finalPage)
        XCTAssertTrue(initial.paintBounds.contains(finalTarget.paintBounds))
        XCTAssertTrue(finalTarget.paintBounds.contains(editedRegion))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: original), originalBytes)
        completed = (testRun?.totalFailureCount ?? 0) == 0
    }

    func testTransformedClippedUnderlayKeepsCurrentNeighborProtectionAfterColdSave() throws {
        let source = try transformedRoundTripUnderlayFixture(neighbor: true)
        let original = try XCTUnwrap(source.page(at: 0))
        let first = try target("iii", on: original)
        let untouchedInk = try nativeInk(of: "KEEP", on: original)
        let originalBytes = try PDFBodyTextPageSnapshot.data(for: original)
        let editedRegion = CGRect(x: 45, y: 170, width: 35, height: 40)
        XCTAssertTrue(first.paintBounds.contains(editedRegion))
        XCTAssertLessThanOrEqual(first.paintBounds.maxX, untouchedInk.minX)
        let outside = try pixelsOutside(editedRegion, on: original)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-Underlay-Neighbor-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var current = source
        for (cycle, pair) in [("iii", "ii"), ("ii", "iii")].enumerated() {
            let page = try XCTUnwrap(current.page(at: 0))
            let selected = try target(pair.0, on: page)
            XCTAssertLessThanOrEqual(selected.paintBounds.maxX, untouchedInk.minX)
            let before = try PDFBodyTextPageSnapshot.data(for: page)
            XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: selected,
                text: "WWWWWWWW", style: selected.style, bounds: selected.bounds))
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
                text: pair.1, style: selected.style, bounds: selected.bounds)
            let wrapper = PDFDocument(); wrapper.insert(edited, at: 0)
            let url = folder.appendingPathComponent("cold-\(cycle).pdf")
            try saveSnapshot(wrapper, to: url)
            current = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Data(contentsOf: url)))
            let cold = try XCTUnwrap(current.page(at: 0))
            XCTAssertTrue(cold.string?.contains(pair.1) == true)
            XCTAssertEqual(try nativeInk(of: "KEEP", on: cold), untouchedInk)
            XCTAssertEqual(try pixelsOutside(editedRegion, on: cold), outside)
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: original), originalBytes)
    }

    func testCurrentInsufficientClipCannotBorrowPriorSavedUnderlayExtent() throws {
        let source = try transformedRoundTripUnderlayFixture()
        let original = try XCTUnwrap(source.page(at: 0))
        let first = try target("iii", on: original)
        let edited = try PDFBodyTextEditor.replacementPage(for: original, target: first,
            text: "ii", style: first.style, bounds: first.bounds)
        let wrapper = PDFDocument(); wrapper.insert(edited, at: 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-Underlay-Current-Clip-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("first.pdf")
        try saveSnapshot(wrapper, to: url)
        let saved = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Data(contentsOf: url)))
        let savedPage = try XCTUnwrap(saved.page(at: 0))
        // Establish the intact text/marker state before introducing a CURRENT
        // clip which cannot contain even that source's glyphs.
        XCTAssertTrue(savedPage.string?.contains("ii") == true)
        let program = try PDFBodyTextPageSnapshot.contentData(for: savedPage)
        let stream = try PDFBodyTextContentStream.parse(program)
        let form = try XCTUnwrap(stream.forms.first)
        XCTAssertNotNil(try PDFBodyTextPageSnapshot.bodyTextLayoutBounds(named: form.name, on: savedPage))
        var content = Data("q 50 180 1 1 re W n\n".utf8)
        content.append(program); content.append(Data("\nQ".utf8))
        let changed = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data:
            PDFBodyTextPageSnapshot.data(for: savedPage, contentOverride: content)))
        let page = try XCTUnwrap(changed.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        if let selection = try? selection("ii", on: page) {
            do {
                if let selected = try PDFBodyTextEditor.target(on: page, selection: selection) {
                    XCTAssertFalse(selected.paintBounds.contains(first.paintBounds))
                    XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: selected,
                        text: "iiiiiiiiiiiiiii", style: selected.style, bounds: selected.bounds))
                }
            } catch { /* Explicit refusal is safe; admission is checked above. */ }
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    private static let transformedRoundTripUnderlayPrefix =
        "q 0.23999999 0 0 -0.23999999 0 300 cm q 100 300.00049 650 399.99951 re W* n 0.9 g 90 280 700 450 re f 0 g "

    private func transformedRoundTripUnderlayFixture(neighbor: Bool = false) throws -> PDFDocument {
        let glyphs = "BT /F1 18 Tf 4.166666840277785 0 0 -4.166666840277785 208.33334201388925 500.0000208333342 Tm (iii) Tj ET "
        let other = neighbor
            ? "BT /F1 18 Tf 4.166666840277785 0 0 -4.166666840277785 354.1666814236117 500.0000208333342 Tm (KEEP) Tj ET " : ""
        let content = Self.transformedRoundTripUnderlayPrefix + glyphs + other + "Q Q\n"
        return try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data:
            PDFMalformedSelectionTestFixture.pdfData(objects: [
                "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
                "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
            ])))
    }

    private func recordTransformedUnderlayMarker(on page: PDFPage, initial: CGRect) throws {
        let content = try PDFBodyTextPageSnapshot.contentData(for: page)
        let stream = try PDFBodyTextContentStream.parse(content)
        XCTAssertEqual(stream.forms.count, 1)
        let form = try XCTUnwrap(stream.forms.first)
        let marker = try XCTUnwrap(PDFBodyTextPageSnapshot.bodyTextLayoutBounds(named: form.name, on: page))
        let recovered = marker.applying(form.transform)
        func values(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.maxX, rect.maxY].map(Double.init) }
        let diagnostic: [String: Any] = ["initial": values(initial), "savedMarker": values(marker),
            "formTransform": [form.transform.a, form.transform.b, form.transform.c, form.transform.d,
                              form.transform.tx, form.transform.ty].map(Double.init),
            "recoveredSavedExtent": values(recovered), "initialContainsRecovered": initial.contains(recovered)]
        let data = try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
        print("BODY_UNDERLAY_ROUNDTRIP_GEOMETRY", String(decoding: data, as: UTF8.self))
    }

    func testFragmentedBlockUsesTheSameOpaqueUnderlayClearanceAsSingleShow() throws {
        let single = try wholeBlockUnderlayFixture(fragmented: false)
        let singleTarget = try target("iii", on: XCTUnwrap(single.page(at: 0)))
        let bare = try wholeBlockUnderlayFixture(fragmented: true, underlay: "")
        let bareTarget = try target("iii", on: XCTUnwrap(bare.page(at: 0)))
        let fragmented = try wholeBlockUnderlayFixture(fragmented: true)
        let page = try XCTUnwrap(fragmented.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let selected = try target("iii", on: page)
        let stream = try PDFBodyTextContentStream.parse(PDFBodyTextPageSnapshot.contentData(for: page))
        XCTAssertEqual(stream.records.count, 3)
        XCTAssertTrue(stream.records.allSatisfy { !$0.isSupported })
        XCTAssertEqual(stream.blocks.count, 1)
        XCTAssertTrue(try XCTUnwrap(stream.blocks.first).isSupported)
        XCTAssertEqual(selected.text, "iii")
        XCTAssertEqual(selected.sourceRuns.count, 3)
        XCTAssertEqual(selected.bounds, bareTarget.bounds)
        XCTAssertEqual(selected.baseline, bareTarget.baseline)
        XCTAssertEqual(singleTarget.paintBounds, CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(bareTarget.paintBounds, singleTarget.paintBounds)
        XCTAssertEqual(selected.paintBounds, singleTarget.paintBounds,
            "A freshly verified whole-block route must retain the same opaque-underlay authority as a single show.")
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    func testFragmentedBlockSingleCharacterEditsPreserveBackgroundAcrossTwoAtomicColdSaves() throws {
        let source = try wholeBlockUnderlayFixture(fragmented: true, untouchedContent: true)
        let original = try XCTUnwrap(source.page(at: 0))
        let sourceBytes = try PDFBodyTextPageSnapshot.data(for: original)
        let control = try wholeBlockUnderlayFixture(fragmented: false, untouchedContent: true)
        let extent = try target("iii", on: XCTUnwrap(control.page(at: 0))).paintBounds
        // Fixed by the owned fixture before any edit. No result-derived mask,
        // no pixel tolerance, and no source-dependent geometry enlargement.
        let editedRegion = CGRect(x: 45, y: 170, width: 100, height: 40)
        XCTAssertTrue(extent.contains(editedRegion))
        _ = try target("iii", on: original)
        let untouchedInk = try nativeInk(of: "KEEP", on: original)
        let outside = try pixelsOutside(editedRegion, on: original)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-WholeBlock-Underlay-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var current = source
        for (cycle, change) in [("iii", "iiW"), ("iiW", "iii")].enumerated() {
            let page = try XCTUnwrap(current.page(at: 0))
            let selected = try target(change.0, on: page)
            XCTAssertEqual(selected.paintBounds, extent)
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
                text: change.1, style: selected.style, bounds: selected.bounds)
            XCTAssertEqual(try pixelsOutside(editedRegion, on: edited), outside)
            XCTAssertEqual(try nativeInk(of: "KEEP", on: edited), untouchedInk)
            let raw = try PDFBodyTextPageSnapshot.contentData(for: edited)
            XCTAssertTrue(raw.starts(with: Data(Self.wholeBlockUnderlay.utf8)))
            XCTAssertNotNil(raw.range(of: Data(Self.wholeBlockUntouchedSuffix.utf8)),
                "The separate text block and triangle operators must remain byte-for-byte intact.")
            let editedDocument = PDFDocument()
            editedDocument.insert(edited, at: 0)
            let url = folder.appendingPathComponent("cycle-\(cycle).pdf")
            try saveSnapshot(editedDocument, to: url)
            current = try XCTUnwrap(PDFDocument(url: url))
            let cold = try XCTUnwrap(current.page(at: 0))
            XCTAssertTrue(cold.string?.contains(change.1) == true)
            XCTAssertEqual(try pixelsOutside(editedRegion, on: cold), outside)
            XCTAssertEqual(try nativeInk(of: "KEEP", on: cold), untouchedInk)
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: original), sourceBytes)
    }

    func testWholeBlockProofDoesNotTurnUnsafePaintIntoBlankClearance() throws {
        let variants = [
            ("triangle", "q 0.9 g 0 0 m 400 0 l 200 300 l h f Q "),
            ("transparent", "q /Half gs 0.9 g 0 0 400 300 re f Q "),
            ("insufficientClip", "q 50 180 2 2 re W n 0.9 g 0 0 400 300 re f Q ")
        ]
        for (reason, paint) in variants {
            let document = try wholeBlockUnderlayFixture(fragmented: true, underlay: paint)
            let page = try XCTUnwrap(document.page(at: 0))
            let before = try PDFBodyTextPageSnapshot.data(for: page)
            let selected = try target("iii", on: page)
            XCTAssertEqual(selected.paintBounds, selected.bounds, reason)
            XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: selected,
                text: "iiW", style: selected.style, bounds: selected.bounds), reason)
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before, reason)
            XCTAssertTrue(page.string?.contains("iii") == true, reason)
        }
    }

    private static let wholeBlockUnderlay = "q 0.9 g 0 0 400 300 re f Q "
    private static let wholeBlockUntouchedSuffix = "\nBT /F1 18 Tf 1 0 0 1 50 100 Tm (KEEP) Tj ET\nq 0.3 g 300 240 m 320 240 l 310 260 l h f Q"

    private func wholeBlockUnderlayFixture(fragmented: Bool,
                                           underlay: String = PDFBodyTextDeclaredExtentTests.wholeBlockUnderlay,
                                           untouchedContent: Bool = false) throws -> PDFDocument {
        let shows = fragmented ? "(i) Tj (i) Tj (i) Tj" : "(iii) Tj"
        let content = underlay + "BT /F1 18 Tf 1 0 0 1 50 180 Tm " + shows + " ET"
            + (untouchedContent ? Self.wholeBlockUntouchedSuffix : "")
        return try XCTUnwrap(PDFRawStreamProvenance.createdDocument(
            data: PDFMalformedSelectionTestFixture.pdfData(objects: [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> /ExtGState << /Half << /ca 0.5 >> >> >> /Contents 5 0 R >>",
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
                "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
            ])))
    }

    func testWordWiderThanOneEmUsesBlankSlackAndKeepsExtentAcrossTwoSaves() throws {
        let source = try fixture()
        let original = try XCTUnwrap(source.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: original)
        let first = try target("iii", on: original)
        let extent = first.paintBounds
        let firstInk = try nativeInk(of: "iii", on: original)
        XCTAssertTrue(extent.contains(firstInk))
        XCTAssertGreaterThan(extent.maxX, firstInk.maxX)
        let outside = try pixelsOutside(extent, on: original)
        var document = source
        for (old, new) in [("iii", "iiiiiiiiii"), ("iiiiiiiiii", "iiiiiiiiiiiiiii")] {
            let page = try XCTUnwrap(document.page(at: 0))
            let current = try target(old, on: page)
            assertRect(current.paintBounds, equals: extent)
            XCTAssertEqual(current.baseline.x, first.baseline.x, accuracy: 0.05)
            XCTAssertEqual(current.baseline.y, first.baseline.y, accuracy: 0.05)
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: current,
                text: new, style: current.style, bounds: current.bounds)
            document = try reopen(edited)
            let saved = try XCTUnwrap(document.page(at: 0))
            XCTAssertTrue(saved.string?.contains(new) == true)
            XCTAssertEqual(try pixelsOutside(extent, on: saved), outside)
        }
        let last = try target("iiiiiiiiiiiiiii", on: XCTUnwrap(document.page(at: 0)))
        let lastInk = try nativeInk(of: "iiiiiiiiiiiiiii", on: XCTUnwrap(document.page(at: 0)))
        XCTAssertGreaterThan(lastInk.width - firstInk.width, first.style.fontSize)
        assertRect(last.paintBounds, equals: extent)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: original), before)
    }

    func testNeighborLimitsSlackAndOversizedReplacementRefusesAtomically() throws {
        let source = try fixture(neighborX: 80)
        let page = try XCTUnwrap(source.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let selected = try target("iii", on: page)
        let neighborInk = try nativeInk(of: "KEEP", on: page)
        XCTAssertLessThanOrEqual(selected.paintBounds.maxX, neighborInk.minX)
        XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: selected,
            text: "WWWWWWWW", style: selected.style, bounds: selected.bounds))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
        XCTAssertTrue(page.string?.contains("iii") == true)
        XCTAssertTrue(page.string?.contains("KEEP") == true)
    }

    func testOverlappingArtworkCannotAuthorizeBlankSlack() throws {
        let source = try fixture(prefix: "0.9 g 0 0 m 400 0 l 200 300 l h f 0 g ")
        let page = try XCTUnwrap(source.page(at: 0))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let selected = try target("iii", on: page)
        // A nonrectangular shape's bounding box does not prove uniform paint
        // under the source. It cannot authorize blank clearance.
        XCTAssertLessThan(selected.paintBounds.width, selected.style.fontSize)
        XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: selected,
            text: "iiiiii", style: selected.style, bounds: selected.bounds))
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
            text: "ii", style: selected.style, bounds: selected.bounds)
        XCTAssertEqual(try pixelsOutside(selected.paintBounds, on: edited), try pixelsOutside(selected.paintBounds, on: page))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    func testOpaqueEarlierRectangleUsesOnlyItsClippedCoverageAcrossTwoSaves() throws {
        let paint = "q 25 145 150 80 re W n 0.9 g 20 140 160 90 re f Q "
        let original = try fixture(prefix: paint), page = try XCTUnwrap(original.page(at: 0))
        let selected = try target("iii", on: page), extent = selected.paintBounds
        assertRect(extent, equals: CGRect(x: 25, y: 145, width: 150, height: 80))
        let outside = try pixelsOutside(extent, on: page)
        let firstInk = try nativeInk(of: "iii", on: page)
        var currentDocument = original
        for (old, new) in [("iii", "iiiiiiiiii"), ("iiiiiiiiii", "iiiiiiiiiiiiiii")] {
            let currentPage = try XCTUnwrap(currentDocument.page(at: 0)), current = try target(old, on: currentPage)
            assertRect(current.paintBounds, equals: extent)
            XCTAssertEqual(current.baseline.x, selected.baseline.x, accuracy: 0.05)
            XCTAssertEqual(current.baseline.y, selected.baseline.y, accuracy: 0.05)
            let edited = try PDFBodyTextEditor.replacementPage(for: currentPage, target: current,
                text: new, style: current.style, bounds: current.bounds)
            currentDocument = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(
                data: PDFBodyTextPageSnapshot.data(for: edited)))
            let saved = try XCTUnwrap(currentDocument.page(at: 0))
            XCTAssertEqual(try pixelsOutside(extent, on: saved), outside)
        }
        let last = try XCTUnwrap(currentDocument.page(at: 0))
        XCTAssertGreaterThan(try nativeInk(of: "iiiiiiiiiiiiiii", on: last).width - firstInk.width, selected.style.fontSize)
        let guarded = try fixture(neighborX: 120, prefix: paint), guardedPage = try XCTUnwrap(guarded.page(at: 0))
        let bounded = try target("iii", on: guardedPage)
        XCTAssertLessThanOrEqual(bounded.paintBounds.maxX, try nativeInk(of: "KEEP", on: guardedPage).minX)
        let before = try PDFBodyTextPageSnapshot.data(for: guardedPage)
        XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: guardedPage, target: bounded,
            text: "WWWWWWWW", style: bounded.style, bounds: bounded.bounds))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: guardedPage), before)
    }

    func testPendingClipCannotAuthorizeItsPathPrefixAsPageCoverage() throws {
        for (reason, pending) in [
            ("compound-after-W", "100 100 20 20 re"),
            ("cm-after-W", "1 0 0 1 0 0 cm"),
            ("q-Q-after-W", "q Q"),
            ("second-W", "W*")
        ] {
            // The even-odd compound variant makes a real hole after W*.
            // At W* the page-covering rectangle is only an unfinished prefix.
            let paint = "q 0 0 400 300 re W* \(pending) n 0.9 g 0 0 400 300 re f Q "
            let source = try fixture(prefix: paint), page = try XCTUnwrap(source.page(at: 0))
            let before = try PDFBodyTextPageSnapshot.data(for: page)
            let selected = try target("iii", on: page)
            XCTAssertLessThan(selected.paintBounds.width, selected.style.fontSize, reason)
            XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: selected,
                text: "iiiiii", style: selected.style, bounds: selected.bounds), reason)
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before, reason)
        }
    }

    func testSavedUnderlayCannotAuthorizePatternsMasksBlendTextClipOrInsufficientClip() throws {
        let content = "0.9 g 0 0 400 300 re f 0 g BT /F1 18 Tf 1 0 0 1 50 180 Tm (iii) Tj ET"
        let tile = "0.5 g 0 0 10 10 re f", mask = "1 g 0 0 400 300 re f"
        let source = try XCTUnwrap(PDFDocument(data: PDFMalformedSelectionTestFixture.pdfData(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> /Pattern << /P1 6 0 R >> /ExtGState << /Mask << /SMask << /S /Alpha /G 7 0 R >> >> /Blend << /BM /Multiply >> /Overprint << /OP true /op true /OPM 1 >> >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources << >> /Length \(tile.utf8.count) >>\nstream\n\(tile)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 400 300] /Group << /S /Transparency /CS /DeviceGray >> /Resources << >> /Length \(mask.utf8.count) >>\nstream\n\(mask)\nendstream"
        ])))
        let page = try XCTUnwrap(source.page(at: 0)), selected = try target("iii", on: page)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
            text: "ii", style: selected.style, bounds: selected.bounds)
        let cachedDocument = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(
            data: PDFBodyTextPageSnapshot.data(for: edited)))
        defer { withExtendedLifetime(cachedDocument) {} }
        let saved = try XCTUnwrap(cachedDocument.page(at: 0))
        assertRect(try target("ii", on: saved).paintBounds, equals: selected.paintBounds)
        let program = try PDFBodyTextPageSnapshot.contentData(for: saved)
        for (reason, prefix) in [
            ("pattern", "q /Pattern cs /P1 scn 0 0 400 300 re f Q"),
            ("bare-pattern", "/Pattern cs"),
            ("soft-mask", "/Mask gs"), ("blend", "/Blend gs"), ("overprint", "/Overprint gs"),
            ("text-clip", "BT /F1 18 Tf 7 Tr 1 0 0 1 50 180 Tm (X) Tj ET"),
            ("small-clip", "0 0 55 185 re W n"),
            ("invalid-Tr-missing", "Tr"), ("invalid-Tr-negative", "-1 Tr"),
            ("invalid-Tr-high", "8 Tr"), ("invalid-Tr-real", "0.5 Tr")
        ] {
            var current = Data(("q " + prefix + "\n").utf8)
            current.append(program); current.append(Data("\nQ".utf8))
            let bytes = try PDFBodyTextPageSnapshot.data(for: saved, contentOverride: current)
            let changed = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
            let changedPage = try XCTUnwrap(changed.page(at: 0))
            let before = try PDFBodyTextPageSnapshot.data(for: changedPage)
            let changedSelection = try selection("ii", on: changedPage)
            do {
                let candidate = try PDFBodyTextEditor.target(on: changedPage, selection: changedSelection)
                if let candidate {
                    XCTAssertFalse(candidate.paintBounds.contains(selected.paintBounds), reason)
                    XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: changedPage,
                        target: candidate, text: "iii", style: candidate.style, bounds: candidate.bounds), reason)
                }
            } catch { /* Both explicit refusal and unavailable native target are safe. */ }
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: changedPage), before, reason)
        }
    }

    func testNegativeSidebearingIsInsideDeclaredExtentWithoutMovingBaseline() throws {
        let source = try fixture(text: "jazz", font: "Times-Italic", size: 24)
        let page = try XCTUnwrap(source.page(at: 0))
        let selected = try target("jazz", on: page)
        let originalInk = try nativeInk(of: "jazz", on: page)
        XCTAssertLessThan(originalInk.minX, selected.baseline.x,
                          "The fixture must exercise real left overhang.")
        XCTAssertTrue(selected.bounds.contains(originalInk))
        let outside = try pixelsOutside(selected.paintBounds, on: page)
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
            text: "jolt", style: selected.style, bounds: selected.bounds)
        let document = try reopen(edited)
        let saved = try XCTUnwrap(document.page(at: 0))
        let next = try target("jolt", on: saved)
        XCTAssertEqual(next.baseline.x, selected.baseline.x, accuracy: 0.05)
        XCTAssertEqual(next.baseline.y, selected.baseline.y, accuracy: 0.05)
        XCTAssertEqual(try pixelsOutside(selected.paintBounds, on: saved), outside)
    }

    func testNonzeroOriginAndRotationKeepPhysicalInkInsideSourceExtent() throws {
        for rotation in [0, 90, 270] {
            let source = try fixture(nonzeroOrigin: true)
            let page = try XCTUnwrap(source.page(at: 0))
            page.rotation = rotation
            let selected = try target("iii", on: page)
            let outside = try pixelsOutside(selected.paintBounds, on: page)
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
                text: "iiii", style: selected.style, bounds: selected.bounds)
            XCTAssertEqual(edited.bounds(for: .mediaBox), page.bounds(for: .mediaBox))
            XCTAssertEqual(edited.rotation, rotation)
            XCTAssertEqual(try pixelsOutside(selected.paintBounds, on: edited), outside)
            let next = try target("iiii", on: edited)
            XCTAssertEqual(next.baseline.x, selected.baseline.x, accuracy: 0.05)
            XCTAssertEqual(next.baseline.y, selected.baseline.y, accuracy: 0.05)
            // Nonzero-origin pages still take the existing PDFium fallback;
            // this checks physical placement, not unproved marker retention.
        }
    }

    func testTightLeadingRejectsNewInkBeforeItCanTouchNeighboringRows() throws {
        let source = try fixture(text: "Middle", size: 16,
            prefix: "BT /F1 16 Tf 1 0 0 1 50 193 Tm (Above) Tj ET ",
            suffix: " BT /F1 16 Tf 1 0 0 1 50 167 Tm (Below) Tj ET")
        let page = try XCTUnwrap(source.page(at: 0))
        let selected = try target("Middle", on: page)
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        var oversized = selected.style
        oversized.fontSize *= 2
        XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: selected,
            text: "g", style: oversized, bounds: selected.bounds))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    func testExistingBodyDraftRetainsSourceGeometryWhileStyleChangesRemainSupported() throws {
        let source = try fixture(text: "Original text")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BodyExtent-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("fixture.pdf")
        XCTAssertTrue(source.write(to: url))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        defer { workspace.closeDiscardingChanges() }
        workspace.setMode(.editing)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: (try XCTUnwrap(page.string) as NSString).range(of: "Original text")))
        XCTAssertTrue(workspace.requestBodyTextEdit(selection: selection))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        var smaller = draft.style
        smaller.fontSize *= 0.9
        workspace.updatePendingInlineTextDraft(id: draft.id, text: "Updated text", style: smaller,
            bounds: draft.bounds.offsetBy(dx: 40, dy: 40))
        XCTAssertEqual(workspace.pendingInlineTextEdit?.bounds, draft.bounds)
        workspace.commitPendingInlineText(id: draft.id, text: "Updated text", style: smaller, bounds: draft.bounds)
        XCTAssertNil(workspace.presentedError)
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertTrue(workspace.document?.page(at: 0)?.string?.contains("Updated text") == true)
    }

    func testEarlierOpaqueRectangleDoesNotAuthorizeCoveredSlack() throws {
        try assertCoverRefused(paint: "0 0 1 rg 105 176 60 25 re f", earlier: true)
    }

    func testLaterTransparentRectangleDoesNotAuthorizeCoveredSlack() throws {
        try assertCoverRefused(paint: "/Half gs 0 0 1 rg 105 176 60 25 re f", earlier: false,
            resources: "/ExtGState << /Half << /ca 0.5 >> >>")
    }

    func testLaterOpaqueTriangleDoesNotAuthorizeItsBoundingBoxAsCoveredSlack() throws {
        try assertCoverRefused(paint: "0 0 1 rg 105 176 m 165 176 l 135 201 l h f", earlier: false)
        // The rectangle's apparent bounds still overlap the source, but its
        // small clip cannot prove an opaque cover over the rest of that area.
        try assertCoverRefused(paint: "108 178 5 5 re W n 0 0 1 rg 105 176 60 25 re f", earlier: false)
    }

    private func assertCoverRefused(paint: String, earlier: Bool, resources: String = "") throws {
        let text = "BT /F1 18 Tf 1 0 0 1 100 180 Tm (iii) Tj ET"
        let cover = "q \(paint) Q"
        let content = earlier ? cover + " " + text : text + " " + cover
        let source = try XCTUnwrap(PDFDocument(data: PDFMalformedSelectionTestFixture.pdfData(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> \(resources) >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ])))
        let page = try XCTUnwrap(source.page(at: 0))
        let selected = try target("iii", on: page)
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        XCTAssertLessThanOrEqual(selected.paintBounds.maxX, selected.bounds.maxX)
        XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: selected,
            text: "WWWW", style: selected.style, bounds: selected.bounds))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
    }

    func testOptInEducated076RetainsLineExtentAfterTheAndOneReedit() throws {
        try originalRegression(environment: "EMBER_BODY_EXTENT_076_PDF",
            sha: "cdb1707eceff1744f0d14996a7a10650474bfecf11afc02eeee9aadb5bd6f8c9",
            phrase: "making machine. It was bulky and bolted to an iron workstation in",
            changes: [("and", "the"), ("the", "one")])
    }

    func testOptInConfucius355IncludesOriginalHeadingInk() throws {
        try originalRegression(environment: "EMBER_BODY_EXTENT_355_PDF",
            sha: "114d299a8a9d5676374bd1e30a15bb8c9dc40862efabe811e6b9fcc792a1080b",
            phrase: "论语全篇 学而篇第一", changes: [("而", "与"), ("与", "及")])
    }

    func testOptInLaser146IncludesOriginalLeftBearingInk() throws {
        try originalRegression(environment: "EMBER_BODY_EXTENT_146_PDF",
            sha: "9a3d5bf2cfefeb0c10ac5aa0aacc722a62cc1ed925a881ee728fe0233336313c",
            phrase: "power fiber lasers: A review. IEEE", changes: [("fiber", "laser"), ("laser", "pulse")])
    }

    private func originalRegression(environment: String, sha: String, phrase: String,
                                    changes: [(String, String)]) throws {
        guard let path = ProcessInfo.processInfo.environment[environment], path.hasPrefix("/") else {
            throw XCTSkip("Set \(environment) to the retained original page-20 fixture.")
        }
        let failureCountBefore = testRun?.totalFailureCount ?? 0
        let url = URL(fileURLWithPath: path)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(try digest(url), sha)
        guard try digest(url) == sha else { throw NSError(domain: "BodyExtentFixture", code: 1) }
        let source = try XCTUnwrap(PDFSourceFileAccess.loadDocument(at: url).document)
        let original = try XCTUnwrap(source.page(at: 19))
        let selected = try target(phrase, on: original)
        let extent = selected.paintBounds
        XCTAssertTrue(extent.contains(try nativeInk(of: phrase, on: original)))
        let outside = try pixelsOutside(extent, on: original)
        let originalSnapshot = try PDFBodyTextPageSnapshot.data(for: original)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BodyExtentReal-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var completed = false
        defer {
            if completed { try? FileManager.default.removeItem(at: folder) }
            else { print("BODY_EXTENT_FAILED_OUTPUTS_RETAINED", folder.path) }
        }
        var workspace = PDFWorkspaceState()
        guard workspace.open(url: url) else { throw NSError(domain: "BodyExtentProductionOpen", code: 1) }
        defer { workspace.closeDiscardingChanges() }
        workspace.setMode(.editing)
        var currentText = selected.text
        var gesture = phrase
        let firstChangeRange = try uniqueWhitespaceRange(changes[0].0, in: gesture)
        let changeOffset = compact((gesture as NSString).substring(to: firstChangeRange.location)).utf16.count
        for (index, pair) in changes.enumerated() {
            let (old, new) = pair
            let document = try XCTUnwrap(workspace.document)
            let currentPage = try XCTUnwrap(document.page(at: 19))
            let selection = try selection(gesture, on: currentPage)
            let current = try XCTUnwrap(PDFBodyTextEditor.target(on: currentPage, selection: selection))
            assertRect(current.paintBounds, equals: extent)
            XCTAssertEqual(compact(current.text), compact(currentText))
            let gestureRange = try uniqueWhitespaceRange(gesture, in: current.text)
            let range = try anchoredChange(old, offset: changeOffset, in: current.text, context: gestureRange)
            let gestureChange = try anchoredChange(old, offset: changeOffset, in: gesture,
                context: NSRange(location: 0, length: (gesture as NSString).length))
            let nextGesture = (gesture as NSString).replacingCharacters(in: gestureChange, with: new)
            let replacement = (current.text as NSString).replacingCharacters(in: range, with: new)
            let beforeText = try XCTUnwrap(currentPage.string)
            let normalizedBefore = compact(beforeText) as NSString
            let targetRange = try uniqueWhitespaceRange(current.text, in: compact(beforeText))
            let expected = normalizedBefore.replacingCharacters(in: targetRange, with: compact(replacement))
            guard workspace.requestBodyTextEdit(selection: selection, preservesSelectionTool: false),
                  let draft = workspace.pendingInlineTextEdit, compact(draft.text) == compact(current.text) else {
                throw NSError(domain: "BodyExtentProductionDraft", code: 1)
            }
            workspace.commitPendingInlineText(id: draft.id, text: replacement, style: draft.style, bounds: draft.bounds)
            guard workspace.pendingInlineTextEdit == nil, workspace.presentedError == nil,
                  document.page(at: 19) !== currentPage else { throw NSError(domain: "BodyExtentProductionCommit", code: 1) }
            let saved = folder.appendingPathComponent("save-\(index + 1).pdf")
            try saveSnapshot(document, to: saved)
            workspace.closeDiscardingChanges()
            workspace = PDFWorkspaceState()
            guard workspace.open(url: saved) else { throw NSError(domain: "BodyExtentProductionReopen", code: 1) }
            workspace.setMode(.editing)
            let reopened = try XCTUnwrap(workspace.document?.page(at: 19))
            currentText = replacement
            gesture = nextGesture
            XCTAssertEqual(compact(try XCTUnwrap(reopened.string)), expected,
                "Every meaningful Unicode character and its whole-page order must survive; only whitespace is normalized.")
            XCTAssertEqual(try pixelsOutside(extent, on: reopened), outside,
                "The source-declared mask is fixed before both saves; outputs cannot enlarge it.")
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: original), originalSnapshot)
        XCTAssertEqual(try digest(url), sha)
        let after = try FileManager.default.attributesOfItem(atPath: path)
        for key in [FileAttributeKey.size, .modificationDate, .systemFileNumber] {
            XCTAssertEqual(after[key] as? NSObject, originalAttributes[key] as? NSObject)
        }
        completed = (testRun?.totalFailureCount ?? failureCountBefore) == failureCountBefore
    }

    /// Delete whitespace only. Nonwhitespace UTF-16 units, including surrogate
    /// pairs/combining characters, retain their exact values and order.
    private func compact(_ text: String) -> String {
        String(decoding: text.utf16.filter { unit in
            UnicodeScalar(unit).map { !CharacterSet.whitespacesAndNewlines.contains($0) } ?? true
        }, as: UTF16.self)
    }

    private func uniqueWhitespaceRange(_ phrase: String, in text: String) throws -> NSRange {
        var units: [UInt16] = [], positions: [Int] = []
        for (index, unit) in text.utf16.enumerated() {
            if let scalar = UnicodeScalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            units.append(unit); positions.append(index)
        }
        let normalized = String(decoding: units, as: UTF16.self) as NSString
        let needle = compact(phrase)
        guard !needle.isEmpty else { throw NSError(domain: "BodyExtentEmptyPhrase", code: 1) }
        let range = normalized.range(of: needle)
        guard range.location != NSNotFound else { throw NSError(domain: "BodyExtentMissingPhrase", code: 1) }
        let suffix = NSRange(location: range.location + 1, length: normalized.length - range.location - 1)
        guard normalized.range(of: needle, options: [], range: suffix).location == NSNotFound else {
            throw NSError(domain: "BodyExtentAmbiguousPhrase", code: 1)
        }
        return NSRange(location: positions[range.location], length: positions[NSMaxRange(range) - 1] - positions[range.location] + 1)
    }

    /// Keep the changed run at its original meaningful-character offset within
    /// the uniquely matched evolving gesture, even if another word shares a prefix.
    private func anchoredChange(_ old: String, offset: Int, in text: String, context: NSRange) throws -> NSRange {
        let source = text as NSString
        guard context.location != NSNotFound, NSMaxRange(context) <= source.length else {
            throw NSError(domain: "BodyExtentInvalidContext", code: 1)
        }
        let slice = source.substring(with: context)
        let positions = slice.utf16.enumerated().compactMap { index, unit -> Int? in
            if let scalar = UnicodeScalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
            return index
        }
        let needle = compact(old), length = needle.utf16.count
        guard offset >= 0, length > 0, offset + length <= positions.count else {
            throw NSError(domain: "BodyExtentInvalidChangeOffset", code: 1)
        }
        let range = NSRange(location: context.location + positions[offset],
            length: positions[offset + length - 1] - positions[offset] + 1)
        guard compact(source.substring(with: range)) == needle else {
            throw NSError(domain: "BodyExtentChangedGesture", code: 1)
        }
        return range
    }

    private func selection(_ phrase: String, on page: PDFPage) throws -> PDFSelection {
        try XCTUnwrap(page.selection(for: uniqueWhitespaceRange(phrase, in: XCTUnwrap(page.string))))
    }

    private final class SaveCompletion: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<Void, Error>?
        func publish(_ value: Result<Void, Error>) { lock.lock(); result = value; lock.unlock(); ready.signal() }
        func take() -> Result<Void, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    }

    private func saveSnapshot(_ document: PDFDocument, to url: URL) throws {
        XCTAssertTrue(Thread.isMainThread)
        let snapshot = try PDFRecoverySnapshot(capturing: document), completion = SaveCompletion()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard !Thread.isMainThread else { throw NSError(domain: "BodyExtentAtomicWorker", code: 1) }
                try AtomicPDFWriter.write(snapshot.takeDocument(), to: url)
                completion.publish(.success(()))
            } catch { completion.publish(.failure(error)) }
        }
        while completion.ready.wait(timeout: .now()) != .success { CFRunLoopRunInMode(.defaultMode, 0.01, true) }
        try XCTUnwrap(completion.take()).get()
    }

    private func target(_ phrase: String, on page: PDFPage) throws -> PDFBodyTextTarget {
        try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection(phrase, on: page)))
    }

    private func fixture(text: String = "iii", font: String = "Helvetica", size: Int = 18,
                         neighborX: Int? = nil, background: Bool = false, nonzeroOrigin: Bool = false,
                         prefix: String = "", suffix: String = "") throws -> PDFDocument {
        let media = nonzeroOrigin ? "10 15 400 300" : "0 0 400 300"
        let underlay = background ? "0.9 0.9 0.9 rg 0 0 400 300 re f 0 0 0 rg " : ""
        let neighbor = neighborX.map { " BT /F1 \(size) Tf 1 0 0 1 \($0) 180 Tm (KEEP) Tj ET" } ?? ""
        let content = underlay + prefix + "BT /F1 \(size) Tf 1 0 0 1 50 180 Tm (\(text)) Tj ET" + neighbor + suffix
        return try XCTUnwrap(PDFDocument(data: PDFMalformedSelectionTestFixture.pdfData(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [\(media)] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /\(font) >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ])))
    }

    private func reopen(_ page: PDFPage) throws -> PDFDocument {
        let document = PDFDocument()
        document.insert(page, at: 0)
        return try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation())))
    }

    private func assertRect(_ actual: CGRect, equals expected: CGRect,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.05, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.05, file: file, line: line)
        XCTAssertEqual(actual.maxX, expected.maxX, accuracy: 0.05, file: file, line: line)
        XCTAssertEqual(actual.maxY, expected.maxY, accuracy: 0.05, file: file, line: line)
    }

    private func pixelsOutside(_ mask: CGRect, on page: PDFPage) throws -> Data {
        let media = page.bounds(for: .mediaBox), scale: CGFloat = 2
        let width = Int(ceil(media.width * scale)), height = Int(ceil(media.height * scale))
        var pixels = Data(repeating: 255, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -media.minX, y: -media.minY)
            context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        let left = max(0, Int(floor((mask.minX - media.minX) * scale)))
        let right = min(width, Int(ceil((mask.maxX - media.minX) * scale)))
        let bottom = max(0, Int(floor((mask.minY - media.minY) * scale)))
        let top = min(height, Int(ceil((mask.maxY - media.minY) * scale)))
        if right > left, top > bottom {
            for y in bottom..<top {
                let offset = ((height - y - 1) * width + left) * 4
                pixels.replaceSubrange(offset..<offset + (right - left) * 4,
                    with: repeatElement(UInt8(255), count: (right - left) * 4))
            }
        }
        return pixels
    }

    /// Independent native source measurement, following the existing
    /// paragraph regression pattern. No product-private geometry is exposed.
    private func nativeInk(of phrase: String, on source: PDFPage) throws -> CGRect {
        let data = try PDFBodyTextPageSnapshot.data(for: source)
        return try data.withUnsafeBytes { bytes in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(document) }
            let page = try XCTUnwrap(FPDF_LoadPage(document, 0)); defer { FPDF_ClosePage(page) }
            let textPage = try XCTUnwrap(FPDFText_LoadPage(page)); defer { FPDFText_ClosePage(textPage) }
            let count = FPDFText_CountChars(textPage)
            guard count >= 0, count <= 250_000 else { throw NSError(domain: "BodyExtentInkBudget", code: 1) }
            var text = "", indices: [Int32] = []
            for index in 0..<count {
                if index % 256 == 0 { try Task.checkCancellation() }
                guard let scalar = UnicodeScalar(FPDFText_GetUnicode(textPage, index)) else { continue }
                let character = String(scalar)
                text += character
                indices.append(contentsOf: repeatElement(index, count: character.utf16.count))
            }
            let range = try uniqueWhitespaceRange(phrase, in: text)
            var ink = CGRect.null
            for index in indices[range.location..<NSMaxRange(range)] {
                var left = 0.0, right = 0.0, bottom = 0.0, top = 0.0
                guard FPDFText_GetCharBox(textPage, index, &left, &right, &bottom, &top) != 0,
                      [left, right, bottom, top].allSatisfy(\.isFinite), right >= left, top >= bottom else {
                    throw NSError(domain: "BodyExtentInkBox", code: 1)
                }
                let box = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
                if !box.isEmpty { ink = ink.union(box) }
            }
            guard !ink.isNull, !ink.isEmpty else { throw NSError(domain: "BodyExtentInkEmpty", code: 1) }
            return ink
        }
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
}
