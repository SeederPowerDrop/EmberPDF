// SPDX-License-Identifier: MPL-2.0

import AppKit
import Darwin
import Foundation
import XCTest
@testable import HwattakPDF

final class PluginNotesTests: XCTestCase {
    func testUTF8MarkdownRoundTripAndExternalOverwriteProtection() throws {
        let directory = try fixtureDirectory()
        let url = directory.appendingPathComponent("연구.md")
        let first = "# 노트\n\nEmber **PDF** 🔥\n"
        let version = try PluginNotesFileStore.save(first, to: url, expectedVersion: nil)
        XCTAssertEqual(try PluginNotesFileStore.load(from: url).text, first)
        let second = "# 다음 생각\n"
        let updated = try PluginNotesFileStore.save(second, to: url, expectedVersion: version)
        XCTAssertNotEqual(version, updated)
        try Data("외부 앱의 수정".utf8).write(to: url)
        XCTAssertThrowsError(try PluginNotesFileStore.save("오래된 내용", to: url, expectedVersion: updated))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "외부 앱의 수정")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["연구.md"])
    }

    func testNewDestinationCannotOverwriteAnUnapprovedExistingFile() throws {
        let url = try fixtureDirectory().appendingPathComponent("existing.md")
        try Data("keep me".utf8).write(to: url)
        XCTAssertThrowsError(try PluginNotesFileStore.save("replace", to: url, expectedVersion: nil))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep me")
    }

    func testExternalReplacementAfterStagingPreservesBothDraftAndOtherEditor() throws {
        let url = try fixtureDirectory().appendingPathComponent("conflict.md")
        let version = try PluginNotesFileStore.save("first", to: url, expectedVersion: nil)
        XCTAssertThrowsError(try PluginNotesFileStore.save("our unsaved draft", to: url, expectedVersion: version) {
            try Data("other editor".utf8).write(to: url, options: .atomic)
        })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "other editor")
    }

    func testNewDestinationAppearingAfterStagingCannotBeOverwritten() throws {
        let directory = try fixtureDirectory()
        let url = directory.appendingPathComponent("new.md")
        XCTAssertThrowsError(try PluginNotesFileStore.save("our draft", to: url, expectedVersion: nil) {
            try Data("other creator".utf8).write(to: url)
        })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "other creator")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["new.md"])
    }

    func testLeafChangedToSymlinkAfterStagingCannotRedirectReplacement() throws {
        let directory = try fixtureDirectory()
        let url = directory.appendingPathComponent("note.md")
        let other = directory.appendingPathComponent("other.md")
        let version = try PluginNotesFileStore.save("original", to: url, expectedVersion: nil)
        try Data("untouched".utf8).write(to: other)
        XCTAssertThrowsError(try PluginNotesFileStore.save("draft", to: url, expectedVersion: version) {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
        })
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "untouched")
    }

    func testParentReplacementAfterStagingCannotRedirectNewSave() throws {
        let directory = try fixtureDirectory()
        let parent = directory.appendingPathComponent("chosen")
        let moved = directory.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let url = parent.appendingPathComponent("note.md")
        XCTAssertThrowsError(try PluginNotesFileStore.save("draft", to: url, expectedVersion: nil) {
            try FileManager.default.moveItem(at: parent, to: moved)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }

    func testRejectsSymlinksDirectoriesPipesAndNonMarkdownFiles() throws {
        let directory = try fixtureDirectory()
        let original = directory.appendingPathComponent("original.md")
        try Data("original".utf8).write(to: original)
        let link = directory.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertThrowsError(try PluginNotesFileStore.load(from: link))
        XCTAssertThrowsError(try PluginNotesFileStore.save("overwrite", to: link, expectedVersion: nil))
        let folder = directory.appendingPathComponent("folder.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertThrowsError(try PluginNotesFileStore.load(from: folder))
        let pipe = directory.appendingPathComponent("pipe.md")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertThrowsError(try PluginNotesFileStore.load(from: pipe))
        let nonMarkdown = directory.appendingPathComponent("document.pdf")
        try Data("text in a pdf named file".utf8).write(to: nonMarkdown)
        XCTAssertThrowsError(try PluginNotesFileStore.load(from: nonMarkdown))
        XCTAssertThrowsError(try PluginNotesFileStore.load(from: URL(string: "https://example.com/note.md")!))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
    }

    func testRejectsHardLinkOverwriteAndPreservesBothLinks() throws {
        let directory = try fixtureDirectory()
        let original = directory.appendingPathComponent("original.md")
        let alias = directory.appendingPathComponent("alias.md")
        try Data("shared bytes".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: alias)
        let version = try PluginNotesFileStore.load(from: alias).version
        XCTAssertThrowsError(try PluginNotesFileStore.save("changed", to: alias, expectedVersion: version))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "shared bytes")
        XCTAssertEqual(try String(contentsOf: alias, encoding: .utf8), "shared bytes")
    }

    func testRejectsOversizedInvalidUTF8AndNULContent() throws {
        let directory = try fixtureDirectory()
        for (name, data) in [
            ("large.md", Data(repeating: 65, count: PluginNotesFileStore.maximumFileBytes + 1)),
            ("binary.md", Data([0xff, 0xfe, 0x00])),
            ("nul.md", Data([65, 0, 66]))
        ] {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            XCTAssertThrowsError(try PluginNotesFileStore.load(from: url), name)
        }
        XCTAssertThrowsError(try PluginNotesFileStore.save(
            String(repeating: "x", count: PluginNotesFileStore.maximumFileBytes + 1),
            to: directory.appendingPathComponent("save.md"), expectedVersion: nil
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("save.md").path))
    }

    func testNativePreviewKeepsRemoteImagesHTMLAndLinksInert() {
        let source = "**Bold** [site](https://example.com) ![image](https://example.com/image.png) <script>alert(1)</script> <https://example.com>"
        let rendered = PluginNotesPreview.inline(source)
        XCTAssertTrue(rendered.runs.allSatisfy { $0.link == nil })
        let plain = String(rendered.characters)
        XCTAssertTrue(plain.contains("![image](https://example.com/image.png)"))
        XCTAssertTrue(plain.contains("<script>alert(1)</script>"))
        let blocks = PluginNotesPreview.blocks("# Title\n> quote\n```swift\n# code, not heading\n```\nbody")
        XCTAssertEqual(blocks.map(\.kind), [.heading(1), .quote, .code, .code, .code, .body])
        XCTAssertTrue(PluginNotesPreview.isTruncated(String(repeating: "x", count: PluginNotesPreview.maximumPreviewCharacters + 1)))
        XCTAssertLessThanOrEqual(PluginNotesPreview.blocks(String(repeating: "line\n", count: 5_000)).count, PluginNotesPreview.maximumPreviewLines)
    }

    func testPDFQuoteCannotIntroduceActiveMarkdownReferences() {
        let source = PluginNoteSource(documentName: "[private](file:///secret).pdf", pageNumber: 12, selectedText: "![hidden](https://example.com)\n<script>evil</script>")
        XCTAssertTrue(source.citation.contains("\\[private\\]"))
        XCTAssertTrue(source.citation.contains("12"))
        XCTAssertTrue(source.quotation!.contains("> \\!\\[hidden\\]"))
        XCTAssertTrue(source.quotation!.contains("\\<script\\>"))
        XCTAssertNil(PluginNoteSource(documentName: "note.pdf", pageNumber: 0, selectedText: " \n").quotation)
    }

    @MainActor
    func testDraftPersistsAcrossPDFResetAndFailedSaveKeepsDirtyState() throws {
        let workspace = PDFWorkspaceState()
        workspace.pluginNotesSession.updateText("Unfinished thought")
        workspace.closeDiscardingChanges()
        XCTAssertEqual(workspace.pluginNotesSession.text, "Unfinished thought")
        XCTAssertTrue(workspace.pluginNotesSession.isModified)
        let url = try fixtureDirectory().appendingPathComponent("conflict.md")
        try Data("existing".utf8).write(to: url)
        XCTAssertFalse(workspace.pluginNotesSession.save(to: url, expectedVersion: nil))
        XCTAssertTrue(workspace.pluginNotesSession.isModified)
        XCTAssertEqual(workspace.pluginNotesSession.text, "Unfinished thought")
        XCTAssertNotNil(workspace.pluginNotesSession.message)
    }

    @MainActor
    func testLaterNoteCancellationPreservesEarlierDiscardChoice() {
        let first = PDFWorkspaceState()
        let second = PDFWorkspaceState()
        first.pluginNotesSession.updateText("first note")
        second.pluginNotesSession.updateText("second note")
        let accepted = UnsavedChangesGuard.confirmAndClose(
            workspaces: [first, second], decisionProvider: { _ in .dontSave },
            notesDecisionProvider: { $0 === first ? .discard : .cancel }
        )
        XCTAssertFalse(accepted)
        XCTAssertEqual(first.pluginNotesSession.text, "first note")
        XCTAssertTrue(first.pluginNotesSession.isModified)
        XCTAssertEqual(second.pluginNotesSession.text, "second note")
    }

    @MainActor
    func testAcceptedNoteDiscardsAreAppliedAfterAllDecisions() {
        let first = PDFWorkspaceState()
        let second = PDFWorkspaceState()
        first.pluginNotesSession.updateText("first note")
        second.pluginNotesSession.updateText("second note")
        var closingSawDrafts = false
        let accepted = UnsavedChangesGuard.confirmAndClose(
            workspaces: [first, second], decisionProvider: { _ in .dontSave },
            notesDecisionProvider: { _ in .discard },
            beforeClosing: { closingSawDrafts = first.pluginNotesSession.isModified && second.pluginNotesSession.isModified }
        )
        XCTAssertTrue(accepted)
        XCTAssertTrue(closingSawDrafts)
        XCTAssertFalse(first.pluginNotesSession.isModified)
        XCTAssertFalse(second.pluginNotesSession.isModified)
        XCTAssertEqual(first.pluginNotesSession.text, "")
    }

    @MainActor
    func testEditorLimitRejectsOversizedEditWithoutTruncatingExistingDraft() {
        let session = PluginNotesSession()
        session.updateText("keep my draft")
        session.updateText(String(repeating: "🔥", count: PluginNotesFileStore.maximumFileBytes / 4 + 1))
        XCTAssertEqual(session.text, "keep my draft")
        XCTAssertTrue(session.isModified)
        XCTAssertNotNil(session.message)
    }

    @MainActor
    func testRevokedAuthorizationPreventsFileReadsWritesAndDraftDiscard() throws {
        let session = PluginNotesSession()
        session.updateText("keep draft")
        let url = try fixtureDirectory().appendingPathComponent("note.md")
        try Data("existing file".utf8).write(to: url)
        let version = try PluginNotesFileStore.version(at: url)
        XCTAssertFalse(session.open(url: url, authorization: { false }))
        XCTAssertFalse(session.save(to: url, expectedVersion: version, authorization: { false }))
        session.newNote(authorization: { false })
        XCTAssertFalse(session.confirmCanClose(authorization: { false }))
        XCTAssertEqual(session.text, "keep draft")
        XCTAssertTrue(session.isModified)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "existing file")
    }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-Notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
