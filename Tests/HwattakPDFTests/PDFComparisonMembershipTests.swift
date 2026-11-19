// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

final class PDFComparisonMembershipTests: XCTestCase {
    func testAddingADocumentRetainsTheResizedMixedLayoutAndOtherLocks() throws {
        let ids = (0..<4).map { _ in UUID() }
        let branchID = UUID(), rootID = UUID()
        let original = PDFComparisonSplit.split(
            id: rootID, axis: .sideBySide, fraction: 0.62,
            first: .document(ids[0]),
            second: .split(id: branchID, axis: .stacked, fraction: 0.31,
                           first: .document(ids[1]), second: .document(ids[2]))
        )
        var configuration = PDFComparisonConfiguration(
            selectedDocumentIDs: Array(ids.prefix(3)),
            lockedDocumentIDs: [ids[1]], splitTree: original
        )

        XCTAssertTrue(configuration.addDocument(ids[3]))

        let result = try split(XCTUnwrap(configuration.effectiveSplitTree))
        XCTAssertEqual(result.first, original, "Adding a PDF must not reset existing dividers.")
        XCTAssertEqual(result.second, .document(ids[3]))
        XCTAssertEqual(result.fraction, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(configuration.selectedDocumentIDs, ids)
        XCTAssertEqual(configuration.lockedDocumentIDs, [ids[1]])
    }

    func testAddRejectsDuplicateAndFifthPDFWithoutMutatingTheLayout() {
        let ids = (0..<5).map { _ in UUID() }
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: Array(ids.prefix(4)))
        configuration.applyGridPreset()
        let original = configuration

        XCTAssertFalse(configuration.addDocument(ids[0]))
        XCTAssertFalse(configuration.addDocument(ids[4]))
        XCTAssertEqual(configuration, original)
    }

    func testRemovingAPaneCollapsesOnlyItsBranchAndKeepsUnrelatedLocks() throws {
        let ids = (0..<4).map { _ in UUID() }
        var configuration = PDFComparisonConfiguration(
            selectedDocumentIDs: ids, lockedDocumentIDs: [ids[0], ids[3]]
        )
        configuration.applyGridPreset()
        let initial = try split(XCTUnwrap(configuration.effectiveSplitTree))
        configuration.setSplitFraction(initial.id, fraction: 0.67)
        let leftID = try split(initial.first).id
        configuration.setSplitFraction(leftID, fraction: 0.28)
        let resized = try split(XCTUnwrap(configuration.effectiveSplitTree))

        XCTAssertTrue(configuration.removeDocument(ids[3]))

        let result = try split(XCTUnwrap(configuration.effectiveSplitTree))
        XCTAssertEqual(result.id, resized.id)
        XCTAssertEqual(result.axis, resized.axis)
        XCTAssertEqual(result.fraction, resized.fraction)
        XCTAssertEqual(result.first, resized.first)
        XCTAssertEqual(result.second, .document(ids[2]))
        XCTAssertEqual(configuration.selectedDocumentIDs, Array(ids.prefix(3)))
        XCTAssertEqual(configuration.lockedDocumentIDs, [ids[0]])
        XCTAssertFalse(configuration.persistedPanelWeights(for: .sideBySide).keys.contains(ids[3]))
    }

    func testExistingComparisonKeepsItsLastPDFAndCanAcceptAnother() {
        let first = UUID(), second = UUID(), replacement = UUID()
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: [first, second])

        XCTAssertTrue(configuration.removeDocument(first))
        XCTAssertFalse(configuration.canBeginComparison)
        XCTAssertTrue(configuration.canContinueComparison)
        XCTAssertEqual(configuration.effectiveSplitTree, .document(second))

        XCTAssertTrue(configuration.addDocument(replacement))
        XCTAssertEqual(configuration.selectedDocumentIDs, [second, replacement])
        XCTAssertTrue(configuration.canBeginComparison)
        XCTAssertTrue(configuration.canContinueComparison)

        XCTAssertTrue(configuration.removeDocument(second))
        XCTAssertTrue(configuration.removeDocument(replacement))
        XCTAssertFalse(configuration.canContinueComparison)
        XCTAssertNil(configuration.effectiveSplitTree)
        XCTAssertTrue(configuration.selectedDocumentIDs.isEmpty)
        XCTAssertTrue(configuration.lockedDocumentIDs.isEmpty)
    }

    func testReplacementKeepsItsSlotAndBothSizePresetsButStartsUnlocked() throws {
        let ids = (0..<4).map { _ in UUID() }
        let replacement = UUID()
        var configuration = PDFComparisonConfiguration(
            selectedDocumentIDs: ids, lockedDocumentIDs: [ids[0], ids[2]]
        )
        configuration.restorePersistedPanelWeights(
            sideBySide: [ids[0]: 2, ids[1]: 3, ids[2]: 4, ids[3]: 1],
            stacked: [ids[0]: 1, ids[1]: 2, ids[2]: 3, ids[3]: 4]
        )
        let horizontal = configuration.panelFractions(for: .sideBySide)
        let vertical = configuration.panelFractions(for: .stacked)
        configuration.applyGridPreset()
        let root = try split(XCTUnwrap(configuration.effectiveSplitTree))
        configuration.setSplitFraction(root.id, fraction: 0.71)
        let original = try split(XCTUnwrap(configuration.effectiveSplitTree))

        XCTAssertTrue(configuration.replaceDocument(ids[2], with: replacement))

        let result = try split(XCTUnwrap(configuration.effectiveSplitTree))
        XCTAssertEqual(result.id, original.id)
        XCTAssertEqual(result.axis, original.axis)
        XCTAssertEqual(result.fraction, original.fraction)
        XCTAssertEqual(result.first, original.first)
        let oldBranch = try split(original.second), newBranch = try split(result.second)
        XCTAssertEqual(newBranch.id, oldBranch.id)
        XCTAssertEqual(newBranch.axis, oldBranch.axis)
        XCTAssertEqual(newBranch.fraction, oldBranch.fraction)
        XCTAssertEqual(newBranch.first, .document(replacement))
        XCTAssertEqual(newBranch.second, oldBranch.second)
        XCTAssertEqual(configuration.selectedDocumentIDs, [ids[0], ids[1], replacement, ids[3]])
        XCTAssertEqual(configuration.lockedDocumentIDs, [ids[0]])
        XCTAssertEqual(configuration.panelFractions(for: .sideBySide), horizontal)
        XCTAssertEqual(configuration.panelFractions(for: .stacked), vertical)
        XCTAssertFalse(configuration.persistedPanelWeights(for: .sideBySide).keys.contains(ids[2]))
        XCTAssertFalse(configuration.persistedPanelWeights(for: .stacked).keys.contains(ids[2]))
    }

    func testReplacingALegacyFlatPaneKeepsTheWeightedGeometry() throws {
        let ids = (0..<3).map { _ in UUID() }
        let replacement = UUID()
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: ids)
        configuration.restorePersistedPanelWeights(sideBySide: [ids[0]: 2, ids[1]: 1, ids[2]: 1], stacked: [:])
        let original = try split(XCTUnwrap(configuration.effectiveSplitTree))

        XCTAssertTrue(configuration.replaceDocument(ids[0], with: replacement))

        let result = try split(XCTUnwrap(configuration.effectiveSplitTree))
        XCTAssertEqual(result.id, original.id)
        XCTAssertEqual(result.axis, original.axis)
        XCTAssertEqual(result.fraction, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(result.first, .document(replacement))
        XCTAssertEqual(result.second, original.second)
        XCTAssertEqual(configuration.panelFractions(for: .sideBySide), [0.5, 0.25, 0.25])
    }

    func testInvalidRemovalOrReplacementCannotDropOrDuplicateAPDF() {
        let ids = (0..<3).map { _ in UUID() }
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: ids, lockedDocumentIDs: [ids[0]])
        configuration.applyGridPreset()
        let original = configuration

        XCTAssertFalse(configuration.removeDocument(UUID()))
        XCTAssertFalse(configuration.replaceDocument(UUID(), with: UUID()))
        XCTAssertFalse(configuration.replaceDocument(ids[0], with: ids[0]))
        XCTAssertFalse(configuration.replaceDocument(ids[0], with: ids[1]))
        XCTAssertEqual(configuration, original)
    }

    private func split(_ tree: PDFComparisonSplit) throws -> (
        id: UUID, axis: PDFComparisonLayout, fraction: Double,
        first: PDFComparisonSplit, second: PDFComparisonSplit
    ) {
        guard case let .split(id, axis, fraction, first, second) = tree else {
            XCTFail("Expected a split node")
            throw NSError(domain: "PDFComparisonMembershipTests", code: 1)
        }
        return (id, axis, fraction, first, second)
    }
}
