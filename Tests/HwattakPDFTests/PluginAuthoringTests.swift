// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

/// Documentation and author tooling use the same package/trust validators as the app.
@MainActor
final class PluginAuthoringTests: XCTestCase {
    private var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testCommunityPackagesAndOptionalAuthorPackage() throws {
        let environment = ProcessInfo.processInfo.environment
        let hostVersion = environment["HWATTAK_PLUGIN_HOST_VERSION"] ?? "0.9.0"
        guard PluginSemanticVersion(hostVersion) != nil else {
            XCTFail("Host version must be major.minor.patch without a suffix")
            return
        }
        let suite = "HwattakPDF.PluginAuthoring.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temporary)
        }
        // No app bundle allowlist: this command verifies community-distributable packages.
        // It neither installs the author's package nor accesses the user's plugin registry.
        let manager = PluginManager(pluginsDirectory: temporary, defaults: defaults,
            hostVersion: hostVersion, bundledPluginsDirectory: nil)
        let packages: [URL]
        if let path = environment["HWATTAK_PLUGIN_VALIDATE_PATH"], !path.isEmpty {
            packages = [URL(fileURLWithPath: path)]
        } else {
            packages = ["HelloEmber", "OfflineChecklist", "CommunityStarter", "QuickCitation", "MarkdownQuote", "ReferenceSearch",
                        "ReadingColors", "MarkdownNotebook", "PageClipper", "RelatedDocuments", "HoverTranslator", "ReadingLab", "ResearchTrail", "EmberRecall"]
                .map { project.appendingPathComponent("Examples/Plugins/\($0).hwattakplugin") }
        }
        for package in packages {
            let inspection = try manager.inspectPackage(at: package)
            print("PLUGIN VALID: \(inspection.manifest.identifier) \(inspection.manifest.version); schema=\(inspection.manifest.schemaVersion); host=\(hostVersion); sha256=\(inspection.manifestDigest)")
        }
        XCTAssertTrue(manager.installedPlugins.isEmpty, "Validation must never install a package")
    }

    func testCompleteManifestExamplesInAuthorDocumentationMatchHostRules() throws {
        let documents = ["PLUGIN-DEVELOPMENT.md", "PLUGIN-DEVELOPMENT.en.md", "PLUGIN-HOST-API.md"]
        let expression = try NSRegularExpression(pattern: "(?s)```json\\s*\\n(.*?)\\n```")
        var count = 0
        for name in documents {
            let text = try String(contentsOf: project.appendingPathComponent("Documentation/\(name)"), encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in expression.matches(in: text, range: range) {
                let body = try XCTUnwrap(Range(match.range(at: 1), in: text))
                _ = try PluginManifestValidator(hostVersion: "0.9.0")
                    .decodeAndValidate(Data(text[body].utf8))
                count += 1
            }
        }
        XCTAssertGreaterThanOrEqual(count, 3, "Keep at least one complete, validated example per guide")
    }

    func testSchemaFourExamplesInstallWithoutBundledTrustAndDeclareExactCapabilities() throws {
        let suite = "EmberPDF.SchemaFourAuthoring.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temporary)
        }
        let manager = PluginManager(pluginsDirectory: temporary, defaults: defaults,
                                    hostVersion: "0.9.0", bundledPluginsDirectory: nil)
        let examples: [(String, PluginActionOutput, Set<PluginCapability>)] = [
            ("ReadingColors", .appearancePanel, [.appearanceWrite]),
            ("MarkdownNotebook", .notesPanel, [.notesWrite, .fileReadWrite, .documentMetadata, .selectedText]),
            ("PageClipper", .pageClipPanel, [.pageImage, .clipboardWrite, .fileExport]),
            ("RelatedDocuments", .relatedDocumentsPanel, [.openDocumentsRead, .currentPageText, .workspaceNavigation]),
            ("HoverTranslator", .hoverTranslationPanel, [.hoverText, .localTranslation])
        ]
        for (name, output, capabilities) in examples {
            let url = project.appendingPathComponent("Examples/Plugins/\(name).hwattakplugin")
            let inspection = try manager.inspectPackage(at: url)
            XCTAssertEqual(inspection.manifest.schemaVersion, 4)
            XCTAssertTrue(inspection.manifest.identifier.hasPrefix("org.emberpdf.examples."))
            XCTAssertEqual(Set(inspection.manifest.capabilities), capabilities)
            XCTAssertEqual(inspection.manifest.actions.count, 1)
            let action = try XCTUnwrap(inspection.manifest.actions.first)
            XCTAssertEqual(action.output, output)
            XCTAssertEqual(action.template, "")
            XCTAssertNil(action.command)
            try manager.install(inspection, replacingExisting: false)
            XCTAssertTrue(manager.isInstalled(identifier: inspection.manifest.identifier))
            try manager.setEnabled(false, identifier: inspection.manifest.identifier)
        }
        manager.refresh()
        XCTAssertEqual(manager.installedPlugins.count, examples.count)
        XCTAssertTrue(manager.installedPlugins.allSatisfy { !$0.isEnabled })
    }
}
