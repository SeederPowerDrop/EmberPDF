// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PluginScriptHostAPITests: XCTestCase {
    func testCapabilitiesRevocationAndUnexpectedParametersFailClosed() async throws {
        let (workspace, collection, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for method in ["document.getInfo", "document.getSelection", "document.getPageText", "workspace.listDocuments",
                       "workspace.navigate", "notes.get", "notes.append", "appearance.get", "appearance.set"] {
            do {
                _ = try await PluginScriptHostAPI.handle(method: method, params: [:], workspace: workspace,
                    collection: collection, isAuthorized: { true }, capabilities: [])
                XCTFail("Missing grant accepted for \(method)")
            } catch { XCTAssertEqual(error as? PluginScriptHostAPI.Failure, .permissionDenied) }
            do {
                _ = try await PluginScriptHostAPI.handle(method: method, params: [:], workspace: workspace,
                    collection: collection, isAuthorized: { false }, capabilities: Set(PluginCapability.allCases))
                XCTFail("Revoked runtime accepted for \(method)")
            } catch { XCTAssertEqual(error as? PluginScriptHostAPI.Failure, .permissionDenied) }
        }
        do {
            _ = try await PluginScriptHostAPI.handle(method: "document.getPageText", params: ["pageNumber": 2], workspace: workspace,
                collection: collection, isAuthorized: { true }, capabilities: [.currentPageText])
            XCTFail("Current-page capability must not accept an arbitrary page")
        } catch { XCTAssertEqual(error as? PluginScriptHostAPI.Failure, .permissionDenied) }
        XCTAssertEqual(workspace.pluginNotesSession.text, "")
        XCTAssertFalse(workspace.isDirty)
    }

    func testDocumentDataIsBoundedJSONAndForeignSelectionIsRejected() async throws {
        let (workspace, collection, directory) = try fixture(text: String(repeating: "page text ", count: 4_000))
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try await PluginScriptHostAPI.handle(method: "document.getPageText", params: [:], workspace: workspace,
            collection: collection, isAuthorized: { true }, capabilities: [.currentPageText])
        let result = try XCTUnwrap(data as? [String: Any])
        let text = try XCTUnwrap(result["text"] as? String)
        XCTAssertLessThanOrEqual(text.utf8.count, HwattakPluginLimits.maximumRenderedUTF8Bytes)
        XCTAssertLessThanOrEqual(text.count, HwattakPluginLimits.maximumRenderedCharacters)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(result))
        let info = try await PluginScriptHostAPI.handle(method: "document.getInfo", params: [:], workspace: workspace,
            collection: collection, isAuthorized: { true }, capabilities: [.documentMetadata])
        let serialized = try JSONSerialization.data(withJSONObject: info)
        XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains(directory.path))
        XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains("file:"))

        let foreign = try XCTUnwrap(PDFDocument(url: workspace.documentURL!))
        workspace.currentSelection = foreign.page(at: 0)?.selection(for: NSRange(location: 0, length: 4))
        do {
            _ = try await PluginScriptHostAPI.handle(method: "document.getSelection", params: [:], workspace: workspace,
                collection: collection, isAuthorized: { true }, capabilities: [.selectedText])
            XCTFail("Foreign PDF selection crossed the script boundary")
        } catch { XCTAssertEqual(error as? PluginScriptHostAPI.Failure, .selectionNotOwned) }
    }

    func testProtectedPDFTextRequiresCopyPermissionOrOwner() async throws {
        let (original, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("protected.pdf")
        let document = try XCTUnwrap(original.document)
        XCTAssertTrue(document.write(to: url, withOptions: [.ownerPasswordOption: "Owner9", .userPasswordOption: "Reader9",
            .accessPermissionsOption: NSNumber(value: 0), PDFDocumentWriteOption(rawValue: kCGPDFContextEncryptionKeyLength as String): 128]))
        for owner in [false, true] {
            let workspace = PDFWorkspaceState(passwordProvider: { _, _ in owner ? "Owner9" : "Reader9" })
            XCTAssertTrue(workspace.open(url: url))
            let collection = MultiDocumentWorkspaceState(initialSession: PDFTabSession(workspace: workspace))
            do {
                _ = try await PluginScriptHostAPI.handle(method: "document.getPageText", params: [:], workspace: workspace,
                    collection: collection, isAuthorized: { true }, capabilities: [.currentPageText])
                XCTAssertTrue(owner)
            } catch { XCTAssertFalse(owner); XCTAssertEqual(error as? PluginScriptHostAPI.Failure, .copyRestricted) }
        }
    }

    func testListAndNavigationUseOpaqueIDsAndValidateBeforeChangingPages() async throws {
        let (workspace, collection, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let returned = try await PluginScriptHostAPI.handle(method: "workspace.listDocuments", params: [:], workspace: workspace,
            collection: collection, isAuthorized: { true }, capabilities: [.openDocumentsRead])
        let list = try XCTUnwrap(returned as? [String: Any])
        let documents = try XCTUnwrap(list["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.count, 1)
        XCTAssertNil(documents.first?["url"])
        XCTAssertNil(documents.first?["path"])
        let ids: [String: Any] = ["workspaceID": collection.activeWorkspaceID.uuidString,
                                  "tabID": try XCTUnwrap(collection.activeTabID).uuidString]
        for invalidPage in [true, 1.5, 0, 3, "2"] as [Any] {
            var parameters = ids; parameters["pageNumber"] = invalidPage
            do {
                _ = try await PluginScriptHostAPI.handle(method: "workspace.navigate", params: parameters, workspace: workspace,
                    collection: collection, isAuthorized: { true }, capabilities: [.workspaceNavigation])
                XCTFail("Invalid page accepted: \(invalidPage)")
            } catch { XCTAssertEqual(error as? PluginScriptHostAPI.Failure, .invalidParameters) }
            XCTAssertEqual(workspace.currentPageIndex, 0)
        }
        var valid = ids; valid["pageNumber"] = 2
        _ = try await PluginScriptHostAPI.handle(method: "workspace.navigate", params: valid, workspace: workspace,
            collection: collection, isAuthorized: { true }, capabilities: [.workspaceNavigation])
        XCTAssertEqual(workspace.currentPageIndex, 1)
    }

    func testNotesAreAppendOnlyAndAttachedFilesNeedTheirOwnGrant() async throws {
        let (workspace, collection, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        workspace.pluginNotesSession.updateText("Existing note")
        _ = try await PluginScriptHostAPI.handle(method: "notes.append", params: ["text": "New thought"], workspace: workspace,
            collection: collection, isAuthorized: { true }, capabilities: [.notesWrite])
        XCTAssertEqual(workspace.pluginNotesSession.text, "Existing note\n\nNew thought\n")
        let markdown = directory.appendingPathComponent("chosen.md")
        try Data("User file".utf8).write(to: markdown)
        XCTAssertTrue(workspace.pluginNotesSession.open(url: markdown))
        for method in ["notes.get", "notes.append"] {
            do {
                _ = try await PluginScriptHostAPI.handle(method: method, params: method == "notes.append" ? ["text": "change"] : [:], workspace: workspace,
                    collection: collection, isAuthorized: { true }, capabilities: [.notesWrite])
                XCTFail("A local-note grant must not implicitly include an attached Markdown file")
            } catch { XCTAssertEqual(error as? PluginScriptHostAPI.Failure, .permissionDenied) }
        }
        XCTAssertEqual(workspace.pluginNotesSession.text, "User file")
        XCTAssertEqual(try String(contentsOf: markdown, encoding: .utf8), "User file")
        let result = try await PluginScriptHostAPI.handle(method: "notes.get", params: [:], workspace: workspace,
            collection: collection, isAuthorized: { true }, capabilities: [.notesWrite, .fileReadWrite])
        XCTAssertEqual((result as? [String: Any])?["text"] as? String, "User file")
    }

    func testAppearanceUsesEnumsAndRejectsInvalidUpdateAtomically() async throws {
        let (workspace, collection, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "EmberPDF-script-appearance-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults, appearanceDidChange: { _ in })
        do {
            _ = try await PluginScriptHostAPI.handle(method: "appearance.set", params: ["mode": "dark", "paper": "arbitrary-css"], workspace: workspace,
                collection: collection, isAuthorized: { true }, capabilities: [.appearanceWrite], preferences: preferences)
            XCTFail("Unrecognized paper should fail before any preference changes")
        } catch { XCTAssertEqual(error as? PluginScriptHostAPI.Failure, .invalidParameters) }
        XCTAssertEqual(preferences.appearance, .system)
        XCTAssertEqual(preferences.readingTheme, .original)
        _ = try await PluginScriptHostAPI.handle(method: "appearance.set", params: ["mode": "light", "paper": "sepia"], workspace: workspace,
            collection: collection, isAuthorized: { true }, capabilities: [.appearanceWrite], preferences: preferences)
        XCTAssertEqual(preferences.appearance, .light)
        XCTAssertEqual(preferences.readingTheme, .sepia)
    }

    func testDocumentTextGrantReadsOtherPagesWithoutNavigating() async throws {
        let (workspace, collection, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (params, capabilities) in [
            ([:], Set<PluginCapability>([.documentTextRead])),
            (["pageNumber": 1], Set<PluginCapability>([.currentPageText])),
            (["pageNumber": 2], Set<PluginCapability>([.documentTextRead]))
        ] as [([String: Any], Set<PluginCapability>)] {
            let result = try await PluginScriptHostAPI.handle(method: "document.getPageText", params: params,
                workspace: workspace, collection: collection, isAuthorized: { true }, capabilities: capabilities)
            XCTAssertEqual((result as? [String: Any])?["pageNumber"] as? Int, params["pageNumber"] as? Int ?? 1)
            XCTAssertEqual(workspace.currentPageIndex, 0)
        }
        for invalid in [0, 3, -1, 1.5, true, "2"] as [Any] {
            do {
                _ = try await PluginScriptHostAPI.handle(method: "document.getPageText", params: ["pageNumber": invalid],
                    workspace: workspace, collection: collection, isAuthorized: { true }, capabilities: [.documentTextRead])
                XCTFail("Invalid page accepted: \(invalid)")
            } catch { XCTAssertEqual(error as? PluginScriptHostAPI.Failure, .invalidParameters) }
        }
    }

    func testScriptCommandsUseNativeNavigationAndToolPermissionBoundaries() async throws {
        let (workspace, collection, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await PluginScriptHostAPI.handle(method: "commands.execute", params: ["kind": "nextPage"],
                workspace: workspace, collection: collection, isAuthorized: { true }, capabilities: [.toolControl])
            XCTFail("Navigation requires its own capability")
        } catch { XCTAssertEqual(error as? PluginScriptHostAPI.Failure, .permissionDenied) }
        XCTAssertEqual(workspace.currentPageIndex, 0)
        let result = try await PluginScriptHostAPI.handle(method: "commands.execute", params: ["kind": "nextPage"],
            workspace: workspace, collection: collection, isAuthorized: { true }, capabilities: [.workspaceNavigation])
        XCTAssertEqual((result as? [String: Any])?["executed"] as? Bool, true)
        XCTAssertEqual(workspace.currentPageIndex, 1)
        workspace.setMode(.editing)
        let oldTool = workspace.activeTool
        for parameters in [["kind": "pen", "width": 100], ["kind": "pen", "width": true],
                           ["kind": "nextPage", "color": "#ffffff"], ["kind": "selection", "unknown": 1]] as [[String: Any]] {
            do {
                _ = try await PluginScriptHostAPI.handle(method: "commands.execute", params: parameters,
                    workspace: workspace, collection: collection, isAuthorized: { true }, capabilities: [.toolControl, .workspaceNavigation])
                XCTFail("Invalid command should not mutate native state")
            } catch { XCTAssertEqual(error as? PluginScriptHostAPI.Failure, .invalidParameters) }
        }
        XCTAssertEqual(workspace.activeTool, oldTool)
        _ = try await PluginScriptHostAPI.handle(method: "commands.execute", params: ["kind": "pen", "width": 2.5, "color": "#deaa77"],
            workspace: workspace, collection: collection, isAuthorized: { true }, capabilities: [.toolControl])
        XCTAssertEqual(workspace.activeTool, .pen)
        XCTAssertEqual(workspace.inkSettings.width, 2.5)
        do {
            _ = try await PluginScriptHostAPI.handle(method: "commands.execute", params: ["kind": "previousPage"],
                workspace: workspace, collection: collection, isAuthorized: { false }, capabilities: [.workspaceNavigation])
            XCTFail("Revoked extension changed the page")
        } catch { XCTAssertEqual(error as? PluginScriptHostAPI.Failure, .permissionDenied) }
        XCTAssertEqual(workspace.currentPageIndex, 1)
    }

    func testScriptMarkupRequiresSelectedTextAndRejectsForeignSelectionBeforeEditing() async throws {
        let (workspace, collection, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        workspace.setMode(.study)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        workspace.currentSelection = page.selection(for: NSRange(location: 0, length: 8))
        do {
            _ = try await PluginScriptHostAPI.handle(method: "commands.execute", params: ["kind": "highlight"],
                workspace: workspace, collection: collection, isAuthorized: { true }, capabilities: [.annotationWrite])
            XCTFail("Markup must require the selected-text grant")
        } catch { XCTAssertEqual(error as? PluginScriptHostAPI.Failure, .permissionDenied) }
        let foreign = try XCTUnwrap(PDFDocument(url: workspace.documentURL!))
        workspace.currentSelection = foreign.page(at: 0)?.selection(for: NSRange(location: 0, length: 8))
        do {
            _ = try await PluginScriptHostAPI.handle(method: "commands.execute", params: ["kind": "highlight"],
                workspace: workspace, collection: collection, isAuthorized: { true }, capabilities: [.annotationWrite, .selectedText])
            XCTFail("Foreign PDF selection must not be edited")
        } catch { XCTAssertEqual(error as? PluginScriptHostAPI.Failure, .selectionNotOwned) }
        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertFalse(workspace.isDirty)
        workspace.currentSelection = page.selection(for: NSRange(location: 0, length: 8))
        _ = try await PluginScriptHostAPI.handle(method: "commands.execute", params: ["kind": "highlight", "color": "#ffeeaa"],
            workspace: workspace, collection: collection, isAuthorized: { true }, capabilities: [.annotationWrite, .selectedText])
        XCTAssertFalse(page.annotations.isEmpty)
        XCTAssertTrue(workspace.isDirty)
    }

    func testWholeDocumentReadAndMarkupRespectProtectedPDFCopyRights() async throws {
        let (original, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("restricted.pdf")
        let document = try XCTUnwrap(original.document)
        XCTAssertTrue(document.write(to: url, withOptions: [.ownerPasswordOption: "Owner9", .userPasswordOption: "Reader9",
            .accessPermissionsOption: NSNumber(value: 0), PDFDocumentWriteOption(rawValue: kCGPDFContextEncryptionKeyLength as String): 128]))
        let workspace = PDFWorkspaceState(passwordProvider: { _, _ in "Reader9" })
        XCTAssertTrue(workspace.open(url: url))
        let collection = MultiDocumentWorkspaceState(initialSession: PDFTabSession(workspace: workspace))
        workspace.currentSelection = workspace.document?.page(at: 0)?.selection(for: NSRange(location: 0, length: 8))
        for (method, params, capabilities) in [
            ("document.getPageText", ["pageNumber": 2], Set<PluginCapability>([.documentTextRead])),
            ("commands.execute", ["kind": "highlight"], Set<PluginCapability>([.annotationWrite, .selectedText]))
        ] as [(String, [String: Any], Set<PluginCapability>)] {
            do {
                _ = try await PluginScriptHostAPI.handle(method: method, params: params, workspace: workspace,
                    collection: collection, isAuthorized: { true }, capabilities: capabilities)
                XCTFail("Protected PDF access should fail")
            } catch { XCTAssertEqual(error as? PluginScriptHostAPI.Failure, .copyRestricted) }
        }
        XCTAssertFalse(workspace.isDirty)
        XCTAssertTrue(workspace.document?.page(at: 0)?.annotations.isEmpty == true)
    }

    private func fixture(text: String = "Selected page text") throws -> (PDFWorkspaceState, MultiDocumentWorkspaceState, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-script-api-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 20, y: 350)
            let line = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            CTLineDraw(CTLineCreateWithAttributedString(line as CFAttributedString), context)
            context.endPDFPage()
        }
        context.closePDF()
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        return (workspace, MultiDocumentWorkspaceState(initialSession: PDFTabSession(workspace: workspace)), directory)
    }
}
