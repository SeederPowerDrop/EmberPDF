// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class AsyncWorkspaceSaveCoordinatorTests: XCTestCase {
    func testCleanSaveDoesNotQueueWriterOrRewriteFile() throws {
        let gate = SaveGate()
        let fixture = try makeWorkspace(gate: gate)
        let original = try Data(contentsOf: fixture.url)

        XCTAssertTrue(WorkspaceSaveCoordinator.requestSave(workspace: fixture.workspace))

        XCTAssertFalse(WorkspaceSaveCoordinator.hasPendingSave(workspace: fixture.workspace))
        XCTAssertFalse(fixture.workspace.isSaving)
        XCTAssertEqual(gate.calls, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
    }

    func testQueuedRequestRejectsDuplicateBeforeWorkerStartsAndKeepsMainActorAvailable() async throws {
        let entered = expectation(description: "save writer entered")
        let gate = SaveGate(entered: entered)
        let fixture = try makeWorkspace(gate: gate)
        let workspace = fixture.workspace
        workspace.rotateSelectedPages(clockwise: true)
        defer { gate.release(); workspace.cancelSave() }

        XCTAssertTrue(WorkspaceSaveCoordinator.requestSave(
            workspace: workspace, decisionProvider: { _ in .overwriteOriginal }
        ))
        XCTAssertFalse(WorkspaceSaveCoordinator.requestSave(
            workspace: workspace, decisionProvider: { _ in XCTFail("duplicate decision"); return .cancel }
        ))
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(workspace.isSaving)
        XCTAssertTrue(workspace.isDirty)
        let heartbeat = await Task { @MainActor in UUID() }.value
        XCTAssertNotNil(heartbeat)
        XCTAssertEqual(PDFDocument(url: fixture.url)?.page(at: 0)?.rotation, 0)

        gate.release()
        await WorkspaceSaveCoordinator.waitForPendingSave(workspace: workspace)

        XCTAssertEqual(gate.calls, 1)
        XCTAssertFalse(workspace.isSaving)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertTrue(workspace.canUndo)
        XCTAssertEqual(PDFDocument(url: fixture.url)?.page(at: 0)?.rotation, 90)
    }

    func testCloseAwaitsExistingSaveWithoutAnotherDecisionOrEarlyTeardown() async throws {
        let entered = expectation(description: "save writer entered")
        let closeStarted = expectation(description: "close started")
        let gate = SaveGate(entered: entered)
        let fixture = try makeWorkspace(gate: gate)
        let workspace = fixture.workspace
        workspace.rotateSelectedPages(clockwise: true)
        defer { gate.release(); workspace.cancelSave() }
        let save = Task { await workspace.saveAsynchronously() }
        await fulfillment(of: [entered], timeout: 5)
        var decisions = 0
        var frozeSession = false
        let close = Task { @MainActor in
            closeStarted.fulfill()
            return await UnsavedChangesGuard.confirmAndCloseAsync(
                workspaces: [workspace],
                decisionProvider: { _ in decisions += 1; return .cancel },
                beforeClosing: { frozeSession = true }
            )
        }
        await fulfillment(of: [closeStarted], timeout: 5)
        XCTAssertNotNil(workspace.document)
        XCTAssertFalse(frozeSession)
        XCTAssertEqual(decisions, 0)

        gate.release()
        let saved = await save.value
        let closed = await close.value

        XCTAssertTrue(saved)
        XCTAssertTrue(closed)
        XCTAssertTrue(frozeSession)
        XCTAssertNil(workspace.document)
        XCTAssertEqual(decisions, 0)
    }

    func testNewEditsDuringExistingSaveKeepDocumentOpenAndDirty() async throws {
        let entered = expectation(description: "save writer entered")
        let closeStarted = expectation(description: "close started")
        let gate = SaveGate(entered: entered)
        let fixture = try makeWorkspace(gate: gate)
        let workspace = fixture.workspace
        workspace.rotateSelectedPages(clockwise: true)
        let document = try XCTUnwrap(workspace.document)
        defer { gate.release(); workspace.cancelSave() }
        let save = Task { await workspace.saveAsynchronously() }
        await fulfillment(of: [entered], timeout: 5)
        var frozeSession = false
        let close = Task { @MainActor in
            closeStarted.fulfill()
            return await UnsavedChangesGuard.confirmAndCloseAsync(
                workspaces: [workspace], decisionProvider: { _ in XCTFail("must await existing save"); return .cancel },
                beforeClosing: { frozeSession = true }
            )
        }
        await fulfillment(of: [closeStarted], timeout: 5)
        workspace.rotateSelectedPages(clockwise: true)

        gate.release()
        let saved = await save.value
        let closed = await close.value

        XCTAssertTrue(saved)
        XCTAssertFalse(closed)
        XCTAssertFalse(frozeSession)
        XCTAssertTrue(workspace.document === document)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(workspace.document?.page(at: 0)?.rotation, 180)
        XCTAssertEqual(PDFDocument(url: fixture.url)?.page(at: 0)?.rotation, 90)
    }

    func testFreshReviewDraftDuringSavePreventsCloseWithoutImplicitApply() async throws {
        let entered = expectation(description: "save writer entered")
        let gate = SaveGate(entered: entered)
        let fixture = try makeWorkspace(gate: gate)
        let workspace = fixture.workspace
        workspace.rotateSelectedPages(clockwise: true)
        defer { gate.release(); workspace.cancelSave() }
        let close = Task { await UnsavedChangesGuard.confirmAndCloseAsync(
            workspaces: [workspace], decisionProvider: { _ in .overwriteOriginal }
        ) }
        await fulfillment(of: [entered], timeout: 5)
        workspace.setMode(.study)
        workspace.addStudyNote()
        let draft = try XCTUnwrap(workspace.pendingTextEdit)
        workspace.updatePendingTextDraft(id: draft.id, text: "Keep this review draft")
        gate.release()
        let closed = await close.value

        XCTAssertFalse(closed)
        XCTAssertNotNil(workspace.document)
        XCTAssertEqual(workspace.pendingTextEdit?.id, draft.id)
        XCTAssertEqual(workspace.pendingTextEdit?.initialText, "Keep this review draft")
        XCTAssertTrue(workspace.document?.page(at: 0)?.annotations.isEmpty == true)
    }

    func testEarlierDontSaveEditedWhileLaterSaveWaitsIsNeverDiscarded() async throws {
        let entered = expectation(description: "second save writer entered")
        let gate = SaveGate(entered: entered)
        let first = try makeWorkspace().workspace
        let secondFixture = try makeWorkspace(gate: gate)
        let second = secondFixture.workspace
        first.rotateSelectedPages(clockwise: true)
        second.rotateSelectedPages(clockwise: true)
        defer { gate.release(); second.cancelSave() }
        var frozeSession = false
        let close = Task { await UnsavedChangesGuard.confirmAndCloseAsync(
            workspaces: [first, second], decisionProvider: { $0 === first ? .dontSave : .overwriteOriginal },
            beforeClosing: { frozeSession = true }
        ) }
        await fulfillment(of: [entered], timeout: 5)
        first.rotateSelectedPages(clockwise: true)
        gate.release()
        let closed = await close.value

        XCTAssertFalse(closed)
        XCTAssertFalse(frozeSession)
        XCTAssertNotNil(first.document)
        XCTAssertNotNil(second.document)
        XCTAssertTrue(first.isDirty)
        XCTAssertFalse(second.isDirty)
        XCTAssertEqual(first.document?.page(at: 0)?.rotation, 180)
    }

    func testNoteChangedDuringLaterPDFSaveRetainsTextAndDefersAllDiscards() async throws {
        let entered = expectation(description: "second save writer entered")
        let gate = SaveGate(entered: entered)
        let first = try makeWorkspace().workspace
        let second = try makeWorkspace(gate: gate).workspace
        first.pluginNotesSession.updateText("Earlier note")
        second.rotateSelectedPages(clockwise: true)
        defer { gate.release(); second.cancelSave() }
        let close = Task { await UnsavedChangesGuard.confirmAndCloseAsync(
            workspaces: [first, second], decisionProvider: { _ in .overwriteOriginal },
            notesDecisionProvider: { _ in .discard }
        ) }
        await fulfillment(of: [entered], timeout: 5)
        first.pluginNotesSession.updateText("New note entered while saving")
        gate.release()
        let closed = await close.value

        XCTAssertFalse(closed)
        XCTAssertEqual(first.pluginNotesSession.text, "New note entered while saving")
        XCTAssertTrue(first.pluginNotesSession.isModified)
        XCTAssertNotNil(first.document)
        XCTAssertNotNil(second.document)
    }

    func testCloseScopeChangeIsCheckedBeforeAnyDiscardOrSessionFreeze() async throws {
        let entered = expectation(description: "second save writer entered")
        let gate = SaveGate(entered: entered)
        let first = try makeWorkspace().workspace
        let second = try makeWorkspace(gate: gate).workspace
        first.rotateSelectedPages(clockwise: true)
        second.rotateSelectedPages(clockwise: true)
        defer { gate.release(); second.cancelSave() }
        var scopeMatches = true
        var frozeSession = false
        let close = Task { await UnsavedChangesGuard.confirmAndCloseAsync(
            workspaces: [first, second], decisionProvider: { $0 === first ? .dontSave : .overwriteOriginal },
            validateBeforeClosing: { scopeMatches }, beforeClosing: { frozeSession = true }
        ) }
        await fulfillment(of: [entered], timeout: 5)
        scopeMatches = false
        gate.release()
        let closed = await close.value

        XCTAssertFalse(closed)
        XCTAssertFalse(frozeSession)
        XCTAssertTrue(first.isDirty)
        XCTAssertNotNil(first.document)
        XCTAssertNotNil(second.document)
    }

    func testLocalizationRefreshDuringSaveDoesNotInvalidateContentCheckpoint() async throws {
        let entered = expectation(description: "save writer entered")
        let gate = SaveGate(entered: entered)
        let workspace = try makeWorkspace(gate: gate).workspace
        workspace.rotateSelectedPages(clockwise: true)
        let checkpoint = workspace.editStateID
        defer { gate.release(); workspace.cancelSave() }
        let close = Task { await UnsavedChangesGuard.confirmAndCloseAsync(
            workspaces: [workspace], decisionProvider: { _ in .overwriteOriginal }
        ) }
        await fulfillment(of: [entered], timeout: 5)
        workspace.refreshLocalization()
        XCTAssertEqual(workspace.editStateID, checkpoint)
        gate.release()
        let closed = await close.value

        XCTAssertTrue(closed)
        XCTAssertNil(workspace.document)
    }

    func testPDFOpenedInInitiallyEmptyTargetDuringSaveIsNeverSilentlyClosed() async throws {
        for emptyFirst in [true, false] {
            let entered = expectation(description: "save entered with emptyFirst=\(emptyFirst)")
            let gate = SaveGate(entered: entered)
            let empty = PDFWorkspaceState()
            let saving = try makeWorkspace(gate: gate).workspace
            let replacement = try makeWorkspace()
            saving.rotateSelectedPages(clockwise: true)
            defer { gate.release(); saving.cancelSave() }
            var frozeSession = false
            let targets = emptyFirst ? [empty, saving] : [saving, empty]
            let close = Task { await UnsavedChangesGuard.confirmAndCloseAsync(
                workspaces: targets,
                decisionProvider: { workspace in
                    XCTAssertTrue(workspace === saving, "The newly opened PDF was not part of the close decision.")
                    return .overwriteOriginal
                },
                beforeClosing: { frozeSession = true }
            ) }
            await fulfillment(of: [entered], timeout: 5)
            XCTAssertTrue(empty.open(url: replacement.url))
            empty.setMode(.editing)
            empty.rotateSelectedPages(clockwise: true)
            let newlyOpened = try XCTUnwrap(empty.document)
            gate.release()
            let closed = await close.value

            XCTAssertFalse(closed)
            XCTAssertFalse(frozeSession)
            XCTAssertTrue(empty.document === newlyOpened)
            XCTAssertTrue(empty.isDirty)
            XCTAssertNotNil(saving.document)
            XCTAssertFalse(saving.isDirty)
            XCTAssertEqual(PDFDocument(url: replacement.url)?.page(at: 0)?.rotation, 0)
        }
    }

    func testFailedLaterSaveKeepsEarlierDontSaveDocumentDirtyAndLive() async throws {
        let entered = expectation(description: "second save writer entered")
        let gate = SaveGate(entered: entered)
        let first = try makeWorkspace().workspace
        let second = try makeWorkspace(gate: gate, failSave: true).workspace
        first.rotateSelectedPages(clockwise: true)
        second.rotateSelectedPages(clockwise: true)
        defer { gate.release(); second.cancelSave() }
        var frozeSession = false
        let close = Task { await UnsavedChangesGuard.confirmAndCloseAsync(
            workspaces: [first, second], decisionProvider: { $0 === first ? .dontSave : .overwriteOriginal },
            beforeClosing: { frozeSession = true }
        ) }
        await fulfillment(of: [entered], timeout: 5)
        gate.release()
        let closed = await close.value

        XCTAssertFalse(closed)
        XCTAssertFalse(frozeSession)
        XCTAssertTrue(first.isDirty)
        XCTAssertTrue(second.isDirty)
        XCTAssertNotNil(first.document)
        XCTAssertNotNil(second.document)
        XCTAssertNotNil(second.presentedError)
        XCTAssertFalse(second.isSaving)
    }

    func testCancelledCopyDoesNotQueueWriterOrChangeOriginalAssociation() async throws {
        let gate = SaveGate()
        let fixture = try makeWorkspace(gate: gate)
        fixture.workspace.rotateSelectedPages(clockwise: true)
        let outcome = await WorkspaceSaveCoordinator.applyAsync(
            .saveCopy, to: fixture.workspace, copyDestination: { nil }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(gate.calls, 0)
        XCTAssertTrue(fixture.workspace.isDirty)
        XCTAssertEqual(fixture.workspace.documentURL, fixture.url)
        XCTAssertFalse(fixture.workspace.isSaving)
    }

    private func makeWorkspace(gate: SaveGate? = nil, failSave: Bool = false) throws -> (workspace: PDFWorkspaceState, url: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AsyncSaveCoordinator-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("original.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 180, height: 240)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let workspace = PDFWorkspaceState(backgroundSaveWriter: { snapshot, request, cancellation in
            if let gate { await gate.wait() }
            if failSave { throw NSError(domain: "AsyncSaveCoordinator", code: 1) }
            return try await PDFBackgroundSaveWriter.write(snapshot: snapshot, request: request, cancellation: cancellation)
        })
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.editing)
        return (workspace, url)
    }

    @MainActor
    private final class SaveGate {
        private let entered: XCTestExpectation?
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var calls = 0

        init(entered: XCTestExpectation? = nil) { self.entered = entered }

        func wait() async {
            calls += 1
            entered?.fulfill()
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }
}
