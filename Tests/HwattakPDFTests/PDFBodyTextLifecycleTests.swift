// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

/// A body draft can fail to fit without ever making the PDF dirty. Lifecycle
/// decisions must retain that input instead of treating the tab as clean.
@MainActor
final class PDFBodyTextLifecycleTests: XCTestCase {
    func testSaveAndSaveCopyRejectUnappliedBodyDraftBeforeDestinationOrNoChangesStatus() throws {
        let url = try makePDF(named: "save")
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        let originalBytes = try Data(contentsOf: url)
        let draft = try makeFailingDraft(in: workspace)
        let document = try XCTUnwrap(workspace.document)
        var choseDestination = false

        XCTAssertFalse(WorkspaceSaveCoordinator.requestSave(workspace: workspace))
        XCTAssertFalse(WorkspaceSaveCoordinator.requestSaveCopy(workspace: workspace))
        XCTAssertEqual(WorkspaceSaveCoordinator.apply(.overwriteOriginal, to: workspace), .cancelled)
        XCTAssertEqual(WorkspaceSaveCoordinator.apply(.saveCopy, to: workspace, copyDestination: {
            choseDestination = true
            return url.deletingLastPathComponent().appendingPathComponent("copy.pdf")
        }), .cancelled)

        XCTAssertFalse(choseDestination)
        XCTAssertTrue(workspace.document === document)
        XCTAssertEqual(workspace.pendingInlineTextEdit?.id, draft.id)
        XCTAssertEqual(workspace.pendingInlineTextEdit?.text, draft.text)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertNotEqual(workspace.statusMessage, L10n.string("status.no_changes_to_save"))
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)

        workspace.cancelPendingInlineText()
        XCTAssertTrue(WorkspaceSaveCoordinator.requestSave(workspace: workspace))
        XCTAssertEqual(workspace.statusMessage, L10n.string("status.no_changes_to_save"))
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    }

    func testWindowAndAppCloseRejectFailedBodyDraftBeforeAnyDiscardOrPersistence() throws {
        for closeDocuments in [true, false] {
            let url = try makePDF(named: "closing-\(closeDocuments)")
            let workspace = PDFWorkspaceState()
            XCTAssertTrue(workspace.open(url: url))
            let draft = try makeFailingDraft(in: workspace)
            let document = try XCTUnwrap(workspace.document)
            var askedToDiscard = false
            var frozeSession = false

            XCTAssertFalse(UnsavedChangesGuard.confirmAndClose(
                workspaces: [workspace, workspace],
                decisionProvider: { _ in
                    askedToDiscard = true
                    return .dontSave
                },
                beforeClosing: { frozeSession = true },
                closeDocuments: closeDocuments
            ))
            XCTAssertFalse(askedToDiscard)
            XCTAssertFalse(frozeSession)
            XCTAssertTrue(workspace.document === document)
            XCTAssertEqual(workspace.pendingInlineTextEdit?.id, draft.id)
            XCTAssertFalse(workspace.isDirty)

            workspace.cancelPendingInlineText()
            XCTAssertTrue(UnsavedChangesGuard.confirmAndClose(
                workspaces: [workspace], decisionProvider: { _ in .cancel },
                closeDocuments: closeDocuments
            ))
            XCTAssertEqual(workspace.document == nil, closeDocuments)
        }
    }

    func testCloseTabKeepsCleanPDFAndFailedDraftUntilEditorIsCancelled() throws {
        let collection = MultiDocumentWorkspaceState()
        let id = try XCTUnwrap(collection.openPDFsInTabs(urls: [try makePDF(named: "tab")]).first)
        let workspace = try XCTUnwrap(collection.activeWorkspace)
        let draft = try makeFailingDraft(in: workspace)

        XCTAssertFalse(collection.closeTab(id))
        XCTAssertEqual(collection.activeTabID, id)
        XCTAssertTrue(collection.tabs.contains(where: { $0.id == id }))
        XCTAssertEqual(workspace.pendingInlineTextEdit?.text, draft.text)
        XCTAssertNotNil(workspace.document)

        workspace.cancelPendingInlineText()
        XCTAssertTrue(collection.closeTab(id))
        XCTAssertFalse(collection.tabs.contains(where: { $0.id == id }))
        XCTAssertNil(workspace.document)
    }

    func testDeletingTabGroupPreflightsFailedDraftBeforeClosingAnyMember() throws {
        let collection = MultiDocumentWorkspaceState()
        let ids = collection.openPDFsInTabs(urls: [
            try makePDF(named: "group-clean"), try makePDF(named: "group-draft")
        ])
        XCTAssertEqual(ids.count, 2)
        let group = try XCTUnwrap(collection.createTabGroup(title: "Body edits", tabIDs: ids))
        let workspace = try XCTUnwrap(collection.activeWorkspace)
        let draft = try makeFailingDraft(in: workspace)
        let originalIDs = collection.tabs.map(\.id)

        XCTAssertFalse(collection.deleteTabGroup(group, keepingTabs: false))
        XCTAssertEqual(collection.tabs.map(\.id), originalIDs)
        XCTAssertTrue(collection.tabs.allSatisfy { $0.workspace.hasOpenDocument })
        XCTAssertNotNil(collection.tabGroups.first(where: { $0.id == group }))
        XCTAssertEqual(workspace.pendingInlineTextEdit?.id, draft.id)

        workspace.cancelPendingInlineText()
        XCTAssertTrue(collection.deleteTabGroup(group, keepingTabs: false))
        XCTAssertTrue(collection.tabs.allSatisfy { !ids.contains($0.id) })
    }

    func testDeletingInactiveWorkspaceKeepsFailedBodyDraftUnlessDiscardExplicit() throws {
        let collection = MultiDocumentWorkspaceState()
        let workspaceID = collection.activeWorkspaceID
        _ = collection.openPDFsInTabs(urls: [try makePDF(named: "workspace")])
        let workspace = try XCTUnwrap(collection.activeWorkspace)
        let draft = try makeFailingDraft(in: workspace)
        let replacementID = collection.createWorkspace(title: "Other workspace")
        XCTAssertEqual(collection.activeWorkspaceID, replacementID)

        XCTAssertFalse(collection.deleteWorkspace(workspaceID))
        XCTAssertEqual(collection.workspaces.count, 2)
        XCTAssertNotNil(workspace.document)
        XCTAssertEqual(workspace.pendingInlineTextEdit?.text, draft.text)
        XCTAssertFalse(workspace.isDirty)

        // This overload represents a discard decision already made by a user.
        XCTAssertTrue(collection.deleteWorkspace(workspaceID, discardingChanges: true))
        XCTAssertEqual(collection.workspaces.count, 1)
        XCTAssertNil(workspace.document)
        XCTAssertNil(workspace.pendingInlineTextEdit)
    }

    private func makeFailingDraft(in workspace: PDFWorkspaceState) throws -> PendingInlineTextEdit {
        workspace.setMode(.editing)
        XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 40, y: 40)))
        let initial = try XCTUnwrap(workspace.pendingInlineTextEdit)
        var style = initial.style
        style.fontSize = 144
        workspace.updatePendingInlineTextDraft(
            id: initial.id,
            text: String(repeating: "Keep this unapplied body text\n", count: 30),
            style: style,
            bounds: initial.bounds
        )
        workspace.prepareForDeactivation()
        let failed = try XCTUnwrap(workspace.pendingInlineTextEdit)
        XCTAssertEqual(failed.id, initial.id)
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        return failed
    }

    private func makePDF(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberPDF-BodyLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 420)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 40, y: 300)
        let text = NSAttributedString(string: "Original body", attributes: [
            .font: NSFont.systemFont(ofSize: 20)
        ])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
        context.closePDF()
        let url = directory.appendingPathComponent("\(name).pdf")
        try (bytes as Data).write(to: url)
        return url
    }
}
