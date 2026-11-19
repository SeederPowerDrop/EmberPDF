// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

@MainActor
final class PluginPermissionTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-PluginPermissions-\(UUID())")
        suite = "EmberPDF.PluginPermissions.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        defaults = nil
        super.tearDown()
    }

    func testRevokingOneCapabilityDisablesOnlyDependentActionsAndPersists() throws {
        let manager = manager()
        let plugin = try install(manifest(actions: [selectionAction, plainAction]), into: manager)
        XCTAssertTrue(authorized(plugin, action: selectionAction, manager: manager))
        XCTAssertEqual(manager.enabledActionCount, 2)
        try manager.setCapabilityGranted(.selectedText, granted: false, identifier: plugin.id)
        XCTAssertFalse(authorized(plugin, action: selectionAction, manager: manager))
        XCTAssertTrue(authorized(plugin, action: plainAction, manager: manager))
        XCTAssertEqual(manager.enabledActionCount, 1)
        let reloaded = self.manager()
        XCTAssertFalse(reloaded.isCapabilityGranted(.selectedText, for: plugin.id))
        XCTAssertFalse(authorized(plugin, action: selectionAction, manager: reloaded))
        try reloaded.setCapabilityGranted(.selectedText, granted: true, identifier: plugin.id)
        XCTAssertTrue(authorized(plugin, action: selectionAction, manager: reloaded))
        XCTAssertThrowsError(try reloaded.setCapabilityGranted(.externalURL, granted: true, identifier: plugin.id))
    }

    func testReviewedUpdateGrantsNewCapabilityButPreservesExplicitDenials() throws {
        let manager = manager()
        let first = try install(manifest(actions: [selectionAction]), into: manager)
        try manager.setCapabilityGranted(.selectedText, granted: false, identifier: first.id)
        let copy = PluginActionManifest(id: "copy", title: "Copy", description: nil, output: .copyText, template: "{{selection}}")
        let second = try install(manifest(version: "2.0.0", actions: [selectionAction, copy]), into: manager, replacing: true)
        XCTAssertNotEqual(first.manifestDigest, second.manifestDigest)
        XCTAssertFalse(manager.isCapabilityGranted(.selectedText, for: second.id))
        XCTAssertTrue(manager.isCapabilityGranted(.clipboardWrite, for: second.id))
        XCTAssertFalse(authorized(second, action: copy, manager: manager))
        XCTAssertFalse(authorized(first, action: selectionAction, manager: manager))
        try manager.setCapabilityGranted(.selectedText, granted: true, identifier: second.id)
        XCTAssertTrue(authorized(second, action: copy, manager: manager))
    }

    func testDiskReplacementCannotAcquireApprovalEvenWithMatchingIntegrityRecord() throws {
        let manager = manager()
        let first = try install(manifest(actions: [plainAction]), into: manager)
        let replacement = manifest(version: "2.0.0", actions: [plainAction, externalAction])
        try writeInstalled(replacement, to: first.installURL)
        manager.refresh()
        let changed = try XCTUnwrap(manager.installedPlugins.first)
        XCTAssertFalse(authorized(changed, action: externalAction, manager: manager))
        // Even a zero-capability action is bound to reviewed bytes.
        XCTAssertFalse(authorized(changed, action: plainAction, manager: manager))
        XCTAssertThrowsError(try manager.setCapabilityGranted(.externalURL, granted: true, identifier: changed.id))
        let reviewed = try install(replacement, into: manager, replacing: true)
        XCTAssertTrue(authorized(reviewed, action: externalAction, manager: manager))
    }

    func testLaterUnreviewedDiskAdditionIsDeniedAcrossRelaunch() throws {
        let manager = manager()
        let value = manifest(actions: [plainAction])
        let url = manager.pluginsDirectory.appendingPathComponent("\(value.identifier).hwattakplugin")
        try writeInstalled(value, to: url)
        manager.refresh()
        let plugin = try XCTUnwrap(manager.installedPlugins.first)
        XCTAssertFalse(authorized(plugin, action: plainAction, manager: manager))
        XCTAssertFalse(authorized(plugin, action: plainAction, manager: self.manager()))
    }

    func testLegacyInstalledApprovalsMigrateOnceAndDisabledStateIsRetained() throws {
        let original = manager()
        let plugin = try install(manifest(actions: [externalAction]), into: original)
        try original.setEnabled(false, identifier: plugin.id)
        defaults.removeObject(forKey: PluginPermissionStore.defaultsKey)
        let migrated = manager()
        XCTAssertTrue(migrated.isCapabilityGranted(.externalURL, for: plugin.id))
        XCTAssertFalse(authorized(plugin, action: externalAction, manager: migrated))
        try migrated.setEnabled(true, identifier: plugin.id)
        XCTAssertTrue(authorized(plugin, action: externalAction, manager: migrated))
        XCTAssertNotNil(defaults.data(forKey: PluginPermissionStore.defaultsKey))
    }

    func testCorruptApprovalArchiveFailsClosedInsteadOfMigrating() throws {
        let original = manager()
        let plugin = try install(manifest(actions: [plainAction, externalAction]), into: original)
        defaults.set(Data("{broken".utf8), forKey: PluginPermissionStore.defaultsKey)
        let reloaded = manager()
        XCTAssertFalse(authorized(plugin, action: plainAction, manager: reloaded))
        XCTAssertFalse(authorized(plugin, action: externalAction, manager: reloaded))
        XCTAssertThrowsError(try reloaded.setCapabilityGranted(.externalURL, granted: true, identifier: plugin.id))
    }

    func testFirstLaunchDoesNotMigrateNewHostPanelsOrExecutablePackages() throws {
        let source = Data("ember.on('load', () => ember.ui.render({title: 'Unreviewed'}));".utf8)
        let panel = PluginActionManifest(id: "appearance", title: "Appearance", description: nil,
                                         output: .appearancePanel, template: "")
        let script = PluginActionManifest(id: "script", title: "Script", description: nil,
                                          output: .scriptPanel, template: "",
                                          scriptSHA256: PluginPackageValidator.sha256Hex(source),
                                          scriptCapabilities: [])
        let values = [
            manifest(schemaVersion: 4, identifier: "org.example.unreviewed-panel", actions: [panel]),
            manifest(schemaVersion: 5, identifier: "org.example.unreviewed-script", actions: [script])
        ]
        // Simulate packages and matching integrity records already on disk
        // before the first launch creates the host-owned approval archive.
        for value in values {
            let url = root.appendingPathComponent("Installed/\(value.identifier).hwattakplugin")
            try writeInstalled(value, to: url)
            if value.schemaVersion == 5 { try source.write(to: url.appendingPathComponent("main.js")) }
        }
        XCTAssertNil(defaults.object(forKey: PluginPermissionStore.defaultsKey))
        let firstLaunch = manager()
        XCTAssertEqual(firstLaunch.installedPlugins.count, 2, "Valid packages should remain available for explicit review")
        for plugin in firstLaunch.installedPlugins {
            XCTAssertFalse(authorized(plugin, action: plugin.manifest.actions[0], manager: firstLaunch))
            XCTAssertFalse(authorized(plugin, action: plugin.manifest.actions[0], manager: manager()))
        }
        XCTAssertNotNil(defaults.data(forKey: PluginPermissionStore.defaultsKey))
    }

    func testSafeModeStopsAllActionsPersistsAndPreservesIndividualChoices() throws {
        let manager = manager()
        let plugin = try install(manifest(actions: [plainAction, externalAction]), into: manager)
        try manager.setCapabilityGranted(.externalURL, granted: false, identifier: plugin.id)
        manager.setSafeModeEnabled(true)
        XCTAssertTrue(manager.enabledPlugins.isEmpty)
        XCTAssertEqual(manager.enabledActionCount, 0)
        XCTAssertFalse(authorized(plugin, action: plainAction, manager: manager))
        let reloaded = self.manager()
        XCTAssertTrue(reloaded.isSafeModeEnabled)
        reloaded.setSafeModeEnabled(false)
        XCTAssertTrue(authorized(plugin, action: plainAction, manager: reloaded))
        XCTAssertFalse(authorized(plugin, action: externalAction, manager: reloaded))
    }

    func testLauncherRejectsRevocationBetweenConsentAndExternalEffect() throws {
        let manager = manager()
        let plugin = try install(manifest(actions: [externalAction]), into: manager)
        var opened = false
        let environment = PluginRuntimeEnvironment(
            showText: { _, _ in XCTFail("unexpected text") },
            writeClipboard: { _ in XCTFail("unexpected clipboard"); return false },
            approveExternalURL: { _, _, _ in
                try! manager.setCapabilityGranted(.externalURL, granted: false, identifier: plugin.id)
                return true
            },
            openExternalURL: { _ in opened = true; return true }
        )
        XCTAssertThrowsError(try PluginActionLauncher.run(
            manager: manager, plugin: plugin, action: externalAction, workspace: nil,
            runner: PluginActionRunner(environment: environment)
        ))
        XCTAssertFalse(opened)
    }

    func testLauncherRejectsSafeModeBeforeAnyEffect() throws {
        let manager = manager()
        let plugin = try install(manifest(actions: [plainAction]), into: manager)
        manager.setSafeModeEnabled(true)
        let environment = PluginRuntimeEnvironment(
            showText: { _, _ in XCTFail("safe mode executed an action") },
            writeClipboard: { _ in XCTFail("unexpected clipboard"); return false },
            approveExternalURL: { _, _, _ in XCTFail("unexpected consent"); return false },
            openExternalURL: { _ in XCTFail("unexpected URL"); return false }
        )
        XCTAssertThrowsError(try PluginActionLauncher.run(
            manager: manager, plugin: plugin, action: plainAction, workspace: nil,
            runner: PluginActionRunner(environment: environment)
        ))
    }

    func testUninstallRemovesApprovalAndReinstallUsesFreshExplicitReview() throws {
        let manager = manager()
        let value = manifest(actions: [externalAction])
        let plugin = try install(value, into: manager)
        try manager.setCapabilityGranted(.externalURL, granted: false, identifier: plugin.id)
        defaults.set(Data("previous private note".utf8), forKey: "plugins.scriptData.v1." + plugin.id)
        try manager.uninstall(identifier: plugin.id)
        XCTAssertFalse(authorized(plugin, action: externalAction, manager: manager))
        XCTAssertNil(defaults.object(forKey: "plugins.scriptData.v1." + plugin.id))
        let replacement = try install(value, into: manager)
        XCTAssertTrue(authorized(replacement, action: externalAction, manager: manager))
    }

    private var selectionAction: PluginActionManifest {
        PluginActionManifest(id: "selection", title: "Selection", description: nil, output: .showText, template: "{{selection}}")
    }

    private var plainAction: PluginActionManifest {
        PluginActionManifest(id: "plain", title: "Plain", description: nil, output: .showText, template: "Hello")
    }

    private var externalAction: PluginActionManifest {
        PluginActionManifest(id: "external", title: "External", description: nil, output: .openURL, template: "https://example.com/")
    }

    private func manifest(schemaVersion: Int = 1, identifier: String = "org.example.permission-test",
                          version: String = "1.0.0", actions: [PluginActionManifest]) -> PluginManifest {
        PluginManifest(
            schemaVersion: schemaVersion, identifier: identifier, displayName: "Permission test",
            version: version, author: "Tests", description: "Permission boundary fixture", minimumHostVersion: nil,
            capabilities: Array(actions.reduce(into: Set<PluginCapability>()) { $0.formUnion($1.requiredCapabilities) }).sorted { $0.rawValue < $1.rawValue },
            actions: actions
        )
    }

    private func manager() -> PluginManager {
        PluginManager(pluginsDirectory: root.appendingPathComponent("Installed"), defaults: defaults,
                      hostVersion: "1.0.0", bundledPluginsDirectory: nil)
    }

    private func install(_ manifest: PluginManifest, into manager: PluginManager, replacing: Bool = false) throws -> InstalledPlugin {
        let source = root.appendingPathComponent("Source-\(UUID()).hwattakplugin")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("manifest.json"))
        try manager.install(manager.inspectPackage(at: source), replacingExisting: replacing)
        return try XCTUnwrap(manager.installedPlugins.first)
    }

    private func writeInstalled(_ manifest: PluginManifest, to url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url.appendingPathComponent("manifest.json"))
        let record = PluginInstallationRecord(schemaVersion: 1, manifestSHA256: PluginPackageValidator.sha256Hex(data), installedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url.appendingPathComponent("installation.json"))
    }

    private func authorized(_ plugin: InstalledPlugin, action: PluginActionManifest, manager: PluginManager) -> Bool {
        manager.isAuthorized(pluginIdentifier: plugin.id, manifestDigest: plugin.manifestDigest, actionID: action.id)
    }
}
