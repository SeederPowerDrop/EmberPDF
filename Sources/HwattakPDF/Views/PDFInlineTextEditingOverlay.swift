// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

/// Shared plain-text editor used by both the on-page editor and the older
/// review/comment sheet.
///
/// The important part is *where* the length limit is applied. A SwiftUI
/// `onChange` handler runs only after TextKit has accepted and laid out pasted
/// content. A hostile PDF annotation or paste can therefore allocate a very
/// large text graph before the handler gets a chance to shorten it. This
/// AppKit boundary limits every insertion before calling `super.insertText`,
/// and routes Paste, Services, and text-drop imports through that same path.
@MainActor
class PDFBoundedPlainTextView: NSTextView {
    /// Default budget shared by both PDF FreeText editors. UTF-8 is already
    /// bounded indirectly by the grapheme and UTF-16 ceilings; `Int.max`
    /// preserves the existing 32K/1M policy while allowing another caller
    /// (such as the AI composer) to install a stricter three-axis budget.
    static let freeTextBudget = EncodedTextBudget(
        maximumCharacters: InlineTextDraftLimiter.maximumCharacterCount,
        maximumUTF8Bytes: Int.max,
        maximumUTF16CodeUnits: InlineTextDraftLimiter.maximumUTF16CodeUnitCount
    )

    var encodedTextBudget = PDFBoundedPlainTextView.freeTextBudget
    var onLengthLimitReached: (() -> Void)?
    /// Injectable only so headless XCTest can exercise the real
    /// `readSelection(from:type:)` override without depending on the macOS
    /// pasteboard XPC service. Production keeps the system-backed default.
    var plainTextPasteboardReader: (NSPasteboard) -> String? = {
        $0.string(forType: .string)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        // FreeText stores plain text. Advertising only that representation
        // also prevents a rich RTF/HTML attachment graph from bypassing the
        // bounded insertion path below.
        [.string]
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let replacement: String
        if let attributed = insertString as? NSAttributedString {
            replacement = attributed.string
        } else if let string = insertString as? String {
            replacement = string
        } else {
            replacement = String(describing: insertString)
        }

        // AppKit normally supplies a valid UTF-16 range. Clamp defensively so
        // drag-and-drop, Services, and input methods share the same safe path.
        let current = string as NSString
        // With NSNotFound, NSTextInputClient replaces the marked composition
        // before falling back to the selection. Using only the caret would
        // leave the unfinished Korean/Japanese/Chinese text in the document.
        let requested = replacementRange.location == NSNotFound
            ? (hasMarkedText() ? markedRange() : selectedRange())
            : replacementRange
        let location = min(max(0, requested.location), current.length)
        let length = min(max(0, requested.length), current.length - location)
        let safeRange = NSRange(location: location, length: length)
        let prefix = current.substring(with: NSRange(location: 0, length: location))
        let suffixStart = NSMaxRange(safeRange)
        let suffix = current.substring(
            with: NSRange(location: suffixStart, length: current.length - suffixStart)
        )
        let remainingCharacters = max(
            0,
            encodedTextBudget.maximumCharacters - prefix.count - suffix.count
        )
        let remainingUTF8 = max(
            0,
            encodedTextBudget.maximumUTF8Bytes
                - prefix.utf8.count
                - suffix.utf8.count
        )
        let remainingUTF16 = max(
            0,
            encodedTextBudget.maximumUTF16CodeUnits
                - prefix.utf16.count
                - suffix.utf16.count
        )
        let limited = EncodedTextLimiter.limit(
            replacement,
            budget: EncodedTextBudget(
                maximumCharacters: remainingCharacters,
                maximumUTF8Bytes: remainingUTF8,
                maximumUTF16CodeUnits: remainingUTF16
            )
        )

        // Crucially, only the bounded replacement reaches NSTextView. The
        // delegate's post-change limiter remains defense in depth, but a huge
        // paste can no longer trigger an equally huge TextKit layout first.
        super.insertText(limited.text, replacementRange: safeRange)
        if limited.wasTruncated {
            onLengthLimitReached?()
        }
    }

    override func readSelection(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        // Paste, Services, and text-drop operations may ask NSTextView to read
        // a pasteboard representation directly, without first calling
        // `insertText`. Calling `super` would let TextKit decode and lay out
        // a huge rich payload before the delegate can enforce the draft cap.
        //
        // Route the plain representation through our preflighted insertion.
        // Refuse every other type: the editor intentionally persists plain PDF
        // FreeText, so importing an unbounded object graph has no useful result.
        guard
            type == .string,
            let plainText = plainTextPasteboardReader(pasteboard)
        else {
            return false
        }
        insertText(plainText, replacementRange: rangeForUserTextChange)
        return true
    }
}

/// NSTextView subclass that gives the on-page editor predictable transaction
/// keys while preserving native selection, copy/paste, spelling, and undo.
/// The review sheet uses the bounded base class without these Return/Escape
/// transaction shortcuts because Return must remain an ordinary line break
/// in its larger multi-line editor.
@MainActor
final class PDFInlineTextView: PDFBoundedPlainTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var returnInsertsNewline = false
    // Preserve fractional PDF baselines after native viewport pixel alignment.
    var bodyTextBaselineOffset: CGFloat = 0 {
        didSet {
            guard bodyTextBaselineOffset != oldValue else { return }
            invalidateTextContainerOrigin()
            needsDisplay = true
        }
    }

    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: origin.x, y: origin.y + bodyTextBaselineOffset)
    }

    override func keyDown(with event: NSEvent) {
        if returnInsertsNewline, !event.modifierFlags.contains(.command),
           event.keyCode == 36 || event.keyCode == 76 {
            super.keyDown(with: event)
            return
        }
        // During Korean/Japanese/Chinese composition Return confirms a marked
        // syllable. Closing the editor at that moment would truncate input, so
        // AppKit must finish composition before Return becomes our commit key.
        switch InlineTextEditorKeyIntent.resolve(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            hasMarkedText: hasMarkedText()
        ) {
        case .cancel:
            onCancel?()
        case .commit:
            onCommit?()
        case .lineBreak, .passThrough:
            // Shift-Return is the documented escape hatch for a line break;
            // marked-text Return remains owned by the input method.
            super.keyDown(with: event)
        }
    }
}

/// A compact AppKit inspector attached to the selected PDF rectangle.
///
/// It intentionally uses an ordinary NSTextView rather than a custom canvas.
/// That preserves macOS text services, native copy/paste, VoiceOver, spelling,
/// input methods, and the responder-chain undo manager inside the draft.
@MainActor
final class PDFInlineTextEditorPanel: NSVisualEffectView, NSTextViewDelegate, NSLayoutManagerDelegate {
    var onDraftChanged: ((String, InlineTextStyle) -> Void)?
    var onLengthLimitReached: (() -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    private(set) var draftID: UUID?
    private(set) var purpose: InlineTextEditPurpose = .freeText
    let textView = PDFInlineTextView(frame: .zero)
    let textScrollView = NSScrollView(frame: .zero)
    private let rootStack = NSStackView()
    private var textScrollConstraints: [NSLayoutConstraint] = []
    private var usesBodyPresentation = false
    private var textPresentationScale: CGFloat = 1
    private var textHorizontalScale: CGFloat = 1
    private var bodyTextLineHeight: CGFloat?
    private var bodyTextFirstLineIndent: CGFloat = 0
    private var bodyTextSourceText: String?
    private var bodyTextSourceStyle: InlineTextStyle?
    private var bodyTextSourceRuns: [InlineTextSourceRun] = []
    private var bodyTextPreviewPaperColor: PDFTextColor?
    private let fontMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeField = NSTextField(frame: .zero)
    private let sizeStepper = NSStepper(frame: .zero)
    private let textColorWell = NSColorWell(frame: .zero)
    private let backgroundColorWell = NSColorWell(frame: .zero)
    private let transparentBackgroundButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let alignmentControl = NSSegmentedControl(frame: .zero)
    private let toolbarScrollView = NSScrollView(frame: .zero)
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let foregroundLabel = NSTextField(labelWithString: "")
    private let backgroundLabel = NSTextField(labelWithString: "")
    private let shortcutHint = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private let applyButton = NSButton(title: "", target: nil, action: nil)
    private var suppressCallbacks = false
    private var fontMenuConfigured = false
    private var languageObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildInterface()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildInterface()
    }

    deinit {
        // NotificationCenter owns its block token. Explicitly removing it
        // keeps repeated PDFView creation/destruction from accumulating idle
        // observers, even though the callback also captures this panel weakly.
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
    }

    func configure(with draft: PendingInlineTextEdit) {
        suppressCallbacks = true
        defer { suppressCallbacks = false }
        // Enumerating every installed font can be noticeable on systems with
        // large font libraries. Do it only when a person actually opens this
        // editor, not for every resident/viewer/comparison PDFView.
        if !fontMenuConfigured {
            configureFontMenu()
            fontMenuConfigured = true
        }
        draftID = draft.id
        purpose = draft.purpose
        bodyTextLineHeight = draft.bodyTextLineHeight
        bodyTextFirstLineIndent = draft.bodyTextFirstLineIndent
        bodyTextSourceText = draft.bodyTextSourceText
        bodyTextSourceStyle = draft.bodyTextSourceStyle
        bodyTextSourceRuns = draft.bodyTextSourceRuns
        bodyTextPreviewPaperColor = draft.bodyTextPreviewPaperColor
        configureBaselineLayout()
        textHorizontalScale = draft.style.horizontalScale
        textView.returnInsertsNewline = draft.purpose == .bodyText
        textView.string = draft.text
        selectFont(named: draft.style.fontName, sourceFont: draft.style.sourceFont)
        sizeField.doubleValue = Double(draft.style.fontSize)
        sizeStepper.doubleValue = Double(draft.style.fontSize)
        textColorWell.color = draft.style.textColor.nsColor
        backgroundColorWell.color = draft.style.backgroundColor.nsColor
        transparentBackgroundButton.state = draft.style.backgroundColor.alpha <= 0.001 ? .on : .off
        backgroundColorWell.isEnabled = transparentBackgroundButton.state == .off
        alignmentControl.selectedSegment = segment(for: draft.style.alignment)
        warningLabel.isHidden = usesBodyPresentation || draft.purpose == .freeText
        refreshPurposeHint()
        refreshShortcuts()
        applyPreview(style: draft.style)
        let length = textView.string.utf16.count
        let requested = draft.initialSelectedRange ?? NSRange(location: 0, length: 0)
        let location = requested.location == NSNotFound ? length : min(max(0, requested.location), length)
        textView.setSelectedRange(NSRange(location: location,
                                         length: min(max(0, requested.length), length - location)))
    }

    var currentText: String { textView.string }

    var currentStyle: InlineTextStyle {
        let requestedSourceFont = fontMenu.selectedItem?.representedObject as? PDFBodyTextDocumentFonts.Lease
        let requestedName = requestedSourceFont?.postScriptName ?? fontMenu.selectedItem?.representedObject as? String
            ?? NSFont.systemFont(ofSize: 15).fontName
        let background = transparentBackgroundButton.state == .on
            ? PDFTextColor.clear
            : PDFTextColor(backgroundColorWell.color)
        return InlineTextStyle(
            fontName: requestedName,
            fontSize: CGFloat(sizeField.doubleValue),
            textColor: PDFTextColor(textColorWell.color),
            backgroundColor: background,
            alignment: alignment(for: alignmentControl.selectedSegment),
            horizontalScale: textHorizontalScale, sourceFont: requestedSourceFont
        )
    }

    func focusText(at point: CGPoint? = nil) {
        textView.window?.makeFirstResponder(textView)
        if let point {
            let location = min(textView.string.utf16.count, textView.characterIndexForInsertion(at: point))
            textView.setSelectedRange(NSRange(location: location, length: 0))
        }
    }

    /// Body text shares the exact native editor and draft transaction, but its
    /// canvas sits over the PDF text while this panel becomes a small toolbar.
    func setBodyPresentation(in host: NSView?) {
        let requested = host != nil
        guard usesBodyPresentation != requested || (host != nil && textScrollView.superview !== host) else { return }
        usesBodyPresentation = requested
        textView.bodyTextBaselineOffset = 0
        textView.textContainer?.lineFragmentPadding = requested ? 0 : 5
        textScrollView.borderType = requested ? .noBorder : .bezelBorder
        NSLayoutConstraint.deactivate(textScrollConstraints)
        if rootStack.arrangedSubviews.contains(where: { $0 === textScrollView }) {
            rootStack.removeArrangedSubview(textScrollView)
        }
        textScrollView.removeFromSuperview()
        if let host {
            textScrollView.translatesAutoresizingMaskIntoConstraints = true
            host.addSubview(textScrollView)
        } else {
            textScrollView.translatesAutoresizingMaskIntoConstraints = false
            rootStack.insertArrangedSubview(textScrollView, at: 1)
            NSLayoutConstraint.activate(textScrollConstraints)
            textView.textContainer?.widthTracksTextView = true
            setTextPresentationScale(1)
        }
        warningLabel.isHidden = requested || purpose == .freeText
        shortcutHint.isHidden = requested
        refreshShortcuts()
    }

    func setTextPresentationScale(_ requested: CGFloat) {
        let scale = requested.isFinite ? min(64, max(0.05, requested)) : 1
        guard abs(scale - textPresentationScale) > 0.0001 else { return }
        textPresentationScale = scale
        applyPreview(style: currentStyle)
    }

    /// Measure the actual first TextKit baseline, including its integral line
    /// height and text-container inset, instead of estimating from font ascent.
    func firstTextBaseline(in host: NSView) -> CGPoint? {
        textScrollView.layoutSubtreeIfNeeded()
        guard let container = textView.textContainer,
              let manager = textView.layoutManager else { return nil }
        manager.ensureLayout(for: container)
        guard manager.numberOfGlyphs > 0 else { return nil }
        let line = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let glyph = manager.location(forGlyphAt: 0)
        let origin = textView.textContainerOrigin
        return textView.convert(CGPoint(x: origin.x + line.minX + glyph.x,
                                        y: origin.y + line.minY + glyph.y), to: host)
    }

    func alignBodyTextBaseline(to baselineY: CGFloat, in host: NSView) {
        guard usesBodyPresentation, baselineY.isFinite,
              let previous = firstTextBaseline(in: host), previous.y.isFinite else { return }
        let clip = textScrollView.contentView
        let previousOffset = clip.convert(.zero, to: host).y - clip.convert(clip.bounds.origin, to: host).y
        guard abs(previous.y - previousOffset - baselineY) > 0.0001 else { return }
        textView.bodyTextBaselineOffset = 0
        guard let current = firstTextBaseline(in: host), current.y.isFinite else { return }
        var frame = textScrollView.frame
        let scrollOffset = clip.convert(.zero, to: host).y - clip.convert(clip.bounds.origin, to: host).y
        // A caret may scroll a long draft inside its canvas. Anchor the
        // unscrolled layout, so that scrolling never moves the canvas itself.
        frame.origin.y += baselineY - (current.y - scrollOffset)
        textScrollView.frame = frame
        // Native clip views can snap the viewport after moving the scroll
        // view. Preserve the fractional PDF baseline inside TextKit instead.
        if let settled = firstTextBaseline(in: host) {
            let settledOffset = clip.convert(.zero, to: host).y
                - clip.convert(clip.bounds.origin, to: host).y
            let source = CGPoint(x: settled.x, y: settled.y - settledOffset)
            let target = CGPoint(x: settled.x, y: baselineY)
            let originDelta = textView.convert(target, from: host).y
                - textView.convert(source, from: host).y
            if originDelta.isFinite {
                textView.bodyTextBaselineOffset = originDelta
            }
        }
    }

    /// A PDF layout width describes text, excluding editor padding and native
    /// scroller gutters. Account for the real scroll view rather than guessing
    /// its platform-dependent gutter width and wrapping a line too early.
    func setBodyCanvasFrame(_ requested: CGRect, textWidth: CGFloat) {
        textScrollView.frame = requested
        textScrollView.layoutSubtreeIfNeeded()
        guard usesBodyPresentation, textWidth.isFinite, textWidth > 0,
              let container = textView.textContainer else { return }
        var frame = textScrollView.frame
        let chromeWidth = frame.width - textScrollView.contentSize.width
            + textView.textContainerInset.width * 2
        frame.size.width = textWidth + chromeWidth
        textScrollView.frame = frame
        textScrollView.layoutSubtreeIfNeeded()
        // NSScrollView rounds its viewport to pixels. Keep the page's exact
        // fractional text width so a glyph at the right edge does not wrap in
        // the preview but remain on the previous line after Apply.
        container.widthTracksTextView = false
        container.containerSize.width = textWidth
    }

    func textDidChange(_ notification: Notification) {
        let limited = InlineTextDraftLimiter.limit(textView.string)
        if limited.wasTruncated {
            let selection = textView.selectedRange()
            suppressCallbacks = true
            textView.string = limited.text
            textView.setSelectedRange(
                NSRange(
                    location: min(selection.location, limited.text.utf16.count),
                    length: 0
                )
            )
            suppressCallbacks = false
            onLengthLimitReached?()
        }
        if purpose == .bodyText { applyPreview(style: currentStyle) }
        notifyDraftChanged()
    }

    @objc private func styleChanged(_ sender: Any?) {
        // Keep the text field and stepper in lockstep and enforce the same
        // limits used by the model even for pasted/non-numeric values.
        if sender as AnyObject? === sizeStepper {
            sizeField.doubleValue = sizeStepper.doubleValue
        }
        var style = currentStyle
        style.normalize()
        sizeField.doubleValue = Double(style.fontSize)
        sizeStepper.doubleValue = Double(style.fontSize)
        backgroundColorWell.isEnabled = transparentBackgroundButton.state == .off
        applyPreview(style: style)
        notifyDraftChanged(style: style)
    }

    @objc private func commitPressed(_ sender: Any?) {
        onCommit?()
    }

    @objc private func cancelPressed(_ sender: Any?) {
        onCancel?()
    }

    private func buildInterface() {
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.72).cgColor
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 12
        shadow?.shadowOffset = CGSize(width: 0, height: -3)
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.28)

        let scrollView = textScrollView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        // NSTextView(frame: .zero) otherwise keeps a zero-width document
        // frame after the scroller receives its Auto Layout width. TextKit
        // retains all glyphs and can show a caret while painting no letters.
        textView.autoresizingMask = [.width]
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.frame.size.width = scrollView.contentSize.width
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = CGSize(width: 7, height: 7)
        textView.delegate = self
        textView.onCommit = { [weak self] in self?.onCommit?() }
        textView.onCancel = { [weak self] in self?.onCancel?() }
        textView.onLengthLimitReached = { [weak self] in self?.onLengthLimitReached?() }
        scrollView.documentView = textView

        fontMenu.target = self
        fontMenu.action = #selector(styleChanged(_:))
        fontMenu.widthAnchor.constraint(equalToConstant: 128).isActive = true

        sizeField.alignment = .right
        sizeField.formatter = numberFormatter
        sizeField.target = self
        sizeField.action = #selector(styleChanged(_:))
        sizeField.widthAnchor.constraint(equalToConstant: 42).isActive = true

        sizeStepper.minValue = Double(InlineTextStyle.minimumFontSize)
        sizeStepper.maxValue = Double(InlineTextStyle.maximumFontSize)
        sizeStepper.increment = 1
        sizeStepper.target = self
        sizeStepper.action = #selector(styleChanged(_:))
        configureColorWell(textColorWell)
        configureColorWell(backgroundColorWell)
        transparentBackgroundButton.target = self
        transparentBackgroundButton.action = #selector(styleChanged(_:))

        alignmentControl.segmentCount = 3
        alignmentControl.trackingMode = .selectOne
        alignmentControl.target = self
        alignmentControl.action = #selector(styleChanged(_:))

        configureCompactLabel(foregroundLabel)
        configureCompactLabel(backgroundLabel)
        // Two rows are substantially easier to scan than one very long row.
        // The containing horizontal scroller is important for narrow HSplitView
        // panes: every control stays keyboard/mouse reachable instead of being
        // clipped beyond the right edge.
        let typographyRow = NSStackView(views: [
            fontMenu, sizeField, sizeStepper, alignmentControl,
        ])
        typographyRow.orientation = .horizontal
        typographyRow.alignment = .centerY
        typographyRow.spacing = 7
        let colorRow = NSStackView(views: [
            foregroundLabel,
            textColorWell,
            backgroundLabel,
            backgroundColorWell,
            transparentBackgroundButton,
        ])
        colorRow.orientation = .horizontal
        colorRow.alignment = .centerY
        colorRow.spacing = 7
        let toolbar = NSStackView(views: [typographyRow, colorRow])
        toolbar.orientation = .vertical
        toolbar.alignment = .leading
        toolbar.spacing = 5
        toolbar.frame = CGRect(x: 0, y: 0, width: 430, height: 58)

        toolbarScrollView.translatesAutoresizingMaskIntoConstraints = false
        toolbarScrollView.drawsBackground = false
        toolbarScrollView.borderType = .noBorder
        toolbarScrollView.hasHorizontalScroller = true
        toolbarScrollView.hasVerticalScroller = false
        toolbarScrollView.autohidesScrollers = true
        toolbarScrollView.documentView = toolbar
        warningLabel.font = .systemFont(ofSize: 11, weight: .medium)
        warningLabel.textColor = .systemOrange
        warningLabel.maximumNumberOfLines = 2

        shortcutHint.font = .systemFont(ofSize: 10)
        shortcutHint.textColor = .secondaryLabelColor
        shortcutHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        applyButton.target = self
        applyButton.action = #selector(commitPressed(_:))
        applyButton.keyEquivalent = "\r"
        applyButton.bezelStyle = .rounded
        let actionRow = NSStackView(views: [shortcutHint, NSView(), cancelButton, applyButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let root = rootStack
        [toolbarScrollView, scrollView, warningLabel, actionRow].forEach { root.addArrangedSubview($0) }
        root.translatesAutoresizingMaskIntoConstraints = false
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        addSubview(root)
        textScrollConstraints = [
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),
        ]
        NSLayoutConstraint.activate(textScrollConstraints)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            toolbarScrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            toolbarScrollView.heightAnchor.constraint(equalToConstant: 62),
            warningLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])

        refreshLocalization()
        installLanguageObserver()
    }

    /// Refreshes every string owned by this long-lived AppKit panel.
    /// SwiftUI recreates its labels when the app language changes, but this
    /// overlay can remain open over the same PDFView and therefore must update
    /// the concrete controls in place.
    func refreshLocalization() {
        textView.setAccessibilityLabel(
            L10n.string("inline_text.editor", defaultValue: "PDF inline text editor")
        )
        fontMenu.setAccessibilityLabel(L10n.string("inline_text.font", defaultValue: "Font"))
        sizeField.setAccessibilityLabel(
            L10n.string("inline_text.font_size", defaultValue: "Font size")
        )
        sizeStepper.setAccessibilityLabel(
            L10n.string("inline_text.font_size", defaultValue: "Font size")
        )
        textColorWell.setAccessibilityLabel(
            L10n.string("inline_text.text_color", defaultValue: "Text color")
        )
        backgroundColorWell.setAccessibilityLabel(
            L10n.string("inline_text.background_color", defaultValue: "Background color")
        )
        transparentBackgroundButton.title = L10n.string(
            "inline_text.transparent_background",
            defaultValue: "Transparent"
        )
        transparentBackgroundButton.setAccessibilityLabel(transparentBackgroundButton.title)

        let alignmentSegments = [
            ("text.alignleft", "inline_text.alignment.left", "Align left"),
            ("text.aligncenter", "inline_text.alignment.center", "Align center"),
            ("text.alignright", "inline_text.alignment.right", "Align right"),
        ]
        for (index, segment) in alignmentSegments.enumerated() {
            let label = L10n.string(segment.1, defaultValue: segment.2)
            let image = NSImage(
                systemSymbolName: segment.0,
                accessibilityDescription: label
            ) ?? NSImage()
            image.accessibilityDescription = label
            alignmentControl.setImage(image, forSegment: index)
            alignmentControl.setToolTip(label, forSegment: index)
        }
        alignmentControl.setAccessibilityLabel(
            L10n.string("inline_text.alignment", defaultValue: "Text alignment")
        )

        toolbarScrollView.setAccessibilityLabel(
            L10n.string("inline_text.appearance_controls", defaultValue: "Text appearance controls")
        )
        foregroundLabel.stringValue = L10n.string(
            "inline_text.text_color.short",
            defaultValue: "Text"
        )
        backgroundLabel.stringValue = L10n.string(
            "inline_text.background_color.short",
            defaultValue: "Background"
        )
        if fontMenuConfigured, let systemItem = fontMenu.item(at: 0) {
            systemItem.title = L10n.string("inline_text.system_font", defaultValue: "System")
        }

        refreshPurposeHint()
        refreshShortcuts()
        cancelButton.title = L10n.string("action.cancel", defaultValue: "Cancel")
        applyButton.title = L10n.string("action.apply", defaultValue: "Apply")
    }

    private func refreshShortcuts() {
        shortcutHint.stringValue = purpose == .bodyText
            ? L10n.string("body_text.shortcuts", defaultValue: "Return Line Break · ⌘Return Apply · Esc Cancel")
            : L10n.string("inline_text.shortcuts", defaultValue: "Return/⌘Return Apply · Shift-Return Line Break · Esc Cancel")
        shortcutHint.setAccessibilityLabel(shortcutHint.stringValue)
        applyButton.keyEquivalentModifierMask = purpose == .bodyText ? .command : []
        applyButton.toolTip = shortcutHint.stringValue
        textView.toolTip = purpose == .bodyText ? shortcutHint.stringValue : nil
    }

    private func refreshPurposeHint() {
        warningLabel.stringValue = purpose == .bodyText
            ? L10n.string("body_text.edit_hint", defaultValue:
                "본문 텍스트를 수정합니다. 내용을 모두 지우고 적용하면 해당 텍스트가 삭제됩니다.")
            : L10n.string("inline_text.visual_replacement_warning", defaultValue:
                "Visual replacement only. The original text remains available to search and copy; this is not secure redaction.")
        warningLabel.setAccessibilityLabel(warningLabel.stringValue)
    }

    private func installLanguageObserver() {
        guard languageObserver == nil else { return }
        languageObserver = NotificationCenter.default.addObserver(
            forName: .appLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshLocalization()
            }
        }
    }

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.minimum = NSNumber(value: Double(InlineTextStyle.minimumFontSize))
        formatter.maximum = NSNumber(value: Double(InlineTextStyle.maximumFontSize))
        formatter.allowsFloats = true
        formatter.maximumFractionDigits = 1
        return formatter
    }

    private func configureFontMenu() {
        fontMenu.removeAllItems()
        let system = NSFont.systemFont(ofSize: 15)
        fontMenu.addItem(withTitle: L10n.string("inline_text.system_font", defaultValue: "System"))
        fontMenu.lastItem?.representedObject = system.fontName
        let manager = NSFontManager.shared
        for family in manager.availableFontFamilies.sorted() {
            let converted = manager.convert(system, toFamily: family)
            fontMenu.addItem(withTitle: family)
            fontMenu.lastItem?.representedObject = converted.fontName
        }
    }

    private func selectFont(named name: String, sourceFont: PDFBodyTextDocumentFonts.Lease? = nil) {
        // A private program is a distinct menu choice from an installed face
        // with the same PostScript name. Selecting that installed choice opts
        // out of source-run preservation through sourceFont identity equality.
        for item in fontMenu.itemArray {
            if let lease = item.representedObject as? PDFBodyTextDocumentFonts.Lease,
               lease != sourceFont { fontMenu.menu?.removeItem(item) }
        }
        if let sourceFont {
            if let item = fontMenu.itemArray.first(where: {
                ($0.representedObject as? PDFBodyTextDocumentFonts.Lease) == sourceFont
            }) { fontMenu.select(item); return }
            fontMenu.addItem(withTitle: sourceFont.font(ofSize: 15)?.displayName ?? name)
            fontMenu.lastItem?.representedObject = sourceFont
            fontMenu.select(fontMenu.lastItem)
            return
        }
        if let item = fontMenu.itemArray.first(where: { ($0.representedObject as? String) == name }) {
            fontMenu.select(item)
            return
        }
        // A PDF may use a bold/italic face or embedded PostScript name that is
        // not the regular face returned by NSFontManager's family list. Keep
        // that exact face as an explicit menu item; otherwise merely opening
        // and applying the editor would silently replace it with System.
        let displayName = NSFont(name: name, size: 15)?.displayName ?? name
        fontMenu.addItem(withTitle: displayName)
        fontMenu.lastItem?.representedObject = name
        fontMenu.select(fontMenu.lastItem)
    }

    private func configureColorWell(_ well: NSColorWell) {
        well.target = self
        well.action = #selector(styleChanged(_:))
        well.widthAnchor.constraint(equalToConstant: 28).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private func configureCompactLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
    }

    private var sourceBaselineAdvance: CGFloat? {
        guard purpose == .bodyText, let bodyTextLineHeight,
              bodyTextLineHeight.isFinite, bodyTextLineHeight > 0 else { return nil }
        let advance = bodyTextLineHeight * textPresentationScale
        return advance.isFinite && advance > 0 ? advance : nil
    }

    private func configureBaselineLayout() {
        guard let manager = textView.layoutManager else { return }
        manager.delegate = self
        let usesFontLeading = sourceBaselineAdvance == nil
        if manager.usesFontLeading != usesFontLeading {
            manager.usesFontLeading = usesFontLeading
            manager.invalidateLayout(forCharacterRange: NSRange(location: 0,
                length: textView.textStorage?.length ?? 0), actualCharacterRange: nil)
        }
    }

    nonisolated func layoutManager(_ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange) -> Bool {
        // This panel owns its TextKit objects on the main actor. Fractional
        // fonts can add leading even with usesFontLeading disabled; control
        // only the source's baseline advance, preserving native glyph layout,
        // ink bounds, baseline offsets, selection, and input-method handling.
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
            guard let advance = sourceBaselineAdvance else { return false }
            lineFragmentRect.pointee.size.height = advance
            return true
        }
    }

    private func applyPreview(style: InlineTextStyle) {
        configureBaselineLayout()
        var previewStyle = style
        if purpose == .bodyText, style.backgroundColor.alpha <= 0.001,
           let paper = bodyTextPreviewPaperColor {
            previewStyle.backgroundColor = paper
        }
        let appearance = PDFInlineTextEditorAppearance(style: previewStyle)
        let resolvedFont = purpose == .bodyText
            ? PDFBodyTextEditor.replacementFont(for: textView.string, preferred: style.font)
            : style.font
        textView.font = style.renderingFont(resolvedFont, size: style.fontSize * textPresentationScale)
        textView.textColor = appearance.ink
        textView.backgroundColor = appearance.paper
        textView.drawsBackground = true
        textScrollView.backgroundColor = appearance.paper
        textScrollView.drawsBackground = true
        textView.insertionPointColor = appearance.ink
        textView.selectedTextAttributes = [
            .foregroundColor: NSColor.selectedTextColor,
            .backgroundColor: NSColor.selectedTextBackgroundColor,
        ]
        textView.alignment = style.alignment
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment
        if purpose == .bodyText, let bodyTextLineHeight, bodyTextLineHeight.isFinite {
            let height = (bodyTextLineHeight > 0 ? bodyTextLineHeight : style.fontSize) * textPresentationScale
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
        }
        textView.defaultParagraphStyle = paragraph
        if purpose == .bodyText {
            let attributed = PDFBodyTextAttributedLayout.attributedString(text: textView.string, style: style,
                sourceText: bodyTextSourceText, sourceStyle: bodyTextSourceStyle, sourceRuns: bodyTextSourceRuns,
                lineHeight: bodyTextLineHeight, firstLineIndent: bodyTextFirstLineIndent,
                textScale: textPresentationScale)
            // Apply appearance attributes in place. Replacing the whole
            // attributed string would discard IME marked text and selection.
            if let storage = textView.textStorage {
                storage.beginEditing()
                attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
                    storage.addAttributes(attributes, range: range)
                }
                storage.endEditing()
            }
        } else {
            textView.textStorage?.addAttribute(.paragraphStyle, value: paragraph,
                range: NSRange(location: 0, length: textView.string.utf16.count))
        }
    }

    private func notifyDraftChanged(style: InlineTextStyle? = nil) {
        guard !suppressCallbacks else { return }
        onDraftChanged?(textView.string, style ?? currentStyle)
    }

    private func segment(for alignment: NSTextAlignment) -> Int {
        switch alignment {
        case .center: 1
        case .right: 2
        default: 0
        }
    }

    private func alignment(for segment: Int) -> NSTextAlignment {
        switch segment {
        case 1: .center
        case 2: .right
        default: .left
        }
    }
}

/// Transparent sibling overlay that hosts the editor and paints an unsaved
/// target rectangle. Editor chrome is never attached to `PDFPage`, so it can
/// never leak into saved or printed output.
@MainActor
final class PDFInlineTextEditingOverlayView: NSView {
    weak var owner: InteractivePDFView?

    /// View-instance identity is separate from the draft UUID. During a
    /// SwiftUI replacement, outgoing and incoming overlays can display the
    /// same draft; only the incoming owner may write it back.
    private let ownershipID = UUID()
    // A normal reader installs this lightweight overlay to keep PDFKit's
    // rendering order stable. Building TextKit, formatting controls and their
    // constraints belongs to the first actual edit, not opening every PDF or
    // creating every compact-spread row.
    private lazy var panel = PDFInlineTextEditorPanel(frame: .zero)
    private var hasPreparedPanel = false
    private var activeDraftID: UUID?
    private var targetRect = CGRect.zero
    private var boundsObserver: NSObjectProtocol?
    private var scaleObserver: NSObjectProtocol?
    private weak var observedClipView: NSClipView?
    private(set) var superviewAttachmentCount = 0
    private var presentsBodyCanvas: Bool {
        hasPreparedPanel && panel.textScrollView.superview === self
    }

    /// Narrow test seam for lifecycle verification. Production callers should
    /// use `prepareForRemoval()` rather than manipulating observers directly.
    var hasInstalledObservers: Bool {
        boundsObserver != nil || scaleObserver != nil
    }

    override var isOpaque: Bool { false }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil {
            superviewAttachmentCount += 1
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isHidden = true
    }

    /// Only the text canvas and formatting controls own mouse input. Returning nil elsewhere keeps
    /// PDFKit form widgets, selection, links, and gestures fully native.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hasPreparedPanel, !panel.isHidden,
              panel.frame.contains(point)
                || (presentsBodyCanvas && panel.textScrollView.frame.contains(point))
        else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        positionPanel()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !targetRect.isEmpty, hasPreparedPanel, !panel.isHidden else { return }
        NSGraphicsContext.saveGraphicsState()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(roundedRect: targetRect, xRadius: 3, yRadius: 3)
        path.lineWidth = 2
        path.setLineDash([5, 3], count: 2, phase: 0)
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    func synchronizeWithWorkspace() {
        let wasPresenting = activeDraftID != nil || !targetRect.isEmpty
        guard
            let owner,
            owner.viewportContext == .normal,
            owner.workspaceState?.allowsInlineTextEditing == true,
            let draft = owner.workspaceState?.pendingInlineTextEdit,
            let document = owner.document,
            draft.pageIndex >= 0,
            draft.pageIndex < document.pageCount,
            owner.compactSpread?.contains(pageIndex: draft.pageIndex) != false
        else {
            removeObservations()
            if hasPreparedPanel { panel.isHidden = true }
            isHidden = true
            targetRect = .zero
            activeDraftID = nil
            if wasPresenting {
                needsDisplay = true
            }
            return
        }

        if activeDraftID != draft.id {
            guard owner.workspaceState?.claimPendingInlineTextEditor(
                ownerID: ownershipID,
                draftID: draft.id
            ) == true else {
                removeObservations()
                if hasPreparedPanel { panel.isHidden = true }
                isHidden = true
                targetRect = .zero
                activeDraftID = nil
                return
            }
            if !hasPreparedPanel { setupPanel() }
            activeDraftID = draft.id
            if draft.purpose == .bodyText {
                // The draft already owns the selected UTF-16 range and reveal
                // geometry. Transfer input from both PDFKit and repaired drag
                // selection to TextKit only once, when this editor claims it.
                owner.finishNativeSelectionPreview()
                owner.clearSelection()
                owner.workspaceState?.currentSelection = nil
            }
            // A rotated page needs the floating text canvas: a horizontal
            // NSTextView cannot safely imitate a rotated PDF baseline.
            let usesPageCanvas = draft.purpose == .bodyText
                && (document.page(at: draft.pageIndex)?.rotation ?? 0) % 360 == 0
            panel.setBodyPresentation(in: usesPageCanvas ? self : nil)
            panel.configure(with: draft)
            panel.isHidden = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeDraftID == draft.id,
                      self.ownsActiveDraft, !self.isHidden else { return }
                self.revealPendingBodyTextSelection()
                self.panel.focusText()
            }
        }
        isHidden = false
        refreshScrollObservation()
        positionPanel()
        needsDisplay = true
    }

    /// Called before PDFView interprets a click outside the editor. A valid
    /// draft becomes one semantic PDF edit before the next pointer tool starts.
    func commitBeforePointerAction() {
        guard ownsActiveDraft else { return }
        commit()
    }

    func prepareForRemoval() {
        // A replacement PDFView may already own a newer draft for this same
        // workspace. The outgoing overlay must never synchronize or commit a
        // transaction whose UUID it does not own.
        if ownsActiveDraft {
            synchronizeDraft()
            owner?.workspaceState?.commitPendingInlineTextDraftIfNeeded()
        }
        if let activeDraftID {
            owner?.workspaceState?.releasePendingInlineTextEditor(
                ownerID: ownershipID,
                draftID: activeDraftID
            )
        }
        removeObservations()
        owner = nil
    }

    private func setupPanel() {
        hasPreparedPanel = true
        isHidden = true
        panel.isHidden = true
        addSubview(panel)
        panel.onDraftChanged = { [weak self] _, _ in
            self?.synchronizeDraft()
            self?.positionPanel()
        }
        panel.onLengthLimitReached = { [weak self] in
            guard let self else { return }
            guard self.ownsActiveDraft else { return }
            let limit = L10n.format(
                "inline_text.length_limit",
                InlineTextDraftLimiter.maximumCharacterCount
            )
            self.owner?.workspaceState?.statusMessage = self.panel.purpose == .visualReplacement
                ? [L10n.string("inline_text.visual_replacement_warning"), limit]
                    .joined(separator: " ")
                : limit
        }
        panel.onCommit = { [weak self] in self?.commit() }
        panel.onCancel = { [weak self] in self?.cancel() }
    }

    private func synchronizeDraft() {
        guard let owner, let id = activeDraftID, ownsActiveDraft else { return }
        owner.workspaceState?.updatePendingInlineTextDraft(
            id: id,
            text: panel.currentText,
            style: panel.currentStyle,
            bounds: owner.workspaceState?.pendingInlineTextEdit?.bounds ?? .zero
        )
    }

    private func commit() {
        guard
            let state = owner?.workspaceState,
            let id = activeDraftID,
            ownsActiveDraft
        else {
            finishPresentation()
            return
        }
        let bounds = state.pendingInlineTextEdit?.bounds ?? .zero
        state.commitPendingInlineText(
            id: id,
            text: panel.currentText,
            style: panel.currentStyle,
            bounds: bounds
        )
        guard state.pendingInlineTextEdit?.id != id else {
            synchronizeDraft()
            return
        }
        finishPresentation()
    }

    private func cancel() {
        if ownsActiveDraft {
            owner?.workspaceState?.cancelPendingInlineText()
        }
        finishPresentation()
    }

    private var ownsActiveDraft: Bool {
        guard let state = owner?.workspaceState, let activeDraftID else { return false }
        return state.ownsPendingInlineTextEditor(
            ownerID: ownershipID,
            draftID: activeDraftID
        )
    }

    private func finishPresentation() {
        activeDraftID = nil
        targetRect = .zero
        if hasPreparedPanel { panel.isHidden = true }
        isHidden = true
        removeObservations()
        owner?.needsDisplay = true
        owner?.window?.makeFirstResponder(owner)
    }

    func focusText(at ownerPoint: CGPoint) {
        guard let owner, presentsBodyCanvas, ownsActiveDraft else { return }
        layoutSubtreeIfNeeded()
        panel.focusText(at: panel.textView.convert(ownerPoint, from: owner))
    }

    func focusTextSelection() {
        guard ownsActiveDraft else { return }
        revealPendingBodyTextSelection()
        layoutSubtreeIfNeeded()
        panel.focusText()
    }

    /// The workspace consumes the request once, so rebuilding an overlay or
    /// typing after a manual scroll never re-centers an already open editor.
    /// The main PDFView update calls this after its page/zoom navigation; the
    /// initial responder callback also covers direct native view entry points.
    func revealPendingBodyTextSelection() {
        guard ownsActiveDraft, let owner, let draftID = activeDraftID,
              let draft = owner.workspaceState?.pendingInlineTextEdit,
              draft.id == draftID, draft.purpose == .bodyText,
              let page = owner.document?.page(at: draft.pageIndex),
              let documentView = owner.documentView,
              documentView.bounds.width > 0, documentView.bounds.height > 0,
              let scroll = owner.compactSpread?.host?.scrollView
                ?? documentView.enclosingScrollView ?? firstScrollView(in: owner)
        else { return }
        let clip = scroll.contentView
        guard clip.bounds.width > 0, clip.bounds.height > 0,
              let lineRects = owner.workspaceState?.consumePendingBodyTextFocus(draftID: draftID)
        else { return }
        let converted = lineRects.map { rect in
            clip.convert(convertedRect(rect, from: page, owner: owner), from: self)
        }
        guard let proposed = PDFBodyTextFocusScrollPolicy.proposedBounds(
            focusing: converted, viewport: clip.bounds, isFlipped: clip.isFlipped)
        else { return }
        // PDFKit's clip view knows its document margins and centered short
        // pages. Use its native clamping rather than assuming a zero origin.
        let constrained = clip.constrainBoundsRect(proposed)
        clip.scroll(to: constrained.origin)
        scroll.reflectScrolledClipView(clip)
        positionPanel()
        // The toolbar click can take focus from TextKit. An explicit edit
        // request must leave typing directed at the selected body text.
        panel.focusText()
        needsDisplay = true
    }

    private func positionPanel() {
        guard
            let owner,
            let draft = owner.workspaceState?.pendingInlineTextEdit,
            draft.id == activeDraftID,
            let page = owner.document?.page(at: draft.pageIndex)
        else { return }

        targetRect = convertedRect(draft.bounds, from: page, owner: owner)
        if presentsBodyCanvas {
            let baseline = draft.bodyTextBaseline.map {
                convert(owner.convert($0, from: page), from: owner)
            }
            positionBodyEditor(targetRect: targetRect, baseline: baseline, draft: draft, page: page, owner: owner)
            return
        }
        panel.frame = InlineTextGeometry.editorPanelFrame(
            targetRect: targetRect,
            viewportBounds: bounds,
            purpose: draft.purpose
        )
    }

    private func positionBodyEditor(targetRect: CGRect, baseline: CGPoint?, draft: PendingInlineTextEdit,
                                    page: PDFPage, owner: InteractivePDFView) {
        let viewport = bounds.insetBy(dx: 8, dy: 8)
        guard viewport.width > 0, viewport.height > 0 else { return }
        let scale = max(0.05, owner.scaleFactor)
        panel.setTextPresentationScale(scale)
        let scroll = panel.textScrollView
        scroll.wantsLayer = true
        let editor = panel.textView
        let padding: CGFloat = 7
        // The editing canvas covers the original run only while its draft is
        // open. It is an ordinary text view, never a PDF annotation.
        let font = editor.font ?? .systemFont(ofSize: 15)
        let nativeWidth = PDFBodyTextEditor.layoutWidth(text: panel.currentText, style: panel.currentStyle,
            bounds: draft.bounds, visibleBox: page.bounds(for: .mediaBox).intersection(page.bounds(for: .cropBox)),
            baseline: draft.bodyTextBaseline, lineHeight: draft.bodyTextLineHeight,
            firstLineIndent: draft.bodyTextFirstLineIndent, sourceText: draft.bodyTextSourceText,
            sourceStyle: draft.bodyTextSourceStyle, sourceRuns: draft.bodyTextSourceRuns)
        let textWidth = max(1, nativeWidth * scale)
        let lineHeight = max(20, ceil(font.ascender - font.descender + font.leading))
        // Text layout is defined in page coordinates. A narrow viewport clips
        // that canvas with the PDF instead of introducing different wrapping
        // from the content that Apply will save.
        let textOriginX = baseline.map { $0.x - draft.bodyTextFirstLineIndent * scale } ?? targetRect.minX
        var frame = CGRect(x: textOriginX - padding, y: targetRect.minY - padding,
                           width: textWidth + padding * 2,
                           height: max(targetRect.height, lineHeight) + padding * 2)
        panel.setBodyCanvasFrame(frame, textWidth: textWidth)
        frame = scroll.frame
        if let container = editor.textContainer, let manager = editor.layoutManager {
            manager.ensureLayout(for: container)
            frame.size.height = min(viewport.height * 0.55,
                max(frame.height, ceil(manager.usedRect(for: container).height) + padding * 2))
        }
        // NSView's coordinate system grows upward; pin the top of the text to
        // the PDF run while additional typed lines expand downward.
        frame.origin.y = targetRect.maxY + padding - frame.height
        frame.origin.y = min(max(viewport.minY, frame.minY), viewport.maxY - frame.height)
        scroll.frame = frame
        if let baseline, baseline.y >= viewport.minY, baseline.y <= viewport.maxY {
            panel.alignBodyTextBaseline(to: baseline.y, in: self)
            frame = scroll.frame
        }
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.controlAccentColor.cgColor
        scroll.layer?.cornerRadius = 3

        let toolbarWidth = min(460, viewport.width)
        let toolbarHeight: CGFloat = 114
        let above = frame.maxY + 6
        let toolbarY = above + toolbarHeight <= viewport.maxY
            ? above : max(viewport.minY, frame.minY - toolbarHeight - 6)
        panel.frame = CGRect(x: min(max(viewport.minX, frame.minX), viewport.maxX - toolbarWidth),
                             y: toolbarY, width: toolbarWidth, height: toolbarHeight)
    }

    private func convertedRect(
        _ pageRect: CGRect,
        from page: PDFPage,
        owner: InteractivePDFView
    ) -> CGRect {
        let pageCorners = [
            CGPoint(x: pageRect.minX, y: pageRect.minY),
            CGPoint(x: pageRect.maxX, y: pageRect.minY),
            CGPoint(x: pageRect.minX, y: pageRect.maxY),
            CGPoint(x: pageRect.maxX, y: pageRect.maxY),
        ]
        let points = pageCorners.map { point -> CGPoint in
            let ownerPoint = owner.convert(point, from: page)
            return convert(ownerPoint, from: owner)
        }
        guard
            let minX = points.map(\.x).min(),
            let maxX = points.map(\.x).max(),
            let minY = points.map(\.y).min(),
            let maxY = points.map(\.y).max()
        else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func refreshScrollObservation() {
        guard let owner else { return }
        let clipView = firstScrollView(in: owner)?.contentView ?? owner.enclosingScrollView?.contentView
        if observedClipView !== clipView {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            observedClipView = clipView
            if let clipView {
                clipView.postsBoundsChangedNotifications = true
                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.positionPanel()
                        self?.needsDisplay = true
                    }
                }
            }
        }
        if scaleObserver == nil {
            scaleObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewScaleChanged,
                object: owner,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.positionPanel()
                    self?.needsDisplay = true
                }
            }
        }
    }

    private func removeObservations() {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
        boundsObserver = nil
        scaleObserver = nil
        observedClipView = nil
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let result = firstScrollView(in: subview) { return result }
        }
        return nil
    }
}

@MainActor
extension InteractivePDFView {
    func revealPendingBodyTextSelection() {
        subviews.compactMap { $0 as? PDFInlineTextEditingOverlayView }
            .forEach { $0.revealPendingBodyTextSelection() }
    }

    func focusInlineTextEditorSelection() {
        subviews.compactMap { $0 as? PDFInlineTextEditingOverlayView }
            .forEach { $0.focusTextSelection() }
    }

    func focusInlineTextEditor(at point: CGPoint) {
        subviews.compactMap { $0 as? PDFInlineTextEditingOverlayView }
            .forEach { $0.focusText(at: point) }
    }

    func configureInlineTextEditingOverlay() {
        let overlay: PDFInlineTextEditingOverlayView
        if let installed = subviews.compactMap({ $0 as? PDFInlineTextEditingOverlayView }).last {
            overlay = installed
        } else {
            overlay = PDFInlineTextEditingOverlayView(frame: bounds)
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        overlay.owner = self
        overlay.synchronizeWithWorkspace()
    }

    func commitInlineTextEditorBeforePointerAction() {
        subviews.compactMap { $0 as? PDFInlineTextEditingOverlayView }
            .forEach { $0.commitBeforePointerAction() }
    }

    func prepareInlineTextEditingOverlayForRemoval() {
        subviews.compactMap { $0 as? PDFInlineTextEditingOverlayView }
            .forEach { $0.prepareForRemoval() }
    }
}
