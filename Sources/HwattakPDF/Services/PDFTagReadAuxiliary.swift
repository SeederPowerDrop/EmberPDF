// SPDX-License-Identifier: MPL-2.0

import CEmberPDFRawStreams
import CryptoKit
import Darwin
import Foundation
import PDFKit

/// One disposable, verified tag reader. Its owner is retained by the catalog
/// plan until the final native writer finishes; it never supplies painting,
/// Info, ID, document attributes, outlines or document-level Catalog policy.
final class PDFTagReadAuxiliary {
    let originalOwner: CGPDFDocument
    let originalRawSource: PDFRawStreamSource
    let document: CGPDFDocument
    let rawSource: PDFRawStreamSource
    let originalDigest: Data
    private let temporaryDirectory: URL

    private init(input: PDFRawStreamSource.TagReadFileInput, document: CGPDFDocument,
                 rawSource: PDFRawStreamSource, directory: URL) {
        originalOwner = input.owner; originalRawSource = input.rawSource
        originalDigest = input.digest; self.document = document
        self.rawSource = rawSource; temporaryDirectory = directory
    }
    deinit { try? FileManager.default.removeItem(at: temporaryDirectory) }

    func matches(original: CGPDFDocument, raw: PDFRawStreamSource) -> Bool {
        originalOwner === original && originalRawSource === raw
            && document.numberOfPages == original.numberOfPages
    }

    struct Limits {
        let residentBytes: UInt64
        let seconds: TimeInterval
        let outputBytes: UInt64
        static let standard = Limits(residentBytes: 1_024 * 1_024 * 1_024,
                                     seconds: 90, outputBytes: 192 * 1_024 * 1_024)
        var isBounded: Bool {
            residentBytes > 0 && residentBytes <= Self.standard.residentBytes
                && seconds > 0 && seconds <= Self.standard.seconds
                && outputBytes > 0 && outputBytes <= Self.standard.outputBytes
        }
    }
    private enum Refusal: Error { case input, process, receipt, limit, ownership }
    /// No auxiliary is accepted for this outcome. The existing original-source
    /// tag builder may still support the graph under its unchanged limits.
    enum OriginalTagReaderFallback: Error { case unsupportedGraph }
    private static let activeHelper = NSLock()

    /// A miss/cap/refusal retains the ordinary writer. Cancellation propagates
    /// and must never launch the ordinary serialization after it was requested.
    static func create(input: PDFRawStreamSource.TagReadFileInput,
                       helperURL: URL? = nil, limits: Limits = .standard) throws -> PDFTagReadAuxiliary? {
        try withHelperSlot(helperURL: helperURL, limits: limits) { helper, deadline in
            try createLocked(input: input, helper: helper, limits: limits, deadline: deadline)
        }
    }

    static func create(immutableSource raw: PDFRawStreamSource, owner: CGPDFDocument,
                       helperURL: URL? = nil, limits: Limits = .standard) throws -> PDFTagReadAuxiliary? {
        try withHelperSlot(helperURL: helperURL, limits: limits) { helper, deadline in
            // Slot admission precedes any temporary raw-input allocation.
            guard let input = try raw.tagReadImmutableInput(in: owner) else { return nil }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("EmberPDF-tag-input-" + UUID().uuidString, isDirectory: true)
                .resolvingSymlinksInPath()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appendingPathComponent("immutable.pdf")
                let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw Refusal.input }
                defer { Darwin.close(descriptor) }
                try input.bytes.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        try PDFSaveCancellation.checkCurrent()
                        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Refusal.limit }
                        let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), min(64 * 1_024, bytes.count - offset))
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw Refusal.input }; offset += count
                    }
                }
                let identity = try FileIdentity(descriptor)
                guard identity.isOwnedPrivateRegular, identity.size == UInt64(input.bytes.count),
                      let file = input.fileInput(at: url, version: try PDFSourceFileVersion.capture(at: url)) else { throw Refusal.input }
                return try createLocked(input: file, helper: helper, limits: limits, deadline: deadline)
            } catch is CancellationError { throw CancellationError() }
            catch is OriginalTagReaderFallback { throw OriginalTagReaderFallback.unsupportedGraph }
            catch { return nil }
        }
    }

    private static func withHelperSlot(helperURL: URL?, limits: Limits,
        body: (URL, TimeInterval) throws -> PDFTagReadAuxiliary?) throws -> PDFTagReadAuxiliary? {
        try PDFSaveCancellation.checkCurrent()
        guard !Thread.isMainThread, limits.isBounded, let helper = helperURL ?? defaultHelperURL,
              FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + limits.seconds
        while !activeHelper.try() {
            try PDFSaveCancellation.checkCurrent()
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            Thread.sleep(forTimeInterval: min(0.02, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        }
        defer { activeHelper.unlock() }
        try PDFSaveCancellation.checkCurrent()
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return try body(helper, deadline)
    }

    private static func createLocked(input: PDFRawStreamSource.TagReadFileInput,
        helper: URL, limits: Limits, deadline: TimeInterval) throws -> PDFTagReadAuxiliary? {
        guard input.digest.count == 32, input.version.fileSize > 0,
              input.version.fileSize <= 128 * 1_024 * 1_024 else { return nil }
        var directory: URL?
        var published = false, phase = "input-open"
        defer { if !published, let directory { try? FileManager.default.removeItem(at: directory) } }
        do {
            let inputFD = Darwin.open(input.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard inputFD >= 0 else { throw Refusal.input }
            defer { Darwin.close(inputFD) }
            let originalFD = try FileIdentity(inputFD)
            try validateInput(input, descriptor: inputFD, identity: originalFD)
            guard try streamDigest(inputFD, maximum: 128 * 1_024 * 1_024) == input.digest else { throw Refusal.input }
            try validateInput(input, descriptor: inputFD, identity: originalFD)
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("EmberPDF-tag-read-" + UUID().uuidString, isDirectory: true)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            directory = temp
            let output = temp.appendingPathComponent("reader.pdf")
            let outputFD = Darwin.open(output.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard outputFD >= 0 else { throw Refusal.input }
            defer { Darwin.close(outputFD) }
            let empty = try FileIdentity(outputFD)
            guard empty.size == 0, empty.isOwnedPrivateRegular, empty.inode != originalFD.inode || empty.device != originalFD.device else { throw Refusal.input }
            phase = "worker"
            try PDFSaveCancellation.checkCurrent()
            let remainingSeconds = deadline - ProcessInfo.processInfo.systemUptime
            guard remainingSeconds > 0 else { throw Refusal.limit }
            let receipt: Receipt
            do {
                receipt = try run(helper: helper, inputFD: inputFD, outputFD: outputFD,
                    digest: input.digest, limits: Limits(residentBytes: limits.residentBytes,
                        seconds: remainingSeconds, outputBytes: limits.outputBytes))
            } catch is OriginalTagReaderFallback {
                // A semantic refusal supplies no auxiliary, but still chooses
                // another reader. Require the same post-worker input binding
                // as a successful receipt before granting that choice.
                try PDFSaveCancellation.checkCurrent()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw Refusal.limit }
                try validateInput(input, descriptor: inputFD, identity: originalFD)
                guard try streamDigest(inputFD, maximum: 128 * 1_024 * 1_024) == input.digest else { throw Refusal.input }
                try validateInput(input, descriptor: inputFD, identity: originalFD)
                try PDFSaveCancellation.checkCurrent()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw Refusal.limit }
                throw OriginalTagReaderFallback.unsupportedGraph
            }
            phase = "worker-receipt-input-output"
            try PDFSaveCancellation.checkCurrent()
            try validateInput(input, descriptor: inputFD, identity: originalFD)
            guard try streamDigest(inputFD, maximum: 128 * 1_024 * 1_024) == input.digest else { throw Refusal.input }
            let complete = try FileIdentity(outputFD)
            guard empty.sameNode(as: complete), complete.isOwnedPrivateRegular,
                  complete.size > 0, complete.size <= limits.outputBytes,
                  receipt.outputBytes == complete.size,
                  receipt.inputBytes == input.version.fileSize,
                  receipt.pageCount == input.owner.numberOfPages,
                  receipt.inputSHA256 == hex(input.digest),
                  receipt.outputSHA256 == hex(try streamDigest(outputFD, maximum: limits.outputBytes)),
                  receipt.rawTagGraphEquivalent, receipt.tagNodes > 0, receipt.tagNodes <= 16_000_000 else { throw Refusal.receipt }
            phase = "loaded-auxiliary-immutable-digest"
            let outputVersion = try PDFSourceFileVersion.capture(at: output)
            let loaded = try PDFSourceFileAccess.loadDocument(at: output)
            guard !loaded.document.isEncrypted, !loaded.document.isLocked,
                  PDFRawStreamProvenance.hasKnownNativeInput(loaded.document),
                  let native = loaded.document.documentRef,
                  native.numberOfPages == input.owner.numberOfPages,
                  let raw = PDFRawStreamProvenance.source(for: loaded.document),
                  let loadedDigest = try raw.signatureInputDigest(in: native),
                  hex(loadedDigest) == receipt.outputSHA256,
                  try PDFSourceFileVersion.capture(at: output) == outputVersion,
                  try FileIdentity(outputFD) == complete else { throw Refusal.receipt }
            try validateInput(input, descriptor: inputFD, identity: originalFD)
            try PDFSaveCancellation.checkCurrent()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Refusal.limit }
            let result = PDFTagReadAuxiliary(input: input, document: native, rawSource: raw, directory: temp)
            published = true
            return result
        } catch is CancellationError { throw CancellationError() }
        catch is OriginalTagReaderFallback { throw OriginalTagReaderFallback.unsupportedGraph }
        catch {
            #if DEBUG
            if ProcessInfo.processInfo.environment["EMBER_NATIVE_STAGING_TRACE"] == "1" {
                FileHandle.standardError.write(Data("tag-read-auxiliary-refused phase=\(phase) error=\(String(describing: error))\n".utf8))
            }
            #endif
            return nil
        }
    }

    private static var defaultHelperURL: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/EmberPluginWorker")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["EMBER_NATIVE_STAGING_WORKER_PATH"],
           FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        #endif
        return nil
    }
    private struct FileIdentity: Equatable {
        let device: Int64, inode: UInt64, size: UInt64, mode: UInt32, user: UInt32, links: UInt64
        let modificationSeconds: Int64, modificationNanos: Int64, changeSeconds: Int64, changeNanos: Int64
        init(_ descriptor: Int32) throws {
            var value = stat()
            guard Darwin.fstat(descriptor, &value) == 0, value.st_size >= 0 else { throw Refusal.input }
            device = Int64(value.st_dev); inode = UInt64(value.st_ino); size = UInt64(value.st_size)
            mode = UInt32(value.st_mode); user = UInt32(value.st_uid); links = UInt64(value.st_nlink)
            modificationSeconds = Int64(value.st_mtimespec.tv_sec); modificationNanos = Int64(value.st_mtimespec.tv_nsec)
            changeSeconds = Int64(value.st_ctimespec.tv_sec); changeNanos = Int64(value.st_ctimespec.tv_nsec)
        }
        var isRegular: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
        var isOwnedPrivateRegular: Bool {
            isRegular && user == getuid() && mode & 0o777 == 0o600 && links == 1
        }
        func sameNode(as other: Self) -> Bool { device == other.device && inode == other.inode }
    }
    private static func validateInput(_ input: PDFRawStreamSource.TagReadFileInput,
                                      descriptor: Int32, identity: FileIdentity) throws {
        try PDFSaveCancellation.checkCurrent()
        guard identity.isRegular, identity.size == input.version.fileSize,
              identity.device >= 0,
              input.version.fileSystemNumber == UInt64(identity.device),
              input.version.fileSystemNodeNumber == identity.inode,
              try FileIdentity(descriptor) == identity,
              try PDFSourceFileVersion.capture(at: input.url) == input.version else { throw Refusal.input }
        let currentFD = Darwin.open(input.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard currentFD >= 0 else { throw Refusal.input }
        defer { Darwin.close(currentFD) }
        guard try FileIdentity(currentFD) == identity else { throw Refusal.input }
    }
    private static func streamDigest(_ descriptor: Int32, maximum: UInt64) throws -> Data {
        let before = try FileIdentity(descriptor)
        guard before.isRegular, before.size > 0, before.size <= maximum else { throw Refusal.input }
        var hasher = SHA256(), buffer = [UInt8](repeating: 0, count: 64 * 1_024), offset: UInt64 = 0
        while offset < before.size {
            try PDFSaveCancellation.checkCurrent()
            let count = Darwin.pread(descriptor, &buffer, min(buffer.count, Int(before.size - offset)), off_t(offset))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Refusal.input }
            hasher.update(data: Data(buffer.prefix(count))); offset += UInt64(count)
        }
        guard try FileIdentity(descriptor) == before else { throw Refusal.input }
        return Data(hasher.finalize())
    }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private struct WorkerIdentity: Equatable {
        let startSeconds: UInt64, startMicros: UInt64, parent: Int32
        static func read(_ pid: Int32) -> (Self, UInt64)? {
            var seconds: UInt64 = 0, micros: UInt64 = 0, parent: Int32 = 0, rss: UInt64 = 0
            guard ember_pdf_read_worker_process_info(pid, &seconds, &micros, &parent, &rss) == 1,
                  parent == getpid(), seconds > 0 else { return nil }
            return (Self(startSeconds: seconds, startMicros: micros, parent: parent), rss)
        }
    }
    private struct Receipt: Decodable {
        let type: String, protocolVersion: Int, status: String
        let inputBytes: UInt64, outputBytes: UInt64, objectCount: UInt64
        let inputSHA256: String, outputSHA256: String
        let rawTagGraphEquivalent: Bool, pageCount: Int, tagNodes: UInt64
    }
    private struct WorkerRefusal: Decodable {
        let type: String, protocolVersion: Int, status: Int
    }
    private static func run(helper: URL, inputFD: Int32, outputFD: Int32,
                            digest: Data, limits: Limits) throws -> Receipt {
        let process = Process(), errors = Pipe()
        process.executableURL = helper
        process.arguments = ["--tag-read-auxiliary", "--protocol-version", "1", "--input-fd", "0",
                             "--output-fd", "1", "--input-sha256", hex(digest)]
        process.standardInput = FileHandle(fileDescriptor: inputFD, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: outputFD, closeOnDealloc: false)
        process.standardError = errors
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let stderrFD = errors.fileHandleForReading.fileDescriptor
        let flags = fcntl(stderrFD, F_GETFL)
        guard flags >= 0, fcntl(stderrFD, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Refusal.process }
        defer { try? errors.fileHandleForReading.close(); try? errors.fileHandleForWriting.close() }
        var receipt = Data(), identity: WorkerIdentity?, failure: Error?, controlClosed = false
        let began = ProcessInfo.processInfo.systemUptime
        try PDFSaveCancellation.checkCurrent()
        guard limits.seconds > 0, ProcessInfo.processInfo.systemUptime - began < limits.seconds else { throw Refusal.limit }
        try process.run()
        // A child that finishes before identity capture cannot qualify. It is
        // still reaped; no reused/unobserved PID is ever used for signalling.
        identity = WorkerIdentity.read(process.processIdentifier)?.0
        func drain() throws {
            guard !controlClosed else { return }
            var bytes = [UInt8](repeating: 0, count: 2_049)
            while true {
                let count = Darwin.read(stderrFD, &bytes, bytes.count)
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw Refusal.receipt }
                if count == 0 { return }
                guard count <= 2_048 - receipt.count else { throw Refusal.limit }
                receipt.append(contentsOf: bytes.prefix(count))
            }
        }
        func stopOwned() {
            // Reader closure is a private cancellation signal to this exact
            // role's self-watchdog, including when PID observation fails.
            if !controlClosed { controlClosed = true; try? errors.fileHandleForReading.close() }
            guard process.isRunning, let identity,
                  WorkerIdentity.read(process.processIdentifier)?.0 == identity else { return }
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning, WorkerIdentity.read(process.processIdentifier)?.0 == identity {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        while process.isRunning {
            do {
                try PDFSaveCancellation.checkCurrent()
                try drain()
                guard try FileIdentity(outputFD).size <= limits.outputBytes else { throw Refusal.limit }
                let observed = WorkerIdentity.read(process.processIdentifier)
                if observed == nil {
                    // libproc stops exposing a child just before Foundation's
                    // termination notification arrives. Require confirmed
                    // Process termination (then exit status + exact receipt),
                    // never infer completion from an unavailable observation.
                    let notificationDeadline = ProcessInfo.processInfo.systemUptime + 0.1
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < notificationDeadline {
                        try PDFSaveCancellation.checkCurrent()
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                    if !process.isRunning { break }
                }
                guard let identity, let observed, observed.0 == identity,
                      observed.1 <= limits.residentBytes,
                      ProcessInfo.processInfo.systemUptime - began < limits.seconds else {
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["EMBER_NATIVE_STAGING_TRACE"] == "1" {
                        let row: [String: Any] = ["helperLimitRefusal": true, "identityCaptured": identity != nil,
                            "identityObserved": observed != nil, "identityEqual": observed?.0 == identity,
                            "residentBytes": observed?.1 ?? 0, "residentLimit": limits.residentBytes,
                            "elapsed": ProcessInfo.processInfo.systemUptime - began, "secondsLimit": limits.seconds]
                        if let bytes = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                            FileHandle.standardError.write(bytes); FileHandle.standardError.write(Data([10]))
                        }
                    }
                    #endif
                    throw Refusal.limit
                }
            } catch { failure = error; stopOwned(); break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        // If OS process observation was unavailable, the exact helper role's
        // independent pipe-reader watchdog requests prompt self-exit; its
        //90s alarm/RSS watchdog is a final boundary. Wait for its owned
        // Process to exit, never leave a helper alive before normal fallback.
        process.waitUntilExit()
        if let failure { throw failure }
        try drain()
        #if DEBUG
        if ProcessInfo.processInfo.environment["EMBER_NATIVE_STAGING_TRACE"] == "1" {
            FileHandle.standardError.write(Data("tag-read-worker-exit=\(process.terminationStatus) receipt=".utf8))
            FileHandle.standardError.write(receipt.prefix(2_048)); FileHandle.standardError.write(Data([10]))
        }
        #endif
        try PDFSaveCancellation.checkCurrent()
        guard identity != nil, !process.isRunning, process.terminationReason == .exit,
              !receipt.isEmpty, receipt.count <= 2_048 else { throw Refusal.process }
        if process.terminationStatus == 65,
           let errorFields = (try? JSONSerialization.jsonObject(with: receipt)) as? [String: Any],
           Set(errorFields.keys) == Set(["type", "protocolVersion", "status"]),
           let refusal = try? JSONDecoder().decode(WorkerRefusal.self, from: receipt),
           refusal.type == "tag-read-auxiliary-error", refusal.protocolVersion == 1, refusal.status == 7 {
            throw OriginalTagReaderFallback.unsupportedGraph
        }
        guard process.terminationStatus == 0 else { throw Refusal.process }
        let value = try JSONDecoder().decode(Receipt.self, from: receipt)
        guard value.type == "tag-read-auxiliary-result", value.protocolVersion == 1, value.status == "ok",
              value.objectCount <= 250_000, value.tagNodes > 0, value.tagNodes <= 16_000_000,
              value.outputBytes <= limits.outputBytes,
              value.inputBytes <= 128 * 1_024 * 1_024, value.rawTagGraphEquivalent else { throw Refusal.receipt }
        return value
    }
}
