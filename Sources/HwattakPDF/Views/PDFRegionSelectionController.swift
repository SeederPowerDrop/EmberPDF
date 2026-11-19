// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import QuartzCore

enum PDFTextSelectionGeometry {
    /// Sample only the clicked page. A corrupt font ascent can make a single
    /// character selection hundreds of pages tall, even when glyphs look fine.
    /// Image-only pages also need the bounded local region recognizer: native
    /// PDFKit dragging otherwise silently selects nothing on a scanned page.
    static func needsRegionSelection(on page: PDFPage) -> Bool {
        let count = page.numberOfCharacters
        guard count > 0 else { return true }
        let box = page.bounds(for: .cropBox)
        let limit = max(box.width, box.height) * 4
        guard limit.isFinite, limit > 0 else { return false }
        var measured = 0
        var collapsed = 0
        for sample in 0..<min(count, 48) {
            let index = sample * max(0, count - 1) / max(1, min(count, 48) - 1)
            guard let selection = page.selection(for: NSRange(location: index, length: 1)),
                  let text = selection.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            measured += 1
            let character = page.characterBounds(at: index)
            if character.width < 0.1 || character.height < 0.1 { collapsed += 1 }
            let rect = selection.bounds(for: page)
            if !rect.isNull && (!rect.width.isFinite || !rect.height.isFinite
                || rect.width > limit || rect.height > limit) { return true }
        }
        // Some scanned books embed zero-height OCR glyphs. PDFKit still
        // reports text and selects ranges, but those ranges jump between rows.
        if measured >= 6 && collapsed * 3 >= measured { return true }
        // PDFKit can leak an unbalanced Form XObject graphics state into its
        // parent, shifting selection rectangles even though rendering is fine.
        return PDFFormGraphicsStateInspector.hasUnbalancedForm(on: page)
    }
}

/// An ephemeral selection only: original PDF bytes, annotations and OCR
/// checkpoints are never rewritten. Damaged font metrics are repaired in a
/// selection-only page; explicit region selection is recognized on-device.
@MainActor
final class PDFRegionSelectionController {
    weak var owner: InteractivePDFView?
    private let overlay = PDFRegionSelectionOverlay(frame: .zero)
    private weak var document: PDFDocument?
    private var revision: UUID?
    private var geometryCache: [(page: PDFPage, damaged: Bool, proxy: PDFNativeSelectionProxy?,
                                 layout: PDFVisualTextLayout?, collapsed: PDFNativeTextLayout.CollapsedLayout?)] = []
    private var visualCache: [(page: PDFPage, layout: PDFVisualTextLayout)] = []
    private var visualLayout: PDFVisualTextLayout?
    private var nativeLayout: PDFVisualTextLayout?
    private var collapsedLayout: PDFNativeTextLayout.CollapsedLayout?
    private var preparationTask: Task<Void, Never>?
    private weak var preparationPage: PDFPage?
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private var page: PDFPage?
    private var start: CGPoint?
    private var region: CGRect?
    private var visualTextDrag: PDFVisualTextDrag?
    private var nativeProxy: PDFNativeSelectionProxy?
    private var nativeAnchor: PDFSelection?
    private var nativeClickCount = 1
    private var nativeHasDragged = false
    private var nativeFragments: [PDFRegionTextFragment] = []
    private var selectionPreviewID: UUID?
    private weak var observedClipView: NSClipView?
    private var boundsObserver: NSObjectProtocol?
    private(set) var selection: PDFRegionTextSelection?
    var isDragging: Bool { start != nil }
    var isActive: Bool { page != nil }

    init(owner: InteractivePDFView) {
        self.owner = owner
        overlay.controller = self
    }

    deinit {
        task?.cancel()
        preparationTask?.cancel()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    func synchronize() {
        guard let owner else { return }
        let newRevision = owner.workspaceState?.revision
        if document !== owner.document || revision != newRevision {
            cancel()
            document = owner.document
            revision = newRevision
            geometryCache.removeAll()
            visualCache.removeAll()
        }
        if owner.activeTool != .select
            || (isActive && !ownsCurrentSelection)
            || (page != nil && !owner.visiblePages.contains(where: { $0 === page })) {
            cancel()
        }
        refreshOverlay()
        prepareVisibleGeometryIfNeeded()
    }

    private var ownsCurrentSelection: Bool {
        guard let state = owner?.workspaceState else { return false }
        if let selectionPreviewID, !state.ownsSelectionPreview(selectionPreviewID) { return false }
        return state.currentSelection === selection
    }

    private func geometry(for page: PDFPage) -> (damaged: Bool, proxy: PDFNativeSelectionProxy?,
                                                layout: PDFVisualTextLayout?, collapsed: PDFNativeTextLayout.CollapsedLayout?) {
        if let cached = geometryCache.first(where: { $0.page === page }) {
            return (cached.damaged, cached.proxy, cached.layout, cached.collapsed)
        }
        let damaged = PDFTextSelectionGeometry.needsRegionSelection(on: page)
        let repaired = damaged ? PDFNativeSelectionProxy.makePage(for: page) : nil
        let proxy = repaired.flatMap { PDFTextSelectionGeometry.needsRegionSelection(on: $0.page) ? nil : $0 }
        let collapsed = damaged && proxy == nil ? PDFNativeTextLayout.makeCollapsedLayout(for: page) : nil
        let lines = proxy.flatMap { PDFNativeTextLayout.makeLines(for: $0.page) } ?? collapsed?.lines
        let layout = lines
            .map { PDFVisualTextLayout(lines: $0, imageToPage: .identity) }
        geometryCache.append((page, damaged, proxy, layout, collapsed))
        if geometryCache.count > 4 { geometryCache.removeFirst() }
        return (damaged, proxy, layout, collapsed)
    }

    private func prepareVisibleGeometryIfNeeded() {
        guard let owner, let state = owner.workspaceState, let document = owner.document,
              document === state.document, owner.window != nil, !isDragging,
              owner.activeTool == .select, state.allows(.copyAndPaste),
              let page = owner.currentPage, owner.visiblePages.contains(where: { $0 === page }),
              !geometryCache.contains(where: { $0.page === page }), preparationPage !== page else { return }
        preparationTask?.cancel()
        preparationPage = page
        let capturedRevision = state.revision
        preparationTask = Task { [weak self, weak document, weak page] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, let document, let page, !Task.isCancelled,
                  self.preparationPage === page else { return }
            self.preparationTask = nil
            self.preparationPage = nil
            guard let owner = self.owner, let state = owner.workspaceState,
                  owner.document === document, state.document === document,
                  state.revision == capturedRevision, state.allows(.copyAndPaste),
                  owner.activeTool == .select, !self.isDragging, NSEvent.pressedMouseButtons == 0,
                  owner.visiblePages.contains(where: { $0 === page }) else { return }
            // Prepare one visible page after its viewport settles. This keeps
            // the initial font/form parsing out of the first mouse-down; OCR
            // and document mutations are never performed by this warm-up.
            _ = self.geometry(for: page)
        }
    }

    func refreshOverlay() {
        guard let owner else { return }
        owner.positionRegionSelectionOverlay(overlay)
        if overlay.frame != owner.bounds { overlay.frame = owner.bounds }
        overlay.isHidden = !isActive
        updateOverlayPath()
        let clipView = owner.documentView?.enclosingScrollView?.contentView
        if observedClipView !== clipView {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            observedClipView = clipView
            boundsObserver = nil
            if let clipView {
                clipView.postsBoundsChangedNotifications = true
                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateOverlayPath() }
                }
            }
        }
    }

    @discardableResult
    func begin(with event: NSEvent) -> Bool {
        // A pointer event may arrive before SwiftUI's next updateNSView.
        // Validate cached geometry against the live document revision now.
        synchronize()
        cancel()
        guard let owner, owner.activeTool == .select,
              let state = owner.workspaceState, state.allows(.copyAndPaste),
              owner.document === state.document else { return false }
        let point = owner.convert(event.locationInWindow, from: nil)
        guard let page = owner.page(for: point, nearest: false) else { return false }
        let pagePoint = owner.convert(point, to: page)
        // Native links and form widgets retain their own pointer behavior.
        guard !page.annotations.contains(where: {
            ($0.type == "Link" || $0.type == "Widget") && $0.bounds.contains(pagePoint)
        }) else { return false }
        let explicit = event.modifierFlags.contains(.option)
        let (damaged, proxy, layout, collapsed) = geometry(for: page)
        guard explicit || damaged else { return false }
        owner.clearSelection()
        state.currentSelection = nil
        self.page = page
        start = pagePoint
        selectionPreviewID = state.beginSelectionPreview()
        nativeProxy = explicit ? nil : proxy
        nativeLayout = explicit ? nil : layout
        // A zero-outline OCR font can still provide verified range-selection
        // cells on the original page. The same visual drag layout then uses
        // native Unicode immediately, without a second OCR interpretation.
        let initialDrag = PDFVisualTextDrag(start: pagePoint, end: pagePoint)
        collapsedLayout = !explicit && collapsed?.supports(initialDrag) == true ? collapsed : nil
        visualLayout = collapsedLayout != nil ? nativeLayout : nil
        visualTextDrag = !explicit && nativeProxy == nil && page.numberOfCharacters > 0
            ? PDFVisualTextDrag(start: pagePoint, end: pagePoint) : nil
        nativeClickCount = event.clickCount
        if let proxy = nativeProxy {
            if nativeClickCount >= 3 {
                nativeAnchor = proxy.page.selectionForLine(at: pagePoint)
            } else if nativeClickCount == 2 {
                nativeAnchor = proxy.page.selectionForWord(at: pagePoint)
            }
            if let nativeAnchor { applyNativeSelection(nativeAnchor) }
        } else {
            region = CGRect(origin: pagePoint, size: .zero)
            state.statusMessage = L10n.string(visualTextDrag == nil ? "selection.region_drag" : "status.ready")
        }
        owner.window?.makeFirstResponder(owner)
        if visualTextDrag != nil, visualLayout == nil { prepareVisualLayout(for: page) }
        refreshOverlay()
        return true
    }

    func drag(with event: NSEvent) {
        // The selection layer follows the newest pointer immediately. Core
        // Animation coalesces presentation with the display; a 60 Hz timer here
        // added latency and capped ProMotion displays unnecessarily.
        updateDrag(with: event)
    }

    private func updateDrag(with event: NSEvent) {
        guard let owner, let page, let start else { return }
        // A pointer event can arrive before SwiftUI delivers a document/tool
        // change. The preview token also detects an external nil-to-nil clear.
        guard let state = owner.workspaceState, document === owner.document,
              revision == state.revision, owner.document === state.document,
              owner.activeTool == .select, state.allows(.copyAndPaste),
              ownsCurrentSelection,
              owner.visiblePages.contains(where: { $0 === page }) else {
            cancel()
            return
        }
        let viewPoint = owner.convert(event.locationInWindow, from: nil)
        if !owner.visibleRect.insetBy(dx: 12, dy: 12).contains(viewPoint) {
            owner.autoscroll(with: event)
        }
        let end = owner.convert(viewPoint, to: page)
        if let proxy = nativeProxy {
            if nativeClickCount < 2, !nativeHasDragged,
               hypot(end.x - start.x, end.y - start.y) * owner.scaleFactor < 2 { return }
            nativeHasDragged = true
            if let nativeLayout {
                var gesture = PDFVisualTextDrag(start: start, end: end)
                if let anchor = nativeAnchor {
                    let extent = nativeClickCount >= 3
                        ? proxy.page.selectionForLine(at: end)
                        : proxy.page.selectionForWord(at: end)
                    let first = anchor.bounds(for: proxy.page)
                    let last = extent.map { $0.bounds(for: proxy.page) }.flatMap { $0.isEmpty ? nil : $0 }
                    if !first.isEmpty {
                        let lastPoint = last.map { CGPoint(x: $0.midX, y: $0.midY) } ?? end
                        let sameRow = last.map {
                            min(first.maxY, $0.maxY) - max(first.minY, $0.minY)
                                > min(first.height, $0.height) * 0.35
                        } ?? (lastPoint.y >= first.minY && lastPoint.y <= first.maxY)
                        let forward = sameRow ? lastPoint.x >= first.midX : lastPoint.y < first.midY
                        gesture = PDFVisualTextDrag(
                            start: CGPoint(x: forward ? first.minX : first.maxX, y: first.midY),
                            end: last.map { CGPoint(x: forward ? $0.maxX : $0.minX, y: $0.midY) } ?? end)
                    }
                }
                applyFragments(nativeLayout.fragments(for: gesture))
                return
            }
            var result = proxy.page.selection(from: start, to: end)
            if let anchor = nativeAnchor {
                let extent = nativeClickCount >= 3
                    ? proxy.page.selectionForLine(at: end)
                    : proxy.page.selectionForWord(at: end)
                // Combining selections with add() can retain overlapping text
                // ranges. Build one character range for word/line dragging.
                var combined: NSRange?
                for part in [result, anchor, extent].compactMap({ $0 }) {
                    for index in 0..<part.numberOfTextRanges(on: proxy.page) {
                        let range = part.range(at: index, on: proxy.page)
                        guard range.location != NSNotFound else { continue }
                        combined = combined.map { NSUnionRange($0, range) } ?? range
                    }
                }
                if let combined { result = proxy.page.selection(for: combined) }
            }
            applyNativeSelection(result)
            return
        }
        if visualTextDrag != nil {
            let drag = PDFVisualTextDrag(start: start, end: end)
            visualTextDrag = drag
            if let collapsedLayout, !collapsedLayout.supports(drag) {
                // A native cell elsewhere on this page may be ambiguous. A
                // gesture entering that area must use the ordinary recognizer,
                // never silently skip the excluded source text.
                self.collapsedLayout = nil
                visualLayout = nil
                applyFragments([])
                prepareVisualLayout(for: page)
            }
            if visualLayout != nil {
                applyVisualSelection()
                return
            }
        }
        region = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
            width: max(abs(start.x - end.x), visualTextDrag == nil ? 0 : 1 / owner.scaleFactor),
            height: max(abs(start.y - end.y), visualTextDrag == nil ? 0 : 1 / owner.scaleFactor))
            .intersection(page.bounds(for: .cropBox))
        updateOverlayPath()
    }

    func end(with event: NSEvent) {
        updateDrag(with: event)
        start = nil
        defer { commitSelectionPreview() }
        if nativeProxy != nil {
            if selection == nil { cancel() }
            return
        }
        let textDrag = visualTextDrag
        guard let owner, let state = owner.workspaceState, let page,
              let document = owner.document, document === state.document,
              state.allows(.copyAndPaste),
              let region = region ?? textDrag.map({ _ in page.bounds(for: .cropBox) }), !region.isNull,
              textDrag.map({ hypot($0.end.x - $0.start.x, $0.end.y - $0.start.y) * owner.scaleFactor >= 4 })
                ?? (region.width * owner.scaleFactor >= 4 && region.height * owner.scaleFactor >= 4) else {
            cancel()
            return
        }
        if textDrag != nil {
            if visualLayout != nil {
                applyVisualSelection()
                if selection == nil { cancel() }
            } else {
                state.statusMessage = L10n.string("selection.region_recognizing")
            }
            return
        }
        let id = UUID()
        requestID = id
        let capturedRevision = state.revision
        state.statusMessage = L10n.string("selection.region_recognizing")
        task = Task { [weak self, weak state, weak document, weak page] in
            do {
                // Yield once so the completed rectangle/progress can be drawn.
                await Task.yield()
                try Task.checkCancellation()
                guard let page else { return }
                let recognitionRegion = textDrag?.recognitionRegion(cropBox: page.bounds(for: .cropBox),
                                                                  rotation: page.rotation) ?? region
                let snapshot = try PDFRegionTextRecognizer.snapshot(page: page, region: recognitionRegion)
                let fragments = try await PDFRegionTextRecognizer.recognize(snapshot, textDrag: textDrag)
                try Task.checkCancellation()
                guard let self, self.requestID == id, let state, let document,
                      self.owner?.document === document, state.document === document,
                      state.revision == capturedRevision, state.allows(.copyAndPaste),
                      state.currentSelection == nil,
                      self.owner?.activeTool == .select,
                      document.index(for: page) != NSNotFound,
                      self.owner?.visiblePages.contains(where: { $0 === page }) == true else { return }
                self.task = nil
                self.requestID = nil
                guard !fragments.isEmpty else {
                    self.cancel()
                    state.statusMessage = L10n.string("selection.region_empty")
                    return
                }
                let result = PDFRegionTextSelection(document: document, page: page, fragments: fragments)
                self.selection = result
                self.region = nil
                state.currentSelection = result
                state.statusMessage = L10n.string("selection.region_ready")
                self.refreshOverlay()
            } catch is CancellationError {
                // A newer gesture/navigation owns the current status/selection.
            } catch {
                guard let self, self.requestID == id else { return }
                self.cancel()
                state?.statusMessage = L10n.string("selection.region_failed")
            }
        }
    }

    private func prepareVisualLayout(for page: PDFPage) {
        if let cached = visualCache.first(where: { $0.page === page }) {
            visualLayout = cached.layout
            return
        }
        guard let owner, let state = owner.workspaceState, let document = owner.document else { return }
        let id = UUID()
        requestID = id
        let capturedRevision = state.revision
        task = Task { [weak self, weak state, weak document, weak page] in
            do {
                await Task.yield()
                try Task.checkCancellation()
                guard let page else { return }
                let snapshot = try PDFRegionTextRecognizer.snapshot(page: page, region: page.bounds(for: .cropBox))
                let lines = try await PDFRegionTextRecognizer.recognizeLines(snapshot)
                try Task.checkCancellation()
                guard let self, self.requestID == id, let state, let document,
                      self.page === page, self.owner?.document === document, state.document === document,
                      state.revision == capturedRevision, state.allows(.copyAndPaste),
                      state.currentSelection == nil || state.currentSelection === self.selection,
                      self.owner?.activeTool == .select,
                      document.index(for: page) != NSNotFound,
                      self.owner?.visiblePages.contains(where: { $0 === page }) == true else { return }
                self.task = nil
                self.requestID = nil
                let layout = PDFVisualTextLayout(lines: lines, imageToPage: snapshot.imageToPage)
                self.visualLayout = layout
                self.visualCache.append((page, layout))
                if self.visualCache.count > 4 { self.visualCache.removeFirst() }
                self.applyVisualSelection()
                if !self.isDragging, self.selection == nil {
                    self.cancel()
                    state.statusMessage = L10n.string("selection.region_empty")
                }
            } catch is CancellationError {
                // A newer gesture or document revision owns the selection.
            } catch {
                guard let self, self.requestID == id else { return }
                self.cancel()
                state?.statusMessage = L10n.string("selection.region_failed")
            }
        }
    }

    private func applyVisualSelection() {
        guard let owner, let drag = visualTextDrag, let layout = visualLayout else { return }
        let wasRegion = region != nil
        let previousSelection = selection
        region = nil
        let moved = hypot(drag.end.x - drag.start.x, drag.end.y - drag.start.y) * owner.scaleFactor >= 4
        applyFragments(moved ? layout.fragments(for: drag) : [])
        // applyFragments already updates changed text. Only an unchanged text
        // result needs another refresh when replacing the pending OCR rectangle.
        if wasRegion, selection === previousSelection { updateOverlayPath() }
    }

    private func applyNativeSelection(_ result: PDFSelection?) {
        guard let owner, let proxy = nativeProxy,
              let document = owner.document, let state = owner.workspaceState,
              document === state.document, state.allows(.copyAndPaste) else { return }
        let fragments = result?.selectionsByLine().compactMap { line -> PDFRegionTextFragment? in
            guard let text = line.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return PDFRegionTextFragment(text: text, bounds: line.bounds(for: proxy.page))
        } ?? []
        applyFragments(fragments)
    }

    private func applyFragments(_ fragments: [PDFRegionTextFragment]) {
        guard let owner, let page, let document = owner.document, let state = owner.workspaceState,
              document === state.document, state.allows(.copyAndPaste) else { return }
        // Keep commands reading the live selection, while SwiftUI, plugins and
        // session persistence receive one final notification at mouse-up.
        guard fragments != nativeFragments else { return }
        let adapted = PDFRegionTextSelection(document: document, page: page, fragments: fragments)
        let result = adapted.fragments.isEmpty ? nil : adapted
        if let selectionPreviewID {
            guard state.updateSelectionPreview(result, id: selectionPreviewID) else {
                cancel()
                return
            }
        } else {
            state.currentSelection = result
        }
        nativeFragments = fragments
        selection = result
        if !isDragging { updateSelectionStatus() }
        updateOverlayPath()
    }

    private func commitSelectionPreview() {
        guard let id = selectionPreviewID else { return }
        selectionPreviewID = nil
        if owner?.workspaceState?.commitSelectionPreview(id) == true, selection != nil {
            updateSelectionStatus()
        }
    }

    private func updateSelectionStatus() {
        guard let state = owner?.workspaceState else { return }
        let message = L10n.string(selection == nil ? "status.ready" : "selection.selected")
        if state.statusMessage != message { state.statusMessage = message }
    }

    func cancel() {
        preparationTask?.cancel()
        preparationTask = nil
        preparationPage = nil
        if isActive, let state = owner?.workspaceState,
           state.statusMessage == L10n.string("selection.region_recognizing")
                || state.statusMessage == L10n.string("selection.region_drag") {
            state.statusMessage = L10n.string("status.ready")
        }
        requestID = nil
        task?.cancel()
        task = nil
        if let id = selectionPreviewID {
            owner?.workspaceState?.cancelSelectionPreview(id)
        } else if let selection, owner?.workspaceState?.currentSelection === selection {
            owner?.workspaceState?.currentSelection = nil
        }
        selectionPreviewID = nil
        selection = nil
        page = nil
        start = nil
        region = nil
        visualTextDrag = nil
        visualLayout = nil
        nativeProxy = nil
        nativeLayout = nil
        collapsedLayout = nil
        nativeAnchor = nil
        nativeClickCount = 1
        nativeHasDragged = false
        nativeFragments = []
        overlay.isHidden = true
        overlay.setRectangles([], isRegion: false)
    }

    private func updateOverlayPath() {
        guard let owner, let page else { return }
        let rectangles: [CGRect]
        if let region { rectangles = [region] }
        else { rectangles = selection?.fragments.map(\.bounds) ?? [] }
        overlay.setRectangles(PDFSelectionOverlayGeometry.map(rectangles,
            convertRectangle: { overlay.convert(owner.convert($0, from: page), from: owner) },
            convertPoint: { overlay.convert(owner.convert($0, from: page), from: owner) }
        ), isRegion: region != nil)
    }
}

/// PDFView's page conversion includes rotation, crop origin, zoom and scroll.
/// Sample that affine mapping once per update instead of resolving the PDFKit
/// page layout separately for each line. Nothing is cached across view changes.
enum PDFSelectionOverlayGeometry {
    static func map(_ rectangles: [CGRect], convertRectangle: (CGRect) -> CGRect,
                    convertPoint: (CGPoint) -> CGPoint) -> [CGRect] {
        guard rectangles.count > 2 else { return rectangles.map(convertRectangle) }
        // A wider basis reduces cancellation when a continuous document's
        // scrolled coordinate origin is far from the displayed page.
        let span: CGFloat = 64
        let origin = convertPoint(.zero)
        let horizontal = convertPoint(CGPoint(x: span, y: 0))
        let vertical = convertPoint(CGPoint(x: 0, y: span))
        let transform = CGAffineTransform(a: (horizontal.x - origin.x) / span,
            b: (horizontal.y - origin.y) / span, c: (vertical.x - origin.x) / span,
            d: (vertical.y - origin.y) / span, tx: origin.x, ty: origin.y)
        guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
            .allSatisfy(\.isFinite), transform.a * transform.d - transform.b * transform.c != 0 else {
            return rectangles.map(convertRectangle)
        }
        return rectangles.map { $0.applying(transform) }
    }
}

@MainActor
final class PDFRegionSelectionOverlay: NSView {
    weak var controller: PDFRegionSelectionController?
    private let selectionLayer = CAShapeLayer()
    private var rectangles: [CGRect] = []
    private var isRegion = false
    private var systemColorsObserver: NSObjectProtocol?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        selectionLayer.fillRule = .nonZero
        selectionLayer.lineWidth = 1
        layer?.addSublayer(selectionLayer)
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
        updateColors()
        systemColorsObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateColors() }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let systemColorsObserver { NotificationCenter.default.removeObserver(systemColorsObserver) }
    }

    func setRectangles(_ rectangles: [CGRect], isRegion: Bool) {
        let scale = window?.backingScaleFactor ?? 2
        guard rectangles != self.rectangles || isRegion != self.isRegion
            || selectionLayer.frame != bounds || selectionLayer.contentsScale != scale else { return }
        let changedRegionMode = isRegion != self.isRegion
        self.rectangles = rectangles
        self.isRegion = isRegion
        let path = CGMutablePath()
        for rect in rectangles { path.addRect(rect) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.frame = bounds
        selectionLayer.contentsScale = scale
        selectionLayer.path = path
        if changedRegionMode { updateColors() }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selectionLayer.fillColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.25).cgColor
            selectionLayer.strokeColor = isRegion ? NSColor.controlAccentColor.cgColor : nil
        }
        CATransaction.commit()
    }
}
