// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

final class PDFComparisonDragSessionTests: XCTestCase {
    func testOnlyTheActiveGestureAndSourceCanCommit() {
        let source = UUID(), other = UUID(), gesture = UUID()
        var session = PDFComparisonDragSession()

        XCTAssertFalse(session.canCommit(sessionID: gesture, sourceID: source))
        XCTAssertTrue(session.update(sessionID: gesture, sourceID: source))
        // Repeated pointer updates retain one physical gesture's identity.
        XCTAssertTrue(session.update(sessionID: gesture, sourceID: source))
        XCTAssertEqual(session.id, gesture)
        XCTAssertEqual(session.sourceID, source)
        XCTAssertTrue(session.canCommit(sessionID: gesture, sourceID: source))
        XCTAssertFalse(session.canCommit(sessionID: UUID(), sourceID: source))
        XCTAssertFalse(session.canCommit(sessionID: gesture, sourceID: other))
    }

    func testEscapeRejectsLatePointerUpdatesAndMouseUpEvenAfterRepeatedCleanup() {
        let source = UUID(), gesture = UUID()
        var session = PDFComparisonDragSession()
        XCTAssertTrue(session.update(sessionID: gesture, sourceID: source))

        session.cancel()
        // Escape also turns off arrangement mode, whose observer clears again.
        session.cancel()
        XCTAssertNil(session.id)
        XCTAssertNil(session.sourceID)
        XCTAssertFalse(session.update(sessionID: gesture, sourceID: source))
        XCTAssertFalse(session.canCommit(sessionID: gesture, sourceID: source))
        XCTAssertNil(session.id)
        XCTAssertNil(session.sourceID)
    }

    func testNewDragAfterCancellationCanArrangeWithoutAcceptingTheOldMouseUp() {
        let documents = (0..<4).map { _ in UUID() }
        let cancelledGesture = UUID(), newGesture = UUID()
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: documents)
        configuration.applyGridPreset()
        configuration.toggleLock(documents[0])
        let beforeCancelledDrop = configuration
        var session = PDFComparisonDragSession()

        XCTAssertTrue(session.update(sessionID: cancelledGesture, sourceID: documents[0]))
        session.cancel()
        if session.canCommit(sessionID: cancelledGesture, sourceID: documents[0]) {
            configuration.placeDocument(documents[0], relativeTo: documents[3], placement: .below)
        }
        XCTAssertEqual(configuration, beforeCancelledDrop)

        XCTAssertTrue(session.update(sessionID: newGesture, sourceID: documents[2]))
        XCTAssertFalse(session.canCommit(sessionID: cancelledGesture, sourceID: documents[0]))
        XCTAssertFalse(session.update(sessionID: cancelledGesture, sourceID: documents[0]))
        XCTAssertEqual(session.id, newGesture)
        XCTAssertEqual(session.sourceID, documents[2])
        XCTAssertTrue(session.canCommit(sessionID: newGesture, sourceID: documents[2]))
        if session.canCommit(sessionID: newGesture, sourceID: documents[2]) {
            configuration.placeDocument(documents[2], relativeTo: documents[0], placement: .below)
        }
        session.cancel()

        XCTAssertNotEqual(configuration.effectiveSplitTree, beforeCancelledDrop.effectiveSplitTree)
        XCTAssertEqual(Set(configuration.selectedDocumentIDs), Set(documents))
        XCTAssertEqual(configuration.selectedDocumentIDs.count, documents.count)
        XCTAssertTrue(configuration.isLocked(documents[0]))
        XCTAssertFalse(session.canCommit(sessionID: newGesture, sourceID: documents[2]))
    }
}
