// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

/// Opt-in coverage for the damaged hidden text layer in the supplied Katz PDF.
/// The source is opened in place, never copied, rewritten, saved, or exported.
/// EMBER_SELECTION_TEST_PDF supplies the absolute path; optional
/// EMBER_SELECTION_TEST_DIAGNOSTICS supplies a directory for selection PNGs.
final class PDFVisualSelectionRealFileTests: XCTestCase {
    private enum Failure: Error { case unexpectedWrite }

    @MainActor
    func testKatzMagneticParagraphDragExcludesFigureLabelsAndPreservesSourceText() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["EMBER_SELECTION_TEST_PDF"], path.hasPrefix("/") else {
            throw XCTSkip("Real PDF selection coverage is opt-in via EMBER_SELECTION_TEST_PDF.")
        }
        let sourceURL = URL(fileURLWithPath: path)
        let originalVersion = try PDFSourceFileVersion.capture(at: sourceURL)
        _ = NSApplication.shared
        let workspace = PDFWorkspaceState(pdfWriter: { _, _, _ in throw Failure.unexpectedWrite })
        XCTAssertTrue(workspace.open(url: sourceURL))
        let document = try XCTUnwrap(workspace.document)
        let page = try XCTUnwrap(document.page(at: 966), "The magnetic-field example is printed page 938.")
        let originalText = page.string
        let revision = workspace.revision
        let annotationCount = page.annotations.count
        let pageCount = document.pageCount
        workspace.setCurrentPage(966)
        workspace.setMode(.viewer)
        workspace.activeTool = .select
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 1_100))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            view.regionSelection.cancel()
            view.prepareInlineTextEditingOverlayForRemoval()
            view.prepareAnnotationEditingOverlayForRemoval()
            view.workspaceState = nil
            view.document = nil
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
            workspace.closeDiscardingChanges()
        }
        view.displayBox = .cropBox
        view.displayMode = .singlePage
        view.autoScales = false
        view.scaleFactor = min(850 / page.bounds(for: .cropBox).width, 1_050 / page.bounds(for: .cropBox).height)
        view.document = document
        view.go(to: page)
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        view.configure(with: workspace)
        view.regionSelection.synchronize()
        XCTAssertTrue(view.visiblePages.contains { $0 === page })

        // These are visible PDF coordinates, measured independently from the
        // source's interleaved text order. A native character-range selection
        // wrongly adds the diagram's Geographic/South Pole labels at x203.
        let full = PDFVisualTextDrag(start: CGPoint(x: 272.5, y: 193), end: CGPoint(x: 329, y: 135))
        let expected = [
            "The other complication is that the Earth’s magnetic poles are not",
            "fixed. The poles switch roughly every 300,000 years, so the north",
            "magnetic pole will one day be very close to the geographic North",
            "Pole, and the south magnetic pole will be very close to the geo-",
            "graphic South Pole. The magnetic poles also wander several tens of",
            "kilometers daily."
        ]
        var fullFragments: [PDFRegionTextFragment] = []
        for gesture in [full, PDFVisualTextDrag(start: full.end, end: full.start)] {
            try begin(gesture, in: view, page: page)
            let selection = try XCTUnwrap(workspace.currentSelection as? PDFRegionTextSelection,
                                          "Repaired native text must follow the pointer synchronously.")
            XCTAssertEqual(normalized(selection.string), normalized(expected.joined(separator: " ")))
            XCTAssertFalse(selection.string?.contains("Geographic") ?? true)
            XCTAssertFalse(selection.fragments.contains { $0.text == "South Pole" })
            XCTAssertTrue(selection.fragments.allSatisfy { $0.bounds.minX > 250 && $0.bounds.height < 20 })
            XCTAssertTrue(selection.pages.first === page)
            XCTAssertNil(view.currentSelection)
            if fullFragments.isEmpty { fullFragments = selection.fragments }
            else { XCTAssertEqual(selection.fragments, fullFragments) }
            view.mouseUp(with: try event(.leftMouseUp, at: gesture.end, in: view, page: page))
            XCTAssertEqual(normalized(workspace.currentSelection?.string), normalized(expected.joined(separator: " ")))
        }

        let partial = PDFVisualTextDrag(start: CGPoint(x: 315.05, y: 193), end: CGPoint(x: 488.55, y: 158))
        let expectedPartial = [
            "complication is that the Earth’s magnetic poles are not", expected[1], expected[2],
            "Pole, and the south magnetic pole will be very close"
        ]
        var partialFragments: [PDFRegionTextFragment] = []
        for gesture in [partial, PDFVisualTextDrag(start: partial.end, end: partial.start)] {
            try begin(gesture, in: view, page: page)
            let selection = try XCTUnwrap(workspace.currentSelection as? PDFRegionTextSelection)
            XCTAssertEqual(normalized(selection.string), normalized(expectedPartial.joined(separator: " ")))
            XCTAssertFalse(selection.string?.contains("Geographic") ?? true)
            XCTAssertFalse(selection.string?.contains("South Pole") ?? true)
            XCTAssertTrue(selection.fragments.allSatisfy { $0.bounds.minX > 250 && $0.bounds.height < 20 })
            if partialFragments.isEmpty { partialFragments = selection.fragments }
            else { XCTAssertEqual(selection.fragments, partialFragments) }
            view.mouseUp(with: try event(.leftMouseUp, at: gesture.end, in: view, page: page))
            XCTAssertEqual(normalized(workspace.currentSelection?.string), normalized(expectedPartial.joined(separator: " ")))
        }

        // The screenshot's endpoint stops inside the fifth line, after its
        // first sentence. The visible period ends at PDF x341.49 on this page.
        let fiveLine = PDFVisualTextDrag(start: full.start, end: CGPoint(x: 341.48, y: 147))
        let expectedFiveLine = Array(expected.prefix(4)) + ["graphic South Pole."]
        var fiveLineFragments: [PDFRegionTextFragment] = []
        for gesture in [fiveLine, PDFVisualTextDrag(start: fiveLine.end, end: fiveLine.start)] {
            try begin(gesture, in: view, page: page)
            let selection = try XCTUnwrap(workspace.currentSelection as? PDFRegionTextSelection)
            XCTAssertEqual(normalized(selection.string), normalized(expectedFiveLine.joined(separator: " ")))
            XCTAssertFalse(selection.string?.contains("Geographic") ?? true)
            XCTAssertFalse(selection.fragments.contains { $0.text == "South Pole" })
            XCTAssertFalse(selection.string?.contains("The magnetic poles also wander") ?? true)
            XCTAssertTrue(selection.fragments.allSatisfy { $0.bounds.minX > 250 && $0.bounds.height < 20 })
            if fiveLineFragments.isEmpty { fiveLineFragments = selection.fragments }
            else { XCTAssertEqual(selection.fragments, fiveLineFragments) }
            view.mouseUp(with: try event(.leftMouseUp, at: gesture.end, in: view, page: page))
            XCTAssertEqual(normalized(workspace.currentSelection?.string), normalized(expectedFiveLine.joined(separator: " ")))
        }

        // Record completed synchronous pointer updates separately from frame
        // drawing and the final commit. This does not measure display latency.
        // Tiny movements stay inside the same character boundary; they must
        // preserve the existing selection object and avoid redundant publishes.
        try begin(full, in: view, page: page)
        let stableSelection = try XCTUnwrap(workspace.currentSelection as? PDFRegionTextSelection)
        let iterationCount = 500
        let points = (0..<iterationCount).map { index in
            CGPoint(x: full.end.x + CGFloat(index % 5) * 0.002,
                    y: full.end.y + CGFloat(index % 3) * 0.002)
        }
        let dragEvents = try points.map { try event(.leftMouseDragged, at: $0, in: view, page: page) }
        var changedSelectionIdentity = 0
        let controllerStarted = ProcessInfo.processInfo.systemUptime
        for dragEvent in dragEvents {
            view.mouseDragged(with: dragEvent)
            if workspace.currentSelection !== stableSelection { changedSelectionIdentity += 1 }
        }
        let controllerSeconds = ProcessInfo.processInfo.systemUptime - controllerStarted
        XCTAssertEqual(changedSelectionIdentity, 0,
                       "Sub-character pointer motion must not allocate/publish a new selection.")
        XCTAssertEqual((workspace.currentSelection as? PDFRegionTextSelection)?.fragments, fullFragments)
        XCTAssertEqual(normalized(workspace.currentSelection?.string), normalized(expected.joined(separator: " ")))
        let finalEvent = try event(.leftMouseUp, at: full.end, in: view, page: page)
        let flushStarted = ProcessInfo.processInfo.systemUptime
        view.mouseUp(with: finalEvent)
        let flushSeconds = ProcessInfo.processInfo.systemUptime - flushStarted
        XCTAssertTrue(workspace.currentSelection === stableSelection,
                      "Committing sub-character movement must preserve selection identity.")
        XCTAssertEqual((workspace.currentSelection as? PDFRegionTextSelection)?.fragments, fullFragments)

        // The original native selection is a timing baseline only: its text
        // order includes the incorrect figure labels asserted absent above.
        var nativeLineCount = 0
        let sourceStarted = ProcessInfo.processInfo.systemUptime
        for point in points {
            nativeLineCount += autoreleasepool {
                page.selection(from: full.start, to: point)?.selectionsByLine().count ?? 0
            }
        }
        let sourceSeconds = ProcessInfo.processInfo.systemUptime - sourceStarted
        XCTAssertGreaterThan(nativeLineCount, 0)
        let benchmark: [String: Any] = [
            "schemaVersion": 2,
            "iterations": iterationCount,
            "controllerSynchronousPointerUpdatesSeconds": controllerSeconds,
            "controllerFinalCommitSeconds": flushSeconds,
            "sourceNativeSelectionAndLineSplittingSeconds": sourceSeconds,
            "selectionIdentityChanges": changedSelectionIdentity,
            "includesFrameDrawing": false,
            "controllerMayDeferIntermediateEvents": false,
            "sourceNativeIsCorrectnessReference": false
        ]
        print("EMBER_SELECTION_DRAG_BENCHMARK iterations=\(iterationCount) controller_synchronous_pointer_updates_seconds=\(controllerSeconds) controller_final_commit_seconds=\(flushSeconds) source_native_selection_and_lines_seconds=\(sourceSeconds) identity_changes=\(changedSelectionIdentity)")

        if let diagnostics = environment["EMBER_SELECTION_TEST_DIAGNOSTICS"], diagnostics.hasPrefix("/") {
            let directory = URL(fileURLWithPath: diagnostics, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let snapshot = try PDFRegionTextRecognizer.snapshot(page: page, region: page.bounds(for: .cropBox))
            try writeDiagnostic(snapshot: snapshot, fragments: fullFragments,
                                to: directory.appendingPathComponent("magnetic-paragraph-selection.png"))
            try writeDiagnostic(snapshot: snapshot, fragments: partialFragments,
                                to: directory.appendingPathComponent("magnetic-partial-selection.png"))
            try writeDiagnostic(snapshot: snapshot, fragments: fiveLineFragments,
                                to: directory.appendingPathComponent("magnetic-five-line-selection.png"))
            try JSONSerialization.data(withJSONObject: benchmark, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("magnetic-drag-benchmark.json"), options: .atomic)
        }
        XCTAssertEqual(page.string, originalText)
        XCTAssertEqual(page.annotations.count, annotationCount)
        XCTAssertEqual(document.pageCount, pageCount)
        XCTAssertEqual(workspace.revision, revision)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertEqual(try PDFSourceFileVersion.capture(at: sourceURL), originalVersion)
    }

    private func normalized(_ text: String?) -> String {
        (text ?? "").precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @MainActor
    func testKatzContentsSelectionStaysInDraggedColumnAndCachesVisibleGeometry() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["EMBER_SELECTION_TEST_PDF"], path.hasPrefix("/") else {
            throw XCTSkip("Real PDF selection coverage is opt-in via EMBER_SELECTION_TEST_PDF.")
        }
        let sourceURL = URL(fileURLWithPath: path)
        let originalVersion = try PDFSourceFileVersion.capture(at: sourceURL)
        _ = NSApplication.shared
        let workspace = PDFWorkspaceState(pdfWriter: { _, _, _ in throw Failure.unexpectedWrite })
        XCTAssertTrue(workspace.open(url: sourceURL))
        let document = try XCTUnwrap(workspace.document)
        let page = try XCTUnwrap(document.page(at: 11), "The Katz contents fixture uses zero-based page 11.")
        let originalText = page.string
        let originalAnnotations = page.annotations.count
        let originalPageCount = document.pageCount
        let originalRevision = workspace.revision
        let snapshot = try PDFRegionTextRecognizer.snapshot(page: page, region: page.bounds(for: .cropBox))
        let lines = try await PDFRegionTextRecognizer.recognizeLines(snapshot)
        if let diagnostics = environment["EMBER_SELECTION_TEST_DIAGNOSTICS"], diagnostics.hasPrefix("/") {
            try FileManager.default.createDirectory(atPath: diagnostics, withIntermediateDirectories: true)
            try lines.map(\.text).joined(separator: "\n").write(
                to: URL(fileURLWithPath: diagnostics).appendingPathComponent("recognized-lines.txt"),
                atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(PDFTextSelectionGeometry.needsRegionSelection(on: page))

        let right = try drag(from: "Real Gases", through: "Evaporation", lines: lines, snapshot: snapshot)
        let left = try drag(from: "The Doppler Shift", through: "Standing Waves", lines: lines, snapshot: snapshot)
        let rightFragments = right.fragments(from: lines, imageToPage: snapshot.imageToPage)
        let leftFragments = left.fragments(from: lines, imageToPage: snapshot.imageToPage)
        let proxy = PDFNativeSelectionProxy.makePage(for: page)
        XCTAssertNotNil(proxy, "The malformed form must preserve native source text through a selection-only repair.")
        func expectedFragments(for gesture: PDFVisualTextDrag) -> [PDFRegionTextFragment] {
            guard let proxy else { return gesture.fragments(from: lines, imageToPage: snapshot.imageToPage) }
            return proxy.page.selection(from: gesture.start, to: gesture.end)?.selectionsByLine().compactMap {
                guard let text = $0.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return PDFRegionTextFragment(text: text, bounds: $0.bounds(for: proxy.page))
            } ?? []
        }
        let expectedRight = expectedFragments(for: right)
        let expectedLeft = expectedFragments(for: left)
        // PDFKit emits duplicated control-only fragments and pads some TOC
        // lines with spaces/U+0007. Compare the visible source text, preserving
        // every other character, and independently verify source geometry.
        func visibleText(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{0007}", with: "")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        func assertVisibleSource(_ actual: [PDFRegionTextFragment], source: [PDFRegionTextFragment]) {
            XCTAssertEqual(visibleText(actual.map(\.text).joined(separator: " ")),
                           visibleText(source.map(\.text).joined(separator: " ")))
            for fragment in actual {
                let reference = source.first { visibleText($0.text) == visibleText(fragment.text) }
                XCTAssertNotNil(reference, "Each selected line must match visible native source text.")
                if let reference {
                    XCTAssertTrue(reference.bounds.insetBy(dx: -0.01, dy: -0.01).contains(fragment.bounds),
                                  "Clipped glyph bounds must remain within their native source line.")
                }
            }
        }
        XCTAssertTrue(expectedRight.map(\.text).joined(separator: " ").contains("Equations of State"))
        XCTAssertTrue(expectedRight.map(\.text).joined(separator: " ").contains("20-7 Phase Changes"))
        // The printed columns are not centered in the paper crop. Measure the
        // real gutter using a long left entry and a right section label.
        let rightLabel = try XCTUnwrap(lines.first { $0.text.contains("Phase Changes") }).bounds
        let leftEntry = try imageBounds(of: "Dimensional Interference", lines: lines)
        let glyphs: [CGRect] = lines.flatMap(\.characterBounds).compactMap { $0 }
        let leftRowGlyphs = glyphs.filter { box in
            let overlap = min(box.maxY, leftEntry.maxY) - max(box.minY, leftEntry.minY)
            return box.maxX < rightLabel.minX && overlap > min(box.height, leftEntry.height) * 0.35
        }
        let leftRowRight = try XCTUnwrap(leftRowGlyphs.map(\.maxX).max())
        let columnBoundary = (leftRowRight + rightLabel.minX) / 2
        assertColumn(rightFragments, isRight: true, columnBoundary: columnBoundary, snapshot: snapshot)
        assertColumn(leftFragments, isRight: false, columnBoundary: columnBoundary, snapshot: snapshot)
        assertColumn(expectedRight, isRight: true, columnBoundary: columnBoundary, snapshot: snapshot)
        assertColumn(expectedLeft, isRight: false, columnBoundary: columnBoundary, snapshot: snapshot)
        XCTAssertTrue(rightFragments.map(\.text).joined(separator: " ").contains("Real Gases"))
        XCTAssertTrue(rightFragments.map(\.text).joined(separator: " ").contains("Evaporation"))
        XCTAssertTrue(leftFragments.map(\.text).joined(separator: " ").contains("Doppler"))
        XCTAssertTrue(leftFragments.map(\.text).joined(separator: " ").contains("Standing Waves"))
        for (gesture, fragments) in [(right, rightFragments), (left, leftFragments)] {
            XCTAssertEqual(PDFVisualTextDrag(start: gesture.end, end: gesture.start)
                .fragments(from: lines, imageToPage: snapshot.imageToPage), fragments)
        }
        if let diagnostics = environment["EMBER_SELECTION_TEST_DIAGNOSTICS"], diagnostics.hasPrefix("/") {
            let directory = URL(fileURLWithPath: diagnostics, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeDiagnostic(snapshot: snapshot, fragments: rightFragments,
                                to: directory.appendingPathComponent("right-column-selection.png"))
            try writeDiagnostic(snapshot: snapshot, fragments: leftFragments,
                                to: directory.appendingPathComponent("left-column-selection.png"))
        }

        workspace.setCurrentPage(11)
        workspace.setMode(.viewer)
        workspace.activeTool = .select
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 1_100))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            view.regionSelection.cancel()
            view.prepareInlineTextEditingOverlayForRemoval()
            view.prepareAnnotationEditingOverlayForRemoval()
            view.workspaceState = nil
            view.document = nil
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
            workspace.closeDiscardingChanges()
        }
        view.displayBox = .cropBox
        view.displayMode = .singlePage
        view.autoScales = false
        view.scaleFactor = min(850 / page.bounds(for: .cropBox).width, 1_050 / page.bounds(for: .cropBox).height)
        view.document = document
        view.go(to: page)
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        view.configure(with: workspace)
        view.regionSelection.synchronize()
        XCTAssertTrue(view.visiblePages.contains { $0 === page })

        // Repairable forms select immediately; otherwise wait for on-device OCR.
        try begin(right, in: view, page: page)
        XCTAssertTrue(view.regionSelection.isDragging)
        XCTAssertNotNil(workspace.currentSelection, "The repaired source should select during the first drag.")
        view.mouseUp(with: try event(.leftMouseUp, at: right.end, in: view, page: page))
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while workspace.currentSelection == nil && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let firstSelection = try XCTUnwrap(workspace.currentSelection as? PDFRegionTextSelection)
        assertVisibleSource(firstSelection.fragments, source: expectedRight)
        assertColumn(firstSelection.fragments, isRight: true, columnBoundary: columnBoundary, snapshot: snapshot)
        XCTAssertFalse(view.regionSelection.isDragging)
        XCTAssertTrue(firstSelection.pages.first === page)

        // A second drag must publish before mouse-up and before any async yield.
        // This proves that pointer updates use the cached full-page geometry.
        try begin(left, in: view, page: page)
        let cachedSelection = try XCTUnwrap(workspace.currentSelection as? PDFRegionTextSelection)
        assertVisibleSource(cachedSelection.fragments, source: expectedLeft)
        assertColumn(cachedSelection.fragments, isRight: false, columnBoundary: columnBoundary, snapshot: snapshot)
        view.mouseUp(with: try event(.leftMouseUp, at: left.end, in: view, page: page))
        XCTAssertEqual((workspace.currentSelection as? PDFRegionTextSelection)?.fragments, cachedSelection.fragments)

        if let diagnostics = environment["EMBER_SELECTION_TEST_DIAGNOSTICS"], diagnostics.hasPrefix("/") {
            let directory = URL(fileURLWithPath: diagnostics, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeDiagnostic(snapshot: snapshot, fragments: firstSelection.fragments,
                                to: directory.appendingPathComponent("right-controller-selection.png"))
            try writeDiagnostic(snapshot: snapshot, fragments: cachedSelection.fragments,
                                to: directory.appendingPathComponent("left-controller-selection.png"))
        }

        // Escape removes a visible cached selection without changing the file.
        view.keyDown(with: try escape(in: view))
        XCTAssertNil(workspace.currentSelection)
        XCTAssertFalse(view.regionSelection.isActive)
        XCTAssertEqual(workspace.revision, originalRevision)
        XCTAssertFalse(workspace.isDirty)

        // A harmless localization refresh rotates the revision without editing
        // the PDF. It clears the cache and invalidates pending recognition.
        workspace.refreshLocalization()
        view.regionSelection.synchronize()
        try begin(right, in: view, page: page)
        view.mouseUp(with: try event(.leftMouseUp, at: right.end, in: view, page: page))
        if proxy == nil { XCTAssertNil(workspace.currentSelection) }
        workspace.refreshLocalization()
        view.regionSelection.synchronize()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(workspace.currentSelection)
        XCTAssertFalse(view.regionSelection.isActive)

        // Escape also cancels a cold request, including a later mouse-up.
        try begin(right, in: view, page: page)
        view.keyDown(with: try escape(in: view))
        view.mouseUp(with: try event(.leftMouseUp, at: right.end, in: view, page: page))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(workspace.currentSelection)
        XCTAssertFalse(view.regionSelection.isActive)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(document.pageCount, originalPageCount)
        XCTAssertEqual(page.string, originalText)
        XCTAssertEqual(page.annotations.count, originalAnnotations)
        XCTAssertEqual(try PDFSourceFileVersion.capture(at: sourceURL), originalVersion)
    }

    private func drag(from firstPhrase: String, through lastPhrase: String,
                      lines: [PDFVisualTextLine], snapshot: PDFRegionTextSnapshot) throws -> PDFVisualTextDrag {
        func point(for phrase: String, leading: Bool) throws -> CGPoint {
            let line = try XCTUnwrap(lines.first { $0.text.localizedCaseInsensitiveContains(phrase) },
                                     "Expected the supplied Katz contents fixture to include \(phrase).")
            let range = try XCTUnwrap(line.text.range(of: phrase, options: .caseInsensitive))
            let first = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
            let last = line.text.distance(from: line.text.startIndex, to: range.upperBound) - 1
            let bounds = try XCTUnwrap(line.characterBounds[leading ? first : last])
            return CGPoint(x: leading ? bounds.minX + 0.1 : bounds.maxX - 0.1, y: bounds.midY)
                .applying(snapshot.imageToPage)
        }
        return try PDFVisualTextDrag(start: point(for: firstPhrase, leading: true),
                                     end: point(for: lastPhrase, leading: false))
    }

    private func assertColumn(_ fragments: [PDFRegionTextFragment], isRight: Bool,
                              columnBoundary: CGFloat, snapshot: PDFRegionTextSnapshot,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(fragments.isEmpty, file: file, line: line)
        for fragment in fragments {
            let pixels = fragment.bounds.applying(snapshot.imageToPage.inverted())
            if isRight {
                XCTAssertGreaterThan(pixels.minX, columnBoundary, file: file, line: line)
            } else {
                XCTAssertLessThan(pixels.maxX, columnBoundary, file: file, line: line)
            }
            XCTAssertGreaterThan(pixels.height, 0, file: file, line: line)
            XCTAssertLessThan(pixels.height, CGFloat(snapshot.image.height) * 0.05, file: file, line: line)
        }
    }

    private func imageBounds(of phrase: String, lines: [PDFVisualTextLine]) throws -> CGRect {
        let line = try XCTUnwrap(lines.first { $0.text.localizedCaseInsensitiveContains(phrase) },
                                 "Missing OCR landmark: \(phrase)")
        let range = try XCTUnwrap(line.text.range(of: phrase, options: .caseInsensitive))
        let start = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
        let end = line.text.distance(from: line.text.startIndex, to: range.upperBound)
        return line.characterBounds[start..<end].compactMap { $0 }.reduce(CGRect.null) { $0.union($1) }
    }

    @MainActor
    private func begin(_ drag: PDFVisualTextDrag, in view: InteractivePDFView, page: PDFPage) throws {
        view.mouseDown(with: try event(.leftMouseDown, at: drag.start, in: view, page: page))
        view.mouseDragged(with: try event(.leftMouseDragged, at: drag.end, in: view, page: page))
    }

    @MainActor
    private func event(_ type: NSEvent.EventType, at point: CGPoint,
                       in view: InteractivePDFView, page: PDFPage) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type,
            location: view.convert(view.convert(point, from: page), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @MainActor
    private func escape(in view: InteractivePDFView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }

    private func writeDiagnostic(snapshot: PDFRegionTextSnapshot, fragments: [PDFRegionTextFragment],
                                 to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: snapshot.image.width, height: snapshot.image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(snapshot.image, in: CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height))
        context.setFillColor(CGColor(red: 0.15, green: 0.5, blue: 0.95, alpha: 0.3))
        for fragment in fragments { context.fill(fragment.bounds.applying(snapshot.imageToPage.inverted())) }
        let image = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)
    }
}
