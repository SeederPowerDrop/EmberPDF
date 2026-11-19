// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Opaque provider contents for comparison-panel reordering.
enum PDFComparisonPanelDragPayload {
    private static let kind = "comparison-panel"

    static func encodedValue(for documentID: UUID) -> String {
        InternalDragPayload.encodedValue(for: documentID, kind: kind)
    }

    static func decode(_ value: String) -> UUID? {
        InternalDragPayload.decode(value, expectedKind: kind)
    }
}

/// How selected PDFs are divided inside the comparison workspace.
enum PDFComparisonLayout: String, CaseIterable, Identifiable, Codable {
    /// Documents are placed next to each other using vertical dividers.
    case sideBySide
    /// Documents are placed above and below each other using horizontal dividers.
    case stacked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sideBySide:
            L10n.string("comparison.side_by_side")
        case .stacked:
            L10n.string("comparison.stacked")
        }
    }

    var splitDescription: String {
        switch self {
        case .sideBySide:
            L10n.string("comparison.vertical_split")
        case .stacked:
            L10n.string("comparison.horizontal_split")
        }
    }

    var systemImage: String {
        switch self {
        case .sideBySide:
            "rectangle.split.2x1"
        case .stacked:
            "rectangle.split.1x2"
        }
    }
}

/// Persistent choices for one comparison workspace.
///
/// `selectedDocumentIDs` is an ordered collection: its order is also the
/// visual order of the comparison panels. A locked document participates in
/// neither side of synchronized scrolling—it does not drive other panels and
/// it does not follow them.
struct PDFComparisonConfiguration: Equatable {
    static let minimumDocumentCount = 2
    static let maximumDocumentCount = 4

    var selectedDocumentIDs: [UUID] = []
    var layout: PDFComparisonLayout = .sideBySide
    var syncEnabled = true
    var lockedDocumentIDs: Set<UUID> = []
    /// A nested arrangement. Nil retains the pre-existing flat split and weights.
    var splitTree: PDFComparisonSplit? = nil
    private(set) var sideBySidePanelWeights: [UUID: Double] = [:]
    private(set) var stackedPanelWeights: [UUID: Double] = [:]

    var canBeginComparison: Bool {
        selectedDocumentIDs.count >= Self.minimumDocumentCount
            && selectedDocumentIDs.count <= Self.maximumDocumentCount
    }

    /// An existing comparison may keep its last panel while the user chooses
    /// another PDF. Starting a new comparison still requires two documents.
    var canContinueComparison: Bool {
        !selectedDocumentIDs.isEmpty
            && selectedDocumentIDs.count <= Self.maximumDocumentCount
    }

    /// Adds a panel without rebuilding the arrangement already on screen.
    @discardableResult
    mutating func addDocument(_ id: UUID) -> Bool {
        guard !isSelected(id), selectedDocumentIDs.count < Self.maximumDocumentCount else {
            return false
        }
        let existingTree = effectiveSplitTree
        selectedDocumentIDs.append(id)
        lockedDocumentIDs.remove(id)
        normalizePanelWeights()
        splitTree = existingTree?.normalized(selectedDocumentIDs: selectedDocumentIDs, fallbackAxis: layout)
        return true
    }

    /// Removes only the comparison membership. Closing the underlying tab is
    /// deliberately outside this model; remaining branches retain their sizes.
    @discardableResult
    mutating func removeDocument(_ id: UUID) -> Bool {
        guard let index = selectionIndex(for: id) else { return false }
        let existingTree = effectiveSplitTree
        selectedDocumentIDs.remove(at: index)
        lockedDocumentIDs.remove(id)
        normalizePanelWeights()
        splitTree = existingTree?.normalized(selectedDocumentIDs: selectedDocumentIDs, fallbackAxis: layout)
        return true
    }

    /// Replaces one pane in place, preserving the split geometry and its
    /// width/height presets. The new PDF starts unlocked for normal navigation.
    @discardableResult
    mutating func replaceDocument(_ id: UUID, with replacementID: UUID) -> Bool {
        guard let index = selectionIndex(for: id), !isSelected(replacementID) else {
            return false
        }
        let existingTree = effectiveSplitTree
        selectedDocumentIDs[index] = replacementID
        lockedDocumentIDs.remove(id)
        lockedDocumentIDs.remove(replacementID)
        if let weight = sideBySidePanelWeights.removeValue(forKey: id) {
            sideBySidePanelWeights[replacementID] = weight
        }
        if let weight = stackedPanelWeights.removeValue(forKey: id) {
            stackedPanelWeights[replacementID] = weight
        }
        normalizePanelWeights()
        splitTree = existingTree?.replacingDocument(id, with: replacementID)
            .normalized(selectedDocumentIDs: selectedDocumentIDs, fallbackAxis: layout)
        return true
    }

    func selectionIndex(for id: UUID) -> Int? {
        selectedDocumentIDs.firstIndex(of: id)
    }

    func isSelected(_ id: UUID) -> Bool {
        selectedDocumentIDs.contains(id)
    }

    func isLocked(_ id: UUID) -> Bool {
        lockedDocumentIDs.contains(id)
    }

    mutating func toggleSelection(_ id: UUID) {
        if let index = selectionIndex(for: id) {
            selectedDocumentIDs.remove(at: index)
            lockedDocumentIDs.remove(id)
        } else if selectedDocumentIDs.count < Self.maximumDocumentCount {
            selectedDocumentIDs.append(id)
        }
        normalizePanelWeights()
        normalizeSplitTree()
    }

    mutating func moveSelection(_ id: UUID, by offset: Int) {
        guard let source = selectionIndex(for: id) else { return }
        let destination = source + offset
        guard selectedDocumentIDs.indices.contains(destination) else { return }
        let oldOrder = selectedDocumentIDs
        selectedDocumentIDs.swapAt(source, destination)
        reorderSplitTree(from: oldOrder)
    }

    /// Moves a selected document immediately before another selected document.
    /// Split weights are keyed by document ID, so the resized width or height
    /// follows the document when it is reordered.
    mutating func moveSelection(_ id: UUID, before targetID: UUID) {
        guard
            id != targetID,
            let source = selectionIndex(for: id),
            selectionIndex(for: targetID) != nil
        else { return }
        let oldOrder = selectedDocumentIDs
        selectedDocumentIDs.remove(at: source)
        guard let target = selectionIndex(for: targetID) else { return }
        selectedDocumentIDs.insert(id, at: target)
        reorderSplitTree(from: oldOrder)
    }

    /// Moves a selected document immediately after another selected document.
    mutating func moveSelection(_ id: UUID, after targetID: UUID) {
        guard
            id != targetID,
            let source = selectionIndex(for: id),
            selectionIndex(for: targetID) != nil
        else { return }
        let oldOrder = selectedDocumentIDs
        selectedDocumentIDs.remove(at: source)
        guard let target = selectionIndex(for: targetID) else { return }
        selectedDocumentIDs.insert(id, at: target + 1)
        reorderSplitTree(from: oldOrder)
    }

    mutating func toggleLock(_ id: UUID) {
        guard isSelected(id) else { return }
        if lockedDocumentIDs.contains(id) {
            lockedDocumentIDs.remove(id)
        } else {
            lockedDocumentIDs.insert(id)
        }
    }

    /// Removes stale tab IDs while preserving the user's panel order.
    mutating func normalize(availableDocumentIDs: Set<UUID>) {
        var seen = Set<UUID>()
        selectedDocumentIDs = selectedDocumentIDs.filter { id in
            availableDocumentIDs.contains(id) && seen.insert(id).inserted
        }
        if selectedDocumentIDs.count > Self.maximumDocumentCount {
            selectedDocumentIDs = Array(selectedDocumentIDs.prefix(Self.maximumDocumentCount))
        }
        lockedDocumentIDs.formIntersection(Set(selectedDocumentIDs))
        normalizePanelWeights()
        normalizeSplitTree()
    }

    /// Returns normalized panel fractions for the requested split direction.
    /// Invalid or stale values fall back to an equal split.
    func panelFractions(for layout: PDFComparisonLayout) -> [Double] {
        let storedWeights: [UUID: Double]
        switch layout {
        case .sideBySide:
            storedWeights = sideBySidePanelWeights
        case .stacked:
            storedWeights = stackedPanelWeights
        }
        let validWeights = selectedDocumentIDs.compactMap { id -> Double? in
            guard let weight = storedWeights[id], weight.isFinite, weight > 0 else { return nil }
            return weight
        }
        let fallbackWeight = validWeights.isEmpty
            ? 1
            : validWeights.reduce(0, +) / Double(validWeights.count)
        let orderedWeights = selectedDocumentIDs.map { id -> Double in
            guard let weight = storedWeights[id], weight.isFinite, weight > 0 else {
                return fallbackWeight
            }
            return weight
        }
        return Self.normalizedFractions(orderedWeights, count: selectedDocumentIDs.count)
    }

    /// Converts stored fractions to concrete panel lengths while enforcing a
    /// usable minimum whenever the comparison viewport is large enough.
    func panelLengths(
        for layout: PDFComparisonLayout,
        availableLength: Double,
        minimumPanelLength: Double
    ) -> [Double] {
        Self.resolvedPanelLengths(
            fractions: panelFractions(for: layout),
            availableLength: availableLength,
            minimumPanelLength: minimumPanelLength
        )
    }

    /// Applies one divider drag. Only the two panels adjacent to the divider
    /// are resized; all other panel lengths remain unchanged.
    mutating func resizeDivider(
        for layout: PDFComparisonLayout,
        afterPanelAt dividerIndex: Int,
        translation: Double,
        availableLength: Double,
        minimumPanelLength: Double,
        initialFractions: [Double]? = nil
    ) {
        let count = selectedDocumentIDs.count
        guard
            count >= Self.minimumDocumentCount,
            dividerIndex >= 0,
            dividerIndex + 1 < count,
            availableLength.isFinite,
            availableLength > 0,
            translation.isFinite
        else { return }

        let startingFractions = Self.normalizedFractions(
            initialFractions ?? panelFractions(for: layout),
            count: count
        )
        var lengths = Self.resolvedPanelLengths(
            fractions: startingFractions,
            availableLength: availableLength,
            minimumPanelLength: minimumPanelLength
        )

        let pairLength = lengths[dividerIndex] + lengths[dividerIndex + 1]
        let effectiveMinimum = min(
            max(0, minimumPanelLength),
            availableLength / Double(count),
            pairLength / 2
        )
        let proposedLeadingLength = lengths[dividerIndex] + translation
        let leadingLength = min(
            max(proposedLeadingLength, effectiveMinimum),
            pairLength - effectiveMinimum
        )
        lengths[dividerIndex] = leadingLength
        lengths[dividerIndex + 1] = pairLength - leadingLength

        setPanelWeights(lengths.map { $0 / availableLength }, for: layout)
    }

    mutating func normalizePanelWeights() {
        sideBySidePanelWeights = normalizedPanelWeights(sideBySidePanelWeights)
        stackedPanelWeights = normalizedPanelWeights(stackedPanelWeights)
    }

    /// Scalar persistence bridge used by the app-wide session archive. The
    /// archive remains independent of this model while the private weight
    /// dictionaries stay encapsulated here.
    func persistedPanelWeights(
        for layout: PDFComparisonLayout
    ) -> [UUID: Double] {
        switch layout {
        case .sideBySide:
            sideBySidePanelWeights
        case .stacked:
            stackedPanelWeights
        }
    }

    mutating func restorePersistedPanelWeights(
        sideBySide: [UUID: Double],
        stacked: [UUID: Double]
    ) {
        sideBySidePanelWeights = sideBySide
        stackedPanelWeights = stacked
        normalizePanelWeights()
    }

    private mutating func setPanelWeights(
        _ fractions: [Double],
        for layout: PDFComparisonLayout
    ) {
        let normalized = Self.normalizedFractions(fractions, count: selectedDocumentIDs.count)
        let weights = Dictionary(uniqueKeysWithValues: zip(selectedDocumentIDs, normalized))
        switch layout {
        case .sideBySide:
            sideBySidePanelWeights = weights
        case .stacked:
            stackedPanelWeights = weights
        }
    }

    private func normalizedPanelWeights(_ weights: [UUID: Double]) -> [UUID: Double] {
        let selectedSet = Set(selectedDocumentIDs)
        var validWeights = weights.filter {
            selectedSet.contains($0.key) && $0.value.isFinite && $0.value > 0
        }
        let fallbackWeight = validWeights.isEmpty
            ? 1
            : validWeights.values.reduce(0, +) / Double(validWeights.count)
        selectedDocumentIDs.forEach { id in
            if validWeights[id] == nil {
                validWeights[id] = fallbackWeight
            }
        }
        return validWeights
    }

    private static func normalizedFractions(_ fractions: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard
            fractions.count == count,
            fractions.allSatisfy({ $0.isFinite && $0 > 0 })
        else {
            return Array(repeating: 1 / Double(count), count: count)
        }

        let total = fractions.reduce(0, +)
        guard total.isFinite, total > 0 else {
            return Array(repeating: 1 / Double(count), count: count)
        }
        return fractions.map { $0 / total }
    }

    /// Distributes the available length proportionally, pinning undersized
    /// panels at the effective minimum and redistributing the remainder.
    private static func resolvedPanelLengths(
        fractions: [Double],
        availableLength: Double,
        minimumPanelLength: Double
    ) -> [Double] {
        let count = fractions.count
        guard count > 0, availableLength.isFinite, availableLength > 0 else {
            return Array(repeating: 0, count: count)
        }

        let normalized = normalizedFractions(fractions, count: count)
        let minimum = min(max(0, minimumPanelLength), availableLength / Double(count))
        var result = Array(repeating: 0.0, count: count)
        var flexibleIndices = Array(normalized.indices)
        var remainingLength = availableLength
        var remainingWeight = 1.0

        while !flexibleIndices.isEmpty {
            guard remainingWeight > 0 else {
                let equalLength = remainingLength / Double(flexibleIndices.count)
                flexibleIndices.forEach { result[$0] = equalLength }
                break
            }

            let undersized = flexibleIndices.filter {
                remainingLength * normalized[$0] / remainingWeight < minimum
            }
            if undersized.isEmpty {
                flexibleIndices.forEach {
                    result[$0] = remainingLength * normalized[$0] / remainingWeight
                }
                break
            }

            let undersizedSet = Set(undersized)
            undersized.forEach {
                result[$0] = minimum
                remainingLength -= minimum
                remainingWeight -= normalized[$0]
            }
            flexibleIndices.removeAll { undersizedSet.contains($0) }
        }

        return result
    }
}

/// A small adapter that keeps comparison UI independent of the tab manager's
/// concrete session type.
@MainActor
struct ComparisonDocument: Identifiable {
    let id: UUID
    let title: String
    let workspace: PDFWorkspaceState
    let workspaceID: UUID?
    let workspaceTitle: String?
    /// One-based position in its workspace, including any home tabs.
    let tabIndex: Int?
    let groupTitle: String?

    init(id: UUID, title: String? = nil, workspace: PDFWorkspaceState,
         workspaceID: UUID? = nil, workspaceTitle: String? = nil,
         tabIndex: Int? = nil, groupTitle: String? = nil) {
        self.id = id
        self.workspace = workspace
        self.title = title ?? workspace.displayName
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.tabIndex = tabIndex
        self.groupTitle = groupTitle
    }

    var pageCount: Int { workspace.pageCount }
    var isDirty: Bool { workspace.isDirty }

    /// Comparison candidates include clean tabs whose PDFKit document was
    /// released by the memory manager. Recreate that document immediately
    /// before the panel is displayed; otherwise `PDFKitViewer` would receive
    /// `nil` and render an empty pane even though the tab still has a URL.
    @discardableResult
    func prepareForDisplay() -> Bool {
        workspace.resumeIfNeeded()
    }
}
