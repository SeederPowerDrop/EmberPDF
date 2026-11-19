// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class OCRExportSaveTests: XCTestCase {
    func testMaximumLengthUnicodeFileNamesRemainSearchable() throws {
        let directory = try makeDirectory()
        let document = try makeDocument()
        let checkpoint = makeCheckpoint()
        let names = [
            String(repeating: "한", count: 82) + "x-OCR.pdf",
            String(repeating: "한", count: 27) + "xxxx-OCR.pdf"
        ]

        for name in names {
            XCTAssertEqual(name.utf8.count, 255)
            let destination = directory.appendingPathComponent(name)
            try SearchablePDFExporter.export(
                document: document, checkpoint: checkpoint, to: destination
            )
            try assertSearchable(at: destination)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, names.count)
    }

    func testExportReplacesUnchangedExistingDestinationAndPreservesSource() throws {
        let directory = try makeDirectory()
        let source = directory.appendingPathComponent("source.pdf")
        let destination = directory.appendingPathComponent("source-OCR.pdf")
        XCTAssertTrue(try makeDocument().write(to: source))
        XCTAssertTrue(try makeDocument().write(to: destination))
        let originalBytes = try Data(contentsOf: source)
        let document = try XCTUnwrap(PDFDocument(url: source))

        try SearchablePDFExporter.export(
            document: document, checkpoint: makeCheckpoint(), to: destination,
            sourceURL: source
        )

        try assertSearchable(at: destination)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       ["source.pdf", "source-OCR.pdf"])
    }

    func testExportWorksWhenOnlySelectedFileIsWritable() throws {
        let directory = try makeDirectory()
        let source = directory.appendingPathComponent("source.pdf")
        let destination = directory.appendingPathComponent("source-OCR.pdf")
        XCTAssertTrue(try makeDocument().write(to: source))
        XCTAssertTrue(try makeDocument().write(to: destination))
        let originalBytes = try Data(contentsOf: source)
        let document = try XCTUnwrap(PDFDocument(url: source))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path
            )
        }
        // Models a save-panel grant for the selected file: its contents can be
        // written, but rendering into a sibling temporary file is forbidden.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path
        )

        try SearchablePDFExporter.export(
            document: document, checkpoint: makeCheckpoint(), to: destination,
            sourceURL: source
        )

        try assertSearchable(at: destination)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       ["source.pdf", "source-OCR.pdf"])
    }

    func testFileCreatedDuringExportIsNotOverwritten() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("source-OCR.pdf")
        let outsideBytes = Data("Another process created this file.".utf8)

        XCTAssertThrowsError(try SearchablePDFExporter.export(
            document: makeDocument(), checkpoint: makeCheckpoint(), to: destination,
            beforeDestinationCommit: {
                try outsideBytes.write(to: destination)
            }
        )) { error in
            guard case WorkspaceError.externalModification(let changedURL) = error else {
                return XCTFail("Expected a destination conflict, received \(error)")
            }
            XCTAssertEqual(changedURL, destination)
        }

        XCTAssertEqual(try Data(contentsOf: destination), outsideBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source-OCR.pdf"])
    }

    func testFileReplacedDuringExportIsNotOverwritten() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("source-OCR.pdf")
        XCTAssertTrue(try makeDocument().write(to: destination))
        let outsideBytes = Data("Another process replaced the selected file.".utf8)

        XCTAssertThrowsError(try SearchablePDFExporter.export(
            document: makeDocument(), checkpoint: makeCheckpoint(), to: destination,
            beforeDestinationCommit: {
                try FileManager.default.removeItem(at: destination)
                try outsideBytes.write(to: destination)
            }
        )) { error in
            guard case WorkspaceError.externalModification = error else {
                return XCTFail("Expected a destination conflict, received \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: destination), outsideBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source-OCR.pdf"])
    }

    func testDiskFullErrorRemainsActionableAndDoesNotDamageExistingDestination() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("source-OCR.pdf")
        XCTAssertTrue(try makeDocument().write(to: destination))
        let originalBytes = try Data(contentsOf: destination)
        let injected = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileWriteOutOfSpace.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "The disk is full."]
        )

        XCTAssertThrowsError(try SearchablePDFExporter.export(
            document: makeDocument(), checkpoint: makeCheckpoint(), to: destination,
            beforeDestinationCommit: { throw injected }
        )) { error in
            let actual = error as NSError
            XCTAssertEqual(actual.domain, injected.domain)
            XCTAssertEqual(actual.code, injected.code)
            XCTAssertEqual(actual.localizedDescription, injected.localizedDescription)
        }

        XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source-OCR.pdf"])
    }

    func testFailedSaveKeepsCompletedOCRAvailableForRetryWithoutRecognition() async throws {
        let directory = try makeDirectory()
        let source = directory.appendingPathComponent("source.pdf")
        XCTAssertTrue(try makeDocument().write(to: source))
        let originalBytes = try Data(contentsOf: source)
        var recognitionCount = 0
        let workspace = PDFWorkspaceState(ocrRecognizer: { url, fingerprint, configuration, _ in
            recognitionCount += 1
            let result = self.makeCheckpoint()
            var checkpoint = OCRCheckpoint(
                documentFingerprint: try fingerprint ?? VisionOCRService.fingerprint(for: url),
                pageCount: result.pageCount,
                configurationFingerprint: VisionOCRService.configurationFingerprint(for: configuration)
            )
            checkpoint.pages = result.pages
            return checkpoint
        })
        XCTAssertTrue(workspace.open(url: source))
        workspace.startOCR(configuration: OCRConfiguration())
        for _ in 0..<500 where !workspace.canUseCompletedOCRResult {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(workspace.canUseCompletedOCRResult)
        let checkpoint = try XCTUnwrap(workspace.ocrCheckpoint)

        // A regular file cannot be used as the output's parent directory.
        let blocker = directory.appendingPathComponent("not-a-folder")
        try Data("file".utf8).write(to: blocker)
        let failedSave = await workspace.exportSearchableOCRCopy(to: blocker.appendingPathComponent("failed.pdf"))
        XCTAssertFalse(failedSave)
        XCTAssertFalse(workspace.isExportingOCR)
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertEqual(workspace.ocrCheckpoint, checkpoint)
        XCTAssertTrue(workspace.canUseCompletedOCRResult)

        let destination = directory.appendingPathComponent("source-OCR.pdf")
        let retriedSave = await workspace.exportSearchableOCRCopy(to: destination)
        XCTAssertTrue(retriedSave)
        XCTAssertFalse(workspace.isExportingOCR)
        try assertSearchable(at: destination)
        XCTAssertEqual(recognitionCount, 1)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertFalse(workspace.isDirty)
    }

    func testNoReplacementMainExportKeepsCommitConflictsAndDiskFullActionable() throws {
        XCTAssertTrue(Thread.isMainThread)
        let temporary = FileManager.default.temporaryDirectory
        func privateStages() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path)
                .filter { $0.hasPrefix("HwattakPDF-OCRExport-") })
        }
        for variant in ["none", "skipped", "empty", "whitespace"] {
            for existing in [false, true] {
                for diskFull in [false, true] {
                    let directory = try makeDirectory()
                    let source = directory.appendingPathComponent("source.pdf")
                    let destination = directory.appendingPathComponent("copy.pdf")
                    XCTAssertTrue(try makeDocument().write(to: source))
                    let original = try Data(contentsOf: source)
                    if existing { try original.write(to: destination) }
                    let document = try XCTUnwrap(PDFDocument(url: source))
                    let originalPage = try XCTUnwrap(document.page(at: 0))
                    let originalAnnotationCount = originalPage.annotations.count
                    var checkpoint = OCRCheckpoint(
                        documentFingerprint: "no-replacement-commit-guards", pageCount: 1,
                        configurationFingerprint: "no-replacement-configuration"
                    )
                    if variant != "none" {
                        let text = variant == "skipped" ? "Existing text" : (variant == "empty" ? "" : " \n\t")
                        checkpoint.pages[0] = OCRPageResult(
                            pageIndex: 0, text: text, observations: text.isEmpty ? [] : [
                                OCRWordBox(text: text, confidence: 1,
                                           x: 0.1, y: 0.5, width: 0.8, height: 0.1)
                            ], completedAt: Date(), skippedBecauseTextExists: variant == "skipped"
                        )
                    }
                    XCTAssertTrue(PDFOCRApplication.replacementPageIndexes(checkpoint: checkpoint).isEmpty)
                    let stagesBefore = try privateStages()
                    let outside = Data("A concurrent creator or replacer owns this destination.".utf8)
                    let injected = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC),
                        userInfo: [NSLocalizedDescriptionKey: "The disk is full (injected)."])
                    var callbackCount = 0
                    XCTAssertThrowsError(try SearchablePDFExporter.export(
                        document: document, checkpoint: checkpoint, to: destination,
                        sourceURL: source, beforeDestinationCommit: {
                            callbackCount += 1
                            if diskFull { throw injected }
                            try outside.write(to: destination)
                        }
                    )) { error in
                        if diskFull {
                            let actual = error as NSError
                            XCTAssertEqual(actual.domain, injected.domain)
                            XCTAssertEqual(actual.code, injected.code)
                            XCTAssertEqual(actual.localizedDescription, injected.localizedDescription)
                        } else {
                            guard case WorkspaceError.externalModification(let changedURL) = error else {
                                return XCTFail("Expected the captured destination conflict, received \(error)")
                            }
                            XCTAssertEqual(changedURL, destination)
                        }
                    }
                    XCTAssertGreaterThan(callbackCount, 0, "The failure must reach final commit validation.")
                    if !diskFull {
                        XCTAssertEqual(try Data(contentsOf: destination), outside)
                    } else if existing {
                        XCTAssertEqual(try Data(contentsOf: destination), original)
                    } else {
                        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                    }
                    XCTAssertEqual(try Data(contentsOf: source), original)
                    XCTAssertTrue(document.page(at: 0) === originalPage)
                    XCTAssertEqual(originalPage.annotations.count, originalAnnotationCount)
                    XCTAssertEqual(document.pageCount, 1)
                    let expectedNames: Set<String> = existing || !diskFull ? ["source.pdf", "copy.pdf"] : ["source.pdf"]
                    XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), expectedNames,
                                   "Failed final writes must remove their sibling staging files.")
                    XCTAssertEqual(try privateStages(), stagesBefore,
                                   "No failed all-skipped export may leave private OCR staging behind.")
                }
            }
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-OCRExportSaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeDocument() throws -> PDFDocument {
        let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        return document
    }

    private func makeCheckpoint() -> OCRCheckpoint {
        var checkpoint = OCRCheckpoint(
            documentFingerprint: "export-save-fixture", pageCount: 1,
            configurationFingerprint: "export-save-configuration"
        )
        checkpoint.pages[0] = OCRPageResult(
            pageIndex: 0, text: "Searchable saved OCR", observations: [
                OCRWordBox(text: "Searchable saved OCR", confidence: 1,
                           x: 0.1, y: 0.5, width: 0.8, height: 0.1)
            ], completedAt: Date(), skippedBecauseTextExists: false
        )
        return checkpoint
    }

    private func assertSearchable(at url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let document = try XCTUnwrap(PDFDocument(url: url), file: file, line: line)
        XCTAssertEqual(document.pageCount, 1, file: file, line: line)
        XCTAssertTrue(document.string?.contains("Searchable saved OCR") == true, file: file, line: line)
    }
}
