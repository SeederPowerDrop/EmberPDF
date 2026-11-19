// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

/// Flushes a completed staging file before its directory entry replaces the
/// destination. This does not make file-scoped direct overwrite atomic, nor
/// guarantee durability of the later directory-entry change after power loss.
enum PDFSaveDurability {
    static func synchronizeStagedFile(at url: URL) throws {
        try synchronizeStagedFile(at: url, fullSync: fullSync, standardSync: standardSync)
    }

    /// The injected calls exercise volume failures without requiring a mounted
    /// network/FUSE volume or changing the user's file-system configuration.
    static func synchronizeStagedFile(
        at url: URL,
        fullSync: (Int32) throws -> Void,
        standardSync: (Int32) throws -> Void
    ) throws {
        // This is our private sibling staging file, never the user-selected
        // destination. Do not follow an unexpected replacement symlink or let
        // the descriptor leak into a subsequently launched helper process.
        let descriptor = try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileWriteInvalidFileName) }
            let descriptor = Darwin.open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw posixFailure() }
            return descriptor
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0 else { throw posixFailure() }
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
            }
            do {
                try fullSync(handle.fileDescriptor)
            } catch {
                let failure = error as NSError
                guard failure.domain == NSPOSIXErrorDomain,
                      failure.code == Int(ENOTSUP) || failure.code == Int(ENOTTY) else { throw error }
                // Some SMB/FUSE volumes refuse F_FULLFSYNC. A successful plain
                // fsync is the supported fallback; disk/I/O failures still stop.
                try standardSync(handle.fileDescriptor)
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func fullSync(_ descriptor: Int32) throws {
        guard Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 else { throw posixFailure() }
    }

    private static func standardSync(_ descriptor: Int32) throws {
        guard Darwin.fsync(descriptor) == 0 else { throw posixFailure() }
    }

    private static func posixFailure() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
