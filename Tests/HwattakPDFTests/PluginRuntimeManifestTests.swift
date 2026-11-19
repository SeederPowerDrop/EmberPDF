// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import HwattakPDF

@MainActor
final class PluginRuntimeManifestTests: XCTestCase {
    private let source = Data("ember.on('load', () => ember.ui.render({title: 'Extension'}));".utf8)

    func testWindowRuntimeAllowsEmptyActionsAndBindsExactCapabilityUnion() throws {
        let value = manifest()
        let decoded = try PluginManifestValidator().decodeAndValidate(JSONEncoder().encode(value))
        XCTAssertEqual(decoded.runtime?.apiVersion, 1)
        XCTAssertEqual(decoded.runtime?.activation, "window")
        XCTAssertTrue(decoded.actions.isEmpty)
        XCTAssertEqual(Set(decoded.capabilities), [.backgroundExecution, .documentTextRead])
        let action = PluginActionManifest(id: "hello", title: "Hello", description: nil,
                                          output: .showText, template: "{{selection}}")
        let withAction = manifest(actions: [action], capabilities: [.backgroundExecution, .documentTextRead, .selectedText])
        try PluginManifestValidator().validate(withAction)
        XCTAssertThrowsError(try PluginManifestValidator().validate(manifest(actions: [action])))
    }

    func testRuntimeObjectRejectsUnknownDuplicateOrWrongTypedFields() throws {
        let data = try JSONEncoder().encode(manifest())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var runtime = try XCTUnwrap(object["runtime"] as? [String: Any])
        runtime["network"] = true
        object["runtime"] = runtime
        XCTAssertThrowsError(try PluginManifestValidator().decodeAndValidate(JSONSerialization.data(withJSONObject: object)))
        object["runtime"] = NSNull()
        XCTAssertThrowsError(try PluginManifestValidator().decodeAndValidate(JSONSerialization.data(withJSONObject: object)))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let duplicated = json.replacingOccurrences(of: "\"apiVersion\":1", with: "\"apiVersion\":1,\"apiVersion\":1")
        XCTAssertNotEqual(json, duplicated)
        XCTAssertThrowsError(try PluginManifestValidator().decodeAndValidate(Data(duplicated.utf8)))
    }

    func testRuntimeRequiresSchemaAPISafeEntryActivationHashAndExplicitExecutionGrant() throws {
        let valid = try JSONEncoder().encode(manifest())
        let mutations: [(String, Any)] = [
            ("apiVersion", 2), ("entry", "../main.js"), ("entry", "worker.js"),
            ("activation", "startup"), ("sha256", String(repeating: "A", count: 64)),
            ("sha256", "bad"), ("capabilities", ["documentTextRead"]),
            ("capabilities", ["backgroundExecution", "externalURL"]),
            ("capabilities", ["backgroundExecution", "backgroundExecution", "documentTextRead"])
        ]
        for (key, replacement) in mutations {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            var runtime = try XCTUnwrap(object["runtime"] as? [String: Any])
            runtime[key] = replacement
            object["runtime"] = runtime
            XCTAssertThrowsError(try PluginManifestValidator().decodeAndValidate(JSONSerialization.data(withJSONObject: object)), key)
        }
        for schema in 1...5 {
            XCTAssertThrowsError(try PluginManifestValidator().validate(manifest(schema: schema)))
        }
        XCTAssertThrowsError(try PluginManifestValidator().validate(manifest(capabilities: [.backgroundExecution])))
        XCTAssertThrowsError(try PluginManifestValidator().validate(manifest(capabilities: [.backgroundExecution, .documentTextRead, .selectedText])))
    }

    func testRuntimeCannotSharePackageCodeWithLegacyScriptPanel() throws {
        let action = PluginActionManifest(id: "open", title: "Open", description: nil,
            output: .scriptPanel, template: "", scriptSHA256: PluginPackageValidator.sha256Hex(source), scriptCapabilities: [])
        XCTAssertThrowsError(try PluginManifestValidator().validate(manifest(actions: [action])))
        let scriptWithBackground = PluginActionManifest(id: "open", title: "Open", description: nil,
            output: .scriptPanel, template: "", scriptSHA256: PluginPackageValidator.sha256Hex(source),
            scriptCapabilities: [.backgroundExecution])
        var legacy = manifest(actions: [scriptWithBackground], capabilities: [.backgroundExecution])
        legacy.runtime = nil
        XCTAssertThrowsError(try PluginManifestValidator().validate(legacy))
    }

    func testRuntimePackageRequiresExactSourceAndRechecksInstalledSnapshot() throws {
        try withFixture { root, defaults in
            let manager = manager(root: root, defaults: defaults)
            let package = try writeSource(manifest(), root: root)
            let inspection = try manager.inspectPackage(at: package)
            XCTAssertEqual(inspection.filePayloads["main.js"], source)
            try manager.install(inspection, replacingExisting: false)
            let plugin = try XCTUnwrap(manager.installedPlugins.first)
            let installed = try PluginPackageValidator().inspectInstalledPackage(at: plugin.installURL)
            XCTAssertEqual(installed.package.filePayloads["main.js"], source)
            try Data("while (true) {}".utf8).write(to: plugin.installURL.appendingPathComponent("main.js"))
            XCTAssertThrowsError(try PluginPackageValidator().inspectInstalledPackage(at: plugin.installURL))
            manager.refresh()
            XCTAssertTrue(manager.installedPlugins.isEmpty)
            XCTAssertFalse(manager.isRuntimeAuthorized(pluginIdentifier: plugin.id, manifestDigest: plugin.manifestDigest))
        }
    }

    func testRuntimeAuthorizationStopsOnPermissionSafeModeDisableAndUninstall() throws {
        try withFixture { root, defaults in
            let manager = manager(root: root, defaults: defaults)
            let inspection = try manager.inspectPackage(at: writeSource(manifest(), root: root))
            try manager.install(inspection, replacingExisting: false)
            let plugin = try XCTUnwrap(manager.installedPlugins.first)
            @MainActor func authorized() -> Bool {
                manager.isRuntimeAuthorized(pluginIdentifier: plugin.id, manifestDigest: plugin.manifestDigest)
            }
            XCTAssertTrue(authorized())
            try manager.setCapabilityGranted(.documentTextRead, granted: false, identifier: plugin.id)
            XCTAssertFalse(authorized())
            try manager.setCapabilityGranted(.documentTextRead, granted: true, identifier: plugin.id)
            XCTAssertTrue(authorized())
            try manager.setCapabilityGranted(.backgroundExecution, granted: false, identifier: plugin.id)
            XCTAssertFalse(authorized())
            let reloaded = self.manager(root: root, defaults: defaults)
            XCTAssertFalse(reloaded.isRuntimeAuthorized(pluginIdentifier: plugin.id, manifestDigest: plugin.manifestDigest))
            try manager.setCapabilityGranted(.backgroundExecution, granted: true, identifier: plugin.id)
            manager.setSafeModeEnabled(true)
            XCTAssertFalse(authorized())
            manager.setSafeModeEnabled(false)
            XCTAssertTrue(authorized())
            try manager.setEnabled(false, identifier: plugin.id)
            XCTAssertFalse(authorized())
            try manager.setEnabled(true, identifier: plugin.id)
            XCTAssertTrue(authorized())
            try manager.uninstall(identifier: plugin.id)
            XCTAssertFalse(authorized())
        }
    }

    func testRuntimeOnDiskNeverInheritsFirstLaunchLegacyApproval() throws {
        try withFixture { root, defaults in
            let installedURL = root.appendingPathComponent("Installed/org.example.runtime.hwattakplugin")
            try writeSource(manifest(), root: root, at: installedURL)
            try writeRecord(for: manifest(), at: installedURL)
            XCTAssertNil(defaults.object(forKey: PluginPermissionStore.defaultsKey))
            let firstLaunch = manager(root: root, defaults: defaults)
            let plugin = try XCTUnwrap(firstLaunch.installedPlugins.first)
            XCTAssertFalse(firstLaunch.isRuntimeAuthorized(pluginIdentifier: plugin.id, manifestDigest: plugin.manifestDigest))
            XCTAssertFalse(firstLaunch.isCapabilityGranted(.backgroundExecution, for: plugin.id))
            XCTAssertThrowsError(try firstLaunch.setCapabilityGranted(.backgroundExecution, granted: true, identifier: plugin.id))
        }
    }

    func testRuntimeReplacementRequiresReviewAndPreservesRevokedPermission() throws {
        try withFixture { root, defaults in
            let manager = manager(root: root, defaults: defaults)
            try manager.install(manager.inspectPackage(at: writeSource(manifest(), root: root)), replacingExisting: false)
            let first = try XCTUnwrap(manager.installedPlugins.first)
            try manager.setCapabilityGranted(.backgroundExecution, granted: false, identifier: first.id)
            let updated = manifest(version: "2.0.0")
            try encodedManifest(updated).write(to: first.installURL.appendingPathComponent("manifest.json"))
            try writeRecord(for: updated, at: first.installURL)
            manager.refresh()
            let second = try XCTUnwrap(manager.installedPlugins.first)
            XCTAssertNotEqual(first.manifestDigest, second.manifestDigest)
            XCTAssertFalse(manager.isRuntimeAuthorized(pluginIdentifier: second.id, manifestDigest: second.manifestDigest))
            try manager.install(manager.inspectPackage(at: writeSource(updated, root: root)), replacingExisting: true)
            XCTAssertFalse(manager.isRuntimeAuthorized(pluginIdentifier: second.id, manifestDigest: second.manifestDigest))
            try manager.setCapabilityGranted(.backgroundExecution, granted: true, identifier: second.id)
            XCTAssertTrue(manager.isRuntimeAuthorized(pluginIdentifier: second.id, manifestDigest: second.manifestDigest))
            XCTAssertFalse(manager.isRuntimeAuthorized(pluginIdentifier: first.id, manifestDigest: first.manifestDigest))
        }
    }

    private func manifest(schema: Int = 6, version: String = "1.0.0", actions: [PluginActionManifest] = [],
                          capabilities: [PluginCapability] = [.backgroundExecution, .documentTextRead]) -> PluginManifest {
        PluginManifest(schemaVersion: schema, identifier: "org.example.runtime", displayName: "Extension",
            version: version, author: "Tests", description: "Runtime boundary fixture", minimumHostVersion: nil,
            capabilities: capabilities, actions: actions,
            runtime: .init(apiVersion: 1, entry: "main.js", sha256: PluginPackageValidator.sha256Hex(source),
                           activation: "window", capabilities: [.backgroundExecution, .documentTextRead]))
    }

    @discardableResult
    private func writeSource(_ value: PluginManifest, root: URL, at destination: URL? = nil) throws -> URL {
        let package = destination ?? root.appendingPathComponent("Source-\(UUID()).hwattakplugin")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try encodedManifest(value).write(to: package.appendingPathComponent("manifest.json"))
        try source.write(to: package.appendingPathComponent("main.js"))
        return package
    }

    private func writeRecord(for value: PluginManifest, at url: URL) throws {
        // The record hashes the exact installed manifest bytes, just like the
        // installer. It is integrity metadata, never an approval credential.
        let bytes = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        let record = PluginInstallationRecord(schemaVersion: 1,
            manifestSHA256: PluginPackageValidator.sha256Hex(bytes), installedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url.appendingPathComponent("installation.json"))
    }

    private func manager(root: URL, defaults: UserDefaults) -> PluginManager {
        PluginManager(pluginsDirectory: root.appendingPathComponent("Installed"), defaults: defaults,
                      hostVersion: "1.0.0", bundledPluginsDirectory: nil)
    }

    private func encodedManifest(_ value: PluginManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func withFixture(_ body: (URL, UserDefaults) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-RuntimeContract-\(UUID())")
        let suite = "EmberPDF.RuntimeContract.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try body(root, defaults)
    }
}
