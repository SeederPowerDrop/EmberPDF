// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

final class PDFComparisonSplitTests: XCTestCase {
    func testLegacyWeightsProduceAStableEquivalentTreeWithoutMutatingConfiguration() throws {
        let ids = (0..<3).map { _ in UUID() }
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: ids)
        configuration.restorePersistedPanelWeights(
            sideBySide: [ids[0]: 2, ids[1]: 1, ids[2]: 1],
            stacked: [ids[0]: 1, ids[1]: 1, ids[2]: 2]
        )
        let first = try XCTUnwrap(configuration.effectiveSplitTree)
        XCTAssertEqual(first, configuration.effectiveSplitTree)
        XCTAssertNil(configuration.splitTree)
        XCTAssertEqual(first.documentIDs, ids)
        XCTAssertEqual(try split(first).fraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try split(split(first).second).fraction, 0.5, accuracy: 0.0001)

        configuration.applyPreset(.stacked)
        XCTAssertEqual(try split(XCTUnwrap(configuration.effectiveSplitTree)).fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(configuration.panelFractions(for: .sideBySide), [0.5, 0.25, 0.25])
    }

    func testPlacementMakesIndependentMixedDirectionGroupsOfOnlyTheSelectedPDFs() throws {
        let ids = (0..<5).map { _ in UUID() }
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: Array(ids.prefix(4)))
        configuration.placeDocument(ids[2], relativeTo: ids[0], placement: .below)
        configuration.placeDocument(ids[3], relativeTo: ids[1], placement: .right)

        let tree = try XCTUnwrap(configuration.effectiveSplitTree)
        XCTAssertEqual(tree.documentIDs, [ids[0], ids[2], ids[1], ids[3]])
        XCTAssertEqual(configuration.selectedDocumentIDs, tree.documentIDs)
        let left = try split(split(tree).first)
        let right = try split(split(tree).second)
        XCTAssertEqual(left.axis, .stacked)
        XCTAssertEqual(left.first, .document(ids[0]))
        XCTAssertEqual(left.second, .document(ids[2]))
        XCTAssertEqual(right.axis, .sideBySide)
        XCTAssertEqual(right.first, .document(ids[1]))
        XCTAssertEqual(right.second, .document(ids[3]))
        let snapshot = configuration
        configuration.placeDocument(ids[4], relativeTo: ids[0], placement: .left)
        configuration.placeDocument(ids[0], relativeTo: ids[0], placement: .left)
        XCTAssertEqual(configuration, snapshot)
    }

    func testTwoNonAdjacentSelectedDocumentsCanBeStackedIndependentlyOfOtherOpenTabs() throws {
        let ids = (0..<4).map { _ in UUID() }
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: [ids[0], ids[3]])
        configuration.applyPreset(.stacked)
        let tree = try XCTUnwrap(configuration.effectiveSplitTree)
        XCTAssertEqual(tree.documentIDs, [ids[0], ids[3]])
        XCTAssertEqual(try split(tree).axis, .stacked)
        XCTAssertEqual(try split(tree).fraction, 0.5)
    }

    func testResizeAndAxisChangeAffectOnlyTheAddressedDivider() throws {
        let ids = (0..<4).map { _ in UUID() }
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: ids)
        configuration.applyGridPreset()
        let initial = try split(XCTUnwrap(configuration.effectiveSplitTree))
        let first = try split(initial.first)
        configuration.setSplitFraction(first.id, fraction: 0.73)
        configuration.setSplitAxis(first.id, axis: .stacked)
        let changed = try split(XCTUnwrap(configuration.effectiveSplitTree))
        XCTAssertEqual(changed.id, initial.id)
        XCTAssertEqual(changed.axis, initial.axis)
        XCTAssertEqual(changed.fraction, initial.fraction)
        XCTAssertEqual(changed.second, initial.second)
        XCTAssertEqual(try split(changed.first).fraction, 0.73)
        XCTAssertEqual(try split(changed.first).axis, .stacked)
        let snapshot = configuration
        configuration.setSplitFraction(first.id, fraction: .nan)
        XCTAssertEqual(configuration, snapshot)
        configuration.setSplitFraction(first.id, fraction: 4)
        XCTAssertEqual(try split(split(XCTUnwrap(configuration.effectiveSplitTree)).first).fraction,
                       PDFComparisonSplit.maximumFraction)
    }

    func testSwapKeepsGeometryAndLocksWithTheirDocumentIdentity() throws {
        let ids = (0..<4).map { _ in UUID() }
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: ids, lockedDocumentIDs: [ids[0]])
        configuration.applyGridPreset()
        let root = try split(XCTUnwrap(configuration.effectiveSplitTree))
        configuration.setSplitFraction(root.id, fraction: 0.63)
        configuration.swapDocuments(ids[0], with: ids[3])
        let changed = try split(XCTUnwrap(configuration.effectiveSplitTree))
        XCTAssertEqual(changed.id, root.id)
        XCTAssertEqual(changed.axis, root.axis)
        XCTAssertEqual(changed.fraction, 0.63)
        XCTAssertEqual(configuration.selectedDocumentIDs, [ids[3], ids[1], ids[2], ids[0]])
        XCTAssertEqual(configuration.lockedDocumentIDs, [ids[0]])
    }

    func testClosingAndAddingATabPreservesRemainingBranchesWithoutDuplicatePanes() throws {
        let ids = (0..<5).map { _ in UUID() }
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: Array(ids.prefix(4)),
                                                        lockedDocumentIDs: [ids[3]])
        configuration.applyGridPreset()
        let root = try split(XCTUnwrap(configuration.effectiveSplitTree))
        configuration.normalize(availableDocumentIDs: Set(ids.prefix(3)))
        let tree = try split(XCTUnwrap(configuration.effectiveSplitTree))
        XCTAssertEqual(tree.first, root.first)
        XCTAssertEqual(tree.second, .document(ids[2]))
        XCTAssertEqual(configuration.lockedDocumentIDs, [])
        configuration.toggleSelection(ids[4])
        XCTAssertEqual(configuration.effectiveSplitTree?.documentIDs, [ids[0], ids[1], ids[2], ids[4]])
        configuration.toggleSelection(ids[3])
        XCTAssertEqual(configuration.effectiveSplitTree?.documentIDs.count, 4)
    }

    func testLegacyReorderButtonsAlsoReorderCustomLayoutLeaves() throws {
        let ids = (0..<4).map { _ in UUID() }
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: ids)
        configuration.applyGridPreset()
        let oldRoot = try split(XCTUnwrap(configuration.effectiveSplitTree))
        configuration.moveSelection(ids[3], before: ids[0])
        XCTAssertEqual(configuration.effectiveSplitTree?.documentIDs, [ids[3], ids[0], ids[1], ids[2]])
        configuration.moveSelection(ids[1], by: -1)
        XCTAssertEqual(configuration.effectiveSplitTree?.documentIDs, configuration.selectedDocumentIDs)
        XCTAssertEqual(try split(XCTUnwrap(configuration.effectiveSplitTree)).id, oldRoot.id)
    }

    func testNormalizationRepairsInvalidFractionsDuplicateLeavesAndNodeIdentities() throws {
        let ids = (0..<5).map { _ in UUID() }
        let malformed = PDFComparisonSplit.split(
            id: ids[0], axis: .sideBySide, fraction: .nan,
            first: .split(id: ids[0], axis: .stacked, fraction: 5,
                          first: .document(ids[0]), second: .document(ids[1])),
            second: .split(id: ids[0], axis: .stacked, fraction: -2,
                           first: .document(ids[0]), second: .document(ids[4]))
        )
        let repaired = try XCTUnwrap(malformed.normalized(selectedDocumentIDs: Array(ids.prefix(4)), fallbackAxis: .stacked))
        XCTAssertEqual(repaired.documentIDs, Array(ids.prefix(4)))
        XCTAssertEqual(Set(allNodeIDs(repaired)).count, 7)
        XCTAssertEqual(allNodeIDs(repaired).count, 7)
        XCTAssertTrue(allFractions(repaired).allSatisfy { $0.isFinite && $0 > 0 && $0 < 1 })
        XCTAssertEqual(repaired, malformed.normalized(selectedDocumentIDs: Array(ids.prefix(4)), fallbackAxis: .stacked))
    }

    func testExcessivelyDeepRuntimeLayoutIsBoundedAndRestoresAllSelectedDocuments() throws {
        let ids = (0..<4).map { _ in UUID() }
        var tree = PDFComparisonSplit.document(ids[0])
        for _ in 0..<100 {
            tree = .split(id: UUID(), axis: .stacked, fraction: 0.5,
                          first: tree, second: .document(UUID()))
        }
        let repaired = try XCTUnwrap(tree.normalized(selectedDocumentIDs: ids, fallbackAxis: .sideBySide))
        XCTAssertEqual(repaired.documentIDs, ids)
        XCTAssertEqual(allNodeIDs(repaired).count, 7)
    }

    func testNestedLayoutRoundTripsThroughComparisonRecordAndNormalizesClosedTabs() throws {
        let ids = (0..<4).map { _ in UUID() }
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: ids)
        configuration.applyGridPreset()
        let root = try split(XCTUnwrap(configuration.effectiveSplitTree))
        configuration.setSplitFraction(root.id, fraction: 0.64)
        configuration.setSplitAxis(try split(root.second).id, axis: .stacked)
        let record = record(ids: ids, tree: configuration.splitTree)
        let decoded = try JSONDecoder().decode(WorkspaceSessionArchive.ComparisonRecord.self,
                                              from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
        let normalized = try XCTUnwrap(decoded.normalized(validDocumentIDs: Set(ids.prefix(3))))
        XCTAssertEqual(normalized.splitTree?.documentIDs, Array(ids.prefix(3)))
        XCTAssertEqual(try split(XCTUnwrap(normalized.splitTree)).fraction, 0.64)
    }

    func testLegacyRecordWithoutTreeDecodesAsTheOriginalFlatLayout() throws {
        let ids = [UUID(), UUID()]
        var json = try encodedRecordObject(record(ids: ids, tree: nil))
        json.removeValue(forKey: "splitTree")
        let decoded = try decodeRecord(json)
        XCTAssertNil(decoded.splitTree)
        XCTAssertEqual(decoded.selectedDocumentIDs, ids)
    }

    func testMalformedOptionalLayoutCannotPreventUnrelatedTabsFromRestoring() throws {
        let ids = [UUID(), UUID()]
        var json = try encodedRecordObject(record(ids: ids, tree: nil))
        for value: Any in ["corrupted", ["kind": "unexpected"], ["kind": "document", "documentID": "bad-uuid"]] {
            json["splitTree"] = value
            let decoded = try decodeRecord(json)
            XCTAssertNil(decoded.splitTree)
            XCTAssertEqual(decoded.selectedDocumentIDs, ids)
            XCTAssertTrue(decoded.isComparing)
        }
        var deep: [String: Any] = ["kind": "document", "documentID": ids[0].uuidString]
        for _ in 0..<40 {
            deep = ["kind": "split", "id": UUID().uuidString, "axis": "stacked", "fraction": 0.5,
                    "first": deep, "second": ["kind": "document", "documentID": ids[1].uuidString]]
        }
        json["splitTree"] = deep
        let decoded = try decodeRecord(json)
        XCTAssertNil(decoded.splitTree)
        XCTAssertEqual(decoded.selectedDocumentIDs, ids)
    }

    func testUnknownAxisAndMalformedFractionRecoverWithoutLosingValidDocuments() throws {
        let ids = [UUID(), UUID()]
        var json = try encodedRecordObject(record(ids: ids, tree: nil))
        json["splitTree"] = ["kind": "split", "axis": "diagonal", "fraction": "invalid",
                             "first": ["kind": "document", "documentID": ids[0].uuidString],
                             "second": ["kind": "document", "documentID": ids[1].uuidString]]
        let decoded = try decodeRecord(json)
        let tree = try XCTUnwrap(decoded.splitTree)
        XCTAssertEqual(tree.documentIDs, ids)
        XCTAssertEqual(try split(tree).axis, .sideBySide)
        XCTAssertEqual(try split(tree).fraction, 0.5)
    }

    func testEqualizeMakesThreeAndFourFlatPanelsEqualWithoutChangingTheirOrderOrDirection() throws {
        for count in [3, 4] {
            for axis in PDFComparisonLayout.allCases {
                let ids = (0..<count).map { _ in UUID() }
                var configuration = PDFComparisonConfiguration(selectedDocumentIDs: ids, layout: axis)
                let original = try XCTUnwrap(configuration.effectiveSplitTree)
                configuration.setSplitFraction(original.id, fraction: 0.8)
                configuration.resetSplitFractions()
                let equalized = try XCTUnwrap(configuration.effectiveSplitTree)
                XCTAssertEqual(equalized.documentIDs, ids)
                XCTAssertEqual(allNodeIDs(equalized), allNodeIDs(original))
                XCTAssertEqual(try split(equalized).axis, axis)
                for area in documentAreaFractions(equalized).values {
                    XCTAssertEqual(area, 1 / Double(count), accuracy: 0.000_001)
                }
                XCTAssertEqual(try split(equalized).fraction, 1 / Double(count), accuracy: 0.000_001)
            }
        }
    }

    func testEqualizeMixedGroupsBalancesDocumentAreaAndPreservesTheExistingHierarchy() throws {
        let ids = (0..<4).map { _ in UUID() }
        let deepID = UUID(), groupID = UUID(), rootID = UUID()
        let original = PDFComparisonSplit.split(
            id: rootID, axis: .sideBySide, fraction: 0.7, first: .document(ids[0]),
            second: .split(
                id: groupID, axis: .stacked, fraction: 0.8, first: .document(ids[1]),
                second: .split(id: deepID, axis: .sideBySide, fraction: 0.2,
                               first: .document(ids[2]), second: .document(ids[3]))
            )
        )
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: ids, splitTree: original)
        configuration.resetSplitFractions()
        let equalized = try XCTUnwrap(configuration.effectiveSplitTree)
        let root = try split(equalized)
        let group = try split(root.second)
        let deep = try split(group.second)
        XCTAssertEqual(allNodeIDs(equalized), allNodeIDs(original))
        XCTAssertEqual(equalized.documentIDs, ids)
        XCTAssertEqual(root.axis, .sideBySide)
        XCTAssertEqual(group.axis, .stacked)
        XCTAssertEqual(deep.axis, .sideBySide)
        XCTAssertEqual(root.fraction, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(group.fraction, 1 / 3, accuracy: 0.000_001)
        XCTAssertEqual(deep.fraction, 0.5, accuracy: 0.000_001)
        for area in documentAreaFractions(equalized).values {
            XCTAssertEqual(area, 0.25, accuracy: 0.000_001)
        }
    }

    private func documentAreaFractions(_ tree: PDFComparisonSplit, area: Double = 1) -> [UUID: Double] {
        switch tree {
        case .document(let id): return [id: area]
        case .split(_, _, let fraction, let first, let second):
            return documentAreaFractions(first, area: area * fraction).merging(
                documentAreaFractions(second, area: area * (1 - fraction)),
                uniquingKeysWith: +
            )
        }
    }

    private func split(_ tree: PDFComparisonSplit) throws -> (
        id: UUID, axis: PDFComparisonLayout, fraction: Double,
        first: PDFComparisonSplit, second: PDFComparisonSplit
    ) {
        guard case .split(let id, let axis, let fraction, let first, let second) = tree else {
            XCTFail("Expected a split branch.")
            throw NSError(domain: "ComparisonSplitTests", code: 1)
        }
        return (id, axis, fraction, first, second)
    }

    private func allNodeIDs(_ tree: PDFComparisonSplit) -> [UUID] {
        switch tree {
        case .document(let id): return [id]
        case .split(let id, _, _, let first, let second): return [id] + allNodeIDs(first) + allNodeIDs(second)
        }
    }

    private func allFractions(_ tree: PDFComparisonSplit) -> [Double] {
        switch tree {
        case .document: return []
        case .split(_, _, let fraction, let first, let second):
            return [fraction] + allFractions(first) + allFractions(second)
        }
    }

    private func record(ids: [UUID], tree: PDFComparisonSplit?) -> WorkspaceSessionArchive.ComparisonRecord {
        .init(windowID: nil, workspaceID: UUID(), isComparing: true, selectedDocumentIDs: ids,
              layout: "sideBySide", syncEnabled: true, lockedDocumentIDs: [],
              sideBySideWeights: [], stackedWeights: [], splitTree: tree)
    }

    private func encodedRecordObject(_ record: WorkspaceSessionArchive.ComparisonRecord) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    }

    private func decodeRecord(_ value: [String: Any]) throws -> WorkspaceSessionArchive.ComparisonRecord {
        try JSONDecoder().decode(WorkspaceSessionArchive.ComparisonRecord.self,
                                 from: JSONSerialization.data(withJSONObject: value))
    }
}
