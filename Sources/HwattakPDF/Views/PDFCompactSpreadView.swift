// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import SwiftUI

/// Communication between a native, fully interactive paged PDFView and its
/// continuous scroller. Both retain the original page/selection identities.
@MainActor
final class PDFCompactSpreadContext {
    let pageIndex: Int
    var scaleFactor: CGFloat
    weak var host: PDFCompactSpreadHostView?

    init(pageIndex: Int, scaleFactor: CGFloat, host: PDFCompactSpreadHostView) {
        self.pageIndex = pageIndex
        self.scaleFactor = scaleFactor
        self.host = host
    }

    func contains(page: PDFPage) -> Bool {
        guard let document = host?.workspace?.document, page.document === document else { return false }
        let index = document.index(for: page)
        return contains(pageIndex: index)
    }

    func contains(pageIndex index: Int) -> Bool { index >= pageIndex && index < pageIndex + 2 }
    func reveal(_ rect: CGRect, on page: PDFPage) {
        DispatchQueue.main.async { [weak self, weak page] in
            guard let self, let page, self.contains(page: page) else { return }
            self.host?.reveal(rect, on: page)
        }
    }
    func activate(page: PDFPage) { host?.activate(page: page) }
    func navigate(to pageIndex: Int) { host?.navigate(to: pageIndex) }
    func zoom(by factor: CGFloat) { host?.zoom(by: factor) }
    func scroll(with event: NSEvent) { host?.scroll(with: event) }
    func keyDown(with event: NSEvent) -> Bool { host?.handleKeyDown(event) ?? false }
    func scrollForArrow(keyCode: UInt16) -> Bool { host?.scrollForArrow(keyCode: keyCode) ?? false }
    func claimSearchReveal(_ selection: PDFSelection) -> Bool { host?.claimSearchReveal(selection) ?? false }
    func commitOtherInlineDraft() {
        guard let index = host?.workspace?.pendingInlineTextEdit?.pageIndex,
              !contains(pageIndex: index) else { return }
        host?.nativePDFView(forPageIndex: index)?.commitInlineTextEditorBeforePointerAction()
    }
}

@MainActor
struct PDFCompactSpreadView: NSViewRepresentable {
    @ObservedObject var workspace: PDFWorkspaceState
    var onScrollActivity: ((PDFVerticalScrollMetrics) -> Void)?
    @EmberTheme private var theme

    func makeNSView(context: Context) -> PDFCompactSpreadHostView {
        PDFCompactSpreadHostView(frame: .zero)
    }

    func updateNSView(_ view: PDFCompactSpreadHostView, context: Context) {
        view.update(workspace: workspace, canvasColor: NSColor(theme.canvas), onScrollActivity: onScrollActivity)
    }

    static func dismantleNSView(_ view: PDFCompactSpreadHostView, coordinator: ()) {
        view.tearDown()
    }
}

@MainActor
private final class PDFCompactSpreadCanvas: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class PDFCompactSpreadHostView: NSView {
    private struct MountedRow {
        let context: PDFCompactSpreadContext
        let view: NSHostingView<PDFKitViewer>
    }
    private struct ReadingAnchor {
        let row: Int
        let fraction: CGFloat
        let horizontal: CGFloat
    }

    private(set) weak var workspace: PDFWorkspaceState?
    let scrollView = NSScrollView()
    private let canvas = PDFCompactSpreadCanvas()
    private var mounted: [Int: MountedRow] = [:]
    private(set) var geometry = PDFCompactSpreadGeometry(pageSizes: [], viewport: .zero)
    private var pageSizes: [CGSize] = []
    private weak var document: PDFDocument?
    private var revision: UUID?
    private var viewportSize = CGSize.zero
    private var fitMode: PDFPageFitMode?
    private var relativeZoom: CGFloat = 1
    private var lastReportedPageIndex: Int?
    private var isApplyingLayout = false
    private var isUpdatingModel = false
    private var updateScheduled = false
    private var pendingPersistence: DispatchWorkItem?
    private var pendingRestoration: PDFViewerViewportState?
    private var boundsObserver: NSObjectProtocol?
    private var onScrollActivity: ((PDFVerticalScrollMetrics) -> Void)?
    private var lastActivityTime: TimeInterval = 0
    private var tornDown = false
    private weak var lastRevealedSearchSelection: PDFSelection?
    private var modifiedScrollGesture = PDFViewportModifiedScrollGestureLatch()
    private var modifiedScrollReset: DispatchWorkItem?

    var materializedRowCount: Int { mounted.count }
    var materializedPageIndices: [Int] { mounted.keys.sorted().map { $0 * 2 } }
    func context(forPageIndex index: Int) -> PDFCompactSpreadContext? { mounted[index / 2]?.context }
    func nativePDFView(forPageIndex index: Int) -> InteractivePDFView? {
        mounted[index / 2].flatMap { nativeView(in: $0.view) }
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.documentView = canvas
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.boundsChanged() }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        pendingPersistence?.cancel()
        modifiedScrollReset?.cancel()
    }

    func update(workspace: PDFWorkspaceState, canvasColor: NSColor,
                onScrollActivity: ((PDFVerticalScrollMetrics) -> Void)?) {
        guard !tornDown else { return }
        self.onScrollActivity = onScrollActivity
        scrollView.backgroundColor = canvasColor
        let changedDocument = self.document !== workspace.document || self.workspace !== workspace
        self.workspace = workspace
        if changedDocument {
            removeAllRows()
            document = workspace.document
            revision = nil
            lastReportedPageIndex = workspace.currentPageIndex
            pendingRestoration = workspace.pdfViewportState
            relativeZoom = 1
            lastRevealedSearchSelection = nil
        }
        if workspace.activeSearchSelection == nil { lastRevealedSearchSelection = nil }
        let changedGeometry = revision != workspace.revision
        if changedGeometry {
            revision = workspace.revision
            pageSizes = (0..<(document?.pageCount ?? 0)).compactMap { index in
                guard let page = document?.page(at: index) else { return nil }
                let size = page.bounds(for: .cropBox).size
                return abs(page.rotation % 180) == 90 ? CGSize(width: size.height, height: size.width) : size
            }
        }
        let changedFit = fitMode != workspace.pageFitMode
        if changedFit {
            fitMode = workspace.pageFitMode
            relativeZoom = 1
        }
        if changedDocument || changedGeometry || changedFit || geometry.rows.isEmpty {
            rebuildLayout(preservingAnchor: !changedDocument)
        }
        if !isUpdatingModel, !changedDocument, lastReportedPageIndex != workspace.currentPageIndex {
            navigate(to: workspace.currentPageIndex)
        }
        scheduleUpdate()
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        scrollView.tile()
        let size = scrollView.contentView.bounds.size
        if size.width > 1, size.height > 1, size != viewportSize {
            rebuildLayout(preservingAnchor: viewportSize != .zero)
        }
    }

    private func readingAnchor() -> ReadingAnchor? {
        let visible = scrollView.contentView.bounds
        guard let index = geometry.rowIndex(at: visible.midY) else { return nil }
        let row = geometry.rows[index]
        return ReadingAnchor(row: index, fraction: (visible.midY - row.frame.minY) / max(1, row.frame.height),
                             horizontal: visible.midX / max(1, geometry.contentSize.width))
    }

    private func rebuildLayout(preservingAnchor: Bool) {
        guard !isApplyingLayout, let workspace, bounds.width > 1, bounds.height > 1 else { return }
        let anchor = preservingAnchor ? readingAnchor() : nil
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        scrollView.frame = bounds
        scrollView.tile()
        viewportSize = scrollView.contentView.bounds.size
        if fitMode == nil, let restore = pendingRestoration, !restore.autoScales, let savedScale = restore.scaleFactor,
           !pageSizes.isEmpty {
            let initial = PDFCompactSpreadGeometry(pageSizes: pageSizes, viewport: viewportSize, fitMode: fitMode)
            let row = min(initial.rows.count - 1, max(0, workspace.currentPageIndex / 2))
            relativeZoom = savedScale / initial.rows[row].scale
        }
        geometry = PDFCompactSpreadGeometry(pageSizes: pageSizes, viewport: viewportSize,
                                            zoom: relativeZoom, fitMode: fitMode)
        canvas.frame = CGRect(origin: .zero, size: geometry.contentSize)
        if let restore = pendingRestoration {
            pendingRestoration = nil
            if restore.usesCompactSpreads, let progress = restore.scrollProgress(forPageIndex: workspace.currentPageIndex) {
                setOrigin(progress.boundsOrigin(documentFrame: canvas.frame, viewportSize: viewportSize))
            } else {
                scrollToPage(workspace.currentPageIndex)
            }
        } else if let anchor, geometry.rows.indices.contains(anchor.row) {
            let row = geometry.rows[anchor.row]
            setOrigin(CGPoint(x: anchor.horizontal * geometry.contentSize.width - viewportSize.width / 2,
                              y: row.frame.minY + row.frame.height * anchor.fraction - viewportSize.height / 2))
        } else { scrollToPage(workspace.currentPageIndex) }
        updateMountedRows()
        persistViewport()
    }

    private func scheduleUpdate() {
        guard !updateScheduled, !tornDown else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            guard !self.tornDown else { return }
            self.updateMountedRows()
        }
    }

    private func updateMountedRows() {
        guard let workspace, !geometry.rows.isEmpty, !tornDown else { return }
        var needed = Set(geometry.materializedRows(in: scrollView.contentView.bounds))
        if let page = workspace.pendingTextEdit?.pageIndex { needed.insert(page / 2) }
        if let page = workspace.pendingInlineTextEdit?.pageIndex { needed.insert(page / 2) }
        for (index, row) in mounted {
            if let native = nativeView(in: row.view), native.isDrawingInkStroke { needed.insert(index) }
            if let responder = window?.firstResponder as? NSView,
               let native = nativeView(in: row.view),
               PDFKitViewer.Coordinator.responder(responder, belongsTo: native) { needed.insert(index) }
        }
        for index in mounted.keys where !needed.contains(index) {
            if let row = mounted.removeValue(forKey: index) {
                row.context.host = nil
                row.view.removeFromSuperview()
            }
        }
        for index in needed.sorted() where geometry.rows.indices.contains(index) {
            let item = geometry.rows[index]
            if let row = mounted[index] {
                let changed = abs(row.context.scaleFactor - item.scale) > 0.0001 || row.view.frame != item.frame
                row.context.scaleFactor = item.scale
                row.view.frame = item.frame
                if changed { row.view.rootView = PDFKitViewer(workspace: workspace, compactSpread: row.context) }
            } else {
                let context = PDFCompactSpreadContext(pageIndex: item.pageIndex, scaleFactor: item.scale, host: self)
                let view = NSHostingView(rootView: PDFKitViewer(workspace: workspace, compactSpread: context))
                view.sizingOptions = []
                view.frame = item.frame
                mounted[index] = MountedRow(context: context, view: view)
                canvas.addSubview(view)
            }
        }
    }

    private func boundsChanged() {
        guard !isApplyingLayout, !tornDown else { return }
        scheduleUpdate()
        if let workspace, let index = geometry.rowIndex(at: scrollView.contentView.bounds.midY) {
            let row = geometry.rows[index]
            // Retain an explicitly selected right page while its spread stays
            // current; the native paged view otherwise reports its left page.
            if workspace.currentPageIndex / 2 != index {
                isUpdatingModel = true
                lastReportedPageIndex = row.pageIndex
                workspace.setCurrentPage(row.pageIndex)
                isUpdatingModel = false
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastActivityTime >= PDFLiveScrollReportingPolicy.minimumInterval {
            lastActivityTime = now
            onScrollActivity?(PDFVerticalScrollMetrics.physical(documentFrame: canvas.frame,
                visibleRect: scrollView.contentView.bounds, isDocumentFlipped: true))
        }
        pendingPersistence?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistViewport() }
        pendingPersistence = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func navigate(to pageIndex: Int) {
        guard let workspace, let document, pageIndex >= 0, pageIndex < document.pageCount else { return }
        let previousFocusedNative = mounted.values.compactMap { row -> InteractivePDFView? in
            guard let responder = window?.firstResponder, let native = nativeView(in: row.view) else { return nil }
            return PDFKitViewer.Coordinator.responder(responder, belongsTo: native) ? native : nil
        }.first
        isApplyingLayout = true
        lastReportedPageIndex = pageIndex
        if workspace.currentPageIndex != pageIndex { workspace.setCurrentPage(pageIndex) }
        scrollToPage(pageIndex)
        updateMountedRows()
        isApplyingLayout = false
        DispatchQueue.main.async { [weak self, weak previousFocusedNative] in
            guard let previousFocusedNative, !previousFocusedNative.arrowKeyRepeater.isRepeating,
                  let self, let view = self.nativePDFView(forPageIndex: pageIndex),
                  self.workspace?.currentPageIndex == pageIndex else { return }
            self.window?.makeFirstResponder(view)
            self.scheduleUpdate()
        }
        persistViewport()
    }

    func claimSearchReveal(_ selection: PDFSelection) -> Bool {
        guard lastRevealedSearchSelection !== selection else { return false }
        lastRevealedSearchSelection = selection
        return true
    }

    func activate(page: PDFPage) {
        guard let document, let workspace, page.document === document else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        lastReportedPageIndex = index
        if workspace.currentPageIndex != index {
            isUpdatingModel = true
            workspace.setCurrentPage(index)
            isUpdatingModel = false
        }
    }

    private func scrollToPage(_ pageIndex: Int) {
        guard geometry.rows.indices.contains(pageIndex / 2) else { return }
        let row = geometry.rows[pageIndex / 2]
        setOrigin(CGPoint(x: max(0, row.frame.midX - viewportSize.width / 2),
                          y: row.frame.minY - max(0, (viewportSize.height - row.frame.height) / 2)))
    }

    func reveal(_ rect: CGRect, on page: PDFPage) {
        guard let document, page.document === document else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return }
        if mounted[pageIndex / 2] == nil { navigate(to: pageIndex) }
        guard let row = mounted[pageIndex / 2] else { return }
        row.view.layoutSubtreeIfNeeded()
        guard let pdfView = nativeView(in: row.view) else { return }
        let hit = canvas.convert(pdfView.convert(rect, from: page), from: pdfView)
        guard hit.midX.isFinite, hit.midY.isFinite else { return }
        isApplyingLayout = true
        lastReportedPageIndex = pageIndex
        workspace?.setCurrentPage(pageIndex)
        setOrigin(CGPoint(x: hit.midX - viewportSize.width / 2, y: hit.midY - viewportSize.height / 2))
        updateMountedRows()
        isApplyingLayout = false
        persistViewport()
    }

    private func nativeView(in view: NSView) -> InteractivePDFView? {
        if let native = view as? InteractivePDFView { return native }
        return view.subviews.lazy.compactMap { self.nativeView(in: $0) }.first
    }

    func zoom(by factor: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        if fitMode != nil {
            let oldGeometry = geometry
            workspace?.endPageFitForManualZoom()
            fitMode = nil
            let widthFit = PDFCompactSpreadGeometry(pageSizes: pageSizes, viewport: viewportSize)
            if let index = oldGeometry.rowIndex(at: scrollView.contentView.bounds.midY), widthFit.rows.indices.contains(index) {
                relativeZoom = oldGeometry.rows[index].scale / widthFit.rows[index].scale
            }
        }
        relativeZoom = min(8, max(0.25, relativeZoom * factor))
        rebuildLayout(preservingAnchor: true)
    }

    func scroll(with event: NSEvent) {
        let modifier = PDFWheelZoomModifier(rawValue: UserDefaults.standard.string(forKey: PDFWheelZoomModifier.defaultsKey) ?? "") ?? .defaultValue
        let intent = PDFViewportScrollIntentResolver.resolve(
            PDFViewportScrollInput(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                   hasPreciseDeltas: event.hasPreciseScrollingDeltas,
                                   modifiers: InteractivePDFView.viewportModifiers(from: event.modifierFlags)),
            zoomModifier: modifier
        )
        let owner = modifiedScrollGesture.ownerForEvent(intent: intent,
            touchPhasePresent: !event.phase.isEmpty,
            touchPhaseBegan: event.phase.contains(.began) || event.phase.contains(.mayBegin),
            momentumPhasePresent: !event.momentumPhase.isEmpty)
        switch owner {
        case .zoom:
            // A released modifier must not turn the momentum tail into a
            // document scroll or keep magnifying after the fingers lift.
            if event.momentumPhase.isEmpty, case .zoom(let factor) = intent { zoom(by: factor) }
        case .horizontalPan:
            if let delta = PDFViewportScrollIntentResolver.horizontalPanDelta(
                deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                hasPreciseDeltas: event.hasPreciseScrollingDeltas) {
                var origin = scrollView.contentView.bounds.origin
                origin.x -= delta
                setOrigin(origin)
            }
        case nil: scrollView.scrollWheel(with: event)
        }
        modifiedScrollReset?.cancel()
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
            modifiedScrollGesture.reset()
            modifiedScrollReset = nil
        } else if owner != nil {
            if event.phase.contains(.ended) { modifiedScrollGesture.touchEnded() }
            let delay = event.phase.contains(.ended) ? 0.28 : (event.phase.isEmpty && event.momentumPhase.isEmpty ? 0.16 : 0.6)
            let reset = DispatchWorkItem { [weak self] in self?.modifiedScrollGesture.reset() }
            modifiedScrollReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: reset)
        }
    }

    override func scrollWheel(with event: NSEvent) { scroll(with: event) }
    override func magnify(with event: NSEvent) { zoom(by: max(0.1, 1 + event.magnification)) }
    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) { super.keyDown(with: event) }
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let workspace, event.type == .keyDown else { return false }
        guard event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty else { return false }
        switch event.keyCode {
        case 115: navigate(to: 0)
        case 119: navigate(to: max(0, workspace.pageCount - 1))
        case 116, 121:
            var origin = scrollView.contentView.bounds.origin
            origin.y += viewportSize.height * 0.9 * (event.keyCode == 121 ? 1 : -1)
            setOrigin(origin)
        default: return false
        }
        return true
    }

    func scrollForArrow(keyCode: UInt16) -> Bool {
        var origin = scrollView.contentView.bounds.origin
        switch keyCode {
        case 123: origin.x -= 40
        case 124: origin.x += 40
        case 125: origin.y += 40
        case 126: origin.y -= 40
        default: return false
        }
        setOrigin(origin)
        return true
    }

    private func setOrigin(_ origin: CGPoint) {
        let clip = scrollView.contentView
        var proposed = clip.bounds
        proposed.origin = origin
        clip.setBoundsOrigin(clip.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func persistViewport() {
        pendingPersistence?.cancel()
        pendingPersistence = nil
        guard let workspace, !geometry.rows.isEmpty else { return }
        let index = min(geometry.rows.count - 1, max(0, workspace.currentPageIndex / 2))
        let progress = PDFScrollProgress.progress(boundsOrigin: scrollView.contentView.bounds.origin,
            documentFrame: canvas.frame, viewportSize: scrollView.contentView.bounds.size)
        workspace.recordPDFViewport(autoScales: abs(relativeZoom - 1) < 0.0001 && fitMode == nil,
                                    scaleFactor: geometry.rows[index].scale, scrollProgress: progress,
                                    usesCompactSpreads: true)
    }

    private func removeAllRows() {
        for row in mounted.values { row.context.host = nil; row.view.removeFromSuperview() }
        mounted.removeAll()
    }

    func tearDown() {
        guard !tornDown else { return }
        persistViewport()
        tornDown = true
        pendingPersistence?.cancel()
        pendingPersistence = nil
        modifiedScrollReset?.cancel()
        modifiedScrollReset = nil
        modifiedScrollGesture.reset()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        removeAllRows()
        workspace = nil
        document = nil
    }
}
