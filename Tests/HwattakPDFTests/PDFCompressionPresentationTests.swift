// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

final class PDFCompressionPresentationTests: XCTestCase {
    @MainActor
    func testQualityChangeDiscardsPreviousPreviewAndSavingIsExplicit() async {
        let model = PDFCompressionPresentation { data, quality in
            XCTAssertEqual(quality, .highQuality)
            return Self.result(original: data.count, compressed: 40)
        }
        XCTAssertEqual(model.quality, .highQuality)
        XCTAssertFalse(model.canSave)
        model.start(documentData: Data(count: 100))
        await waitUntil { !model.isProcessing }
        XCTAssertEqual(model.result?.compressedBytes, 40)
        XCTAssertTrue(model.canSave)

        model.selectQuality(.small)
        XCTAssertNil(model.result)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isProcessing)
        XCTAssertFalse(model.canSave)
    }

    @MainActor
    func testResultMustBeatOriginalDiskSizeNotJustLargerSnapshot() async {
        let model = PDFCompressionPresentation { data, _ in
            Self.result(original: data.count, compressed: 80)
        }
        model.start(documentData: Data(count: 200), originalBytes: 70)
        await waitUntil { !model.isProcessing }
        XCTAssertTrue(model.result?.didReduce == true)
        XCTAssertFalse(model.canSave, "A PDFKit snapshot can already be larger than the file on disk.")
    }

    @MainActor
    func testNoReductionAndEmptyResultsCannotBeSaved() async {
        for size in [100, 140, 0] {
            let model = PDFCompressionPresentation { data, _ in
                Self.result(original: data.count, compressed: size)
            }
            model.start(documentData: Data(count: 100))
            await waitUntil { !model.isProcessing }
            XCTAssertFalse(model.canSave)
        }
    }

    @MainActor
    func testCancelledNativeOperationCannotRestorePreview() async {
        let gate = ControlledCompressor()
        let model = PDFCompressionPresentation { data, quality in
            try await gate.run(data: data, quality: quality)
        }
        model.start(documentData: Data(count: 100))
        await waitUntil { await gate.requestCount == 1 }
        model.cancel()
        XCTAssertFalse(model.isProcessing)
        await gate.finish(request: 0, result: Self.result(original: 100, compressed: 40))
        await settleTasks()
        XCTAssertNil(model.result)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.canSave)
    }

    @MainActor
    func testOlderPreviewCannotOverwriteNewerQualityResult() async {
        let gate = ControlledCompressor()
        let model = PDFCompressionPresentation { data, quality in
            try await gate.run(data: data, quality: quality)
        }
        model.start(documentData: Data(count: 100))
        await waitUntil { await gate.requestCount == 1 }
        model.selectQuality(.small)
        model.start(documentData: Data(count: 100))
        await waitUntil { await gate.requestCount == 2 }

        await gate.finish(request: 1, result: Self.result(original: 100, compressed: 20))
        await waitUntil { !model.isProcessing }
        XCTAssertTrue(model.canSave)
        await gate.finish(request: 0, result: Self.result(original: 100, compressed: 80))
        await settleTasks()
        XCTAssertEqual(model.quality, .small)
        XCTAssertEqual(model.result?.compressedBytes, 20)
        XCTAssertTrue(model.canSave)
    }

    @MainActor
    func testWorkerFailureDisplaysErrorAndCannotBeSaved() async {
        let model = PDFCompressionPresentation { _, _ in throw FixtureError.failed }
        model.start(documentData: Data(count: 100))
        await waitUntil { !model.isProcessing }
        XCTAssertEqual(model.errorMessage, "Fixture compression failure")
        XCTAssertNil(model.result)
        XCTAssertFalse(model.canSave)
        model.cancel()
        XCTAssertNil(model.errorMessage)
    }

    private static func result(original: Int, compressed: Int) -> PDFCompressionResult {
        PDFCompressionResult(
            data: Data(count: compressed),
            originalBytes: original,
            compressedBytes: compressed,
            didReduce: compressed < original
        )
    }

    @MainActor
    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for compression state", file: file, line: line)
    }

    private func settleTasks() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    private enum FixtureError: LocalizedError {
        case failed
        var errorDescription: String? { "Fixture compression failure" }
    }

    /// Deliberately ignores cancellation to model a native PDF write finishing
    /// after the user has stopped it or selected another quality preset.
    private actor ControlledCompressor {
        private(set) var requestCount = 0
        private var continuations: [Int: CheckedContinuation<PDFCompressionResult, Error>] = [:]

        func run(data: Data, quality: PDFCompressionQuality) async throws -> PDFCompressionResult {
            try await withCheckedThrowingContinuation { continuation in
                let request = requestCount
                requestCount += 1
                continuations[request] = continuation
            }
        }

        func finish(request: Int, result: PDFCompressionResult) {
            continuations.removeValue(forKey: request)?.resume(returning: result)
        }
    }
}
