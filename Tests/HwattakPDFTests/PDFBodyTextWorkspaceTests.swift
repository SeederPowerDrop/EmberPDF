// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextWorkspaceTests: XCTestCase {
    func testOptInTaggedKoreanGlyphCorrectionAndReverseEditPreservePageContents() async throws {
        guard let path = ProcessInfo.processInfo.environment["EMBER_TAGGED_KOREAN_EDIT_PDF"] else {
            throw XCTSkip("Set EMBER_TAGGED_KOREAN_EDIT_PDF to the read-only Korean technical QA input.")
        }
        let input = URL(fileURLWithPath: path)
        let inputBytes = try Data(contentsOf: input)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let workspace = PDFWorkspaceState()
        defer {
            workspace.closeDiscardingChanges()
            try? FileManager.default.removeItem(at: output)
        }
        XCTAssertTrue(workspace.open(url: input))
        let originalDocument = try XCTUnwrap(workspace.document)
        let originalPage = try XCTUnwrap(originalDocument.page(at: 3))
        let originalString = try XCTUnwrap(originalPage.string)
        let originalContent = try (0..<originalDocument.pageCount).map {
            try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(originalDocument.page(at: $0)))
        }
        var targetBounds: CGRect?
        for (index, pair) in [("탐색", "검색"), ("검색", "탐색")].enumerated() {
            let (before, after) = pair
            workspace.setMode(.editing)
            let document = try XCTUnwrap(workspace.document), page = try XCTUnwrap(document.page(at: 3))
            let found = document.findString(before, withOptions: []).filter {
                $0.pages.first === page && (targetBounds?.intersects($0.bounds(for: page)) ?? true)
            }
            XCTAssertEqual(found.count, 1)
            XCTAssertTrue(workspace.requestBodyTextEdit(selection: try XCTUnwrap(found.first), preservesSelectionTool: false))
            let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
            targetBounds = draft.bounds
            let selection = try XCTUnwrap(draft.initialSelectedRange)
            XCTAssertEqual((draft.text as NSString).substring(with: selection), before)
            let text = (draft.text as NSString).replacingCharacters(in: selection, with: after)
            workspace.updatePendingInlineTextDraft(id: draft.id, text: text, style: draft.style, bounds: draft.bounds)
            workspace.commitPendingInlineTextDraftIfNeeded()
            XCTAssertNil(workspace.pendingInlineTextEdit, workspace.presentedError ?? "")
            XCTAssertTrue(workspace.isDirty)
            let edited = try XCTUnwrap(document.page(at: 3))
            XCTAssertEqual(PDFBodyLosslessProvenance.commit(for: edited)?.rewrite.kind, .glyph)
            let destination = output.appendingPathComponent("edit-\(index).pdf")
            let saved = await workspace.saveAsynchronously(as: destination)
            XCTAssertTrue(saved, workspace.presentedError ?? "")
            XCTAssertTrue(workspace.open(url: destination))
            let reopened = try XCTUnwrap(workspace.document), checked = try XCTUnwrap(reopened.page(at: 3))
            XCTAssertEqual(reopened.pageCount, originalContent.count)
            XCTAssertNotNil(checked.pageRef?.dictionary.flatMap { PDFCatalogStructurePreserver.object($0, "StructParents") })
            XCTAssertEqual(checked.string, index == 0 ? originalString.replacingOccurrences(of: before, with: after) : originalString)
            for pageIndex in originalContent.indices where pageIndex != 3 || index == 1 {
                XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(reopened.page(at: pageIndex))), originalContent[pageIndex])
            }
        }
        XCTAssertEqual(try Data(contentsOf: input), inputBytes)
    }

    func testReplacementChangesSearchableContentAndSurvivesSaveUndoRedo() throws {
        let (workspace, url) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        let original = try XCTUnwrap(document.page(at: 0))
        let untouched = try XCTUnwrap(document.page(at: 1))
        let note = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 60, height: 20),
                                 forType: .square, withProperties: nil)
        note.contents = "Preserve annotation"
        original.addAnnotation(note)
        let link = PDFAnnotation(bounds: CGRect(x: 20, y: 30, width: 80, height: 20),
                                 forType: .link, withProperties: nil)
        let point = CGPoint(x: 47, y: 287)
        let destination = PDFDestination(page: original, at: point)
        destination.zoom = 1.5
        link.destination = destination
        untouched.addAnnotation(link)
        let outline = PDFOutline()
        let child = PDFOutline()
        child.label = "Body"
        child.destination = destination
        outline.insertChild(child, at: 0)
        document.outlineRoot = outline

        try beginAndCommit("Updated body", workspace: workspace)
        let edited = try XCTUnwrap(document.page(at: 0))
        XCTAssertTrue(workspace.document === document)
        XCTAssertFalse(edited === original)
        XCTAssertTrue(document.page(at: 1) === untouched)
        XCTAssertTrue(edited.annotations.contains(where: { $0 === note }))
        XCTAssertEqual(edited.annotations.count, 1)
        XCTAssertTrue(document.findString("Original body", withOptions: []).isEmpty)
        XCTAssertEqual(document.findString("Updated body", withOptions: []).count, 1)
        XCTAssertTrue(edited.string?.contains("Unchanged nearby") == true)
        XCTAssertTrue(link.destination?.page === edited)
        XCTAssertEqual(link.destination?.point, point)
        XCTAssertEqual(link.destination?.zoom, 1.5)
        XCTAssertTrue(child.destination?.page === edited)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.saveSynchronously())
        XCTAssertFalse(workspace.isDirty)
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(reopened.findString("Original body", withOptions: []).isEmpty)
        XCTAssertEqual(reopened.findString("Updated body", withOptions: []).count, 1)

        workspace.undo()
        XCTAssertTrue(document.page(at: 0) === original)
        XCTAssertTrue(original.annotations.contains(where: { $0 === note }))
        XCTAssertTrue(link.destination?.page === original)
        XCTAssertTrue(child.destination?.page === original)
        XCTAssertTrue(workspace.isDirty)
        workspace.redo()
        XCTAssertTrue(document.page(at: 0) === edited)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertNil(workspace.presentedError)
    }

    func testDeleteAndInsertAreRealContentAndUndoRestoresIt() throws {
        let (workspace, url) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        try beginAndCommit("", workspace: workspace)
        XCTAssertTrue(document.findString("Original body", withOptions: []).isEmpty)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Unchanged nearby") == true)
        XCTAssertEqual(document.page(at: 0)?.annotations.count, 0)
        workspace.undo()
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(document.findString("Original body", withOptions: []).count, 1)
        workspace.redo()
        XCTAssertTrue(document.findString("Original body", withOptions: []).isEmpty)

        XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 40, y: 180)))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        XCTAssertEqual(draft.text, "")
        workspace.commitPendingInlineText(id: draft.id, text: "Added body",
                                          style: draft.style, bounds: draft.bounds)
        XCTAssertEqual(document.findString("Added body", withOptions: []).count, 1)
        XCTAssertEqual(document.page(at: 0)?.annotations.count, 0)
        workspace.undo()
        XCTAssertTrue(document.findString("Added body", withOptions: []).isEmpty)
        workspace.redo()
        XCTAssertEqual(document.findString("Added body", withOptions: []).count, 1)
        XCTAssertNil(workspace.presentedError)
    }

    func testCancelUnchangedDraftAndSelectionEntryDoNotAlterPDF() throws {
        let (workspace, url) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        let original = try XCTUnwrap(document.page(at: 0))
        workspace.currentSelection = document.findString("Original", withOptions: []).first
        workspace.selectTool(.text)
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        XCTAssertEqual(draft.purpose, .bodyText)
        XCTAssertTrue(draft.text.contains("Original body"))
        workspace.cancelPendingInlineText()
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertTrue(document.page(at: 0) === original)
        XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        workspace.commitPendingInlineTextDraftIfNeeded()
        XCTAssertFalse(workspace.isDirty)
        XCTAssertTrue(document.page(at: 0) === original)
        XCTAssertNil(workspace.pendingInlineTextEdit)
    }

    func testRegionSelectionWithWhitespaceAtItsCenterStillOpensNativeText() throws {
        let (workspace, url) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        let page = try XCTUnwrap(document.page(at: 0))
        let wideBounds = CGRect(x: 40, y: 300, width: 340, height: 14)
        XCTAssertNil(try PDFBodyTextEditor.target(on: page,
            at: CGPoint(x: wideBounds.midX, y: wideBounds.midY)))
        workspace.currentSelection = PDFRegionTextSelection(document: document, page: page,
            fragments: [PDFRegionTextFragment(text: "Original body", bounds: wideBounds)])
        workspace.selectTool(.text)
        XCTAssertEqual(workspace.pendingInlineTextEdit?.purpose, .bodyText)
        XCTAssertTrue(workspace.pendingInlineTextEdit?.text.contains("Original body") == true)
        workspace.cancelPendingInlineText()
        XCTAssertFalse(workspace.isDirty)
    }

    func testStaleDraftCannotSaveSwitchModeOrBeDroppedByOpenClose() throws {
        let (workspace, url) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.updatePendingInlineTextDraft(id: draft.id, text: "Do not lose this draft",
                                               style: draft.style, bounds: draft.bounds)
        let otherPage = try XCTUnwrap(document.page(at: 1)?.copy() as? PDFPage)
        document.removePage(at: 0)
        document.insert(otherPage, at: 0)
        XCTAssertFalse(workspace.saveSynchronously())
        XCTAssertNotNil(workspace.pendingInlineTextEdit)
        XCTAssertNotNil(workspace.presentedError)
        workspace.undo()
        workspace.redo()
        XCTAssertNotNil(workspace.pendingInlineTextEdit)
        workspace.activeTool = .pen
        XCTAssertEqual(workspace.activeTool, .text)
        workspace.setMode(.viewer)
        XCTAssertEqual(workspace.mode, .editing)
        XCTAssertFalse(workspace.open(url: url))
        workspace.close()
        XCTAssertTrue(workspace.document === document)
        XCTAssertEqual(workspace.pendingInlineTextEdit?.text, "Do not lose this draft")
        workspace.cancelPendingInlineText()
    }

    func testPendingBodyEditIsCommittedBeforePageMovementAndRotation() throws {
        let (workspace, url) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.updatePendingInlineTextDraft(id: draft.id, text: "Moved body",
                                               style: draft.style, bounds: draft.bounds)
        workspace.movePage(from: 0, before: 2)
        XCTAssertTrue(document.page(at: 1)?.string?.contains("Moved body") == true)
        workspace.undo()
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Moved body") == true)
        workspace.undo()
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Original body") == true)
        XCTAssertFalse(workspace.isDirty)

        XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        let rotationDraft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.updatePendingInlineTextDraft(id: rotationDraft.id, text: "Rotated body",
                                               style: rotationDraft.style, bounds: rotationDraft.bounds)
        workspace.rotateSelectedPages(clockwise: true)
        XCTAssertEqual(document.page(at: 0)?.rotation, 90)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Rotated body") == true)
        workspace.undo()
        XCTAssertEqual(document.page(at: 0)?.rotation, 0)
        workspace.undo()
        XCTAssertFalse(workspace.isDirty)
        XCTAssertNil(workspace.presentedError)
    }

    func testDocumentUndoSettlesBodyDraftAndPreservesEarlierAnnotationHistory() throws {
        let (workspace, url) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        XCTAssertTrue(workspace.requestInlineTextEdit(
            pageIndex: 0, point: CGPoint(x: 30, y: 100), annotation: nil
        ))
        let noteDraft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.commitPendingInlineText(id: noteDraft.id, text: "Earlier note",
                                          style: noteDraft.style, bounds: noteDraft.bounds)
        let note = try XCTUnwrap(document.page(at: 0)?.annotations.first)
        XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        let bodyDraft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.updatePendingInlineTextDraft(id: bodyDraft.id, text: "Latest body",
                                               style: bodyDraft.style, bounds: bodyDraft.bounds)
        workspace.undo()
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Original body") == true)
        XCTAssertTrue(document.page(at: 0)?.annotations.contains(where: { $0 === note }) == true)
        workspace.redo()
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Latest body") == true)
        XCTAssertTrue(document.page(at: 0)?.annotations.contains(where: { $0 === note }) == true)
        workspace.undo()
        workspace.undo()
        XCTAssertFalse(workspace.isDirty)
        XCTAssertTrue(document.page(at: 0)?.annotations.isEmpty == true)
        XCTAssertNil(workspace.presentedError)
    }

    func testImageAndSignatureInsertionSettleBodyBeforeCapturingPageHistory() throws {
        for insertsSignature in [false, true] {
            let (workspace, url) = try Self.fixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let document = try XCTUnwrap(workspace.document)
            XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
            let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
            workspace.updatePendingInlineTextDraft(id: draft.id, text: "Edited body",
                                                   style: draft.style, bounds: draft.bounds)
            if insertsSignature {
                let stroke = SignatureStroke(points: [
                    SignaturePoint(x: 10, y: 10, pressure: 0.4, timestamp: 0),
                    SignaturePoint(x: 80, y: 40, pressure: 0.7, timestamp: 0.1),
                    SignaturePoint(x: 140, y: 20, pressure: 0.5, timestamp: 0.2)
                ])
                XCTAssertTrue(workspace.addSignature([stroke], canvasSize: CGSize(width: 180, height: 80)))
            } else {
                let image = NSImage(size: CGSize(width: 20, height: 20), flipped: false) { rect in
                    NSColor.red.setFill()
                    rect.fill()
                    return true
                }
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let imageURL = url.deletingLastPathComponent().appendingPathComponent("insert.png")
                try png.write(to: imageURL)
                workspace.insertImage(url: imageURL)
                let imageRequest = try XCTUnwrap(workspace.pendingImageInsertion)
                let preparedImages = try ImageInsertionPreparation.prepare(urls: imageRequest.urls, option: .original)
                XCTAssertTrue(workspace.approveImageInsertion(imageRequest, images: preparedImages))
            }
            let edited = try XCTUnwrap(document.page(at: 0))
            XCTAssertNil(workspace.pendingInlineTextEdit)
            XCTAssertTrue(edited.string?.contains("Edited body") == true)
            XCTAssertEqual(edited.annotations.count, 1)
            workspace.undo()
            XCTAssertTrue(edited.annotations.isEmpty)
            XCTAssertTrue(document.page(at: 0)?.string?.contains("Edited body") == true)
            workspace.undo()
            XCTAssertFalse(workspace.isDirty)
            XCTAssertTrue(document.page(at: 0)?.string?.contains("Original body") == true)
            workspace.redo()
            workspace.redo()
            XCTAssertTrue(document.page(at: 0) === edited)
            XCTAssertEqual(edited.annotations.count, 1)
            XCTAssertNil(workspace.presentedError)
        }
    }

    func testImageLayerAndDeletionCommandsFollowPageAfterPendingBodyCommit() throws {
        for deletesImage in [false, true] {
            let (workspace, url) = try Self.fixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let document = try XCTUnwrap(workspace.document)
            let original = try XCTUnwrap(document.page(at: 0))
            let image = NSImage(size: CGSize(width: 20, height: 20), flipped: false) { rect in
                NSColor.red.setFill()
                rect.fill()
                return true
            }
            let first = ImageStampAnnotation(image: image, bounds: CGRect(x: 20, y: 20, width: 30, height: 30))
            let second = ImageStampAnnotation(image: image, bounds: CGRect(x: 60, y: 20, width: 30, height: 30))
            _ = ImageAnnotationIdentity.assign(to: first)
            _ = ImageAnnotationIdentity.assign(to: second)
            original.addAnnotation(first)
            original.addAnnotation(second)
            XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
            let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
            workspace.updatePendingInlineTextDraft(id: draft.id, text: "Edited body",
                                                   style: draft.style, bounds: draft.bounds)
            if deletesImage {
                XCTAssertTrue(workspace.deleteImageAnnotation(first, on: original))
            } else {
                XCTAssertTrue(workspace.reorderImageAnnotation(first, on: original, command: .bringToFront))
            }
            let edited = try XCTUnwrap(document.page(at: 0))
            XCTAssertFalse(edited === original)
            XCTAssertTrue(edited.string?.contains("Edited body") == true)
            XCTAssertTrue(edited.annotations.first === second)
            XCTAssertEqual(edited.annotations.count, deletesImage ? 1 : 2)
            workspace.undo()
            XCTAssertTrue(document.page(at: 0) === edited)
            XCTAssertTrue(edited.annotations.first === first)
            XCTAssertTrue(edited.annotations.last === second)
            workspace.undo()
            XCTAssertTrue(document.page(at: 0) === original)
            XCTAssertTrue(original.annotations.first === first)
            XCTAssertTrue(original.annotations.last === second)
            XCTAssertFalse(workspace.isDirty)
            workspace.redo()
            workspace.redo()
            XCTAssertTrue(document.page(at: 0) === edited)
            XCTAssertTrue(edited.annotations.first === second)
            XCTAssertEqual(edited.annotations.count, deletesImage ? 1 : 2)
            XCTAssertNil(workspace.presentedError)
        }
    }

    func testHighlightCannotRegisterAgainstSelectionInvalidatedByBodyCommit() throws {
        let (workspace, url) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        workspace.currentSelection = document.findString("Original body", withOptions: []).first
        XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.updatePendingInlineTextDraft(id: draft.id, text: "Edited body",
                                               style: draft.style, bounds: draft.bounds)
        workspace.highlightCurrentSelection()
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertTrue(document.page(at: 0)?.annotations.isEmpty == true)
        XCTAssertEqual(workspace.presentedError, L10n.string("error.select_text_first"))
        workspace.clearError()
        workspace.undo()
        XCTAssertFalse(workspace.isDirty)
        XCTAssertNil(workspace.presentedError)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Original body") == true)
    }

    func testModesAndRestrictedPasswordSessionRejectBodyEdits() throws {
        let (workspace, url) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        workspace.setMode(.viewer)
        XCTAssertFalse(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        workspace.setMode(.study)
        XCTAssertFalse(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        let source = try XCTUnwrap(PDFDocument(url: url))
        let protectedURL = url.deletingLastPathComponent().appendingPathComponent("protected.pdf")
        XCTAssertTrue(source.write(to: protectedURL, withOptions: [
            .userPasswordOption: "ReaderPass9", .ownerPasswordOption: "OwnerPass9",
            .accessPermissionsOption: NSNumber(value: PDFAccessPermissions.allowsCommenting.rawValue)
        ]))
        let restricted = PDFWorkspaceState(passwordProvider: { _, _ in "ReaderPass9" })
        XCTAssertTrue(restricted.open(url: protectedURL))
        XCTAssertEqual(restricted.document?.permissionsStatus, .user)
        restricted.setMode(.editing)
        XCTAssertFalse(restricted.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        XCTAssertFalse(restricted.isDirty)
        XCTAssertNil(restricted.pendingInlineTextEdit)
    }

    func testBodyEditOn3309PageDocumentKeepsUnrelatedPagesAndCompletesPromptly() throws {
        let (workspace, url) = try Self.fixture(pageCount: 3_309)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        let lastPage = try XCTUnwrap(document.page(at: 3_308))
        let start = ProcessInfo.processInfo.systemUptime
        try beginAndCommit("Updated body", workspace: workspace)
        let duration = ProcessInfo.processInfo.systemUptime - start
        print("Body edit including link remapping on 3,309 pages: \(duration) seconds")
        XCTAssertLessThan(duration, 10, "A one-page edit must remain bounded on large textbooks.")
        XCTAssertEqual(document.pageCount, 3_309)
        XCTAssertTrue(document.page(at: 3_308) === lastPage)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Updated body") == true)
    }

    func testBodyPageSwapPreservesRawTextPopupRelationshipsAcrossSaveUndoRedo() async throws {
        for mode in ["no-popup", "absent", "null", "linked"] {
            let (workspace, url, bytes) = try rawRelationshipFixture(mode: mode)
            defer {
                workspace.closeDiscardingChanges()
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            try assertRawRelationship(bytes, mode: mode)
            let document = try XCTUnwrap(workspace.document), original = try XCTUnwrap(document.page(at: 0))
            let annotations = original.annotations, identities = annotations.map(ObjectIdentifier.init)
            let note = try XCTUnwrap(annotations.first { $0.type == "Text" })
            let popup = try XCTUnwrap(note.popup), contents = note.contents, bounds = note.bounds
            let popupContents = popup.contents, popupBounds = popup.bounds, modification = popup.modificationDate
            try beginAndCommit("Updated body", workspace: workspace)
            let edited = try XCTUnwrap(document.page(at: 0))
            XCTAssertFalse(edited === original)
            for stage in ["apply", "undo", "redo"] {
                if stage == "undo" { workspace.undo() }
                if stage == "redo" { workspace.redo() }
                let page = try XCTUnwrap(document.page(at: 0))
                XCTAssertTrue(page === (stage == "undo" ? original : edited))
                XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), identities,
                    "A same-object move must not leave an extra SDK-promoted Popup in the page.")
                XCTAssertTrue(note.popup === popup)
                XCTAssertEqual(note.contents, contents); XCTAssertEqual(note.bounds, bounds)
                XCTAssertEqual(popup.contents, popupContents); XCTAssertEqual(popup.bounds, popupBounds)
                XCTAssertEqual(popup.modificationDate, modification)
                let expected = stage == "undo" ? "Original body" : "Updated body"
                XCTAssertTrue(page.string?.contains(expected) == true)
                let output = url.deletingLastPathComponent().appendingPathComponent("\(mode)-\(stage).pdf")
                let saved = await workspace.saveAsynchronously(as: output)
                XCTAssertTrue(saved, workspace.presentedError ?? "")
                try assertRawRelationship(Data(contentsOf: output), mode: mode)
                let reopened = try XCTUnwrap(PDFDocument(url: output))
                XCTAssertTrue(reopened.page(at: 0)?.string?.contains(expected) == true)
                XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), identities)
                XCTAssertTrue(note.popup === popup)
                XCTAssertEqual(popup.modificationDate, modification)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                XCTAssertNil(workspace.presentedError)
            }
        }
    }

    func testBodyPageSwapRejectsAnEditedUnlistedPopupBeforeChangingLivePage() throws {
        let (workspace, url, bytes) = try rawRelationshipFixture(mode: "no-popup")
        defer {
            workspace.closeDiscardingChanges()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let document = try XCTUnwrap(workspace.document), original = try XCTUnwrap(document.page(at: 0))
        let annotations = original.annotations, identities = annotations.map(ObjectIdentifier.init)
        let note = try XCTUnwrap(annotations.first), popup = try XCTUnwrap(note.popup)
        let contents = note.contents, bounds = note.bounds
        let changed = Date(timeIntervalSince1970: 946684800)
        popup.modificationDate = changed
        XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        let state = workspace.editStateID
        workspace.commitPendingInlineText(id: draft.id, text: "Updated body", style: draft.style, bounds: draft.bounds)
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertEqual(workspace.pendingInlineTextEdit?.id, draft.id)
        XCTAssertEqual(workspace.editStateID, state)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertTrue(document.page(at: 0) === original)
        XCTAssertEqual(original.annotations.map(ObjectIdentifier.init), identities)
        XCTAssertTrue(original.string?.contains("Original body") == true)
        XCTAssertTrue(note.popup === popup)
        XCTAssertEqual(popup.modificationDate, changed)
        XCTAssertEqual(note.contents, contents); XCTAssertEqual(note.bounds, bounds)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        workspace.cancelPendingInlineText()
    }

    private func rawRelationshipFixture(mode: String) throws -> (PDFWorkspaceState, URL, Data) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-BodyRelationships-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = "BT /F1 20 Tf 40 300 Td (Original body) Tj 0 -40 Td (Unchanged nearby) Tj ET\n"
        let parent = mode == "linked" ? " /Parent 6 0 R" : mode == "null" ? " /Parent null" : ""
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 420] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /Annots [6 0 R\(mode == "no-popup" ? "" : " 7 0 R")] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /Annot /Subtype /Text /Rect [20 20 40 40] /Contents (Original note) /F 4\(mode == "no-popup" ? "" : " /Popup 7 0 R") >>"
        ]
        if mode != "no-popup" { objects.append("<< /Type /Annot /Subtype /Popup /Rect [60 20 140 90]\(parent) >>") }
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let url = directory.appendingPathComponent("source.pdf")
        try bytes.write(to: url)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url)); workspace.setMode(.editing)
        return (workspace, url, bytes)
    }

    private func assertRawRelationship(_ bytes: Data, mode: String,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let native = try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: bytes as CFData))))
        let page = try XCTUnwrap(native.page(at: 1)?.dictionary)
        let annotations = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
        XCTAssertEqual(CGPDFArrayGetCount(annotations), mode == "no-popup" ? 1 : 2, file: file, line: line)
        var first: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(annotations, 0, &first), file: file, line: line)
        let note = try XCTUnwrap(first)
        if mode == "no-popup" {
            XCTAssertNil(PDFCatalogStructurePreserver.object(note, "Popup"), file: file, line: line)
        } else {
            var second: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetDictionary(annotations, 1, &second), file: file, line: line)
            let popup = try XCTUnwrap(second)
            XCTAssertEqual(PDFCatalogStructurePreserver.dictionary(note, "Popup").map(pdfReferenceIdentity), pdfReferenceIdentity(popup), file: file, line: line)
            switch mode {
            case "absent": XCTAssertNil(PDFCatalogStructurePreserver.object(popup, "Parent"), file: file, line: line)
            case "null": XCTAssertEqual(PDFCatalogStructurePreserver.object(popup, "Parent").map(CGPDFObjectGetType), .null, file: file, line: line)
            default: XCTAssertEqual(PDFCatalogStructurePreserver.dictionary(popup, "Parent").map(pdfReferenceIdentity), pdfReferenceIdentity(note), file: file, line: line)
            }
        }
        withExtendedLifetime(native) {}
    }

    private func beginAndCommit(_ text: String, workspace: PDFWorkspaceState) throws {
        XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        XCTAssertEqual(draft.purpose, .bodyText)
        XCTAssertTrue(draft.text.contains("Original body"))
        workspace.commitPendingInlineText(id: draft.id, text: text, style: draft.style, bounds: draft.bounds)
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertNil(workspace.presentedError)
    }

    fileprivate static func fixture(pageCount: Int = 2, bodyText: String = "Original body", pageWidth: CGFloat = 400, fontName: String = "Helvetica", fontSize: CGFloat = 20) throws -> (PDFWorkspaceState, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberPDF-BodyText-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: pageWidth, height: 420)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            for (text, y) in [(index == 0 ? bodyText : "Other page", 300.0),
                              ("Unchanged nearby", 260.0)] {
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: 40, y: y)
                let line = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTLigatureAttributeName as String): 0
                ])
                CTLineDraw(CTLineCreateWithAttributedString(line), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        let url = directory.appendingPathComponent("body.pdf")
        try (data as Data).write(to: url)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.editing)
        return (workspace, url)
    }
}


/// Exercise the same PDFView pointer routing that was missing in the reported
/// workflow, including the AppKit editor's actual Return-to-Apply callback.
@MainActor
final class PDFBodyTextInteractionTests: XCTestCase {
    func testCompletedWordSelectionOpensBodyRunAndCancelKeepsOriginal() throws {
        let fixture = try ViewFixture()
        defer { fixture.detach() }
        let originalPage = try XCTUnwrap(fixture.workspace.document?.page(at: 0))
        let originalText = try XCTUnwrap(originalPage.string)
        XCTAssertEqual(fixture.workspace.activeTool, .select)
        try fixture.completeWordSelectionAndOpenEditor()
        XCTAssertEqual(fixture.workspace.pendingInlineTextEdit?.purpose, .bodyText)
        XCTAssertTrue(fixture.workspace.pendingInlineTextEdit?.text.contains("Original body") == true)
        let editor = try XCTUnwrap(fixture.editor)
        XCTAssertTrue(editor.string.contains("Original body"))
        try fixture.captureBodyEditorIfRequested()
        editor.keyDown(with: try fixture.key(53))
        XCTAssertNil(fixture.workspace.pendingInlineTextEdit)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)
        XCTAssertTrue(fixture.workspace.document?.page(at: 0) === originalPage)
        XCTAssertEqual(originalPage.string, originalText)
        XCTAssertTrue(fixture.workspace.document?.page(at: 0)?.string?.contains("Original body") == true)
    }

    func testTextToolBodyAndBlankClicksApplyThroughNativeEditor() throws {
        let fixture = try ViewFixture()
        defer { fixture.detach() }
        fixture.workspace.selectTool(.text)
        fixture.view.configure(with: fixture.workspace)
        fixture.view.mouseDown(with: try fixture.mouse(point: CGPoint(x: 70, y: 307)))
        let editor = try XCTUnwrap(fixture.editor)
        XCTAssertTrue(editor.string.contains("Original body"))
        editor.string = "Changed body"
        editor.didChangeText()
        editor.keyDown(with: try fixture.key(36, modifiers: .command))
        XCTAssertNil(fixture.workspace.pendingInlineTextEdit)
        XCTAssertTrue(fixture.workspace.document?.findString("Original body", withOptions: []).isEmpty == true)
        XCTAssertEqual(fixture.workspace.document?.findString("Changed body", withOptions: []).count, 1)

        fixture.view.layoutDocumentView()
        XCTAssertEqual(fixture.workspace.activeTool, .select)
        // Applying a body edit returns to Select. Start a new Text-tool
        // insertion explicitly before clicking blank space; otherwise PDFKit
        // correctly treats that click as a native selection gesture.
        fixture.workspace.selectTool(.text)
        fixture.view.configure(with: fixture.workspace)
        fixture.view.mouseDown(with: try fixture.mouse(point: CGPoint(x: 40, y: 180)))
        let insertionEditor = try XCTUnwrap(fixture.editor)
        XCTAssertEqual(insertionEditor.string, "")
        insertionEditor.string = "Inserted body"
        insertionEditor.didChangeText()
        insertionEditor.keyDown(with: try fixture.key(36, modifiers: .command))
        XCTAssertNil(fixture.workspace.pendingInlineTextEdit)
        XCTAssertEqual(fixture.workspace.document?.findString("Inserted body", withOptions: []).count, 1)
        XCTAssertTrue(fixture.workspace.document?.page(at: 0)?.annotations.isEmpty == true)
        XCTAssertNil(fixture.workspace.presentedError)
    }

    func testBodyEditorIsOnThePageReturnInsertsLineAndClickCommitsBeforeNextRun() throws {
        let fixture = try ViewFixture()
        defer { fixture.detach() }
        fixture.workspace.selectTool(.text)
        fixture.view.configure(with: fixture.workspace)
        fixture.view.mouseDown(with: try fixture.mouse(point: CGPoint(x: 70, y: 307)))
        let draft = try XCTUnwrap(fixture.workspace.pendingInlineTextEdit)
        let editor = try XCTUnwrap(fixture.editor)
        let page = try XCTUnwrap(fixture.workspace.document?.page(at: 0))
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let canvasInPDFView = scroll.convert(scroll.bounds, to: fixture.view)
        XCTAssertTrue(canvasInPDFView.intersects(fixture.view.convert(draft.bounds, from: page)))
        XCTAssertGreaterThan(editor.frame.width, 30)
        fixture.window.makeKey()
        fixture.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.keyDown(with: try fixture.key(36))
        XCTAssertEqual(fixture.workspace.pendingInlineTextEdit?.id, draft.id)
        XCTAssertTrue(editor.string.hasSuffix("\n"), "Return must insert a line break without applying a body edit.")
        editor.insertText("Second line", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.string.contains("Second line"))
        fixture.view.mouseDown(with: try fixture.mouse(point: CGPoint(x: 70, y: 267)))
        XCTAssertEqual(fixture.workspace.activeTool, .text)
        XCTAssertNotEqual(fixture.workspace.pendingInlineTextEdit?.id, draft.id)
        XCTAssertTrue(fixture.workspace.pendingInlineTextEdit?.text.contains("Unchanged nearby") == true)
        XCTAssertEqual(fixture.workspace.document?.findString("Second line", withOptions: []).count, 1)
        XCTAssertNil(fixture.workspace.presentedError)
    }

    func testBodyEditorZoomChangesDisplayFontWithoutChangingPDFStyle() throws {
        let fixture = try ViewFixture()
        defer { fixture.detach() }
        fixture.workspace.selectTool(.text)
        fixture.view.configure(with: fixture.workspace)
        fixture.view.mouseDown(with: try fixture.mouse(point: CGPoint(x: 70, y: 307)))
        let initial = try XCTUnwrap(fixture.workspace.pendingInlineTextEdit)
        let editor = try XCTUnwrap(fixture.editor)
        fixture.view.scaleFactor = 1.5
        fixture.view.layoutDocumentView()
        fixture.view.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: .PDFViewScaleChanged, object: fixture.view)
        XCTAssertEqual(editor.font?.pointSize ?? 0, initial.style.fontSize * 1.5, accuracy: 0.01)
        XCTAssertEqual(fixture.workspace.pendingInlineTextEdit?.style, initial.style)
        XCTAssertEqual(editor.string, initial.text)
    }

    func testRotatedPageKeepsReadableFloatingEditor() throws {
        let fixture = try ViewFixture()
        defer { fixture.detach() }
        let page = try XCTUnwrap(fixture.workspace.document?.page(at: 0))
        page.rotation = 90
        fixture.view.layoutDocumentView()
        XCTAssertTrue(fixture.workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        fixture.view.configure(with: fixture.workspace)
        fixture.view.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(fixture.editor)
        var ancestor = editor.superview
        while ancestor != nil, !(ancestor is PDFInlineTextEditorPanel) { ancestor = ancestor?.superview }
        XCTAssertTrue(ancestor is PDFInlineTextEditorPanel)
        XCTAssertGreaterThan(editor.frame.width, 100)
        XCTAssertTrue(editor.string.contains("Original body"))
        XCTAssertTrue(editor.drawsBackground)
    }

    func testCancelledDraftDoesNotReceiveQueuedKeyboardFocus() async throws {
        let fixture = try ViewFixture()
        defer { fixture.detach() }
        try fixture.completeWordSelectionAndOpenEditor()
        let editor = try XCTUnwrap(fixture.editor)
        editor.keyDown(with: try fixture.key(53))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertNil(fixture.workspace.pendingInlineTextEdit)
        XCTAssertFalse(fixture.window.firstResponder === editor)
    }

    func testLongFrenchHeadingRendersDirectlyOnPage() throws {
        let header = "Confirmation de la validation de l’enregistrement de votre demande de séjour"
        let fixture = try ViewFixture(header: header)
        defer { fixture.detach() }
        fixture.workspace.selectTool(.text)
        fixture.view.configure(with: fixture.workspace)
        fixture.view.mouseDown(with: try fixture.mouse(point: CGPoint(x: 70, y: 307)))
        let editor = try XCTUnwrap(fixture.editor)
        XCTAssertEqual(editor.string, header)
        XCTAssertGreaterThan(editor.frame.width, 500)
        XCTAssertEqual(editor.font?.pointSize, 16)
        XCTAssertTrue(editor.drawsBackground)
        let replacement = "Confirmation — texte modifié directement dans le PDF"
        fixture.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText(replacement, replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, replacement)
        XCTAssertEqual(fixture.workspace.pendingInlineTextEdit?.text, replacement)
        XCTAssertTrue(fixture.workspace.document?.page(at: 0)?.string?.contains(header) == true,
                      "Typing changes only the draft until the user applies it.")
        XCTAssertTrue(fixture.workspace.document?.findString(replacement, withOptions: []).isEmpty == true)
        try fixture.captureBodyEditorIfRequested()
    }

    @MainActor
    private struct ViewFixture {
        let workspace: PDFWorkspaceState
        let url: URL
        let window: NSWindow
        let view: InteractivePDFView

        init(header: String? = nil) throws {
            (workspace, url) = try PDFBodyTextWorkspaceTests.fixture(bodyText: header ?? "Original body",
                pageWidth: header == nil ? 400 : 1000,
                fontName: header == nil ? "Helvetica" : "Helvetica-Bold", fontSize: header == nil ? 20 : 16)
            view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: header == nil ? 500 : 1100, height: 600))
            window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.displayBox = .cropBox
            view.displayMode = .singlePage
            view.autoScales = false
            view.scaleFactor = 1
            view.document = workspace.document
            view.go(to: try XCTUnwrap(workspace.document?.page(at: 0)))
            view.layoutDocumentView()
            view.layoutSubtreeIfNeeded()
            view.configure(with: workspace)
        }

        var editor: PDFInlineTextView? {
            func find(in root: NSView) -> PDFInlineTextView? {
                if let editor = root as? PDFInlineTextView { return editor }
                for child in root.subviews {
                    if let editor = find(in: child) { return editor }
                }
                return nil
            }
            return find(in: view)
        }

        func completeWordSelectionAndOpenEditor() throws {
            // Select now enters editing after native selection is released.
            // A lone synthetic double-click mouseDown enters PDFKit's private
            // tracking loop, which waits for a queued mouseUp before returning.
            // These cancel/focus tests start at the completed word-selection
            // handoff; PDFDirectTextEditingInteractionTests separately covers
            // queued native release and a complete repaired mouse sequence.
            let page = try XCTUnwrap(workspace.document?.page(at: 0))
            let text = try XCTUnwrap(page.string) as NSString
            let range = text.range(of: "Original")
            XCTAssertNotEqual(range.location, NSNotFound)
            let selection = try XCTUnwrap(page.selection(for: range))
            view.beginNativeSelectionPreview()
            view.setCurrentSelection(selection, animate: false)
            XCTAssertNil(workspace.pendingInlineTextEdit)
            view.finishNativeSelectionPreview()
            XCTAssertTrue(view.beginEditingSelectedBodyText())
        }

        func mouse(point: CGPoint, clicks: Int = 1) throws -> NSEvent {
            let page = try XCTUnwrap(workspace.document?.page(at: 0))
            let viewPoint = view.convert(point, from: page)
            return try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: view.convert(viewPoint, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: clicks, pressure: 1
            ))
        }

        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: code == 36 ? "\r" : "", charactersIgnoringModifiers: code == 36 ? "\r" : "",
                isARepeat: false, keyCode: code
            ))
        }

        func captureBodyEditorIfRequested() throws {
            guard let path = ProcessInfo.processInfo.environment["EMBER_BODY_EDITOR_QA_DIRECTORY"] else { return }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearanceName)
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("body-canvas-\(appearanceName.rawValue).png"))
            }
        }

        func detach() {
            workspace.cancelPendingInlineText()
            view.prepareInlineTextEditingOverlayForRemoval()
            view.document = nil
            window.contentView = nil
            window.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }
}
