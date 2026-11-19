// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// 비교 모드에 들어가기 전 문서·순서·분할 방향·동기화 옵션을 고르는 sheet다.
///
/// `draft`는 사용자가 확인하기 전의 임시 복사본이다. 취소하면 binding에 아무것도
/// 쓰지 않고, 시작 버튼을 눌렀을 때만 부모 configuration에 commit한다. 이 패턴은
/// 설정 창에서 '취소'가 정말 무변경이어야 할 때 재사용할 수 있다.
@MainActor
struct ComparisonSetupSheet: View {
    let documents: [ComparisonDocument]
    @Binding private var configuration: PDFComparisonConfiguration
    let onCancel: () -> Void
    let onStart: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// 편집 중인 값과 실제 적용 값을 분리하는 transactional draft.
    @State private var draft: PDFComparisonConfiguration
    @State private var presentation = ComparisonChooserPresentation.gallery
    @State private var previewPage = ComparisonChooserPreviewPage.current
    @State private var filter = ComparisonChooserFilter()

    init(
        documents: [ComparisonDocument],
        configuration: Binding<PDFComparisonConfiguration>,
        onCancel: @escaping () -> Void,
        onStart: @escaping () -> Void
    ) {
        self.documents = documents
        _configuration = configuration
        self.onCancel = onCancel
        self.onStart = onStart
        _draft = State(initialValue: configuration.wrappedValue)
    }

    @EmberTheme private var theme

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    documentSelection
                    layoutSelection
                    scrollSelection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            footer
        }
        .frame(minWidth: 660, idealWidth: 860, maxWidth: 1_040, minHeight: 620, idealHeight: 790)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .onAppear(perform: prepareDraft)
        .onChange(of: documents.map(\.id)) { _, ids in
            draft.normalize(availableDocumentIDs: Set(ids))
            if let scope = filter.workspaceID, !documents.contains(where: { $0.workspaceID == scope }) {
                filter.workspaceID = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            TogetherViewIcon(size: 28)
                .frame(width: 44, height: 44)
                .background(theme.dropHighlight, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("PDF 비교 설정"))
                    .font(.title3.weight(.semibold))
                Text("함께 볼 문서 2~4개와 배치 방식을 선택하세요.")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(theme.sidebar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: 1)
        }
    }

    private var documentSelection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle(
                "비교할 PDF",
                detail: L10n.format(
                    "comparison.selection_count",
                    draft.selectedDocumentIDs.count,
                    PDFComparisonConfiguration.maximumDocumentCount
                )
            )

            if documents.isEmpty {
                ContentUnavailableView(
                    L10n.string("비교할 PDF가 없습니다"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("먼저 두 개 이상의 PDF를 탭으로 열어 주세요.")
                )
                .frame(maxWidth: .infinity, minHeight: 170)
                .hwattakPDFCard(theme, cornerRadius: 12)
            } else {
                browserControls
                selectedDocuments
                documentBrowser
            }

            if !documents.isEmpty && documents.count < PDFComparisonConfiguration.minimumDocumentCount {
                Label(L10n.string("비교하려면 PDF 탭을 하나 더 열어 주세요."), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(theme.warning)
            }
        }
    }

    private var visibleDocuments: [ComparisonDocument] { filter.documents(in: documents) }

    private var workspaceChoices: [(id: UUID, title: String)] {
        var seen = Set<UUID>()
        return documents.compactMap { document in
            guard let id = document.workspaceID, seen.insert(id).inserted else { return nil }
            return (id, document.workspaceTitle ?? L10n.string("comparison.chooser.workspace"))
        }
    }

    private var browserControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Picker(L10n.string("comparison.chooser.presentation"), selection: $presentation) {
                    ForEach(ComparisonChooserPresentation.allCases, id: \.self) { mode in
                        Label(L10n.string(mode.titleKey), systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented).frame(width: 190)
                .accessibilityIdentifier("comparison-chooser-presentation")
                Spacer(minLength: 8)
                Picker(L10n.string("comparison.chooser.preview"), selection: $previewPage) {
                    ForEach(ComparisonChooserPreviewPage.allCases, id: \.self) { page in
                        Text(L10n.string(page.titleKey)).tag(page)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 150)
                .accessibilityIdentifier("comparison-chooser-preview")
            }
            HStack(spacing: 10) {
                if !workspaceChoices.isEmpty {
                    Picker(L10n.string("gallery.workspace_scope"), selection: $filter.workspaceID) {
                        Text(L10n.string("gallery.all_workspaces")).tag(Optional<UUID>.none)
                        ForEach(workspaceChoices, id: \.id) { item in
                            Text(item.title).tag(Optional(item.id))
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 210)
                    .accessibilityIdentifier("comparison-chooser-workspace")
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryText)
                    TextField(L10n.string("comparison.chooser.search"), text: $filter.query)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("comparison-chooser-search")
                    if !filter.query.isEmpty {
                        Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(theme.secondaryText)
                            .accessibilityLabel(L10n.string("gallery.search.clear"))
                    }
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(theme.card, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(theme.border, lineWidth: 1) }
                Text(L10n.format("gallery.count", visibleDocuments.count))
                    .font(.caption).foregroundStyle(theme.secondaryText).fixedSize()
            }
        }
    }

    /// Keep selected documents accessible even when a workspace/query hides
    /// their cards. Ordering and removing always act on the same local draft.
    private var selectedDocuments: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("comparison.chooser.selected_order"))
                .font(.caption.weight(.medium)).foregroundStyle(theme.secondaryText)
            if draft.selectedDocumentIDs.isEmpty {
                Text(L10n.string("comparison.chooser.select_hint"))
                    .font(.caption).foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(draft.selectedDocumentIDs, id: \.self) { id in
                            if let document = documents.first(where: { $0.id == id }),
                               let index = draft.selectionIndex(for: id) {
                                selectedDocumentChip(document, index: index)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .accessibilityIdentifier("comparison-chooser-selected")
    }

    private func selectedDocumentChip(_ document: ComparisonDocument, index: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1)").font(.caption.bold()).foregroundStyle(theme.accent)
            Text(document.title).font(.caption).lineLimit(1).frame(maxWidth: 120)
            Button { draft.moveSelection(document.id, by: -1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            }
            .disabled(index == 0)
            .help(L10n.string("action.move_forward"))
            .accessibilityLabel(document.title + ", " + L10n.string("action.move_forward"))
            Button { draft.moveSelection(document.id, by: 1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .disabled(index == draft.selectedDocumentIDs.count - 1)
            .help(L10n.string("action.move_backward"))
            .accessibilityLabel(document.title + ", " + L10n.string("action.move_backward"))
            Button { draft.toggleSelection(document.id) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(theme.secondaryText)
            }
            .help(L10n.string("comparison.chooser.remove"))
            .accessibilityLabel(document.title + ", " + L10n.string("comparison.chooser.remove"))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(theme.selectionFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(theme.selectionBorder, lineWidth: 1) }
        .help(document.title + "\n" + locationLabel(document))
    }

    private var documentBrowser: some View {
        ScrollView {
            if visibleDocuments.isEmpty {
                ContentUnavailableView(
                    L10n.string("gallery.no_results"), systemImage: "doc.text.magnifyingglass",
                    description: Text(L10n.string("comparison.chooser.no_results_help"))
                )
                .frame(maxWidth: .infinity, minHeight: 270)
            } else if presentation == .gallery {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 175, maximum: 260), spacing: 12)], spacing: 12) {
                    ForEach(visibleDocuments) { document in documentCard(document) }
                }
                .padding(3)
            } else {
                LazyVStack(spacing: 1) {
                    ForEach(visibleDocuments) { document in documentRow(document) }
                }
                .hwattakPDFCard(theme, cornerRadius: 12)
                .padding(3)
            }
        }
        .frame(height: 320)
        .accessibilityIdentifier("comparison-chooser-documents")
    }

    private func locationLabel(_ document: ComparisonDocument) -> String {
        [document.workspaceTitle, document.groupTitle,
         document.tabIndex.map { L10n.format("comparison.chooser.tab", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func documentCard(_ document: ComparisonDocument) -> some View {
        let selectionIndex = draft.selectionIndex(for: document.id)
        let selected = selectionIndex != nil
        let selectionLimitReached = draft.selectedDocumentIDs.count >= PDFComparisonConfiguration.maximumDocumentCount

        return Button { draft.toggleSelection(document.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ComparisonChooserPreview(workspace: document.workspace, source: previewPage)
                    .frame(height: 155).padding(12)
                    .background(theme.canvas.opacity(0.8))
                    .overlay(alignment: .topTrailing) {
                        selectionBadge(selectionIndex).padding(8)
                    }
                VStack(alignment: .leading, spacing: 5) {
                    Text(document.title)
                        .font(.system(size: 12, weight: .medium)).lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                    Text(locationLabel(document))
                        .font(.system(size: 10, weight: .medium)).lineLimit(2)
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        Text(L10n.format("gallery.current_page", document.workspace.currentPageIndex + 1, document.pageCount))
                            .monospacedDigit()
                        Spacer(minLength: 0)
                        if document.isDirty {
                            Circle().fill(theme.accent).frame(width: 5, height: 5)
                                .help(L10n.string("gallery.modified"))
                        }
                    }
                    .font(.caption2).foregroundStyle(theme.secondaryText)
                }
                .padding(10)
            }
            .background(selected ? theme.selectionFill : theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? theme.selectionBorder : theme.border, lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!selected && selectionLimitReached)
        .help(document.title + "\n" + locationLabel(document))
        .accessibilityLabel(document.title + ", " + locationLabel(document) + ", " + L10n.format("page.count", document.pageCount))
        .accessibilityValue(selected ? L10n.format("comparison.order", (selectionIndex ?? 0) + 1) : L10n.string("selection.not_selected"))
        .accessibilityIdentifier("comparison-chooser-card-\(document.id)")
    }

    private func selectionBadge(_ index: Int?) -> some View {
        ZStack {
            Circle().fill(index != nil ? theme.accent : theme.panel)
            if let index {
                Text("\(index + 1)").font(.caption.bold()).foregroundStyle(theme.accentForeground)
            } else {
                Image(systemName: "plus").font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
            }
        }
        .frame(width: 27, height: 27)
        .overlay { Circle().stroke(index != nil ? theme.accent : theme.border, lineWidth: 1) }
    }

    private func documentRow(_ document: ComparisonDocument) -> some View {
        let selectionIndex = draft.selectionIndex(for: document.id)
        let selected = selectionIndex != nil
        let selectionLimitReached = draft.selectedDocumentIDs.count >= PDFComparisonConfiguration.maximumDocumentCount

        return HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    draft.toggleSelection(document.id)
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? theme.accent : theme.panel)
                        if let selectionIndex {
                            Text("\(selectionIndex + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(theme.accentForeground)
                        } else {
                            Image(systemName: "plus")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .frame(width: 29, height: 29)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(selected ? theme.accent : theme.border, lineWidth: 1)
                    }

                    ComparisonChooserPreview(workspace: document.workspace, source: previewPage, width: 54)
                        .frame(width: 40, height: 50)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Text(locationLabel(document))
                            .font(.caption).lineLimit(1).foregroundStyle(theme.secondaryText)
                        HStack(spacing: 5) {
                            Text(L10n.format("page.count", document.pageCount))
                            if document.isDirty {
                                Text("편집됨")
                                    .foregroundStyle(theme.warning)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!selected && selectionLimitReached)
            .accessibilityLabel(
                L10n.format("comparison.document_accessibility", document.title, document.pageCount)
                + ", " + locationLabel(document)
            )
            .accessibilityIdentifier("comparison-chooser-row-\(document.id)")
            .accessibilityValue(
                selected
                    ? L10n.format("comparison.order", (selectionIndex ?? 0) + 1)
                    : L10n.string("selection.not_selected")
            )

            if let selectionIndex {
                HStack(spacing: 2) {
                    reorderButton("chevron.up", label: L10n.string("action.move_forward")) {
                        draft.moveSelection(document.id, by: -1)
                    }
                    .disabled(selectionIndex == 0)

                    reorderButton("chevron.down", label: L10n.string("action.move_backward")) {
                        draft.moveSelection(document.id, by: 1)
                    }
                    .disabled(selectionIndex == draft.selectedDocumentIDs.count - 1)
                }
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 74)
        .background(selected ? theme.dropHighlight.opacity(0.62) : Color.clear)
    }

    private var layoutSelection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle("배치", detail: "분할선 방향까지 함께 표시합니다.")

            HStack(spacing: 8) {
                layoutButton(
                    "comparison.arrange.horizontal",
                    symbol: "rectangle.split.2x1",
                    identifier: "comparison-setup-horizontal"
                ) {
                    draft.applyPreset(.sideBySide)
                }
                layoutButton(
                    "comparison.arrange.vertical",
                    symbol: "rectangle.split.1x2",
                    identifier: "comparison-setup-vertical"
                ) {
                    draft.applyPreset(.stacked)
                }
                layoutButton(
                    "comparison.arrange.grid",
                    symbol: "rectangle.split.2x2",
                    identifier: "comparison-setup-grid"
                ) {
                    draft.applyGridPreset()
                }
            }
            .buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.splitTree == nil ? layoutHelp : L10n.string("comparison.arrange.custom"))
                Text(L10n.string("comparison.arrange.hint"))
            }
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
        }
    }

    private func layoutButton(
        _ titleKey: String,
        symbol: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(L10n.string(titleKey), systemImage: symbol)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
    }

    private var scrollSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("트랙패드 스크롤", detail: nil)

            Toggle(isOn: $draft.syncEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("문서 위치 함께 이동")
                        .font(.system(size: 13, weight: .semibold))
                    Text(L10n.string("comparison.motion_sync.help"))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hwattakPDFCard(theme, cornerRadius: 12)

            Label(
                L10n.string("comparison.pin.help"),
                systemImage: "pin.fill"
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
        }
    }

    private var footer: some View {
        HStack {
            Text(validationMessage)
                .font(.caption)
                .foregroundStyle(draft.canBeginComparison ? theme.secondaryText : theme.warning)

            Spacer()

            Button("취소", action: onCancel)
                .keyboardShortcut(.cancelAction)

            Button(L10n.string("비교 시작")) {
                configuration = draft
                onStart()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.canBeginComparison)
            .accessibilityIdentifier("comparison-start")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(theme.sidebar)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.border).frame(height: 1)
        }
    }

    private var layoutHelp: String {
        switch draft.layout {
        case .sideBySide:
            L10n.string("comparison.layout.side_by_side_help")
        case .stacked:
            L10n.string("comparison.layout.stacked_help")
        }
    }

    private var validationMessage: String {
        if draft.selectedDocumentIDs.count < PDFComparisonConfiguration.minimumDocumentCount {
            return L10n.format(
                "comparison.minimum_selection",
                PDFComparisonConfiguration.minimumDocumentCount
            )
        }
        return L10n.format("comparison.open_selection", draft.selectedDocumentIDs.count)
    }

    private func sectionTitle(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.string(title))
                .font(.headline)
            Spacer()
            if let detail {
                Text(L10n.string(detail))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private func reorderButton(
        _ systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 25, height: 25)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func prepareDraft() {
        let availableIDs = Set(documents.map(\.id))
        draft.normalize(availableDocumentIDs: availableIDs)

        if draft.selectedDocumentIDs.count < PDFComparisonConfiguration.minimumDocumentCount {
            for id in documents.map(\.id) where !draft.isSelected(id) {
                draft.selectedDocumentIDs.append(id)
                if draft.selectedDocumentIDs.count == PDFComparisonConfiguration.minimumDocumentCount {
                    break
                }
            }
        }
    }
}
