// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

@MainActor
extension InteractivePDFView {
    func updatePageFitMode(revealCurrentPage: Bool = false) {
        guard compactSpread == nil else { return }
        if viewportContext == .comparison {
            if revealCurrentPage, pendingComparisonPageIndex == nil {
                pendingComparisonPageIndex = workspaceState?.currentPageIndex
            }
            scheduleComparisonPageFitUpdate()
            return
        }
        let requested = viewportContext == .normal ? workspaceState?.pageFitMode : nil
        if requested != nil, revealCurrentPage { revealPageAfterFitting = true }
        if activePageFitMode != requested {
            activePageFitMode = requested
            revealPageAfterFitting = requested != nil
            if requested == nil, workspaceState?.pdfViewportState.autoScales == true {
                autoScales = true
            }
        }
        schedulePageFitUpdate()
    }

    func schedulePageFitUpdate() {
        guard compactSpread == nil else { return }
        if viewportContext == .comparison {
            scheduleComparisonPageFitUpdate()
            return
        }
        guard activePageFitMode != nil, !isApplyingPageFitScale, !pageFitUpdateScheduled else { return }
        pageFitUpdateScheduled = true
        // PDFKit replaces its clip view during layout and spread changes.
        // Read its final size after that layout, never from SwiftUI's old frame.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyPageFitScale()
            self.pageFitUpdateScheduled = false
        }
    }

    /// PDFKit's continuous autoScales is width-only. A short stacked pane
    /// instead needs a whole page, and resizing must not change its page index.
    func prepareComparisonViewportReflow() {
        guard viewportContext == .comparison else { return }
        if pendingComparisonPageIndex == nil {
            pendingComparisonPageIndex = workspaceState?.currentPageIndex
            if !comparisonAutomaticallyFitsPage { comparisonReflowDestination = currentDestination }
        }
        // Set before super.setFrameSize: PDFKit may synchronously report another
        // currentPage as soon as its clip view is resized.
        scheduleComparisonPageFitUpdate()
    }

    func scheduleComparisonPageFitUpdate() {
        refreshComparisonClipFrameObservation()
        guard viewportContext == .comparison, !isApplyingPageFitScale,
              !pageFitUpdateScheduled, bounds.width > 1, bounds.height > 1,
              let state = workspaceState, let document,
              document.page(at: pendingComparisonPageIndex ?? state.currentPageIndex) != nil else { return }
        let viewport = comparisonPageFitViewportSize
        let viewportChanged = comparisonFitViewportSize.map {
            abs($0.width - viewport.width) > 0.5 || abs($0.height - viewport.height) > 0.5
        } ?? true
        guard pendingComparisonPageIndex != nil || viewportChanged else { return }
        if !comparisonAutomaticallyFitsPage, pendingComparisonPageIndex == nil {
            pendingComparisonPageIndex = state.currentPageIndex
            comparisonReflowDestination = currentDestination
        }
        pageFitUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyComparisonPageFit()
            self.pageFitUpdateScheduled = false
            // Legacy scrollers can change the clip size after PDFKit lays out
            // the scaled document. Refit only if that actual viewport changed.
            self.scheduleComparisonPageFitUpdate()
        }
    }

    private func refreshComparisonClipFrameObservation() {
        guard viewportContext == .comparison else { return }
        let clip = firstDocumentScrollView()?.contentView
        guard clip !== observedComparisonClip else { return }
        comparisonClipFrameObservation = nil
        observedComparisonClip = clip
        observedComparisonClipFrameSize = clip?.frame.size
        guard let clip else { return }
        // PDFKit can tile its scroll view on a later run-loop turn without
        // laying out PDFView again. Frame notifications also cover the native
        // setFrameSize: path, which does not consistently emit frame KVO.
        clip.postsFrameChangedNotifications = true
        let token = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clip, queue: nil
        ) { [weak self, weak clip] _ in
            DispatchQueue.main.async { [weak self, weak clip] in
                guard let self, let clip,
                      self.viewportContext == .comparison,
                      self.observedComparisonClip === clip,
                      self.observedComparisonClipFrameSize != clip.frame.size else { return }
                self.observedComparisonClipFrameSize = clip.frame.size
                self.scheduleComparisonPageFitUpdate()
            }
        }
        comparisonClipFrameObservation = PDFComparisonClipFrameObservation(token)
    }

    private var comparisonPageFitViewportSize: CGSize {
        guard let clip = firstDocumentScrollView()?.contentView else { return bounds.size }
        let viewport = convert(clip.bounds, from: clip).intersection(bounds)
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 1, viewport.height > 1 else { return bounds.size }
        return viewport.size
    }

    func applyComparisonPageFit() {
        guard viewportContext == .comparison, let state = workspaceState,
              let document, bounds.width > 1, bounds.height > 1,
              let selectedPage = document.page(at: pendingComparisonPageIndex ?? state.currentPageIndex)
        else { return }
        let selectedIndex = document.index(for: selectedPage)
        isApplyingPageFitScale = true
        defer {
            isApplyingPageFitScale = false
            onComparisonViewportReflowCompleted?()
        }
        firstDocumentScrollView()?.tile()
        let viewport = comparisonPageFitViewportSize
        if comparisonAutomaticallyFitsPage {
            let count = (displayMode == .twoUp || displayMode == .twoUpContinuous) ? 2 : 1
            let start = selectedIndex / count * count
            let sizes = (start..<min(start + count, document.pageCount)).compactMap { index -> CGSize? in
                guard let page = document.page(at: index) else { return nil }
                let size = page.bounds(for: displayBox).size
                return abs(page.rotation % 180) == 90 ? CGSize(width: size.height, height: size.width) : size
            }
            let margins = displaysPageBreaks ? pageBreakMargins : NSEdgeInsetsZero
            if let width = PDFPageFitMode.width.scaleFactor(
                viewportSize: viewport, pageSizes: sizes,
                horizontalInsets: (margins.left + margins.right) * CGFloat(count)
            ), let height = PDFPageFitMode.height.scaleFactor(
                viewportSize: viewport, pageSizes: sizes,
                verticalInsets: margins.top + margins.bottom
            ) {
                let target = min(width, height)
                autoScales = false
                minScaleFactor = min(minScaleFactor, target)
                maxScaleFactor = max(maxScaleFactor, target)
                if abs(scaleFactor - target) > 0.0001 { scaleFactor = target }
                layoutDocumentView()
            }
        }
        if !comparisonAutomaticallyFitsPage, let destination = comparisonReflowDestination,
           destination.page === selectedPage {
            go(to: destination)
        } else {
            revealComparisonPage(selectedPage)
        }
        // Keep the input measurement so a later scrollbar layout cannot mark
        // a fit calculated for the old viewport as already up to date.
        comparisonFitViewportSize = viewport
        pendingComparisonPageIndex = nil
        comparisonReflowDestination = nil
        state.recordPDFViewport(autoScales: comparisonAutomaticallyFitsPage,
                                scaleFactor: scaleFactor, scrollProgress: nil, context: .comparison)
    }

    func revealComparisonPage(_ page: PDFPage) {
        let wasApplying = isApplyingPageFitScale
        isApplyingPageFitScale = true
        defer { isApplyingPageFitScale = wasApplying }
        comparisonReadingAnchorPage = nil
        go(to: page)
        if comparisonAutomaticallyFitsPage { centerComparisonPage(page) }
        // At the beginning/end, the clip can clamp before a short page reaches
        // the center. Keep that explicit destination only until the viewport
        // actually moves; otherwise Next/Previous can skip an edge page.
        if let clip = firstDocumentScrollView()?.contentView {
            comparisonReadingAnchorPage = page
            comparisonReadingAnchorClip = clip
            comparisonReadingAnchorBounds = clip.bounds
        }
    }

    func anchoredComparisonReadingPage() -> PDFPage? {
        guard viewportContext == .comparison,
              let page = comparisonReadingAnchorPage,
              page.document === document,
              let clip = comparisonReadingAnchorClip,
              clip === firstDocumentScrollView()?.contentView,
              comparisonReadingAnchorBounds == clip.bounds else {
            comparisonReadingAnchorPage = nil
            return nil
        }
        return page
    }

    private func centerComparisonPage(_ page: PDFPage) {
        guard let scroll = firstDocumentScrollView() else { return }
        let clip = scroll.contentView
        let rect = clip.convert(convert(page.bounds(for: displayBox), from: page), from: self)
        guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0 else { return }
        var proposed = clip.bounds
        // Comparison navigation identifies the page at the viewport center.
        // Top-aligning a short landscape page can put the next page there,
        // changing both the page number and the next resize's fit target.
        // Clip coordinates also handle rotated pages and nonzero crop origins.
        proposed.origin = CGPoint(x: rect.midX - proposed.width / 2,
                                  y: rect.midY - proposed.height / 2)
        let constrained = clip.constrainBoundsRect(proposed)
        guard constrained.origin.x.isFinite, constrained.origin.y.isFinite else { return }
        clip.setBoundsOrigin(constrained.origin)
        scroll.reflectScrolledClipView(clip)
    }

    func applyPageFitScale() {
        guard compactSpread == nil, viewportContext == .normal,
              let mode = activePageFitMode,
              mode == workspaceState?.pageFitMode,
              let state = workspaceState,
              let document,
              let selectedPage = document.page(at: state.currentPageIndex),
              bounds.width > 1, bounds.height > 1
        else { return }

        let pageCount = (displayMode == .twoUp || displayMode == .twoUpContinuous) ? 2 : 1
        let start = state.currentPageIndex / pageCount * pageCount
        let pageSizes = (start..<min(start + pageCount, document.pageCount)).compactMap { index -> CGSize? in
            guard let page = document.page(at: index) else { return nil }
            let size = page.bounds(for: displayBox).size
            return abs(page.rotation % 180) == 90
                ? CGSize(width: size.height, height: size.width) : size
        }
        // The clip view's bounds are magnified document units. Convert back to
        // PDFView coordinates to measure the actual on-screen reading area.
        let scrollView = firstDocumentScrollView()
        let viewport = scrollView.map {
            convert($0.contentView.bounds, from: $0.contentView).size
        } ?? bounds.size
        let margins = displaysPageBreaks ? pageBreakMargins : NSEdgeInsetsZero
        let isContinuous = displayMode == .singlePageContinuous || displayMode == .twoUpContinuous
        guard var target = mode.scaleFactor(
            viewportSize: viewport,
            pageSizes: pageSizes,
            horizontalInsets: (margins.left + margins.right) * CGFloat(pageCount + (isContinuous ? 0 : 1)),
            verticalInsets: (margins.top + margins.bottom) * (displayMode == .singlePageContinuous ? 1 : 2)
        ) else { return }
        // PDFKit scales page-break margins with the document. Its intrinsic
        // width also includes rotation, unequal pages and paged-mode gutters;
        // using that width prevents a small unwanted horizontal overflow.
        if mode == .width, let width = scrollView?.documentView?.frame.width,
           width.isFinite, width > 0 {
            target = min(20, max(0.05, viewport.width / width))
        }

        isApplyingPageFitScale = true
        defer { isApplyingPageFitScale = false }
        autoScales = false
        // PDFKit's automatic fit can leave a narrower allowed zoom range.
        // Expand that range before asking it to fill just one axis.
        minScaleFactor = min(minScaleFactor, target)
        maxScaleFactor = max(maxScaleFactor, target)
        if abs(scaleFactor - target) > 0.0001 {
            scaleFactor = target
            layoutDocumentView()
            if mode == .height { revealPageAfterFitting = true }
        }
        if revealPageAfterFitting {
            revealPageAfterFitting = false
            go(to: selectedPage)
        }
        state.recordPDFViewport(
            autoScales: false,
            scaleFactor: scaleFactor,
            scrollProgress: nil
        )
    }

    func endPageFitForManualZoom() {
        if viewportContext == .comparison {
            comparisonAutomaticallyFitsPage = false
            return
        }
        guard viewportContext == .normal, activePageFitMode != nil else { return }
        activePageFitMode = nil
        revealPageAfterFitting = false
        workspaceState?.endPageFitForManualZoom()
    }
}
