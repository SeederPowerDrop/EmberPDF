// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import HwattakPDF

@MainActor
final class PluginFoundationTests: XCTestCase {
    func testHostPanelsRequireTheirExactCapabilitiesAndSchema() throws {
        let outputs: [PluginActionOutput] = [.appearancePanel, .notesPanel, .pageClipPanel, .relatedDocumentsPanel, .hoverTranslationPanel]
        for output in outputs {
            let action = PluginActionManifest(id: "open", title: "Open", description: nil, output: output, template: "")
            let valid = manifest(schema: 4, action: action, capabilities: Array(action.requiredCapabilities))
            try PluginManifestValidator().validate(valid)
            XCTAssertThrowsError(try PluginManifestValidator().validate(manifest(schema: 3, action: action, capabilities: valid.capabilities)))
            XCTAssertThrowsError(try PluginManifestValidator().validate(manifest(schema: 4, action: action, capabilities: [])))
        }
    }

    func testExecutablePackageBindsCodeBytesToReviewedManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("Example.hwattakplugin")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let code = Data("ember.on('load', () => ember.ui.render({title:'Hello'}));".utf8)
        let action = PluginActionManifest(id: "open", title: "Open", description: nil, output: .scriptPanel, template: "",
            scriptSHA256: PluginPackageValidator.sha256Hex(code), scriptCapabilities: [])
        try JSONEncoder().encode(manifest(schema: 5, action: action, capabilities: [])).write(to: package.appendingPathComponent("manifest.json"))
        try code.write(to: package.appendingPathComponent("main.js"))
        let accepted = try PluginPackageValidator().inspectSourcePackage(at: package)
        XCTAssertEqual(accepted.filePayloads["main.js"], code)
        try Data("while(true) {}".utf8).write(to: package.appendingPathComponent("main.js"))
        XCTAssertThrowsError(try PluginPackageValidator().inspectSourcePackage(at: package))
        var unsupported = action
        unsupported.scriptCapabilities = [.externalURL]
        XCTAssertThrowsError(try PluginManifestValidator().validate(manifest(schema: 5, action: unsupported, capabilities: [.externalURL])))
    }

    func testNotesAndScriptCanOpenBeforeTextIsSelected() {
        let notes = PluginActionManifest(id: "notes", title: "Notes", description: nil, output: .notesPanel, template: "")
        let script = PluginActionManifest(id: "script", title: "Script", description: nil, output: .scriptPanel, template: "", scriptSHA256: String(repeating: "0", count: 64), scriptCapabilities: [.selectedText])
        XCTAssertFalse(notes.needsSelection)
        XCTAssertFalse(script.needsSelection)
    }

    func testHoverRejectsUnboundedOrControlText() {
        XCTAssertEqual(PluginHoverCapture.boundedWord("  Ember  "), "Ember")
        XCTAssertNil(PluginHoverCapture.boundedWord(""))
        XCTAssertNil(PluginHoverCapture.boundedWord(String(repeating: "a", count: 121)))
        XCTAssertNil(PluginHoverCapture.boundedWord("a\0b"))
    }

    private func manifest(schema: Int, action: PluginActionManifest, capabilities: [PluginCapability]) -> PluginManifest {
        .init(schemaVersion: schema, identifier: "org.example.foundation", displayName: "Example", version: "1.0.0",
            author: "Tests", description: "Test", minimumHostVersion: nil, capabilities: capabilities, actions: [action])
    }
}
