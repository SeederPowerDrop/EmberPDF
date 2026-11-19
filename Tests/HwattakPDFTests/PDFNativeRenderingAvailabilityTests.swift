// SPDX-License-Identifier: MPL-2.0

import AppKit
import IOSurface
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFNativeRenderingAvailabilityTests: XCTestCase {
    func testDeniedAllocationDoesNotAttemptToLockOrUnlock() {
        var locks = 0, unlocks = 0
        let result = PDFNativeRenderingAvailability.probe(createSurface: { nil },
            lockSurface: { _ in locks += 1; return 0 },
            unlockSurface: { _ in unlocks += 1; return 0 })
        XCTAssertEqual(result, .unavailable(.allocation))
        XCTAssertEqual(locks, 0)
        XCTAssertEqual(unlocks, 0)
    }

    @MainActor
    func testUnavailableGraphicsDoesNotConstructAnyPDFView() {
        var constructionCount = 0
        let view = PDFNativeViewFactory.makeView(availability: .unavailable(.allocation)) {
            constructionCount += 1
            return PDFView(frame: .zero)
        }
        XCTAssertEqual(constructionCount, 0)
        XCTAssertTrue(view is PDFNativeRenderingUnavailableView)
        XCTAssertFalse(containsPDFView(view))
        let label = view.subviews.compactMap { $0 as? NSTextField }.first
        XCTAssertFalse(label?.stringValue.isEmpty ?? true)
    }

    @MainActor
    func testAvailableGraphicsReturnsTheOriginalNativeViewWithoutWrapping() {
        let original = NSView(frame: CGRect(x: 0, y: 0, width: 520, height: 720))
        var constructionCount = 0
        let result = PDFNativeViewFactory.makeView(availability: .available) {
            constructionCount += 1
            return original
        }
        XCTAssertEqual(constructionCount, 1)
        XCTAssertTrue(result === original)
        XCTAssertEqual(result.frame, original.frame)
    }

    @MainActor
    private func containsPDFView(_ view: NSView) -> Bool {
        view is PDFView || view.subviews.contains { containsPDFView($0) }
    }
}
