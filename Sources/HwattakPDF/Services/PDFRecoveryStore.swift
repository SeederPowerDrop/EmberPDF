// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// Immutable PDF generations plus an atomically replaced small manifest.
/// A failed/interrupted snapshot never replaces the user's original document.
struct PDFRecoveryStore: Sendable {
    static let enabledKey = "recovery.automatic.enabled"
    static let maximumSnapshotBytes = 256 * 1_024 * 1_024
    let directory: URL
    /// Dependency seam for deterministic staging/lifecycle tests. Production
    /// passes nil and immediately writes on the serial recovery worker.
    private let beforeStaging: (@Sendable () -> Void)?

    struct PreparedGeneration: Sendable {
        let id: UUID
        let fileName: String
        let displayName: String
        let pageCount: Int
        let directory: URL
        var url: URL { directory.appendingPathComponent(fileName) }
    }

    struct Record: Codable, Identifiable {
        let id: UUID
        let fileName: String
        let displayName: String
        let updatedAt: Date
        let pageCount: Int
    }

    init(directory: URL? = nil, beforeStaging: (@Sendable () -> Void)? = nil) {
        self.beforeStaging = beforeStaging
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HwattakPDF/Recovery", isDirectory: true)
    }

    func records() -> [Record] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 65_536,
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  url.deletingPathExtension().lastPathComponent == record.id.uuidString,
                  record.fileName == URL(fileURLWithPath: record.fileName).lastPathComponent,
                  record.fileName.hasSuffix(".pdf"),
                  UUID(uuidString: String(record.fileName.dropLast(4))) != nil,
                  record.pageCount > 0,
                  FileManager.default.fileExists(atPath: pdfURL(for: record).path) else { return nil }
            return record
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func pdfURL(for record: Record) -> URL { directory.appendingPathComponent(record.fileName) }

    func makeWorkingCopy(of record: Record) throws -> URL {
        let folder = directory.appendingPathComponent("Working", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let copy = folder.appendingPathComponent("Recovered.pdf")
        do {
            try FileManager.default.copyItem(at: pdfURL(for: record), to: copy)
            return copy
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func isWorkingCopy(_ url: URL) -> Bool {
        url.lastPathComponent == "Recovered.pdf"
            && UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) != nil
            && url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                == directory.appendingPathComponent("Working").standardizedFileURL
    }

    func removeWorkingCopy(at url: URL) {
        guard isWorkingCopy(url) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Legacy synchronous entry point used by explicit maintenance/tests.
    /// Automatic recovery exclusively uses the detached background path.
    @MainActor
    func save(document: PDFDocument, id: UUID, displayName: String) throws {
        let prepared = try prepareGeneration(document: document, id: id, displayName: displayName)
        defer { discard(prepared) }
        try publish(prepared)
    }

    /// Serializes only the worker's detached snapshot. No manifest is visible
    /// until its owner validates the revision and publishes on the main actor.
    func prepareGeneration(document: PDFDocument, id: UUID, displayName: String) throws -> PreparedGeneration {
        guard !document.isEncrypted, document.pageCount > 0 else { throw WorkspaceError.noDocument }
        beforeStaging?()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let prepared = PreparedGeneration(id: id, fileName: "\(UUID().uuidString).pdf",
            displayName: String(displayName.prefix(512)), pageCount: document.pageCount, directory: directory)
        var completed = false
        defer { if !completed { discard(prepared) } }
        try AtomicPDFWriter.write(document, to: prepared.url, validateStagedPDF: { url, _ in
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= Self.maximumSnapshotBytes else {
                throw WorkspaceError.operationFailed(L10n.string("recovery.limit"))
            }
        }, allowDirectOverwriteFallback: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: prepared.url.path)
        completed = true
        return prepared
    }

    @MainActor
    func publish(_ prepared: PreparedGeneration) throws {
        guard prepared.directory.standardizedFileURL == directory.standardizedFileURL,
              prepared.fileName == URL(fileURLWithPath: prepared.fileName).lastPathComponent,
              UUID(uuidString: String(prepared.fileName.dropLast(4))) != nil,
              prepared.fileName.hasSuffix(".pdf"), prepared.pageCount > 0,
              let size = try prepared.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maximumSnapshotBytes else {
            throw WorkspaceError.operationFailed(L10n.string("recovery.limit"))
        }
        let existing = records()
        let previous = existing.first { $0.id == prepared.id }
        guard previous != nil || existing.count < 32 else {
            throw WorkspaceError.operationFailed(L10n.string("recovery.limit"))
        }
        let retainedBytes = existing.reduce(Int64(0)) { total, record in
            total + Int64((try? pdfURL(for: record).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let replacedBytes = previous.flatMap { try? pdfURL(for: $0).resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        guard retainedBytes - Int64(replacedBytes) + Int64(size) <= 1_024 * 1_024 * 1_024 else {
            throw WorkspaceError.operationFailed(L10n.string("recovery.limit"))
        }
        let record = Record(id: prepared.id, fileName: prepared.fileName, displayName: prepared.displayName,
            updatedAt: Date(), pageCount: prepared.pageCount)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("\(prepared.id).json"), options: .atomic)
        if let previous, previous.fileName != prepared.fileName {
            try? FileManager.default.removeItem(at: pdfURL(for: previous))
        }
    }

    /// Called after cancellation or stale completion; a published generation
    /// is retained. A late worker therefore cannot remove a newer checkpoint.
    func discard(_ prepared: PreparedGeneration) {
        guard prepared.directory.standardizedFileURL == directory.standardizedFileURL,
              prepared.fileName == URL(fileURLWithPath: prepared.fileName).lastPathComponent,
              prepared.fileName.hasSuffix(".pdf"),
              UUID(uuidString: String(prepared.fileName.dropLast(4))) != nil,
              !records().contains(where: { $0.fileName == prepared.fileName }) else { return }
        try? FileManager.default.removeItem(at: prepared.url)
    }

    func remove(id: UUID) {
        guard let record = records().first(where: { $0.id == id }) else { return }
        // Remove the manifest first; an interrupted cleanup leaves only an orphan.
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
            try? FileManager.default.removeItem(at: pdfURL(for: record))
        } catch { /* A cleanup error must not compromise the saved original. */ }
    }
}
