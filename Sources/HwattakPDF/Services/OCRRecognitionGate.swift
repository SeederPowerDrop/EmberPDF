// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Bounds OCR's PDFKit/Vision workers across workspaces. Waiting suspends the
/// task before it creates a PDFDocument or page bitmap; it never blocks a thread.
/// Each request keeps its own file, checkpoint store, and progress callback.
final class OCRRecognitionGate: Sendable {
    static let shared = OCRRecognitionGate()

    struct State: Equatable, Sendable {
        let isOccupied: Bool
        let queuedRequestCount: Int
    }

    private let admission = Admission()

    var state: State { get async { await admission.state } }

    /// A cancellation request never releases an active permit by itself. The
    /// operation must return or throw first, including waiting for a cancelled
    /// native worker that cannot interrupt its current synchronous operation.
    func withPermit<Value>(_ operation: () async throws -> Value) async throws -> Value {
        let ticket = UUID()
        try await admission.acquire(ticket)
        do {
            // A queued request can be cancelled just as release grants it the
            // permit. Check again after resuming and return that permit below.
            try Task.checkCancellation()
            let result = try await operation()
            await admission.release(ticket)
            return result
        } catch {
            await admission.release(ticket)
            throw error
        }
    }

    private actor Admission {
        private var active: UUID?
        private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

        var state: State {
            State(isOccupied: active != nil, queuedRequestCount: waiters.count)
        }

        func acquire(_ ticket: UUID) async throws {
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if active == nil {
                        active = ticket
                        continuation.resume()
                    } else {
                        waiters.append((ticket, continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancelQueued(ticket) }
            }
        }

        func release(_ ticket: UUID) {
            guard active == ticket else { return }
            active = nil
            guard !waiters.isEmpty else { return }
            let (next, continuation) = waiters.removeFirst()
            active = next
            continuation.resume()
        }

        private func cancelQueued(_ ticket: UUID) {
            guard let index = waiters.firstIndex(where: { $0.0 == ticket }) else { return }
            waiters.remove(at: index).1.resume(throwing: CancellationError())
        }
    }
}
