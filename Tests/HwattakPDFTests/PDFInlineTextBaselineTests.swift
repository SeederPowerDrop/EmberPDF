// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFInlineTextBaselineTests: XCTestCase {
    func testRealBodyDraftOverlayKeepsPDFBaselineAndMultilineWrappingAtBothZooms() throws {
        _ = NSApplication.shared
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 400)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)),
                                              mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = try XCTUnwrap(NSFont(name: "Times-Roman", size: 9.9626))
        for (text, y) in [("Original first line", 240.0), ("Original second line", 226.0)] {
            context.textPosition = CGPoint(x: 90, y: y)
            // Keep this baseline/wrapping fixture free of semantic ActualText
            // wrappers that Quartz otherwise emits for the "fi" ligature.
            // Unsupported semantic replacements have separate safety tests.
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [.font: font, .ligature: 0])), context)
        }
        context.endPDFPage()
        context.closePDF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-\(UUID().uuidString).pdf")
        try (data as Data).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let displayAndZoomScales: [(CGFloat, CGFloat)] = [(1, 1), (1, 2), (2, 1), (2, 2)]
        for (backingScale, scale) in displayAndZoomScales {
            let state = PDFWorkspaceState()
            XCTAssertTrue(state.open(url: url))
            state.setMode(.editing)
            let page = try XCTUnwrap(state.document?.page(at: 0))
            let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 1400, height: 900))
            let window = BaselineTestWindow(contentRect: view.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.testBackingScale = backingScale
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer {
                state.cancelPendingInlineText()
                view.prepareInlineTextEditingOverlayForRemoval()
                view.prepareAnnotationEditingOverlayForRemoval()
                view.workspaceState = nil
                window.makeFirstResponder(nil)
                window.contentView = nil
                window.close()
            }
            view.document = state.document
            view.displayMode = .singlePage
            view.autoScales = false
            view.scaleFactor = scale
            view.configure(with: state)
            view.go(to: page)
            view.layoutDocumentView()
            view.layoutSubtreeIfNeeded()
            let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0,
                length: try XCTUnwrap(page.string).utf16.count)))
            XCTAssertTrue(state.requestBodyTextEdit(selection: selection))
            view.configureInlineTextEditingOverlay()
            view.layoutSubtreeIfNeeded()
            let draft = try XCTUnwrap(state.pendingInlineTextEdit)
            let originalBaseline = try XCTUnwrap(draft.bodyTextBaseline)
            XCTAssertNotNil(draft.bodyTextLineHeight)
            let panel = try XCTUnwrap(descendant(PDFInlineTextEditorPanel.self, in: view))
            let container = try XCTUnwrap(panel.textView.textContainer)
            let baseline = try XCTUnwrap(panel.firstTextBaseline(in: view))
            let expected = view.convert(originalBaseline, from: page)
            XCTAssertEqual(baseline.y, expected.y, accuracy: 0.1)
            let alignedFrame = panel.textScrollView.frame
            for _ in 0..<3 {
                panel.alignBodyTextBaseline(to: expected.y, in: view)
                XCTAssertEqual(try XCTUnwrap(panel.firstTextBaseline(in: view)).y, expected.y, accuracy: 0.1)
                XCTAssertEqual(panel.textScrollView.frame, alignedFrame,
                    "Repeated alignment must not move an already anchored canvas.")
            }
            // The last glyph's advance extends beyond its painted bounds.
            // The editor must keep enough width for the original complete line.
            let longestOriginalLine = CTLineCreateWithAttributedString(NSAttributedString(
                string: "Original second line", attributes: [.font: font, .ligature: 0]))
            let originalAdvance = CGFloat(CTLineGetTypographicBounds(longestOriginalLine, nil, nil, nil))
            let expectedWidth = max(draft.bounds.width, originalAdvance) + 1
            XCTAssertEqual(container.containerSize.width, expectedWidth * scale, accuracy: 0.1)

            // Resizing the viewport must clip the page and editor consistently,
            // rather than silently choosing a new wrap width for the draft.
            view.frame.size.width = 450
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(container.containerSize.width, expectedWidth * scale, accuracy: 0.1)
        }
    }

    func testBodyPreviewUsesActualTextKitBaselineAtNormalAndDoubleZoom() throws {
        for scale: CGFloat in [1, 2] {
            let host = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
            let panel = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 114))
            host.addSubview(panel)
            panel.setBodyPresentation(in: host)
            let style = InlineTextStyle(fontName: "Times-Roman", fontSize: 9.9626,
                textColor: .black, backgroundColor: .clear, alignment: .left)
            let baselineY: CGFloat = 380
            panel.configure(with: PendingInlineTextEdit(pageIndex: 0, bounds: .zero,
                isEditingExistingAnnotation: false, purpose: .bodyText,
                text: "Another example of native text", style: style,
                bodyTextBaseline: CGPoint(x: 120, y: baselineY)))
            panel.setTextPresentationScale(scale)
            let height: CGFloat = 100
            panel.textScrollView.frame = CGRect(x: 113,
                y: baselineY + style.font.ascender * scale + 7 - height,
                width: 600, height: height)
            let previousBaseline = try XCTUnwrap(panel.firstTextBaseline(in: host))
            XCTAssertGreaterThan(abs(previousBaseline.y - baselineY), 0.5,
                "This font exposes TextKit's extra baseline distance beyond the PDF font ascent.")

            panel.alignBodyTextBaseline(to: baselineY, in: host)

            XCTAssertEqual(try XCTUnwrap(panel.firstTextBaseline(in: host)).y, baselineY, accuracy: 0.01)
            XCTAssertEqual(panel.currentStyle, style, "Preview placement must not alter PDF text style.")
        }
    }

    func testChangingFontAndSizeKeepsPreviewOnOriginalPDFBaseline() throws {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let panel = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 114))
        host.addSubview(panel)
        panel.setBodyPresentation(in: host)
        let baselineY: CGFloat = 380
        for (name, size) in [("Times-Roman", 9.9626), ("Helvetica", 16.0), ("Times-Bold", 12.0)] {
            let style = InlineTextStyle(fontName: name, fontSize: size,
                textColor: .black, backgroundColor: .clear, alignment: .left)
            panel.configure(with: PendingInlineTextEdit(pageIndex: 0, bounds: .zero,
                isEditingExistingAnnotation: false, purpose: .bodyText,
                text: "Same line, new font", style: style,
                bodyTextBaseline: CGPoint(x: 120, y: baselineY)))
            panel.setTextPresentationScale(2)
            panel.textScrollView.frame = CGRect(x: 113, y: 300, width: 600, height: 100)

            panel.alignBodyTextBaseline(to: baselineY, in: host)

            XCTAssertEqual(try XCTUnwrap(panel.firstTextBaseline(in: host)).y, baselineY, accuracy: 0.01)
            XCTAssertEqual(panel.currentStyle, style)
        }
    }

    func testScrollingLongDraftDoesNotMoveAnchoredCanvas() throws {
        for backingScale: CGFloat in [1, 2] {
            let host = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
            let window = BaselineTestWindow(contentRect: host.frame, styleMask: .borderless,
                                            backing: .buffered, defer: false)
            window.testBackingScale = backingScale
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer {
                window.makeFirstResponder(nil)
                window.contentView = nil
                window.close()
            }
            let panel = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 114))
            host.addSubview(panel)
            panel.setBodyPresentation(in: host)
            let baselineY: CGFloat = 380.5
            let style = InlineTextStyle(fontName: "Times-Roman", fontSize: 12,
                textColor: .black, backgroundColor: .clear, alignment: .left)
            panel.configure(with: PendingInlineTextEdit(pageIndex: 0, bounds: .zero,
                isEditingExistingAnnotation: false, purpose: .bodyText,
                text: Array(repeating: "Long draft line", count: 60).joined(separator: "\n"), style: style,
                bodyTextBaseline: CGPoint(x: 120, y: baselineY)))
            panel.setBodyCanvasFrame(CGRect(x: 113, y: 300, width: 400, height: 120), textWidth: 380)
            panel.textView.sizeToFit()
            panel.alignBodyTextBaseline(to: baselineY, in: host)
            let anchoredFrame = panel.textScrollView.frame
            let originalVisibleBaseline = try XCTUnwrap(panel.firstTextBaseline(in: host)).y
            let clip = panel.textScrollView.contentView
            clip.scroll(to: CGPoint(x: 0, y: 120))
            panel.textScrollView.reflectScrolledClipView(clip)
            XCTAssertGreaterThan(clip.bounds.minY, 0)
            let scrolledVisibleBaseline = try XCTUnwrap(panel.firstTextBaseline(in: host)).y
            XCTAssertGreaterThan(abs(scrolledVisibleBaseline - originalVisibleBaseline), 100)

            panel.alignBodyTextBaseline(to: baselineY, in: host)

            XCTAssertEqual(panel.textScrollView.frame.origin.y, anchoredFrame.origin.y, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(panel.firstTextBaseline(in: host)).y, scrolledVisibleBaseline, accuracy: 0.01)
        }
    }

    func testBodyPreviewUsesTheSameWholeTextFallbackFontAsCommit() {
        let panel = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 246))
        let style = InlineTextStyle(fontName: "Times-Roman", fontSize: 12,
            textColor: .black, backgroundColor: .clear, alignment: .left)
        panel.configure(with: PendingInlineTextEdit(pageIndex: 0, bounds: .zero,
            isEditingExistingAnnotation: false, purpose: .bodyText, text: "English text", style: style))
        panel.setTextPresentationScale(2)
        panel.textView.string = "한글과 English text"
        panel.textDidChange(Notification(name: NSText.didChangeNotification, object: panel.textView))
        let committedFont = PDFBodyTextEditor.replacementFont(for: panel.currentText, preferred: style.font)

        XCTAssertEqual(panel.textView.font?.fontName, committedFont.fontName)
        XCTAssertEqual(panel.textView.font?.pointSize, 24)
        XCTAssertEqual(panel.currentStyle, style)
    }

    func testFreeTextPanelDoesNotUseBodyBaselineAlignment() {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let panel = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 246))
        host.addSubview(panel)
        panel.configure(with: PendingInlineTextEdit(pageIndex: 0, bounds: .zero,
            isEditingExistingAnnotation: false, purpose: .freeText,
            text: "Ordinary annotation", style: .standard(for: .freeText)))
        panel.layoutSubtreeIfNeeded()
        let originalFrame = panel.textScrollView.frame

        panel.alignBodyTextBaseline(to: 600, in: host)

        XCTAssertEqual(panel.textScrollView.frame, originalFrame)
    }

    private func descendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let found = root as? T { return found }
        return root.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }
}

// Exercise native clip tiling independently of the developer's display scale.
private final class BaselineTestWindow: NSWindow {
    var testBackingScale: CGFloat = 1
    override var backingScaleFactor: CGFloat { testBackingScale }
}
