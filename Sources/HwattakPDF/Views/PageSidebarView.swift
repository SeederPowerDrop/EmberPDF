// SPDX-License-Identifier: MPL-2.0

import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// 문서의 모든 페이지를 썸네일로 보여 주고 선택·재정렬·삭제를 돕는 사이드바다.
///
/// 배치 위치에 따라 세로 `LazyVStack` 또는 가로 `LazyHStack`만 바뀌고, 각 실제
/// 페이지는 언제나 원래 page index를 ID와 drag target으로 유지한다. 2장/4장
/// 묶음의 빈 slot은 보기용일 뿐 선택이나 drop 대상이 아니다.
struct PageSidebarView: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let placement: PageOverviewPlacement
    @Binding var sidebarMode: DocumentSidebarMode
    var onThumbnailScalePreview: (Double?) -> Void = { _ in }
    /// drag 시작 시 문서 revision과 난수 token을 함께 캡처한다. drop 시 이 값과
    /// provider payload를 모두 검증해 취소된 drag나 외부 텍스트가 페이지를
    /// 뜻밖에 이동시키지 못하게 한다.
    @State private var showingDisplayOptions = false
    @State private var pageDragSession: PDFPageDragSession?
    @State private var magnificationBaseline: Double?
    @State private var liveThumbnailScaleValue: Double?
    @State private var isThumbnailScaleSliderEditing = false
    @State private var searchHitCountsByPage: [Int: Int] = [:]
    @FocusState private var isPageStripFocused: Bool
    // 묶음 방식과 썸네일 배율은 PDF 내용이 아니라 사용자 보기 선호이므로
    // 문서 undo/session 대신 UserDefaults를 감싼 @AppStorage에 보관한다.
    @AppStorage(PageSidebarPreferences.layoutModeKey)
    private var layoutModeValue = PageSidebarLayoutMode.single.rawValue
    @AppStorage(PageSidebarPreferences.thumbnailScaleKey)
    private var thumbnailScaleValue = PageSidebarPreferences.defaultThumbnailScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection

    @EmberTheme private var theme
    private var layoutMode: PageSidebarLayoutMode {
        PageSidebarLayoutMode(rawValue: layoutModeValue) ?? .single
    }
    private var thumbnailScale: Double {
        PageSidebarPreferences.clampedThumbnailScale(liveThumbnailScaleValue ?? thumbnailScaleValue)
    }
    /// Selecting and navigating pages is available in every mode. Reordering,
    /// rotating, and deleting change PDF structure and belong to Editing only.
    private var canEditPages: Bool { workspace.allows(.pageEditing) }
    /// 실제 페이지 배열을 바꾸지 않고 표시용 그룹만 계산한다.
    private var pageGroups: [PageSidebarPageGroup] {
        layoutMode.groups(pageCount: workspace.pageCount)
    }
    var body: some View {
        Group {
            if placement.usesHorizontalPageStrip {
                horizontalPagePanel
            } else {
                verticalPagePanel
            }
        }
        .background(theme.sidebar)
        .foregroundStyle(theme.primaryText)
        .onAppear(perform: normalizeSavedPreferences)
        .onDisappear {
            // Cancel a gesture if its tab/panel is removed before mouse-up.
            clearThumbnailScalePreview()
        }
        .onChange(of: showingDisplayOptions) { _, isPresented in
            if !isPresented, isThumbnailScaleSliderEditing {
                commitThumbnailScalePreview()
            }
        }
        .onChange(of: layoutModeValue) { _, _ in
            normalizeSavedPreferences()
        }
        .onChange(of: thumbnailScaleValue) { _, newValue in
            let clamped = PageSidebarPreferences.clampedThumbnailScale(newValue)
            if clamped != newValue {
                thumbnailScaleValue = clamped
            }
        }
        .onReceive(workspace.$searchNavigatorResults) { results in
            // Compute once per published result batch. Looking this up from
            // every thumbnail must stay O(results + pages), even for a large
            // study document with thousands of matches.
            searchHitCountsByPage = Dictionary(grouping: results, by: \.pageIndex)
                .mapValues(\.count)
        }
        .onChange(of: workspace.mode) { _, _ in
            // A drag may have begun a moment before a Control-number shortcut
            // changed mode. Discard its local token so a later drop cannot use
            // the previous mode's authority.
            if !canEditPages {
                pageDragSession = nil
            }
        }
    }

    private var verticalPagePanel: some View {
        VStack(spacing: 0) {
            sidebarHeader
            horizontalDivider
            verticalPageScroller
            if canEditPages {
                horizontalDivider
                sidebarFooter
            }
        }
        .frame(
            minWidth: PageSidebarPreferences.minimumVerticalPanelWidth(
                layoutMode: layoutMode,
                thumbnailScale: thumbnailScale
            ),
            maxWidth: .infinity,
            maxHeight: .infinity
        )
    }

    private var horizontalPagePanel: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                sidebarHeader
                PageJumpControl(workspace: workspace)
                    .padding(.horizontal, 8)
            }
            .padding(.bottom, 8)
            .frame(width: 146)
            verticalDivider
            horizontalPageScroller
            if canEditPages {
                verticalDivider
                sidebarFooter
                    .frame(width: 112)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: PageSidebarPreferences.minimumHorizontalPanelHeight(
                layoutMode: layoutMode,
                thumbnailScale: thumbnailScale
            ),
            maxHeight: .infinity
        )
    }

    private var verticalPageScroller: some View {
        GeometryReader { geometry in
            verticalPageScroller(panelWidth: geometry.size.width)
        }
    }

    private func verticalPageScroller(panelWidth: CGFloat) -> some View {
        let thumbnailWidth = CGFloat(PageSidebarLayoutMetrics.thumbnailWidth(
            panelDimension: panelWidth,
            placement: placement,
            layoutMode: layoutMode,
            thumbnailScale: thumbnailScale
        ))
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 12) {
                    ForEach(pageGroups) { group in
                        verticalPageGroup(group, thumbnailWidth: thumbnailWidth)
                    }

                    if workspace.pageCount > 1, canEditPages {
                        pageEndDropTarget(horizontal: false)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 16)
            }
            .modifier(pageNavigationKeyboardModifier)
            .onChange(of: workspace.currentPageIndex) { _, newValue in
                // Held arrows can outpace an animated scroll. Keep the current
                // thumbnail in view immediately instead of chasing old targets.
                proxy.scrollTo(newValue, anchor: .center)
            }
            .onChange(of: layoutModeValue) { _, _ in
                proxy.scrollTo(workspace.currentPageIndex, anchor: .center)
            }
            .simultaneousGesture(thumbnailMagnificationGesture)
        }
    }

    private var horizontalPageScroller: some View {
        GeometryReader { geometry in
            horizontalPageScroller(panelHeight: geometry.size.height)
        }
    }

    private func horizontalPageScroller(panelHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(pageGroups) { group in
                        horizontalPageGroup(group, panelHeight: panelHeight)
                    }

                    if workspace.pageCount > 1, canEditPages {
                        pageEndDropTarget(horizontal: true, availableHeight: panelHeight)
                    }
                }
                .padding(.horizontal, 16)
                .padding(
                    .top,
                    CGFloat(PageSidebarLayoutMetrics.horizontalScrollerTopPadding)
                )
                .padding(
                    .bottom,
                    CGFloat(PageSidebarLayoutMetrics.horizontalScrollerBottomPadding)
                )
            }
            .modifier(pageNavigationKeyboardModifier)
            .onChange(of: workspace.currentPageIndex) { _, newValue in
                proxy.scrollTo(newValue, anchor: .center)
            }
            .onChange(of: layoutModeValue) { _, _ in
                proxy.scrollTo(workspace.currentPageIndex, anchor: .center)
            }
            .simultaneousGesture(thumbnailMagnificationGesture)
        }
    }

    private var horizontalDivider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(height: 1)
    }

    /// Keep keyboard focus on the strip, rather than a lazy thumbnail that
    /// disappears as navigation scrolls. Header fields and sliders retain
    /// their own arrow-key behavior because they are outside this scope.
    private var pageNavigationKeyboardModifier: some ViewModifier {
        PDFArrowKeyNavigationModifier(
            isFocused: $isPageStripFocused,
            contextID: "\(workspace.revision)-\(workspace.mode)-\(placement)-\(layoutMode)",
            onArrow: { handlePagingKey($0, modifiers: []) }
        )
    }

    func handlePagingKey(_ key: KeyEquivalent, modifiers: EventModifiers) -> KeyPress.Result {
        guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
              workspace.pageCount > 0 else { return .ignored }

        let direction: PageSidebarNavigationDirection
        switch key {
        case .upArrow: direction = .up
        case .downArrow: direction = .down
        case .leftArrow: direction = .left
        case .rightArrow: direction = .right
        default: return .ignored
        }

        // Consume arrows at document ends too, so native scrolling/focus
        // traversal cannot take over halfway through a held arrow key.
        guard let destination = layoutMode.navigationTarget(
            from: workspace.currentPageIndex,
            direction: direction,
            placement: placement,
            pageCount: workspace.pageCount,
            isRightToLeft: layoutDirection == .rightToLeft
        ) else { return .handled }
        workspace.selectedPages = [destination]
        workspace.setCurrentPage(destination)
        return .handled
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(width: 1)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 4) {
            // Keep both modes reachable when a small thumbnail size makes
            // the panel narrower than the localized text segments.
            ViewThatFits(in: .horizontal) {
                DocumentSidebarModePicker(selection: $sidebarMode)
                    .fixedSize(horizontal: true, vertical: false)
                DocumentSidebarModePicker(selection: $sidebarMode, compact: true)
            }
            .frame(maxWidth: .infinity)
            Button { showingDisplayOptions.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("page.sidebar.settings", defaultValue: "페이지 미리보기 설정"))
            .accessibilityLabel(
                L10n.string("page.sidebar.settings", defaultValue: "페이지 미리보기 설정")
            )
            .accessibilityIdentifier("page-sidebar-options")
            .popover(isPresented: $showingDisplayOptions, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string("page.sidebar.settings", defaultValue: "페이지 미리보기 설정"))
                        .font(.headline)
                        .padding(.horizontal, 12)
                    sidebarDisplayControls
                }
                .padding(.vertical, 14)
                .frame(width: 280)
                .foregroundStyle(theme.primaryText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var sidebarDisplayControls: some View {
        VStack(spacing: 8) {
            Picker(
                L10n.string("page.sidebar.layout", defaultValue: "페이지 묶음 보기"),
                selection: layoutModeBinding
            ) {
                ForEach(PageSidebarLayoutMode.allCases) { mode in
                    Image(systemName: mode.symbolName)
                        .help(mode.title)
                        .accessibilityLabel(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(
                L10n.string("page.sidebar.layout", defaultValue: "페이지 묶음 보기")
            )
            .accessibilityValue(layoutMode.title)
            .help(
                L10n.string(
                    "page.sidebar.layout_help",
                    defaultValue: "좌우 2페이지는 1–2, 3–4 순서로 묶어 표시합니다."
                )
            )

            HStack {
                Text(
                    L10n.string("page.sidebar.thumbnail_size", defaultValue: "페이지 미리보기 크기")
                )
                Spacer()
                Text("50%–300%")
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
            }
            .font(.caption2)
            .padding(.top, 4)

            HStack(spacing: 6) {
                Button {
                    adjustThumbnailScale(by: -1)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help(L10n.string("page.sidebar.zoom_out", defaultValue: "페이지 축소"))
                .accessibilityLabel(
                    L10n.string("page.sidebar.zoom_out", defaultValue: "페이지 축소")
                )
                .disabled(
                    thumbnailScale <= PageSidebarPreferences.minimumThumbnailScale + 0.0001
                )

                Slider(
                    value: thumbnailScaleBinding,
                    in: PageSidebarPreferences.minimumThumbnailScale
                        ... PageSidebarPreferences.maximumThumbnailScale,
                    step: 0.05,
                    onEditingChanged: { isEditing in
                        if isEditing {
                            isThumbnailScaleSliderEditing = true
                            previewThumbnailScale(thumbnailScale)
                        } else {
                            commitThumbnailScalePreview()
                        }
                    }
                )
                .controlSize(.small)
                .accessibilityLabel(
                    L10n.string("page.sidebar.thumbnail_size", defaultValue: "페이지 미리보기 크기")
                )
                .accessibilityValue("\(thumbnailScalePercent)%")
                .accessibilityIdentifier("page-sidebar-thumbnail-scale")

                Button {
                    adjustThumbnailScale(by: 1)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help(L10n.string("page.sidebar.zoom_in", defaultValue: "페이지 확대"))
                .accessibilityLabel(
                    L10n.string("page.sidebar.zoom_in", defaultValue: "페이지 확대")
                )
                .disabled(
                    thumbnailScale >= PageSidebarPreferences.maximumThumbnailScale - 0.0001
                )

                Button {
                    setThumbnailScale(PageSidebarPreferences.defaultThumbnailScale)
                } label: {
                    Text("\(thumbnailScalePercent)%")
                        .font(.caption2.monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                }
                .buttonStyle(.borderless)
                .help(
                    L10n.string("page.sidebar.thumbnail_reset", defaultValue: "미리보기 크기를 100%로")
                )
                .accessibilityLabel(
                    L10n.string("page.sidebar.thumbnail_reset", defaultValue: "미리보기 크기를 100%로")
                )
                .accessibilityValue("\(thumbnailScalePercent)%")
                .accessibilityIdentifier("page-sidebar-thumbnail-reset")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var layoutModeBinding: Binding<PageSidebarLayoutMode> {
        Binding(
            get: { layoutMode },
            set: { layoutModeValue = $0.rawValue }
        )
    }

    private var thumbnailScaleBinding: Binding<Double> {
        Binding(
            get: { thumbnailScale },
            set: { value in
                if isThumbnailScaleSliderEditing {
                    previewThumbnailScale(value)
                } else {
                    // Keyboard/accessibility adjustments have no drag lifecycle.
                    setThumbnailScale(value)
                }
            }
        )
    }

    private var thumbnailScalePercent: Int {
        Int((thumbnailScale * 100).rounded())
    }

    @ViewBuilder
    private func verticalPageGroup(
        _ group: PageSidebarPageGroup,
        thumbnailWidth: CGFloat
    ) -> some View {
        switch layoutMode {
        case .single:
            pageSlot(group.slots.first ?? nil, thumbnailWidth: thumbnailWidth)

        case .facingPages:
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(group.slots.enumerated()), id: \.offset) { _, pageIndex in
                    pageSlot(pageIndex, thumbnailWidth: thumbnailWidth)
                }
            }
            .modifier(PageSidebarGroupCard(theme: theme))

        case .fourPages:
            LazyVGrid(
                columns: [
                    GridItem(.fixed(thumbnailWidth + 16), spacing: 6),
                    GridItem(.fixed(thumbnailWidth + 16), spacing: 6)
                ],
                alignment: .center,
                spacing: 6
            ) {
                ForEach(Array(group.slots.enumerated()), id: \.offset) { _, pageIndex in
                    pageSlot(pageIndex, thumbnailWidth: thumbnailWidth)
                }
            }
            .modifier(PageSidebarGroupCard(theme: theme))
        }
    }

    @ViewBuilder
    private func horizontalPageGroup(
        _ group: PageSidebarPageGroup,
        panelHeight: CGFloat
    ) -> some View {
        let thumbnailWidth = CGFloat(PageSidebarLayoutMetrics.thumbnailWidth(
            panelDimension: panelHeight,
            placement: placement,
            layoutMode: layoutMode,
            thumbnailScale: thumbnailScale,
            maximumPageAspect: maximumPageAspect(in: group)
        ))
        if layoutMode == .single {
            pageSlot(group.slots.first ?? nil, thumbnailWidth: thumbnailWidth)
        } else {
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(group.slots.enumerated()), id: \.offset) { _, pageIndex in
                    // Empty trailing slots reserve a column, not a portrait
                    // page's height that could overflow a landscape group.
                    pageSlot(pageIndex, thumbnailWidth: thumbnailWidth, placeholderHeight: 1)
                }
            }
            .modifier(PageSidebarGroupCard(theme: theme))
        }
    }

    private func maximumPageAspect(in group: PageSidebarPageGroup) -> Double {
        // Inspect only this lazy group's pages. Scanning the entire document
        // on every divider movement defeats PDFKit's lazy page loading.
        group.pageIndices.compactMap { index -> Double? in
            guard let page = workspace.document?.page(at: index) else { return nil }
            let size = page.bounds(for: .cropBox).size
            guard size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return nil }
            let aspect = abs(page.rotation % 180) == 90
                ? size.width / size.height : size.height / size.width
            return aspect.isFinite && aspect > 0 ? Double(aspect) : nil
        }.max() ?? 1.414
    }

    @ViewBuilder
    private func pageSlot(
        _ pageIndex: Int?,
        thumbnailWidth: CGFloat,
        placeholderHeight: CGFloat? = nil
    ) -> some View {
        if
            let pageIndex,
            let page = workspace.document?.page(at: pageIndex)
        {
            pageRow(page: page, index: pageIndex, thumbnailWidth: thumbnailWidth)
                .frame(width: thumbnailWidth + 16)
                .id(pageIndex)
        } else {
            Color.clear
                .frame(
                    width: thumbnailWidth + 16,
                    height: placeholderHeight ?? thumbnailWidth * 1.35 + 25
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func pageRow(page: PDFPage, index: Int, thumbnailWidth: CGFloat) -> some View {
        let selected = workspace.selectedPages.contains(index)
        let searchHitCount = searchHitCountsByPage[index] ?? 0
        let pageButton = Button {
            isPageStripFocused = true
            updateSelection(index)
        } label: {
            PageThumbnailView(
                page: page,
                pageIndex: index,
                width: thumbnailWidth,
                revision: workspace.revision,
                fileSource: workspace.thumbnailFileSource
            )
            .frame(width: thumbnailWidth)
            .padding(8)
            .modifier(PageThumbnailSelectionSurface(isSelected: selected, theme: theme))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.accent)
                        .background(theme.card, in: Circle())
                        .padding(7)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if searchHitCount > 0 {
                    Label("\(searchHitCount)", systemImage: "magnifyingglass")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(theme.card.opacity(0.96), in: Capsule())
                        .overlay {
                            Capsule().stroke(theme.selectionBorder, lineWidth: 1)
                        }
                        .padding(7)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format("page.number", index + 1))
        .accessibilityValue(
            pageAccessibilityValue(selected: selected, searchHitCount: searchHitCount)
        )
        .accessibilityAddTraits(selected ? .isSelected : [])

        let contextualPageButton = pageButton.contextMenu {
            Menu(L10n.string("menu.export_selected_pages")) {
                Button(L10n.string("menu.export_selected_pages.combined")) {
                    exportSelectedPagesCombined(clickedIndex: index)
                }
                Button(L10n.string("menu.export_selected_pages.individual")) {
                    exportSelectedPagesIndividually(clickedIndex: index)
                }
            }
            .disabled(!workspace.canExtractPages)

            if canEditPages {
                Divider()
                Button(L10n.string("왼쪽으로 회전")) {
                    prepareContextSelection(for: index)
                    workspace.rotateSelectedPages(clockwise: false)
                }
                Button(L10n.string("오른쪽으로 회전")) {
                    prepareContextSelection(for: index)
                    workspace.rotateSelectedPages(clockwise: true)
                }
                Divider()
                Button(L10n.string("선택 페이지 삭제"), role: .destructive) {
                    prepareContextSelection(for: index)
                    workspace.deleteSelectedPages()
                }
            }
        }

        if canEditPages {
            contextualPageButton
                .accessibilityHint(
                    L10n.string("page.sidebar.edit_accessibility_hint")
                )
                .onDrag {
                    let session = PDFPageDragSession(
                        sourceIndex: index,
                        documentRevision: workspace.revision
                    )
                    pageDragSession = session
                    return PDFPageDragPayload.itemProvider(for: session)
                }
                .modifier(
                    PageReorderDropTargetModifier(
                        isEnabled: pageDragSession != nil,
                        target: index,
                        pageDragSession: $pageDragSession,
                        workspace: workspace
                    )
                )
        } else {
            // Read-only page export remains available in Viewer and Study;
            // mutation-only drag, rotate, and delete affordances stay absent.
            contextualPageButton
                .accessibilityHint(
                    L10n.string("page.sidebar.view_accessibility_hint")
                )
        }
    }

    private func pageAccessibilityValue(selected: Bool, searchHitCount: Int) -> String {
        let selection = selected
            ? L10n.string("selection.selected")
            : L10n.string("selection.not_selected")
        guard searchHitCount > 0 else { return selection }
        return "\(selection), \(L10n.format("search.navigator.page_hit_count", searchHitCount))"
    }

    private func prepareContextSelection(for index: Int) {
        if !workspace.selectedPages.contains(index) {
            workspace.selectedPages = [index]
        }
        workspace.setCurrentPage(index)
    }

    private func exportSelectedPagesCombined(clickedIndex: Int) {
        guard workspace.canExtractPages else { return }
        prepareContextSelection(for: clickedIndex)
        guard !workspace.selectedPages.isEmpty else { return }
        if let url = WorkspaceFilePanels.chooseSavePDF(
            suggestedName: SelectedPagePDFExporter.combinedFileName(
                for: workspace.documentURL
            ),
            title: L10n.string("panel.title.save_selected_pages_combined")
        ) {
            Task { await workspace.exportSelectedPagesAsCombinedPDFAsynchronously(to: url) }
        }
    }

    private func exportSelectedPagesIndividually(clickedIndex: Int) {
        guard workspace.canExtractPages else { return }
        prepareContextSelection(for: clickedIndex)
        guard !workspace.selectedPages.isEmpty else { return }
        if let directory = WorkspaceFilePanels.chooseDirectory(
            title: L10n.string("panel.title.choose_individual_pages_folder"),
            message: L10n.format(
                "panel.message.export_individual_pages",
                workspace.selectedPages.count
            )
        ) {
            Task { await workspace.exportSelectedPagesAsIndividualPDFsAsynchronously(to: directory) }
        }
    }

    private func pageEndDropTarget(
        horizontal: Bool,
        availableHeight: CGFloat? = nil
    ) -> some View {
        let scrollerPadding = CGFloat(
            PageSidebarLayoutMetrics.horizontalScrollerTopPadding
                + PageSidebarLayoutMetrics.horizontalScrollerBottomPadding
        )
        let dropHeight = horizontal
            ? min(150, max(36, (availableHeight ?? 150 + scrollerPadding) - scrollerPadding))
            : 36
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(pageDragSession == nil ? Color.clear : theme.dropHighlight)
            .frame(width: horizontal ? 74 : nil, height: dropHeight)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        pageDragSession == nil ? Color.clear : theme.accent.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            }
            .overlay {
                if pageDragSession != nil {
                    Label(
                        "문서 끝으로 이동",
                        systemImage: horizontal ? "arrow.right.to.line" : "arrow.down.to.line"
                    )
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .labelStyle(.iconOnly)
                }
            }
            .modifier(
                PageEndDropTargetModifier(
                    isEnabled: pageDragSession != nil,
                    pageDragSession: $pageDragSession,
                    workspace: workspace
                )
            )
            .accessibilityLabel("문서 끝으로 이동")
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            Button {
                workspace.moveSelectedPage(by: -1)
            } label: {
                Image(systemName: placement.usesHorizontalPageStrip ? "arrow.left" : "arrow.up")
            }
            .help("선택 페이지를 앞으로 이동")
            .disabled(
                !canEditPages
                    || workspace.selectedPages.count != 1
                    || workspace.selectedPages.contains(0)
            )

            Button {
                workspace.moveSelectedPage(by: 1)
            } label: {
                Image(systemName: placement.usesHorizontalPageStrip ? "arrow.right" : "arrow.down")
            }
            .help("선택 페이지를 뒤로 이동")
            .disabled(
                !canEditPages
                    || workspace.selectedPages.count != 1
                    || workspace.selectedPages.contains(max(0, workspace.pageCount - 1))
            )

            Spacer()

            Button(role: .destructive) {
                workspace.deleteSelectedPages()
            } label: {
                Image(systemName: "trash")
            }
            .help("선택 페이지 삭제")
            .disabled(!canEditPages || workspace.selectedPages.isEmpty || workspace.pageCount <= 1)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 11)
    }

    private var thumbnailMagnificationGesture: some Gesture {
        MagnificationGesture(minimumScaleDelta: 0.01)
            .onChanged { magnification in
                if magnificationBaseline == nil {
                    magnificationBaseline = thumbnailScale
                }
                let baseline = magnificationBaseline ?? thumbnailScale
                previewThumbnailScale(baseline * Double(magnification))
            }
            .onEnded { magnification in
                if let baseline = magnificationBaseline {
                    previewThumbnailScale(baseline * Double(magnification))
                }
                commitThumbnailScalePreview()
            }
    }

    private func adjustThumbnailScale(by steps: Int) {
        setThumbnailScale(PageSidebarPreferences.adjustedThumbnailScale(
            thumbnailScale,
            steps: steps
        ))
    }

    /// Keep a gesture local to the visible panel. Writing AppStorage for every
    /// slider/pinch pulse used to invalidate all tabs and windows, even though
    /// only this panel is being resized. The parent still receives a live value
    /// so panel bounds follow the pointer; one value is persisted on release.
    private func previewThumbnailScale(_ value: Double) {
        let clamped = PageSidebarPreferences.clampedThumbnailScale(value)
        guard liveThumbnailScaleValue != clamped else { return }
        liveThumbnailScaleValue = clamped
        onThumbnailScalePreview(clamped)
    }

    private func setThumbnailScale(_ value: Double) {
        let clamped = PageSidebarPreferences.clampedThumbnailScale(value)
        if thumbnailScaleValue != clamped { thumbnailScaleValue = clamped }
        clearThumbnailScalePreview()
    }

    private func commitThumbnailScalePreview() {
        if let value = liveThumbnailScaleValue { setThumbnailScale(value) }
        else { clearThumbnailScalePreview() }
    }

    private func clearThumbnailScalePreview() {
        liveThumbnailScaleValue = nil
        magnificationBaseline = nil
        isThumbnailScaleSliderEditing = false
        onThumbnailScalePreview(nil)
    }

    private func normalizeSavedPreferences() {
        if PageSidebarLayoutMode(rawValue: layoutModeValue) == nil {
            layoutModeValue = PageSidebarLayoutMode.single.rawValue
        }

        let clampedScale = PageSidebarPreferences.clampedThumbnailScale(thumbnailScaleValue)
        if clampedScale != thumbnailScaleValue {
            thumbnailScaleValue = clampedScale
        }
    }

    private func updateSelection(_ index: Int) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            if workspace.selectedPages.contains(index) {
                workspace.selectedPages.remove(index)
            } else {
                workspace.selectedPages.insert(index)
            }
        } else if flags.contains(.shift), let anchor = workspace.selectedPages.min() {
            workspace.selectedPages = Set(min(anchor, index)...max(anchor, index))
        } else {
            workspace.selectedPages = [index]
        }
        workspace.setCurrentPage(index)
    }
}

/// Selection stays quiet around the page; hover only changes the surrounding
/// surface, so the document preview itself keeps its original colors.
private struct PageThumbnailSelectionSurface: ViewModifier {
    let isSelected: Bool
    let theme: HwattakPDFTheme
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                isSelected ? theme.selectionFill : (isHovering ? theme.hoverFill : Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? theme.selectionBorder : Color.clear, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }
}

private struct PageSidebarGroupCard: ViewModifier {
    let theme: HwattakPDFTheme

    func body(content: Content) -> some View {
        content
            .padding(5)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.border.opacity(0.45), lineWidth: 0.75)
            }
            .accessibilityElement(children: .contain)
    }
}

/// SwiftUI installs every onDrop as a broad AppKit data/item destination even
/// when the declared type is plain text. Keep those nested destinations out of
/// the hierarchy until an app-owned page drag actually starts so Finder files
/// fall through to the one workspace-level fileURL receiver.
private struct PageReorderDropTargetModifier: ViewModifier {
    let isEnabled: Bool
    let target: Int
    @Binding var pageDragSession: PDFPageDragSession?
    let workspace: PDFWorkspaceState

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrop(
                of: [PDFPageDragPayload.typeIdentifier],
                delegate: PageReorderDropDelegate(
                    target: target,
                    pageDragSession: $pageDragSession,
                    workspace: workspace
                )
            )
        } else {
            content
        }
    }
}

private struct PageEndDropTargetModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var pageDragSession: PDFPageDragSession?
    let workspace: PDFWorkspaceState

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrop(
                of: [PDFPageDragPayload.typeIdentifier],
                delegate: PageEndDropDelegate(
                    pageDragSession: $pageDragSession,
                    workspace: workspace
                )
            )
        } else {
            content
        }
    }
}

private struct PageEndDropDelegate: DropDelegate {
    @Binding var pageDragSession: PDFPageDragSession?
    let workspace: PDFWorkspaceState

    func validateDrop(info: DropInfo) -> Bool {
        guard !info.hasItemsConforming(to: [UTType.fileURL.identifier]) else {
            return false
        }
        guard info.hasItemsConforming(to: [PDFPageDragPayload.typeIdentifier]),
              workspace.allows(.pageEditing),
              let session = pageDragSession,
              session.documentRevision == workspace.revision,
              (0..<workspace.pageCount).contains(session.sourceIndex)
        else { return false }
        return true
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        let localSession = pageDragSession
        let scheduled = PDFPageDragPayload.loadEncodedValue(
            from: info.itemProviders(for: [PDFPageDragPayload.typeIdentifier])
        ) { encodedValue in
            defer { clearSession(ifMatching: localSession) }
            guard
                workspace.allows(.pageEditing),
                workspace.document != nil,
                let source = PDFPageDragPayload.validatedSourceIndex(
                    encodedValue: encodedValue,
                    localSession: localSession,
                    currentDocumentRevision: workspace.revision,
                    currentPageCount: workspace.pageCount
                )
            else { return }
            workspace.movePageToEnd(from: source)
        }
        guard scheduled else {
            clearSession(ifMatching: localSession)
            return false
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .move)
    }

    private func clearSession(ifMatching session: PDFPageDragSession?) {
        guard pageDragSession?.token == session?.token else { return }
        pageDragSession = nil
    }
}

private struct PageReorderDropDelegate: DropDelegate {
    let target: Int
    @Binding var pageDragSession: PDFPageDragSession?
    let workspace: PDFWorkspaceState

    func validateDrop(info: DropInfo) -> Bool {
        guard !info.hasItemsConforming(to: [UTType.fileURL.identifier]) else {
            return false
        }
        guard info.hasItemsConforming(to: [PDFPageDragPayload.typeIdentifier]),
              workspace.allows(.pageEditing),
              let session = pageDragSession,
              session.documentRevision == workspace.revision,
              (0..<workspace.pageCount).contains(session.sourceIndex),
              (0..<workspace.pageCount).contains(target)
        else { return false }
        return true
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        let localSession = pageDragSession
        let scheduled = PDFPageDragPayload.loadEncodedValue(
            from: info.itemProviders(for: [PDFPageDragPayload.typeIdentifier])
        ) { encodedValue in
            defer { clearSession(ifMatching: localSession) }
            guard
                workspace.allows(.pageEditing),
                workspace.document != nil,
                let source = PDFPageDragPayload.validatedSourceIndex(
                    encodedValue: encodedValue,
                    localSession: localSession,
                    currentDocumentRevision: workspace.revision,
                    currentPageCount: workspace.pageCount,
                    targetIndex: target
                )
            else { return }
            workspace.movePage(from: source, before: target)
        }
        guard scheduled else {
            clearSession(ifMatching: localSession)
            return false
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .move)
    }

    private func clearSession(ifMatching session: PDFPageDragSession?) {
        guard pageDragSession?.token == session?.token else { return }
        pageDragSession = nil
    }
}
