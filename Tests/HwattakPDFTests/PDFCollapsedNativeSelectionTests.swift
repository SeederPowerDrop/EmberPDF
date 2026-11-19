// SPDX-License-Identifier: MPL-2.0

import AppKit
import CryptoKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFCollapsedNativeSelectionTests: XCTestCase {
    func testNativeUnicodeAndRepeatedPhrasesStayAtTheirOwnGeometry() throws {
        let page = CollapsedSelectionPage(rows: [("Native 大뼈樓 text.", 380), ("Native 大뼈樓 text.", 320)])
        let source = page.string
        let native = try XCTUnwrap(PDFNativeTextLayout.makeCollapsedLayout(for: page))
        let layout = PDFVisualTextLayout(lines: native.lines, imageToPage: .identity)
        let drag = PDFVisualTextDrag(start: CGPoint(x: 40, y: 325), end: CGPoint(x: 230, y: 325))
        XCTAssertTrue(native.supports(drag))
        let selected = layout.fragments(for: drag)
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.text, "Native 大뼈樓 text.")
        XCTAssertEqual(selected.first?.bounds.minY, 320)
        XCTAssertEqual(selected, layout.fragments(for: .init(start: drag.end, end: drag.start)))
        XCTAssertFalse(native.supports(.init(start: CGPoint(x: 400, y: 40), end: drag.end)))
        XCTAssertEqual(page.string, source)
    }

    func testOverlappingIndependentNativeRangesDoNotChooseAnArbitraryOccurrence() {
        let page = CollapsedSelectionPage(rows: [("Native 大뼈樓 text.", 380), ("Native 大뼈樓 text.", 380)])
        XCTAssertNil(PDFNativeTextLayout.makeCollapsedLayout(for: page))
    }

    func testMalformedUnrelatedCellIsExcludedAndCannotBeCrossedByNativeDrag() throws {
        let page = CollapsedSelectionPage(rows: [("Native 大뼈樓 text.", 380), ("Bad caption", 180)], badLastRow: true)
        let native = try XCTUnwrap(PDFNativeTextLayout.makeCollapsedLayout(for: page))
        XCTAssertEqual(native.lines.count, 1)
        XCTAssertEqual(native.excludedBounds.count, 1)
        XCTAssertTrue(native.supports(.init(start: CGPoint(x: 40, y: 385), end: CGPoint(x: 230, y: 385))))
        XCTAssertFalse(native.supports(.init(start: CGPoint(x: 40, y: 385), end: CGPoint(x: 320, y: 185))))
    }

    func testMissingNativeGlyphExcludesWholeLineInsteadOfReturningPartialUnicode() throws {
        let page = CollapsedSelectionPage(rows: [("Native 大뼈樓 text.", 380), ("Unrelated row", 320)], omittedGlyph: 8)
        let native = try XCTUnwrap(PDFNativeTextLayout.makeCollapsedLayout(for: page))
        XCTAssertEqual(native.lines.map(\.text), ["Unrelated row"])
        XCTAssertEqual(native.excludedBounds.count, 1)
        XCTAssertFalse(native.supports(.init(start: CGPoint(x: 40, y: 385), end: CGPoint(x: 230, y: 385))))
        XCTAssertTrue(native.supports(.init(start: CGPoint(x: 40, y: 325), end: CGPoint(x: 160, y: 325))))
    }

    func testPointerRouteUsesNativeUnicodeSynchronouslyWithoutVisionOrDocumentMutation() throws {
        _ = NSApplication.shared
        let state = PDFWorkspaceState()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("blank.pdf")
        let blank = PDFDocument()
        let blankPage = PDFPage()
        blankPage.setBounds(CGRect(x: 0, y: 0, width: 400, height: 500), for: .mediaBox)
        blank.insert(blankPage, at: 0)
        XCTAssertTrue(blank.write(to: url))
        XCTAssertTrue(state.open(url: url))
        let document = try XCTUnwrap(state.document)
        let page = CollapsedSelectionPage(rows: [("Native 大뼈樓 text.", 380), ("Unrelated row", 320)])
        document.removePage(at: 0)
        document.insert(page, at: 0)
        state.setMode(.editing)
        state.activeTool = .select
        let revision = state.revision
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        let window = host(view, document: document, page: page, state: state, scale: 1)
        defer { detach(view, window: window, state: state) }
        XCTAssertTrue(PDFTextSelectionGeometry.needsRegionSelection(on: page))
        try drag(.init(start: CGPoint(x: 40, y: 385), end: CGPoint(x: 230, y: 385)), in: view, page: page, window: window)
        let selection = try XCTUnwrap(state.currentSelection as? PDFRegionTextSelection)
        XCTAssertEqual(selection.string, "Native 大뼈樓 text.")
        XCTAssertNil(view.currentSelection)
        XCTAssertFalse(view.regionSelection.isDragging)
        XCTAssertEqual(state.revision, revision)
        XCTAssertFalse(state.isDirty)
        XCTAssertFalse(state.canUndo)
        XCTAssertNil(state.pendingInlineTextEdit)
        XCTAssertEqual(page.annotations.count, 0)
    }

    /// The original remains outside the repository and is only read. Supply
    /// the one-page Probability fixture (or the original book's page21).
    func testNewtonHanjaFullLinePointerAndTextButtonUseExactNativeUnicode() async throws {
        guard let path = ProcessInfo.processInfo.environment["EMBER_NEWTON_PROBABILITY_PDF"], path.hasPrefix("/") else {
            throw XCTSkip("Set EMBER_NEWTON_PROBABILITY_PDF for the supplied Newton Hanzi page.")
        }
        _ = NSApplication.shared
        let source = URL(fileURLWithPath: path)
        let hash = SHA256.hash(data: try Data(contentsOf: source, options: .mappedIfSafe))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("Newton-Hanja-copy.pdf")
        try FileManager.default.copyItem(at: source, to: copy)
        let state = PDFWorkspaceState()
        XCTAssertTrue(state.open(url: copy))
        state.setMode(.editing)
        state.activeTool = .select
        let document = try XCTUnwrap(state.document)
        let index = document.pageCount == 1 ? 0 : 20
        state.setCurrentPage(index)
        let page = try XCTUnwrap(document.page(at: index))
        let originalText = page.string
        let snapshot = try PDFBodyTextPageSnapshot.data(for: page)
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 1_000))
        let window = host(view, document: document, page: page, state: state, scale: 0.5)
        let coordinator = PDFKitViewer.Coordinator(state: state, viewportContext: .normal)
        coordinator.attach(to: view)
        defer { coordinator.detach(); detach(view, window: window, state: state) }
        let gesture = PDFVisualTextDrag(start: CGPoint(x: 98, y: 1332), end: CGPoint(x: 579, y: 1321))
        try drag(gesture, in: view, page: page, window: window)
        let selection = try XCTUnwrap(state.currentSelection as? PDFRegionTextSelection,
                                      "Native cells must complete synchronously, without Vision.")
        XCTAssertEqual(selection.string, "일본의 씨름 대회인 오스모(大뼈樓)에서는 마지막 날에 두 사람")
        XCTAssertTrue(selection.pages.first === page)
        XCTAssertNil(view.currentSelection)
        state.selectTool(.text)
        view.configure(with: state)
        view.revealPendingBodyTextSelection()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let draft = try XCTUnwrap(state.pendingInlineTextEdit)
        XCTAssertEqual(draft.purpose, .bodyText)
        XCTAssertTrue(draft.text.contains("(大뼈樓)"))
        let selected = (draft.text as NSString).substring(with: try XCTUnwrap(draft.initialSelectedRange))
        XCTAssertEqual(selected.filter { !$0.isWhitespace }, (selection.string ?? "").filter { !$0.isWhitespace })
        XCTAssertNil(state.presentedError)
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(page.string, originalText)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), snapshot)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: source, options: .mappedIfSafe)), hash)
    }

    private func host(_ view: InteractivePDFView, document: PDFDocument, page: PDFPage,
                      state: PDFWorkspaceState, scale: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.displayBox = .cropBox
        view.displayMode = .singlePage
        view.autoScales = false
        view.scaleFactor = scale
        view.document = document
        view.go(to: page)
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        view.configure(with: state)
        view.regionSelection.synchronize()
        return window
    }

    private func detach(_ view: InteractivePDFView, window: NSWindow, state: PDFWorkspaceState) {
        state.cancelPendingInlineText()
        view.regionSelection.cancel()
        view.prepareInlineTextEditingOverlayForRemoval()
        view.prepareAnnotationEditingOverlayForRemoval()
        view.workspaceState = nil
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
        state.closeDiscardingChanges()
    }

    private func drag(_ gesture: PDFVisualTextDrag, in view: InteractivePDFView, page: PDFPage, window: NSWindow) throws {
        for (type, point) in [(NSEvent.EventType.leftMouseDown, gesture.start), (.leftMouseDragged, gesture.end), (.leftMouseUp, gesture.end)] {
            let location = view.convert(view.convert(point, from: page), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
    }
}

private final class CollapsedSelectionPage: PDFPage {
    private let sourceRows: [(String, CGFloat)]
    private let badLastRow: Bool
    private let omittedGlyph: Int?
    private var glyphs: [(text: String, range: NSRange, bounds: CGRect)] = []
    private var ranges: [NSRange] = []

    init(rows: [(String, CGFloat)], badLastRow: Bool = false, omittedGlyph: Int? = nil) {
        sourceRows = rows
        self.badLastRow = badLastRow
        self.omittedGlyph = omittedGlyph
        super.init()
        setBounds(CGRect(x: 0, y: 0, width: 400, height: 500), for: .mediaBox)
        var offset = 0
        for (row, entry) in rows.enumerated() {
            let start = offset
            for (column, character) in entry.0.enumerated() {
                let value = String(character), length = value.utf16.count
                let origin: CGFloat = badLastRow && row == rows.count - 1 ? 280 : 40
                let box = CGRect(x: origin + CGFloat(column) * 10, y: entry.1, width: 10,
                                 height: badLastRow && row == rows.count - 1 ? 300 : 20)
                glyphs.append((value, NSRange(location: offset, length: length), box))
                offset += length
            }
            ranges.append(NSRange(location: start, length: offset - start))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var numberOfCharacters: Int { glyphs.reduce(0) { $0 + $1.range.length } }
    override var string: String? { sourceRows.map(\.0).joined(separator: "\n") }
    override func characterBounds(at index: Int) -> CGRect {
        guard let glyph = glyphs.first(where: { NSLocationInRange(index, $0.range) }) else { return .zero }
        return CGRect(x: glyph.bounds.minX, y: glyph.bounds.minY, width: glyph.bounds.width, height: 0)
    }
    override func selection(for range: NSRange) -> PDFSelection? {
        if range.location == 0, range.length == numberOfCharacters {
            let lines = ranges.map { rowRange -> CollapsedSelectionRange in
                let selected = glyphs.filter { NSLocationInRange($0.range.location, rowRange) }
                return CollapsedSelectionRange(text: selected.map(\.text).joined(), range: rowRange,
                    bounds: selected.reduce(CGRect.null) { $0.union($1.bounds) })
            }
            return CollapsedSelectionRange(text: string ?? "", range: range,
                bounds: lines.reduce(CGRect.null) { $0.union($1.bounds(for: self)) }, lines: lines)
        }
        if range.location == omittedGlyph { return nil }
        guard let glyph = glyphs.first(where: { NSLocationInRange(range.location, $0.range) }) else { return nil }
        return CollapsedSelectionRange(text: glyph.text, range: glyph.range, bounds: glyph.bounds)
    }
}

private final class CollapsedSelectionRange: PDFSelection {
    let value: String
    let selectedRange: NSRange
    let rectangle: CGRect
    let lines: [PDFSelection]?
    init(text: String, range: NSRange, bounds: CGRect, lines: [PDFSelection]? = nil) {
        value = text; selectedRange = range; rectangle = bounds; self.lines = lines
        super.init(document: PDFDocument())
    }
    override var string: String? { value }
    override func bounds(for page: PDFPage) -> CGRect { rectangle }
    override func selectionsByLine() -> [PDFSelection] { lines ?? [self] }
    override func numberOfTextRanges(on page: PDFPage) -> Int { 1 }
    override func range(at index: Int, on page: PDFPage) -> NSRange { selectedRange }
}
