// SPDX-License-Identifier: MPL-2.0

import Combine
import Foundation

/// Keeps a preview bound to the exact quality choice that produced it.
/// A cancelled native PDF write may finish later, but cannot restore its result.
@MainActor
final class PDFCompressionPresentation: ObservableObject {
    typealias Worker = @Sendable (Data, PDFCompressionQuality) async throws -> PDFCompressionResult

    @Published private(set) var quality: PDFCompressionQuality = .highQuality
    @Published private(set) var isProcessing = false
    @Published private(set) var result: PDFCompressionResult?
    @Published private(set) var errorMessage: String?

    private let worker: Worker
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var originalBytes = 0

    init(worker: @escaping Worker = PDFCompressionPresentation.compressInBackground) {
        self.worker = worker
    }

    deinit { task?.cancel() }

    var canSave: Bool {
        guard !isProcessing, let result else { return false }
        return result.didReduce
            && result.compressedBytes == result.data.count
            && result.compressedBytes < result.originalBytes
            && result.compressedBytes < originalBytes
            && !result.data.isEmpty
    }

    func selectQuality(_ quality: PDFCompressionQuality) {
        guard self.quality != quality else { return }
        cancel()
        self.quality = quality
    }

    func start(documentData: Data, originalBytes: Int? = nil) {
        cancel()
        self.originalBytes = originalBytes ?? documentData.count
        let requestGeneration = generation
        let quality = quality
        let worker = worker
        isProcessing = true
        task = Task { [weak self] in
            do {
                let result = try await worker(documentData, quality)
                try Task.checkCancellation()
                guard let self, self.generation == requestGeneration else { return }
                self.result = result
                self.isProcessing = false
                self.task = nil
            } catch is CancellationError {
                guard let self, self.generation == requestGeneration else { return }
                self.isProcessing = false
                self.task = nil
            } catch {
                guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.isProcessing = false
                self.task = nil
            }
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        isProcessing = false
        result = nil
        errorMessage = nil
    }

    nonisolated private static func compressInBackground(
        data: Data,
        quality: PDFCompressionQuality
    ) async throws -> PDFCompressionResult {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try PDFCompressionService.compress(data: data, quality: quality)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
