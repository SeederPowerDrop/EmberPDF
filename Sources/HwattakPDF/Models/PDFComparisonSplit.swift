// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation

/// The edge of a comparison panel at which another PDF will be placed.
enum PDFComparisonPlacement: String, CaseIterable, Identifiable {
    case left, right, above, below

    var id: String { rawValue }
    var axis: PDFComparisonLayout {
        switch self {
        case .left, .right: .sideBySide
        case .above, .below: .stacked
        }
    }
    var isLeading: Bool { self == .left || self == .above }
}

/// An ordered binary split gives each group its own direction and divider.
/// Four leaves need at most three levels; a modest extra archive allowance
/// lets normalization repair stale leaves without accepting unlimited nesting.
indirect enum PDFComparisonSplit: Codable, Equatable, Identifiable {
    case document(UUID)
    case split(id: UUID, axis: PDFComparisonLayout, fraction: Double,
               first: PDFComparisonSplit, second: PDFComparisonSplit)

    static let maximumArchiveDepth = 8
    static let minimumFraction = 0.02
    static let maximumFraction = 0.98

    var id: UUID {
        switch self {
        case .document(let id), .split(let id, _, _, _, _): id
        }
    }

    var documentIDs: [UUID] {
        switch self {
        case .document(let id): [id]
        case .split(_, _, _, let first, let second): first.documentIDs + second.documentIDs
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, documentID, id, axis, fraction, first, second
    }

    init(from decoder: Decoder) throws {
        // Each branch adds exactly one coding key. Count only tree child keys,
        // independently of where a session embeds this value.
        let depth = decoder.codingPath.filter {
            $0.stringValue == CodingKeys.first.rawValue || $0.stringValue == CodingKeys.second.rawValue
        }.count
        guard depth <= Self.maximumArchiveDepth else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Comparison split nesting exceeds the supported limit."
            ))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "document":
            self = .document(try values.decode(UUID.self, forKey: .documentID))
        case "split":
            let first = try values.decode(Self.self, forKey: .first)
            let second = try values.decode(Self.self, forKey: .second)
            let id = (try? values.decode(UUID.self, forKey: .id))
                ?? Self.stableSplitID(documentIDs: first.documentIDs + second.documentIDs)
            let axis = (try? values.decode(PDFComparisonLayout.self, forKey: .axis)) ?? .sideBySide
            let fraction = (try? values.decode(Double.self, forKey: .fraction)) ?? 0.5
            self = .split(id: id, axis: axis, fraction: Self.sanitizedFraction(fraction),
                          first: first, second: second)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values,
                                                  debugDescription: "Unknown comparison split node.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .document(let id):
            try values.encode("document", forKey: .kind)
            try values.encode(id, forKey: .documentID)
        case .split(let id, let axis, let fraction, let first, let second):
            try values.encode("split", forKey: .kind)
            try values.encode(id, forKey: .id)
            try values.encode(axis, forKey: .axis)
            try values.encode(Self.sanitizedFraction(fraction), forKey: .fraction)
            try values.encode(first, forKey: .first)
            try values.encode(second, forKey: .second)
        }
    }

    /// Removes stale/duplicate documents and collapses empty branches. Missing
    /// selected documents are appended, so an archived layout cannot hide a tab.
    func normalized(selectedDocumentIDs: [UUID], fallbackAxis: PDFComparisonLayout) -> Self? {
        let selected = Self.boundedDocumentIDs(selectedDocumentIDs)
        let allowed = Set(selected)
        var seenDocuments = Set<UUID>()
        var seenNodes = allowed
        func visit(_ node: Self, depth: Int) -> Self? {
            guard depth <= Self.maximumArchiveDepth else { return nil }
            switch node {
            case .document(let id):
                guard allowed.contains(id), seenDocuments.insert(id).inserted else { return nil }
                return .document(id)
            case .split(let id, let axis, let fraction, let first, let second):
                let first = visit(first, depth: depth + 1)
                let second = visit(second, depth: depth + 1)
                guard let first else { return second }
                guard let second else { return first }
                var uniqueID = id
                if !seenNodes.insert(uniqueID).inserted {
                    var salt = 0
                    repeat {
                        uniqueID = Self.stableSplitID(
                            documentIDs: first.documentIDs + second.documentIDs, salt: salt
                        )
                        salt += 1
                    } while !seenNodes.insert(uniqueID).inserted
                }
                return .split(id: uniqueID, axis: axis, fraction: Self.sanitizedFraction(fraction),
                              first: first, second: second)
            }
        }
        var result = visit(self, depth: 0)
        for id in selected where !seenDocuments.contains(id) {
            if let first = result {
                var salt = 0
                var splitID: UUID
                repeat {
                    splitID = Self.stableSplitID(documentIDs: first.documentIDs + [id], salt: salt)
                    salt += 1
                } while !seenNodes.insert(splitID).inserted
                result = .split(id: splitID,
                                axis: fallbackAxis,
                                fraction: Double(first.documentIDs.count) / Double(first.documentIDs.count + 1),
                                first: first, second: .document(id))
            } else {
                result = .document(id)
            }
        }
        return result
    }

    static func boundedDocumentIDs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        var result: [UUID] = []
        for id in ids where seen.insert(id).inserted {
            result.append(id)
            if result.count == PDFComparisonConfiguration.maximumDocumentCount { break }
        }
        return result
    }

    static func sanitizedFraction(_ fraction: Double) -> Double {
        fraction.isFinite ? min(max(fraction, minimumFraction), maximumFraction) : 0.5
    }

    /// Stable synthetic IDs prevent a legacy flat layout from rebuilding all
    /// PDF viewers on each SwiftUI evaluation before the first divider edit.
    static func stableSplitID(documentIDs: [UUID], salt: Int = 0) -> UUID {
        let input = "EmberPDF.comparison.split.\(salt):" + documentIDs.map(\.uuidString).joined(separator: ":")
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    fileprivate static func flat(ids: [UUID], axis: PDFComparisonLayout, weights: [Double]) -> Self? {
        guard let firstID = ids.first else { return nil }
        guard ids.count > 1 else { return .document(firstID) }
        let total = weights.reduce(0, +)
        let fraction = total.isFinite && total > 0 ? weights[0] / total : 1 / Double(ids.count)
        let remainder = Self.flat(ids: Array(ids.dropFirst()), axis: axis, weights: Array(weights.dropFirst()))!
        return .split(id: stableSplitID(documentIDs: ids), axis: axis,
                      fraction: sanitizedFraction(fraction), first: .document(firstID), second: remainder)
    }

    fileprivate func removing(_ documentID: UUID) -> Self? {
        switch self {
        case .document(let id): return id == documentID ? nil : self
        case .split(let id, let axis, let fraction, let first, let second):
            let first = first.removing(documentID), second = second.removing(documentID)
            guard let first else { return second }
            guard let second else { return first }
            return .split(id: id, axis: axis, fraction: fraction, first: first, second: second)
        }
    }

    fileprivate func replacingDocuments(_ transform: (UUID) -> Self) -> Self {
        switch self {
        case .document(let id): return transform(id)
        case .split(let id, let axis, let fraction, let first, let second):
            return .split(id: id, axis: axis, fraction: fraction,
                          first: first.replacingDocuments(transform), second: second.replacingDocuments(transform))
        }
    }

    func replacingDocument(_ documentID: UUID, with replacementID: UUID) -> Self {
        replacingDocuments { .document($0 == documentID ? replacementID : $0) }
    }

    /// Each PDF receives the same share of the available area. A flat chain
    /// must divide 1:3, then 1:2, then 1:1 for four documents; setting every
    /// divider to one half would progressively shrink the later panels.
    fileprivate func equalizingFractions() -> Self {
        switch self {
        case .document: return self
        case .split(let id, let axis, _, let first, let second):
            let firstCount = first.documentIDs.count
            let totalCount = firstCount + second.documentIDs.count
            return .split(id: id, axis: axis,
                          fraction: Double(firstCount) / Double(totalCount),
                          first: first.equalizingFractions(), second: second.equalizingFractions())
        }
    }

    fileprivate func updatingSplits(_ transform: (UUID, PDFComparisonLayout, Double) -> (PDFComparisonLayout, Double)) -> Self {
        switch self {
        case .document: return self
        case .split(let id, let axis, let fraction, let first, let second):
            let (axis, fraction) = transform(id, axis, fraction)
            return .split(id: id, axis: axis, fraction: Self.sanitizedFraction(fraction),
                          first: first.updatingSplits(transform), second: second.updatingSplits(transform))
        }
    }
}

extension PDFComparisonConfiguration {
    var effectiveSplitTree: PDFComparisonSplit? {
        let ids = PDFComparisonSplit.boundedDocumentIDs(selectedDocumentIDs)
        if let splitTree {
            return splitTree.normalized(selectedDocumentIDs: ids, fallbackAxis: layout)
        }
        // Read the old independent width/height weights without changing them.
        let weights = persistedPanelWeights(for: layout)
        let valid = weights.values.filter { $0.isFinite && $0 > 0 }
        let fallback = valid.isEmpty ? 1 : valid.reduce(0, +) / Double(valid.count)
        return PDFComparisonSplit.flat(ids: ids, axis: layout, weights: ids.map {
            guard let value = weights[$0], value.isFinite, value > 0 else { return fallback }
            return value
        })
    }

    mutating func applyPreset(_ layout: PDFComparisonLayout) {
        self.layout = layout
        splitTree = nil
    }

    mutating func applyGridPreset() {
        let ids = PDFComparisonSplit.boundedDocumentIDs(selectedDocumentIDs)
        guard ids.count > 2 else { applyPreset(.sideBySide); return }
        let leading = Array(ids.prefix(2)), trailing = Array(ids.dropFirst(2))
        let first = PDFComparisonSplit.flat(ids: leading, axis: .sideBySide, weights: leading.map { _ in 1 })!
        let second = PDFComparisonSplit.flat(ids: trailing, axis: .sideBySide, weights: trailing.map { _ in 1 })!
        layout = .stacked
        splitTree = .split(id: PDFComparisonSplit.stableSplitID(documentIDs: ids), axis: .stacked,
                           fraction: 0.5, first: first, second: second)
    }

    mutating func placeDocument(_ id: UUID, relativeTo targetID: UUID, placement: PDFComparisonPlacement) {
        guard id != targetID, isSelected(id), isSelected(targetID),
              let remaining = effectiveSplitTree?.removing(id) else { return }
        let first: PDFComparisonSplit = .document(placement.isLeading ? id : targetID)
        let second: PDFComparisonSplit = .document(placement.isLeading ? targetID : id)
        let replacement = PDFComparisonSplit.split(
            id: UUID(), axis: placement.axis, fraction: 0.5, first: first, second: second
        )
        splitTree = remaining.replacingDocuments { $0 == targetID ? replacement : .document($0) }
        selectedDocumentIDs = splitTree!.documentIDs
    }

    mutating func swapDocuments(_ id: UUID, with targetID: UUID) {
        guard id != targetID, isSelected(id), isSelected(targetID), let tree = effectiveSplitTree else { return }
        splitTree = tree.replacingDocuments {
            .document($0 == id ? targetID : ($0 == targetID ? id : $0))
        }
        selectedDocumentIDs = splitTree!.documentIDs
    }

    mutating func setSplitAxis(_ id: UUID, axis: PDFComparisonLayout) {
        splitTree = effectiveSplitTree?.updatingSplits { currentID, currentAxis, fraction in
            (currentID == id ? axis : currentAxis, fraction)
        }
    }

    mutating func setSplitFraction(_ id: UUID, fraction: Double) {
        guard fraction.isFinite else { return }
        splitTree = effectiveSplitTree?.updatingSplits { currentID, axis, currentFraction in
            (axis, currentID == id ? fraction : currentFraction)
        }
    }

    mutating func resetSplitFractions() {
        splitTree = effectiveSplitTree?.equalizingFractions()
    }

    mutating func normalizeSplitTree() {
        guard let splitTree else { return }
        self.splitTree = splitTree.normalized(selectedDocumentIDs: selectedDocumentIDs, fallbackAxis: layout)
    }

    /// Existing before/after buttons keep the custom geometry while replacing
    /// leaf identities, instead of silently ignoring a reordered tab list.
    mutating func reorderSplitTree(from oldOrder: [UUID]) {
        guard let splitTree, oldOrder.count == selectedDocumentIDs.count else { return }
        let mapping = Dictionary(zip(oldOrder, selectedDocumentIDs), uniquingKeysWith: { first, _ in first })
        self.splitTree = splitTree.replacingDocuments { .document(mapping[$0] ?? $0) }
    }
}
