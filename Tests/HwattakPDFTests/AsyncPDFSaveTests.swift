// SPDX-License-Identifier: MPL-2.0

import AppKit
import CryptoKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class AsyncPDFSaveTests: XCTestCase {
    func testPendingSaveKeepsMainActorResponsiveIncludingSnapshotCapture() async throws {
        let fixture = try makeFixture(), gate = AsyncSaveGate()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = gatedWorkspace(gate)
        XCTAssertTrue(workspace.open(url: fixture.source))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        let probes = AsyncSaveMainActorProbes()
        probes.start()
        let task = Task { await workspace.saveAsynchronously() }
        try await waitForGate(gate)
        XCTAssertTrue(workspace.isSaving)
        try await Task.sleep(nanoseconds: 250_000_000)
        let pending = probes.snapshot()
        XCTAssertGreaterThanOrEqual(pending.handled, 3)
        XCTAssertLessThan(pending.maximumLatency, 0.75)
        await gate.release()
        let saved = await task.value
        try await Task.sleep(nanoseconds: 30_000_000)
        let finished = probes.stop()
        XCTAssertTrue(saved)
        XCTAssertLessThan(finished.maximumLatency, 0.75)
        XCTAssertFalse(workspace.isSaving)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(PDFDocument(url: fixture.source)?.page(at: 0)?.rotation, 90)
        workspace.closeDiscardingChanges()
    }

    func testEditsDuringSaveKeepNewerHistoryDirtyAndUndoReturnsToSavedCheckpoint() async throws {
        let fixture = try makeFixture(), gate = AsyncSaveGate()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = gatedWorkspace(gate)
        XCTAssertTrue(workspace.open(url: fixture.source))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        let capturedState = workspace.editStateID
        let task = Task { await workspace.saveAsynchronously() }
        try await waitForGate(gate)
        workspace.rotateSelectedPages(clockwise: true)
        XCTAssertNotEqual(workspace.editStateID, capturedState)
        await gate.release()
        let saved = await task.value
        XCTAssertTrue(saved)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(workspace.document?.page(at: 0)?.rotation, 180)
        XCTAssertEqual(PDFDocument(url: fixture.source)?.page(at: 0)?.rotation, 90)
        workspace.undo()
        XCTAssertEqual(workspace.editStateID, capturedState)
        XCTAssertFalse(workspace.isDirty)
        workspace.redo()
        XCTAssertTrue(workspace.isDirty)
        workspace.closeDiscardingChanges()
    }

    func testLanguageAndNavigationChangesDoNotInvalidateCapturedSave() async throws {
        let fixture = try makeFixture(), gate = AsyncSaveGate()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let preference = UserDefaults.standard.object(forKey: AppPreferences.languageDefaultsKey)
        defer { UserDefaults.standard.set(preference, forKey: AppPreferences.languageDefaultsKey) }
        let workspace = gatedWorkspace(gate)
        XCTAssertTrue(workspace.open(url: fixture.source))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        let capturedState = workspace.editStateID
        let task = Task { await workspace.saveAsynchronously() }
        try await waitForGate(gate)
        for language in AppLanguage.allCases {
            UserDefaults.standard.set(language.rawValue, forKey: AppPreferences.languageDefaultsKey)
            workspace.refreshLocalization()
            workspace.currentPageIndex = 0
            XCTAssertTrue(workspace.isSaving)
            XCTAssertEqual(workspace.statusMessage, L10n.string("action.saving"))
            XCTAssertEqual(workspace.editStateID, capturedState)
        }
        await gate.release()
        let saved = await task.value
        XCTAssertTrue(saved)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(workspace.statusMessage, L10n.format("status.saved_file", fixture.source.lastPathComponent))
        workspace.closeDiscardingChanges()
    }

    func testDuplicateSaveDoesNotStartAnotherWriterOrRedirectItsDestination() async throws {
        let fixture = try makeFixture(), gate = AsyncSaveGate()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = gatedWorkspace(gate)
        XCTAssertTrue(workspace.open(url: fixture.source))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        let task = Task { await workspace.saveAsynchronously() }
        try await waitForGate(gate)
        let other = fixture.directory.appendingPathComponent("duplicate-copy.pdf")
        let duplicate = await workspace.saveAsynchronously(as: other)
        XCTAssertFalse(duplicate)
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
        await gate.release()
        let saved = await task.value
        XCTAssertTrue(saved)
        XCTAssertEqual(workspace.documentURL, fixture.source)
        workspace.closeDiscardingChanges()
    }

    func testNativeWidgetTypedDuringSaveRemainsDetectablyDirtyAfterCompletion() async throws {
        let fixture = try makeFixture(), gate = AsyncSaveGate()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let seed = try XCTUnwrap(PDFDocument(url: fixture.source))
        let field = PDFAnnotation(bounds: CGRect(x: 25, y: 170, width: 120, height: 28), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "async-field"
        field.widgetStringValue = "captured"
        try XCTUnwrap(seed.page(at: 0)).addAnnotation(field)
        XCTAssertTrue(seed.write(to: fixture.source))
        let workspace = gatedWorkspace(gate)
        XCTAssertTrue(workspace.open(url: fixture.source))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        let task = Task { await workspace.saveAsynchronously() }
        try await waitForGate(gate)
        let liveField = try XCTUnwrap(workspace.document?.page(at: 0)?.annotations.first)
        // A native field editor may change its value before deactivation has
        // published a document revision. Completion must not prime over it.
        liveField.widgetStringValue = "typed while saving"
        await gate.release()
        let saved = await task.value
        XCTAssertTrue(saved)
        XCTAssertEqual(PDFDocument(url: fixture.source)?.page(at: 0)?.annotations.first?.widgetStringValue, "captured")
        XCTAssertEqual(liveField.widgetStringValue, "typed while saving")
        workspace.prepareForDeactivation()
        XCTAssertTrue(workspace.isDirty)
        workspace.undo()
        XCTAssertEqual(liveField.widgetStringValue, "captured")
        XCTAssertFalse(workspace.isDirty)
        workspace.closeDiscardingChanges()
    }

    func testWriterFailureKeepsSourceAndDirtyHistoryAndAllowsRetry() async throws {
        let fixture = try makeFixture(), gate = AsyncSaveGate()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try Data(contentsOf: fixture.source)
        var fail = true
        let workspace = PDFWorkspaceState(backgroundSaveWriter: { snapshot, request, cancellation in
            await gate.enter()
            if fail { throw AsyncSaveTestFailure.injected }
            return try await PDFBackgroundSaveWriter.write(snapshot: snapshot, request: request, cancellation: cancellation)
        })
        XCTAssertTrue(workspace.open(url: fixture.source))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        let capturedState = workspace.editStateID
        let task = Task { await workspace.saveAsynchronously() }
        try await waitForGate(gate)
        await gate.release()
        let failed = await task.value
        XCTAssertFalse(failed)
        XCTAssertFalse(workspace.isSaving)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(workspace.editStateID, capturedState)
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertEqual(try Data(contentsOf: fixture.source), original)
        fail = false
        let retried = await workspace.saveAsynchronously()
        XCTAssertTrue(retried)
        XCTAssertFalse(workspace.isDirty)
        workspace.closeDiscardingChanges()
    }

    func testExternalSourceChangeWhileQueuedIsNeverOverwritten() async throws {
        let fixture = try makeFixture(), gate = AsyncSaveGate()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = gatedWorkspace(gate)
        XCTAssertTrue(workspace.open(url: fixture.source))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        let task = Task { await workspace.saveAsynchronously() }
        try await waitForGate(gate)
        let external = try Data(contentsOf: fixture.source) + Data("\n% external save\n".utf8)
        try external.write(to: fixture.source)
        await gate.release()
        let saved = await task.value
        XCTAssertFalse(saved)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertEqual(try Data(contentsOf: fixture.source), external)
        workspace.closeDiscardingChanges()
    }

    func testSaveCopyDestinationAppearingWhileQueuedIsNotOverwritten() async throws {
        let fixture = try makeFixture(), gate = AsyncSaveGate()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try Data(contentsOf: fixture.source)
        let destination = fixture.directory.appendingPathComponent("copy.pdf")
        let workspace = gatedWorkspace(gate)
        XCTAssertTrue(workspace.open(url: fixture.source))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        let task = Task { await workspace.saveAsynchronously(as: destination) }
        try await waitForGate(gate)
        let external = Data("external destination must survive".utf8)
        try external.write(to: destination)
        await gate.release()
        let saved = await task.value
        XCTAssertFalse(saved)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(workspace.documentURL, fixture.source)
        XCTAssertEqual(try Data(contentsOf: fixture.source), original)
        XCTAssertEqual(try Data(contentsOf: destination), external)
        workspace.closeDiscardingChanges()
    }

    func testOrdinarySavesKeepExistingFilesWhenSiblingStagingIsDenied() async throws {
        for synchronous in [false, true] {
            for saveCopy in [false, true] {
                let fixture = try makeFixture()
                let destination = fixture.directory.appendingPathComponent("copy.pdf")
                let original = try Data(contentsOf: fixture.source)
                if saveCopy { try original.write(to: destination) }
                let workspace = PDFWorkspaceState()
                defer {
                    workspace.closeDiscardingChanges()
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                           ofItemAtPath: fixture.directory.path)
                    try? FileManager.default.removeItem(at: fixture.directory)
                }
                XCTAssertTrue(workspace.open(url: fixture.source))
                workspace.setMode(.editing)
                workspace.rotateSelectedPages(clockwise: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                                      ofItemAtPath: fixture.directory.path)
                let requestedURL = saveCopy ? destination : nil
                let saved: Bool
                if synchronous { saved = workspace.saveSynchronously(as: requestedURL) }
                else { saved = await workspace.saveAsynchronously(as: requestedURL) }
                XCTAssertFalse(saved, "A save that cannot safely replace the destination should fail")
                XCTAssertTrue(workspace.isDirty)
                XCTAssertEqual(workspace.document?.page(at: 0)?.rotation, 90)
                XCTAssertEqual(workspace.documentURL, fixture.source)
                XCTAssertNotNil(workspace.presentedError)
                XCTAssertEqual(try Data(contentsOf: fixture.source), original)
                if saveCopy { XCTAssertEqual(try Data(contentsOf: destination), original) }
                XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)),
                               saveCopy ? ["source.pdf", "copy.pdf"] : ["source.pdf"])
            }
        }
    }

    func testCancelBeforeWorkerCommitPreservesOriginalAndAllowsAnotherSave() async throws {
        let fixture = try makeFixture(), gate = AsyncSaveGate()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try Data(contentsOf: fixture.source)
        let workspace = gatedWorkspace(gate)
        XCTAssertTrue(workspace.open(url: fixture.source))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        let task = Task { await workspace.saveAsynchronously() }
        try await waitForGate(gate)
        workspace.cancelSave()
        await gate.release()
        let saved = await task.value
        XCTAssertFalse(saved)
        XCTAssertFalse(workspace.isSaving)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), original)
        let retried = await workspace.saveAsynchronously()
        XCTAssertTrue(retried)
        XCTAssertFalse(workspace.isDirty)
        workspace.closeDiscardingChanges()
    }

    func testCancellationAfterCommittedBytesStillAcceptsSavedCheckpoint() async throws {
        let fixture = try makeFixture(), committed = AsyncSaveGate()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState(backgroundSaveWriter: { snapshot, request, cancellation in
            let result = try await PDFBackgroundSaveWriter.write(snapshot: snapshot, request: request, cancellation: cancellation)
            await committed.enter()
            return result
        })
        XCTAssertTrue(workspace.open(url: fixture.source))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        let task = Task { await workspace.saveAsynchronously() }
        try await waitForGate(committed)
        workspace.cancelSave()
        await committed.release()
        let saved = await task.value
        XCTAssertTrue(saved)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.isSaving)
        XCTAssertEqual(PDFDocument(url: fixture.source)?.page(at: 0)?.rotation, 90)
        workspace.closeDiscardingChanges()
    }

    func testResetAndReplacementDocumentIgnoreLateCommittedCompletion() async throws {
        let first = try makeFixture(), second = try makeFixture(), committed = AsyncSaveGate()
        defer {
            try? FileManager.default.removeItem(at: first.directory)
            try? FileManager.default.removeItem(at: second.directory)
        }
        let workspace = PDFWorkspaceState(backgroundSaveWriter: { snapshot, request, cancellation in
            let result = try await PDFBackgroundSaveWriter.write(snapshot: snapshot, request: request, cancellation: cancellation)
            await committed.enter()
            return result
        })
        XCTAssertTrue(workspace.open(url: first.source))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        let task = Task { await workspace.saveAsynchronously() }
        try await waitForGate(committed)
        workspace.closeDiscardingChanges()
        XCTAssertTrue(workspace.open(url: second.source))
        let current = workspace.document
        let currentState = workspace.editStateID
        await committed.release()
        let accepted = await task.value
        XCTAssertFalse(accepted)
        XCTAssertTrue(workspace.document === current)
        XCTAssertEqual(workspace.documentURL, second.source)
        XCTAssertEqual(workspace.editStateID, currentState)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.isSaving)
        XCTAssertEqual(workspace.document?.page(at: 0)?.rotation, 0)
        workspace.closeDiscardingChanges()
    }

    func testNormalCloseAndOpenRemainGuardedWhileSaveIsPending() async throws {
        let fixture = try makeFixture(), replacement = try makeFixture(), gate = AsyncSaveGate()
        defer {
            try? FileManager.default.removeItem(at: fixture.directory)
            try? FileManager.default.removeItem(at: replacement.directory)
        }
        let workspace = gatedWorkspace(gate)
        XCTAssertTrue(workspace.open(url: fixture.source))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        let original = workspace.document
        let task = Task { await workspace.saveAsynchronously() }
        try await waitForGate(gate)
        workspace.close()
        XCTAssertTrue(workspace.document === original)
        XCTAssertFalse(workspace.open(url: replacement.source))
        XCTAssertEqual(workspace.documentURL, fixture.source)
        await gate.release()
        let saved = await task.value
        XCTAssertTrue(saved)
        workspace.closeDiscardingChanges()
    }

    func testCancelledCatalogPlanLeavesCallerGraphUntouchedAndClearsThreadContext() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let document = try XCTUnwrap(PDFDocument(url: fixture.source))
        let token = PDFSaveCancellation()
        token.cancel()
        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(token) {
            try PDFCatalogStructurePreserver.plan(for: document)
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertNoThrow(try PDFSaveCancellation.checkCurrent())
        var graph = PDFCatalogGraphPlan()
        graph.catalogEntries["Sentinel"] = .integer(7)
        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(token) {
            try PDFTaggedStructurePreserver.addPreservedTags(from: [], to: &graph)
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(graph.catalogEntries.count, 1)
        XCTAssertTrue(graph.pageEntries.isEmpty)
        XCTAssertNoThrow(try PDFSaveCancellation.checkCurrent())
    }

    func testOptInRealTaggedBookUsesAsyncModelAndRecordsWholeSaveMainActorLatency() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let sourcePath = env["EMBER_ASYNC_TAGGED_PDF"], sourcePath.hasPrefix("/"),
              let outputPath = env["EMBER_ASYNC_SAVE_OUTPUT"], outputPath.hasPrefix("/"),
              let reportPath = env["EMBER_ASYNC_SAVE_REPORT"], reportPath.hasPrefix("/") else {
            throw XCTSkip("Set explicit read-only large tagged source, distinct output, and QA report paths.")
        }
        let source = URL(fileURLWithPath: sourcePath), output = URL(fileURLWithPath: outputPath)
        let reportURL = URL(fileURLWithPath: reportPath)
        guard !PDFSourceFileVersion.refersToSameLocation(source, output),
              !PDFSourceFileVersion.refersToSameLocation(source, reportURL),
              !PDFSourceFileVersion.refersToSameLocation(output, reportURL),
              !FileManager.default.fileExists(atPath: output.path),
              !FileManager.default.fileExists(atPath: reportURL.path) else { throw AsyncSaveTestFailure.unsafePath }
        let (binary, expectedBinarySHA) = try explicitFrozenTestBinary(in: env)
        let before = try PDFSourceFileVersion.capture(at: source)
        let originalSHA = try fingerprint(source)
        let workspace = PDFWorkspaceState()
        defer { workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: source))
        XCTAssertEqual(workspace.pageCount, 357, "Use the explicitly identified full tagged source")
        let initialRotation = try XCTUnwrap(workspace.document?.page(at: 0)).rotation
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        let document = try XCTUnwrap(workspace.document)
        let expectedPageCount = document.pageCount
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let expectedFirstRotation = firstPage.rotation
        XCTAssertEqual(expectedFirstRotation, (initialRotation + 90) % 360)
        XCTAssertTrue(workspace.isDirty)
        let boxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
        let expectedFirstBounds = boxes.map { firstPage.bounds(for: $0) }
        // Do not enumerate/prime all live pages before the measurement. The
        // detached capture itself must pay its page/annotation setup on main.
        let probes = AsyncSaveMainActorProbes()
        probes.start()
        let started = ProcessInfo.processInfo.systemUptime
        let saved = await workspace.saveAsynchronously(as: output)
        let seconds = ProcessInfo.processInfo.systemUptime - started
        try await Task.sleep(nanoseconds: 50_000_000)
        let latency = probes.stop()
        XCTAssertTrue(saved)
        XCTAssertFalse(workspace.isSaving)
        XCTAssertFalse(workspace.isDirty)
        // Read expected values from a separate original reopen only after
        // latency sampling stops. The controlled edit changes rotation alone.
        let pristine = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(pristine.pageCount, expectedPageCount)
        let pages = try (0..<pristine.pageCount).map { try XCTUnwrap(pristine.page(at: $0)) }
        let contents = try pages.map { try PDFBodyTextPageSnapshot.contentData(for: $0) }
        var bounds = pages.map { page in boxes.map { page.bounds(for: $0) } }
        bounds[0] = expectedFirstBounds
        var rotations = pages.map(\.rotation)
        rotations[0] = expectedFirstRotation
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(reopened.pageCount, pages.count)
        for index in pages.indices {
            let page = try XCTUnwrap(reopened.page(at: index))
            XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: page), contents[index], "page \(index)")
            XCTAssertEqual(page.rotation, rotations[index], "page \(index)")
            for (boxIndex, box) in boxes.enumerated() {
                XCTAssertEqual(page.bounds(for: box), bounds[index][boxIndex], "page \(index), box \(boxIndex)")
            }
        }
        XCTAssertEqual(try PDFSourceFileVersion.capture(at: source), before)
        XCTAssertEqual(try fingerprint(source), originalSHA)
        XCTAssertGreaterThan(latency.handled, 5, "Heavy capture and serialization must both be included")
        XCTAssertLessThan(latency.maximumLatency, 2.0, "A multi-second main-actor freeze remains")
        XCTAssertLessThan(latency.p95Latency, 0.25)
        XCTAssertEqual(try fingerprint(binary), expectedBinarySHA)
        let report: [String: Any] = ["build": 86, "source": source.path, "output": output.path,
            "sourceSHA256": originalSHA, "outputSHA256": try fingerprint(output),
            "sourceBytes": before.fileSize, "sourceModificationTime": before.contentModificationDate.timeIntervalSince1970,
            "pageCount": pages.count, "operation": "async ordinary Save Copy after one page rotation",
            "selectedPageIndex": 0, "expectedRotation": rotations.first ?? 0,
            "saveSeconds": seconds, "probeIntervalSeconds": 0.05, "handledMainActorProbes": latency.handled,
            "enqueuedProbes": latency.enqueued, "maximumMainActorLatencySeconds": latency.maximumLatency,
            "p95MainActorLatencySeconds": latency.p95Latency, "snapshotCaptureIncluded": true,
            "compiledTestBinary": binary.path, "compiledTestBinarySHA256": expectedBinarySHA,
            "compiledTestBinarySHA256VerifiedBeforeAndAfter": true,
            "scope": "Source PDF unchanged; native all-page contents/five boxes/rotation checked. Independent tag/navigation/image/raster checks must consume this exact output separately. This is not a GUI/startup measurement."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: reportURL)
        withExtendedLifetime(pages) {}
    }

    func testOptInRealTaggedBookCancellationStopsBeforeOutputCommit() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let sourcePath = env["EMBER_ASYNC_TAGGED_PDF"], sourcePath.hasPrefix("/"),
              let outputPath = env["EMBER_ASYNC_SAVE_OUTPUT"], outputPath.hasPrefix("/") else {
            throw XCTSkip("Set explicit read-only large tagged source and distinct QA output path.")
        }
        let source = URL(fileURLWithPath: sourcePath)
        let output = URL(fileURLWithPath: outputPath).deletingPathExtension().appendingPathExtension("cancelled.pdf")
        guard !PDFSourceFileVersion.refersToSameLocation(source, output),
              !FileManager.default.fileExists(atPath: output.path) else { throw AsyncSaveTestFailure.unsafePath }
        let (binary, expectedBinarySHA) = try explicitFrozenTestBinary(in: env)
        let before = try PDFSourceFileVersion.capture(at: source)
        let originalSHA = try fingerprint(source)
        let workspace = PDFWorkspaceState()
        defer { workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: source))
        XCTAssertEqual(workspace.pageCount, 357, "Use the explicitly identified full tagged source")
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        let started = ProcessInfo.processInfo.systemUptime
        let task = Task { await workspace.saveAsynchronously(as: output) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(workspace.isSaving, "Use the explicitly identified heavy tagged source")
        workspace.cancelSave()
        let saved = await task.value
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertFalse(saved)
        XCTAssertLessThan(elapsed, 10, "Cancellation should not traverse millions of remaining slots")
        XCTAssertFalse(workspace.isSaving)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try PDFSourceFileVersion.capture(at: source), before)
        XCTAssertEqual(try fingerprint(source), originalSHA)
        XCTAssertEqual(try fingerprint(binary), expectedBinarySHA)
        print("ASYNC_TAGGED_CANCEL_SECONDS", elapsed)
    }

    func testOptInCorpusOutputsPassThroughActualAsyncSnapshotWriter() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let manifestPath = env["EMBER_ASYNC_SAVE_CORPUS_MANIFEST"],
              manifestPath.hasPrefix("/") else {
            throw XCTSkip("Set the explicit61-entry selected-page output manifest for async resaving.")
        }
        let (binary, expectedBinarySHA) = try explicitFrozenTestBinary(in: env)
        struct Entry: Decodable { let id: String; let sourcePath: String; let outputPath: String }
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let outputRoot = manifestURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: manifestURL))
        guard entries.count == 61, Set(entries.map(\.id)).count == entries.count,
              Set(entries.map(\.outputPath)).count == entries.count else { throw AsyncSaveTestFailure.unsafePath }
        // Validate the complete batch before writing its first output. No
        // output may alias any of the declared immutable generation inputs.
        let sources = entries.map { URL(fileURLWithPath: $0.sourcePath) }
        let outputs = entries.map { URL(fileURLWithPath: $0.outputPath) }
        for output in outputs {
            guard output.path.hasPrefix("/"), !FileManager.default.fileExists(atPath: output.path),
                  output.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(outputRoot),
                  sources.allSatisfy({ !PDFSourceFileVersion.refersToSameLocation($0, output) }) else {
                throw AsyncSaveTestFailure.unsafePath
            }
        }
        for (index, entry) in entries.enumerated() {
            guard entry.sourcePath.hasPrefix("/") else { throw AsyncSaveTestFailure.unsafePath }
            let source = sources[index], output = outputs[index]
            let before = try PDFSourceFileVersion.capture(at: source)
            let beforeSHA = try fingerprint(source)
            let workspace = PDFWorkspaceState()
            XCTAssertTrue(workspace.open(url: source), entry.id)
            let pageCount = try XCTUnwrap(workspace.document).pageCount
            let saved = await workspace.saveAsynchronously(as: output)
            XCTAssertTrue(saved, "\(entry.id): \(workspace.presentedError ?? "no error")")
            XCTAssertFalse(workspace.isSaving)
            XCTAssertFalse(workspace.isDirty)
            XCTAssertEqual(workspace.documentURL, output)
            XCTAssertEqual(PDFDocument(url: output)?.pageCount, pageCount, entry.id)
            XCTAssertEqual(try PDFSourceFileVersion.capture(at: source), before, entry.id)
            XCTAssertEqual(try fingerprint(source), beforeSHA, entry.id)
            workspace.closeDiscardingChanges()
            print("ASYNC_CORPUS_OUTPUT", entry.id, pageCount, try fingerprint(output))
        }
        XCTAssertEqual(try fingerprint(binary), expectedBinarySHA)
    }

    private func explicitFrozenTestBinary(in environment: [String: String]) throws -> (URL, String) {
        guard let expected = environment["EMBER_ASYNC_EXPECTED_TEST_BINARY_SHA256"], expected.count == 64,
              let binary = Bundle(for: Self.self).executableURL,
              try fingerprint(binary) == expected else { throw AsyncSaveTestFailure.unsafePath }
        return (binary, expected)
    }

    private func gatedWorkspace(_ gate: AsyncSaveGate) -> PDFWorkspaceState {
        PDFWorkspaceState(backgroundSaveWriter: { snapshot, request, cancellation in
            await gate.enter()
            return try await PDFBackgroundSaveWriter.write(snapshot: snapshot, request: request, cancellation: cancellation)
        })
    }

    private func waitForGate(_ gate: AsyncSaveGate) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while await gate.calls == 0, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let calls = await gate.calls
        XCTAssertGreaterThan(calls, 0, "Save never reached its injected writer")
        if calls == 0 { throw AsyncSaveTestFailure.timeout }
    }

    private func makeFixture() throws -> (directory: URL, source: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AsyncPDFSave-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 180, height: 240)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 24, y: 34, width: 48, height: 17))
        context.endPDFPage()
        context.closePDF()
        return (directory, source)
    }

    private func fingerprint(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
}

private enum AsyncSaveTestFailure: Error { case injected, timeout, unsafePath }

private actor AsyncSaveGate {
    private(set) var calls = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        calls += 1
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// The producer does not depend on main. A main-only timer would miss the
/// initial frozen interval by starting its first tick after a long capture.
private final class AsyncSaveMainActorProbes: @unchecked Sendable {
    struct Summary {
        let enqueued: Int
        let handled: Int
        let maximumLatency: TimeInterval
        let p95Latency: TimeInterval
    }
    private let lock = NSLock()
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "AsyncSaveTest.probes"))
    private var enqueued = 0
    private var latencies: [TimeInterval] = []

    func start() {
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let queued = ProcessInfo.processInfo.systemUptime
            self.lock.lock(); self.enqueued += 1; self.lock.unlock()
            DispatchQueue.main.async { [self] in
                let latency = ProcessInfo.processInfo.systemUptime - queued
                self.lock.lock(); self.latencies.append(latency); self.lock.unlock()
            }
        }
        timer.activate()
    }

    func snapshot() -> Summary {
        lock.lock(); let count = enqueued, sorted = latencies.sorted(); lock.unlock()
        let percentile = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        return Summary(enqueued: count, handled: sorted.count, maximumLatency: sorted.last ?? 0, p95Latency: percentile)
    }

    func stop() -> Summary { timer.cancel(); return snapshot() }
    deinit { timer.cancel() }
}
