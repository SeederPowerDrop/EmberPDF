// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

final class OCRRecognitionGateTests: XCTestCase {
    func testOnlyOneOperationRunsAndQueuedRequestsEnterInFIFOOrder() async throws {
        let gate = OCRRecognitionGate()
        let activity = Activity()
        let firstRelease = Latch()
        let secondRelease = Latch()
        let first = Task {
            try await gate.withPermit {
                await activity.enter(1)
                await firstRelease.wait()
                await activity.leave()
                return "first-file"
            }
        }
        try await waitUntil { await activity.entered == [1] }
        let second = Task {
            try await gate.withPermit {
                await activity.enter(2)
                await secondRelease.wait()
                await activity.leave()
                return "second-checkpoint"
            }
        }
        try await waitUntil { await gate.state.queuedRequestCount == 1 }
        let third = Task {
            try await gate.withPermit {
                await activity.enter(3)
                await activity.leave()
                return "third-callback"
            }
        }
        try await waitUntil { await gate.state.queuedRequestCount == 2 }
        let whileQueued = await activity.entered
        XCTAssertEqual(whileQueued, [1], "Queued operations must not begin preparing their own PDF/Vision work.")
        await firstRelease.open()
        try await waitUntil { await activity.entered == [1, 2] }
        let remaining = await gate.state.queuedRequestCount
        XCTAssertEqual(remaining, 1)
        await secondRelease.open()
        let firstValue = try await first.value
        let secondValue = try await second.value
        let thirdValue = try await third.value
        XCTAssertEqual([firstValue, secondValue, thirdValue], ["first-file", "second-checkpoint", "third-callback"])
        let entered = await activity.entered
        let maximum = await activity.maximumActive
        let state = await gate.state
        XCTAssertEqual(entered, [1, 2, 3])
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(state, .init(isOccupied: false, queuedRequestCount: 0))
    }

    func testCancellingQueuedRequestRemovesItWithoutRunningItsOperation() async throws {
        let gate = OCRRecognitionGate()
        let activity = Activity()
        let firstRelease = Latch()
        let first = Task {
            try await gate.withPermit {
                await activity.enter(1)
                await firstRelease.wait()
                await activity.leave()
            }
        }
        try await waitUntil { await activity.entered == [1] }
        let cancelled = Task {
            try await gate.withPermit {
                await activity.enter(2)
                await activity.leave()
            }
        }
        try await waitUntil { await gate.state.queuedRequestCount == 1 }
        cancelled.cancel()
        try await waitUntil { await gate.state.queuedRequestCount == 0 }
        let cancelledResult = await cancelled.result
        assertCancellation(cancelledResult)
        let held = await gate.state
        let entered = await activity.entered
        XCTAssertTrue(held.isOccupied, "Removing a waiter must not release the current worker.")
        XCTAssertEqual(entered, [1])
        await firstRelease.open()
        try await first.value
        let final = await gate.state
        XCTAssertFalse(final.isOccupied)
    }

    func testAlreadyCancelledRequestDoesNotOccupyGateOrRunOperation() async throws {
        let gate = OCRRecognitionGate()
        let activity = Activity()
        let begin = Latch()
        let cancelled = Task {
            await begin.wait()
            try await gate.withPermit {
                await activity.enter(1)
                await activity.leave()
            }
        }
        cancelled.cancel()
        await begin.open()
        assertCancellation(await cancelled.result)
        let entered = await activity.entered
        let state = await gate.state
        XCTAssertTrue(entered.isEmpty)
        XCTAssertEqual(state, .init(isOccupied: false, queuedRequestCount: 0))
    }

    func testCancelledNativeWorkerKeepsPermitUntilItActuallyFinishes() async throws {
        let gate = OCRRecognitionGate()
        let activity = Activity()
        let nativeRelease = Latch()
        let first = Task {
            try await gate.withPermit {
                let worker = Task.detached {
                    await activity.enter(1)
                    // Models a native synchronous call: cancelling its Task
                    // cannot finish it until the underlying call returns.
                    await nativeRelease.wait()
                    await activity.leave()
                    try Task.checkCancellation()
                }
                return try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
            }
        }
        try await waitUntil { await activity.entered == [1] }
        let second = Task {
            try await gate.withPermit {
                await activity.enter(2)
                await activity.leave()
                return 2
            }
        }
        try await waitUntil { await gate.state.queuedRequestCount == 1 }
        first.cancel()
        // A cancelled caller can suspend here without blocking any thread.
        // The second worker must remain queued until nativeRelease opens.
        for _ in 0..<12 { await Task.yield() }
        let duringCancellation = await gate.state
        let enteredBeforeCompletion = await activity.entered
        XCTAssertEqual(duringCancellation, .init(isOccupied: true, queuedRequestCount: 1))
        XCTAssertEqual(enteredBeforeCompletion, [1])
        await nativeRelease.open()
        assertCancellation(await first.result)
        let secondValue = try await second.value
        let maximum = await activity.maximumActive
        XCTAssertEqual(secondValue, 2)
        XCTAssertEqual(maximum, 1)
    }

    func testThrowingOperationReturnsPermitForNextRequest() async throws {
        let gate = OCRRecognitionGate()
        do {
            let _: Int = try await gate.withPermit { throw ExpectedFailure.operation }
            XCTFail("The operation error must reach its own caller.")
        } catch ExpectedFailure.operation {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let result = try await gate.withPermit { 42 }
        let state = await gate.state
        XCTAssertEqual(result, 42)
        XCTAssertEqual(state, .init(isOccupied: false, queuedRequestCount: 0))
    }

    func testCancellationDuringPermitHandoffDoesNotLeakOrOverlapWorkers() async throws {
        for iteration in 0..<40 {
            let gate = OCRRecognitionGate()
            let activity = Activity()
            let release = Latch()
            let first = Task {
                try await gate.withPermit {
                    await activity.enter(1)
                    await release.wait()
                    await activity.leave()
                }
            }
            try await waitUntil { await activity.entered == [1] }
            let racing = Task {
                try await gate.withPermit {
                    await activity.enter(2)
                    await Task.yield()
                    await activity.leave()
                    try Task.checkCancellation()
                }
            }
            try await waitUntil { await gate.state.queuedRequestCount == 1 }
            // Cover both orders. Actor scheduling can deliver cancellation
            // before removal, during grant, or after the resumed task starts.
            if iteration.isMultiple(of: 2) {
                racing.cancel()
                await release.open()
            } else {
                await release.open()
                racing.cancel()
            }
            try await first.value
            switch await racing.result {
            case .success: break // Completion may legitimately win the race.
            case .failure(let error): XCTAssertTrue(error is CancellationError)
            }
            let next = try await gate.withPermit {
                await activity.enter(3)
                await activity.leave()
                return 3
            }
            let maximum = await activity.maximumActive
            let state = await gate.state
            XCTAssertEqual(next, 3)
            XCTAssertEqual(maximum, 1, "iteration \(iteration)")
            XCTAssertEqual(state, .init(isOccupied: false, queuedRequestCount: 0), "iteration \(iteration)")
        }
    }

    private enum ExpectedFailure: Error { case operation, timeout }

    private func assertCancellation<Value>(_ result: Result<Value, Error>, file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success: XCTFail("Expected cancellation", file: file, line: line)
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for a deterministic gate transition.")
        throw ExpectedFailure.timeout
    }

    private actor Activity {
        private(set) var entered: [Int] = []
        private var active = 0
        private(set) var maximumActive = 0

        func enter(_ id: Int) {
            entered.append(id)
            active += 1
            maximumActive = max(maximumActive, active)
        }

        func leave() { active -= 1 }
    }

    private actor Latch {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
}
