// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit
import SwiftUI

/// SwiftUI 상태 모델과 AppKit `PDFView`를 연결하는 adapter다.
///
/// `NSViewRepresentable` 수명주기:
/// 1. `makeNSView`에서 PDFView를 한 번 만들고 delegate/observer를 붙인다.
/// 2. `updateNSView`에서 최신 모델 상태와 기존 PDFView의 차이만 적용한다.
/// 3. `dismantleNSView`에서 form 입력·viewport를 commit하고 observer를 해제한다.
///
/// Coordinator가 notification과 delegate를 받아 `PDFWorkspaceState`로 되돌려 보내며,
/// `isApplyingState` 같은 guard가 모델 -> 뷰 -> 모델의 무한 피드백을 막는다.
@MainActor
struct PDFKitViewer: NSViewRepresentable {
    @ObservedObject var state: PDFWorkspaceState
    @AppStorage(PDFPageNavigationMode.defaultsKey)
    private var pageNavigationModeValue = PDFPageNavigationMode.defaultValue.rawValue
    @AppStorage(PDFWheelZoomModifier.defaultsKey)
    private var wheelZoomModifierValue = PDFWheelZoomModifier.defaultValue.rawValue
    @AppStorage(AppPerformanceSettings.efficientRenderingEnabledKey)
    private var efficientRenderingEnabled = AppPerformanceSettings.defaultEfficientRenderingEnabled
    @AppStorage(PDFReadingTheme.defaultsKey)
    private var readingThemeValue = PDFReadingTheme.original.rawValue
    @EmberTheme private var theme
    private let scrollSyncCoordinator: PDFScrollSyncCoordinator?
    private let scrollSyncID: UUID?
    private let scrollSyncLocked: Bool
    private let onScrollActivity: ((PDFVerticalScrollMetrics) -> Void)?
    private let viewportContext: PDFViewerViewportContext
    private let compactSpread: PDFCompactSpreadContext?

    init(
        workspace: PDFWorkspaceState,
        scrollSyncCoordinator: PDFScrollSyncCoordinator? = nil,
        scrollSyncID: UUID? = nil,
        scrollSyncLocked: Bool = false,
        viewportContext: PDFViewerViewportContext = .normal,
        compactSpread: PDFCompactSpreadContext? = nil,
        onScrollActivity: ((PDFVerticalScrollMetrics) -> Void)? = nil
    ) {
        _state = ObservedObject(wrappedValue: workspace)
        self.scrollSyncCoordinator = scrollSyncCoordinator
        self.scrollSyncID = scrollSyncID
        self.scrollSyncLocked = scrollSyncLocked
        self.viewportContext = viewportContext
        self.compactSpread = compactSpread
        self.onScrollActivity = onScrollActivity
    }

    init(
        state: PDFWorkspaceState,
        scrollSyncCoordinator: PDFScrollSyncCoordinator? = nil,
        scrollSyncID: UUID? = nil,
        scrollSyncLocked: Bool = false,
        viewportContext: PDFViewerViewportContext = .normal,
        compactSpread: PDFCompactSpreadContext? = nil,
        onScrollActivity: ((PDFVerticalScrollMetrics) -> Void)? = nil
    ) {
        _state = ObservedObject(wrappedValue: state)
        self.scrollSyncCoordinator = scrollSyncCoordinator
        self.scrollSyncID = scrollSyncID
        self.scrollSyncLocked = scrollSyncLocked
        self.viewportContext = viewportContext
        self.compactSpread = compactSpread
        self.onScrollActivity = onScrollActivity
    }

    /// SwiftUI struct가 재생성되어도 AppKit delegate 상태를 유지할 참조 객체다.
    func makeCoordinator() -> Coordinator {
        Coordinator(
            state: state,
            viewportContext: viewportContext,
            onScrollActivity: onScrollActivity
        )
    }

    /// AppKit view의 변하지 않는 기본 설정은 생성 시 한 번만 적용한다.
    func makeNSView(context: Context) -> NSView {
        let nativeView = PDFNativeViewFactory.makeView {
            InteractivePDFView(frame: .zero)
        }
        guard let pdfView = nativeView as? InteractivePDFView else { return nativeView }
        pdfView.compactSpread = compactSpread
        if compactSpread != nil { pdfView.displayMode = .twoUp }
        pdfView.pageNavigationMode = pageNavigationMode
        pdfView.displayDirection = pageNavigationMode == .horizontalPaging ? .horizontal : .vertical
        pdfView.displaysPageBreaks = compactSpread == nil
        pdfView.displaysAsBook = false
        pdfView.displayBox = .cropBox
        pdfView.readingDisplayFilter.apply(readingTheme, to: pdfView, canvasColor: NSColor(theme.canvas))
        pdfView.pageShadowsEnabled = viewportContext == .normal || !efficientRenderingEnabled
        pdfView.autoScales = viewportContext == .normal && compactSpread == nil
        pdfView.viewportContext = viewportContext
        pdfView.comparisonContentFixed = scrollSyncLocked
        pdfView.wheelZoomModifier = wheelZoomModifier
        pdfView.configure(with: state)
        context.coordinator.attach(to: pdfView)
        context.coordinator.updateScrollSyncRegistration(
            coordinator: scrollSyncCoordinator,
            id: scrollSyncID,
            locked: scrollSyncLocked
        )
        context.coordinator.refreshScrollActivityObservation()
        return pdfView
    }

    /// 매 SwiftUI 갱신마다 호출되므로 비싼 작업은 identity/revision 비교 뒤 실행한다.
    func updateNSView(_ nativeView: NSView, context: Context) {
        guard let pdfView = nativeView as? InteractivePDFView else {
            (nativeView as? PDFNativeRenderingUnavailableView)?.refreshMessage()
            return
        }
        let coordinator = context.coordinator
        pdfView.compactSpread = compactSpread
        pdfView.comparisonAllowsProgrammaticScale = true
        defer { pdfView.comparisonAllowsProgrammaticScale = false }
        if let scrollSyncCoordinator, let scrollSyncID {
            scrollSyncCoordinator.beginProgrammaticUpdate(id: scrollSyncID)
        }
        defer {
            if let scrollSyncCoordinator, let scrollSyncID {
                scrollSyncCoordinator.endProgrammaticUpdate(id: scrollSyncID)
            }
        }
        let canvasColor = NSColor(theme.canvas)
        // Keep the unfiltered canvas explicit: PDFView's getter can return
        // the clip's compensated background after a reading theme is applied.
        pdfView.readingDisplayFilter.apply(readingTheme, to: pdfView, canvasColor: canvasColor)
        coordinator.updateState(state)
        coordinator.updateScrollActivityHandler(onScrollActivity)
        // [학습 03] 여기서 go(to:)를 호출하면 PDFKit 알림도 발생할 수 있습니다.
        // 적용 중인 상태임을 표시해 알림을 사용자 입력으로 다시 처리하지 않도록 하고, defer로 이 표시를 해제합니다.
        coordinator.isApplyingState = true
        defer { coordinator.isApplyingState = false }
        var pdfKitHierarchyMayHaveChanged = false

        if viewportContext == .normal, compactSpread == nil {
            state.preparePDFViewportForNavigationMode(pageNavigationMode)
        }
        let navigationChanged = pdfView.pageNavigationMode != pageNavigationMode
        if navigationChanged {
            if (pdfView.pageNavigationMode == .horizontalPaging) != (pageNavigationMode == .horizontalPaging) {
                coordinator.cancelViewportRestoration()
            }
            pdfView.pageNavigationMode = pageNavigationMode
        }

        if pdfView.viewportContext != viewportContext {
            pdfView.viewportContext = viewportContext
        }
        pdfView.comparisonContentFixed = scrollSyncLocked
        pdfView.configure(with: state)
        if pdfView.wheelZoomModifier != wheelZoomModifier {
            pdfView.wheelZoomModifier = wheelZoomModifier
        }
        let pageShadowsEnabled = viewportContext == .normal || !efficientRenderingEnabled
        if pdfView.pageShadowsEnabled != pageShadowsEnabled {
            pdfView.pageShadowsEnabled = pageShadowsEnabled
        }

        // [학습 02] !==는 클래스 객체의 식별성(identity)을 비교합니다. 파일 내용의 차이가 아니라
        // 지금 PDFView가 바로 그 PDFDocument 객체를 표시하는지 검사합니다.
        let documentChanged = pdfView.document !== state.document
        if documentChanged {
            pdfView.searchScroll.cancelMotion()
            pdfView.resetPageTurnGesture()
            pdfKitHierarchyMayHaveChanged = true
            if viewportContext == .comparison {
                pdfView.comparisonAutomaticallyFitsPage = state.pdfViewportState(for: .comparison).autoScales
                pdfView.pendingComparisonPageIndex = state.currentPageIndex
                pdfView.autoScales = false
            }
            pdfView.document = state.document
            coordinator.lastAppliedPageIndex = nil
            coordinator.lastAppliedPage = nil
            coordinator.lastSearchSelection = nil
            if state.document != nil, compactSpread == nil {
                let viewport = state.pdfViewportState(for: viewportContext)
                if
                    let scaleFactor = viewport.scaleFactor,
                    !viewport.autoScales
                {
                    pdfView.autoScales = false
                    pdfView.scaleFactor = min(20, max(0.05, scaleFactor))
                } else {
                    pdfView.autoScales = viewportContext == .normal
                }
            }
        }

        let requestedMode: PDFDisplayMode = compactSpread != nil ? .twoUp : Self.requestedDisplayMode(
            pageColumns: state.pageColumns,
            twoPageDisplayMode: state.twoPageDisplayMode,
            viewportContext: viewportContext,
            navigationMode: pageNavigationMode
        )
        let requestedDirection: PDFDisplayDirection = pageNavigationMode == .horizontalPaging ? .horizontal : .vertical
        if pdfView.displayMode != requestedMode || pdfView.displayDirection != requestedDirection {
            pdfKitHierarchyMayHaveChanged = true
            coordinator.cancelViewportRestoration()
            pdfView.resetPageTurnGesture()
            let wasAutoScaling = pdfView.autoScales
            let previousScale = pdfView.scaleFactor
            coordinator.lastAppliedPageIndex = nil
            coordinator.lastAppliedPage = nil
            coordinator.lastSearchSelection = nil
            pdfView.displayDirection = requestedDirection
            pdfView.displayMode = requestedMode
            if wasAutoScaling {
                pdfView.autoScales = true
            } else {
                pdfView.scaleFactor = previousScale
            }
        }

        // [학습 03] PDFDocument 내부를 편집해도 document 참조(reference)는 같을 수 있습니다.
        // 이때도 PDFKit에 다시 배치하고 그리도록 요청하기 위해 별도 변경 신호인 revision을 사용합니다.
        if coordinator.lastRevision != state.revision {
            pdfKitHierarchyMayHaveChanged = true
            coordinator.lastRevision = state.revision
            pdfView.layoutDocumentView()
            pdfView.needsDisplay = true
        }

        let requestedPageIndex = compactSpread?.pageIndex ?? state.currentPageIndex
        if
            let document = state.document,
            requestedPageIndex >= 0,
            requestedPageIndex < document.pageCount,
            let page = document.page(at: requestedPageIndex),
            coordinator.requiresNavigation(
                to: page,
                at: requestedPageIndex,
                in: pdfView
            )
        {
            state.primeWidgetValues(on: page)
            coordinator.lastAppliedPageIndex = requestedPageIndex
            coordinator.lastAppliedPage = page
            pdfView.searchScroll.cancelMotion()
            if viewportContext == .comparison {
                pdfView.revealComparisonPage(page)
            } else {
                pdfView.go(to: page)
            }
            if requestedMode == .twoUp {
                pdfView.visiblePages.forEach { state.primeWidgetValues(on: $0) }
            }
        }

        // PDFKit can replace its private document/scroll views when a document,
        // display mode, or layout changes. Refresh after those mutations and
        // once more on the next run loop after PDFKit has finished layout.
        coordinator.updateScrollSyncRegistration(
            coordinator: scrollSyncCoordinator,
            id: scrollSyncID,
            locked: scrollSyncLocked,
            forceRefresh: pdfKitHierarchyMayHaveChanged
        )
        if pdfKitHierarchyMayHaveChanged {
            pdfView.relinquishNativeFileDropDestination()
            pdfView.invalidateDocumentScrollViewCache()
            // A PDFDisplayMode change can replace PDFKit's private document
            // hierarchy. Reconnect the normal editor overlays to that hierarchy.
            pdfView.configure(with: state)
            pdfView.restoreRenderingOverlayOrderIfNeeded()
            coordinator.refreshScrollActivityObservation()
            coordinator.scheduleScrollActivityObservationRefresh()
        }
        if let compactSpread {
            pdfView.autoScales = false
            pdfView.minScaleFactor = min(pdfView.minScaleFactor, compactSpread.scaleFactor)
            pdfView.maxScaleFactor = max(pdfView.maxScaleFactor, compactSpread.scaleFactor)
            if abs(pdfView.scaleFactor - compactSpread.scaleFactor) > 0.0001 {
                pdfView.scaleFactor = compactSpread.scaleFactor
                pdfView.layoutDocumentView()
            }
            // The outer scroll view owns the continuous position. A row has no
            // native scrolling range, even when PDFKit recreates its clip view.
            if let scroll = pdfView.firstDocumentScrollView() {
                scroll.hasVerticalScroller = false
                scroll.hasHorizontalScroller = false
                scroll.verticalScrollElasticity = .none
                scroll.horizontalScrollElasticity = .none
            }
        } else {
            // A body edit replaces a page with identical geometry. Revealing
            // it again queues a fit-mode go(to:) after viewport restoration,
            // which would undo that restoration on the next run loop.
            pdfView.updatePageFitMode(revealCurrentPage: pdfKitHierarchyMayHaveChanged
                && !coordinator.isPreservingBodyTextViewport)
        }
        applySearchSelection(to: pdfView, coordinator: coordinator)
        coordinator.applyStudyNoteReveal(state.studyNoteRevealRequest, to: pdfView)
        coordinator.clearSelectionAfterMarkup(in: pdfView)
        pdfView.regionSelection.synchronize()
        pdfView.readingDisplayFilter.refreshTarget()
        pdfView.searchScroll.synchronize(with: state)
        coordinator.restoreBodyTextViewportAfterUpdate()
        if documentChanged, compactSpread == nil {
            coordinator.scheduleViewportRestoration(
                state.pdfViewportState(for: viewportContext)
            )
        }
        pdfView.revealPendingBodyTextSelection()
    }

    private var readingTheme: PDFReadingTheme {
        PDFReadingTheme(rawValue: readingThemeValue) ?? .original
    }

    /// PDFKit이 지원하는 1·2페이지 표시 모드로 워크스페이스 선택을 변환한다.
    /// 3페이지 이상은 `WorkspaceView`에서 개요 화면으로 분기되므로 이 함수에
    /// 들어오지 않지만, 방어적으로 두 페이지 연속 보기로 정규화한다.
    static func requestedDisplayMode(
        pageColumns: Int,
        twoPageDisplayMode: PDFTwoPageDisplayMode,
        viewportContext: PDFViewerViewportContext = .normal,
        navigationMode: PDFPageNavigationMode = .verticalScroll
    ) -> PDFDisplayMode {
        // Each comparison pane represents one document in one continuous
        // column. Inheriting the source tab's two-page or 3–12-page overview
        // silently created spreads, especially visible after a pane resized.
        // Leave the source tab's display preferences untouched on exit.
        if viewportContext == .comparison { return .singlePageContinuous }
        if navigationMode == .horizontalPaging, pageColumns <= 2 {
            return pageColumns > 1 ? .twoUp : .singlePage
        }
        guard pageColumns > 1 else { return .singlePageContinuous }
        // Normal 3+ page calls use the SwiftUI overview. Keep their defensive
        // PDFKit fallback separate from comparison presentation.
        guard pageColumns == 2 else {
            return .twoUpContinuous
        }
        return twoPageDisplayMode == .paged ? .twoUp : .twoUpContinuous
    }

    private var wheelZoomModifier: PDFWheelZoomModifier {
        PDFWheelZoomModifier(rawValue: wheelZoomModifierValue) ?? .defaultValue
    }

    private var pageNavigationMode: PDFPageNavigationMode {
        guard viewportContext == .normal else { return .verticalScroll }
        return PDFPageNavigationMode(rawValue: pageNavigationModeValue) ?? .defaultValue
    }

    static func dismantleNSView(_ nativeView: NSView, coordinator: Coordinator) {
        guard let pdfView = nativeView as? InteractivePDFView else {
            coordinator.detach()
            return
        }
        // A replacement coordinator may already have installed its token on
        // the shared workspace. Commit through this outgoing view directly so
        // normal↔comparison/layout rebuilds cannot route the old field editor
        // to the new PDFView's handler.
        // Synchronize/commit the custom inline draft before the PDFView and its
        // native field editors leave the responder chain.
        pdfView.prepareInlineTextEditingOverlayForRemoval()
        pdfView.finishEraserGesture()
        coordinator.prepareForDismantling()
        coordinator.detach()
        pdfView.cancelInkStroke()
        pdfView.resetViewportScrollGesture()
        pdfView.resetPageTurnGesture()
        pdfView.prepareAnnotationEditingOverlayForRemoval()
        pdfView.regionSelection.cancel()
        pdfView.finishNativeSelectionPreview()
        pdfView.searchScroll.detach()
        pdfView.readingDisplayFilter.detach()
        pdfView.workspaceState = nil
    }

    private func applySearchSelection(to pdfView: PDFView, coordinator: Coordinator) {
        coordinator.applySearchSelection(state.activeSearchSelection, to: pdfView)
    }

    @MainActor
    final class Coordinator: NSObject {
        // [학습 03] 이 객체는 연결을 관리합니다. 문서 모델과 PDFView의 수명을 늘리지 않도록
        // 약한 참조(weak reference)를 사용하며, 연결 대상이 사라진 상태(nil)도 정상적으로 처리해야 합니다.
        private(set) weak var state: PDFWorkspaceState?
        weak var pdfView: InteractivePDFView?
        var isApplyingState = false
        var lastAppliedPageIndex: Int?
        weak var lastAppliedPage: PDFPage?
        var lastRevision: UUID?
        var lastSearchSelection: PDFSelection?
        private var lastSynchronizedSearchSelection: PDFSelection?
        private var activeSearchSelectionCancellable: AnyCancellable?
        private var formEventMonitor: Any?
        private var viewportScrollEventMonitor: Any?
        private weak var scrollSyncCoordinator: PDFScrollSyncCoordinator?
        private var scrollSyncID: UUID?
        private var scrollSyncLocked = false
        private var scrollSyncRefreshScheduled = false
        private weak var observedScrollView: NSScrollView?
        private var liveScrollObserver: NSObjectProtocol?
        private var liveScrollEndObserver: NSObjectProtocol?
        private var pendingLiveScrollReportWorkItem: DispatchWorkItem?
        private var liveScrollReportGeneration = UUID()
        private var lastLiveScrollDeliveryTime: TimeInterval?
        private var lastObservedVerticalScrollOrigin: CGFloat?
        private var scrollActivityRefreshScheduled = false
        private var viewportRestoreGeneration = UUID()
        private var bodyTextViewport: (document: PDFDocument, pageIndex: Int, origin: CGPoint, scale: CGFloat)?
        private var wasApplyingStateBeforeBodyReplacement = false
        private var searchNavigationGeneration = UUID()
        private var lastMarkupSelectionClearRequestID: UUID?
        private var onScrollActivity: ((PDFVerticalScrollMetrics) -> Void)?
        private let currentTime: () -> TimeInterval
        private let viewportContext: PDFViewerViewportContext
        private let deactivationCommitToken = UUID()
        private weak var registeredDeactivationState: PDFWorkspaceState?
        var hasRegisteredDeactivationCommitHandler: Bool {
            registeredDeactivationState != nil
        }

        init(
            state: PDFWorkspaceState,
            viewportContext: PDFViewerViewportContext = .normal,
            onScrollActivity: ((PDFVerticalScrollMetrics) -> Void)? = nil,
            currentTime: @escaping () -> TimeInterval = {
                ProcessInfo.processInfo.systemUptime
            }
        ) {
            self.state = state
            lastMarkupSelectionClearRequestID = state.markupSelectionClearRequestID
            self.viewportContext = viewportContext
            self.onScrollActivity = onScrollActivity
            self.currentTime = currentTime
        }

        func attach(to pdfView: InteractivePDFView) {
            // [학습 03] 다시 연결하기 전에 기존 구독(subscription)을 해제해야 한 이벤트가 여러 번 처리되지 않습니다.
            // object: pdfView는 이 창의 PDFView에서 온 알림만 받도록 범위를 제한하는 필터(filter)입니다.
            detach()
            self.pdfView = pdfView
            NotificationCenter.default.addObserver(self, selector: #selector(bodyPageWillReplace(_:)),
                name: PDFBodyPageReplacementEvents.willReplace, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(bodyPageDidReplace(_:)),
                name: PDFBodyPageReplacementEvents.didReplace, object: nil)
            observeActiveSearchSelection()
            registerDeactivationCommitHandlerIfNeeded()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged(_:)),
                name: .PDFViewPageChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(selectionChanged(_:)),
                name: .PDFViewSelectionChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scaleChanged(_:)),
                name: .PDFViewScaleChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textFieldEditingBegan(_:)),
                name: NSText.didBeginEditingNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textFieldEditingEnded(_:)),
                name: NSText.didEndEditingNotification,
                object: nil
            )
            formEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseUp, .rightMouseUp, .keyUp]
            ) { [weak self, weak pdfView] event in
                if event.type == .leftMouseUp, event.window === pdfView?.window {
                    // PDFKit can finish a selection in its own tracking loop,
                    // including a release outside the original page bounds.
                    pdfView?.scheduleNativeSelectionCommit()
                }
                guard
                    let self,
                    let pdfView,
                    event.window === pdfView.window,
                    self.eventTargetsPDFView(event, pdfView: pdfView)
                else {
                    return event
                }
                // While PDFKit's shared text field editor is active, AppKit's
                // native UndoManager owns Command-Z. Defer the document-level
                // semantic snapshot until the editor resigns, so native undo
                // is not recorded as a new inverse PDF command.
                if
                    event.type == .keyUp,
                    let textView = event.window?.firstResponder as? NSTextView,
                    textView.isFieldEditor
                {
                    return event
                }
                // PDFKit commits some controls at event end and others when
                // the field editor resigns, so check both moments.
                let interactedPage = pdfView.currentPage
                self.scheduleWidgetSynchronization(on: interactedPage, after: 0)
                self.scheduleWidgetSynchronization(on: interactedPage, after: 0.12)
                return event
            }
            viewportScrollEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .magnify, .smartMagnify, .leftMouseDown, .rightMouseDown, .keyDown]
            ) { [weak self, weak pdfView] event in
                guard
                    let self,
                    let pdfView
                else { return event }
                guard event.window === pdfView.window else {
                    pdfView.finishViewportScrollGesture()
                    return event
                }
                if self.eventTargetsPDFView(event, pdfView: pdfView) {
                    if pdfView.suppressesFixedComparisonNavigation(event) { return nil }
                    // A later pointer/key gesture owns the viewport, even if
                    // SwiftUI has not consumed the edit's final update yet.
                    self.bodyTextViewport = nil
                    self.cancelSearchNavigation()
                }
                if let spread = pdfView.compactSpread,
                   self.eventTargetsPDFView(event, pdfView: pdfView) {
                    if event.type == .scrollWheel {
                        spread.scroll(with: event)
                        return nil
                    }
                    if event.type == .magnify {
                        spread.zoom(by: max(0.1, 1 + event.magnification))
                        return nil
                    }
                    if event.type == .smartMagnify {
                        spread.zoom(by: 1.5)
                        return nil
                    }
                }
                if event.type == .magnify || event.type == .smartMagnify {
                    if self.eventTargetsPDFView(event, pdfView: pdfView),
                       event.type == .smartMagnify || abs(event.magnification) > 0.0001 {
                        pdfView.endPageFitForManualZoom()
                    }
                    return event
                }
                guard event.type == .scrollWheel else { return event }
                // Native scrolling stays on PDFKit's path. Page turns and
                // modified zoom/pan first check which view owns the gesture.
                guard pdfView.viewportScrollRequiresInterception(event) else {
                    return event
                }
                guard self.eventTargetsPDFView(event, pdfView: pdfView) else {
                    pdfView.finishViewportScrollGesture()
                    return event
                }
                let handled = pdfView.handleViewportScroll(event)
                return handled ? nil : event
            }
            pdfView.onModifiedScrollGestureEnded = { [weak self] in
                self?.captureViewportState()
            }
            pdfView.onSearchAssistedScrollEnded = { [weak self] in
                self?.captureViewportState()
            }
            pdfView.onComparisonSynchronizedScroll = { [weak self, weak pdfView] in
                guard let self, let pdfView, self.pdfView === pdfView,
                      let document = pdfView.document,
                      let page = PDFScrollSyncCoordinator.readingPage(in: pdfView) else { return }
                let index = document.index(for: page)
                guard index != NSNotFound else { return }
                self.lastAppliedPageIndex = index
                self.lastAppliedPage = page
                if self.state?.currentPageIndex != index { self.state?.setCurrentPage(index) }
                self.captureViewportState()
            }
            pdfView.onComparisonViewportReflowCompleted = { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                if let coordinator = self.scrollSyncCoordinator, let id = self.scrollSyncID {
                    coordinator.refreshAfterLayout(pdfView: pdfView, id: id, locked: self.scrollSyncLocked)
                }
                self.refreshScrollActivityObservation()
            }
            refreshScrollActivityObservation()
            scheduleScrollActivityObservationRefresh()
        }

        func updateState(_ state: PDFWorkspaceState) {
            guard self.state !== state else { return }
            cancelSearchNavigation()
            unregisterDeactivationCommitHandler()
            activeSearchSelectionCancellable?.cancel()
            activeSearchSelectionCancellable = nil
            lastSynchronizedSearchSelection = nil
            self.state = state
            lastMarkupSelectionClearRequestID = state.markupSelectionClearRequestID
            if pdfView != nil {
                observeActiveSearchSelection()
            }
            registerDeactivationCommitHandlerIfNeeded()
        }

        /// Keeps the model selection authoritative for every consumer that does
        /// not read PDFView directly (markup, Share Note, AI context). PDFKit's
        /// selection-changed notification is intentionally ignored while
        /// `updateNSView` applies state, so search navigation needs this explicit
        /// model-side bridge.
        private func observeActiveSearchSelection() {
            activeSearchSelectionCancellable?.cancel()
            var isInitialReplay = true
            activeSearchSelectionCancellable = state?.$activeSearchSelection.sink {
                [weak self, weak state] selection in
                MainActor.assumeIsolated {
                    guard let self, self.state === state else { return }
                    if isInitialReplay {
                        isInitialReplay = false
                        // A reattached reader receives the existing hit before
                        // any new search command. A later drag or editor owns
                        // the current selection, including an explicit nil.
                        self.lastSynchronizedSearchSelection = selection
                        return
                    }
                    if selection != nil {
                        // An explicit activation can select the very same hit
                        // again after a manual drag. Reapply it to PDFKit too.
                        self.lastSearchSelection = nil
                    }
                    self.synchronizeActiveSearchSelection(selection)
                }
            }
        }

        private func synchronizeActiveSearchSelection(_ selection: PDFSelection?) {
            // Virtual rows can mount long after a search. The workspace owns
            // the selected result; remounting must not replace a later manual
            // text selection with the previously active search hit.
            guard pdfView?.compactSpread == nil, let state else { return }
            if let selection {
                lastSynchronizedSearchSelection = selection
                if state.currentSelection !== selection {
                    state.currentSelection = selection
                }
                return
            }

            if
                let previous = lastSynchronizedSearchSelection,
                state.currentSelection === previous
            {
                state.currentSelection = nil
            }
            lastSynchronizedSearchSelection = nil
        }

        func clearSelectionAfterMarkup(in pdfView: PDFView) {
            guard viewportContext == .normal, let state,
                  pdfView.document === state.document,
                  let requestID = state.markupSelectionClearRequestID,
                  requestID != lastMarkupSelectionClearRequestID else { return }
            lastMarkupSelectionClearRequestID = requestID
            // The blue native selection can obscure an otherwise thin underline.
            pdfView.clearSelection()
        }

        /// Renders a hit only while search still owns the workspace selection.
        /// Repeated SwiftUI updates must not turn an old search highlight into
        /// a new command and replace a later native drag or editor selection.
        /// This boundary is internal for regression tests without a host window.
        func applySearchSelection(_ selection: PDFSelection?, to pdfView: PDFView) {
            guard let selection else {
                cancelSearchNavigation()
                if let previous = lastSearchSelection {
                    pdfView.highlightedSelections = nil
                    if let current = pdfView.currentSelection, current === previous {
                        pdfView.clearSelection()
                    }
                    lastSearchSelection = nil
                }
                return
            }

            if let spread = (pdfView as? InteractivePDFView)?.compactSpread,
               !selection.pages.contains(where: { spread.contains(page: $0) }) {
                cancelSearchNavigation()
                lastSearchSelection = nil
                pdfView.highlightedSelections = nil
                return
            }
            guard state?.currentSelection === selection else { return }
            guard lastSearchSelection !== selection else { return }
            // A pending tab/view restoration must not pull an explicit search
            // jump back to the old scroll position on the next run loop.
            cancelViewportRestoration()
            cancelSearchNavigation()
            let generation = searchNavigationGeneration
            let wasApplyingState = isApplyingState
            isApplyingState = true
            defer { isApplyingState = wasApplyingState }
            (pdfView as? InteractivePDFView)?.searchScroll.cancelMotion()
            selection.color = NSColor.systemYellow.withAlphaComponent(0.62)
            pdfView.highlightedSelections = [selection]
            lastSearchSelection = selection
            pdfView.setCurrentSelection(selection, animate: false)
            let shouldReveal = (pdfView as? InteractivePDFView)?.compactSpread?.claimSearchReveal(selection) ?? true
            guard shouldReveal else { return }
            pdfView.go(to: selection)
            centerSearchSelection(selection, in: pdfView)

            // PDFKit and width/height fitting can finish layout after SwiftUI's
            // update. Correct once using that final viewport, never on result
            // batches or later user scrolling. A saved tab position takes
            // precedence when this is an existing search restored with a tab.
            let document = pdfView.document
            let revision = state?.revision
            DispatchQueue.main.async { [weak self, weak pdfView, weak selection, weak document] in
                guard let self, let pdfView, let selection, let document,
                      self.searchNavigationGeneration == generation,
                      self.pdfView === pdfView, pdfView.document === document,
                      self.state?.document === document, self.state?.revision == revision,
                      self.lastSearchSelection === selection,
                      self.state?.activeSearchSelection === selection,
                      let page = selection.pages.first,
                      self.state?.currentPageIndex == document.index(for: page) else { return }
                let wasApplyingState = self.isApplyingState
                self.isApplyingState = true
                defer { self.isApplyingState = wasApplyingState }
                self.centerSearchSelection(selection, in: pdfView)
                self.captureViewportState()
            }
        }

        private func cancelSearchNavigation() {
            searchNavigationGeneration = UUID()
        }

        private func centerSearchSelection(_ selection: PDFSelection, in pdfView: PDFView) {
            guard let page = selection.pages.first,
                  let document = pdfView.document, document.index(for: page) != NSNotFound else { return }
            centerPageBounds(selection.bounds(for: page), on: page, in: pdfView)
        }

        /// Notes on the current page still need an explicit bounds reveal: a
        /// page-index change alone cannot move between two notes on that page.
        func applyStudyNoteReveal(_ request: StudyNoteRevealRequest?, to pdfView: PDFView) {
            guard viewportContext == .normal, let request,
                  !request.isConsumed,
                  let state, let document = state.document, pdfView.document === document,
                  state.studyNoteRevealRequest === request,
                  ObjectIdentifier(document) == request.documentID, state.revision == request.revision,
                  let annotation = request.annotation, let page = annotation.page,
                  document.index(for: page) != NSNotFound,
                  page.annotations.contains(where: { $0 === annotation }),
                  !annotation.bounds.isEmpty, !annotation.bounds.isNull, !annotation.bounds.isInfinite else { return }
            guard (pdfView as? InteractivePDFView)?.compactSpread?.contains(page: page) != false else { return }
            request.isConsumed = true
            cancelViewportRestoration()
            cancelSearchNavigation()
            let generation = searchNavigationGeneration
            let wasApplyingState = isApplyingState
            isApplyingState = true
            defer { isApplyingState = wasApplyingState }
            (pdfView as? InteractivePDFView)?.searchScroll.cancelMotion()
            pdfView.go(to: annotation.bounds, on: page)
            centerPageBounds(annotation.bounds, on: page, in: pdfView)

            DispatchQueue.main.async { [weak self, weak pdfView, weak document, weak request] in
                guard let self, let request else { return }
                defer {
                    if self.state?.studyNoteRevealRequest === request {
                        self.state?.studyNoteRevealRequest = nil
                    }
                }
                guard let pdfView, let document,
                      self.searchNavigationGeneration == generation,
                      self.pdfView === pdfView, pdfView.document === document,
                      self.state?.document === document, self.state?.revision == request.revision,
                      self.state?.studyNoteRevealRequest === request,
                      let annotation = request.annotation, let page = annotation.page,
                      document.index(for: page) != NSNotFound,
                      page.annotations.contains(where: { $0 === annotation }),
                      self.state?.currentPageIndex == document.index(for: page) else { return }
                let wasApplyingState = self.isApplyingState
                self.isApplyingState = true
                defer { self.isApplyingState = wasApplyingState }
                self.centerPageBounds(annotation.bounds, on: page, in: pdfView)
                self.captureViewportState()
            }
        }

        private func centerPageBounds(_ bounds: CGRect, on page: PDFPage, in pdfView: PDFView) {
            if let spread = (pdfView as? InteractivePDFView)?.compactSpread {
                spread.reveal(bounds, on: page)
                return
            }
            (pdfView as? InteractivePDFView)?.applyPageFitScale()
            pdfView.layoutSubtreeIfNeeded()
            guard let scrollView = firstScrollView(in: pdfView) ?? pdfView.enclosingScrollView else { return }
            let clip = scrollView.contentView
            let hit = clip.convert(pdfView.convert(bounds, from: page), from: pdfView)
            guard !hit.isNull, !hit.isInfinite, hit.midY.isFinite,
                  hit.width > 0, hit.height > 0, clip.bounds.height > 0 else { return }
            var proposed = clip.bounds
            // Both rectangles use clip coordinates, so magnification, flipped
            // views, crop boxes and rotated pages need no special arithmetic.
            // Keep PDFKit's horizontal reveal and clamp at document edges.
            proposed.origin.y = hit.midY - proposed.height / 2
            let constrained = clip.constrainBoundsRect(proposed)
            guard constrained.origin.x.isFinite, constrained.origin.y.isFinite else { return }
            clip.setBoundsOrigin(constrained.origin)
            scrollView.reflectScrolledClipView(clip)
        }

        /// Ends editing only when this PDFView (or its private field editor)
        /// owns the window's first responder. Other controls and other windows
        /// are intentionally left untouched.
        func commitFocusedFormEditing() {
            guard
                let pdfView,
                let window = pdfView.window,
                let responder = window.firstResponder,
                Self.responder(responder, belongsTo: pdfView)
            else { return }
            _ = window.makeFirstResponder(pdfView)
        }

        /// The outgoing coordinator commits through its own PDFView. Other
        /// normal/comparison coordinators have separate registry tokens and are
        /// neither invoked nor removed by this local dismantling step.
        func prepareForDismantling() {
            pdfView?.commitAnnotationEditingBeforeDeactivation()
            commitFocusedFormEditing()
            // Comparison panes cannot edit native widgets. Re-scanning every
            // page visited by each of the four read-only panes here duplicates
            // the normal editor's commit and delays returning to that editor.
            // Keep its form commit intact; every pane still records its own
            // viewport before observers and scroll synchronization are removed.
            if viewportContext == .normal, pdfView?.compactSpread == nil {
                state?.synchronizeWidgetValues()
            }
            captureViewportState()
        }

        static func responder(_ responder: NSResponder, belongsTo pdfView: PDFView) -> Bool {
            guard let responderView = responder as? NSView else { return false }
            if responderView === pdfView || responderView.isDescendant(of: pdfView) {
                return true
            }

            // AppKit's shared NSTextView field editor is hosted by the window,
            // not beneath the edited control. Its delegate identifies the
            // PDFKit control that owns the current editing session.
            if
                let textView = responderView as? NSTextView,
                textView.isFieldEditor,
                let ownerView = textView.delegate as? NSView
            {
                return ownerView === pdfView || ownerView.isDescendant(of: pdfView)
            }
            return false
        }

        private func registerDeactivationCommitHandlerIfNeeded() {
            guard
                pdfView != nil,
                let state
            else { return }
            registeredDeactivationState = state
            state.installDeactivationCommitHandler(id: deactivationCommitToken) { [weak self, weak pdfView] in
                guard let self else { return }
                self.cancelSearchNavigation()
                // Save, tab switch, close, and hibernation all enter through
                // this hook. Settle image/crop geometry first, then commit the
                // custom on-page text editor and native PDFKit form fields, so
                // no visible mutation remains only in a view hierarchy while
                // the model still appears clean.
                pdfView?.commitAnnotationEditingBeforeDeactivation()
                pdfView?.finishEraserGesture()
                pdfView?.commitInlineTextEditorBeforePointerAction()
                self.commitFocusedFormEditing()
                // A gallery may keep this PDFView mounted while hiding it.
                // Stop pending motion before recording the position so no
                // delayed snap or modified gesture changes it underneath.
                pdfView?.searchScroll.cancelMotion()
                pdfView?.resetViewportScrollGesture()
                // Quit/close persistence flushes before SwiftUI dismantles
                // the view, so capture the final zoom/scroll here as well.
                self.captureViewportState()
            }
        }

        private func unregisterDeactivationCommitHandler() {
            registeredDeactivationState?.removeDeactivationCommitHandler(
                id: deactivationCommitToken
            )
            registeredDeactivationState = nil
        }

        private func eventTargetsPDFView(_ event: NSEvent, pdfView: PDFView) -> Bool {
            if event.type == .keyUp || event.type == .keyDown {
                guard let responder = event.window?.firstResponder else { return false }
                return Self.responder(responder, belongsTo: pdfView)
            }

            guard let hitView = event.window?.contentView?.hitTest(event.locationInWindow) else {
                return false
            }
            return hitView === pdfView || hitView.isDescendant(of: pdfView)
        }

        func updateScrollSyncRegistration(
            coordinator: PDFScrollSyncCoordinator?,
            id: UUID?,
            locked: Bool,
            forceRefresh: Bool = false
        ) {
            let registrationChanged = scrollSyncCoordinator !== coordinator
                || scrollSyncID != id
                || scrollSyncLocked != locked
            if registrationChanged {
                if let scrollSyncCoordinator, let scrollSyncID, let pdfView {
                    scrollSyncCoordinator.unregister(id: scrollSyncID, pdfView: pdfView)
                }
                scrollSyncCoordinator = coordinator
                scrollSyncID = id
            }
            scrollSyncLocked = locked

            guard registrationChanged || forceRefresh else { return }
            guard let coordinator, let id, let pdfView else { return }
            coordinator.updateRegistration(
                pdfView: pdfView,
                id: id,
                locked: locked
            )
            scheduleScrollSyncRegistrationRefresh()
        }

        func updateScrollActivityHandler(
            _ handler: ((PDFVerticalScrollMetrics) -> Void)?
        ) {
            onScrollActivity = handler
        }

        func refreshScrollActivityObservation() {
            guard pdfView?.compactSpread == nil else {
                removeScrollActivityObservation()
                return
            }
            guard
                let pdfView,
                let scrollView = firstScrollView(in: pdfView) ?? pdfView.enclosingScrollView
            else {
                removeScrollActivityObservation()
                return
            }

            guard observedScrollView !== scrollView else { return }
            removeScrollActivityObservation()
            observedScrollView = scrollView
            lastObservedVerticalScrollOrigin = scrollView.contentView.bounds.origin.y
            liveScrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                guard let self, let scrollView else { return }
                MainActor.assumeIsolated {
                    self.reportLiveScroll(from: scrollView)
                }
            }
            liveScrollEndObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                guard let self, let scrollView else { return }
                MainActor.assumeIsolated {
                    self.finishLiveScroll(from: scrollView)
                }
            }
        }

        func scheduleScrollActivityObservationRefresh() {
            guard !scrollActivityRefreshScheduled else { return }
            scrollActivityRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollActivityRefreshScheduled = false
                self.refreshScrollActivityObservation()
            }
        }

        func detach() {
            bodyTextViewport = nil
            viewportRestoreGeneration = UUID()
            cancelSearchNavigation()
            unregisterDeactivationCommitHandler()
            activeSearchSelectionCancellable?.cancel()
            activeSearchSelectionCancellable = nil
            lastSynchronizedSearchSelection = nil
            if let scrollSyncCoordinator, let scrollSyncID, let pdfView {
                scrollSyncCoordinator.unregister(id: scrollSyncID, pdfView: pdfView)
            }
            scrollSyncCoordinator = nil
            scrollSyncID = nil
            scrollSyncLocked = false
            scrollSyncRefreshScheduled = false
            scrollActivityRefreshScheduled = false
            removeScrollActivityObservation()
            NotificationCenter.default.removeObserver(self)
            if let formEventMonitor {
                NSEvent.removeMonitor(formEventMonitor)
                self.formEventMonitor = nil
            }
            if let viewportScrollEventMonitor {
                NSEvent.removeMonitor(viewportScrollEventMonitor)
                self.viewportScrollEventMonitor = nil
            }
            pdfView?.onModifiedScrollGestureEnded = nil
            pdfView?.onSearchAssistedScrollEnded = nil
            pdfView?.onComparisonViewportReflowCompleted = nil
            pdfView?.onComparisonSynchronizedScroll = nil
            pdfView = nil
        }

        private func reportLiveScroll(from scrollView: NSScrollView) {
            guard
                !isApplyingState,
                observedScrollView === scrollView
            else {
                return
            }

            if let scrollSyncCoordinator, let scrollSyncID, let pdfView {
                scrollSyncCoordinator.receiveLiveScroll(
                    pdfView: pdfView, id: scrollSyncID, locked: scrollSyncLocked
                )
            }
            let currentOriginY = scrollView.contentView.bounds.origin.y
            guard PDFLiveScrollReportingPolicy.hasMeaningfulVerticalMovement(
                from: lastObservedVerticalScrollOrigin,
                to: currentOriginY
            ) else {
                return
            }
            lastObservedVerticalScrollOrigin = currentOriginY

            let now = currentTime()
            let delay = PDFLiveScrollReportingPolicy.deliveryDelay(
                lastDeliveryTime: lastLiveScrollDeliveryTime,
                currentTime: now
            )
            if delay <= 0 {
                cancelPendingLiveScrollReport()
                deliverLiveScrollActivity(from: scrollView, at: now)
            } else if pendingLiveScrollReportWorkItem == nil {
                let generation = UUID()
                liveScrollReportGeneration = generation
                let workItem = DispatchWorkItem { [weak self, weak scrollView] in
                    guard let self, let scrollView else { return }
                    guard self.liveScrollReportGeneration == generation else { return }
                    self.pendingLiveScrollReportWorkItem = nil
                    self.deliverLiveScrollActivity(
                        from: scrollView,
                        at: self.currentTime()
                    )
                }
                pendingLiveScrollReportWorkItem = workItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + delay,
                    execute: workItem
                )
            }
        }

        private func deliverLiveScrollActivity(
            from scrollView: NSScrollView,
            at time: TimeInterval
        ) {
            guard !isApplyingState, observedScrollView === scrollView else { return }
            let metrics: PDFVerticalScrollMetrics?
            if usesPagedTwoPageMode {
                metrics = semanticPagedScrollMetrics()
            } else {
                metrics = PDFScrollViewMetricsResolver.resolve(scrollView)
            }
            guard let metrics else { return }
            lastLiveScrollDeliveryTime = time
            onScrollActivity?(metrics)
        }

        private func finishLiveScroll(from scrollView: NSScrollView) {
            guard observedScrollView === scrollView else { return }
            if pendingLiveScrollReportWorkItem != nil {
                cancelPendingLiveScrollReport()
                deliverLiveScrollActivity(
                    from: scrollView,
                    at: currentTime()
                )
            }
            // Session restoration only needs the settled position. Keeping this
            // write off the native delta path leaves PDFKit's tile compositor
            // free to follow the pointer while still preserving the final view.
            captureViewportState(scrollView: scrollView)
            lastObservedVerticalScrollOrigin = scrollView.contentView.bounds.origin.y
            lastLiveScrollDeliveryTime = nil
        }

        private func cancelPendingLiveScrollReport() {
            liveScrollReportGeneration = UUID()
            pendingLiveScrollReportWorkItem?.cancel()
            pendingLiveScrollReportWorkItem = nil
        }

        @objc private func bodyPageWillReplace(_ notification: Notification) {
            guard let pdfView, pdfView.compactSpread == nil,
                  let document = notification.object as? PDFDocument,
                  pdfView.document === document,
                  let page = pdfView.currentPage,
                  let scroll = pdfView.firstDocumentScrollView() else { return }
            let index: Int
            if usesPagedTwoPageMode,
               let requestedIndex = state?.currentPageIndex,
               let requestedPage = document.page(at: requestedIndex),
               pdfView.visiblePages.contains(where: { $0 === requestedPage }) {
                // PDFKit reports the left page for a spread, including while
                // the editor and workspace are on its right page.
                index = requestedIndex
            } else {
                let readingPage = viewportContext == .comparison
                    ? PDFScrollSyncCoordinator.readingPage(in: pdfView) ?? page : page
                index = document.index(for: readingPage)
            }
            guard index != NSNotFound else { return }
            cancelViewportRestoration()
            bodyTextViewport = (document, index, scroll.contentView.bounds.origin, pdfView.scaleFactor)
            wasApplyingStateBeforeBodyReplacement = isApplyingState
            // Removing a page briefly exposes its neighbour. That is not user
            // navigation and must not change the workspace's current page.
            isApplyingState = true
        }

        @objc private func bodyPageDidReplace(_ notification: Notification) {
            guard let snapshot = bodyTextViewport,
                  let document = notification.object as? PDFDocument,
                  snapshot.document === document, let pdfView,
                  let page = document.page(at: snapshot.pageIndex) else { return }
            defer { isApplyingState = wasApplyingStateBeforeBodyReplacement }
            lastAppliedPageIndex = snapshot.pageIndex
            lastAppliedPage = page
            pdfView.layoutDocumentView()
            if pdfView.currentPage !== page { pdfView.go(to: page) }
            restoreBodyTextViewport(consume: false)
        }

        /// SwiftUI performs another layout/fit after the transaction publishes
        /// its revision. Restore once at the end of that same update as well.
        func restoreBodyTextViewportAfterUpdate() {
            restoreBodyTextViewport(consume: true)
        }

        var isPreservingBodyTextViewport: Bool {
            guard let snapshot = bodyTextViewport, let pdfView else { return false }
            return pdfView.document === snapshot.document
                && state?.currentPageIndex == snapshot.pageIndex
        }

        private func restoreBodyTextViewport(consume: Bool) {
            guard let snapshot = bodyTextViewport else { return }
            if consume { bodyTextViewport = nil }
            guard let pdfView, pdfView.document === snapshot.document,
                  state?.currentPageIndex == snapshot.pageIndex,
                  let scroll = pdfView.firstDocumentScrollView() else { return }
            if abs(pdfView.scaleFactor - snapshot.scale) > 0.0001 {
                pdfView.scaleFactor = snapshot.scale
            }
            pdfView.layoutSubtreeIfNeeded()
            let clip = scroll.contentView
            var proposed = clip.bounds
            proposed.origin = snapshot.origin
            clip.setBoundsOrigin(clip.constrainBoundsRect(proposed).origin)
            scroll.reflectScrolledClipView(clip)
        }

        func captureViewportState() {
            let scrollView = pdfView.flatMap {
                firstScrollView(in: $0) ?? $0.enclosingScrollView
            }
            captureViewportState(scrollView: scrollView)
        }

        private func captureViewportState(scrollView: NSScrollView?) {
            guard let pdfView, pdfView.compactSpread == nil else { return }
            let progress: PDFScrollProgress?
            if
                let scrollView,
                let documentView = scrollView.contentView.documentView
            {
                progress = PDFScrollProgress.progress(
                    boundsOrigin: scrollView.contentView.bounds.origin,
                    documentFrame: documentView.frame,
                    viewportSize: scrollView.contentView.bounds.size
                )
            } else {
                progress = nil
            }
            state?.recordPDFViewport(
                autoScales: pdfView.viewportContext == .comparison
                    ? pdfView.comparisonAutomaticallyFitsPage : pdfView.autoScales,
                scaleFactor: pdfView.scaleFactor,
                scrollProgress: progress,
                context: viewportContext
            )
        }

        func scheduleViewportRestoration(_ viewport: PDFViewerViewportState) {
            guard pdfView?.compactSpread == nil, !viewport.usesCompactSpreads else { return }
            // Whole-document percentages from another pane geometry would
            // override comparison's page-preserving automatic fit.
            if viewportContext == .comparison, viewport.autoScales { return }
            guard
                let currentPageIndex = state?.currentPageIndex,
                viewport.scrollProgress(forPageIndex: currentPageIndex) != nil
            else { return }
            cancelSearchNavigation()
            let generation = UUID()
            viewportRestoreGeneration = generation
            DispatchQueue.main.async { [weak self] in
                self?.restoreViewport(viewport, generation: generation)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.restoreViewport(viewport, generation: generation)
                }
            }
        }

        func cancelViewportRestoration() {
            viewportRestoreGeneration = UUID()
        }

        private func restoreViewport(
            _ viewport: PDFViewerViewportState,
            generation: UUID
        ) {
            guard
                viewportRestoreGeneration == generation,
                let currentPageIndex = state?.currentPageIndex,
                let progress = viewport.scrollProgress(forPageIndex: currentPageIndex),
                let pdfView,
                let scrollView = firstScrollView(in: pdfView) ?? pdfView.enclosingScrollView,
                let documentView = scrollView.contentView.documentView
            else { return }

            pdfView.layoutSubtreeIfNeeded()
            let origin = progress.boundsOrigin(
                documentFrame: documentView.frame,
                viewportSize: scrollView.contentView.bounds.size
            )
            if let scrollSyncCoordinator, let scrollSyncID {
                scrollSyncCoordinator.beginProgrammaticUpdate(id: scrollSyncID)
            }
            isApplyingState = true
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isApplyingState = false
            if let scrollSyncCoordinator, let scrollSyncID {
                scrollSyncCoordinator.endProgrammaticUpdate(id: scrollSyncID)
            }
        }

        private func removeScrollActivityObservation() {
            cancelPendingLiveScrollReport()
            if let liveScrollObserver {
                NotificationCenter.default.removeObserver(liveScrollObserver)
                self.liveScrollObserver = nil
            }
            if let liveScrollEndObserver {
                NotificationCenter.default.removeObserver(liveScrollEndObserver)
                self.liveScrollEndObserver = nil
            }
            lastLiveScrollDeliveryTime = nil
            lastObservedVerticalScrollOrigin = nil
            observedScrollView = nil
        }

        private func firstScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            for subview in view.subviews {
                if let scrollView = firstScrollView(in: subview) {
                    return scrollView
                }
            }
            return nil
        }

        private func scheduleScrollSyncRegistrationRefresh() {
            guard !scrollSyncRefreshScheduled else { return }
            scrollSyncRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollSyncRefreshScheduled = false
                guard
                    let scrollSyncCoordinator = self.scrollSyncCoordinator,
                    let scrollSyncID = self.scrollSyncID,
                    let pdfView = self.pdfView
                else {
                    return
                }
                scrollSyncCoordinator.updateRegistration(
                    pdfView: pdfView,
                    id: scrollSyncID,
                    locked: self.scrollSyncLocked
                )
            }
        }

        private func scheduleWidgetSynchronization(
            on page: PDFPage?,
            after delay: TimeInterval
        ) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.state?.synchronizeWidgetValues(on: page)
            }
        }

        /// Mouse and Tab interception are the normal boundary, but accessibility
        /// or a future PDFKit implementation can still create a field editor
        /// directly. Refuse that editor before it accepts text when the workspace
        /// has no durable form-write path.
        @objc func textFieldEditingBegan(_ notification: Notification) {
            guard
                let pdfView,
                pdfView.viewportContext == .comparison
                    || state?.allowsNativeFormEditing != true,
                let textView = notification.object as? NSTextView,
                textView.isFieldEditor,
                Self.responder(textView, belongsTo: pdfView),
                let window = pdfView.window
            else { return }
            _ = window.makeFirstResponder(pdfView)
            if pdfView.viewportContext == .normal {
                state?.presentedError = L10n.string(
                    "security.user_session_read_only",
                    defaultValue: "사용자 암호로 연 PDF는 보안을 유지해 저장할 수 없어 읽기 전용으로 열립니다. 편집하려면 소유자 암호로 다시 여세요."
                )
            }
        }

        /// A field editor may resign because the user clicked a toolbar,
        /// sidebar or another window. Those clicks do not target PDFView and
        /// therefore bypass the local mouse monitor above. Observe the actual
        /// AppKit editing boundary so the complete text session becomes one
        /// semantic PDF undo command after PDFKit commits its widget value.
        @objc func textFieldEditingEnded(_ notification: Notification) {
            guard
                let pdfView,
                let textView = notification.object as? NSTextView,
                textView.isFieldEditor,
                Self.responder(textView, belongsTo: pdfView)
            else { return }
            let editedPage = pdfView.currentPage
            // didEndEditing is the semantic boundary and PDFKit has normally
            // committed the field by this point. Capture synchronously so a
            // toolbar action triggered by the same click is registered after
            // the form command, preserving chronological undo order.
            state?.synchronizeWidgetValues(on: editedPage)
            // A few PDFKit controls publish their value one run-loop later.
            // The semantic snapshot makes this a no-op in the common case.
            scheduleWidgetSynchronization(on: editedPage, after: 0.12)
        }

        func requiresNavigation(
            to requestedPage: PDFPage,
            at requestedIndex: Int,
            in pdfView: PDFView
        ) -> Bool {
            if
                usesPagedTwoPageMode,
                lastAppliedPageIndex == requestedIndex,
                lastAppliedPage === requestedPage,
                pdfView.visiblePages.contains(where: { $0 === requestedPage })
            {
                return false
            }
            let displayedPage = viewportContext == .comparison
                ? PDFScrollSyncCoordinator.readingPage(in: pdfView) : pdfView.currentPage
            return lastAppliedPageIndex != requestedIndex
                || lastAppliedPage !== requestedPage
                || displayedPage !== requestedPage
        }

        /// Identity-only compatibility seam used by document-replacement
        /// regression tests that do not construct a live PDFView hierarchy.
        func requiresNavigation(
            to requestedPage: PDFPage,
            at requestedIndex: Int,
            visiblePage: PDFPage?
        ) -> Bool {
            lastAppliedPageIndex != requestedIndex
                || lastAppliedPage !== requestedPage
                || visiblePage !== requestedPage
        }

        @objc private func pageChanged(_ notification: Notification) {
            // [학습 03] 아래 코드는 PDFKit에서 모델로 변경을 전달합니다. 반대로 모델을 화면에 적용하는 동안에는
            // updateNSView가 isApplyingState를 켜므로 같은 페이지 이동을 다시 모델에 전달하지 않습니다.
            guard
                !isApplyingState,
                self.pdfView?.isApplyingPageFitScale != true,
                !(self.pdfView?.viewportContext == .comparison && self.pdfView?.pageFitUpdateScheduled == true),
                let pdfView = notification.object as? PDFView,
                let document = pdfView.document,
                let page = viewportContext == .comparison
                    ? PDFScrollSyncCoordinator.readingPage(in: pdfView) : pdfView.currentPage
            else { return }

            let index = document.index(for: page)
            guard index != NSNotFound else { return }

            if let spread = (pdfView as? InteractivePDFView)?.compactSpread {
                // A native PDF link may navigate this row. Delegate its target,
                // then restore the row instead of reassigning its page identity.
                if !spread.contains(pageIndex: index) {
                    spread.navigate(to: index)
                    isApplyingState = true
                    if let anchor = document.page(at: spread.pageIndex) { pdfView.go(to: anchor) }
                    isApplyingState = false
                }
                return
            }
            if usesPagedTwoPageMode {
                pdfView.visiblePages.forEach { state?.primeWidgetValues(on: $0) }
                // `currentPage` may be the left page even after an explicit
                // jump to the right page. Preserve that exact requested index
                // while it remains inside the visible spread.
                if
                    let requestedIndex = state?.currentPageIndex,
                    let requestedPage = document.page(at: requestedIndex),
                    pdfView.visiblePages.contains(where: { $0 === requestedPage })
                {
                    lastAppliedPageIndex = requestedIndex
                    lastAppliedPage = requestedPage
                    if let metrics = semanticPagedScrollMetrics(pageIndex: requestedIndex) {
                        onScrollActivity?(metrics)
                    }
                    return
                }
            }

            lastAppliedPageIndex = index
            lastAppliedPage = page
            if state?.currentPageIndex != index {
                state?.setCurrentPage(index)
            }
            if usesPagedTwoPageMode {
                if let metrics = semanticPagedScrollMetrics(pageIndex: index) {
                    onScrollActivity?(metrics)
                }
            }
        }

        private var usesPagedTwoPageMode: Bool {
            if pdfView?.compactSpread != nil { return true }
            return viewportContext == .normal
                && state?.pageColumns == 2
                && (state?.twoPageDisplayMode == .paged || pdfView?.pageNavigationMode == .horizontalPaging)
        }

        private func semanticPagedScrollMetrics(
            pageIndex: Int? = nil
        ) -> PDFVerticalScrollMetrics? {
            guard let state, state.pageCount > 0 else { return nil }
            return PDFVerticalScrollMetrics.semantic(
                pageIndex: pageIndex ?? state.currentPageIndex,
                pageCount: state.pageCount,
                visiblePageCount: 2,
                pageStride: 2
            )
        }

        @objc private func selectionChanged(_ notification: Notification) {
            guard
                !isApplyingState,
                let pdfView = notification.object as? PDFView
            else { return }
            if let interactive = pdfView as? InteractivePDFView {
                interactive.regionSelection.cancel()
            }
            if let spread = (pdfView as? InteractivePDFView)?.compactSpread,
               pdfView.currentSelection == nil,
               state?.currentSelection?.pages.contains(where: { spread.contains(page: $0) }) != true {
                return
            }
            if let interactive = pdfView as? InteractivePDFView,
               interactive.consumeNativeSelectionChange() { return }
            state?.currentSelection = pdfView.currentSelection
        }

        @objc private func scaleChanged(_ notification: Notification) {
            guard !isApplyingState, notification.object as? PDFView === pdfView else { return }
            guard pdfView?.isHandlingModifiedZoom != true else { return }
            if let pdfView, let spread = pdfView.compactSpread {
                let factor = pdfView.scaleFactor / max(0.0001, spread.scaleFactor)
                if abs(factor - 1) > 0.001 { spread.zoom(by: factor) }
                return
            }
            if let pdfView, !pdfView.isApplyingPageFitScale, !pdfView.pageFitUpdateScheduled {
                bodyTextViewport = nil
                cancelSearchNavigation()
                pdfView.endPageFitForManualZoom()
            }
            captureViewportState()
        }
    }
}

final class PDFComparisonClipFrameObservation {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

@MainActor
final class InteractivePDFView: PDFView, NSMenuItemValidation {
    weak var workspaceState: PDFWorkspaceState?
    var compactSpread: PDFCompactSpreadContext?
    let readingDisplayFilter = PDFReadingDisplayFilterController()
    lazy var regionSelection = PDFRegionSelectionController(owner: self)
    lazy var searchScroll = PDFSearchScrollController(owner: self)
    var activePageFitMode: PDFPageFitMode?
    var isApplyingPageFitScale = false
    var pageFitUpdateScheduled = false
    var revealPageAfterFitting = false
    var comparisonAutomaticallyFitsPage = true
    var pendingComparisonPageIndex: Int?
    var comparisonFitViewportSize: CGSize?
    var comparisonClipFrameObservation: PDFComparisonClipFrameObservation?
    weak var observedComparisonClip: NSClipView?
    var observedComparisonClipFrameSize: CGSize?
    var comparisonReflowDestination: PDFDestination?
    weak var comparisonReadingAnchorPage: PDFPage?
    weak var comparisonReadingAnchorClip: NSClipView?
    var comparisonReadingAnchorBounds: CGRect?
    var onComparisonViewportReflowCompleted: (() -> Void)?
    var onComparisonSynchronizedScroll: (() -> Void)?
    var pageNavigationMode: PDFPageNavigationMode = .defaultValue {
        didSet {
            if oldValue != pageNavigationMode {
                resetPageTurnGesture()
                arrowKeyRepeater.stop()
            }
        }
    }
    let arrowKeyRepeater = PDFArrowKeyRepeater()
    var pageTurnGesture = PDFGridPagingGestureSession()
    var pageTurnResetWorkItem: DispatchWorkItem?
    var wheelZoomModifier: PDFWheelZoomModifier = .defaultValue
    /// Comparison views are intentionally read-only even when their source tab
    /// is currently in Editing mode.
    var viewportContext: PDFViewerViewportContext = .normal {
        didSet {
            if viewportContext != .comparison {
                comparisonClipFrameObservation = nil
                observedComparisonClip = nil
                observedComparisonClipFrameSize = nil
            }
        }
    }
    var comparisonContentFixed = false {
        didSet {
            if comparisonContentFixed, !oldValue {
                arrowKeyRepeater.stop()
                resetPageTurnGesture()
                finishViewportScrollGesture()
            }
        }
    }
    var isComparisonContentFixed: Bool {
        viewportContext == .comparison && comparisonContentFixed
    }
    var comparisonAllowsProgrammaticScale = false
    override var scaleFactor: CGFloat {
        get { super.scaleFactor }
        set {
            guard !isComparisonContentFixed || comparisonAllowsProgrammaticScale || isApplyingPageFitScale else { return }
            super.scaleFactor = newValue
        }
    }
    override func zoomIn(_ sender: Any?) {
        guard !isComparisonContentFixed else { return }
        if let compactSpread { compactSpread.zoom(by: 1.2); return }
        super.zoomIn(sender)
    }

    override func zoomOut(_ sender: Any?) {
        guard !isComparisonContentFixed else { return }
        if let compactSpread { compactSpread.zoom(by: 1 / 1.2); return }
        super.zoomOut(sender)
    }

    override func magnify(with event: NSEvent) {
        guard !isComparisonContentFixed else { return }
        if let compactSpread { compactSpread.zoom(by: max(0.1, 1 + event.magnification)); return }
        super.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        guard !isComparisonContentFixed else { return }
        if let compactSpread { compactSpread.zoom(by: 1.5); return }
        super.smartMagnify(with: event)
    }

    private(set) var activeTool: WorkspaceTool = .select
    fileprivate var currentInkSettings = InkSettings()
    fileprivate var inkPage: PDFPage?
    var isDrawingInkStroke: Bool { inkPage != nil }
    fileprivate var inkInput: PDFInkInputBuffer?
    fileprivate var inkUsesPressure = false

    private let inkOverlay = PDFInkPreviewView(frame: .zero)
    private var modifiedScrollGesture = PDFViewportModifiedScrollGestureLatch()
    private var modifiedScrollEndWorkItem: DispatchWorkItem?
    private weak var cachedDocumentScrollView: NSScrollView?
    var onModifiedScrollGestureEnded: (() -> Void)?
    var onSearchAssistedScrollEnded: (() -> Void)?
    /// A Widget consumes a complete mouse sequence in a normal PDFView. In a
    /// comparison viewport we swallow that sequence so PDFKit cannot create a
    /// field editor after the protected mouse-down.
    private var suppressingProtectedWidgetMouseSequence = false
    private var ownsRegionMouseSequence = false
    private var nativeSelectionPreviewID: UUID?
    private weak var nativeSelectionWorkspace: PDFWorkspaceState?
    private weak var nativeSelectionDocument: PDFDocument?
    private var nativeSelectionRevision: UUID?
    private var nativeSelectionGestureActive = false
    private var nativeSelectionGestureID: UUID?
    private var handlingNativeSelectionEvent = false
    private var eraserGesture: PDFEraserGesture?
    private var previousEraserPoint: CGPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        relinquishNativeFileDropDestination()
        installInkOverlay()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        relinquishNativeFileDropDestination()
        installInkOverlay()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finishNativeSelectionPreview() }
        arrowKeyRepeater.stop()
        searchScroll.cancelMotion()
        relinquishNativeFileDropDestination()
    }

    /// PDFView registers the legacy filename pasteboard type and otherwise
    /// becomes the deepest Finder destination, preventing the outer workspace
    /// receiver from seeing a drop over the rendered page. The app owns file
    /// opening at the tab/workspace boundary; PDFKit selection and annotation
    /// movement use their native pointer paths and do not need this destination.
    func relinquishNativeFileDropDestination() {
        unregisterDraggedTypes()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            AppEditCommandRouter.shared.invalidate()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        arrowKeyRepeater.stop()
        if !handlingNativeSelectionEvent { finishNativeSelectionPreview() }
        return super.resignFirstResponder()
    }

    func configure(with state: PDFWorkspaceState) {
        workspaceState = state
        currentInkSettings = state.inkSettings

        // Comparison panels share the source workspace object with the regular
        // window. The user may choose Pen/Eraser in that other window after the
        // comparison panel has appeared, so an onAppear reset is insufficient.
        // Derive an effective read-only tool on every state update instead.
        let effectiveTool: WorkspaceTool = viewportContext == .comparison
            ? .select
            : state.activeTool
        if activeTool != effectiveTool {
            finishEraserGesture()
            activeTool = effectiveTool
            if activeTool != .pen {
                cancelInkStroke()
            }
            window?.invalidateCursorRects(for: self)
        }
        if nativeSelectionGestureActive { _ = validateNativeSelectionPreview() }
        // Comparison panes are strictly read-only and may show four PDFViews
        // at once. Do not allocate editor panels or annotation scanners there;
        // selection, links and scrolling remain native PDFKit behavior.
        if viewportContext == .normal {
            configureAnnotationEditingOverlay()
            configureInlineTextEditingOverlay()
            restoreRenderingOverlayOrderIfNeeded()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if viewportContext == .comparison, newSize != frame.size,
           newSize.width > 1, newSize.height > 1 {
            // Capture before PDFKit changes its clip geometry and emits page
            // notifications. Those notifications describe layout, not reading.
            prepareComparisonViewportReflow()
        }
        super.setFrameSize(newSize)
        if viewportContext == .comparison { schedulePageFitUpdate() }
    }

    override func layout() {
        super.layout()
        readingDisplayFilter.refreshTarget()
        inkOverlay.frame = bounds
        if inkPage != nil { inkOverlay.needsDisplay = true }
        schedulePageFitUpdate()
        regionSelection.refreshOverlay()
        searchScroll.refreshLayout()
    }

    /// PDFKit decides the pointer again while moving between text and scanned
    /// image areas, so a cursor rectangle alone cannot keep Select as an I-beam.
    override func setCursorFor(_ area: PDFAreaOfInterest) {
        if usesTextSelectionCursor(for: area) {
            NSCursor.iBeam.set()
        } else {
            super.setCursorFor(area)
        }
    }

    func usesTextSelectionCursor(for area: PDFAreaOfInterest) -> Bool {
        let interactive: PDFAreaOfInterest = [.linkArea, .controlArea, .textFieldArea, .iconArea, .popupArea]
        return activeTool == .select && area.contains(.pageArea)
            && workspaceState?.document != nil
            && area.intersection(interactive).isEmpty
            && workspaceState?.allows(.copyAndPaste) == true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        switch activeTool {
        case .select:
            break
        case .text:
            addCursorRect(bounds, cursor: .iBeam)
        case .pen, .eraser:
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        finishEraserGesture()
        finishNativeSelectionPreview()
        // Recover if the preceding mouse-up was lost when focus changed.
        ownsRegionMouseSequence = false
        // Events inside the floating panel never reach PDFView. Therefore an
        // event that does arrive here is an outside click and closes the prior
        // transaction before a new tool interprets the same pointer action.
        compactSpread?.commitOtherInlineDraft()
        commitInlineTextEditorBeforePointerAction()
        guard workspaceState?.pendingInlineTextEdit == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let compactSpread, let page = page(for: point, nearest: false) {
            compactSpread.activate(page: page)
        }

        suppressingProtectedWidgetMouseSequence = blockedNativeFormWidget(at: point) != nil
        if suppressingProtectedWidgetMouseSequence {
            clearAnnotationEditingSelection()
            cancelInkStroke()
            window?.makeFirstResponder(self)
            if viewportContext == .normal {
                workspaceState?.presentedError = L10n.string(
                    "security.user_session_read_only",
                    defaultValue: "사용자 암호로 연 PDF는 보안을 유지해 저장할 수 없어 읽기 전용으로 열립니다. 편집하려면 소유자 암호로 다시 여세요."
                )
            }
            return
        }

        if viewportContext == .comparison {
            // Selection, links, wheel/trackpad scrolling and ordinary PDFView
            // behavior stay native. Form Widgets are the one Select-tool case
            // that mutates a document, so intercept only that hit.
            clearAnnotationEditingSelection()
            cancelInkStroke()
            if regionSelection.begin(with: event) {
                ownsRegionMouseSequence = true
                return
            }
            nativeSelectionMouseDown(with: event, at: point)
            return
        }

        if let page = page(for: point, nearest: true) {
            workspaceState?.primeWidgetValues(on: page)
        }
        switch activeTool {
        case .select:
            clearAnnotationEditingSelection()
            if event.clickCount == 2, let state = workspaceState, state.mode == .study,
               let page = page(for: point, nearest: false), let document,
               let annotation = page.annotation(at: convert(point, to: page)),
               annotation.shouldDisplay,
               let note = state.studyNotes(on: document.index(for: page))
                .first(where: { $0.annotation === annotation }) {
                regionSelection.cancel()
                state.editStudyNote(note)
                return
            }
            if regionSelection.begin(with: event) {
                ownsRegionMouseSequence = true
                return
            }
            nativeSelectionMouseDown(with: event, at: point)
        case .text:
            handleTextClick(event)
        case .pen:
            beginInkStroke(event)
        case .eraser:
            beginEraserGesture(event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if nativeSelectionGestureActive, !validateNativeSelectionPreview() { return }
        handlingNativeSelectionEvent = nativeSelectionGestureActive
        defer { handlingNativeSelectionEvent = false }
        if eraserGesture != nil {
            updateEraserGesture(event)
            return
        }
        if suppressingProtectedWidgetMouseSequence {
            return
        }
        if ownsRegionMouseSequence {
            if regionSelection.isDragging { regionSelection.drag(with: event) }
            return
        }
        guard viewportContext == .normal else {
            cancelInkStroke()
            super.mouseDragged(with: event)
            return
        }
        guard activeTool == .pen, inkPage != nil else {
            super.mouseDragged(with: event)
            return
        }
        appendInkPoint(from: event)
    }

    override func mouseUp(with event: NSEvent) {
        let ownsNativeGesture = nativeSelectionGestureActive
        defer {
            handlingNativeSelectionEvent = false
            if ownsNativeGesture {
                finishNativeSelectionPreview()
            }
        }
        if ownsNativeGesture, !validateNativeSelectionPreview() { return }
        handlingNativeSelectionEvent = ownsNativeGesture
        if eraserGesture != nil {
            updateEraserGesture(event)
            finishEraserGesture()
            return
        }
        if suppressingProtectedWidgetMouseSequence {
            suppressingProtectedWidgetMouseSequence = false
            return
        }
        if ownsRegionMouseSequence {
            ownsRegionMouseSequence = false
            if regionSelection.isDragging {
                regionSelection.end(with: event)
            }
            return
        }
        guard viewportContext == .normal else {
            cancelInkStroke()
            super.mouseUp(with: event)
            return
        }
        guard activeTool == .pen, inkPage != nil else {
            super.mouseUp(with: event)
            return
        }
        appendInkPoint(from: event, finishing: true)
        commitInkStroke()
    }

    override func keyDown(with event: NSEvent) {
        if nativeSelectionGestureActive { finishNativeSelectionPreview() }
        if suppressesFixedComparisonNavigation(event) { return }
        if event.keyCode == 53, isDrawingInkStroke {
            cancelInkStroke()
            return
        }
        if event.keyCode == 53, regionSelection.isActive {
            regionSelection.cancel()
            return
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c",
           regionSelection.selection != nil {
            copy(nil)
            return
        }
        if regionSelection.isActive, !event.modifierFlags.contains(.command) {
            regionSelection.cancel()
        }
        if handlePageNavigationKey(event) { return }
        if compactSpread?.keyDown(with: event) == true { return }
        if suppressesNativeFormWidgetTraversal(keyCode: event.keyCode) {
            // PDFKit uses Tab/Shift-Tab to enter and cycle AcroForm controls.
            // A comparison panel has no editable field destination, so consume
            // only that traversal key. Copy, selection, arrows, Page Up/Down,
            // links and every other native PDFView shortcut still reach super.
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        arrowKeyRepeater.handleKeyUp(keyCode: event.keyCode)
        super.keyUp(with: event)
    }

    override func clearSelection() {
        if nativeSelectionGestureActive, !handlingNativeSelectionEvent {
            invalidateNativeSelectionPreview()
        }
        regionSelection.cancel()
        super.clearSelection()
    }

    private func nativeSelectionMouseDown(with event: NSEvent, at point: CGPoint) {
        if let page = page(for: point, nearest: false) {
            let pagePoint = convert(point, to: page)
            let hitsControl = page.annotations.contains {
                let type = $0.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return (type == "Link" || type == "Widget") && $0.bounds.contains(pagePoint)
            }
            if !hitsControl { beginNativeSelectionPreview() }
        }
        handlingNativeSelectionEvent = nativeSelectionGestureActive
        defer { handlingNativeSelectionEvent = false }
        super.mouseDown(with: event)
    }

    /// PDFKit continues drawing its native selection. Only its model bridge is
    /// deferred, so changing characters does not rebuild the SwiftUI workspace.
    func beginNativeSelectionPreview() {
        finishNativeSelectionPreview()
        guard let state = workspaceState, let document,
              state.document === document, activeTool == .select,
              state.allows(.copyAndPaste) else { return }
        nativeSelectionWorkspace = state
        nativeSelectionDocument = document
        nativeSelectionRevision = state.revision
        nativeSelectionPreviewID = state.beginSelectionPreview()
        nativeSelectionGestureActive = true
        nativeSelectionGestureID = UUID()
    }

    private func validateNativeSelectionPreview() -> Bool {
        guard nativeSelectionGestureActive else { return false }
        guard let id = nativeSelectionPreviewID, let state = nativeSelectionWorkspace,
              workspaceState === state, document === nativeSelectionDocument,
              state.document === document, state.revision == nativeSelectionRevision,
              activeTool == .select, (viewportContext == .comparison || state.activeTool == .select),
              state.allows(.copyAndPaste),
              state.ownsSelectionPreview(id) else {
            invalidateNativeSelectionPreview()
            return false
        }
        return true
    }

    private func invalidateNativeSelectionPreview() {
        if let id = nativeSelectionPreviewID { nativeSelectionWorkspace?.cancelSelectionPreview(id) }
        nativeSelectionPreviewID = nil
        // Keep owning this mouse sequence until release. Late PDFKit events
        // must not replace a search hit or selection from another document.
    }

    @discardableResult
    func consumeNativeSelectionChange() -> Bool {
        guard nativeSelectionGestureActive else { return false }
        if validateNativeSelectionPreview(), let id = nativeSelectionPreviewID {
            _ = nativeSelectionWorkspace?.updateSelectionPreview(currentSelection, id: id)
        }
        return true
    }

    func finishNativeSelectionPreview() {
        guard nativeSelectionGestureActive else { return }
        if validateNativeSelectionPreview(), let id = nativeSelectionPreviewID {
            _ = nativeSelectionWorkspace?.updateSelectionPreview(currentSelection, id: id)
            _ = nativeSelectionWorkspace?.commitSelectionPreview(id)
        }
        nativeSelectionPreviewID = nil
        nativeSelectionWorkspace = nil
        nativeSelectionDocument = nil
        nativeSelectionRevision = nil
        nativeSelectionGestureActive = false
        nativeSelectionGestureID = nil
    }

    func scheduleNativeSelectionCommit(allowsDirectEditing: Bool = false) {
        guard let id = nativeSelectionGestureID else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.nativeSelectionGestureID == id else { return }
            let selectionIsCurrent = self.validateNativeSelectionPreview()
            self.finishNativeSelectionPreview()
            if selectionIsCurrent, allowsDirectEditing { self.beginEditingSelectedBodyText() }
        }
    }

    /// Enter TextKit only after the selection gesture has finished. This keeps
    /// PDFium snapshots and editor layout out of the pointer-move hot path.
    /// Mapping must cover the complete selection; an unsupported selection
    /// remains available for ordinary copying instead of editing one run.
    @discardableResult
    func beginEditingSelectedBodyText() -> Bool {
        guard viewportContext == .normal, activeTool == .select,
              let state = workspaceState, state.activeTool == .select,
              state.allowsInlineTextEditing, state.document === document,
              state.pendingInlineTextEdit == nil, !regionSelection.isDragging,
              !nativeSelectionGestureActive,
              let selection = state.currentSelection,
              state.requestBodyTextEdit(selection: selection, preservesSelectionTool: true)
        else { return false }
        regionSelection.cancel()
        super.clearSelection()
        state.currentSelection = nil
        configureInlineTextEditingOverlay()
        focusInlineTextEditorSelection()
        return true
    }

    override func copy(_ sender: Any?) {
        guard let selection = regionSelection.selection else {
            super.copy(sender)
            return
        }
        guard workspaceState?.allows(.copyAndPaste) == true,
              workspaceState?.currentSelection === selection,
              document === workspaceState?.document,
              let text = selection.string, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return workspaceState?.allows(.copyAndPaste) == true
                && (regionSelection.selection != nil || currentSelection != nil)
        }
        return true
    }

    /// A fixed pane retains selection/copy but consumes movement and zoom input.
    func suppressesFixedComparisonNavigation(_ event: NSEvent) -> Bool {
        guard isComparisonContentFixed else { return false }
        switch event.type {
        case .scrollWheel, .magnify, .smartMagnify:
            return true
        case .keyDown:
            if [49, 115, 116, 119, 121, 123, 124, 125, 126].contains(event.keyCode) {
                return true
            }
            return event.modifierFlags.contains(.command)
                && ["+", "=", "-", "0"].contains(event.charactersIgnoringModifiers ?? "")
        default:
            return false
        }
    }

    /// Small deterministic seam for the keyboard half of comparison read-only
    /// enforcement. Hardware-layout modifiers do not change the Tab key code,
    /// so this covers both forward and Shift-Tab widget traversal.
    func suppressesComparisonWidgetTraversal(keyCode: UInt16) -> Bool {
        viewportContext == .comparison && keyCode == 48
    }

    /// Normal encrypted user sessions are subject to the same protection as a
    /// comparison viewport. Missing workspace authority is deliberately blocked.
    func suppressesNativeFormWidgetTraversal(keyCode: UInt16) -> Bool {
        keyCode == 48
            && (viewportContext == .comparison
                || workspaceState?.allowsNativeFormEditing != true)
    }

    func cancelInkStroke() {
        let hadPreview = inkPage != nil || inkInput != nil
        inkPage = nil
        inkInput = nil
        inkUsesPressure = false
        inkOverlay.isHidden = true
        if hadPreview {
            inkOverlay.needsDisplay = true
        }
    }

    /// Handles only an unambiguous convenience gesture. Returning `false`
    /// leaves the original NSEvent untouched so PDFKit keeps ownership of
    /// ordinary scrolling, form widgets, annotations, selection and pinch.
    @discardableResult
    func handleViewportScroll(_ event: NSEvent) -> Bool {
        guard !isComparisonContentFixed else { return true }
        let input = PDFViewportScrollInput(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            modifiers: Self.viewportModifiers(from: event.modifierFlags)
        )
        let intent = PDFViewportScrollIntentResolver.resolve(
            input,
            zoomModifier: wheelZoomModifier
        )
        let owner = modifiedScrollGesture.ownerForEvent(
            intent: intent,
            touchPhasePresent: !event.phase.isEmpty,
            touchPhaseBegan: event.phase.contains(.mayBegin)
                || event.phase.contains(.began),
            momentumPhasePresent: !event.momentumPhase.isEmpty
        )

        guard let owner else {
            modifiedScrollEndWorkItem?.cancel()
            modifiedScrollEndWorkItem = nil
            return handlePageTurnScroll(event)
        }

        resetPageTurnGesture()

        switch owner {
        case .zoom:
            if let stepFactor = PDFViewportScrollIntentResolver.zoomStepFactor(
                deltaY: input.deltaY,
                hasPreciseDeltas: input.hasPreciseDeltas
            ) {
                _ = zoomAroundPointer(
                    stepFactor: stepFactor,
                    pointerInView: convert(event.locationInWindow, from: nil)
                )
            }
        case .horizontalPan:
            if let delta = PDFViewportScrollIntentResolver.horizontalPanDelta(
                deltaX: input.deltaX,
                deltaY: input.deltaY,
                hasPreciseDeltas: input.hasPreciseDeltas
            ) {
                _ = panHorizontally(wheelDelta: delta)
            }
        }

        updateModifiedScrollLifecycle(after: event)
        // An owned phase is consumed even when it reaches a scale/pan edge.
        return true
    }

    /// Cheap preflight for the local event monitor. A latched gesture keeps
    /// ownership through momentum even after the keyboard modifier is released.
    func viewportScrollRequiresInterception(_ event: NSEvent) -> Bool {
        if modifiedScrollGesture.owner != nil { return true }
        if canHandlePageTurnScroll(event) { return true }
        let input = PDFViewportScrollInput(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            modifiers: Self.viewportModifiers(from: event.modifierFlags)
        )
        return PDFViewportScrollIntentResolver.resolve(
            input,
            zoomModifier: wheelZoomModifier
        ) != .native
    }

    var isHandlingModifiedZoom: Bool {
        modifiedScrollGesture.owner == .zoom
    }

    func resetViewportScrollGesture() {
        resetPageTurnGesture()
        modifiedScrollEndWorkItem?.cancel()
        modifiedScrollEndWorkItem = nil
        modifiedScrollGesture.reset()
    }

    func finishViewportScrollGesture() {
        resetPageTurnGesture()
        let hadOwner = modifiedScrollGesture.owner != nil
        resetViewportScrollGesture()
        if hadOwner {
            onModifiedScrollGestureEnded?()
        }
    }

    func invalidateDocumentScrollViewCache() {
        arrowKeyRepeater.stop()
        cachedDocumentScrollView = nil
    }

    func restoreRenderingOverlayOrderIfNeeded() {
        restoreEditingOverlayOrderIfNeeded(above: inkOverlay)
        regionSelection.refreshOverlay()
    }

    func positionRegionSelectionOverlay(_ overlay: NSView) {
        let inkIndex = subviews.firstIndex { $0 === inkOverlay }
        let overlayIndex = subviews.firstIndex { $0 === overlay }
        guard let inkIndex else { return }
        if overlayIndex != inkIndex - 1 {
            addSubview(overlay, positioned: .below, relativeTo: inkOverlay)
        }
    }

    var inkPreviewSubviewIndexForTesting: Int? {
        subviews.firstIndex { $0 === inkOverlay }
    }

    private func updateModifiedScrollLifecycle(after event: NSEvent) {
        modifiedScrollEndWorkItem?.cancel()
        modifiedScrollEndWorkItem = nil

        if
            event.phase.contains(.cancelled)
                || event.momentumPhase.contains(.ended)
                || event.momentumPhase.contains(.cancelled)
        {
            finishViewportScrollGesture()
            return
        }

        let delay: TimeInterval?
        if event.phase.contains(.ended) {
            modifiedScrollGesture.touchEnded()
            delay = 0.28
        } else if event.phase.isEmpty, event.momentumPhase.isEmpty {
            delay = 0.16
        } else {
            // Defensive fallback for devices/drivers that omit an explicit
            // ended phase. Continuous events refresh this deadline.
            delay = 0.6
        }

        guard let delay else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishViewportScrollGesture()
        }
        modifiedScrollEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    static func viewportModifiers(
        from flags: NSEvent.ModifierFlags
    ) -> PDFViewportScrollModifiers {
        var result: PDFViewportScrollModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    @discardableResult
    func zoomAroundPointer(stepFactor: CGFloat, pointerInView: CGPoint) -> Bool {
        guard document != nil else { return false }
        guard let anchorPage = page(for: pointerInView, nearest: true) else { return false }
        let anchorOnPage = convert(pointerInView, to: anchorPage)
        let oldScale = scaleFactor
        let targetScale = PDFViewportScrollIntentResolver.clampedScale(
            currentScale: oldScale,
            stepFactor: stepFactor,
            minimumScale: minScaleFactor,
            maximumScale: maxScaleFactor
        )
        guard abs(targetScale - oldScale) > 0.000_001 else { return true }

        endPageFitForManualZoom()
        autoScales = false
        scaleFactor = targetScale
        layoutDocumentView()
        layoutSubtreeIfNeeded()

        if let scrollView = firstDocumentScrollView() {
            let clipView = scrollView.contentView
            let anchorAfterZoom = convert(anchorOnPage, from: anchorPage)
            let anchorInClip = clipView.convert(anchorAfterZoom, from: self)
            // PDFKit implements scaleFactor using NSScrollView magnification,
            // which changes clipView.bounds.size. Recompute the cursor's local
            // offset *after* scaling instead of reusing pre-scale pixels.
            let pointerInClip = clipView.convert(pointerInView, from: self)
            let pointerOffsetAfterScale = CGPoint(
                x: pointerInClip.x - clipView.bounds.origin.x,
                y: pointerInClip.y - clipView.bounds.origin.y
            )
            var proposedBounds = clipView.bounds
            proposedBounds.origin.x = anchorInClip.x - pointerOffsetAfterScale.x
            proposedBounds.origin.y = anchorInClip.y - pointerOffsetAfterScale.y
            let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
            clipView.setBoundsOrigin(constrainedBounds.origin)
            scrollView.reflectScrolledClipView(clipView)
        }

        return true
    }

    private func panHorizontally(wheelDelta: CGFloat) -> Bool {
        guard
            wheelDelta.isFinite,
            abs(wheelDelta) > 0.0001,
            let scrollView = firstDocumentScrollView(),
            let documentView = scrollView.contentView.documentView
        else { return false }

        let clipView = scrollView.contentView
        let availableWidth = documentView.frame.width - clipView.bounds.width
        guard availableWidth > 0.5 else {
            // Shift is horizontal-only even when the fitted page has nowhere
            // to pan; passing it through could unexpectedly scroll vertically.
            return true
        }

        var proposedBounds = clipView.bounds
        proposedBounds.origin.x -= wheelDelta
        let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
        guard abs(constrainedBounds.origin.x - clipView.bounds.origin.x) > 0.0001 else {
            // This PDF canvas owns the horizontal gesture even at its edge;
            // handing it back would unexpectedly turn the same gesture into
            // vertical document scrolling.
            return true
        }
        clipView.setBoundsOrigin(constrainedBounds.origin)
        scrollView.reflectScrolledClipView(clipView)
        return true
    }

    func firstDocumentScrollView() -> NSScrollView? {
        if
            let cachedDocumentScrollView,
            cachedDocumentScrollView === enclosingScrollView
                || cachedDocumentScrollView.isDescendant(of: self)
        {
            return cachedDocumentScrollView
        }
        let resolved = Self.firstScrollView(in: self) ?? enclosingScrollView
        cachedDocumentScrollView = resolved
        return resolved
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let result = firstScrollView(in: subview) { return result }
        }
        return nil
    }

    private func installInkOverlay() {
        inkOverlay.owner = self
        inkOverlay.isHidden = true
        inkOverlay.autoresizingMask = [.width, .height]
        inkOverlay.frame = bounds
        addSubview(inkOverlay, positioned: .above, relativeTo: nil)
    }

    /// Testable event-boundary seam for comparison-form protection.
    /// Coordinates are in this PDFView's view space.
    func comparisonWidget(at viewPoint: CGPoint) -> PDFAnnotation? {
        guard viewportContext == .comparison else { return nil }
        return widget(at: viewPoint)
    }

    /// Returns a widget only when native editing is forbidden for this viewport.
    /// Coordinates are in this PDFView's view space.
    func blockedNativeFormWidget(at viewPoint: CGPoint) -> PDFAnnotation? {
        guard
            viewportContext == .comparison
                || workspaceState?.allowsNativeFormEditing != true
        else { return nil }
        return widget(at: viewPoint)
    }

    private func widget(at viewPoint: CGPoint) -> PDFAnnotation? {
        guard let page = page(for: viewPoint, nearest: false) else { return nil }
        let pagePoint = convert(viewPoint, to: page)
        return page.annotations.reversed().first { annotation in
            let type = annotation.type?.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            return type == "Widget" && annotation.bounds.contains(pagePoint)
        }
    }

    private func handleTextClick(_ event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        let pagePoint = convert(viewPoint, to: page)
        let hitAnnotation = page.annotation(at: pagePoint)
        let editableAnnotation: PDFAnnotation?
        if hitAnnotation?.shouldDisplay == true,
           hitAnnotation?.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText" {
            editableAnnotation = hitAnnotation
        } else {
            editableAnnotation = nil
        }

        guard let document, let state = workspaceState else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return }

        if viewportContext == .normal, state.allowsInlineTextEditing {
            // Double-click editing of existing objects is handled by the
            // selection overlay. The Text tool also supports a single-click
            // path, but only for HwattakPDF-owned FreeText annotations.
            let appOwnedFreeText = editableAnnotation.flatMap { annotation in
                EditableAnnotationIdentity.kind(of: annotation) == .freeText
                    ? annotation
                    : nil
            }

            // A third-party FreeText may carry authoring semantics or custom
            // appearance data that HwattakPDF does not understand. Do not
            // reinterpret a click on that object as a request to create a new
            // blank inline annotation on top of it. Falling through preserves
            // the established review sheet, where adoption remains explicit.
            let canUseInlinePath = editableAnnotation == nil || appOwnedFreeText != nil

            if editableAnnotation == nil {
                _ = state.requestBodyTextEdit(pageIndex: pageIndex, point: pagePoint)
                configureInlineTextEditingOverlay()
                focusInlineTextEditor(at: viewPoint)
                return
            }
            if canUseInlinePath, state.requestInlineTextEdit(
                pageIndex: pageIndex, point: pagePoint, annotation: appOwnedFreeText
            ) {
                configureInlineTextEditingOverlay()
                return
            }
            if
                canUseInlinePath,
                state.inlineTextEditRejectionReason == .existingTextExceedsSafetyLimit
            {
                // The object was deliberately left byte-for-byte unchanged.
                // Do not route it into the legacy unbounded TextEditor or
                // reinterpret the click as a new annotation.
                return
            }
        }

        // Viewer/Study notes and unowned third-party FreeText retain the
        // existing transactional sheet instead of being silently adopted by
        // the direct editing overlay.
        state.requestTextEdit(
            pageIndex: pageIndex,
            point: pagePoint,
            annotation: editableAnnotation
        )
    }

    private func beginInkStroke(_ event: NSEvent) {
        // `activeTool` is a view snapshot and can be one SwiftUI update behind
        // a global mode/tool shortcut. Refuse to start from that stale snapshot
        // unless the current model still authorizes handwriting with Pen.
        guard
            viewportContext == .normal,
            let state = workspaceState,
            state.allows(.handwriting),
            state.activeTool == .pen
        else {
            cancelInkStroke()
            super.mouseDown(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        inkPage = page
        // SwiftUI may reconfigure this view during a drag (for example after a
        // preset shortcut). One stroke must retain one coherent appearance.
        inkInput = PDFInkInputBuffer(settings: state.inkSettings)
        inkUsesPressure = state.inkSettings.pressureEnabled
            && state.inkSettings.drawingOptions.shape == .freehand
            && (event.subtype == .tabletPoint || event.type == .tabletPoint)
        appendInkPoint(from: event, acceptingDuplicate: true)
    }

    override func tabletPoint(with event: NSEvent) {
        guard inkPage != nil else { super.tabletPoint(with: event); return }
        appendInkPoint(from: event)
    }

    private func appendInkPoint(from event: NSEvent, acceptingDuplicate: Bool = false, finishing: Bool = false) {
        guard let page = inkPage, let settings = inkInput?.settings else { return }
        var invalidated = CGRect.null
        if !inkUsesPressure, settings.pressureEnabled, settings.drawingOptions.shape == .freehand,
           event.subtype == .tabletPoint || event.type == .tabletPoint {
            inkUsesPressure = true
            let pressure = CGFloat(event.pressure)
            invalidated = inkInput?.promoteToPressure(pressure.isFinite ? pressure : 1) ?? .null
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let pagePoint = convert(viewPoint, to: page)
        let pageBounds = page.bounds(for: displayBox)
        let tolerance = max(2, settings.width)
        guard pageBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(pagePoint) else { return }

        if !acceptingDuplicate, let previous = inkInput?.points.last {
            let distance = hypot(pagePoint.x - previous.x, pagePoint.y - previous.y)
            // Sample in screen points so zooming out does not flood capture
            // with invisible motion. Always keep the actual release endpoint.
            let minimum = finishing ? 0.000_001 : 0.35 / max(0.01, scaleFactor)
            if distance < minimum {
                invalidateInkPreview(invalidated, on: page)
                return
            }
        }

        let raw = CGFloat(event.pressure)
        let pressure = inkUsesPressure && raw.isFinite ? min(1, max(0, raw)) : 1
        invalidated = invalidated.union(inkInput?.append(pagePoint, pressure: pressure) ?? .null)
        inkOverlay.isHidden = false
        invalidateInkPreview(invalidated, on: page)
    }

    private func invalidateInkPreview(_ pageRect: CGRect, on page: PDFPage) {
        guard !pageRect.isNull, !pageRect.isInfinite else { return }
        let rect = inkOverlay.convert(convert(pageRect, from: page), from: self)
        inkOverlay.setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
    }

    private func commitInkStroke() {
        guard let page = inkPage, let input = inkInput else {
            cancelInkStroke()
            return
        }
        let committed = commitInkStroke(input.points, on: page,
            pressures: inkUsesPressure ? input.pressures : nil, settings: input.settings)
        cancelInkStroke()
        if committed {
            needsDisplay = true
        }
    }

    /// Final mutation boundary for a native PDFKit Ink annotation.
    ///
    /// Mouse-down and mouse-up can straddle a mode or tool change. Re-checking
    /// the live model here prevents a stale drag from committing after Pen has
    /// become unavailable. The page identity check also prevents a pending
    /// stroke from being attached to a PDF that has since been replaced.
    @discardableResult
    func commitInkStroke(_ capturedPoints: [CGPoint], on page: PDFPage, pressures: [CGFloat]? = nil,
                         settings: InkSettings? = nil) -> Bool {
        guard
            viewportContext == .normal,
            let state = workspaceState,
            state.allows(.handwriting),
            state.activeTool == .pen,
            let document = state.document,
            document.index(for: page) != NSNotFound,
            let first = capturedPoints.first
        else { return false }

        let settings = settings ?? currentInkSettings
        if pressures != nil || settings.pdfInkColor.alphaComponent < 1 || settings.style != .ink
            || settings.drawingOptions.requiresCustomAppearance {
            let pressures = pressures ?? Array(repeating: CGFloat(1), count: capturedPoints.count)
            guard let annotation = PressureInkAnnotation(points: capturedPoints, pressures: pressures,
                width: settings.width, color: settings.pdfInkColor, style: settings.style,
                options: settings.drawingOptions) else { return false }
            page.addAnnotation(annotation)
            state.registerAddedAnnotation(annotation, on: page, message: L10n.string("펜 주석을 추가했습니다."), actionLocalization: .init(key: "펜 주석을 추가했습니다."))
            return true
        }
        var points = capturedPoints
        if points.count == 1 {
            points.append(CGPoint(x: first.x + max(0.2, settings.width * 0.08), y: first.y))
        }

        let lineWidth = max(0.2, settings.width)
        let padding = max(2, lineWidth * 1.25)
        let minX = points.map(\.x).min() ?? first.x
        let maxX = points.map(\.x).max() ?? first.x
        let minY = points.map(\.y).min() ?? first.y
        let maxY = points.map(\.y).max() ?? first.y
        let bounds = CGRect(
            x: minX - padding,
            y: minY - padding,
            width: max(maxX - minX + padding * 2, padding * 2),
            height: max(maxY - minY + padding * 2, padding * 2)
        )

        let path = NSBezierPath()
        path.move(to: CGPoint(x: points[0].x - bounds.minX, y: points[0].y - bounds.minY))
        for point in points.dropFirst() {
            path.line(to: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY))
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        PDFAnnotationPrivacy.clearImplicitAuthor(on: annotation)
        annotation.color = settings.pdfInkColor
        annotation.modificationDate = Date()
        annotation.setValue("HwattakPDF-Ink-\(UUID().uuidString)", forAnnotationKey: .name)
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        annotation.add(path)
        page.addAnnotation(annotation)

        state.registerAddedAnnotation(
            annotation,
            on: page,
            message: L10n.string("펜 주석을 추가했습니다."), actionLocalization: .init(key: "펜 주석을 추가했습니다.")
        )
        return true
    }

    private func beginEraserGesture(_ event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard viewportContext == .normal, let state = workspaceState,
              let page = page(for: viewPoint, nearest: false),
              let gesture = PDFEraserGesture(workspace: state, page: page) else { return }
        window?.makeFirstResponder(self)
        eraserGesture = gesture
        previousEraserPoint = convert(viewPoint, to: page)
        updateEraserGesture(event)
    }

    private func updateEraserGesture(_ event: NSEvent) {
        guard let gesture = eraserGesture, let state = workspaceState,
              viewportContext == .normal, state.activeTool == .eraser else {
            finishEraserGesture()
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard page(for: viewPoint, nearest: false) === gesture.page else {
            previousEraserPoint = nil
            return
        }
        let point = convert(viewPoint, to: gesture.page)
        let mode = event.modifierFlags.contains(.option) ? state.eraserMode.alternate : state.eraserMode
        if gesture.erase(from: previousEraserPoint ?? point, to: point,
                         radius: state.eraserSize / 2, mode: mode) {
            needsDisplay = true
        }
        previousEraserPoint = point
    }

    func finishEraserGesture() {
        let gesture = eraserGesture
        eraserGesture = nil
        previousEraserPoint = nil
        gesture?.finish()
    }
}

@MainActor
private final class PDFInkPreviewView: NSView {
    weak var owner: InteractivePDFView?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let owner, let page = owner.inkPage,
              let context = NSGraphicsContext.current?.cgContext,
              let input = owner.inkInput, input.geometry != nil else { return }
        // Three PDFKit conversions describe the entire affine page-to-overlay
        // mapping, including crop origin, page rotation, scrolling and zoom.
        // Long strokes no longer call PDFView.convert once per sample/frame.
        let origin = convert(owner.convert(CGPoint.zero, from: page), from: owner)
        let x = convert(owner.convert(CGPoint(x: 1, y: 0), from: page), from: owner)
        let y = convert(owner.convert(CGPoint(x: 0, y: 1), from: page), from: owner)
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
            c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y))
        PDFInkStrokeRenderer.draw(strokes: input.strokes(intersecting: context.boundingBoxOfClipPath), color: input.settings.pdfInkColor,
            style: input.settings.style, options: input.settings.drawingOptions, in: context)
    }
}
