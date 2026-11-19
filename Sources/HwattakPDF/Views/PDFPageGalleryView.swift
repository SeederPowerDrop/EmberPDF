// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// All pages in the active PDF, with one shared selection for batch operations.
/// Reading layout and zoom remain untouched when the gallery is dismissed.
struct PDFPageGalleryView: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let exportCombined: () -> Void
    let exportIndividually: () -> Void
    let close: () -> Void

    @AppStorage("pageGallery.thumbnailWidth") private var savedThumbnailWidth = 192.0
    @State private var liveThumbnailWidth: Double?
    @State private var magnificationBaseline: Double?
    @State private var selectionAnchor: Int?
    @State private var showingMove = false
    @State private var referencePage = "1"
    @State private var moveAfterPage = false
    @State private var pendingDeletion: GalleryDeletion?
    @State private var dragSession: GalleryDragSession?
    @State private var dropInFlight = false
    @State private var insertionTarget: Int?
    @FocusState private var gridFocused: Bool
    @EmberTheme private var theme

    private var thumbnailWidth: Double { min(460, max(112, liveThumbnailWidth ?? savedThumbnailWidth)) }
    private var hasSelection: Bool { !workspace.selectedPages.isEmpty }
    private var canEdit: Bool { workspace.allows(.pageEditing) && !workspace.isWritingOCRResult }
    private var canDelete: Bool { canEdit && hasSelection && workspace.selectedPages.count < workspace.pageCount }

    var body: some View {
        VStack(spacing: 0) {
            galleryHeader
            Divider().overlay(theme.border)
            selectionToolbar
            Divider().overlay(theme.border)
            pageGrid
            galleryFooter
        }
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
        .onAppear {
            savedThumbnailWidth = thumbnailWidth
            selectionAnchor = workspace.currentPageIndex
        }
        .onChange(of: workspace.revision) { _, _ in
            selectionAnchor = workspace.currentPageIndex
            dragSession = nil
            insertionTarget = nil
            pendingDeletion = nil
            showingMove = false
        }
        .onChange(of: workspace.mode) { _, _ in
            dragSession = nil
            insertionTarget = nil
            pendingDeletion = nil
            showingMove = false
        }
        .onDisappear { commitThumbnailWidth() }
        .task(id: dragSession?.payload.token) {
            guard let token = dragSession?.payload.token else { return }
            // SwiftUI's onDrag has no cancellation callback. Observe release
            // only while dragging; an accepted provider load owns cleanup.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                if NSEvent.pressedMouseButtons & 1 == 0, !dropInFlight {
                    // Let the native drop callback claim the provider first.
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard dragSession?.payload.token == token else { return }
                    if dropInFlight || NSEvent.pressedMouseButtons & 1 != 0 { continue }
                    dragSession = nil
                    insertionTarget = nil
                    return
                }
            }
        }
        .alert(
            L10n.format("page_gallery.delete_title", pendingDeletion?.pages.count ?? 0),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { deletion in
            Button(L10n.string("action.cancel"), role: .cancel) { pendingDeletion = nil }
            Button(L10n.string("page_gallery.delete"), role: .destructive) {
                guard canDelete, deletion.revision == workspace.revision,
                      deletion.pages == workspace.selectedPages else { return }
                workspace.deleteSelectedPages()
            }
        } message: { _ in
            Text(L10n.string("page_gallery.delete_message"))
        }
        .accessibilityIdentifier("pdf-page-gallery")
    }

    private var galleryHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                galleryTitle
                Spacer(minLength: 12)
                sizeControl
                closeButton
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack { galleryTitle; Spacer(); closeButton }
                sizeControl
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(theme.panel)
    }

    private var galleryTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(L10n.string("page_gallery.title"), systemImage: "rectangle.grid.3x2")
                .font(.system(size: 17, weight: .semibold))
            Text(L10n.format("page_gallery.subtitle", workspace.pageCount))
                .font(.caption).foregroundStyle(theme.secondaryText)
        }
        .fixedSize()
    }

    private var closeButton: some View {
        Button(action: close) {
            Label(L10n.string("page_gallery.close"), systemImage: "arrow.uturn.backward")
        }
        .controlSize(.large)
        .accessibilityIdentifier("page-gallery-close")
    }

    private var sizeControl: some View {
        HStack(spacing: 8) {
            Button { adjustThumbnailWidth(-32) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(thumbnailWidth <= 112)
            Slider(value: Binding(
                get: { thumbnailWidth },
                set: { liveThumbnailWidth = $0 }
            ), in: 112...460, onEditingChanged: { editing in
                if !editing { commitThumbnailWidth() }
            })
            .frame(width: 130)
            .accessibilityLabel(L10n.string("page_gallery.size"))
            .accessibilityValue(L10n.format("value.percent", Int(thumbnailWidth / 192 * 100)))
            .accessibilityIdentifier("page-gallery-size")
            Button { adjustThumbnailWidth(32) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(thumbnailWidth >= 460)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.secondaryText)
        .help(L10n.string("page_gallery.size"))
    }

    private var selectionToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Text(L10n.format("page_gallery.selected", workspace.selectedPages.count))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(hasSelection ? theme.accent : theme.secondaryText)
                Button(L10n.string(workspace.selectedPages.count == workspace.pageCount
                                   ? "page_gallery.deselect_all" : "page_gallery.select_all")) {
                    if workspace.selectedPages.count == workspace.pageCount {
                        workspace.selectedPages = []
                        selectionAnchor = nil
                    } else {
                        workspace.selectedPages = PDFPageGallerySelection.selectAll(pageCount: workspace.pageCount)
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("page-gallery-select-all")

                Divider().frame(height: 20)
                extractionMenu
                if canEdit {
                    Menu {
                        Button(L10n.string("오른쪽으로 회전")) { workspace.rotateSelectedPages(clockwise: true) }
                        Button(L10n.string("왼쪽으로 회전")) { workspace.rotateSelectedPages(clockwise: false) }
                    } label: {
                        Label(L10n.string("page_gallery.rotate"), systemImage: "rotate.right")
                    }
                    .disabled(!hasSelection)
                    .accessibilityIdentifier("page-gallery-rotate")
                    Button {
                        referencePage = String(workspace.currentPageIndex + 1)
                        showingMove = true
                    } label: {
                        Label(L10n.string("page_gallery.move"), systemImage: "arrow.left.arrow.right")
                    }
                    .disabled(!hasSelection || workspace.selectedPages.count == workspace.pageCount)
                    .popover(isPresented: $showingMove) { movePopover }
                    .accessibilityIdentifier("page-gallery-move")
                    Button(role: .destructive, action: requestDeletion) {
                        Label(L10n.string("page_gallery.delete"), systemImage: "trash")
                    }
                    .disabled(!canDelete)
                    .help(L10n.string(hasSelection && workspace.selectedPages.count == workspace.pageCount
                                      ? "page_gallery.minimum_one" : "page_gallery.delete"))
                    .accessibilityIdentifier("page-gallery-delete")
                } else if workspace.mode != .editing {
                    Button {
                        workspace.setMode(.editing)
                    } label: {
                        Label(L10n.string("page_gallery.edit"), systemImage: "pencil")
                    }
                    .help(L10n.string("page_gallery.edit_hint"))
                    .accessibilityIdentifier("page-gallery-edit")
                }
            }
            .controlSize(.regular)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(theme.panel)
    }

    private var extractionMenu: some View {
        Menu {
            Button(L10n.string("menu.export_selected_pages.combined"), action: exportCombined)
            Button(L10n.string("menu.export_selected_pages.individual"), action: exportIndividually)
        } label: {
            Label(L10n.string("page_gallery.extract"), systemImage: "square.and.arrow.up")
        }
        .disabled(!hasSelection || !workspace.canExtractPages)
        .accessibilityIdentifier("page-gallery-extract")
    }

    private var pageGrid: some View {
        GeometryReader { geometry in
            let width = max(80, min(CGFloat(thumbnailWidth), geometry.size.width - 48))
            let columns = max(1, Int((geometry.size.width - 24) / (width + 24)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 24), count: columns),
                              alignment: .center, spacing: 24) {
                        ForEach(0..<workspace.pageCount, id: \.self) { index in
                            GalleryPageLoader(workspace: workspace, index: index) { page in
                                pageCard(page, index: index, width: width)
                            }.id(index)
                        }
                    }
                    .padding(24)
                    endDropTarget
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                }
                .background(theme.canvas)
                .focusable()
                .focused($gridFocused)
                .onKeyPress(phases: [.down, .repeat]) { press in
                    handleKey(press, columns: columns)
                }
                .onAppear {
                    proxy.scrollTo(workspace.currentPageIndex, anchor: .center)
                    gridFocused = true
                }
                .onChange(of: workspace.currentPageIndex) { _, index in
                    proxy.scrollTo(index)
                }
                .onChange(of: showingMove) { oldValue, newValue in
                    if oldValue && !newValue { gridFocused = true }
                }
                .simultaneousGesture(MagnificationGesture().onChanged { factor in
                    if magnificationBaseline == nil { magnificationBaseline = thumbnailWidth }
                    liveThumbnailWidth = min(460, max(112, (magnificationBaseline ?? thumbnailWidth) * factor))
                }.onEnded { _ in
                    commitThumbnailWidth()
                    magnificationBaseline = nil
                })
                .environment(\.isPDFViewportResizing, liveThumbnailWidth != nil)
            }
        }
    }

    @ViewBuilder
    private func pageCard(_ page: PDFPage, index: Int, width: CGFloat) -> some View {
        let card = galleryCard(page, index: index, width: width)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { openPage(index) }
            .onTapGesture {
                selectPage(index, modifiers: (NSApp.currentEvent?.modifierFlags ?? []).union(NSEvent.modifierFlags))
            }
            .contextMenu { pageContextMenu(index: index) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.format("page.number", index + 1))
            .accessibilityValue(L10n.string(workspace.selectedPages.contains(index) ? "selection.selected" : "selection.not_selected"))
            .accessibilityAddTraits(workspace.selectedPages.contains(index) ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { selectPage(index, modifiers: []) }
            .accessibilityAction(named: Text(L10n.string("page_gallery.open_page"))) { openPage(index) }
            .accessibilityIdentifier("page-gallery-page-\(index + 1)")

        if canEdit {
            card
                .onDrag { beginDrag(index: index) }
                .modifier(GalleryDropModifier(
                    enabled: dragSession != nil,
                    target: index,
                    width: width,
                    insertionTarget: $insertionTarget,
                    perform: performDrop
                ))
        } else {
            card
        }
    }

    private func galleryCard(_ page: PDFPage, index: Int, width: CGFloat) -> some View {
        let selected = workspace.selectedPages.contains(index)
        let previewHeight = (width - 20) * 1.28
        let pageSize = page.bounds(for: .cropBox).size
        let rotated = abs(page.rotation % 180) == 90
        let pageWidth = rotated ? pageSize.height : pageSize.width
        let pageHeight = rotated ? pageSize.width : pageSize.height
        let aspect = pageHeight > 0 && pageWidth > 0 ? pageWidth / pageHeight : 1
        let imageWidth = min(width - 20, previewHeight * aspect)
        return VStack(spacing: 10) {
            PageThumbnailView(page: page, pageIndex: index, width: imageWidth,
                              revision: workspace.revision, showPageNumber: false,
                              fileSource: workspace.thumbnailFileSource)
                .frame(width: imageWidth)
                .frame(width: width - 20, height: previewHeight)
                .padding(.top, 4)
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? theme.accent : theme.secondaryText.opacity(0.5))
                    .contentShape(Rectangle())
                    .onTapGesture { selectPage(index, modifiers: [.command]) }
                Spacer(minLength: 4)
                Text(L10n.format("page.number", index + 1))
                    .font(.system(size: 12, weight: selected ? .semibold : .medium).monospacedDigit())
                Spacer(minLength: 4)
                Image(systemName: "checkmark.circle.fill").hidden()
            }
            .foregroundStyle(selected ? theme.accent : theme.secondaryText)
        }
        .padding(10)
        .frame(width: width)
        .background(selected ? theme.dropHighlight : theme.card.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? theme.accent : theme.border.opacity(0.6), lineWidth: selected ? 2 : 1)
        }
        .overlay(alignment: .leading) {
            if insertionTarget == index {
                Capsule().fill(theme.accent).frame(width: 4).padding(.leading, -14)
            }
        }
        .overlay(alignment: .trailing) {
            if insertionTarget == index + 1 {
                Capsule().fill(theme.accent).frame(width: 4).padding(.trailing, -14)
            }
        }
    }

    @ViewBuilder
    private func pageContextMenu(index: Int) -> some View {
        Button(L10n.string("page_gallery.open_page")) { openPage(index) }
        Divider()
        Menu(L10n.string("page_gallery.extract")) {
            Button(L10n.string("menu.export_selected_pages.combined")) { prepareContextSelection(index); exportCombined() }
            Button(L10n.string("menu.export_selected_pages.individual")) { prepareContextSelection(index); exportIndividually() }
        }
        .disabled(!workspace.canExtractPages)
        if canEdit {
            Divider()
            Button(L10n.string("왼쪽으로 회전")) { prepareContextSelection(index); workspace.rotateSelectedPages(clockwise: false) }
            Button(L10n.string("오른쪽으로 회전")) { prepareContextSelection(index); workspace.rotateSelectedPages(clockwise: true) }
            Menu(L10n.string("page_gallery.move")) {
                Button(L10n.string("page_gallery.move_start")) { prepareContextSelection(index); moveSelection(before: 0) }
                Button(L10n.string("page_gallery.move_end")) { prepareContextSelection(index); moveSelection(before: workspace.pageCount) }
            }
            Divider()
            Button(L10n.string("page_gallery.delete"), role: .destructive) { prepareContextSelection(index); requestDeletion() }
                .disabled(workspace.pageCount <= 1 || (workspace.selectedPages.contains(index) && workspace.selectedPages.count == workspace.pageCount))
        }
    }

    private var endDropTarget: some View {
        Color.clear
            .frame(height: 44)
            .overlay {
                if dragSession != nil {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(insertionTarget == workspace.pageCount ? theme.dropHighlight : theme.card)
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])) }
                    Label(L10n.string("page_gallery.drop_end"), systemImage: "arrow.down.to.line")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                }
            }
            .modifier(GalleryDropModifier(enabled: dragSession != nil && canEdit,
                                          target: workspace.pageCount, width: nil,
                                          insertionTarget: $insertionTarget, perform: performDrop))
    }

    private var galleryFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.string("page_gallery.hint"))
            if canEdit { Text(L10n.string("page_gallery.drag_hint")) }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 9)
        .background(theme.panel)
    }

    private var movePopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("page_gallery.move_title")).font(.headline)
            HStack {
                Button(L10n.string("page_gallery.move_start")) { moveSelection(before: 0) }
                Button(L10n.string("page_gallery.move_end")) { moveSelection(before: workspace.pageCount) }
            }
            Divider()
            HStack {
                TextField(L10n.string("page_gallery.move_page"), text: $referencePage)
                    .textFieldStyle(.roundedBorder).frame(width: 64)
                    .accessibilityIdentifier("page-gallery-move-reference")
                    .onSubmit { if let target = moveTarget { moveSelection(before: target) } }
                Text("/ \(workspace.pageCount)").foregroundStyle(theme.secondaryText)
                Picker(L10n.string("page_gallery.move"), selection: $moveAfterPage) {
                    Text(L10n.string("page_gallery.move_before")).tag(false)
                    Text(L10n.string("page_gallery.move_after")).tag(true)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 130)
                Button(L10n.string("page_gallery.move_apply")) {
                    if let target = moveTarget { moveSelection(before: target) }
                }
                .disabled(moveTarget == nil)
            }
            Text(L10n.string("page_gallery.move_hint")).font(.caption).foregroundStyle(theme.secondaryText)
        }
        .padding(18)
    }

    private var moveTarget: Int? {
        guard let page = Int(referencePage.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...max(1, workspace.pageCount)).contains(page) else { return nil }
        return moveAfterPage ? page : page - 1
    }

    private func selectPage(_ index: Int, modifiers: NSEvent.ModifierFlags) {
        let result = PDFPageGallerySelection.select(
            page: index, selectedPages: workspace.selectedPages,
            anchor: selectionAnchor, pageCount: workspace.pageCount,
            extending: modifiers.contains(.shift), toggling: modifiers.contains(.command)
        )
        // setCurrentPage seeds an empty selection; apply the actual selection last.
        workspace.setCurrentPage(index)
        workspace.selectedPages = result.selectedPages
        selectionAnchor = result.anchor
        gridFocused = true
    }

    private func openPage(_ index: Int) {
        workspace.setCurrentPage(index)
        workspace.selectedPages = [index]
        workspace.invalidatePDFViewportScrollPosition()
        close()
    }

    private func prepareContextSelection(_ index: Int) {
        if !workspace.selectedPages.contains(index) { selectPage(index, modifiers: []) }
    }

    private func requestDeletion() {
        guard canDelete else { return }
        pendingDeletion = GalleryDeletion(revision: workspace.revision, pages: workspace.selectedPages)
    }

    private func moveSelection(before target: Int) {
        guard canEdit else { return }
        workspace.moveSelectedPages(before: target)
        showingMove = false
        gridFocused = true
    }

    private func adjustThumbnailWidth(_ delta: Double) {
        savedThumbnailWidth = min(460, max(112, thumbnailWidth + delta))
        liveThumbnailWidth = nil
    }

    private func commitThumbnailWidth() {
        savedThumbnailWidth = thumbnailWidth
        liveThumbnailWidth = nil
    }

    private func handleKey(_ press: KeyPress, columns: Int) -> KeyPress.Result {
        guard !showingMove, pendingDeletion == nil else { return .ignored }
        if press.key == "a", press.modifiers == .command {
            workspace.selectedPages = PDFPageGallerySelection.selectAll(pageCount: workspace.pageCount)
            return .handled
        }
        guard press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
        switch press.key {
        case .escape:
            if dragSession != nil {
                dragSession = nil
                insertionTarget = nil
            } else {
                close()
            }
            return .handled
        case .return: openPage(workspace.currentPageIndex); return .handled
        case .delete: requestDeletion(); return .handled
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            let offset: Int
            switch press.key {
            case .leftArrow: offset = -1
            case .rightArrow: offset = 1
            case .upArrow: offset = -columns
            default: offset = columns
            }
            let target = min(max(0, workspace.currentPageIndex + offset), workspace.pageCount - 1)
            selectPage(target, modifiers: press.modifiers.contains(.shift) ? [.shift] : [])
            return .handled
        default: return .ignored
        }
    }

    private func beginDrag(index: Int) -> NSItemProvider {
        prepareContextSelection(index)
        let session = PDFPageDragSession(sourceIndex: index, documentRevision: workspace.revision)
        dropInFlight = false
        dragSession = GalleryDragSession(payload: session, pages: workspace.selectedPages)
        return PDFPageDragPayload.itemProvider(for: session)
    }

    private func performDrop(_ providers: [NSItemProvider], _ target: Int) -> Bool {
        guard canEdit, let session = dragSession else { return false }
        dropInFlight = true
        let scheduled = PDFPageDragPayload.loadEncodedValue(from: providers) { encodedValue in
            guard dragSession?.payload.token == session.payload.token else { return }
            defer { dragSession = nil; insertionTarget = nil; dropInFlight = false }
            guard canEdit, workspace.isPageGalleryVisible,
                  (0...workspace.pageCount).contains(target),
                  session.pages.allSatisfy({ (0..<workspace.pageCount).contains($0) }),
                  PDFPageDragPayload.validatedSourceIndex(
                    encodedValue: encodedValue, localSession: session.payload,
                    currentDocumentRevision: workspace.revision,
                    currentPageCount: workspace.pageCount
                  ) != nil else { return }
            workspace.selectedPages = session.pages
            workspace.moveSelectedPages(before: target)
        }
        if !scheduled { dragSession = nil; insertionTarget = nil; dropInFlight = false }
        return scheduled
    }
}

/// ForEach always emits one child per index. Page lookup happens only when
/// LazyVGrid materializes that child, not when it counts conditional children.
private struct GalleryPageLoader<Content: View>: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let index: Int
    @ViewBuilder let content: (PDFPage) -> Content

    var body: some View {
        if let page = workspace.document?.page(at: index) { content(page) }
    }
}

private struct GalleryDeletion {
    let revision: UUID
    let pages: Set<Int>
}

private struct GalleryDragSession {
    let payload: PDFPageDragSession
    let pages: Set<Int>
}

/// Only install nested drop receivers during an internal drag so ordinary
/// Finder drops still reach the workspace's file-opening receiver.
private struct GalleryDropModifier: ViewModifier {
    let enabled: Bool
    let target: Int
    let width: CGFloat?
    @Binding var insertionTarget: Int?
    let perform: ([NSItemProvider], Int) -> Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [PDFPageDragPayload.typeIdentifier], delegate: GalleryDropDelegate(
                target: target, width: width, insertionTarget: $insertionTarget, perform: perform
            ))
        } else {
            content
        }
    }
}

private struct GalleryDropDelegate: DropDelegate {
    let target: Int
    let width: CGFloat?
    @Binding var insertionTarget: Int?
    let perform: ([NSItemProvider], Int) -> Bool

    private func destination(_ info: DropInfo) -> Int {
        target + ((width.map { info.location.x > $0 / 2 } ?? false) ? 1 : 0)
    }
    func validateDrop(info: DropInfo) -> Bool {
        !info.hasItemsConforming(to: [UTType.fileURL.identifier])
            && info.hasItemsConforming(to: [PDFPageDragPayload.typeIdentifier])
    }
    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { insertionTarget = destination(info) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        insertionTarget = destination(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { insertionTarget = nil }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        insertionTarget = nil
        return perform(info.itemProviders(for: [PDFPageDragPayload.typeIdentifier]), destination(info))
    }
}
