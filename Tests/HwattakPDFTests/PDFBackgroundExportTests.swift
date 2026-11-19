// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Combine
import CryptoKit
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBackgroundExportTests: XCTestCase {
    func testColdCombinedUIExportOwnsOnlySelectedPagesAndKeepsLiveEditsOnMain() async throws {
        let folder = try temporaryFolder(), source = folder.appendingPathComponent("source.pdf")
        let original = fixture(modes: ["absent", "no-popup", "present", "present"])
        try original.write(to: source)
        let entered = expectation(description: "Export worker owns selected copy")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let workspace = PDFWorkspaceState(backgroundExportSession: { document, access in
            XCTAssertEqual(document.pageCount, 3, "Do not transfer a full four-page source.")
            return try PDFBackgroundExportSession(consuming: document, retainingAccess: access, beforeWriting: {
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw TestFailure.timeout }
            })
        })
        XCTAssertTrue(workspace.open(url: source))
        workspace.selectedPages = [2, 0, 1]
        workspace.currentPageIndex = 2
        let live = try XCTUnwrap(workspace.document), ids = live.page(at: 0)!.annotations.map(ObjectIdentifier.init)
        let revision = workspace.revision, state = workspace.editStateID
        let destination = folder.appendingPathComponent("combined.pdf")
        let task = Task { await workspace.exportSelectedPagesAsCombinedPDFAsynchronously(to: destination) }
        await fulfillment(of: [entered], timeout: 8)
        XCTAssertTrue(workspace.isExportingSelectedPages)
        XCTAssertFalse(workspace.canHibernate)
        let heartbeat = expectation(description: "Main actor remains usable while worker is waiting")
        Task { @MainActor in heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 2)
        try XCTUnwrap(live.page(at: 0)?.annotations.first { $0.type == "Text" }).contents = "NEW LIVE EDIT"
        release.signal()
        let saved = await task.value
        XCTAssertTrue(saved, workspace.presentedError ?? "")
        try assertPage(Data(contentsOf: destination), page: 0, contents: "ORIGINAL-0", popup: true, parent: false)
        try assertPage(Data(contentsOf: destination), page: 1, contents: "ORIGINAL-1", popup: false, parent: false)
        try assertPage(Data(contentsOf: destination), page: 2, contents: "ORIGINAL-2", popup: true, parent: true)
        XCTAssertEqual(PDFDocument(url: destination)?.pageCount, 3)
        XCTAssertTrue(workspace.document === live)
        XCTAssertEqual(live.page(at: 0)!.annotations.map(ObjectIdentifier.init), ids)
        XCTAssertEqual(live.page(at: 0)?.annotations.first?.contents, "NEW LIVE EDIT")
        XCTAssertEqual(workspace.selectedPages, [0, 1, 2])
        XCTAssertEqual(workspace.currentPageIndex, 2)
        XCTAssertEqual(workspace.revision, revision)
        XCTAssertEqual(workspace.editStateID, state)
        XCTAssertEqual(workspace.documentURL, source)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(workspace.isExportingSelectedPages)
    }

    func testIndividualUIExportKeepsOriginalNoncontiguousPageNumbersAndExistingFolder() async throws {
        let folder = try temporaryFolder(), source = folder.appendingPathComponent("Lecture.pdf")
        let original = fixture(modes: ["absent", "no-popup", "present"])
        try original.write(to: source)
        let existing = folder.appendingPathComponent("Lecture-selected-pages")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: source)); workspace.selectedPages = [2, 0]
        let state = workspace.editStateID
        let saved = await workspace.exportSelectedPagesAsIndividualPDFsAsynchronously(to: folder)
        XCTAssertTrue(saved, workspace.presentedError ?? "")
        let output = folder.appendingPathComponent("Lecture-selected-pages-2")
        let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.map(\.lastPathComponent), ["Lecture-page-0001.pdf", "Lecture-page-0003.pdf"])
        try assertPage(Data(contentsOf: files[0]), page: 0, contents: "ORIGINAL-0", popup: true, parent: false)
        try assertPage(Data(contentsOf: files[1]), page: 0, contents: "ORIGINAL-2", popup: true, parent: true)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(workspace.selectedPages, [0, 2]); XCTAssertEqual(workspace.editStateID, state)
        XCTAssertFalse(workspace.isDirty)
    }

    func testCombinedWorkerRechecksHardLinkAliasWithoutTouchingOriginal() async throws {
        let folder = try temporaryFolder(), source = folder.appendingPathComponent("source.pdf")
        let bytes = fixture(modes: ["present"]); try bytes.write(to: source)
        let destination = folder.appendingPathComponent("copy.pdf")
        let workspace = PDFWorkspaceState(backgroundExportSession: { document, access in
            try PDFBackgroundExportSession(consuming: document, retainingAccess: access, beforeWriting: {
                XCTAssertFalse(Thread.isMainThread)
                try FileManager.default.linkItem(at: source, to: destination)
            })
        })
        XCTAssertTrue(workspace.open(url: source)); workspace.selectedPages = [0]
        let saved = await workspace.exportSelectedPagesAsCombinedPDFAsynchronously(to: destination)
        XCTAssertFalse(saved); XCTAssertNotNil(workspace.presentedError)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertFalse(workspace.isDirty)
    }

    func testCloseCancelsPendingExportAndCannotPublishAStaleStatus() async throws {
        let folder = try temporaryFolder(), source = folder.appendingPathComponent("source.pdf")
        let original = fixture(modes: ["present"]); try original.write(to: source)
        let destination = folder.appendingPathComponent("cancelled.pdf")
        let entered = expectation(description: "Worker is held before writing")
        let release = DispatchSemaphore(value: 0); defer { release.signal() }
        let workspace = PDFWorkspaceState(backgroundExportSession: { document, access in
            try PDFBackgroundExportSession(consuming: document, retainingAccess: access, beforeWriting: {
                entered.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw TestFailure.timeout }
            })
        })
        XCTAssertTrue(workspace.open(url: source)); workspace.selectedPages = [0]
        let task = Task { await workspace.exportSelectedPagesAsCombinedPDFAsynchronously(to: destination) }
        await fulfillment(of: [entered], timeout: 8)
        workspace.closeDiscardingChanges()
        let statusAfterClose = workspace.statusMessage
        release.signal()
        let saved = await task.value
        XCTAssertFalse(saved); XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNil(workspace.document); XCTAssertNil(workspace.presentedError)
        XCTAssertEqual(workspace.statusMessage, statusAfterClose)
        XCTAssertFalse(workspace.isExportingSelectedPages)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testLanguageChangeKeepsCapturedExportAndDuplicateRequestDoesNotStartAnotherOwner() async throws {
        let folder = try temporaryFolder(), source = folder.appendingPathComponent("source.pdf")
        let original = fixture(modes: ["present"]); try original.write(to: source)
        let previous = UserDefaults.standard.object(forKey: AppPreferences.languageDefaultsKey)
        defer { UserDefaults.standard.set(previous, forKey: AppPreferences.languageDefaultsKey) }
        let entered = expectation(description: "Captured writer")
        let release = DispatchSemaphore(value: 0); defer { release.signal() }
        let workspace = PDFWorkspaceState(backgroundExportSession: { document, access in
            try PDFBackgroundExportSession(consuming: document, retainingAccess: access, beforeWriting: {
                entered.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw TestFailure.timeout }
            })
        })
        XCTAssertTrue(workspace.open(url: source)); workspace.selectedPages = [0]
        let destination = folder.appendingPathComponent("chosen.pdf")
        let task = Task { await workspace.exportSelectedPagesAsCombinedPDFAsynchronously(to: destination) }
        await fulfillment(of: [entered], timeout: 8)
        for language in AppLanguage.allCases {
            UserDefaults.standard.set(language.rawValue, forKey: AppPreferences.languageDefaultsKey)
            workspace.refreshLocalization()
            XCTAssertTrue(workspace.isExportingSelectedPages)
        }
        let duplicate = folder.appendingPathComponent("duplicate.pdf")
        let accepted = await workspace.exportSelectedPagesAsCombinedPDFAsynchronously(to: duplicate)
        XCTAssertFalse(accepted)
        release.signal()
        let completed = await task.value
        XCTAssertTrue(completed)
        XCTAssertEqual(workspace.statusMessage, L10n.format("status.exported_pages_combined", 1, destination.lastPathComponent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testOwnerPermittedEncryptedUIExtractionAndRestrictedUserPolicyRemainSeparate() async throws {
        let folder = try temporaryFolder(), source = folder.appendingPathComponent("encrypted.pdf")
        try encryptedFixture(allowed: false).write(to: source)
        let original = try Data(contentsOf: source)
        let owner = PDFWorkspaceState(passwordProvider: { _, _ in "OwnerExport90" })
        XCTAssertTrue(owner.open(url: source)); owner.selectedPages = [0, 1]
        XCTAssertEqual(owner.document?.permissionsStatus, .owner)
        let allowed = await owner.exportSelectedPagesAsCombinedPDFAsynchronously(to: folder.appendingPathComponent("owner.pdf"))
        XCTAssertTrue(allowed, owner.presentedError ?? "")
        let ownerOutput = try Data(contentsOf: folder.appendingPathComponent("owner.pdf"))
        XCTAssertEqual(PDFDocument(data: ownerOutput)?.pageCount, 2)
        try assertPage(ownerOutput, page: 0, contents: "ORIGINAL-0", popup: true, parent: false)
        try assertPage(ownerOutput, page: 1, contents: "ORIGINAL-1", popup: false, parent: false)
        let user = PDFWorkspaceState(passwordProvider: { _, _ in "ReaderExport90" })
        XCTAssertTrue(user.open(url: source)); user.selectedPages = [0]
        XCTAssertEqual(user.document?.permissionsStatus, .user)
        let blocked = await user.exportSelectedPagesAsCombinedPDFAsynchronously(to: folder.appendingPathComponent("blocked.pdf"))
        XCTAssertFalse(blocked); XCTAssertNotNil(user.presentedError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("blocked.pdf").path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testExportSessionConsumesFinalDocumentOnceAndReusesOnlyPrivatePreview() async throws {
        let folder = try temporaryFolder()
        let document = try XCTUnwrap(PDFDocument(data: fixture(modes: ["no-popup"])))
        PDFRawStreamProvenance.bindCreated(document, data: fixture(modes: ["no-popup"]))
        let session = try PDFBackgroundExportSession(consuming: document, beforeWriting: { XCTAssertFalse(Thread.isMainThread) })
        let preview = folder.appendingPathComponent("preview.pdf"), final = folder.appendingPathComponent("final.pdf")
        _ = try await session.write(to: preview, finishing: false)
        _ = try await session.write(to: final)
        XCTAssertEqual(PDFDocument(url: preview)?.pageCount, 1)
        XCTAssertEqual(PDFDocument(url: final)?.pageCount, 1)
        let duplicate = folder.appendingPathComponent("duplicate.pdf")
        do { _ = try await session.write(to: duplicate); XCTFail("Final ownership was already consumed.") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.path))
    }

    func testUserCopyingAndAssemblyPermissionStillAllowsAsyncSelectedExport() async throws {
        let folder = try temporaryFolder(), source = folder.appendingPathComponent("allowed-user.pdf")
        try encryptedFixture(allowed: true).write(to: source)
        let original = try Data(contentsOf: source)
        let workspace = PDFWorkspaceState(passwordProvider: { _, _ in "ReaderExport90" })
        XCTAssertTrue(workspace.open(url: source)); workspace.selectedPages = [0, 1]
        let sourceDocument = try XCTUnwrap(workspace.document)
        XCTAssertEqual(workspace.document?.permissionsStatus, .user)
        XCTAssertTrue(workspace.document?.allowsCopying == true)
        XCTAssertTrue(workspace.document?.allowsDocumentAssembly == true)
        let destination = folder.appendingPathComponent("allowed.pdf")
        let saved = await workspace.exportSelectedPagesAsCombinedPDFAsynchronously(to: destination)
        XCTAssertTrue(saved, workspace.presentedError ?? "")
        XCTAssertTrue(workspace.document === sourceDocument)
        XCTAssertEqual(sourceDocument.pageCount, 2)
        XCTAssertTrue(sourceDocument.isEncrypted)
        XCTAssertFalse(sourceDocument.isLocked)
        XCTAssertEqual(sourceDocument.permissionsStatus, .user)
        XCTAssertTrue(sourceDocument.allowsCopying)
        XCTAssertTrue(sourceDocument.allowsDocumentAssembly)
        XCTAssertFalse(sourceDocument.allowsCommenting)
        let output = try Data(contentsOf: destination)
        XCTAssertEqual(PDFDocument(data: output)?.pageCount, 2)
        try assertPage(output, page: 0, contents: "ORIGINAL-0", popup: true, parent: false)
        try assertPage(output, page: 1, contents: "ORIGINAL-1", popup: false, parent: false)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(workspace.documentURL, source)
    }

    func testSearchableQueueCancellationKeepsExistingDestinationAndSource() async throws {
        let folder = try temporaryFolder(), source = folder.appendingPathComponent("source.pdf")
        let destination = folder.appendingPathComponent("existing.pdf")
        let bytes = fixture(modes: ["present"]); try bytes.write(to: source); try bytes.write(to: destination)
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        let temporary = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("HwattakPDF-OCRExport-") })
        do {
            try await Task.detached {
                let document = try XCTUnwrap(PDFDocument(data: bytes))
                let checkpoint = OCRCheckpoint(documentFingerprint: "cancel-fixture", pageCount: 1, configurationFingerprint: "cancel-configuration")
                try PDFSaveCancellation.withCurrent(cancellation) {
                    try SearchablePDFExporter.export(document: document, checkpoint: checkpoint,
                        to: destination, sourceURL: source)
                }
            }.value
            XCTFail("The dispatch-thread cancellation must reach the OCR exporter.")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("HwattakPDF-OCRExport-") })
        XCTAssertEqual(after, before, "Cancellation must remove the private OCR staging folder.")
    }

    func testPrivatePreviewThenSearchableExportPreservesUnrecognizedPageRelationships() async throws {
        let folder = try temporaryFolder(), source = folder.appendingPathComponent("source.pdf")
        let original = fixture(modes: ["absent", "no-popup"]); try original.write(to: source)
        let loaded = try PDFSourceFileAccess.loadDocument(at: source).document
        let isolated = try PDFPageOperations.extract(from: loaded, indexes: [0, 1])
        let session = try PDFBackgroundExportSession(consuming: isolated,
            retainingAccess: [SecurityScopedAccess(url: source)], beforeWriting: { XCTAssertFalse(Thread.isMainThread) })
        _ = try await session.write(to: folder.appendingPathComponent("preview.pdf"), finishing: false)
        var checkpoint = OCRCheckpoint(documentFingerprint: "private-ocr", pageCount: 2, configurationFingerprint: "private-configuration")
        for index in 0..<2 {
            checkpoint.pages[index] = OCRPageResult(pageIndex: index, text: "", observations: [],
                completedAt: Date(), skippedBecauseTextExists: true)
        }
        let destination = folder.appendingPathComponent("searchable.pdf")
        _ = try await session.exportSearchable(checkpoint: checkpoint, to: destination, renderDPI: 72,
            protectedSourceURLs: [source], destinationPrecondition: PDFDestinationPrecondition(destination: destination))
        let output = try Data(contentsOf: destination)
        try assertPage(output, page: 0, contents: "ORIGINAL-0", popup: true, parent: false)
        try assertPage(output, page: 1, contents: "ORIGINAL-1", popup: false, parent: false)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testAdmissionBoundsPendingCancelledGraphsUntilRealWorkerCleanup() async throws {
        let folder = try temporaryFolder(), bytes = fixture(modes: ["present"])
        let baseline = PDFBackgroundExportSession.retainedSessionCount
        XCTAssertEqual(baseline, 0)
        let entered = expectation(description: "First writer is active")
        let release = DispatchSemaphore(value: 0); defer { release.signal() }
        let first = try PDFBackgroundExportSession(consuming: XCTUnwrap(PDFDocument(data: bytes)), beforeWriting: {
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw TestFailure.timeout }
        })
        let task = Task { try await first.write(to: folder.appendingPathComponent("first.pdf")) }
        await fulfillment(of: [entered], timeout: 8)
        let second = try PDFBackgroundExportSession(consuming: XCTUnwrap(PDFDocument(data: bytes)))
        second.cancel()
        XCTAssertEqual(PDFBackgroundExportSession.retainedSessionCount, baseline + 2,
            "Cancelling a queued owner cannot release its admission ahead of actual graph cleanup.")
        XCTAssertThrowsError(try PDFBackgroundExportSession(consuming: XCTUnwrap(PDFDocument(data: bytes))))
        release.signal()
        _ = try await task.value
        await second.waitForCompletion()
        XCTAssertEqual(PDFBackgroundExportSession.retainedSessionCount, baseline)
        let retry = try PDFBackgroundExportSession(consuming: XCTUnwrap(PDFDocument(data: bytes)))
        retry.cancel()
        await retry.waitForCompletion()
        XCTAssertEqual(PDFBackgroundExportSession.retainedSessionCount, baseline)
    }

    func testIndividualCancellationCleansOwnedStagingBeforePublishing() async throws {
        let folder = try temporaryFolder(), bytes = fixture(modes: ["present", "present"])
        let cancellation = PDFSaveCancellation()
        let manager = CancellingExportFileManager(cancellation)
        do {
            _ = try await Task.detached {
                let document = try XCTUnwrap(PDFDocument(data: bytes))
                PDFRawStreamProvenance.bindCreated(document, data: bytes)
                return try PDFSaveCancellation.withCurrent(cancellation) {
                    try SelectedPagePDFExporter.exportIndividually(from: document, indexes: [0, 1],
                        to: folder, sourceURL: nil, fileManager: manager)
                }
            }.value
            XCTFail("Cancellation must not publish a completed directory.")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testBuilderKeepsColdOptionalRelationshipsAndRepeatedSourcePagesOnWorker() async throws {
        let folder = try temporaryFolder(), source = folder.appendingPathComponent("source.pdf")
        let original = fixture(modes: ["absent", "no-popup"]); try original.write(to: source)
        let workerEntered = expectation(description: "Builder writer owns assembled PDF")
        let model = ImagePDFAssemblyModel(backgroundExportSession: { document, access in
            XCTAssertEqual(document.pageCount, 3)
            return try PDFBackgroundExportSession(consuming: document, retainingAccess: access, beforeWriting: {
                XCTAssertFalse(Thread.isMainThread); workerEntered.fulfill()
            })
        })
        let selection = try model.preparePDFSelection(source)
        model.addPDFPages(from: selection, indexes: [0, 1])
        model.addPDFPages(from: selection, indexes: [0])
        let destination = folder.appendingPathComponent("builder.pdf")
        model.startExport(to: destination, ocrConfiguration: nil)
        await model.waitForExportCompletion()
        await fulfillment(of: [workerEntered], timeout: 3)
        XCTAssertNil(model.presentedError)
        XCTAssertEqual(model.lastSavedURL, destination)
        XCTAssertEqual(PDFDocument(url: destination)?.pageCount, 3)
        try assertPage(Data(contentsOf: destination), page: 0, contents: "ORIGINAL-0", popup: true, parent: false)
        try assertPage(Data(contentsOf: destination), page: 1, contents: "ORIGINAL-1", popup: false, parent: false)
        try assertPage(Data(contentsOf: destination), page: 2, contents: "ORIGINAL-0", popup: true, parent: false)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testSelectedPageWaitDrainsCancelledQueuedSessionBeforeReturning() async throws {
        let folder = try temporaryFolder(), source = folder.appendingPathComponent("source.pdf")
        let bytes = fixture(modes: ["present"]); try bytes.write(to: source)
        let baseline = PDFBackgroundExportSession.retainedSessionCount
        XCTAssertEqual(baseline, 0)
        let entered = expectation(description: "An earlier writer holds the global queue")
        let release = DispatchSemaphore(value: 0); defer { release.signal() }
        let first = try PDFBackgroundExportSession(consuming: XCTUnwrap(PDFDocument(data: bytes)), beforeWriting: {
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw TestFailure.timeout }
        })
        let firstTask = Task { try await first.write(to: folder.appendingPathComponent("first.pdf")) }
        addTeardownBlock {
            first.cancel(); release.signal()
            _ = try? await firstTask.value
            await first.waitForCompletion()
        }
        await fulfillment(of: [entered], timeout: 8)

        var request: Task<Bool, Never>?
        let workspace = PDFWorkspaceState(backgroundExportSession: { document, access in
            let session = try PDFBackgroundExportSession(consuming: document, retainingAccess: access,
                beforeWriting: { XCTFail("The cancelled queued export must never start writing.") })
            // Cancel the caller before the inner task can enter perform. Its
            // cancellation handler will cancel that task/session immediately.
            request?.cancel()
            return session
        })
        addTeardownBlock {
            first.cancel(); release.signal()
            _ = try? await firstTask.value
            await workspace.waitForSelectedPagePDFExport()
        }
        XCTAssertTrue(workspace.open(url: source)); workspace.selectedPages = [0]
        let destination = folder.appendingPathComponent("cancelled.pdf")
        request = Task { await workspace.exportSelectedPagesAsCombinedPDFAsynchronously(to: destination) }
        let result = await request!.value
        XCTAssertFalse(result)
        XCTAssertFalse(workspace.isExportingSelectedPages)
        XCTAssertEqual(PDFBackgroundExportSession.retainedSessionCount, baseline + 2,
            "Task completion must precede the held queue's actual cleanup in this fixture.")

        let waiting = expectation(description: "Explicit workspace drain has started")
        var returned = false
        let waiter = Task { @MainActor in
            waiting.fulfill()
            await workspace.waitForSelectedPagePDFExport()
            returned = true
        }
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertFalse(returned, "Waiting for a finished UI task alone is not an actual owner cleanup drain.")
        XCTAssertEqual(PDFBackgroundExportSession.retainedSessionCount, baseline + 2)
        first.cancel(); release.signal()
        do { _ = try await firstTask.value; XCTFail("The held owner was cancelled.") }
        catch { XCTAssertTrue(error is CancellationError) }
        await waiter.value
        XCTAssertTrue(returned)
        XCTAssertEqual(PDFBackgroundExportSession.retainedSessionCount, baseline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        await workspace.waitForSelectedPagePDFExport()
    }

    func testBuilderWaitDrainsCancelledQueuedSessionBeforeReturning() async throws {
        let folder = try temporaryFolder(), source = folder.appendingPathComponent("source.pdf")
        let bytes = fixture(modes: ["present"]); try bytes.write(to: source)
        let baseline = PDFBackgroundExportSession.retainedSessionCount
        XCTAssertEqual(baseline, 0)
        let entered = expectation(description: "An earlier writer holds the Builder queue")
        let release = DispatchSemaphore(value: 0); defer { release.signal() }
        let first = try PDFBackgroundExportSession(consuming: XCTUnwrap(PDFDocument(data: bytes)), beforeWriting: {
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw TestFailure.timeout }
        })
        let firstTask = Task { try await first.write(to: folder.appendingPathComponent("first.pdf")) }
        addTeardownBlock {
            first.cancel(); release.signal()
            _ = try? await firstTask.value
            await first.waitForCompletion()
        }
        await fulfillment(of: [entered], timeout: 8)

        let admitted = expectation(description: "Builder cancels its task before entering the worker")
        weak var activeModel: ImagePDFAssemblyModel?
        let model = ImagePDFAssemblyModel(backgroundExportSession: { document, access in
            let session = try PDFBackgroundExportSession(consuming: document, retainingAccess: access,
                beforeWriting: { XCTFail("The cancelled queued Builder must never start writing.") })
            activeModel?.cancelExport()
            admitted.fulfill()
            return session
        })
        activeModel = model
        let uiCompleted = expectation(description: "Cancelled Builder task has published its completion")
        let completion = model.$isProcessing.dropFirst().filter { !$0 }.first().sink { _ in
            uiCompleted.fulfill()
        }
        defer { completion.cancel() }
        addTeardownBlock {
            first.cancel(); release.signal()
            _ = try? await firstTask.value
            await model.waitForExportCompletion()
        }
        model.addPDFPages(from: try model.preparePDFSelection(source), indexes: [0])
        let destination = folder.appendingPathComponent("cancelled-builder.pdf")
        model.startExport(to: destination, ocrConfiguration: nil)
        await fulfillment(of: [admitted, uiCompleted], timeout: 5)
        XCTAssertFalse(model.isProcessing)
        XCTAssertEqual(PDFBackgroundExportSession.retainedSessionCount, baseline + 2)
        let waiting = expectation(description: "Explicit Builder drain has started")
        var returned = false
        let waiter = Task { @MainActor in
            waiting.fulfill()
            await model.waitForExportCompletion()
            returned = true
        }
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertFalse(returned, "Builder must retain and drain the queued owner after its UI task terminates.")
        XCTAssertEqual(PDFBackgroundExportSession.retainedSessionCount, baseline + 2)
        first.cancel(); release.signal()
        do { _ = try await firstTask.value; XCTFail("The held owner was cancelled.") }
        catch { XCTAssertTrue(error is CancellationError) }
        await waiter.value
        XCTAssertTrue(returned)
        XCTAssertEqual(PDFBackgroundExportSession.retainedSessionCount, baseline)
        XCTAssertNil(model.lastSavedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        await model.waitForExportCompletion()
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-background-export-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func assertPage(_ bytes: Data, page index: Int, contents: String, popup: Bool, parent: Bool,
                            password: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let unlockedReader: PDFDocument?
        let native: CGPDFDocument
        if let password {
            let reader = try XCTUnwrap(PDFDocument(data: bytes))
            XCTAssertTrue(reader.unlock(withPassword: password), file: file, line: line)
            native = try XCTUnwrap(reader.documentRef)
            unlockedReader = reader
        } else {
            native = try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: bytes as CFData))))
            unlockedReader = nil
        }
        let page = try XCTUnwrap(native.page(at: index + 1)?.dictionary)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
        XCTAssertEqual(CGPDFArrayGetCount(list), popup ? 2 : 1, file: file, line: line)
        var note: CGPDFDictionaryRef?, popupDictionary: CGPDFDictionaryRef?, text: CGPDFStringRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &note), file: file, line: line)
        let n = try XCTUnwrap(note)
        XCTAssertTrue(CGPDFDictionaryGetString(n, "Contents", &text), file: file, line: line)
        XCTAssertEqual(CGPDFStringCopyTextString(try XCTUnwrap(text)) as String?, contents, file: file, line: line)
        if popup {
            XCTAssertTrue(CGPDFArrayGetDictionary(list, 1, &popupDictionary), file: file, line: line)
            let p = try XCTUnwrap(popupDictionary)
            XCTAssertEqual(PDFCatalogStructurePreserver.dictionary(n, "Popup").map(pdfReferenceIdentity), pdfReferenceIdentity(p), file: file, line: line)
            if parent { XCTAssertEqual(PDFCatalogStructurePreserver.dictionary(p, "Parent").map(pdfReferenceIdentity), pdfReferenceIdentity(n), file: file, line: line) }
            else { XCTAssertNil(PDFCatalogStructurePreserver.object(p, "Parent"), file: file, line: line) }
        } else { XCTAssertNil(PDFCatalogStructurePreserver.object(n, "Popup"), file: file, line: line) }
        withExtendedLifetime((native, unlockedReader)) {}
    }

    /// These two owned fixtures were encrypted losslessly with qpdf12.4.1,
    /// not PDFKit (whose encryption write normalizes Popup/Parent first).
    /// Independent decrypted raw-key/ref proof: fixture-proof.json SHA
    /// b4d6e626af2d9d9793867b906e32b2c003cbbd2d96f3ca5ed8bbb17e663c9292.
    private func encryptedFixture(allowed: Bool) throws -> Data {
        let encoded: String
        let expectedSHA: String
        if allowed {
            expectedSHA = "5f87dfab71f1297192b26801706b82dc0df9428d3ff60081a06c5714ac0a3d65"
            encoded = """
            JVBERi0xLjcKJb/3ov4KMSAwIG9iago8PCAvUGFnZXMgMiAwIFIgL1R5cGUgL0NhdGFsb2cgPj4KZW5kb2JqCjIgMCBvYmoKPDwg
            L0NvdW50IDIgL0tpZHMgWyAzIDAgUiA0IDAgUiBdIC9UeXBlIC9QYWdlcyA+PgplbmRvYmoKMyAwIG9iago8PCAvQW5ub3RzIFsg
            NSAwIFIgNiAwIFIgXSAvTWVkaWFCb3ggWyAwIDAgMjIwIDIyMCBdIC9QYXJlbnQgMiAwIFIgL1Jlc291cmNlcyA8PCA+PiAvVHlw
            ZSAvUGFnZSA+PgplbmRvYmoKNCAwIG9iago8PCAvQW5ub3RzIFsgNyAwIFIgXSAvTWVkaWFCb3ggWyAwIDAgMjIwIDIyMCBdIC9Q
            YXJlbnQgMiAwIFIgL1Jlc291cmNlcyA8PCA+PiAvVHlwZSAvUGFnZSA+PgplbmRvYmoKNSAwIG9iago8PCAvQ29udGVudHMgPDU5
            ZWQwMDJhZmE1OWE5YjgwNTg1NWY1ODZiNjY5ZmUxMmMxNDc2NGNkNTIxZmViZTM2NzYwMzAyNTA0NWFhYjk+IC9GIDQgL1BvcHVw
            IDYgMCBSIC9SZWN0IFsgMTAgMTAgMzAgMzAgXSAvU3VidHlwZSAvVGV4dCAvVHlwZSAvQW5ub3QgPj4KZW5kb2JqCjYgMCBvYmoK
            PDwgL1JlY3QgWyA0MCA0MCA5MCA5MCBdIC9TdWJ0eXBlIC9Qb3B1cCAvVHlwZSAvQW5ub3QgPj4KZW5kb2JqCjcgMCBvYmoKPDwg
            L0NvbnRlbnRzIDwwMWVmOTkzYjRkM2MyNzA3ZTJlZDU1NGU1NTM2YmE5YjEyMGIyYjMwZWIwODVlNmY0Y2M4Y2JiNDA5ODQwNGRh
            PiAvRiA0IC9SZWN0IFsgMTAgMTAgMzAgMzAgXSAvU3VidHlwZSAvVGV4dCAvVHlwZSAvQW5ub3QgPj4KZW5kb2JqCjggMCBvYmoK
            PDwgL0NGIDw8IC9TdGRDRiA8PCAvQXV0aEV2ZW50IC9Eb2NPcGVuIC9DRk0gL0FFU1YyIC9MZW5ndGggMTYgPj4gPj4gL0ZpbHRl
            ciAvU3RhbmRhcmQgL0xlbmd0aCAxMjggL08gPGU3ZDc3ZGE1OWZhZGVjNTk4ZDhmZDM3M2RkZDgyZTg4M2ZkMWU1YjlmMWU4YTQy
            OWNkZGI3YTZiMDMyZmYxM2M+IC9PRSA8PiAvUCAtMjM1MiAvUiA0IC9TdG1GIC9TdGRDRiAvU3RyRiAvU3RkQ0YgL1UgPGQ0Mzcz
            OTVhNjRmYWMwZGYyN2NiNDgwYTA5NGY4NzBhMDAyMTQ0Njk5MGI5ZTQxMTQwNzFhNGQ5MTA0OTg0YzE+IC9VRSA8PiAvViA0ID4+
            CmVuZG9iagp4cmVmCjAgOQowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMTUgMDAwMDAgbiAKMDAwMDAwMDA2NCAwMDAwMCBu
            IAowMDAwMDAwMTI5IDAwMDAwIG4gCjAwMDAwMDAyNDMgMDAwMDAgbiAKMDAwMDAwMDM1MSAwMDAwMCBuIAowMDAwMDAwNTE3IDAw
            MDAwIG4gCjAwMDAwMDA1ODkgMDAwMDAgbiAKMDAwMDAwMDc0MiAwMDAwMCBuIAp0cmFpbGVyIDw8IC9Sb290IDEgMCBSIC9TaXpl
            IDkgL0lEIFs8ODllYmU0NDk0MGQ5MGZhNmIyMDExYjcwNTFiYmJjYzY+PDg5ZWJlNDQ5NDBkOTBmYTZiMjAxMWI3MDUxYmJiY2M2
            Pl0gL0VuY3J5cHQgOCAwIFIgPj4Kc3RhcnR4cmVmCjEwNTgKJSVFT0YK
            """
        } else {
            expectedSHA = "2437c6b1da6bc5e8ad7452673ba2c903e1a6f0332d9f38a57dc7eb6ec4ffb473"
            encoded = """
            JVBERi0xLjcKJb/3ov4KMSAwIG9iago8PCAvUGFnZXMgMiAwIFIgL1R5cGUgL0NhdGFsb2cgPj4KZW5kb2JqCjIgMCBvYmoKPDwg
            L0NvdW50IDIgL0tpZHMgWyAzIDAgUiA0IDAgUiBdIC9UeXBlIC9QYWdlcyA+PgplbmRvYmoKMyAwIG9iago8PCAvQW5ub3RzIFsg
            NSAwIFIgNiAwIFIgXSAvTWVkaWFCb3ggWyAwIDAgMjIwIDIyMCBdIC9QYXJlbnQgMiAwIFIgL1Jlc291cmNlcyA8PCA+PiAvVHlw
            ZSAvUGFnZSA+PgplbmRvYmoKNCAwIG9iago8PCAvQW5ub3RzIFsgNyAwIFIgXSAvTWVkaWFCb3ggWyAwIDAgMjIwIDIyMCBdIC9Q
            YXJlbnQgMiAwIFIgL1Jlc291cmNlcyA8PCA+PiAvVHlwZSAvUGFnZSA+PgplbmRvYmoKNSAwIG9iago8PCAvQ29udGVudHMgPDFl
            NmIxMzc3MzI5NTM5Y2U2ZjY4OTMwYWM1ODVkMmNjMmQwOTc2NzE0OTQ2YWFmNzRlNjI3OGE5MDY5MWFjNGI+IC9GIDQgL1BvcHVw
            IDYgMCBSIC9SZWN0IFsgMTAgMTAgMzAgMzAgXSAvU3VidHlwZSAvVGV4dCAvVHlwZSAvQW5ub3QgPj4KZW5kb2JqCjYgMCBvYmoK
            PDwgL1JlY3QgWyA0MCA0MCA5MCA5MCBdIC9TdWJ0eXBlIC9Qb3B1cCAvVHlwZSAvQW5ub3QgPj4KZW5kb2JqCjcgMCBvYmoKPDwg
            L0NvbnRlbnRzIDxiYmYxYjI0OWE3YTZiNTRhZTRkOTdmMDFjMzAyZThkYzIxYjZkY2I2Y2Q2M2E0YWI1NDZlMzg2NTQ3OTk4ZWY1
            PiAvRiA0IC9SZWN0IFsgMTAgMTAgMzAgMzAgXSAvU3VidHlwZSAvVGV4dCAvVHlwZSAvQW5ub3QgPj4KZW5kb2JqCjggMCBvYmoK
            PDwgL0NGIDw8IC9TdGRDRiA8PCAvQXV0aEV2ZW50IC9Eb2NPcGVuIC9DRk0gL0FFU1YyIC9MZW5ndGggMTYgPj4gPj4gL0ZpbHRl
            ciAvU3RhbmRhcmQgL0xlbmd0aCAxMjggL08gPGU3ZDc3ZGE1OWZhZGVjNTk4ZDhmZDM3M2RkZDgyZTg4M2ZkMWU1YjlmMWU4YTQy
            OWNkZGI3YTZiMDMyZmYxM2M+IC9PRSA8PiAvUCAtMzM5MiAvUiA0IC9TdG1GIC9TdGRDRiAvU3RyRiAvU3RkQ0YgL1UgPDNkZWEy
            NWM3MWNjZWNmNjZhZmNmMjkwNDU1YjQxNzE3MDAyMTQ0Njk5MGI5ZTQxMTQwNzFhNGQ5MTA0OTg0YzE+IC9VRSA8PiAvViA0ID4+
            CmVuZG9iagp4cmVmCjAgOQowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMTUgMDAwMDAgbiAKMDAwMDAwMDA2NCAwMDAwMCBu
            IAowMDAwMDAwMTI5IDAwMDAwIG4gCjAwMDAwMDAyNDMgMDAwMDAgbiAKMDAwMDAwMDM1MSAwMDAwMCBuIAowMDAwMDAwNTE3IDAw
            MDAwIG4gCjAwMDAwMDA1ODkgMDAwMDAgbiAKMDAwMDAwMDc0MiAwMDAwMCBuIAp0cmFpbGVyIDw8IC9Sb290IDEgMCBSIC9TaXpl
            IDkgL0lEIFs8MTZlNzhiMDkyMjY1MWRlOTBiNGNhM2NkNWFlMGU0YWU+PDE2ZTc4YjA5MjI2NTFkZTkwYjRjYTNjZDVhZTBlNGFl
            Pl0gL0VuY3J5cHQgOCAwIFIgPj4Kc3RhcnR4cmVmCjEwNTgKJSVFT0YK
            """
        }
        let bytes = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), expectedSHA)
        try assertPage(bytes, page: 0, contents: "ORIGINAL-0", popup: true, parent: false, password: "OwnerExport90")
        try assertPage(bytes, page: 1, contents: "ORIGINAL-1", popup: false, parent: false, password: "OwnerExport90")
        return bytes
    }

    private func fixture(modes: [String]) -> Data {
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", ""]
        var pages: [Int] = []
        for (index, mode) in modes.enumerated() {
            let page = objects.count + 1, note = page + 1, popup = page + 2
            pages.append(page)
            let hasPopup = mode != "no-popup"
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << >> /Annots [\(note) 0 R\(hasPopup ? " \(popup) 0 R" : "")] >>")
            objects.append("<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /F 4 /Contents (ORIGINAL-\(index))\(hasPopup ? " /Popup \(popup) 0 R" : "") >>")
            if hasPopup { objects.append("<< /Type /Annot /Subtype /Popup /Rect [40 40 90 90]\(mode == "present" ? " /Parent \(note) 0 R" : "") >>") }
        }
        objects[1] = "<< /Type /Pages /Kids [\(pages.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>"
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    private enum TestFailure: Error { case timeout }
}

private final class CancellingExportFileManager: FileManager, @unchecked Sendable {
    let cancellation: PDFSaveCancellation
    init(_ cancellation: PDFSaveCancellation) { self.cancellation = cancellation; super.init() }
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        if url.lastPathComponent.hasPrefix(".HwattakPDF-selected-pages-") { cancellation.cancel() }
    }
}
