// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Darwin
import Foundation

/// Markdown access belongs to the host, never to a manifest. Callers supply only
/// URLs explicitly chosen in a native file panel and keep their sandbox grant.
enum PluginNotesFileStore {
    static let maximumFileBytes = 1_024 * 1_024

    struct Version: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let digest: Data
    }

    struct LoadedNote {
        let text: String
        let version: Version
    }

    enum Failure: LocalizedError {
        case invalidPath, unsupportedFile, tooLarge, invalidText, externallyChanged, linkedFile

        var errorDescription: String? {
            switch self {
            case .invalidPath: return L10n.string("plugins.notes.error.path", defaultValue: "사용자가 선택한 로컬 Markdown 파일만 열 수 있습니다.")
            case .unsupportedFile: return L10n.string("plugins.notes.error.file", defaultValue: "일반 .md 또는 .markdown 파일을 선택하세요. 바로가기와 심볼릭 링크는 열지 않습니다.")
            case .tooLarge: return L10n.string("plugins.notes.error.size", defaultValue: "노트는 UTF-8 기준 1 MB 이하로 저장할 수 있습니다.")
            case .invalidText: return L10n.string("plugins.notes.error.encoding", defaultValue: "UTF-8 형식의 텍스트 파일을 선택하세요.")
            case .externallyChanged: return L10n.string("plugins.notes.error.changed", defaultValue: "다른 앱에서 파일이 변경되었습니다. 내용을 보존하려면 다른 이름으로 저장하세요.")
            case .linkedFile: return L10n.string("plugins.notes.error.linked", defaultValue: "다른 파일과 연결된 파일은 덮어쓰지 않습니다. 다른 이름으로 저장하세요.")
            }
        }
    }

    static func load(from url: URL) throws -> LoadedNote {
        // NSFileCoordinator may open the item before invoking its accessor. A
        // FIFO would block there, before our regular-file check could run.
        // read() uses O_NONBLOCK/O_NOFOLLOW_ANY and fstat before reading bytes.
        let requested = try Location(url)
        guard try read(requested) != nil else { throw posixError(ENOENT) }
        return try coordinate(url: url, writing: false) { coordinatedURL in
            try requested.validateParent()
            let location = try Location(coordinatedURL)
            guard let loaded = try read(location) else { throw posixError(ENOENT) }
            guard var text = String(data: loaded.data, encoding: .utf8), !text.contains("\0") else {
                throw Failure.invalidText
            }
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            return LoadedNote(text: text, version: loaded.version)
        }
    }

    /// The save panel authorizes the current destination, including replacement.
    /// Capture that version before writing; nil means it must remain absent.
    static func version(at url: URL) throws -> Version? {
        // A nonexistent SavePanel destination cannot be coordinated for reading.
        // This bounded snapshot is checked again inside the coordinated write.
        try read(Location(url))?.version
    }

    static func save(
        _ text: String, to url: URL, expectedVersion: Version?,
        beforeCommit: (() throws -> Void)? = nil
    ) throws -> Version {
        let data = Data(text.utf8)
        guard data.count <= maximumFileBytes else { throw Failure.tooLarge }
        guard !text.contains("\0") else { throw Failure.invalidText }
        let requested = try Location(url)
        // Reject nonregular existing destinations before coordination too.
        // The authoritative checks remain inside the coordinated transaction.
        try validateDestination(requested, expectedVersion: expectedVersion)
        return try coordinate(url: url, writing: true, replacing: expectedVersion != nil) { coordinatedURL in
            try requested.validateParent()
            let location = try Location(coordinatedURL)
            try validateDestination(location, expectedVersion: expectedVersion)

            // SavePanel grants the selected file, not arbitrary siblings or the
            // contents of its ancestors. Ask the OS for an authorized staging
            // directory on this volume; never fall back to truncating the note.
            let fileManager = FileManager.default
            // For a missing URL, FileManager may first create an empty target
            // while locating the volume. Base a new note on the existing parent
            // instead so only the final exclusive rename creates the target.
            let stagingReference = expectedVersion == nil
                ? coordinatedURL.deletingLastPathComponent() : coordinatedURL
            let replacementDirectory = try fileManager.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: stagingReference, create: true
            )
            defer { try? fileManager.removeItem(at: replacementDirectory) }
            let staged = try Location(replacementDirectory.appendingPathComponent("note.md"))
            try stage(data, at: staged)
            // This hook lets tests model another editor replacing the target
            // while the completed staging file is waiting to be committed.
            try beforeCommit?()
            try location.validateParent()
            try validateDestination(location, expectedVersion: expectedVersion)
            if expectedVersion == nil {
                // An uncoordinated creator after the version check must still
                // win. RENAME_EXCL commits the complete file or changes nothing.
                guard renamex_np(staged.path, location.path, UInt32(RENAME_EXCL)) == 0 else {
                    if errno == EEXIST { throw Failure.externallyChanged }
                    throw posixError()
                }
            } else {
                // Foundation's replacement API uses the system-provided staging
                // location and keeps destination metadata. Both items share a
                // volume, and no partial bytes are written into the original.
                _ = try fileManager.replaceItemAt(location.url, withItemAt: staged.url)
            }
            try location.validateParent()
            guard let saved = try read(location), saved.data == data else { throw Failure.externallyChanged }
            return saved.version
        }
    }

    private static func validateDestination(_ location: Location, expectedVersion: Version?) throws {
        let original = try read(location)
        guard original?.version == expectedVersion else { throw Failure.externallyChanged }
        guard original == nil || original?.links == 1 else { throw Failure.linkedFile }
    }

    private static func stage(_ data: Data, at location: Location) throws {
        let descriptor = open(location.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError() }
        guard let checked = try read(location), checked.data == data, checked.links == 1 else {
            throw Failure.externallyChanged
        }
    }

    private static func coordinate<T>(
        url: URL, writing: Bool, replacing: Bool = false, operation: (URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        if writing {
            coordinator.coordinate(
                writingItemAt: url, options: replacing ? .forReplacing : [], error: &coordinationError
            ) { coordinatedURL in result = Result { try operation(coordinatedURL) } }
        } else {
            coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
                result = Result { try operation(coordinatedURL) }
            }
        }
        if let result { return try result.get() }
        if let coordinationError {
            // Match PDFSourceFileAccess: some non-app XCTest hosts cannot reach
            // filecoordinationd. The packaged app always fails closed, while
            // tests exercise exactly the same version-guarded file transaction.
            guard Bundle.main.bundleURL.pathExtension.lowercased() != "app" else { throw coordinationError }
            return try operation(url)
        }
        throw posixError(EIO)
    }

    private struct ReadResult {
        let data: Data
        let version: Version
        let links: UInt16
    }

    private static func read(_ location: Location) throws -> ReadResult? {
        try location.validateParent()
        // O_NOFOLLOW_ANY rejects symlinks in every component without opening
        // ancestors for reading (which would exceed a selected-file grant).
        let descriptor = open(location.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw Failure.unsupportedFile }
            throw posixError()
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw posixError() }
        guard (before.st_mode & S_IFMT) == S_IFREG else { throw Failure.unsupportedFile }
        guard before.st_size >= 0, before.st_size <= maximumFileBytes else { throw Failure.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError() }
            if count == 0 { break }
            guard data.count + count <= maximumFileBytes else { throw Failure.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw posixError() }
        guard metadataMatches(before, after), after.st_size == data.count else { throw Failure.externallyChanged }
        try location.validateParent()
        return ReadResult(
            data: data,
            version: Version(
                device: after.st_dev, inode: after.st_ino, size: after.st_size,
                modifiedSeconds: after.st_mtimespec.tv_sec,
                modifiedNanoseconds: after.st_mtimespec.tv_nsec,
                digest: Data(SHA256.hash(data: data))
            ),
            links: after.st_nlink
        )
    }

    private static func metadataMatches(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    /// A selected-file grant permits path traversal/metadata checks, not reading
    /// the contents of ancestor directories. Resolve legitimate system aliases
    /// (such as /var), retain POSIX canonical bytes, and check parent identity
    /// around each operation. File opens reject any newly introduced symlink.
    private struct Location {
        let url: URL
        let path: String
        let parentPath: String
        let parentDevice: Int32
        let parentInode: UInt64

        init(_ selectedURL: URL) throws {
            guard selectedURL.isFileURL,
                  selectedURL.host == nil || selectedURL.host == "" || selectedURL.host == "localhost",
                  ["md", "markdown"].contains(selectedURL.pathExtension.lowercased()),
                  !selectedURL.path.contains("\0"), !selectedURL.pathComponents.contains("..") else {
                throw Failure.invalidPath
            }
            let filename = selectedURL.lastPathComponent
            guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
                throw Failure.invalidPath
            }
            // Do not standardize the resolved URL again: Foundation can shorten
            // /private/var to /var, reintroducing the system symlink.
            guard let resolved = realpath(selectedURL.deletingLastPathComponent().path, nil) else {
                throw posixError()
            }
            parentPath = String(cString: resolved)
            free(resolved)
            path = (parentPath == "/" ? "" : parentPath) + "/" + filename
            url = URL(fileURLWithPath: path)
            var metadata = stat()
            guard lstat(parentPath, &metadata) == 0 else { throw posixError() }
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else { throw Failure.invalidPath }
            parentDevice = metadata.st_dev
            parentInode = metadata.st_ino
        }

        func validateParent() throws {
            var metadata = stat()
            guard lstat(parentPath, &metadata) == 0 else { throw posixError() }
            guard (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_dev == parentDevice, metadata.st_ino == parentInode else {
                throw Failure.externallyChanged
            }
        }
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
