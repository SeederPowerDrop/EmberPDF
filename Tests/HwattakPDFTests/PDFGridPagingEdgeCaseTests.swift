// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import HwattakPDF

final class PDFGridPagingEdgeCaseTests: XCTestCase {
    func testAllDirectionPreferenceIsSharedWithTheMainPDFCanvas() {
        XCTAssertEqual(
            PDFGridPagingDirection(rawValue: PDFPageNavigationMode.allDirectionsPaging.rawValue),
            .allDirections
        )
    }

    func testEveryArrowTurnsTheVisibleGroupInAllGridSizes() {
        for groupSize in 3...12 {
            for (keyCode, expectedStep): (UInt16, Int) in [
                (123, -1), (126, -1), (124, 1), (125, 1)
            ] {
                let step = PDFGridPagingDirection.allDirections.keyboardPageStep(
                    keyCode: keyCode,
                    requestedPageCount: groupSize
                )
                XCTAssertEqual(step, expectedStep)
                XCTAssertEqual(
                    PDFPageNavigationMode.targetPage(
                        from: groupSize + 1,
                        pageCount: groupSize * 3,
                        pagesPerTurn: groupSize,
                        step: step ?? 0
                    ),
                    expectedStep < 0 ? 0 : groupSize * 2
                )
            }
        }
    }

    func testAllDirectionGridPagingStopsAtDocumentEndsIncludingPartialGroup() {
        for groupSize in 3...12 {
            let count = groupSize * 2 + 1
            for previousKey: UInt16 in [123, 126] {
                let step = PDFGridPagingDirection.allDirections.keyboardPageStep(
                    keyCode: previousKey, requestedPageCount: groupSize
                )
                XCTAssertNil(PDFPageNavigationMode.targetPage(
                    from: 0, pageCount: count, pagesPerTurn: groupSize, step: step ?? 0
                ))
                XCTAssertEqual(PDFPageNavigationMode.targetPage(
                    from: count - 1, pageCount: count, pagesPerTurn: groupSize, step: step ?? 0
                ), groupSize)
            }
            for nextKey: UInt16 in [124, 125] {
                let step = PDFGridPagingDirection.allDirections.keyboardPageStep(
                    keyCode: nextKey, requestedPageCount: groupSize
                )
                XCTAssertEqual(PDFPageNavigationMode.targetPage(
                    from: groupSize, pageCount: count, pagesPerTurn: groupSize, step: step ?? 0
                ), count - 1)
                XCTAssertNil(PDFPageNavigationMode.targetPage(
                    from: count - 1, pageCount: count, pagesPerTurn: groupSize, step: step ?? 0
                ))
            }
        }
    }

    func testExistingGridModesKeepTheirArrowAxisAndNonFourPageBehavior() {
        XCTAssertEqual(PDFGridPagingDirection.vertical.keyboardPageStep(keyCode: 126, requestedPageCount: 4), -1)
        XCTAssertEqual(PDFGridPagingDirection.vertical.keyboardPageStep(keyCode: 125, requestedPageCount: 4), 1)
        XCTAssertNil(PDFGridPagingDirection.vertical.keyboardPageStep(keyCode: 123, requestedPageCount: 4))
        XCTAssertNil(PDFGridPagingDirection.vertical.keyboardPageStep(keyCode: 124, requestedPageCount: 4))
        XCTAssertEqual(PDFGridPagingDirection.horizontal.keyboardPageStep(keyCode: 123, requestedPageCount: 4), -1)
        XCTAssertEqual(PDFGridPagingDirection.horizontal.keyboardPageStep(keyCode: 124, requestedPageCount: 4), 1)
        XCTAssertNil(PDFGridPagingDirection.horizontal.keyboardPageStep(keyCode: 125, requestedPageCount: 4))
        XCTAssertNil(PDFGridPagingDirection.horizontal.keyboardPageStep(keyCode: 126, requestedPageCount: 4))

        for mode: PDFGridPagingDirection in [.vertical, .horizontal] {
            for groupSize in (3...12).filter({ $0 != 4 }) {
                for keyCode: UInt16 in [123, 124, 125, 126, 116, 121] {
                    XCTAssertNil(mode.keyboardPageStep(keyCode: keyCode, requestedPageCount: groupSize))
                }
            }
        }
    }

    func testPageUpDownRemainGroupShortcutsWithoutConsumingReturnOrOtherKeys() {
        for mode in PDFGridPagingDirection.allCases {
            XCTAssertEqual(mode.keyboardPageStep(keyCode: 116, requestedPageCount: 4), -1)
            XCTAssertEqual(mode.keyboardPageStep(keyCode: 121, requestedPageCount: 4), 1)
            for keyCode: UInt16 in [36, 48, 49, 51, 53, 0] {
                XCTAssertNil(mode.keyboardPageStep(keyCode: keyCode, requestedPageCount: 4))
            }
        }
        for invalidGroupSize in [0, 1, 2, 13] {
            XCTAssertNil(PDFGridPagingDirection.allDirections.keyboardPageStep(
                keyCode: 125, requestedPageCount: invalidGroupSize
            ))
        }
    }

    func testGroupsNormalizeEveryDocumentBoundaryToFourPageStarts() {
        let expectations: [(pageCount: Int, pageIndex: Int, start: Int, slots: [Int?])] = [
            (1, 0, 0, [0, nil, nil, nil]),
            (3, 2, 0, [0, 1, 2, nil]),
            (4, 3, 0, [0, 1, 2, 3]),
            (5, 4, 4, [4, nil, nil, nil]),
            (7, 6, 4, [4, 5, 6, nil]),
            (8, 7, 4, [4, 5, 6, 7]),
            (259, 258, 256, [256, 257, 258, nil])
        ]

        for expectation in expectations {
            let group = PDFGridPageGroup(
                containing: expectation.pageIndex,
                documentPageCount: expectation.pageCount
            )
            XCTAssertEqual(group.startIndex, expectation.start)
            XCTAssertEqual(group.pageSlots, expectation.slots)
        }
    }

    func testGroupNavigationMovesExactlyFourAndStopsAtDocumentEdges() {
        let first = PDFGridPageGroup(startIndex: 0, documentPageCount: 259)
        XCTAssertNil(first.previousStartIndex)
        XCTAssertEqual(first.nextStartIndex, 4)

        let middle = PDFGridPageGroup(startIndex: 132, documentPageCount: 259)
        XCTAssertEqual(middle.previousStartIndex, 128)
        XCTAssertEqual(middle.nextStartIndex, 136)

        let last = PDFGridPageGroup(startIndex: 258, documentPageCount: 259)
        XCTAssertEqual(last.startIndex, 256)
        XCTAssertEqual(last.previousStartIndex, 252)
        XCTAssertNil(last.nextStartIndex)
    }

    func testBothFourPageArrangementsUseTheSameGroupStart() {
        for mode in PDFGridLayoutMode.allCases {
            XCTAssertEqual(mode.navigationTarget(for: 0, requestedPageCount: 4), 0)
            XCTAssertEqual(mode.navigationTarget(for: 3, requestedPageCount: 4), 0)
            XCTAssertEqual(mode.navigationTarget(for: 4, requestedPageCount: 4), 4)
            XCTAssertEqual(mode.navigationTarget(for: 7, requestedPageCount: 4), 4)
        }
    }

    func testMomentumSharesTheSameOnePageLatchAsItsTouchGesture() {
        var session = PDFGridPagingGestureSession()
        session.beginTouchGesture()
        XCTAssertEqual(
            session.consume(primaryDelta: -60, crossAxisDelta: 0),
            1
        )

        session.endTouchGesture()
        session.beginMomentum()
        XCTAssertNil(session.consume(primaryDelta: -200, crossAxisDelta: 0))

        session.endMomentum()
        session.beginTouchGesture()
        XCTAssertEqual(
            session.consume(primaryDelta: 60, crossAxisDelta: 0),
            -1
        )
    }
}
