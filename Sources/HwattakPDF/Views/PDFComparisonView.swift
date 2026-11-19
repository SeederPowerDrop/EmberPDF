// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let comparisonPanelsCoordinateSpace = "ember-pdf-comparison-panels"
private let comparisonPanelHeaderHeight: CGFloat = 64

/// Keeps each PDFView at a stable document identity while split rectangles change.
/// A recursive stack would recreate views when a document changes split parent.
@MainActor
struct PDFComparisonView: View {
    let documents: [ComparisonDocument]
    @Binding var configuration: PDFComparisonConfiguration
    let onConfigure: () -> Void
    let onExit: () -> Void
    var onSelectDocument: (UUID, UUID?) -> Void = { _, _ in }
    var onOpenDocument: (UUID?) -> Void = { _ in }
    var onRemoveDocument: (UUID) -> Void = { _ in }
    var isOpeningDocument = false
    var isFocusMode: Bool = false
    var setFocusMode: (Bool) -> Void = { _ in }

    @StateObject private var scrollCoordinator = PDFScrollSyncCoordinator()
    // The sidebar observes progress. The native page surface only owns this
    // stable reference, so reading every page does not redraw every PDF pane.
    @State private var differenceService = PDFDocumentDifferenceService()
    @State private var showingDifferences = false
    @State private var activeDivider: UUID?
    @State private var initialFraction: Double?
    @State private var hoveredDivider: UUID?
    @State private var isArranging = false
    @State private var showingAddDocument = false
    @State private var dragSession = PDFComparisonDragSession()
    @State private var dragPoint: CGPoint?
    private var draggedDocumentID: UUID? { dragSession.sourceID }
    @State private var dropTarget: UUID?
    @State private var dropPlacement: PDFComparisonDropLocation?
    @EmberTheme private var theme

    private var selectedDocuments: [ComparisonDocument] {
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        return configuration.selectedDocumentIDs.compactMap { byID[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Keep this container's slot stable while removing hidden controls
            // from AppKit's keyboard and accessibility hierarchies altogether.
            VStack(spacing: 0) {
                if !isFocusMode { toolbar }
            }
            if !selectedDocuments.isEmpty {
                HStack(spacing: 0) {
                    panels
                    if showingDifferences && !isFocusMode {
                        Divider()
                        PDFDocumentDifferenceView(documents: selectedDocuments,
                            lockedIDs: configuration.lockedDocumentIDs, service: differenceService,
                            reveal: { scrollCoordinator.revealComparisonDifferences($0) },
                            close: { showingDifferences = false })
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(L10n.string("비교할 PDF가 부족합니다"), systemImage: "rectangle.split.2x1")
                } description: {
                    Text(L10n.string("열려 있는 PDF 중 2~4개를 다시 선택해 주세요."))
                } actions: {
                    Button(L10n.string("문서 선택"), action: onConfigure)
                }
            }
        }
        .background(theme.canvas)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .overlay(alignment: .topTrailing) {
            if isFocusMode { focusControls.padding(8) }
        }
        .onChange(of: configuration.syncEnabled, initial: true) { _, value in scrollCoordinator.enabled = value }
        .onChange(of: documents.map(\.id), initial: true) { _, ids in
            configuration.normalize(availableDocumentIDs: Set(ids))
        }
        .onChange(of: configuration.selectedDocumentIDs) { _, _ in clearDrag() }
        .onChange(of: isArranging) { _, enabled in if !enabled { clearDrag() } }
        .onChange(of: isFocusMode) { _, enabled in
            if enabled { finishArranging() }
        }
        .onDisappear { clearDrag(); differenceService.cancel(); NSCursor.arrow.set() }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Button(action: onExit) { Label(L10n.string("비교 종료"), systemImage: "chevron.backward") }
                        .keyboardShortcut(isFocusMode || isArranging || draggedDocumentID != nil ? nil : KeyboardShortcut(.escape, modifiers: []))
                        .accessibilityIdentifier("comparison-exit")
                    HStack(spacing: 5) {
                        TogetherViewIcon(size: 18)
                        Text(L10n.string("PDF 비교")).font(.headline)
                    }
                    Text(L10n.format("document.count", selectedDocuments.count)).foregroundStyle(theme.secondaryText)
                    Divider().frame(height: 20)
                    Button { showingAddDocument = true } label: {
                        Label(L10n.string("comparison.document.add"), systemImage: "doc.badge.plus")
                    }
                    .disabled(configuration.selectedDocumentIDs.count >= PDFComparisonConfiguration.maximumDocumentCount || isOpeningDocument)
                    .help(L10n.string(configuration.selectedDocumentIDs.count >= PDFComparisonConfiguration.maximumDocumentCount
                                     ? "comparison.document.limit" : "comparison.document.add.help"))
                    .accessibilityIdentifier("comparison-add-document")
                    .popover(isPresented: $showingAddDocument, arrowEdge: .bottom) {
                        ComparisonQuickDocumentPicker(
                            documents: documents,
                            excludedDocumentIDs: Set(configuration.selectedDocumentIDs),
                            onSelect: { id in
                                showingAddDocument = false
                                onSelectDocument(id, nil)
                            },
                            onOpenFile: {
                                showingAddDocument = false
                                DispatchQueue.main.async { onOpenDocument(nil) }
                            }
                        )
                    }
                    if isOpeningDocument { ProgressView().controlSize(.small) }
                    Menu {
                        Button { configuration.applyPreset(.sideBySide) } label: {
                            Label(L10n.string("comparison.arrange.horizontal"), systemImage: PDFComparisonLayout.sideBySide.systemImage)
                        }
                        Button { configuration.applyPreset(.stacked) } label: {
                            Label(L10n.string("comparison.arrange.vertical"), systemImage: PDFComparisonLayout.stacked.systemImage)
                        }
                        Button { configuration.applyGridPreset() } label: {
                            Label(L10n.string("comparison.arrange.grid"), systemImage: "rectangle.split.2x2")
                        }
                        Divider()
                        Button { configuration.resetSplitFractions() } label: {
                            Label(L10n.string("comparison.arrange.equal"), systemImage: "equal.square")
                        }
                    } label: {
                        Label(L10n.string("배치"), systemImage: "rectangle.split.2x2")
                    }
                    .fixedSize()
                    .accessibilityIdentifier("comparison-layout-menu")
                    Button {
                        if isArranging || draggedDocumentID != nil {
                            clearDrag()
                            isArranging = false
                        } else {
                            isArranging = true
                        }
                    } label: {
                        Label(L10n.string(isArranging ? "comparison.arrange.done" : "comparison.arrange.edit"),
                              systemImage: isArranging ? "checkmark" : "hand.draw")
                    }
                    .foregroundStyle(isArranging ? theme.accent : theme.primaryText)
                    .keyboardShortcut(!isFocusMode && (isArranging || draggedDocumentID != nil) ? KeyboardShortcut(.escape, modifiers: []) : nil)
                    .help(L10n.string("comparison.arrange.edit_hint"))
                    .accessibilityIdentifier("comparison-arrangement-edit")
                    Toggle(isOn: $configuration.syncEnabled) {
                        Label(L10n.string("comparison.motion_sync"), systemImage: "arrow.triangle.branch")
                    }
                    .toggleStyle(.switch).fixedSize()
                    .help(L10n.string("comparison.motion_sync.help"))
                    .accessibilityIdentifier("comparison-sync-toggle")
                    HStack(spacing: 3) {
                        Button { scrollCoordinator.stepPages(by: -1) } label: {
                            Image(systemName: "chevron.left.2")
                        }
                        .help(L10n.string("comparison.all_previous"))
                        .accessibilityLabel(L10n.string("comparison.all_previous"))
                        .accessibilityIdentifier("comparison-all-previous")
                        Button { scrollCoordinator.stepPages(by: 1) } label: {
                            Image(systemName: "chevron.right.2")
                        }
                        .help(L10n.string("comparison.all_next"))
                        .accessibilityLabel(L10n.string("comparison.all_next"))
                        .accessibilityIdentifier("comparison-all-next")
                    }
                    .disabled(selectedDocuments.allSatisfy { configuration.isLocked($0.id) })
                    Button(action: onConfigure) {
                        Label(L10n.string("문서 선택"), systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("comparison-configure")
                    Button { showingDifferences.toggle() } label: {
                        Label(PDFDocumentDifferenceText.string("title", "Text changes"), systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(selectedDocuments.count < 2)
                    .foregroundStyle(showingDifferences ? theme.accent : theme.primaryText)
                    .accessibilityIdentifier("comparison-difference-toggle")
                    Button {
                        finishArranging()
                        setFocusMode(true)
                    } label: {
                        Label(L10n.string("view.focus.enter"), systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .help(L10n.string("comparison.focus.help"))
                    .accessibilityIdentifier("comparison-focus-enter")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .frame(height: 42)
            }
            Text(L10n.string(isArranging ? "comparison.arrange.edit_hint" : "comparison.arrange.hint"))
                .font(.caption).foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .background(theme.sidebar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Only these two compact controls cover the documents in focus mode.
    /// The toolbar's container remains in the same slot above the panels,
    /// preserving every PDFView and its reading position when toggling.
    private var focusControls: some View {
        HStack(spacing: 2) {
            Button { setFocusMode(false) } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .frame(width: 28, height: 28)
            }
            .keyboardShortcut(.escape, modifiers: [])
            .help(L10n.string("view.focus.exit_help"))
            .accessibilityLabel(L10n.string("view.focus.exit"))
            .accessibilityIdentifier("comparison-focus-exit")
            Divider().frame(height: 16)
            Button(action: onExit) {
                Image(systemName: "xmark").frame(width: 28, height: 28)
            }
            .help(L10n.string("비교 종료"))
            .accessibilityLabel(L10n.string("비교 종료"))
            .accessibilityIdentifier("comparison-focus-comparison-exit")
        }
        .font(.system(size: 12, weight: .semibold))
        .buttonStyle(.borderless)
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(theme.border.opacity(0.8), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    private func finishArranging() {
        clearDrag()
        isArranging = false
    }

    private var panels: some View {
        GeometryReader { proxy in
            let geometry = PDFComparisonGeometry(tree: configuration.effectiveSplitTree, size: proxy.size)
            ZStack(alignment: .topLeading) {
                ForEach(selectedDocuments) { document in
                    if let rect = geometry.panels[document.id] {
                        PDFComparisonPanel(document: document,
                            isLocked: configuration.isLocked(document.id),
                            isFocusMode: isFocusMode,
                            syncEnabled: configuration.syncEnabled,
                            scrollCoordinator: scrollCoordinator,
                            otherDocuments: selectedDocuments.filter { $0.id != document.id },
                            availableDocuments: documents,
                            selectedDocumentIDs: Set(configuration.selectedDocumentIDs),
                            isOpeningDocument: isOpeningDocument,
                            replaceDocument: { onSelectDocument($0, document.id) },
                            openDocument: { onOpenDocument(document.id) },
                            closeDocument: { onRemoveDocument(document.id) },
                            dragChanged: { sessionID, point in
                                updatePanelDrag(document.id, sessionID: sessionID, at: point, geometry: geometry)
                            },
                            dragEnded: { sessionID, point in
                                finishPanelDrag(document.id, sessionID: sessionID, at: point, geometry: geometry)
                            },
                            dragCancelled: { sessionID in cancelPanelDrag(sessionID) },
                            toggleLock: { configuration.toggleLock(document.id) },
                            place: { target, placement in
                                configuration.placeDocument(document.id, relativeTo: target, placement: placement)
                            },
                            swap: { target in configuration.swapDocuments(document.id, with: target) })
                        .frame(width: rect.width, height: rect.height)
                        .clipped()
                        .overlay(alignment: .bottom) {
                            if isArranging && !isFocusMode {
                                PDFComparisonArrangementSurface(
                                    title: document.title,
                                    isSource: draggedDocumentID == document.id,
                                    showsPrompt: draggedDocumentID == nil,
                                    dragChanged: { sessionID, point in
                                        updatePanelDrag(document.id, sessionID: sessionID, at: point, geometry: geometry)
                                    },
                                    dragEnded: { sessionID, point in
                                        finishPanelDrag(document.id, sessionID: sessionID, at: point, geometry: geometry)
                                    },
                                    dragCancelled: { sessionID in cancelPanelDrag(sessionID) }
                                )
                                .frame(height: max(0, rect.height - comparisonPanelHeaderHeight))
                                .accessibilityIdentifier("comparison-arrangement-surface-\(document.id)")
                            }
                        }
                        .overlay { dropPreview(for: document.id) }
                        .offset(x: rect.minX, y: rect.minY)
                    }
                }
                ForEach(geometry.dividers) { divider in
                    splitDivider(divider)
                        .frame(width: divider.rect.width, height: divider.rect.height)
                        .offset(x: divider.rect.minX, y: divider.rect.minY)
                }
                if let source = selectedDocuments.first(where: { $0.id == draggedDocumentID }), let point = dragPoint {
                    dragGhost(title: source.title, point: point, size: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .coordinateSpace(name: comparisonPanelsCoordinateSpace)
            .environment(\.layoutDirection, .leftToRight)
        }
        .background(theme.border)
        .clipped()
    }

    private func splitDivider(_ split: PDFComparisonGeometry.Divider) -> some View {
        let vertical = split.axis == .sideBySide
        return ZStack {
            theme.border.opacity(0.3)
            RoundedRectangle(cornerRadius: 2)
                .fill(activeDivider == split.id || hoveredDivider == split.id ? theme.accent : theme.secondaryText.opacity(0.45))
                .frame(width: vertical ? 3 : 30, height: vertical ? 30 : 3)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(comparisonPanelsCoordinateSpace)).onChanged { value in
            if activeDivider != split.id { activeDivider = split.id; initialFraction = split.fraction }
            let delta = vertical ? value.translation.width : value.translation.height
            let fraction = (initialFraction ?? split.fraction) + Double(delta / max(1, split.availableLength))
            configuration.setSplitFraction(split.id, fraction: min(split.maximumFraction, max(split.minimumFraction, fraction)))
        }.onEnded { _ in activeDivider = nil; initialFraction = nil })
        .onHover { inside in
            hoveredDivider = inside ? split.id : nil
            (inside ? (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown) : NSCursor.arrow).set()
        }
        .contextMenu {
            Button { configuration.setSplitAxis(split.id, axis: .sideBySide) } label: {
                Label(L10n.string("comparison.arrange.horizontal"), systemImage: PDFComparisonLayout.sideBySide.systemImage)
            }
            Button { configuration.setSplitAxis(split.id, axis: .stacked) } label: {
                Label(L10n.string("comparison.arrange.vertical"), systemImage: PDFComparisonLayout.stacked.systemImage)
            }
            Button { configuration.setSplitFraction(split.id, fraction: 0.5) } label: {
                Label(L10n.string("comparison.arrange.equal"), systemImage: "equal.square")
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.string(vertical ? "comparison.resize.width" : "comparison.resize.height"))
        .accessibilityValue("\(Int(split.fraction * 100))%")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.05 : -0.05
            configuration.setSplitFraction(split.id, fraction: min(split.maximumFraction, max(split.minimumFraction, split.fraction + delta)))
        }
        .accessibilityIdentifier("comparison-divider-\(split.id)")
    }

    @ViewBuilder private func dropPreview(for id: UUID) -> some View {
        if let source = draggedDocumentID {
            GeometryReader { proxy in
                if source == id {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .padding(3)
                } else {
                    let active = dropTarget == id ? dropPlacement : nil
                    if let active {
                        let rect = active.previewRect(in: proxy.size)
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accent.opacity(0.24))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.accent, lineWidth: 3))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                    ForEach(PDFComparisonDropLocation.guides, id: \.localizationKey) { location in
                        let selected = active == location
                        let compact = proxy.size.width < 340 || proxy.size.height < 260
                        let point = location.guideCenter(in: proxy.size)
                        HStack(spacing: 4) {
                            Image(systemName: location.systemImage).font(.caption.weight(.semibold))
                            if !compact {
                                Text(L10n.string(location.localizationKey)).font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(selected ? theme.canvas : theme.primaryText)
                        .padding(.horizontal, compact ? 8 : 10).padding(.vertical, 7)
                        .background(selected ? theme.accent : theme.sidebar.opacity(0.96), in: Capsule())
                        .overlay(Capsule().stroke(theme.accent.opacity(selected ? 1 : 0.45), lineWidth: selected ? 2 : 1))
                        .position(point)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func dragGhost(title: String, point: CGPoint, size: CGSize) -> some View {
        let width = min(260, max(100, size.width - 24))
        let x = min(max(8, point.x + 18), max(8, size.width - width - 8))
        let y = min(max(8, point.y + 18), max(8, size.height - 64))
        return VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: "doc.fill")
                .font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Text(L10n.string(dropPlacement?.localizationKey ?? "comparison.drag.cancel_hint"))
                .font(.caption2).foregroundStyle(theme.secondaryText)
        }
        .padding(10)
        .frame(width: width, alignment: .leading)
        .background(theme.sidebar.opacity(0.97), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.accent, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .offset(x: x, y: y)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func moveDocument(_ source: UUID, _ target: UUID, _ location: PDFComparisonDropLocation) {
        guard configuration.isSelected(source), configuration.isSelected(target), source != target else { return }
        switch location {
        case .swap: configuration.swapDocuments(source, with: target)
        case .edge(let placement): configuration.placeDocument(source, relativeTo: target, placement: placement)
        }
        clearDrag()
    }

    private func updatePanelDrag(_ source: UUID, sessionID: UUID, at point: CGPoint, geometry: PDFComparisonGeometry) {
        guard point.x.isFinite, point.y.isFinite, configuration.isSelected(source),
              dragSession.update(sessionID: sessionID, sourceID: source) else { return }
        dragPoint = point
        NSCursor.closedHand.set()
        let destination = geometry.dropDestination(at: point, excluding: source)
        dropTarget = destination?.id
        dropPlacement = destination?.location
    }

    private func finishPanelDrag(_ source: UUID, sessionID: UUID, at point: CGPoint, geometry: PDFComparisonGeometry) {
        // A cancelled mouse gesture may still deliver its final mouse-up. It
        // must not commit, even if its pointer is over a valid destination.
        guard dragSession.canCommit(sessionID: sessionID, sourceID: source) else { return }
        defer { clearDrag() }
        guard let destination = geometry.dropDestination(at: point, excluding: source) else { return }
        moveDocument(source, destination.id, destination.location)
    }

    private func cancelPanelDrag(_ sessionID: UUID) {
        if dragSession.id == sessionID { clearDrag() }
    }

    private func clearDrag() {
        dragSession.cancel()
        dragPoint = nil; dropTarget = nil; dropPlacement = nil
        activeDivider = nil; initialFraction = nil
        NSCursor.arrow.set()
    }

}

/// Geometry is separate from the SwiftUI hierarchy to preserve each PDFView.
struct PDFComparisonGeometry {
    struct Divider: Identifiable {
        let id: UUID
        let axis: PDFComparisonLayout
        let fraction: Double
        let rect: CGRect
        let availableLength: CGFloat
        let minimumFraction: Double
        let maximumFraction: Double
    }
    private(set) var panels: [UUID: CGRect] = [:]
    private(set) var dividers: [Divider] = []
    static let dividerWidth: CGFloat = 10

    init(tree: PDFComparisonSplit?, size: CGSize) {
        guard let tree, size.width.isFinite, size.height.isFinite else { return }
        resolve(tree, in: CGRect(origin: .zero, size: CGSize(width: max(0,size.width), height: max(0,size.height))))
    }

    func dropDestination(at point: CGPoint, excluding sourceID: UUID) -> (id: UUID, location: PDFComparisonDropLocation)? {
        guard point.x.isFinite, point.y.isFinite,
              let target = panels.first(where: { $0.key != sourceID && $0.value.contains(point) }) else {
            return nil
        }
        let localPoint = CGPoint(x: point.x - target.value.minX, y: point.y - target.value.minY)
        return (target.key, .resolve(point: localPoint, size: target.value.size))
    }

    private func minimumSize(_ node: PDFComparisonSplit) -> CGSize {
        switch node {
        case .document: return CGSize(width: 180, height: 140)
        case .split(_, let axis, _, let first, let second):
            let a = minimumSize(first), b = minimumSize(second)
            if axis == .sideBySide { return CGSize(width: a.width + b.width + Self.dividerWidth, height: max(a.height,b.height)) }
            return CGSize(width: max(a.width,b.width), height: a.height + b.height + Self.dividerWidth)
        }
    }

    private mutating func resolve(_ node: PDFComparisonSplit, in rect: CGRect) {
        switch node {
        case .document(let id): panels[id] = rect
        case .split(let id, let axis, let stored, let first, let second):
            let vertical = axis == .sideBySide
            let length = vertical ? rect.width : rect.height
            let divider = min(Self.dividerWidth, length)
            let available = max(0, length - divider)
            let a = minimumSize(first), b = minimumSize(second)
            let minA = vertical ? a.width : a.height, minB = vertical ? b.width : b.height
            let fit = min(1, available / max(1, minA + minB))
            let lower = available > 0 ? Double(minA * fit / available) : 0.5
            let upper = available > 0 ? Double(1 - minB * fit / available) : 0.5
            let fraction = min(upper, max(lower, stored.isFinite ? stored : 0.5))
            let firstLength = available * fraction
            let aRect = CGRect(x: rect.minX,y: rect.minY,width: vertical ? firstLength : rect.width,height: vertical ? rect.height : firstLength)
            let splitRect = CGRect(x: rect.minX + (vertical ? firstLength : 0),y: rect.minY + (vertical ? 0 : firstLength),width: vertical ? divider : rect.width,height: vertical ? rect.height : divider)
            let bRect = CGRect(x: vertical ? splitRect.maxX : rect.minX,y: vertical ? rect.minY : splitRect.maxY,width: vertical ? available-firstLength : rect.width,height: vertical ? rect.height : available-firstLength)
            dividers.append(Divider(id:id,axis:axis,fraction:fraction,rect:splitRect,availableLength:available,minimumFraction:lower,maximumFraction:upper))
            resolve(first,in:aRect); resolve(second,in:bRect)
        }
    }
}

let comparisonPanelDragType = UTType.utf8PlainText
func comparisonPanelItemProvider(for id: UUID) -> NSItemProvider {
    let payload = PDFComparisonPanelDragPayload.encodedValue(for: id)
    let provider = NSItemProvider(object: payload as NSString)
    provider.suggestedName = payload
    return provider
}

enum PDFComparisonDropLocation: Equatable {
    case edge(PDFComparisonPlacement)
    case swap
    static let guides: [Self] = [.edge(.left), .edge(.right), .edge(.above), .edge(.below), .swap]

    var localizationKey: String {
        switch self {
        case .edge(.left): "comparison.drop.left"
        case .edge(.right): "comparison.drop.right"
        case .edge(.above): "comparison.drop.above"
        case .edge(.below): "comparison.drop.below"
        case .swap: "comparison.drop.swap"
        }
    }

    var systemImage: String {
        switch self {
        case .edge(.left): "arrow.left.to.line"
        case .edge(.right): "arrow.right.to.line"
        case .edge(.above): "arrow.up.to.line"
        case .edge(.below): "arrow.down.to.line"
        case .swap: "arrow.left.arrow.right"
        }
    }

    /// These visible target centers deliberately share the resolver's local
    /// coordinate system, including narrow panels in a mixed arrangement.
    func guideCenter(in size: CGSize) -> CGPoint {
        switch self {
        case .edge(.left): CGPoint(x: size.width * 0.12, y: size.height * 0.5)
        case .edge(.right): CGPoint(x: size.width * 0.88, y: size.height * 0.5)
        case .edge(.above): CGPoint(x: size.width * 0.5, y: size.height * 0.12)
        case .edge(.below): CGPoint(x: size.width * 0.5, y: size.height * 0.88)
        case .swap: CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        }
    }

    static func resolve(point: CGPoint, size: CGSize) -> Self {
        let x = point.x / max(1,size.width), y = point.y / max(1,size.height)
        if x > 0.28 && x < 0.72 && y > 0.28 && y < 0.72 { return .swap }
        let edges: [(CGFloat,PDFComparisonPlacement)] = [(x,.left),(1-x,.right),(y,.above),(1-y,.below)]
        return .edge(edges.min { $0.0 < $1.0 }!.1)
    }
    func previewRect(in size: CGSize) -> CGRect {
        switch self {
        case .swap: return CGRect(origin:.zero,size:size)
                .insetBy(dx:min(6, max(0, size.width / 2)), dy:min(6, max(0, size.height / 2)))
        case .edge(.left): return CGRect(x:0,y:0,width:size.width/2,height:size.height)
        case .edge(.right): return CGRect(x:size.width/2,y:0,width:size.width/2,height:size.height)
        case .edge(.above): return CGRect(x:0,y:0,width:size.width,height:size.height/2)
        case .edge(.below): return CGRect(x:0,y:size.height/2,width:size.width,height:size.height/2)
        }
    }
}

@MainActor
private struct PDFComparisonPanel: View {
    let document: ComparisonDocument
    let isLocked: Bool
    let isFocusMode: Bool
    let syncEnabled: Bool
    @ObservedObject var scrollCoordinator: PDFScrollSyncCoordinator
    let otherDocuments: [ComparisonDocument]
    let availableDocuments: [ComparisonDocument]
    let selectedDocumentIDs: Set<UUID>
    let isOpeningDocument: Bool
    let replaceDocument: (UUID) -> Void
    let openDocument: () -> Void
    let closeDocument: () -> Void
    let dragChanged: (UUID, CGPoint) -> Void
    let dragEnded: (UUID, CGPoint) -> Void
    let dragCancelled: (UUID) -> Void
    let toggleLock: () -> Void
    let place: (UUID,PDFComparisonPlacement) -> Void
    let swap: (UUID) -> Void
    @ObservedObject private var workspace: PDFWorkspaceState
    @State private var isHeaderHovered = false
    @State private var showingReplacement = false
    @EmberTheme private var theme

    init(document:ComparisonDocument,isLocked:Bool,isFocusMode:Bool,syncEnabled:Bool,scrollCoordinator:PDFScrollSyncCoordinator,
         otherDocuments:[ComparisonDocument], availableDocuments: [ComparisonDocument],
         selectedDocumentIDs: Set<UUID>, isOpeningDocument: Bool,
         replaceDocument: @escaping (UUID) -> Void, openDocument: @escaping () -> Void,
         closeDocument: @escaping () -> Void, dragChanged:@escaping (UUID, CGPoint)->Void,
         dragEnded:@escaping (UUID, CGPoint)->Void,dragCancelled:@escaping (UUID)->Void,toggleLock:@escaping ()->Void,
         place:@escaping (UUID,PDFComparisonPlacement)->Void,swap:@escaping (UUID)->Void) {
        self.document=document; self.isLocked=isLocked; self.isFocusMode=isFocusMode; self.syncEnabled=syncEnabled
        self.scrollCoordinator=scrollCoordinator; self.otherDocuments=otherDocuments
        self.availableDocuments = availableDocuments; self.selectedDocumentIDs = selectedDocumentIDs
        self.isOpeningDocument = isOpeningDocument; self.replaceDocument = replaceDocument
        self.openDocument = openDocument; self.closeDocument = closeDocument
        self.dragChanged=dragChanged; self.dragEnded=dragEnded; self.dragCancelled=dragCancelled
        self.toggleLock=toggleLock; self.place=place; self.swap=swap
        _workspace=ObservedObject(wrappedValue:document.workspace)
    }

    var body: some View {
        VStack(spacing:0) {
            // Keep the PDF viewer as the second stable sibling. Only the
            // header's controls are removed when focus mode is enabled.
            VStack(spacing: 0) {
                if !isFocusMode {
                    VStack(spacing:2) {
                        HStack(spacing:5) {
                            HStack(spacing:5) {
                                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme.accent)
                                    .frame(width: 24, height: 24)
                                    .background(theme.accent.opacity(isHeaderHovered ? 0.2 : 0.1), in: RoundedRectangle(cornerRadius: 5))
                                Text(document.title).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength:0)
                            }
                            .frame(maxWidth:.infinity,minHeight:32,alignment:.leading)
                            .contentShape(Rectangle())
                            .modifier(PDFComparisonDragGesture(
                                changed: dragChanged, ended: dragEnded, cancelled: dragCancelled
                            ))
                            .onHover { hovering in
                                isHeaderHovered = hovering
                                (hovering ? NSCursor.openHand : NSCursor.arrow).set()
                            }
                            .help(L10n.string("comparison.arrange.hint"))
                            .accessibilityIdentifier("comparison-drag-\(document.id)")
                            Menu {
                                ForEach(otherDocuments) { other in
                                    Menu(other.title) {
                                        Button { place(other.id,.left) } label: {
                                            Label(L10n.string("comparison.place.left"), systemImage: "rectangle.lefthalf.inset.filled")
                                        }
                                        Button { place(other.id,.right) } label: {
                                            Label(L10n.string("comparison.place.right"), systemImage: "rectangle.righthalf.inset.filled")
                                        }
                                        Button { place(other.id,.above) } label: {
                                            Label(L10n.string("comparison.place.above"), systemImage: "rectangle.tophalf.inset.filled")
                                        }
                                        Button { place(other.id,.below) } label: {
                                            Label(L10n.string("comparison.place.below"), systemImage: "rectangle.bottomhalf.inset.filled")
                                        }
                                        Divider()
                                        Button { swap(other.id) } label: {
                                            Label(L10n.string("comparison.place.swap"), systemImage: "arrow.left.arrow.right")
                                        }
                                    }
                                }
                            } label: { Image(systemName:"rectangle.3.group") }
                            .menuStyle(.borderlessButton).fixedSize()
                            .disabled(otherDocuments.isEmpty)
                            .help(L10n.string("comparison.arrange.panel"))
                            .accessibilityLabel(L10n.format("comparison.arrange.document",document.title))
                            .accessibilityIdentifier("comparison-arrange-\(document.id)")
                            Button(action:toggleLock) { Image(systemName:isLocked ? "pin.fill" : "pin.slash") }
                                .foregroundStyle(isLocked ? theme.warning : theme.secondaryText)
                                .help(L10n.string("comparison.pin.help"))
                                .accessibilityLabel(L10n.format(isLocked ? "comparison.unpin" : "comparison.pin",document.title))
                                .accessibilityValue(L10n.string(isLocked ? "comparison.sync_excluded" : "comparison.sync_included"))
                                .accessibilityIdentifier("comparison-pin-\(document.id)")
                            Button { showingReplacement = true } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            .disabled(isOpeningDocument)
                            .help(L10n.string("comparison.document.replace.help"))
                            .accessibilityLabel(L10n.string("comparison.document.replace") + ": " + document.title)
                            .accessibilityIdentifier("comparison-replace-\(document.id)")
                            .popover(isPresented: $showingReplacement, arrowEdge: .bottom) {
                                ComparisonQuickDocumentPicker(
                                    documents: availableDocuments, excludedDocumentIDs: selectedDocumentIDs,
                                    replacingTitle: document.title,
                                    onSelect: { id in
                                        showingReplacement = false
                                        replaceDocument(id)
                                    }, onOpenFile: {
                                        showingReplacement = false
                                        DispatchQueue.main.async { openDocument() }
                                    }
                                )
                            }
                            Button(action: closeDocument) { Image(systemName: "xmark") }
                                .foregroundStyle(theme.secondaryText)
                                .help(L10n.string("comparison.document.close.help"))
                                .accessibilityLabel(L10n.string("comparison.document.close") + ": " + document.title)
                                .accessibilityIdentifier("comparison-close-\(document.id)")
                        }
                        HStack(spacing:4) {
                            Button { scrollCoordinator.stepPages(by:-1,sourceID:document.id) } label: { Image(systemName:"chevron.left") }
                                .disabled(workspace.currentPageIndex<=0)
                                .accessibilityLabel(L10n.format("comparison.page.previous",document.title))
                            PageJumpControl(workspace:workspace,onNavigate: { index in
                                scrollCoordinator.goToPage(index:index,sourceID:document.id)
                            })
                            .accessibilityIdentifier("comparison-page-\(document.id)")
                            Button { scrollCoordinator.stepPages(by:1,sourceID:document.id) } label: { Image(systemName:"chevron.right") }
                                .disabled(workspace.currentPageIndex+1>=workspace.pageCount)
                                .accessibilityLabel(L10n.format("comparison.page.next",document.title))
                            Spacer(minLength:0)
                            if isLocked {
                                Text(L10n.string("comparison.pinned")).font(.caption2).foregroundStyle(theme.warning)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                        }
                        .disabled(isLocked)
                        .padding(.bottom,4)
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    .padding(.horizontal,8)
                    .frame(height: comparisonPanelHeaderHeight)
                    .background(theme.sidebar)
                }
            }
            PDFKitViewer(state:workspace,scrollSyncCoordinator:scrollCoordinator,scrollSyncID:document.id,
                         scrollSyncLocked:isLocked,viewportContext:.comparison)
                .frame(maxWidth:.infinity,maxHeight:.infinity)
                .environment(\.layoutDirection,.leftToRight)
        }
        .background(theme.canvas)
        .overlay(Rectangle().stroke(isLocked ? theme.warning.opacity(0.65) : .clear,lineWidth:2).allowsHitTesting(false))
        .overlay(alignment: .topLeading) {
            if isFocusMode && isLocked {
                Button(action: toggleLock) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.warning)
                        .frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.borderless)
                .help(L10n.string("comparison.pin.help"))
                .accessibilityLabel(L10n.format("comparison.unpin", document.title))
                .accessibilityValue(L10n.string("comparison.sync_excluded"))
                .accessibilityIdentifier("comparison-focus-pin-\(document.id)")
                .padding(6)
            }
        }
        .onAppear { _ = document.prepareForDisplay() }
    }
}

/// One physical drag retains its identity after Escape so a late mouse-up
/// cannot apply a placement which the user has already cancelled.
struct PDFComparisonDragSession {
    private(set) var id: UUID?
    private(set) var sourceID: UUID?
    private var cancelledID: UUID?

    mutating func update(sessionID: UUID, sourceID: UUID) -> Bool {
        guard sessionID != cancelledID else { return false }
        id = sessionID
        self.sourceID = sourceID
        return true
    }

    func canCommit(sessionID: UUID, sourceID: UUID) -> Bool {
        id == sessionID && self.sourceID == sourceID && sessionID != cancelledID
    }

    mutating func cancel() {
        if let id { cancelledID = id }
        id = nil
        sourceID = nil
    }
}

/// Both the compact title handle and the optional large arrangement surface
/// use the same canvas coordinates, threshold, and cancellation semantics.
@MainActor
private struct PDFComparisonDragGesture: ViewModifier {
    let changed: (UUID, CGPoint) -> Void
    let ended: (UUID, CGPoint) -> Void
    let cancelled: (UUID) -> Void
    @State private var gestureID: UUID?
    @GestureState private var isDragging = false

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(comparisonPanelsCoordinateSpace))
                    .updating($isDragging) { _, active, _ in active = true }
                    .onChanged { value in
                        let id = gestureID ?? UUID()
                        gestureID = id
                        changed(id, value.location)
                    }
                    .onEnded { value in
                        guard let id = gestureID else { return }
                        gestureID = nil
                        ended(id, value.location)
                    }
            )
            .onChange(of: isDragging) { _, active in
                if !active, let id = gestureID {
                    gestureID = nil
                    cancelled(id)
                }
            }
            .onDisappear {
                if let id = gestureID { cancelled(id) }
            }
    }
}

@MainActor
private struct PDFComparisonArrangementSurface: View {
    let title: String
    let isSource: Bool
    let showsPrompt: Bool
    let dragChanged: (UUID, CGPoint) -> Void
    let dragEnded: (UUID, CGPoint) -> Void
    let dragCancelled: (UUID) -> Void
    @EmberTheme private var theme

    var body: some View {
        ZStack {
            theme.canvas.opacity(isSource ? 0.44 : 0.2)
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .padding(5)
            if showsPrompt {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.title2).foregroundStyle(theme.accent)
                    Text(L10n.string("comparison.drag.document"))
                        .font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                    Text(title).font(.caption2).foregroundStyle(theme.secondaryText)
                        .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
                }
                .padding(14)
                .frame(maxWidth: 230)
                .background(theme.sidebar.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.accent.opacity(0.35)))
                .padding(14)
            }
        }
        .contentShape(Rectangle())
        .modifier(PDFComparisonDragGesture(changed: dragChanged, ended: dragEnded, cancelled: dragCancelled))
        .onHover { hovering in (hovering ? NSCursor.openHand : NSCursor.arrow).set() }
        .help(L10n.string("comparison.arrange.edit_hint"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + ", " + L10n.string("comparison.drag.handle"))
    }
}
