// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 창 하나의 탭 막대와 활성 문서/비교 화면을 조립한다.
///
/// 활성 탭 하나만 무거운 `WorkspaceView`/`PDFView`를 가지며 비활성 clean 탭은
/// `PDFTabMemoryManager`가 휴면시킬 수 있다. Finder open 이벤트, 탭 tear-out,
/// 비교 mode와 session snapshot도 창 수명 경계인 이 뷰에서 조정한다.
@MainActor
struct TabbedWorkspaceView: View {
    @ObservedObject var workspace: MultiDocumentWorkspaceState
    let handlesLaunchArguments: Bool
    let windowID: UUID?
    let sessionCoordinator: AppWideWorkspaceSessionCoordinator?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PDFTabMemorySettings.loadedTabBudgetKey)
    private var loadedTabBudget = PDFTabMemorySettings.defaultLoadedTabBudget
    /// 뷰 재계산마다 새 manager를 만들지 않도록 창 수명 동안 한 번만 생성한다.
    @StateObject private var memoryManager: PDFTabMemoryManager
    @StateObject private var extensionHost: PluginExtensionHost
    @State private var showingComparisonSetup = false
    @State private var isComparing = false
    @State private var comparisonConfiguration = PDFComparisonConfiguration()
    @State private var comparisonWorkspaceID: UUID
    @State private var comparisonOpenTask: Task<Void, Never>?
    @State private var isOpeningComparisonDocument = false
    @State private var showingComparisonOpenError = false
    @State private var launchArgumentsHandled = false
    @State private var draggedTabID: UUID?
    @State private var isTabTearOutTargeted = false
    @State private var isWorkspaceFileDropTargeted = false
    /// Focus mode is a temporary window presentation, not a document setting.
    /// Keeping it here lets the same state hide both the tab bar and the
    /// workspace chrome without changing any tab's saved sidebar preference.
    @State private var isFocusMode = false
    @State private var isGalleryPresented = false

    init(
        workspace: MultiDocumentWorkspaceState,
        handlesLaunchArguments: Bool = true,
        windowID: UUID? = nil,
        sessionCoordinator: AppWideWorkspaceSessionCoordinator? = nil
    ) {
        self.workspace = workspace
        self.handlesLaunchArguments = handlesLaunchArguments
        self.windowID = windowID
        self.sessionCoordinator = sessionCoordinator
        let restoredComparison = sessionCoordinator?.comparisonPresentationState(
            windowID: windowID,
            workspaceID: workspace.activeWorkspaceID
        )
        _comparisonWorkspaceID = State(initialValue: workspace.activeWorkspaceID)
        _comparisonConfiguration = State(
            initialValue: restoredComparison?.configuration
                ?? PDFComparisonConfiguration()
        )
        _isComparing = State(
            initialValue: restoredComparison?.isComparing ?? false
        )
        _memoryManager = StateObject(
            wrappedValue: PDFTabMemoryManager(workspace: workspace)
        )
        _extensionHost = StateObject(wrappedValue: PluginExtensionHost(collection: workspace))
    }

    private var comparisonDocuments: [ComparisonDocument] {
        workspace.comparisonDocuments
    }

    @EmberTheme private var theme

    private var windowTitle: String {
        guard let activeWorkspace = workspace.activeWorkspace else { return "EmberPDF" }
        return !activeWorkspace.hasOpenDocument
            ? "EmberPDF"
            : activeWorkspace.windowTitle
    }

    var body: some View {
        HStack(spacing: 0) {
            lifecycleWorkspace
            if !isFocusMode, let item = extensionHost.selectedExtension {
                Divider()
                PluginExtensionSidebar(host: extensionHost, item: item, session: item.session)
                    .id(item.session.id)
            }
        }
        .environment(\.pluginCommandScope, extensionHost.id)
        .focusedSceneValue(\.pluginExtensionScope, extensionHost.id)
        .alert(
            L10n.string("recent.reconnect.title"),
            isPresented: Binding(
                get: { workspace.recentDocumentRecovery != nil },
                set: { if !$0 { workspace.recentDocumentRecovery = nil } }
            ),
            presenting: workspace.recentDocumentRecovery
        ) { request in
            Button(L10n.string("recent.reconnect.choose")) {
                // Let the alert dismiss before presenting the system chooser.
                DispatchQueue.main.async {
                    reconnectRecentDocument(request)
                }
            }
            Button(L10n.format("recent.remove", request.displayName), role: .destructive) {
                workspace.removeRecentDocument(id: request.recentID)
            }
            Button(L10n.string("action.cancel"), role: .cancel) { }
        } message: { request in
            Text(L10n.format("recent.reconnect.message", request.displayName))
        }
        .alert(L10n.string("comparison.document.error"), isPresented: $showingComparisonOpenError) {
            Button(L10n.string("action.confirm"), role: .cancel) { }
        }
        .onAppear {
            extensionHost.documentCommandsAllowed = !isComparing && !isGalleryPresented
            extensionHost.start()
        }
        .onChange(of: isComparing || isGalleryPresented) { _, readOnly in
            extensionHost.documentCommandsAllowed = !readOnly
        }
        .onDisappear { extensionHost.stop() }
    }

    /// Split the large scene into smaller typed stages. Besides keeping the
    /// code readable, this avoids Swift's generic type-checker timing out as
    /// focused values, sheets and lifecycle observers are added over time.
    private var chromeWorkspace: some View {
        ZStack {
            // Keep the reader and its geometry mounted while the overview is
            // open, preserving the exact zoom, scroll position and side panels.
            VStack(spacing: 0) {
                if !isFocusMode {
                    tabBar
                    if !extensionHost.extensions.isEmpty {
                        PluginExtensionShelf(host: extensionHost)
                    }
                }
                workspaceLayer
            }
            .opacity(isGalleryPresented ? 0 : 1)
            .disabled(isGalleryPresented)
            .allowsHitTesting(!isGalleryPresented)
            .accessibilityHidden(isGalleryPresented)

            if isGalleryPresented {
                PDFDocumentGalleryView(
                    workspace: workspace,
                    onSelect: selectGalleryDocument,
                    onClose: closeGallery
                )
                .zIndex(3)
            }
        }
        .background(theme.canvas)
        .emberTint()
        .focusedSceneValue(
            \.documentSearchAvailable,
            !isComparing && !isGalleryPresented && workspace.activeWorkspace?.document != nil
        )
        // Commands live outside this view hierarchy. Publish the presentation
        // boundary so menu clicks made after focusing the comparison toolbar
        // cannot mutate the hidden normal editor's workspace.
        .focusedSceneValue(\.comparisonReadOnlyActive, isComparing || isGalleryPresented)
        .focusedSceneValue(
            \.documentGalleryCommands,
            DocumentGalleryCommandContext(
                isPresented: isGalleryPresented,
                canOpen: canOpenGallery,
                toggle: toggleGallery
            )
        )
        .focusedSceneValue(
            \.workspacePresentationCommands,
            WorkspacePresentationCommandContext(
                isFocusMode: isFocusMode,
                canToggleFocusMode: canToggleFocusMode,
                setFocusMode: setFocusMode
            )
        )
        .navigationTitle(windowTitle)
        .sheet(isPresented: $showingComparisonSetup) {
            ComparisonSetupSheet(
                documents: comparisonDocuments,
                configuration: $comparisonConfiguration,
                onCancel: { showingComparisonSetup = false },
                onStart: {
                    // Preserve live form/inline edits before the normal
                    // reader unmounts. Transactional study-note drafts remain
                    // drafts; deactivation never implies their Apply action.
                    workspace.activeWorkspace?.prepareForDeactivation()
                    showingComparisonSetup = false
                    memoryManager.setProtectedTabIDs(
                        Set(comparisonConfiguration.selectedDocumentIDs)
                    )
                    isComparing = true
                }
            )
        }
    }

    private var stateObservedWorkspace: some View {
        chromeWorkspace
        .onChange(of: comparisonDocuments.map(\.id)) { _, availableIDs in
            normalizeComparisonForAvailableDocuments(availableIDs)
        }
        .onChange(of: workspace.activeTabID) { oldValue, newValue in
            if oldValue != newValue { closeGallery() }
            memoryManager.activeTabDidChange()
            if isComparing, oldValue != newValue {
                exitComparison()
            }
        }
        .onChange(of: workspace.activeWorkspaceID) { _, newWorkspaceID in
            cancelComparisonOpen()
            closeGallery()
            // Commit the outgoing workspace's last comparison snapshot before
            // replacing the local presentation state with the next workspace.
            persistComparisonPresentationState()
            memoryManager.activeTabDidChange()
            showingComparisonSetup = false
            restoreComparisonPresentationState(for: newWorkspaceID)
            clearTabDragState()
        }
        .onChange(of: workspace.allTabs.map(\.id)) { _, _ in
            memoryManager.workspaceContentsDidChange()
        }
        .onChange(of: workspace.allTabs.map { $0.workspace.canHibernate }) { _, _ in
            // Re-evaluate only when the eligibility bit changes. Observing all
            // workspace updates directly would run the LRU policy for every
            // scroll or selection event; this distinct value catches save,
            // draft and OCR completion without adding that steady CPU cost.
            memoryManager.enforceBudget()
        }
        .onChange(of: loadedTabBudget) { _, newValue in
            memoryManager.updateLoadedTabBudget(newValue)
        }
    }

    private var lifecycleWorkspace: some View {
        stateObservedWorkspace
        .onChange(of: isComparing) { _, newValue in
            if newValue {
                closeGallery()
                setFocusMode(false)
            }
            if !newValue {
                setFocusMode(false)
                memoryManager.releaseComparisonProtectionAfterTransition()
            }
            persistComparisonPresentationState()
        }
        .onChange(of: comparisonConfiguration) { _, _ in
            persistComparisonPresentationState()
        }
        .onChange(of: comparisonConfiguration.selectedDocumentIDs) { _, ids in
            guard isComparing else { return }
            if ids.isEmpty {
                exitComparison()
            } else {
                memoryManager.setProtectedTabIDs(Set(ids), deferCleanup: true)
            }
        }
        .onChange(of: draggedTabID) { _, newValue in
            if newValue == nil {
                isTabTearOutTargeted = false
            }
        }
        .onExitCommand {
            if isGalleryPresented {
                closeGallery()
            } else if isFocusMode {
                setFocusMode(false)
            } else {
                clearTabDragState()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didResignActiveNotification
            )
        ) { _ in
            clearTabDragState()
        }
        .onDisappear {
            cancelComparisonOpen()
            clearTabDragState()
            if windowID == nil {
                AppExternalFileOpenCoordinator.shared.mainWindowDidDisappear()
            }
            workspace.cancelPendingBatchOpen()
        }
        .onOpenURL { url in
            AppExternalFileOpenCoordinator.shared.enqueue([url])
        }
        .onAppear {
            if windowID == nil {
                AppExternalFileOpenCoordinator.shared.configure(
                    workspace: workspace,
                    presentMainWindow: {
                        openWindow(id: "main", value: MainWorkspaceWindowID.main)
                    }
                )
            }
            memoryManager.workspaceContentsDidChange()
            normalizeComparisonForAvailableDocuments(
                comparisonDocuments.map(\.id)
            )
            if isComparing {
                memoryManager.setProtectedTabIDs(
                    Set(comparisonConfiguration.selectedDocumentIDs)
                )
            }
            if windowID == nil {
                sessionCoordinator?.openRestoredWindows { requestID in
                    openWindow(value: requestID)
                }
            }
            openLaunchArgumentPDFsOnce()
        }
    }

    private var tabBar: some View {
        PDFTabBar(
            workspace: workspace,
            canCompare: comparisonDocuments.count >= PDFComparisonConfiguration.minimumDocumentCount,
            isComparing: isComparing,
            comparisonAction: {
                if isComparing {
                    exitComparison()
                } else {
                    prepareComparison()
                }
            },
            draggedTabID: $draggedTabID,
            galleryAction: toggleGallery,
            isGalleryPresented: isGalleryPresented
        )
    }

    private var workspaceLayer: some View {
        ZStack {
            // Only the visible workspace owns an NSView/PDFView. Previously
            // every hidden tab stayed in this ZStack at zero opacity, keeping
            // PDFKit render caches, observers and page views alive.
            if !isComparing, let session = workspace.activeSession {
                WorkspaceView(
                    multiDocumentWorkspace: workspace,
                    openDocument: openPDFsInTabs,
                    recentDocuments: workspace.recentDocuments,
                    openRecentDocument: { document in
                        workspace.openRecentDocument(id: document.id)
                    },
                    removeRecentDocument: { document in
                        workspace.removeRecentDocument(id: document.id)
                    },
                    clearRecentDocuments: workspace.clearRecentDocuments,
                    isActive: true,
                    isFocusMode: isFocusMode,
                    setFocusMode: setFocusMode,
                    canCompareDocuments: comparisonDocuments.count >= PDFComparisonConfiguration.minimumDocumentCount,
                    compareDocuments: prepareComparison
                )
                    .environmentObject(session.workspace)
                    .id(session.id)
                    .zIndex(1)
            }

            if isComparing {
                PDFComparisonView(
                    documents: comparisonDocuments,
                    configuration: $comparisonConfiguration,
                    onConfigure: { showingComparisonSetup = true },
                    onExit: exitComparison,
                    onSelectDocument: selectComparisonDocument,
                    onOpenDocument: openComparisonDocument,
                    onRemoveDocument: { comparisonConfiguration.removeDocument($0) },
                    isOpeningDocument: isOpeningComparisonDocument,
                    isFocusMode: isFocusMode,
                    setFocusMode: setFocusMode
                )
                .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Own the Finder destination at the same outer workspace boundary as
        // tab tear-out. A nested destination on WorkspaceView is bypassed by
        // PDFKit/ScrollView hosting regions, which made only the tab bar accept
        // files. One non-overlapping file receiver here covers the PDF canvas,
        // page/search sidebars, AI sidebar, and empty workspace.
        .onDrop(
            of: [UTType.fileURL],
            isTargeted: $isWorkspaceFileDropTargeted,
            perform: acceptWorkspaceFileDrop
        )
        .modifier(
            WorkspaceTabTearOutDropTargetModifier(
                isEnabled: !isGalleryPresented && draggedTabID != nil,
                draggedTabID: $draggedTabID,
                isTargeted: $isTabTearOutTargeted,
                workspace: workspace,
                openWindow: { requestID in
                    openWindow(value: requestID)
                }
            )
        )
        .overlay {
            ZStack {
                if
                    isWorkspaceFileDropTargeted,
                    !isComparing,
                    let targetWorkspace = workspace.activeWorkspace
                {
                    WorkspaceFileDropOverlay(
                        hasOpenDocument: targetWorkspace.hasOpenDocument
                    )
                    .padding(28)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .allowsHitTesting(false)
                }

                if isTabTearOutTargeted && draggedTabID != nil {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(theme.steel.opacity(0.12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(
                                    theme.ribbon,
                                    style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                                )
                        }
                        .overlay {
                            Label(
                                L10n.string("새 HwattakPDF 창으로 분리", defaultValue: "새 EmberPDF 창으로 분리"),
                                systemImage: "macwindow.badge.plus"
                            )
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(theme.chromeText)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(theme.chromeRaised, in: Capsule())
                        }
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if isFocusMode, !isComparing {
                Button {
                    setFocusMode(false)
                } label: {
                    Label(
                        L10n.string(
                            "view.focus.exit",
                            defaultValue: "집중 보기 종료"
                        ),
                        systemImage: "arrow.down.right.and.arrow.up.left"
                    )
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.chromeText)
                .background(theme.chromeRaised.opacity(0.88), in: Capsule())
                .overlay {
                    Capsule().stroke(theme.border.opacity(0.8), lineWidth: 1)
                }
                .padding(12)
                .help(
                    L10n.string(
                        "view.focus.exit_help",
                        defaultValue: "Esc로도 집중 보기를 종료할 수 있습니다."
                    )
                )
                .accessibilityIdentifier("focus-mode-exit")
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.14), value: isWorkspaceFileDropTargeted)
        .animation(isComparing ? nil : .easeInOut(duration: 0.16), value: isFocusMode)
    }

    private func acceptWorkspaceFileDrop(providers: [NSItemProvider]) -> Bool {
        guard !isComparing, !isGalleryPresented, let targetWorkspace = workspace.activeWorkspace else {
            return false
        }

        // Capture the workspace under the pointer before asynchronous provider
        // loading. Opening the first PDF activates a different tab, but images
        // and any diagnostics from this one drop still belong to the original
        // document surface.
        return WorkspaceExternalFileDropReceiver.receive(from: providers) { droppedFiles in
            guard !isGalleryPresented else { return }
            WorkspaceFileDropCoordinator.handle(
                droppedFiles,
                workspace: targetWorkspace,
                multiDocumentWorkspace: workspace
            )
        }
    }

    private func openPDFsInTabs() {
        let urls = WorkspaceFilePanels.chooseViewableFiles()
        workspace.beginOpeningViewableFilesInTabs(urls: urls)
    }

    private func reconnectRecentDocument(_ request: RecentDocumentRecoveryRequest) {
        guard let url = WorkspaceFilePanels.chooseRecentPDF(
            named: request.displayName,
            suggestedURL: request.suggestedURL
        ) else { return }
        workspace.reopenRecentDocument(id: request.recentID, from: url)
    }

    private func openLaunchArgumentPDFsOnce() {
        guard handlesLaunchArguments else { return }
        guard !launchArgumentsHandled else { return }
        launchArgumentsHandled = true

        let urls = ProcessInfo.processInfo.arguments.dropFirst().compactMap { path -> URL? in
            let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
            guard fileExtension == "pdf"
                || ImagePDFConverter.supportedExtensions.contains(fileExtension)
            else { return nil }
            return URL(fileURLWithPath: path)
        }
        workspace.beginOpeningViewableFilesInTabs(urls: urls)
    }

    private func clearTabDragState() {
        draggedTabID = nil
        isTabTearOutTargeted = false
    }

    private var canToggleFocusMode: Bool {
        !isGalleryPresented && (isFocusMode || (isComparing
            ? comparisonConfiguration.canContinueComparison
            : workspace.activeWorkspace?.document != nil))
    }

    private func setFocusMode(_ enabled: Bool) {
        guard !enabled || canToggleFocusMode else { return }
        if isComparing {
            // Resize the resident PDFViews once, rather than relaying every
            // animation frame through PDFKit's document layout and fitting.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { isFocusMode = enabled }
        } else {
            withAnimation(.easeInOut(duration: 0.16)) { isFocusMode = enabled }
        }
    }

    private func exitComparison() {
        cancelComparisonOpen()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isFocusMode = false
            isComparing = false
        }
    }

    private func selectComparisonDocument(_ id: UUID, replacing replacedID: UUID?) {
        guard isComparing, !comparisonConfiguration.isSelected(id),
              let candidate = comparisonDocuments.first(where: { $0.id == id }) else { return }
        if let replacedID {
            guard comparisonConfiguration.isSelected(replacedID) else { return }
        } else {
            guard comparisonConfiguration.selectedDocumentIDs.count < PDFComparisonConfiguration.maximumDocumentCount else { return }
        }
        let originWorkspaceID = workspace.activeWorkspaceID
        guard candidate.prepareForDisplay() else {
            // Password cancellation is not an error.
            showingComparisonOpenError = candidate.workspace.presentedError != nil
            return
        }
        // A password dialog can dispatch a nested AppKit event loop. Recheck
        // ownership before replacing a pane in a potentially different view.
        guard isComparing, workspace.activeWorkspaceID == originWorkspaceID else { return }
        var updated = comparisonConfiguration
        let changed = replacedID.map { updated.replaceDocument($0, with: id) }
            ?? updated.addDocument(id)
        guard changed else { return }
        memoryManager.setProtectedTabIDs(Set(updated.selectedDocumentIDs), deferCleanup: true)
        comparisonConfiguration = updated
    }

    private func openComparisonDocument(replacing replacedID: UUID?) {
        guard isComparing, !isOpeningComparisonDocument else { return }
        if let replacedID {
            guard comparisonConfiguration.isSelected(replacedID) else { return }
        } else {
            guard comparisonConfiguration.selectedDocumentIDs.count < PDFComparisonConfiguration.maximumDocumentCount else { return }
        }
        guard let url = WorkspaceFilePanels.choosePDFs(allowsMultipleSelection: false, purpose: .openInTabs).first else { return }
        let originWorkspaceID = workspace.activeWorkspaceID
        let originalTabIDs = Set(workspace.allTabs.map(\.id))
        let access = SecurityScopedAccess(url: url)
        isOpeningComparisonDocument = true
        comparisonOpenTask = Task { @MainActor in
            defer { withExtendedLifetime(access) {} }
            let id = await workspace.openPDFForComparison(url: url)
            guard !Task.isCancelled else { return }
            isOpeningComparisonDocument = false
            comparisonOpenTask = nil
            guard isComparing, workspace.activeWorkspaceID == originWorkspaceID else { return }
            guard let id else {
                showingComparisonOpenError = true
                return
            }
            // Selecting a file already shown should be a harmless no-op.
            selectComparisonDocument(id, replacing: replacedID)
            // A newly opened encrypted/corrupt candidate that never became
            // visible must not leave an unusable tab after a cancelled prompt.
            if !originalTabIDs.contains(id), !comparisonConfiguration.isSelected(id),
               let tab = workspace.allTabs.first(where: { $0.id == id }),
               tab.workspace.document == nil, !tab.workspace.isDirty {
                _ = workspace.closeTab(id)
            }
        }
    }

    private func cancelComparisonOpen() {
        comparisonOpenTask?.cancel()
        comparisonOpenTask = nil
        isOpeningComparisonDocument = false
    }

    private func restoreComparisonPresentationState(for workspaceID: UUID) {
        isFocusMode = false
        comparisonWorkspaceID = workspaceID
        let restored = sessionCoordinator?.comparisonPresentationState(
            windowID: windowID,
            workspaceID: workspaceID
        )
        comparisonConfiguration = restored?.configuration
            ?? PDFComparisonConfiguration()
        isComparing = restored?.isComparing ?? false
        normalizeComparisonForAvailableDocuments(
            comparisonDocuments.map(\.id)
        )
        if isComparing {
            memoryManager.setProtectedTabIDs(Set(comparisonConfiguration.selectedDocumentIDs))
        } else {
            memoryManager.releaseComparisonProtectionAfterTransition()
        }
    }

    private func persistComparisonPresentationState() {
        sessionCoordinator?.updateComparisonPresentationState(
            windowID: windowID,
            workspaceID: comparisonWorkspaceID,
            state: WorkspaceComparisonPresentationState(
                isComparing: isComparing,
                configuration: comparisonConfiguration
            )
        )
    }

    private func normalizeComparisonForAvailableDocuments(_ availableIDs: [UUID]) {
        comparisonConfiguration.normalize(
            availableDocumentIDs: Set(availableIDs)
        )
        if isComparing && !comparisonConfiguration.canContinueComparison {
            exitComparison()
        }
    }

    private func prepareComparison() {
        guard !isGalleryPresented else { return }
        let available = comparisonDocuments.map(\.id)
        guard available.count >= PDFComparisonConfiguration.minimumDocumentCount else { return }
        comparisonConfiguration.normalize(availableDocumentIDs: Set(available))
        if comparisonConfiguration.selectedDocumentIDs.count < PDFComparisonConfiguration.minimumDocumentCount {
            comparisonConfiguration.selectedDocumentIDs = Array(
                available.prefix(PDFComparisonConfiguration.maximumDocumentCount)
            )
        }
        showingComparisonSetup = true
    }

    private var canOpenGallery: Bool {
        !isComparing && !showingComparisonSetup
            && workspace.allTabs.contains { $0.workspace.hasOpenDocument }
    }

    private func toggleGallery() {
        if isGalleryPresented {
            closeGallery()
            return
        }
        guard canOpenGallery,
              NSApp.keyWindow?.attachedSheet == nil,
              NSApp.keyWindow?.sheetParent == nil else { return }
        workspace.activeWorkspace?.prepareForDeactivation()
        NSApp.keyWindow?.makeFirstResponder(nil)
        clearTabDragState()
        isWorkspaceFileDropTargeted = false
        isGalleryPresented = true
    }

    private func closeGallery() {
        guard isGalleryPresented else { return }
        isGalleryPresented = false
        PDFDocumentGalleryPreviewService.shared.removeAllCachedPreviews()
    }

    private func selectGalleryDocument(
        _ workspaceID: UUID,
        _ tabID: UUID,
        _ searchResult: PDFSearchResult?
    ) {
        guard workspace.sessions(inWorkspace: workspaceID).contains(where: {
            $0.id == tabID && $0.workspace.hasOpenDocument
        }) else { return }
        closeGallery()
        workspace.selectGalleryDocument(
            workspaceID: workspaceID,
            tabID: tabID,
            searchResult: searchResult
        )
    }
}

private struct WorkspaceTabTearOutDropTargetModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var draggedTabID: UUID?
    @Binding var isTargeted: Bool
    let workspace: MultiDocumentWorkspaceState
    let openWindow: (UUID) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrop(
                of: [UTType.utf8PlainText.identifier],
                delegate: WorkspaceTabTearOutDropDelegate(
                    draggedTabID: $draggedTabID,
                    isTargeted: $isTargeted,
                    workspace: workspace,
                    openWindow: openWindow
                )
            )
        } else {
            content
        }
    }
}

private struct WorkspaceTabTearOutDropDelegate: DropDelegate {
    @Binding var draggedTabID: UUID?
    @Binding var isTargeted: Bool
    let workspace: MultiDocumentWorkspaceState
    let openWindow: (UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        validatedLocalTabID(info) != nil
    }

    func dropEntered(info: DropInfo) {
        isTargeted = validatedLocalTabID(info) != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validatedLocalTabID(info) != nil else {
            isTargeted = false
            return DropProposal(operation: .cancel)
        }
        isTargeted = true
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        guard
            let expectedTabID = validatedLocalTabID(info),
            let provider = info.itemProviders(
                for: [UTType.utf8PlainText.identifier]
            ).first
        else {
            isTargeted = false
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            let encodedValue = (object as? NSString).map(String.init) ?? ""
            Task { @MainActor in
                guard
                    PDFTabTearOutDropRules.authoritativeTabID(
                        encodedValue: encodedValue,
                        expectedTabID: expectedTabID,
                        openTabIDs: Set(workspace.tabs.map(\.id))
                    ) != nil,
                    let requestID = PDFTabTearOutStore.shared.stageNewWindow(
                        tabID: expectedTabID,
                        from: workspace
                    )
                else { return }
                openWindow(requestID)
            }
        }
        draggedTabID = nil
        isTargeted = false
        return true
    }

    private func validatedLocalTabID(_ info: DropInfo) -> UUID? {
        // Finder providers can expose more than one representation. External
        // files always belong to the workspace file route, never tab tear-out.
        guard !info.hasItemsConforming(to: [UTType.fileURL.identifier]) else {
            return nil
        }
        return PDFTabTearOutDropRules.localCandidate(
            draggedTabID: draggedTabID,
            openTabIDs: Set(workspace.tabs.map(\.id)),
            hasCompatibleProvider: info.hasItemsConforming(
                to: [UTType.utf8PlainText.identifier]
            )
        )
    }
}
