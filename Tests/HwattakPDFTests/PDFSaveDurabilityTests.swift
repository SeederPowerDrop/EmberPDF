// SPDX-License-Identifier: MPL-2.0

import AppKit
import Darwin
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFSaveDurabilityTests: XCTestCase {
    func testNativeFlushOfRegularStagingFilePreservesItsBytes() throws {
        let directory = try makeDirectory()
        let staged = directory.appendingPathComponent("staged.pdf")
        let bytes = Data(repeating: 0x51, count: 64 * 1_024)
        try bytes.write(to: staged)
        try PDFSaveDurability.synchronizeStagedFile(at: staged)
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
    }

    func testSuccessfulFullFlushDoesNotUseFallbackAndClosesDescriptor() throws {
        let directory = try makeDirectory()
        let staged = directory.appendingPathComponent("staged.pdf")
        try Data("staged".utf8).write(to: staged)
        var descriptor: Int32 = -1
        var fallbackCalls = 0
        try PDFSaveDurability.synchronizeStagedFile(at: staged, fullSync: { descriptor = $0 },
                                                  standardSync: { _ in fallbackCalls += 1 })
        XCTAssertEqual(fallbackCalls, 0)
        try assertDescriptorClosed(descriptor)
    }

    func testStagingSymlinkIsRefusedWithoutTouchingItsTarget() throws {
        let directory = try makeDirectory()
        let target = directory.appendingPathComponent("target.pdf")
        let staged = directory.appendingPathComponent("staged.pdf")
        let bytes = Data("keep".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: target)
        var syncCalls = 0
        XCTAssertThrowsError(try PDFSaveDurability.synchronizeStagedFile(at: staged,
            fullSync: { _ in syncCalls += 1 }, standardSync: { _ in syncCalls += 1 }))
        XCTAssertEqual(syncCalls, 0)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    @MainActor
    func testUnsupportedFullFlushFallsBackToNativeFsyncBeforeCommit() throws {
        for unsupported in [ENOTSUP, ENOTTY] {
            let directory = try makeDirectory()
            let destination = directory.appendingPathComponent("out.pdf")
            let oldBytes = Data("original".utf8)
            try oldBytes.write(to: destination)
            let document = try makeDocument()
            var events: [String] = []
            var directFallbackCount = 0
            try AtomicPDFWriter.write(document, to: destination,
                validateDestinationBeforeCommit: {
                    events.append("destination")
                    XCTAssertEqual(try Data(contentsOf: destination), oldBytes)
                },
                validateStagedPDF: { staged, count in
                    XCTAssertEqual(count, 1)
                    XCTAssertEqual(PDFDocument(url: staged)?.pageCount, 1)
                    events.append("validated")
                },
                onDirectWriteFallback: { directFallbackCount += 1 },
                synchronizeStagedFile: { staged in
                    try PDFSaveDurability.synchronizeStagedFile(at: staged, fullSync: { descriptor in
                        XCTAssertEqual(Darwin.fcntl(descriptor, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)
                        events.append("full")
                        throw self.posix(unsupported)
                    }, standardSync: { descriptor in
                        events.append("fsync")
                        guard Darwin.fsync(descriptor) == 0 else { throw self.posix(errno) }
                    })
                })
            XCTAssertEqual(events, ["validated", "full", "fsync", "destination"])
            XCTAssertEqual(directFallbackCount, 0)
            XCTAssertEqual(PDFDocument(url: destination)?.pageCount, 1)
            try assertNoStagingFiles(in: directory)
        }
    }

    @MainActor
    func testFlushFailureKeepsOriginalForExistingAndAbsentDestinations() throws {
        // A permission-looking flush error must not be confused with inability
        // to create a sibling file. Other real I/O errors must also propagate.
        for failure in [EIO, ENOSPC, EACCES, EPERM, EINVAL] {
            for existed in [false, true] {
                let directory = try makeDirectory()
                let destination = directory.appendingPathComponent("out.pdf")
                let original = Data("original".utf8)
                if existed { try original.write(to: destination) }
                var directFallbackCount = 0
                var fallbackSyncCount = 0
                var failedDescriptor: Int32 = -1
                XCTAssertThrowsError(try AtomicPDFWriter.write(try makeDocument(), to: destination,
                    onDirectWriteFallback: { directFallbackCount += 1 },
                    synchronizeStagedFile: { staged in
                        try PDFSaveDurability.synchronizeStagedFile(at: staged,
                            fullSync: { descriptor in failedDescriptor = descriptor; throw self.posix(failure) },
                            standardSync: { _ in fallbackSyncCount += 1 })
                    })) { error in
                        XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
                        XCTAssertEqual((error as NSError).code, Int(failure))
                    }
                XCTAssertEqual(directFallbackCount, 0)
                XCTAssertEqual(fallbackSyncCount, 0)
                try assertDescriptorClosed(failedDescriptor)
                if existed { XCTAssertEqual(try Data(contentsOf: destination), original) }
                else { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path)) }
                try assertNoStagingFiles(in: directory)
            }
        }
    }

    @MainActor
    func testFailedFallbackFlushKeepsOriginalAndPropagatesFailure() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("out.pdf")
        let original = Data("original".utf8)
        try original.write(to: destination)
        var directFallbackCount = 0
        var failedDescriptor: Int32 = -1
        XCTAssertThrowsError(try AtomicPDFWriter.write(try makeDocument(), to: destination,
            onDirectWriteFallback: { directFallbackCount += 1 },
            synchronizeStagedFile: { staged in
                try PDFSaveDurability.synchronizeStagedFile(at: staged,
                    fullSync: { descriptor in failedDescriptor = descriptor; throw self.posix(ENOTSUP) },
                    standardSync: { _ in throw self.posix(EIO) })
            })) { error in
                XCTAssertEqual((error as NSError).code, Int(EIO))
            }
        XCTAssertEqual(directFallbackCount, 0)
        try assertDescriptorClosed(failedDescriptor)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        try assertNoStagingFiles(in: directory)
    }

    @MainActor
    func testExternalChangeWhileFlushingIsStillRejectedBeforeCommit() throws {
        for existed in [false, true] {
            let directory = try makeDirectory()
            let destination = directory.appendingPathComponent("out.pdf")
            if existed { try Data("original".utf8).write(to: destination) }
            let externalBytes = Data("external edit during flush".utf8)
            var directFallbackCount = 0
            XCTAssertThrowsError(try AtomicPDFWriter.write(try makeDocument(), to: destination,
                onDirectWriteFallback: { directFallbackCount += 1 },
                synchronizeStagedFile: { staged in
                    try PDFSaveDurability.synchronizeStagedFile(at: staged)
                    try externalBytes.write(to: destination)
                })) { error in
                    guard case WorkspaceError.externalModification = error else {
                        return XCTFail("Expected destination conflict, received \(error)")
                    }
                }
            XCTAssertEqual(directFallbackCount, 0)
            XCTAssertEqual(try Data(contentsOf: destination), externalBytes)
            try assertNoStagingFiles(in: directory)
        }
    }

    @MainActor
    func testFailedFlushLeavesWorkspaceDirtyAndBothFilesUnchanged() throws {
        let directory = try makeDirectory()
        let source = directory.appendingPathComponent("source.pdf")
        let destination = directory.appendingPathComponent("copy.pdf")
        XCTAssertTrue(try makeDocument().write(to: source))
        let originalBytes = try Data(contentsOf: source)
        try originalBytes.write(to: destination)
        var directFallbackCount = 0
        let workspace = PDFWorkspaceState(pdfWriter: { document, url, validate in
            try AtomicPDFWriter.write(document, to: url,
                validateDestinationBeforeCommit: validate,
                onDirectWriteFallback: { directFallbackCount += 1 },
                synchronizeStagedFile: { _ in throw self.posix(EIO) })
        })
        XCTAssertTrue(workspace.open(url: source))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertFalse(workspace.saveSynchronously(as: destination))
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(workspace.documentURL, source)
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertEqual(directFallbackCount, 0)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
        try assertNoStagingFiles(in: directory)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberPDF-Durability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    private func makeDocument() throws -> PDFDocument {
        let image = NSImage(size: CGSize(width: 120, height: 180), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        return document
    }

    private func posix(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private func assertDescriptorClosed(_ descriptor: Int32) throws {
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let result = Darwin.fcntl(descriptor, F_GETFD)
        let failure = errno
        XCTAssertEqual(result, -1)
        XCTAssertEqual(failure, EBADF)
    }

    private func assertNoStagingFiles(in directory: URL) throws {
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).allSatisfy { !$0.lastPathComponent.hasPrefix(".HwattakPDF-") })
    }
}
