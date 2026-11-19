// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit
import XCTest
@testable import HwattakPDF

final class WorkspaceChangeCoalescingTests: XCTestCase {
    @MainActor
    func testOpeningPDFDeliversOneWindowRefreshWithCompleteDocumentState() async throws {
        let url = try makePDF()
        let collection = MultiDocumentWorkspaceState()
        let documentWorkspace = try XCTUnwrap(collection.activeWorkspace)
        var documentChanges = 0
        var windowChanges = 0
        var observedURLs: [URL?] = []
        var observedPageCounts: [Int] = []
        let delivered = expectation(description: "opened document delivered")
        let extraDelivery = expectation(description: "no redundant window refresh")
        extraDelivery.isInverted = true
        let documentObserver = documentWorkspace.objectWillChange.sink {
            documentChanges += 1
        }
        let windowObserver = collection.objectWillChange.sink {
            windowChanges += 1
            observedURLs.append(documentWorkspace.documentURL)
            observedPageCounts.append(documentWorkspace.pageCount)
            if windowChanges == 1 { delivered.fulfill() }
            if windowChanges == 2 { extraDelivery.fulfill() }
        }
        defer {
            documentObserver.cancel()
            windowObserver.cancel()
        }

        XCTAssertTrue(documentWorkspace.open(url: url))
        XCTAssertGreaterThan(documentChanges, 10,
                             "Exercise the real multi-property opening transaction.")
        XCTAssertEqual(windowChanges, 0,
                       "Window observers must see the finished transaction, not partial state.")
        await fulfillment(of: [delivered], timeout: 1)
        await fulfillment(of: [extraDelivery], timeout: 0.05)

        XCTAssertEqual(windowChanges, 1)
        XCTAssertEqual(observedURLs, [url])
        XCTAssertEqual(observedPageCounts, [1])
        print("Workspace open notifications: document=\(documentChanges), window=\(windowChanges)")
    }

    @MainActor
    func testChangesAcrossTabsCoalesceAndLaterChangesStillArrive() async throws {
        let collection = MultiDocumentWorkspaceState()
        _ = collection.newTab()
        _ = collection.newTab()
        let states = collection.tabs.map(\.workspace)
        // Structural tab changes can commit the outgoing tab. Drain that
        // earlier transaction before observing the independent edit bursts.
        try await Task.sleep(for: .milliseconds(50))
        var observedStatuses: [[String]] = []
        let firstDelivery = expectation(description: "first edit burst")
        let secondDelivery = expectation(description: "later edit burst")
        let extraDelivery = expectation(description: "only one refresh per burst")
        extraDelivery.isInverted = true
        let observer = collection.objectWillChange.sink {
            observedStatuses.append(states.map(\.statusMessage))
            switch observedStatuses.count {
            case 1: firstDelivery.fulfill()
            case 2: secondDelivery.fulfill()
            case 3: extraDelivery.fulfill()
            default: break
            }
        }
        defer { observer.cancel() }

        for state in states {
            for index in 0..<100 { state.statusMessage = "first-\(index)" }
        }
        await fulfillment(of: [firstDelivery], timeout: 1)
        XCTAssertEqual(observedStatuses, [Array(repeating: "first-99", count: 3)])

        for state in states {
            for index in 0..<100 { state.statusMessage = "second-\(index)" }
        }
        await fulfillment(of: [secondDelivery], timeout: 1)
        await fulfillment(of: [extraDelivery], timeout: 0.05)

        XCTAssertEqual(observedStatuses, [
            Array(repeating: "first-99", count: 3),
            Array(repeating: "second-99", count: 3)
        ])
    }

    @MainActor
    func testChangeMadeDuringDeliverySchedulesAnotherRefresh() async throws {
        let collection = MultiDocumentWorkspaceState()
        let state = try XCTUnwrap(collection.activeWorkspace)
        var observedStatuses: [String] = []
        let delivered = expectation(description: "observer-triggered change delivered")
        let extraDelivery = expectation(description: "no duplicate observer-triggered change")
        extraDelivery.isInverted = true
        let observer = collection.objectWillChange.sink {
            observedStatuses.append(state.statusMessage)
            switch observedStatuses.count {
            case 1: state.statusMessage = "changed during delivery"
            case 2: delivered.fulfill()
            case 3: extraDelivery.fulfill()
            default: break
            }
        }
        defer { observer.cancel() }

        state.statusMessage = "first transaction"
        await fulfillment(of: [delivered], timeout: 1)
        await fulfillment(of: [extraDelivery], timeout: 0.05)

        XCTAssertEqual(observedStatuses, ["first transaction", "changed during delivery"])
    }

    @MainActor
    private func makePDF() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceChangeCoalescing-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("one-page.pdf")
        let image = NSImage(size: NSSize(width: 120, height: 180), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(document.write(to: url))
        return url
    }
}
