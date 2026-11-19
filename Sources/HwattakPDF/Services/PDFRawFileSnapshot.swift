// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

/// Worker-only immutable input for large native PDFs. APFS cloning avoids a
/// second whole-file allocation. An unlinked, read-only descriptor survives
/// replacement of the original URL without rebinding an older native graph.
final class PDFRawFileSnapshot {
    static let maximumFileBytes: UInt64 = 1_024 * 1_024 * 1_024
    private static let maximumRetainedBytes: UInt64 = 2 * maximumFileBytes
    private static let reserveLock = NSLock()
    private static var retainedBytes: UInt64 = 0
    private static var retainedCount = 0
    private let reservation: Reservation
    private(set) var descriptor: Int32
    let byteCount: Int

    private init(descriptor: Int32, bytes: Int, reservation: Reservation) {
        self.descriptor = descriptor; byteCount = bytes; self.reservation = reservation
    }
    deinit { closeDescriptor() }
    /// QPDF owns its successful duplicate; retain only the budget reservation.
    func closeDescriptor() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }

    private final class Reservation {
        let bytes: UInt64
        init?(_ bytes: UInt64) {
            reserveLock.lock(); defer { reserveLock.unlock() }
            guard bytes > 0, bytes <= maximumFileBytes, retainedCount < 4,
                  bytes <= maximumRetainedBytes - retainedBytes else { return nil }
            self.bytes = bytes; retainedBytes += bytes; retainedCount += 1
        }
        deinit {
            reserveLock.lock(); defer { reserveLock.unlock() }
            retainedBytes -= bytes; retainedCount -= 1
        }
    }
    private enum Refusal: Error { case unavailable }

    /// Unsupported clone/volume/space falls back to the existing writer.
    /// Cancellation and changed source versions must abort this save instead.
    static func create(url: URL, expected: PDFSourceFileVersion) throws -> PDFRawFileSnapshot? {
        try PDFSaveCancellation.checkCurrent()
        guard !Thread.isMainThread, let reservation = Reservation(expected.fileSize) else { return nil }
        do {
            guard try PDFSourceFileVersion.capture(at: url) == expected else {
                throw WorkspaceError.externalModification(url)
            }
            let source = Darwin.open(expected.canonicalURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard source >= 0 else { throw Refusal.unavailable }
            defer { Darwin.close(source) }
            var before = stat()
            guard fstat(source, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_size > 0, UInt64(before.st_size) == expected.fileSize,
                  expected.fileSystemNumber == UInt64(before.st_dev),
                  expected.fileSystemNodeNumber == UInt64(before.st_ino),
                  try PDFSourceFileVersion.capture(at: url) == expected else {
                throw WorkspaceError.externalModification(url)
            }
            let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("EmberPDF-raw-snapshot-" + UUID().uuidString, isDirectory: true)
            let disk = try FileManager.default.attributesOfFileSystem(forPath: directory.deletingLastPathComponent().path)
            guard let available = (disk[.systemFreeSize] as? NSNumber)?.uint64Value,
                  available > expected.fileSize + 2 * maximumFileBytes else { return nil }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directoryFD >= 0 else { throw Refusal.unavailable }
            defer { Darwin.close(directoryFD) }
            var directoryStat = stat()
            guard fstat(directoryFD, &directoryStat) == 0,
                  directoryStat.st_uid == geteuid(), (directoryStat.st_mode & 0o7777) == 0o700 else {
                throw Refusal.unavailable
            }
            try PDFSaveCancellation.checkCurrent()
            let cloned = fclonefileat(source, directoryFD, "source.pdf", UInt32(CLONE_NOOWNERCOPY))
            var after = stat()
            guard fstat(source, &after) == 0, sameVersion(before, after),
                  try PDFSourceFileVersion.capture(at: url) == expected else {
                throw WorkspaceError.externalModification(url)
            }
            guard cloned == 0 else { return nil }
            try PDFSaveCancellation.checkCurrent()
            let frozen = openat(directoryFD, "source.pdf", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard frozen >= 0 else { throw Refusal.unavailable }
            var transferred = false
            defer { if !transferred { Darwin.close(frozen) } }
            var copy = stat()
            guard fchmod(frozen, 0o600) == 0, fstat(frozen, &copy) == 0,
                  (copy.st_mode & S_IFMT) == S_IFREG, copy.st_uid == geteuid(),
                  (copy.st_mode & 0o7777) == 0o600, copy.st_nlink == 1,
                  copy.st_size == before.st_size,
                  !(copy.st_dev == before.st_dev && copy.st_ino == before.st_ino),
                  unlinkat(directoryFD, "source.pdf", 0) == 0,
                  fstat(frozen, &copy) == 0, copy.st_nlink == 0 else { throw Refusal.unavailable }
            try PDFSaveCancellation.checkCurrent()
            transferred = true
            return PDFRawFileSnapshot(descriptor: frozen, bytes: Int(expected.fileSize), reservation: reservation)
        } catch is CancellationError { throw CancellationError() }
        catch let error as WorkspaceError { throw error }
        catch { return nil }
    }

    private static func sameVersion(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
            && a.st_mode == b.st_mode && a.st_uid == b.st_uid
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
            && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
            && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
