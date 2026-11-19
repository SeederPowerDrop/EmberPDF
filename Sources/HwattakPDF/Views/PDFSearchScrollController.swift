// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit

/// Value-only search geometry. No PDFSelection or PDFPage graph is retained.
struct PDFSearchHitGeometry {
    let id: UUID
    let pageIndex: Int
    let lineRects: [CGRect]

    static func resolve(_ result: PDFSearchResult, in document: PDFDocument) -> Self? {
        guard result.pageIndex >= 0, result.pageIndex < document.pageCount,
              let page = document.page(at: result.pageIndex) else { return nil }
        let range = result.sourceRange
        let count = page.numberOfCharacters
        guard range.location >= 0, range.location <= count, range.length > 0,
              range.length <= count - range.location else { return nil }
        let crop = page.bounds(for: .cropBox)
        let media = page.bounds(for: .mediaBox)
        guard usable(crop), let selection = page.selection(for: range) else { return nil }
        let rects = selection.selectionsByLine().prefix(32).compactMap { line -> CGRect? in
            let rect = line.bounds(for: page)
            // Corrupt font metrics must not create page-sized decorations.
            guard usable(rect), rect.width <= max(crop.width, media.width) * 1.1,
                  rect.height <= max(crop.height, media.height) * 1.1 else { return nil }
            let clipped = rect.intersection(crop)
            return usable(clipped) ? clipped : nil
        }
        guard !rects.isEmpty else { return nil }
        return Self(id: result.id, pageIndex: result.pageIndex, lineRects: rects)
    }

    private static func usable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }
}

/// Search-only visual assistance. Native scrollers, text selection and PDF
/// bytes remain owned by PDFKit. Only a settled user scroll may move the clip.
@MainActor
final class PDFSearchScrollController {
    private weak var owner: InteractivePDFView?
    private let isWindowActive: @MainActor (NSWindow) -> Bool
    private weak var workspace: PDFWorkspaceState?
    private weak var document: PDFDocument?
    private var revision: UUID?
    private let overlay = PDFSearchLocationOverlay(frame: .zero)
    private var subscription: AnyCancellable?
    private var results: [PDFSearchResult] = []
    private var hits: [PDFSearchHitGeometry] = []
    private var hitsByPage: [Int: [PDFSearchHitGeometry]] = [:]
    private var processedCount = 0
    private var geometryTask: Task<Void, Never>?
    private var generation = UUID()
    private var markerProgressByID: [UUID: CGFloat] = [:]
    private var markersDirty = true
    private var markerTrackLength: CGFloat = 0
    private var pageTransforms: [Int: CGAffineTransform] = [:]
    private var stamp: LayoutStamp?
    private weak var scrollView: NSScrollView?
    private var scrollObservers: [NSObjectProtocol] = []
    private var lifetimeObservers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var refreshScheduled = false
    private var isRefreshing = false
    private var pendingSnap: DispatchWorkItem?
    private var snapTimer: Timer?
    private var isSnapping = false
    private var gestureActive = false
    private var gestureMoved = false
    private var gestureWasFast = false
    private var touchScrolling = false
    private var momentumScrolling = false
    private var lastInputTime: TimeInterval = 0
    private var lastScrollTime: TimeInterval?
    private var lastScrollOrigin: CGPoint?
    private var lastSnappedID: UUID?
    private var lastSnappedOrigin: CGPoint?

    private struct LayoutStamp: Equatable {
        let documentView: ObjectIdentifier
        let bounds: CGRect
        let viewportSize: CGSize
        let scale: CGFloat
        let mode: PDFDisplayMode
        let direction: PDFDisplayDirection
        let page: Int
    }

    init(
        owner: InteractivePDFView,
        isWindowActive: @escaping @MainActor (NSWindow) -> Bool = { $0.isKeyWindow && NSApp.isActive }
    ) {
        self.owner = owner
        self.isWindowActive = isWindowActive
    }

    deinit {
        subscription?.cancel()
        geometryTask?.cancel()
        pendingSnap?.cancel()
        snapTimer?.invalidate()
        for observer in scrollObservers + lifetimeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    func synchronize(with workspace: PDFWorkspaceState) {
        if self.workspace !== workspace {
            detach()
            self.workspace = workspace
            subscription = workspace.$searchNavigatorResults.sink { [weak self] results in
                MainActor.assumeIsolated { self?.receive(results) }
            }
            installInputObservation()
        }
        refreshLayout()
    }

    func detach() {
        cancelMotion()
        geometryTask?.cancel()
        geometryTask = nil
        generation = UUID()
        subscription?.cancel()
        subscription = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        for observer in scrollObservers + lifetimeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        scrollObservers.removeAll()
        lifetimeObservers.removeAll()
        scrollView = nil
        document = nil
        workspace = nil
        results.removeAll()
        clearGeometry()
        overlay.removeFromSuperview()
    }

    /// State application, new input and focus changes also interrupt an
    /// in-flight easing step. They never wait for its animation to finish.
    func cancelMotion() {
        pendingSnap?.cancel()
        pendingSnap = nil
        snapTimer?.invalidate()
        snapTimer = nil
        isSnapping = false
        gestureActive = false
        gestureMoved = false
        gestureWasFast = false
        touchScrolling = false
        momentumScrolling = false
        lastScrollTime = nil
        lastScrollOrigin = nil
    }

    private func receive(_ incoming: [PDFSearchResult]) {
        // Compact rows share one document. Resolve geometry only for this
        // spread; scanning the entire search result set per row wastes work.
        let updated = owner?.compactSpread.map { spread in
            incoming.filter { spread.contains(pageIndex: $0.pageIndex) }
        } ?? incoming
        let appended = updated.count >= results.count
            && updated.first?.id == results.first?.id
            && (results.isEmpty || updated[results.count - 1].id == results.last?.id)
        results = updated
        if !appended || updated.isEmpty {
            cancelMotion()
            clearGeometry()
        }
        requestRefresh()
    }

    private func clearGeometry() {
        generation = UUID()
        geometryTask?.cancel()
        geometryTask = nil
        processedCount = 0
        hits.removeAll()
        hitsByPage.removeAll()
        markerProgressByID.removeAll()
        markersDirty = true
        pageTransforms.removeAll()
        stamp = nil
        lastSnappedID = nil
        lastSnappedOrigin = nil
        overlay.matchRects = []
        overlay.markerProgresses = []
        overlay.activeMarkerProgress = nil
        overlay.isHidden = true
    }

    func refreshLayout() {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let owner, let workspace else { return }
        if document !== owner.document || revision != workspace.revision {
            cancelMotion()
            clearGeometry()
            document = owner.document
            revision = workspace.revision
        }
        guard owner.document === workspace.document, let document,
              !results.isEmpty, let scroll = owner.firstDocumentScrollView(),
              let documentView = scroll.documentView else {
            overlay.isHidden = true
            return
        }
        bindScrollView(scroll)
        positionOverlay(over: scroll)
        overlay.frame = owner.bounds
        overlay.isHidden = false
        overlay.contentClip = overlay.convert(scroll.contentView.bounds, from: scroll.contentView)
        let axis: PDFSearchScrollAxis = owner.displayDirection == .horizontal
            && scroll.hasHorizontalScroller ? .horizontal : .vertical
        overlay.markerAxis = axis
        overlay.markerTrack = markerTrack(in: scroll, axis: axis)
        let continuous = owner.displayMode == .singlePageContinuous || owner.displayMode == .twoUpContinuous
        let newStamp = LayoutStamp(
            documentView: ObjectIdentifier(documentView), bounds: documentView.bounds,
            viewportSize: scroll.contentView.bounds.size, scale: owner.scaleFactor,
            mode: owner.displayMode, direction: owner.displayDirection,
            page: continuous ? -1 : owner.currentPage.map { document.index(for: $0) } ?? -1
        )
        if newStamp != stamp {
            cancelMotion()
            stamp = newStamp
            pageTransforms.removeAll()
            markerProgressByID.removeAll()
            markersDirty = true
            for hit in hits { projectMarker(hit) }
        }
        updatePresentation()
        buildGeometryIfNeeded()
    }

    private func positionOverlay(over scroll: NSScrollView) {
        guard let owner else { return }
        var backing: NSView = scroll
        while let parent = backing.superview, parent !== owner { backing = parent }
        guard backing.superview === owner else { return }
        let backingIndex = owner.subviews.firstIndex { $0 === backing }
        let overlayIndex = owner.subviews.firstIndex { $0 === overlay }
        if overlay.superview !== owner || overlayIndex != backingIndex.map({ $0 + 1 }) {
            owner.addSubview(overlay, positioned: .above, relativeTo: backing)
        }
    }

    private func buildGeometryIfNeeded() {
        guard geometryTask == nil, processedCount < results.count,
              let document, document === workspace?.document else { return }
        let token = generation
        geometryTask = Task { @MainActor [weak self, weak document] in
            var lastPaint = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                guard let self, let document, self.generation == token,
                      self.document === document else { return }
                let end = min(self.results.count, self.processedCount + 96)
                while self.processedCount < end {
                    let result = self.results[self.processedCount]
                    self.processedCount += 1
                    if let hit = PDFSearchHitGeometry.resolve(result, in: document) {
                        self.hits.append(hit)
                        self.hitsByPage[hit.pageIndex, default: []].append(hit)
                        self.projectMarker(hit)
                    }
                }
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPaint > 0.08 || self.processedCount == self.results.count {
                    self.updatePresentation()
                    lastPaint = now
                }
                if self.processedCount == self.results.count {
                    self.geometryTask = nil
                    return
                }
                await Task.yield()
            }
        }
    }

    private func transform(for pageIndex: Int) -> CGAffineTransform? {
        if let cached = pageTransforms[pageIndex] { return cached }
        guard let owner, let page = document?.page(at: pageIndex),
              let documentView = scrollView?.documentView else { return nil }
        if owner.displayMode == .singlePage || owner.displayMode == .twoUp,
           !owner.visiblePages.contains(where: { $0 === page }) { return nil }
        func point(_ value: CGPoint) -> CGPoint {
            documentView.convert(owner.convert(value, from: page), from: owner)
        }
        let p = point(.zero), x = point(CGPoint(x: 1, y: 0)), y = point(CGPoint(x: 0, y: 1))
        let transform = CGAffineTransform(a: x.x - p.x, b: x.y - p.y,
                                          c: y.x - p.x, d: y.y - p.y, tx: p.x, ty: p.y)
        guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
            .allSatisfy(\.isFinite) else { return nil }
        pageTransforms[pageIndex] = transform
        return transform
    }

    private func projectMarker(_ hit: PDFSearchHitGeometry) {
        guard let rect = hit.lineRects.first, let transform = transform(for: hit.pageIndex),
              let documentView = scrollView?.documentView else { return }
        let point = CGPoint(x: rect.midX, y: rect.midY).applying(transform)
        markersDirty = true
        markerProgressByID[hit.id] = PDFSearchScrollPolicy.markerProgress(
            point: point, documentBounds: documentView.bounds, axis: overlay.markerAxis,
            isFlipped: documentView.isFlipped
        )
    }

    private func updatePresentation() {
        guard let owner, let document, let scroll = scrollView else { return }
        var rectangles: [CGRect] = []
        for page in owner.visiblePages {
            let index = document.index(for: page)
            for hit in hitsByPage[index] ?? [] {
                for rect in hit.lineRects {
                    let converted = overlay.convert(owner.convert(rect, from: page), from: owner)
                    if converted.intersects(overlay.contentClip) { rectangles.append(converted) }
                    if rectangles.count >= 600 { break }
                }
                if rectangles.count >= 600 { break }
            }
            if rectangles.count >= 600 { break }
        }
        overlay.matchRects = rectangles
        let length = overlay.markerAxis == .vertical ? overlay.markerTrack.height : overlay.markerTrack.width
        if markersDirty || markerTrackLength != length {
            overlay.markerProgresses = PDFSearchScrollPolicy.mergeMarkerProgresses(
                Array(markerProgressByID.values), trackLength: length
            )
            markersDirty = false
            markerTrackLength = length
        }
        if let index = workspace?.searchResultIndex, results.indices.contains(index) {
            overlay.activeMarkerProgress = markerProgressByID[results[index].id]
        } else { overlay.activeMarkerProgress = nil }
        overlay.contentClip = overlay.convert(scroll.contentView.bounds, from: scroll.contentView)
    }

    private func markerTrack(in scroll: NSScrollView, axis: PDFSearchScrollAxis) -> CGRect {
        let scroller = axis == .vertical ? scroll.verticalScroller : scroll.horizontalScroller
        if let scroller {
            let slot = scroller.rect(for: .knobSlot)
            let rect = overlay.convert(slot, from: scroller)
            if !rect.isEmpty, !rect.isInfinite, rect.intersects(overlay.bounds) {
                // Keep the middle of the thumb available for native dragging.
                return axis == .vertical
                    ? CGRect(x: rect.maxX - 5, y: rect.minY, width: 5, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.maxY - 5, width: rect.width, height: 5)
            }
        }
        let visible = overlay.convert(scroll.bounds, from: scroll)
        return axis == .vertical
            ? CGRect(x: visible.maxX - 6, y: visible.minY + 4, width: 5, height: max(1, visible.height - 8))
            : CGRect(x: visible.minX + 4, y: visible.maxY - 6, width: max(1, visible.width - 8), height: 5)
    }

    private func bindScrollView(_ scroll: NSScrollView) {
        guard scrollView !== scroll else { return }
        cancelMotion()
        for observer in scrollObservers { NotificationCenter.default.removeObserver(observer) }
        scrollObservers.removeAll()
        scrollView = scroll
        stamp = nil
        let center = NotificationCenter.default
        scroll.contentView.postsBoundsChangedNotifications = true
        func observe(_ name: Notification.Name, object: AnyObject, _ action: @escaping () -> Void) {
            scrollObservers.append(center.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            })
        }
        observe(NSView.boundsDidChangeNotification, object: scroll.contentView) { [weak self] in
            guard let self else { return }
            self.requestRefresh()
            if self.gestureActive, !self.isSnapping,
               ProcessInfo.processInfo.systemUptime - self.lastInputTime < 0.4 {
                self.recordScrollMovement()
            }
        }
        observe(NSScrollView.willStartLiveScrollNotification, object: scroll) { [weak self] in
            self?.beginGesture()
        }
        observe(NSScrollView.didLiveScrollNotification, object: scroll) { [weak self] in
            guard let self, !self.isSnapping else { return }
            if !self.gestureActive { self.beginGesture() }
            self.lastInputTime = ProcessInfo.processInfo.systemUptime
            self.recordScrollMovement()
        }
        observe(NSScrollView.didEndLiveScrollNotification, object: scroll) { [weak self] in
            self?.touchScrolling = false
            self?.momentumScrolling = false
            self?.scheduleSnap()
        }
    }

    private func requestRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshLayout()
        }
    }

    private func installInputObservation() {
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            lifetimeObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.cancelMotion() } })
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .leftMouseUp, .keyDown, .magnify, .smartMagnify]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.observeInput(event) }
            return event
        }
    }

    private func observeInput(_ event: NSEvent) {
        guard let owner, let window = owner.window, event.window === window,
              Self.acceptsInput(at: event.locationInWindow, in: window, owner: owner)
        else { cancelMotion(); return }
        if event.type == .leftMouseUp { if gestureActive { scheduleSnap() }; return }
        if event.type == .scrollWheel {
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                cancelMotion(); return
            }
            if !gestureActive { beginGesture() }
            if event.phase.contains(.began) || event.phase.contains(.changed) { touchScrolling = true }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { touchScrolling = false }
            if event.momentumPhase.contains(.began) || event.momentumPhase.contains(.changed) { momentumScrolling = true }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { momentumScrolling = false }
            pendingSnap?.cancel()
            snapTimer?.invalidate()
            snapTimer = nil
            isSnapping = false
            lastInputTime = ProcessInfo.processInfo.systemUptime
            let delta = max(abs(event.scrollingDeltaX), abs(event.scrollingDeltaY))
            if delta * (event.hasPreciseScrollingDeltas ? 1 : 10) > 48 { gestureWasFast = true }
            scheduleSnap()
        } else {
            cancelMotion()
        }
    }

    /// A gallery can retain the PDFView at zero opacity to preserve its exact
    /// viewport. Native event monitors bypass SwiftUI's disabled/hit-test
    /// modifiers, so both effective visibility and the actual hit owner matter.
    static func acceptsInput(at windowPoint: CGPoint, in window: NSWindow, owner: NSView) -> Bool {
        guard owner.window === window, isEffectivelyVisible(owner),
              owner.bounds.contains(owner.convert(windowPoint, from: nil)),
              let hit = window.contentView?.hitTest(windowPoint) else { return false }
        return hit === owner || hit.isDescendant(of: owner)
    }

    private static func isEffectivelyVisible(_ view: NSView) -> Bool {
        guard !view.visibleRect.isEmpty else { return false }
        var ancestor: NSView? = view
        while let current = ancestor {
            if current.isHidden || current.alphaValue <= 0.01 {
                return false
            }
            if let layer = current.layer, layer.opacity <= 0.01 {
                return false
            }
            ancestor = current.superview
        }
        return true
    }

    private func beginGesture() {
        guard let owner, Self.isEffectivelyVisible(owner),
              !results.isEmpty, let clip = scrollView?.contentView else { return }
        if !gestureActive {
            cancelMotion()
            gestureActive = true
            gestureWasFast = false
            lastScrollOrigin = clip.bounds.origin
            lastScrollTime = nil
        }
        lastInputTime = ProcessInfo.processInfo.systemUptime
    }

    private func recordScrollMovement() {
        guard gestureActive, !isSnapping, let scroll = scrollView, let owner else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let origin = scroll.contentView.bounds.origin
        if let previous = lastScrollOrigin {
            let delta = owner.convert(CGSize(width: origin.x - previous.x, height: origin.y - previous.y),
                                      from: scroll.contentView)
            let distance = max(abs(delta.width), abs(delta.height))
            if distance > 0.01 {
                gestureMoved = true
                // The first native movement can arrive immediately after
                // gesture start. Measure velocity between actual movements.
                if let time = lastScrollTime {
                    let elapsed = max(1.0 / 120, now - time)
                    if distance / elapsed > PDFSearchScrollPolicy.fastScrollSpeed { gestureWasFast = true }
                }
                lastScrollTime = now
                lastScrollOrigin = origin
            }
        } else {
            lastScrollTime = now
            lastScrollOrigin = origin
        }
        scheduleSnap()
    }

    private func scheduleSnap() {
        pendingSnap?.cancel()
        guard gestureActive else { return }
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.pendingSnap = nil
            // Native knob tracking and text drags must finish before snapping.
            guard NSEvent.pressedMouseButtons == 0, !self.touchScrolling, !self.momentumScrolling else { return }
            let wasFast = self.gestureWasFast
            self.gestureActive = false
            guard self.gestureMoved, !wasFast else { return }
            self.snapIfClose()
        }
        pendingSnap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PDFSearchScrollPolicy.settleDelay, execute: work)
    }

    private func snapIfClose() {
        guard let owner, let workspace, let document, let scroll = scrollView,
              owner.document === document, document === workspace.document,
              owner.compactSpread == nil, owner.viewportContext == .normal, let window = owner.window, isWindowActive(window),
              Self.isEffectivelyVisible(owner),
              window.attachedSheet == nil, !workspace.isSearching,
              owner.activeTool == .select, !owner.isDrawingInkStroke,
              !owner.regionSelection.isActive, !owner.isHandlingModifiedZoom,
              owner.currentSelection == nil || owner.currentSelection === workspace.activeSearchSelection,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if let editor = owner.window?.firstResponder as? NSTextView,
           PDFKitViewer.Coordinator.responder(editor, belongsTo: owner) { return }
        let clip = scroll.contentView
        guard let documentView = scroll.documentView else { return }
        let axis = overlay.markerAxis
        let unit = owner.convert(CGSize(width: 1, height: 1), from: clip)
        let screenScale = axis == .vertical ? abs(unit.height) : abs(unit.width)
        if let snappedOrigin = lastSnappedOrigin {
            let distance = axis == .vertical ? abs(clip.bounds.minY - snappedOrigin.y)
                : abs(clip.bounds.minX - snappedOrigin.x)
            if distance * screenScale > PDFSearchScrollPolicy.maxSnapDistance * 2 {
                lastSnappedID = nil
                lastSnappedOrigin = nil
            }
        }
        var candidate: (id: UUID, offset: CGFloat)?
        for page in owner.visiblePages {
            for hit in hitsByPage[document.index(for: page)] ?? [] where hit.id != lastSnappedID {
                guard let rect = hit.lineRects.first, let transform = transform(for: hit.pageIndex) else { continue }
                let documentPoint = CGPoint(x: rect.midX, y: rect.midY).applying(transform)
                let point = clip.convert(documentPoint, from: documentView)
                guard clip.bounds.contains(point), let offset = PDFSearchScrollPolicy.snapOffset(
                    hitCoordinate: axis == .vertical ? point.y : point.x,
                    viewportOrigin: axis == .vertical ? clip.bounds.minY : clip.bounds.minX,
                    viewportLength: axis == .vertical ? clip.bounds.height : clip.bounds.width,
                    axis: axis, isFlipped: clip.isFlipped, screenScale: screenScale
                ) else { continue }
                if candidate == nil || abs(offset) < abs(candidate!.offset) { candidate = (hit.id, offset) }
            }
        }
        guard let candidate else { return }
        var proposed = clip.bounds
        if axis == .vertical { proposed.origin.y += candidate.offset }
        else { proposed.origin.x += candidate.offset }
        let target = clip.constrainBoundsRect(proposed).origin
        guard target != clip.bounds.origin else { return }
        lastSnappedID = candidate.id
        lastSnappedOrigin = target
        animateScroll(to: target, in: scroll)
    }

    private func animateScroll(to target: CGPoint, in scroll: NSScrollView) {
        let start = scroll.contentView.bounds.origin
        let began = ProcessInfo.processInfo.systemUptime
        let token = generation
        isSnapping = true
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak scroll] timer in
            MainActor.assumeIsolated {
                guard let self, let scroll, self.generation == token, self.isSnapping,
                      let owner = self.owner, Self.isEffectivelyVisible(owner),
                      let window = owner.window, self.isWindowActive(window) else {
                    timer.invalidate()
                    self?.cancelMotion()
                    return
                }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.12)
                let eased = 1 - pow(1 - progress, 3)
                let origin = CGPoint(x: start.x + (target.x - start.x) * eased,
                                     y: start.y + (target.y - start.y) * eased)
                scroll.contentView.setBoundsOrigin(origin)
                scroll.reflectScrolledClipView(scroll.contentView)
                self.requestRefresh()
                if progress >= 1 {
                    timer.invalidate()
                    self.snapTimer = nil
                    self.isSnapping = false
                    self.owner?.onSearchAssistedScrollEnded?()
                }
            }
        }
        snapTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
