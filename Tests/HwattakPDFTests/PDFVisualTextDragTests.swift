// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFVisualTextDragTests: XCTestCase {
    func testSelectionUsesVisibleRowsInsteadOfOCRColumnOrderInBothDirections() {
        let lines = [line("157", x: 10, y: 100), line("165", x: 10, y: 60),
                     line("Other text", x: 55, y: 100), line("Selected text", x: 55, y: 60)]
        for (start, end) in [(CGPoint(x: 8, y: 65), CGPoint(x: 190, y: 65)),
                             (CGPoint(x: 190, y: 65), CGPoint(x: 8, y: 65))] {
            let fragments = PDFVisualTextDrag(start: start, end: end)
                .fragments(from: lines, imageToPage: .identity)
            XCTAssertEqual(fragments.map(\.text), ["165", "Selected text"])
            XCTAssertTrue(fragments.allSatisfy { $0.bounds.minY == 60 })
        }
    }

    func testPartialCharactersAndMultilineEndpoints() {
        let lines = [line("Alpha bravo", x: 10, y: 100), line("Echo foxtrot", x: 10, y: 60)]
        let partial = PDFVisualTextDrag(start: CGPoint(x: 69, y: 105), end: CGPoint(x: 119, y: 105))
            .fragments(from: lines, imageToPage: .identity)
        XCTAssertEqual(partial.map(\.text), ["bravo"])
        let multiline = PDFVisualTextDrag(start: CGPoint(x: 69, y: 105), end: CGPoint(x: 49, y: 65))
            .fragments(from: lines, imageToPage: .identity)
        XCTAssertEqual(multiline.map(\.text), ["bravo", "Echo"])
        XCTAssertEqual(multiline.map(\.bounds), [CGRect(x: 70, y: 100, width: 50, height: 10),
                                                CGRect(x: 10, y: 60, width: 40, height: 10)])
    }

    func testMultilineTOCSelectionStaysInItsColumnWithStaggeredRowsInBothDirections() {
        let left = [line("17-7", x: 10, y: 140), line("Waves", x: 80, y: 140), line("502", x: 220, y: 140),
                    line("Refraction", x: 80, y: 100), line("506", x: 220, y: 100),
                    line("17-9", x: 10, y: 60), line("Doppler", x: 80, y: 60), line("507", x: 220, y: 60)]
        let right = [line("20-4", x: 340, y: 155), line("Distribution", x: 410, y: 155), line("588", x: 550, y: 155),
                     line("Diffusion", x: 410, y: 115), line("593", x: 550, y: 115),
                     line("20-6", x: 340, y: 75), line("Real gases", x: 410, y: 75), line("596", x: 550, y: 75)]
        let lines = right + left // OCR reading order is deliberately unrelated.
        for (start, end, expected) in [
            (CGPoint(x: 8, y: 145), CGPoint(x: 260, y: 65), left),
            (CGPoint(x: 338, y: 160), CGPoint(x: 590, y: 80), right)
        ] {
            for (first, last) in [(start, end), (end, start)] {
                let fragments = PDFVisualTextDrag(start: first, end: last)
                    .fragments(from: lines, imageToPage: .identity)
                XCTAssertEqual(fragments.map(\.text), expected.map(\.text))
                XCTAssertEqual(fragments.map(\.bounds), expected.map(\.bounds))
            }
        }
    }

    func testColumnSelectionPreservesPartialMultilineEndpointsAtEveryRotation() {
        let lines = [line("Alpha bravo", x: 10, y: 100), line("Echo foxtrot", x: 10, y: 60),
                     line("Other first", x: 240, y: 105), line("Other second", x: 240, y: 65)]
        for rotation in [0, 90, 180, 270] {
            let transform = PDFRegionTextRecognizer.displayTransform(
                cropBox: CGRect(x: 30, y: 60, width: 400, height: 500), rotation: rotation).inverted()
            for (start, end) in [(CGPoint(x: 69, y: 105), CGPoint(x: 49, y: 65)),
                                 (CGPoint(x: 49, y: 65), CGPoint(x: 69, y: 105))] {
                let fragments = PDFVisualTextDrag(start: start.applying(transform), end: end.applying(transform))
                    .fragments(from: lines, imageToPage: transform)
                XCTAssertEqual(fragments.map(\.text), ["bravo", "Echo"])
                XCTAssertEqual(fragments.map(\.bounds), [CGRect(x: 70, y: 100, width: 50, height: 10),
                                                        CGRect(x: 10, y: 60, width: 40, height: 10)]
                    .map { $0.applying(transform) })
            }
        }
    }

    func testWideSectionNumberAndPageNumberSpacingDoesNotSplitTOCEntries() {
        let lines = [line("17-7", x: 10, y: 140), line("Waves", x: 110, y: 140), line("502", x: 300, y: 140),
                     line("17-8", x: 10, y: 100), line("Refraction", x: 110, y: 100), line("506", x: 300, y: 100),
                     line("17-9", x: 10, y: 60), line("Doppler", x: 110, y: 60), line("507", x: 300, y: 60)]
        let fragments = PDFVisualTextDrag(start: CGPoint(x: 108, y: 145), end: CGPoint(x: 340, y: 65))
            .fragments(from: lines, imageToPage: .identity)
        XCTAssertEqual(fragments.map(\.text), ["Waves", "502", "17-8", "Refraction", "506", "17-9", "Doppler", "507"])
    }

    func testPartialTOCDragKeepsPageNumbersInItsColumn() {
        let lines = [line("17-7", x: 10, y: 140), line("Waves", x: 80, y: 140), line("502", x: 220, y: 140),
                     line("17-8", x: 10, y: 100), line("Refraction", x: 80, y: 100), line("506", x: 220, y: 100),
                     line("17-9", x: 10, y: 60), line("Doppler", x: 80, y: 60), line("507", x: 220, y: 60),
                     line("Other first", x: 340, y: 145), line("Other middle", x: 340, y: 105),
                     line("Other last", x: 340, y: 65)]
        let fragments = PDFVisualTextDrag(start: CGPoint(x: 78, y: 145), end: CGPoint(x: 160, y: 65))
            .fragments(from: lines, imageToPage: .identity)
        XCTAssertEqual(fragments.map(\.text), ["Waves", "502", "17-8", "Refraction", "506", "17-9", "Doppler"])
    }

    func testColumnGutterCanBeFoundInsideCombinedOCRObservations() {
        let lines = [line("Alpha bravo              Other first", x: 10, y: 100),
                     line("Echo foxtrot             Other second", x: 10, y: 60)]
        let fragments = PDFVisualTextDrag(start: CGPoint(x: 8, y: 105), end: CGPoint(x: 140, y: 65))
            .fragments(from: lines, imageToPage: .identity)
        XCTAssertEqual(fragments.map(\.text), ["Alpha bravo", "Echo foxtrot"])
        XCTAssertTrue(fragments.allSatisfy { $0.bounds.maxX <= 130 })
    }

    func testFullWidthHeaderElsewhereDoesNotBridgeDraggedColumns() {
        let lines = [line("A full width running header across both columns", x: 10, y: 200),
                     line("Alpha bravo", x: 10, y: 100), line("Echo foxtrot", x: 10, y: 60),
                     line("Other first", x: 240, y: 105), line("Other second", x: 240, y: 65)]
        let fragments = PDFVisualTextDrag(start: CGPoint(x: 8, y: 105), end: CGPoint(x: 140, y: 65))
            .fragments(from: lines, imageToPage: .identity)
        XCTAssertEqual(fragments.map(\.text), ["Alpha bravo", "Echo foxtrot"])
    }

    func testSingleOppositeColumnRowDoesNotEnterMultilineSelection() {
        let lines = [line("Alpha bravo", x: 10, y: 100), line("Echo foxtrot", x: 10, y: 60),
                     line("Other column", x: 240, y: 80)]
        for (start, end) in [(CGPoint(x: 8, y: 105), CGPoint(x: 140, y: 65)),
                             (CGPoint(x: 140, y: 65), CGPoint(x: 8, y: 105))] {
            let fragments = PDFVisualTextDrag(start: start, end: end)
                .fragments(from: lines, imageToPage: .identity)
            XCTAssertEqual(fragments.map(\.text), ["Alpha bravo", "Echo foxtrot"])
        }
    }

    func testShortDiagonalDragDoesNotSnapToCloserRowInOppositeColumn() {
        let lines = [line("Alpha bravo", x: 10, y: 100), line("Other column", x: 240, y: 115)]
        for (start, end) in [(CGPoint(x: 8, y: 105), CGPoint(x: 119, y: 114)),
                             (CGPoint(x: 119, y: 114), CGPoint(x: 8, y: 105))] {
            let fragments = PDFVisualTextDrag(start: start, end: end)
                .fragments(from: lines, imageToPage: .identity)
            XCTAssertEqual(fragments.map(\.text), ["Alpha bravo"])
            XCTAssertEqual(fragments.first?.bounds, lines[0].bounds)
        }
    }

    func testLongTOCTitlesKeepNarrowBookGutterInBothDirections() {
        let left = [line("Interference in Pulses and One-Dimensional", x: 10, y: 100),
                    line("Two-and Three-Dimensional Interference", x: 10, y: 60)]
        let rightX = left.map(\.bounds.maxX).max()! + 18
        let lines = left + [line("Thermal Energy Work and Heat", x: rightX, y: 105),
                            line("Specific Thermodynamic Processes", x: rightX, y: 65)]
        let first = CGPoint(x: 8, y: 105)
        let last = CGPoint(x: left[1].bounds.maxX + 1, y: 65)
        for (start, end) in [(first, last), (last, first)] {
            let fragments = PDFVisualTextDrag(start: start, end: end)
                .fragments(from: lines, imageToPage: .identity)
            XCTAssertEqual(fragments.map(\.text), left.map(\.text))
            XCTAssertEqual(fragments.map(\.bounds), left.map(\.bounds))
        }
    }

    func testCachedLayoutExcludesLeftFigureLabelsFromBodyDrag() {
        let body = [line("The magnetic field points north.", x: 240, y: 140),
                    line("A compass aligns with the field.", x: 240, y: 100),
                    line("Its direction varies by location.", x: 240, y: 60)]
        // Embedded PDF order can interleave figure labels between body lines.
        let lines = [body[0], line("Geographic", x: 10, y: 120), body[1],
                     line("South Pole", x: 20, y: 80), body[2]]
        let layout = PDFVisualTextLayout(lines: lines, imageToPage: .identity)
        let first = CGPoint(x: 238, y: 145)
        let last = CGPoint(x: body[2].bounds.maxX + 1, y: 65)
        for (start, end) in [(first, last), (last, first)] {
            let fragments = layout.fragments(for: PDFVisualTextDrag(start: start, end: end))
            XCTAssertEqual(fragments.map(\.text), body.map(\.text))
            XCTAssertEqual(fragments.map(\.bounds), body.map(\.bounds))
        }
        // Reusing one layout with a different gesture must still allow the
        // labels themselves to be selected intentionally.
        let labels = layout.fragments(for: PDFVisualTextDrag(
            start: CGPoint(x: 8, y: 125), end: CGPoint(x: 130, y: 85)))
        XCTAssertEqual(labels.map(\.text), ["Geographic", "South Pole"])
    }

    func testCachedRowsAreRegroupedAfterRemovingTallOppositeColumnObservation() {
        let body = [line("Alpha bravo", x: 240, y: 100), line("Echo foxtrot", x: 240, y: 60)]
        let label = line("Geographic South Pole", x: 10, y: 80)
        let tallLabel = PDFVisualTextLine(text: label.text,
            bounds: CGRect(x: 10, y: 20, width: 210, height: 200), characterBounds: label.characterBounds)
        let layout = PDFVisualTextLayout(lines: [tallLabel] + body, imageToPage: .identity)
        let fragments = layout.fragments(for: PDFVisualTextDrag(
            start: CGPoint(x: 238, y: 105), end: CGPoint(x: 370, y: 65)))
        XCTAssertEqual(fragments.map(\.text), body.map(\.text))
        XCTAssertEqual(fragments.map(\.bounds), body.map(\.bounds))
    }

    func testCachedEndpointsFollowCharacterEdgesWhenPointerMovesBackAndForth() {
        let layout = PDFVisualTextLayout(lines: [line("Alpha bravo", x: 10, y: 100)],
                                         imageToPage: .identity)
        let start = CGPoint(x: 8, y: 105)
        for (x, expected) in [(24.9, "A"), (25.0, "Al"), (25.1, "Al"),
                              (54.9, "Alph"), (55.0, "Alpha"), (69.9, "Alpha"),
                              (75.0, "Alpha b"), (25.0, "Al"), (24.9, "A")] {
            let end = CGPoint(x: x, y: 105)
            for (first, last) in [(start, end), (end, start)] {
                XCTAssertEqual(layout.fragments(for: PDFVisualTextDrag(start: first, end: last))
                    .map(\.text), [expected])
            }
        }
        // An empty result must invalidate the returned fragment cache. Moving
        // back over the old endpoint then restores the text immediately.
        XCTAssertTrue(layout.fragments(for: PDFVisualTextDrag(
            start: CGPoint(x: 62, y: 105), end: CGPoint(x: 68, y: 105))).isEmpty)
        XCTAssertEqual(layout.fragments(for: PDFVisualTextDrag(
            start: start, end: CGPoint(x: 55, y: 105))).map(\.text), ["Alpha"])
    }

    func testCachedGutterAndRowsUpdateWhenDragChangesLinesOrColumns() {
        let body = [line("Alpha bravo", x: 240, y: 140),
                    line("Echo foxtrot", x: 240, y: 100),
                    line("Golf hotel", x: 240, y: 60)]
        let layout = PDFVisualTextLayout(lines: [body[0], line("Geographic", x: 10, y: 120),
            body[1], line("South Pole", x: 20, y: 80), body[2]], imageToPage: .identity)
        let first = CGPoint(x: 238, y: 145)
        for (end, expected) in [
            (CGPoint(x: 290, y: 145), ["Alpha"]),
            (CGPoint(x: 280, y: 105), ["Alpha bravo", "Echo"]),
            (CGPoint(x: 280, y: 65), ["Alpha bravo", "Echo foxtrot", "Golf"]),
            (CGPoint(x: 280, y: 105), ["Alpha bravo", "Echo"])
        ] {
            XCTAssertEqual(layout.fragments(for: PDFVisualTextDrag(start: first, end: end))
                .map(\.text), expected)
        }
        XCTAssertEqual(layout.fragments(for: PDFVisualTextDrag(
            start: CGPoint(x: 8, y: 125), end: CGPoint(x: 130, y: 85)))
            .map(\.text), ["Geographic", "South Pole"])
        XCTAssertEqual(layout.fragments(for: PDFVisualTextDrag(
            start: first, end: CGPoint(x: 280, y: 65)))
            .map(\.text), ["Alpha bravo", "Echo foxtrot", "Golf"])
    }

    func testCachedCharacterEdgesKeepExpandedLigatureTogether() {
        let cluster = CGRect(x: 20, y: 100, width: 10, height: 10)
        let source = PDFVisualTextLine(text: "office",
            bounds: CGRect(x: 10, y: 100, width: 50, height: 10),
            characterBounds: [CGRect(x: 10, y: 100, width: 10, height: 10),
                cluster, cluster, cluster,
                CGRect(x: 40, y: 100, width: 10, height: 10),
                CGRect(x: 50, y: 100, width: 10, height: 10)])
        let layout = PDFVisualTextLayout(lines: [source], imageToPage: .identity)
        for (x, expected) in [(24.9, []), (25.0, ["ffi"]), (25.1, ["ffi"]),
                              (44.9, ["ffi"]), (45.0, ["ffic"]), (24.9, [])] {
            XCTAssertEqual(layout.fragments(for: PDFVisualTextDrag(
                start: CGPoint(x: 19, y: 105), end: CGPoint(x: x, y: 105)))
                .map(\.text), expected)
        }
    }

    func testDragStartedOnTextKeepsSelectionWhenReleasedInMargin() {
        let lines = [line("157", x: 10, y: 100), line("165", x: 10, y: 60),
                     line("Other text", x: 55, y: 100), line("Selected text", x: 55, y: 60)]
        let selection = PDFVisualTextDrag(start: CGPoint(x: 8, y: 65), end: CGPoint(x: 190, y: 40))
            .fragments(from: lines, imageToPage: .identity)
        XCTAssertEqual(selection.map(\.text), ["165", "Selected text"])
        XCTAssertTrue(selection.allSatisfy { $0.bounds.minY == 60 })
        let blankStart = PDFVisualTextDrag(start: CGPoint(x: 8, y: 40), end: CGPoint(x: 190, y: 65))
            .fragments(from: lines, imageToPage: .identity)
        XCTAssertTrue(blankStart.isEmpty)
    }

    func testWhitespaceAndBlankMarginDoNotSelectAnUnrelatedLine() {
        let lines = [line("Alpha bravo", x: 10, y: 100)]
        XCTAssertTrue(PDFVisualTextDrag(start: CGPoint(x: 62, y: 105), end: CGPoint(x: 68, y: 105))
            .fragments(from: lines, imageToPage: .identity).isEmpty)
        XCTAssertTrue(PDFVisualTextDrag(start: CGPoint(x: 10, y: 50), end: CGPoint(x: 100, y: 50))
            .fragments(from: lines, imageToPage: .identity).isEmpty)
    }

    func testRotatedPageCoordinatesSelectSameVisibleText() {
        let lines = [line("165", x: 10, y: 60), line("Selected text", x: 55, y: 60)]
        for rotation in [0, 90, 180, 270] {
            let pageToImage = PDFRegionTextRecognizer.displayTransform(
                cropBox: CGRect(x: 30, y: 60, width: 300, height: 400), rotation: rotation)
            let imageToPage = pageToImage.inverted()
            let drag = PDFVisualTextDrag(start: CGPoint(x: 8, y: 65).applying(imageToPage),
                                         end: CGPoint(x: 190, y: 65).applying(imageToPage))
            let fragments = drag.fragments(from: lines, imageToPage: imageToPage)
            XCTAssertEqual(fragments.map(\.text), ["165", "Selected text"])
            XCTAssertEqual(fragments[0].bounds, lines[0].bounds.applying(imageToPage))
        }
    }

    func testHorizontalDragRendersBoundedLineContextAtEveryRotation() {
        let crop = CGRect(x: 30, y: 60, width: 300, height: 400)
        for rotation in [0, 90, 180, 270] {
            let transform = PDFRegionTextRecognizer.displayTransform(cropBox: crop, rotation: rotation)
            let drag = PDFVisualTextDrag(start: CGPoint(x: 45, y: 200).applying(transform.inverted()),
                                         end: CGPoint(x: 250, y: 200).applying(transform.inverted()))
            let region = drag.recognitionRegion(cropBox: crop, rotation: rotation)
            XCTAssertFalse(region.isEmpty)
            XCTAssertEqual(region.intersection(crop), region)
            XCTAssertEqual(region.applying(transform).height, 48, accuracy: 0.001)
        }
    }

    @MainActor
    func testCursorUsesIBeamForTextAndImagePageButLeavesLinksAndControlsNative() throws {
        _ = NSApplication.shared
        let workspace = PDFWorkspaceState()
        let view = InteractivePDFView(frame: .zero)
        view.configure(with: workspace)
        // Empty documents have no copying permission; selection cannot pretend
        // to work there, just as for password-protected reader sessions.
        XCTAssertFalse(view.usesTextSelectionCursor(for: [.pageArea, .textArea]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cursor.pdf")
        try PDFMalformedSelectionTestFixture.data().write(to: url)
        XCTAssertTrue(workspace.open(url: url))
        view.configure(with: workspace)
        XCTAssertTrue(view.usesTextSelectionCursor(for: [.pageArea, .textArea]))
        XCTAssertTrue(view.usesTextSelectionCursor(for: [.pageArea, .imageArea]))
        for interactive: PDFAreaOfInterest in [.linkArea, .controlArea, .textFieldArea, .iconArea, .popupArea] {
            XCTAssertFalse(view.usesTextSelectionCursor(for: [.pageArea, interactive]))
        }
        workspace.setMode(.editing)
        workspace.activeTool = .pen
        view.configure(with: workspace)
        XCTAssertFalse(view.usesTextSelectionCursor(for: [.pageArea, .textArea]))
        view.workspaceState = nil
    }

    private func line(_ text: String, x: CGFloat, y: CGFloat) -> PDFVisualTextLine {
        let boxes: [CGRect?] = text.enumerated().map { offset, character in
            character.isWhitespace ? nil : CGRect(x: x + CGFloat(offset) * 10, y: y, width: 10, height: 10)
        }
        return PDFVisualTextLine(text: text, bounds: CGRect(x: x, y: y, width: CGFloat(text.count) * 10, height: 10),
                                 characterBounds: boxes)
    }
}
