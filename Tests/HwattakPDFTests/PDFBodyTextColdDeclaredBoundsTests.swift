// SPDX-License-Identifier: MPL-2.0
// Owned fixtures only; no corpus input or file/page-specific product conditions.
import AppKit
import CoreText
import CPDFium
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextColdDeclaredBoundsTests: XCTestCase {
    func testSavedExtentClipsOnlySubpixelFloatingPointOvershootWithoutGrowing() throws {
        let visible = CGRect(x: 0, y: 0, width: 640, height: 880)
        let error = CGFloat(880).ulp * 64
        let extent = CGRect(x: -error, y: 700, width: 640 + error, height: 180)
        let glyphs = CGRect(x: 72, y: 730, width: 450, height: 27)
        XCTAssertFalse(visible.contains(extent), "The old exact boundary check rejects arithmetic noise.")
        let result = try XCTUnwrap(PDFBodyTextEditor.savedPaintExtent(extent, within: visible, containing: glyphs))
        XCTAssertEqual(result, extent.intersection(visible))
        XCTAssertTrue(visible.contains(result))
        XCTAssertTrue(extent.contains(result))
        XCTAssertTrue(result.contains(glyphs))
    }

    func testSavedExtentHandlesAllFourBoundaryEdgesAndNegativePageOrigins() throws {
        let visible = CGRect(x: -128, y: -256, width: 640, height: 880)
        let error = CGFloat(880).ulp * 64
        let glyphs = visible.insetBy(dx: 40, dy: 40)
        for extent in [visible.insetBy(dx: -error, dy: 0), visible.insetBy(dx: 0, dy: -error)] {
            let result = try XCTUnwrap(PDFBodyTextEditor.savedPaintExtent(extent, within: visible, containing: glyphs))
            XCTAssertEqual(result, visible)
            XCTAssertTrue(extent.contains(result))
        }
    }

    func testSavedExtentRejectsRealOvershootAndCannotUseLargeMarkerAsPermission() {
        let visible = CGRect(x: 0, y: 0, width: 640, height: 880)
        let glyphs = CGRect(x: 72, y: 730, width: 450, height: 27)
        for overshoot in [CGFloat(880).ulp * 256, 0.000001, 0.1, 100] {
            let extent = CGRect(x: -overshoot, y: 0, width: 640 + overshoot, height: 880)
            XCTAssertNil(PDFBodyTextEditor.savedPaintExtent(extent, within: visible, containing: glyphs))
        }
    }

    func testSavedExtentKeepsExactInteriorAndNeverClipsOutGlyphs() throws {
        let visible = CGRect(x: 0, y: 0, width: 640, height: 880)
        let extent = CGRect(x: 20, y: 100, width: 560, height: 700)
        let glyphs = CGRect(x: 72, y: 730, width: 450, height: 27)
        XCTAssertEqual(PDFBodyTextEditor.savedPaintExtent(extent, within: visible, containing: glyphs), extent)
        XCTAssertNil(PDFBodyTextEditor.savedPaintExtent(extent, within: visible,
            containing: CGRect(x: 19, y: 730, width: 450, height: 27)))
        XCTAssertNil(PDFBodyTextEditor.savedPaintExtent(visible.insetBy(dx: -CGFloat(880).ulp, dy: 0), within: visible,
            containing: CGRect(x: -CGFloat(880).ulp, y: 730, width: 450, height: 27)))
    }

    func testSavedExtentRejectsNonfiniteEmptyAndInvalidGeometry() {
        let visible = CGRect(x: 0, y: 0, width: 640, height: 880)
        let glyphs = CGRect(x: 72, y: 730, width: 450, height: 27)
        for extent in [CGRect.null, .infinite, .zero, CGRect(x: 0, y: 0, width: -1, height: 10)] {
            XCTAssertNil(PDFBodyTextEditor.savedPaintExtent(extent, within: visible, containing: glyphs))
        }
        XCTAssertNil(PDFBodyTextEditor.savedPaintExtent(visible, within: visible, containing: .zero))
    }

    func testOwnedSavedFormTinyOverflowIsLegacyGuardRedAndSurvivesTwoColdEdits() throws {
        let delta = CGFloat(880).ulp * 64
        let data = try roundoffSavedFormFixture(overshoot: delta)
        let original = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: data))
        let originalPage = try XCTUnwrap(original.page(at: 0))
        let visible = originalPage.bounds(for: .mediaBox).intersection(originalPage.bounds(for: .cropBox))
        let stream = try PDFBodyTextContentStream.parse(PDFBodyTextPageSnapshot.contentData(for: originalPage))
        let form = try XCTUnwrap(stream.forms.first)
        let saved = try XCTUnwrap(PDFBodyTextPageSnapshot.bodyTextLayoutBounds(named: form.name, on: originalPage))
        let recovered = saved.applying(form.transform)
        XCTAssertFalse(visible.contains(recovered), "This actual Form must be RED under the former exact visible.contains guard.")
        XCTAssertTrue(visible.contains(try nativeInk(originalPage)))
        let fixedMask = CGRect(x: 64, y: 720, width: 128, height: 48)
        let fixedOutside = try roundoffPixelsOutside(originalPage, mask: fixedMask)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-Roundoff-Cold-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var completed = false
        defer { if completed { try? FileManager.default.removeItem(at: folder) } }
        var current = folder.appendingPathComponent("source.pdf")
        try data.write(to: current, options: .withoutOverwriting)
        var coldCycles = 0
        for (cycle, pair) in [("iii", "ii"), ("ii", "iii")].enumerated() {
            let workspace = PDFWorkspaceState()
            XCTAssertTrue(workspace.open(url: current)); workspace.setMode(.editing)
            let document = try XCTUnwrap(workspace.document), page = try XCTUnwrap(document.page(at: 0))
            let text = try XCTUnwrap(page.string) as NSString
            let range = text.range(of: pair.0)
            XCTAssertNotEqual(range.location, NSNotFound)
            let selection = try XCTUnwrap(page.selection(for: range))
            XCTAssertTrue(workspace.requestBodyTextEdit(selection: selection))
            let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
            let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
            XCTAssertEqual(target.text, pair.0)
            XCTAssertTrue(visible.contains(target.paintBounds))
            XCTAssertTrue(target.paintBounds.contains(try nativeInk(page)))
            XCTAssertTrue(target.paintBounds.contains(fixedMask))
            workspace.commitPendingInlineText(id: draft.id, text: pair.1, style: draft.style, bounds: draft.bounds)
            XCTAssertNil(workspace.pendingInlineTextEdit); XCTAssertNil(workspace.presentedError)
            guard workspace.pendingInlineTextEdit == nil, workspace.presentedError == nil else {
                throw NSError(domain: "OwnedRoundoffCommit", code: cycle)
            }
            let edited = try XCTUnwrap(document.page(at: 0))
            XCTAssertEqual(try roundoffPixelsOutside(edited, mask: fixedMask), fixedOutside)
            let output = folder.appendingPathComponent("cold-\(cycle).pdf")
            try save(document, to: output)
            let bytes = try Data(contentsOf: output)
            XCTAssertLessThanOrEqual(bytes.count, 1_024 * 1_024)
            let cold = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
            let coldPage = try XCTUnwrap(cold.page(at: 0)), coldTarget = try roundoffTarget(pair.1, on: coldPage)
            XCTAssertEqual(coldTarget.text, pair.1)
            XCTAssertTrue(visible.contains(coldTarget.paintBounds))
            XCTAssertTrue(coldTarget.paintBounds.contains(try nativeInk(coldPage)))
            XCTAssertEqual(try roundoffPixelsOutside(coldPage, mask: fixedMask), fixedOutside)
            current = output; coldCycles += 1
            workspace.closeDiscardingChanges()
        }
        XCTAssertEqual(coldCycles, 2)
        emit(["stage": "roundoff-owned-two-cold", "completedColdCycles": coldCycles,
            "legacyVisibleContainsRecovered": visible.contains(recovered), "recovered": rect(recovered),
            "visible": rect(visible), "precisionCapIsPolicyNotProvenArithmeticOrigin": true])
        completed = (testRun?.totalFailureCount ?? 0) == 0
    }

    func testOwnedSavedFormRealOverflowAndOutOfPageGlyphRemainRefused() throws {
        let tiny = CGFloat(880).ulp * 64
        for (overshoot, glyphX, outsideGlyph) in [(CGFloat(0.000001), CGFloat(72), false), (tiny, CGFloat(-2), true)] {
            let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data:
                roundoffSavedFormFixture(overshoot: overshoot, glyphX: glyphX)))
            let page = try XCTUnwrap(document.page(at: 0))
            let visible = page.bounds(for: .mediaBox).intersection(page.bounds(for: .cropBox))
            XCTAssertEqual(visible.contains(try nativeInk(page)), !outsideGlyph)
            let before = try PDFBodyTextPageSnapshot.data(for: page)
            let pixels = try roundoffPixelsOutside(page, mask: .zero)
            let text = try XCTUnwrap(page.string) as NSString
            let selection = try XCTUnwrap(page.selection(for: text.range(of: "iii")))
            let admitted = try? PDFBodyTextEditor.target(on: page, selection: selection)
            XCTAssertNil(admitted, "Neither real overflow nor out-of-page glyphs receive inward-clamp authority.")
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
            XCTAssertEqual(try roundoffPixelsOutside(page, mask: .zero), pixels)
        }
    }

    func testOwnedSavedFormTinyOverflowDoesNotCrossAnIndependentObstacle() throws {
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data:
            roundoffSavedFormFixture(overshoot: CGFloat(880).ulp * 64, obstacle: true)))
        let page = try XCTUnwrap(document.page(at: 0)), target = try roundoffTarget("iii", on: page)
        XCTAssertLessThanOrEqual(target.paintBounds.maxX, 90)
        let proposed = coreTextInk("WWWWWWWW", target: target)
        XCTAssertFalse(target.paintBounds.contains(proposed))
        let before = try PDFBodyTextPageSnapshot.data(for: page)
        let pixels = try roundoffPixelsOutside(page, mask: .zero)
        XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "WWWWWWWW", style: target.style, bounds: target.bounds))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
        XCTAssertEqual(try roundoffPixelsOutside(page, mask: .zero), pixels)
    }

    private func roundoffTarget(_ word: String, on page: PDFPage) throws -> PDFBodyTextTarget {
        let text = try XCTUnwrap(page.string) as NSString
        let range = text.range(of: word)
        XCTAssertNotEqual(range.location, NSNotFound)
        let selection = try XCTUnwrap(page.selection(for: range))
        return try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
    }

    private func roundoffSavedFormFixture(overshoot: CGFloat, glyphX: CGFloat = 72, obstacle: Bool = false) throws -> Data {
        // The marker is valid inside the Form BBox. Its sole root invocation
        // translates by a bounded decimal amount, producing a real parsed
        // saved-layout edge just beyond the current visible page.
        let translation = String(format: "%.17f", locale: Locale(identifier: "en_US_POSIX"), Double(-overshoot))
        let x = String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), Double(glyphX))
        let independent = obstacle ? "0.6 g 90 725 20 25 re f " : "0.8 g 500 100 80 40 re f "
        let root = "q " + independent + "Q q 1 0 0 1 " + translation + " 0 cm /Owned Do Q\n"
        let body = "BT /F1 18 Tf 1 0 0 1 " + x + " 730 Tm (iii) Tj ET\n"
        let data = PDFMalformedSelectionTestFixture.pdfData(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 640 880] /Resources << /XObject << /Owned 6 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(root.utf8.count) >>\nstream\n\(root)endstream",
            "<< /Type /XObject /Subtype /Form /FormType 1 /EmberPDFBodyText true /EmberPDFBodyTextBounds [0 0 640 880] /BBox [0 0 640 880] /Resources << /Font << /F1 4 0 R >> >> /Length \(body.utf8.count) >>\nstream\n\(body)endstream"
        ])
        guard data.count <= 64 * 1_024 else { throw NSError(domain: "OwnedRoundoffInputCap", code: 1) }
        return data
    }

    private func roundoffPixelsOutside(_ page: PDFPage, mask: CGRect) throws -> Data {
        let media = page.bounds(for: .mediaBox)
        guard media == CGRect(x: 0, y: 0, width: 640, height: 880) else { throw NSError(domain: "OwnedRoundoffRasterCap", code: 1) }
        var pixels = Data(repeating: 255, count: 640 * 880 * 4)
        try pixels.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 640, height: 880,
                bitsPerComponent: 8, bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor); context.fill(media)
            context.drawPDFPage(try XCTUnwrap(page.pageRef))
            let deviceMask = context.convertToDeviceSpace(mask).integral
            context.setShouldAntialias(false); context.setFillColor(NSColor.white.cgColor)
            context.fill(context.convertToUserSpace(deviceMask))
        }
        return pixels
    }

    func testOwnedGeorgiaCaseRoundTripKeepsSourceInkInsideColdDeclaration() throws {
        for constrained in [false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "Ember-Cold-Georgia-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let input = directory.appendingPathComponent("owned-source.pdf")
            try fixture(constrained: constrained).write(to: input, options: .withoutOverwriting)
            var current = input
            var fixedOutside: Data?
            var fixedMask: CGRect?
            var completedColdCycles = 0
            var firstFailureStage = "none"
            var currentStage = "setup"
            defer {
                emit(["stage": "case-summary", "constrained": constrained,
                    "completedColdCycles": completedColdCycles, "expectedColdCycles": 2,
                    "firstFailureStage": firstFailureStage == "none" && completedColdCycles < 2 ? currentStage : firstFailureStage,
                    "lastReachedStage": currentStage,
                    "remainingColdCyclesNotExecuted": 2 - completedColdCycles])
            }
            for (cycle, pair) in [("both", "Both"), ("Both", "both")].enumerated() {
                currentStage = "cycle-\(cycle)-request"
                let workspace = PDFWorkspaceState()
                XCTAssertTrue(workspace.open(url: current))
                workspace.setMode(.editing)
                let document = try XCTUnwrap(workspace.document)
                let page = try XCTUnwrap(document.page(at: 0))
                let text = try XCTUnwrap(page.string) as NSString
                let range = text.range(of: pair.0)
                XCTAssertNotEqual(range.location, NSNotFound)
                let selection = try XCTUnwrap(page.selection(for: range))
                // The production request is the first target/selection consumer.
                let requested = workspace.requestBodyTextEdit(selection: selection)
                emit(["stage": "request", "constrained": constrained, "cycle": cycle,
                    "requested": requested, "error": workspace.presentedError ?? ""])
                XCTAssertTrue(requested)
                guard requested else { firstFailureStage = currentStage; break }
                let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
                let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
                XCTAssertEqual(target.text, pair.0)
                XCTAssertEqual(target.style.alignment, .left)
                XCTAssertEqual(target.firstLineIndent, 0)
                let sourceCTInk = coreTextInk(pair.0, target: target)
                let replacementCTInk = coreTextInk(pair.1, target: target)
                currentStage = "cycle-\(cycle)-source-ink-declaration"
                emit(["stage": "before-commit", "constrained": constrained, "cycle": cycle,
                    "bounds": rect(target.bounds), "declared": rect(target.paintBounds),
                    "nativeInk": rect(try nativeInk(page)), "sourceCTInk": rect(sourceCTInk),
                    "replacementCTInk": rect(replacementCTInk),
                    "sourceCTContained": target.paintBounds.contains(sourceCTInk),
                    "replacementCTContained": target.paintBounds.contains(replacementCTInk),
                    "baseline": [target.baseline.x, target.baseline.y],
                    "font": target.style.fontName, "size": target.style.fontSize,
                    "markers": try markers(page)])
                // For this owned single-line, same-face source, a declaration
                // narrower than its own source glyph paths is the regression.
                XCTAssertTrue(target.paintBounds.contains(sourceCTInk),
                    "Existing source ink must not be silently excluded from its declaration.")
                if !target.paintBounds.contains(sourceCTInk), firstFailureStage == "none" {
                    firstFailureStage = currentStage
                }
                if fixedMask == nil {
                    fixedMask = target.paintBounds
                    fixedOutside = try outside(page, mask: target.paintBounds)
                }
                currentStage = "cycle-\(cycle)-commit"
                workspace.commitPendingInlineText(id: draft.id, text: pair.1,
                    style: draft.style, bounds: draft.bounds)
                emit(["stage": "after-commit", "constrained": constrained, "cycle": cycle,
                    "draftPresent": workspace.pendingInlineTextEdit != nil,
                    "error": workspace.presentedError ?? ""])
                XCTAssertNil(workspace.pendingInlineTextEdit)
                XCTAssertNil(workspace.presentedError)
                guard workspace.pendingInlineTextEdit == nil, workspace.presentedError == nil else {
                    if firstFailureStage == "none" { firstFailureStage = currentStage }
                    break
                }
                let edited = try XCTUnwrap(document.page(at: 0))
                XCTAssertEqual(try outside(edited, mask: XCTUnwrap(fixedMask)), fixedOutside)
                emit(["stage": "edited", "constrained": constrained, "cycle": cycle,
                    "nativeInk": rect(try nativeInk(edited)), "markers": try markers(edited)])
                let output = directory.appendingPathComponent("cold-\(cycle).pdf")
                currentStage = "cycle-\(cycle)-atomic-save"
                try save(document, to: output)
                XCTAssertLessThanOrEqual(try Data(contentsOf: output).count, 1_024 * 1_024)
                PDFBodyTextDocumentFonts.invalidate(document)
                let cold = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Data(contentsOf: output)))
                let coldPage = try XCTUnwrap(cold.page(at: 0))
                currentStage = "cycle-\(cycle)-cold-text-and-outside"
                XCTAssertEqual(coldPage.string?.trimmingCharacters(in: .whitespacesAndNewlines), pair.1)
                XCTAssertEqual(try outside(coldPage, mask: XCTUnwrap(fixedMask)), fixedOutside)
                emit(["stage": "cold-saved", "constrained": constrained, "cycle": cycle,
                    "nativeInk": rect(try nativeInk(coldPage)), "markers": try markers(coldPage)])
                current = output
                completedColdCycles += 1
                currentStage = "cycle-\(cycle)-complete"
            }
            XCTAssertEqual(completedColdCycles, 2, "A refused first change is not a completed cold-reedit test.")
        }
    }

    func testOwnedGeorgiaSameTextNativeRoundTripSeparatesCanonicalizationFromCaseChange() throws {
        for constrained in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "Ember-Cold-Georgia-Noop-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let input = try fixture(constrained: constrained)
            let original = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: input))
            let page = try XCTUnwrap(original.page(at: 0))
            let text = try XCTUnwrap(page.string) as NSString
            let selection = try XCTUnwrap(page.selection(for: text.range(of: "both")))
            let selected = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
            let expectedOutside = try outside(page, mask: selected.paintBounds)
            emit(["stage": "noop-original", "constrained": constrained,
                "declared": rect(selected.paintBounds), "nativeInk": rect(try nativeInk(page)),
                "sourceCTInk": rect(coreTextInk(selected.text, target: selected))])
            // Direct engine call intentionally bypasses the Workspace no-op
            // early return; it diagnoses the native serialization boundary.
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: selected,
                text: selected.text, style: selected.style, bounds: selected.bounds)
            let live = PDFDocument(); live.insert(edited, at: 0)
            let output = directory.appendingPathComponent("same-text-cold.pdf")
            try save(live, to: output)
            let cold = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Data(contentsOf: output)))
            let coldPage = try XCTUnwrap(cold.page(at: 0)), coldText = try XCTUnwrap(coldPage.string) as NSString
            let coldSelection = try XCTUnwrap(coldPage.selection(for: coldText.range(of: "both")))
            let coldTarget = try XCTUnwrap(PDFBodyTextEditor.target(on: coldPage, selection: coldSelection))
            emit(["stage": "noop-cold", "constrained": constrained,
                "declared": rect(coldTarget.paintBounds), "nativeInk": rect(try nativeInk(coldPage)),
                "sourceCTInk": rect(coreTextInk(coldTarget.text, target: coldTarget)),
                "originalDeclared": rect(selected.paintBounds), "markers": try markers(coldPage)])
            XCTAssertEqual(coldTarget.text, selected.text)
            XCTAssertEqual(try outside(coldPage, mask: selected.paintBounds), expectedOutside)
            XCTAssertTrue(coldTarget.paintBounds.contains(coreTextInk(coldTarget.text, target: coldTarget)))
            XCTAssertTrue(coldTarget.paintBounds.contains(selected.paintBounds),
                "A same-text native/cold cycle must expose any narrowed source declaration.")
        }
    }

    func testOwnedGeorgiaColdLeftObstacleRefusesReturnAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Ember-Cold-Georgia-Obstacle-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("owned-source.pdf")
        try fixture(constrained: true).write(to: input, options: .withoutOverwriting)
        let first = PDFWorkspaceState()
        XCTAssertTrue(first.open(url: input)); first.setMode(.editing)
        let document = try XCTUnwrap(first.document), page = try XCTUnwrap(document.page(at: 0))
        let text = try XCTUnwrap(page.string) as NSString
        let selection = try XCTUnwrap(page.selection(for: text.range(of: "both")))
        XCTAssertTrue(first.requestBodyTextEdit(selection: selection))
        let draft = try XCTUnwrap(first.pendingInlineTextEdit)
        let firstTarget = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        let fixedMask = firstTarget.paintBounds
        let originalOutside = try outside(page, mask: fixedMask)
        // Derive only the original selected text's raster contribution before
        // any edit. The shared owned fixture emits the same triangle and paper.
        let background = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(
            data: fixture(constrained: true, includeText: false)))
        let backgroundOutside = try outside(XCTUnwrap(background.page(at: 0)), mask: fixedMask)
        let sourceCoverage = try OriginalOutsideCoverage(original: originalOutside, background: backgroundOutside)
        XCTAssertFalse(sourceCoverage.pixelOffsets.isEmpty,
            "This fixture must exercise source text raster coverage outside its geometric declaration.")
        first.commitPendingInlineText(id: draft.id, text: "Both", style: draft.style, bounds: draft.bounds)
        XCTAssertNil(first.pendingInlineTextEdit); XCTAssertNil(first.presentedError)
        guard first.pendingInlineTextEdit == nil, first.presentedError == nil else {
            XCTFail("Negative control never reached its declared cold-refusal stage."); return
        }
        // Keep the same geometric mask and exact RGBA equality elsewhere.
        // The removed original glyph's precomputed fringe must become the
        // unchanged background, never newly painted pixels outside the mask.
        XCTAssertTrue(sourceCoverage.preservesBackgroundAndRemovesSourceCoverage(
            try outside(XCTUnwrap(document.page(at: 0)), mask: fixedMask)))
        let saved = directory.appendingPathComponent("first-cold.pdf")
        try save(document, to: saved)
        let second = PDFWorkspaceState()
        XCTAssertTrue(second.open(url: saved)); second.setMode(.editing)
        let cold = try XCTUnwrap(second.document), coldPage = try XCTUnwrap(cold.page(at: 0))
        XCTAssertTrue(sourceCoverage.preservesBackgroundAndRemovesSourceCoverage(
            try outside(coldPage, mask: fixedMask)))
        let coldText = try XCTUnwrap(coldPage.string) as NSString
        let coldSelection = try XCTUnwrap(coldPage.selection(for: coldText.range(of: "Both")))
        XCTAssertTrue(second.requestBodyTextEdit(selection: coldSelection))
        let selected = try XCTUnwrap(PDFBodyTextEditor.target(on: coldPage, selection: coldSelection))
        let coldDraft = try XCTUnwrap(second.pendingInlineTextEdit)
        let markerRecords = try markers(coldPage)
        let proposedInk = coreTextInk("both", target: selected)
        XCTAssertFalse(selected.paintBounds.contains(proposedInk),
            "The negative control must actually cross the current independently found obstacle.")
        let beforeBytes = try PDFBodyTextPageSnapshot.data(for: coldPage)
        let beforePixels = try outside(coldPage, mask: .zero)
        second.commitPendingInlineText(id: coldDraft.id, text: "both",
            style: coldDraft.style, bounds: coldDraft.bounds)
        emit(["stage": "cold-obstacle-negative", "declared": rect(selected.paintBounds),
            "proposedInk": rect(proposedInk), "markers": markerRecords,
            "draftPresent": second.pendingInlineTextEdit != nil,
            "error": second.presentedError ?? ""])
        XCTAssertNotNil(second.pendingInlineTextEdit)
        XCTAssertNotNil(second.presentedError)
        XCTAssertTrue(cold.page(at: 0) === coldPage)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: coldPage), beforeBytes)
        XCTAssertEqual(try outside(coldPage, mask: .zero), beforePixels)
        XCTAssertEqual(coldPage.string, coldText as String)
        // No second PDF is saved after an expected refusal.
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("second.pdf").path))
    }

    func testOwnedSourceRasterFootprintStillDetectsUnrelatedTriangleChange() throws {
        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture(constrained: true)))
        let page = try XCTUnwrap(source.page(at: 0)), text = try XCTUnwrap(page.string) as NSString
        let selection = try XCTUnwrap(page.selection(for: text.range(of: "both")))
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        let fixedMask = target.paintBounds
        let background = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(
            data: fixture(constrained: true, includeText: false)))
        let backgroundOutside = try outside(XCTUnwrap(background.page(at: 0)), mask: fixedMask)
        let coverage = try OriginalOutsideCoverage(original: outside(page, mask: fixedMask),
            background: backgroundOutside)
        XCTAssertFalse(coverage.pixelOffsets.isEmpty)
        XCTAssertTrue(coverage.preservesBackgroundAndRemovesSourceCoverage(backgroundOutside),
            "Removing only the independently identified original text must remain admissible.")
        // The control changes real unrelated vector paint, not selected text.
        // Neither its pixels nor the future edit choose the source footprint.
        let changedTriangle = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(
            data: fixture(constrained: true, includeText: false, triangleWhite: 0.6)))
        let changedOutside = try outside(XCTUnwrap(changedTriangle.page(at: 0)), mask: fixedMask)
        XCTAssertNotEqual(changedOutside, backgroundOutside)
        XCTAssertNotEqual(try coverage.withoutOriginalSourceCoverage(changedOutside),
            try coverage.withoutOriginalSourceCoverage(backgroundOutside),
            "The negative control must change pixels outside the source-only footprint.")
        XCTAssertFalse(coverage.preservesBackgroundAndRemovesSourceCoverage(changedOutside),
            "Source text coverage must never conceal an unrelated triangle color change.")
    }

    /// Test-only raster ownership, captured entirely from original inputs.
    /// This does not widen the geometric mask or accept any RGBA tolerance.
    private struct OriginalOutsideCoverage {
        let pixelOffsets: [Int]
        private let background: Data
        private let originalWithoutCoverage: Data

        init(original: Data, background: Data) throws {
            guard original.count == 720 * 560 * 4, background.count == original.count else {
                throw NSError(domain: "OwnedCoverageCap", code: 1)
            }
            self.background = background
            var offsets: [Int] = [], normalized = original
            for offset in stride(from: 0, to: original.count, by: 4) {
                if (0..<4).contains(where: { original[offset + $0] != background[offset + $0] }) {
                    offsets.append(offset)
                    for channel in 0..<4 { normalized[offset + channel] = 0 }
                }
            }
            pixelOffsets = offsets
            originalWithoutCoverage = normalized
        }

        func withoutOriginalSourceCoverage(_ pixels: Data) throws -> Data {
            guard pixels.count == background.count else { throw NSError(domain: "OwnedCoverageCap", code: 2) }
            var result = pixels
            for offset in pixelOffsets { for channel in 0..<4 { result[offset + channel] = 0 } }
            return result
        }

        func preservesBackgroundAndRemovesSourceCoverage(_ actual: Data) -> Bool {
            guard actual.count == background.count,
                  let normalized = try? withoutOriginalSourceCoverage(actual),
                  normalized == originalWithoutCoverage else { return false }
            // The excluded old coverage is independently checked too: the
            // replacement must expose precisely the original background there.
            return pixelOffsets.allSatisfy { offset in
                (0..<4).allSatisfy { actual[offset + $0] == background[offset + $0] }
            }
        }
    }

    private func fixture(constrained: Bool, includeText: Bool = true, triangleWhite: CGFloat = 0.9) throws -> Data {
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 360, height: 280)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = try XCTUnwrap(NSFont(name: "Georgia", size: 15))
        let baseline = CGPoint(x: 80.125, y: 190.375)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "both", attributes: [
            .font: font, .foregroundColor: NSColor.black, .ligature: 0]))
        let originalInk = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            .offsetBy(dx: baseline.x, dy: baseline.y)
        context.beginPDFPage(nil)
        if constrained {
            // Only the left edge is constrained. This nonrectangular shape's
            // bounds intrude 0.05pt into the original CT ink's left edge, while
            // its vertical bounds stay strictly inside the original ink.
            // It does not also clamp the line's right/top/bottom clearance.
            let edge = originalInk.minX + 0.05
            let middle = originalInk.midY
            let halfHeight = min(1, originalInk.height / 10)
            context.setFillColor(NSColor(calibratedWhite: triangleWhite, alpha: 1).cgColor)
            context.move(to: CGPoint(x: 20, y: middle - halfHeight))
            context.addLine(to: CGPoint(x: edge, y: middle))
            context.addLine(to: CGPoint(x: 20, y: middle + halfHeight))
            context.closePath(); context.fillPath()
        }
        context.textMatrix = .identity
        context.textPosition = baseline
        if includeText { CTLineDraw(line, context) }
        context.endPDFPage(); context.closePDF()
        guard bytes.length <= 1_024 * 1_024 else { throw NSError(domain: "OwnedFixtureCap", code: 1) }
        return bytes as Data
    }

    private func coreTextInk(_ text: String, target: PDFBodyTextTarget) -> CGRect {
        let attributed = PDFBodyTextAttributedLayout.attributedString(text: text, style: target.style,
            sourceText: target.text, sourceStyle: target.style, sourceRuns: target.sourceRuns,
            lineHeight: target.lineHeight, firstLineIndent: target.firstLineIndent)
        let line = CTLineCreateWithAttributedString(attributed)
        return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            .offsetBy(dx: target.baseline.x, dy: target.baseline.y)
    }

    private func markers(_ page: PDFPage) throws -> [[String: Any]] {
        let program = try PDFBodyTextContentStream.parse(PDFBodyTextPageSnapshot.contentData(for: page))
        guard program.forms.count <= 8 else { throw NSError(domain: "OwnedFormCap", code: 1) }
        return try program.forms.compactMap { form in
            guard let saved = try PDFBodyTextPageSnapshot.bodyTextLayoutBounds(named: form.name, on: page) else { return nil }
            return ["name": form.name, "local": rect(saved),
                "page": rect(saved.applying(form.transform)),
                "matrix": [form.transform.a, form.transform.b, form.transform.c,
                    form.transform.d, form.transform.tx, form.transform.ty]]
        }
    }

    private func nativeInk(_ page: PDFPage) throws -> CGRect {
        let data = try PDFBodyTextPageSnapshot.data(for: page)
        return try data.withUnsafeBytes { bytes in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(document) }
            let native = try XCTUnwrap(FPDF_LoadPage(document, 0)); defer { FPDF_ClosePage(native) }
            let text = try XCTUnwrap(FPDFText_LoadPage(native)); defer { FPDFText_ClosePage(text) }
            let count = FPDFText_CountChars(text)
            guard count > 0, count <= 32 else { throw NSError(domain: "OwnedGlyphCap", code: 1) }
            var union = CGRect.null
            for index in 0..<count where FPDFText_GetUnicode(text, index) > 32 {
                var l = 0.0, r = 0.0, b = 0.0, t = 0.0
                guard FPDFText_GetCharBox(text, index, &l, &r, &b, &t) != 0,
                      [l, r, b, t].allSatisfy(\.isFinite), r >= l, t >= b else {
                    throw NSError(domain: "OwnedGlyphBounds", code: 1)
                }
                union = union.union(CGRect(x: l, y: b, width: r - l, height: t - b))
            }
            return union
        }
    }

    private func outside(_ page: PDFPage, mask: CGRect) throws -> Data {
        let media = page.bounds(for: .mediaBox), scale: CGFloat = 2
        let w = Int(media.width * scale), h = Int(media.height * scale)
        guard w == 720, h == 560 else { throw NSError(domain: "OwnedRasterCap", code: 1) }
        var pixels = Data(repeating: 255, count: w * h * 4)
        try pixels.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale); ctx.drawPDFPage(try XCTUnwrap(page.pageRef))
            // Draw the fixed mask in the same CTM as the page. No bitmap-row
            // orientation assumption and no post-edit mask expansion.
            let deviceMask = ctx.convertToDeviceSpace(mask).integral
            ctx.setShouldAntialias(false)
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(ctx.convertToUserSpace(deviceMask))
        }
        return pixels
    }

    private final class Completion: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var value: Result<Void, Error>?
        func set(_ result: Result<Void, Error>) { lock.lock(); value = result; lock.unlock(); ready.signal() }
        func take() -> Result<Void, Error>? { lock.lock(); defer { lock.unlock() }; return value }
    }
    private func save(_ document: PDFDocument, to url: URL) throws {
        let snapshot = try PDFRecoverySnapshot(capturing: document), result = Completion()
        DispatchQueue.global(qos: .userInitiated).async {
            result.set(Result { _ = try AtomicPDFWriter.write(snapshot.takeDocument(), to: url) })
        }
        let deadline = Date().addingTimeInterval(30)
        while result.ready.wait(timeout: .now()) != .success {
            guard Date() < deadline else { throw NSError(domain: "OwnedWriterDeadline", code: 1) }
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
        try XCTUnwrap(result.take()).get()
    }
    private func rect(_ r: CGRect) -> [CGFloat] { [r.minX, r.minY, r.maxX, r.maxY] }
    private func emit(_ value: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              bytes.count <= 16 * 1_024 else { XCTFail("Owned observation cap"); return }
        FileHandle.standardError.write(Data("OWNED_COLD_BOUND ".utf8) + bytes + Data([10]))
    }
}
