// SPDX-License-Identifier: MPL-2.0
import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

/// These integration tests run the real JavaScript helper through reviewed,
/// hash-bound schema-6 packages. All files and preferences are test-owned;
/// collections have no recent-document or session-persistence store.
@MainActor
final class PluginExtensionHostTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var manager: PluginManager!
    private var hosts: [PluginExtensionHost] = []

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-ExtensionHost-\(UUID())")
        suite = "EmberPDF.ExtensionHostTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        manager = PluginManager(pluginsDirectory: root.appendingPathComponent("Installed"), defaults: defaults,
                                hostVersion: "1.0.0", bundledPluginsDirectory: nil)
    }

    override func tearDown() {
        hosts.forEach { $0.stop() }
        hosts = []
        manager = nil
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testStartupWithoutPDFRegistersCommandsAndExposesEmptyContext() async throws {
        let plugin = try install("empty", source: """
        ember.commands.register({id:'inspect',title:'Inspect context',run:async()=>{
          const context=await ember.call('app.getContext');
          await ember.ui.render({title:context.hasDocument?'Document':'No PDF',text:String(context.apiVersion)});
        }});
        """)
        let collection = MultiDocumentWorkspaceState()
        let host = try makeHost(collection)
        let session = try session(in: host, identifier: plugin.id)
        try await eventually { PluginRuntimeCommandRegistry.shared.commands(in: host.id).count == 1 }
        let command = try XCTUnwrap(PluginRuntimeCommandRegistry.shared.commands(in: host.id).first)
        PluginRuntimeCommandRegistry.shared.run(command.id, scope: host.id)
        try await eventually { session.view.title == "No PDF" }
        XCTAssertEqual(session.view.text, "1")
        XCTAssertFalse(collection.activeWorkspace?.hasOpenDocument == true)
        XCTAssertTrue(session.isRunning)
        XCTAssertNil(session.errorMessage)
    }

    func testSynchronousLoadHandlerRunsBeforeInitiallyQueuedAppReadyEvent() async throws {
        let plugin = try install("startup-order", source: """
        ember.on('load',()=>{
          ember.on('app.ready',context=>ember.ui.render({title:'Ready after load',text:String(context.apiVersion)}));
        });
        """)
        let host = try makeHost(MultiDocumentWorkspaceState())
        let session = try session(in: host, identifier: plugin.id)
        try await eventually { session.view.title == "Ready after load" }
        XCTAssertEqual(session.view.text, "1")
        XCTAssertTrue(session.isRunning)
    }

    func testClosingPresentationLeavesCommandsAndExtensionRunning() async throws {
        let plugin = try install("presentation", source: """
        let opened=0;
        ember.commands.register({id:'open',title:'Open panel',run:async()=>{
          await ember.ui.open();
          await ember.ui.render({title:'Opened '+(++opened)});
        }});
        ember.commands.register({id:'close',title:'Close panel',run:()=>ember.ui.close()});
        """)
        let host = try makeHost(MultiDocumentWorkspaceState())
        let session = try session(in: host, identifier: plugin.id)
        let registry = PluginRuntimeCommandRegistry.shared
        try await eventually { registry.commands(in: host.id).count == 2 }
        let open = try XCTUnwrap(registry.commands(in: host.id).first(where: { $0.title == "Open panel" }))
        let close = try XCTUnwrap(registry.commands(in: host.id).first(where: { $0.title == "Close panel" }))
        registry.run(open.id, scope: host.id)
        try await eventually { host.selectedIdentifier == plugin.id && session.view.title == "Opened 1" }
        host.selectedIdentifier = nil // The native panel's close control.
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(registry.commands(in: host.id).count, 2)
        registry.run(open.id, scope: host.id)
        try await eventually { host.selectedIdentifier == plugin.id && session.view.title == "Opened 2" }
        registry.run(close.id, scope: host.id)
        try await eventually { host.selectedIdentifier == nil }
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(registry.commands(in: host.id).count, 2)
        XCTAssertEqual(try self.session(in: host, identifier: plugin.id).id, session.id)
    }

    func testPageTabAndWorkspaceChangesDeliverEventsWithoutRestartingExtension() async throws {
        let plugin = try install("events", source: """
        const events=[];
        ember.commands.register({id:'present',title:'Present',run:()=>ember.ui.open()});
        for(const name of ['document.changed','documents.changed','workspace.changed','page.changed']) {
          ember.on(name,()=>{events.push(name);return ember.ui.render({title:'Events',text:events.join('|')})});
        }
        ember.on('load',()=>ember.ui.render({title:'Ready'}));
        """)
        let firstURL = try makePDF("first")
        let firstWorkspace = PDFWorkspaceState()
        XCTAssertTrue(firstWorkspace.open(url: firstURL))
        let firstTab = PDFTabSession(workspace: firstWorkspace)
        let collection = MultiDocumentWorkspaceState(initialSession: firstTab)
        let host = try makeHost(collection)
        let session = try self.session(in: host, identifier: plugin.id)
        try await eventually { session.view.title == "Ready" && session.commands.count == 1 }
        let originalID = session.id

        firstWorkspace.setCurrentPage(1)
        try await eventually { session.view.text?.contains("page.changed") == true }
        let secondTab = try XCTUnwrap(collection.addTab(opening: makePDF("second")))
        try await eventually {
            session.view.text?.contains("documents.changed") == true &&
                session.view.text?.contains("document.changed") == true
        }
        XCTAssertEqual(collection.activeTabID, secondTab)
        let changesBeforeReturn = occurrences("document.changed", in: session.view.text)
        collection.selectTab(firstTab.id)
        try await eventually { self.occurrences("document.changed", in: session.view.text) > changesBeforeReturn }
        _ = collection.createWorkspace(title: "Another test workspace")
        try await eventually { session.view.text?.contains("workspace.changed") == true }
        XCTAssertEqual(try self.session(in: host, identifier: plugin.id).id, originalID)
        XCTAssertEqual(PluginRuntimeCommandRegistry.shared.commands(in: host.id).count, 1)
        XCTAssertTrue(session.isRunning)
        XCTAssertNil(session.errorMessage)
    }

    func testTwoPluginsWithSameCommandIDCoexistAndAreWindowScoped() async throws {
        let firstPlugin = try install("first", source: commandSource(title: "First extension"))
        let secondPlugin = try install("second", source: commandSource(title: "Second extension"))
        let firstHost = try makeHost(MultiDocumentWorkspaceState())
        let secondHost = try makeHost(MultiDocumentWorkspaceState())
        let first = try session(in: firstHost, identifier: firstPlugin.id)
        let sibling = try session(in: firstHost, identifier: secondPlugin.id)
        let otherWindow = try session(in: secondHost, identifier: firstPlugin.id)
        let registry = PluginRuntimeCommandRegistry.shared
        try await eventually { registry.commands(in: firstHost.id).count == 2 && registry.commands(in: secondHost.id).count == 2 }
        let firstCommands = registry.commands(in: firstHost.id)
        let secondCommands = registry.commands(in: secondHost.id)
        XCTAssertEqual(Set((firstCommands + secondCommands).map(\.id)).count, 4)
        let command = try XCTUnwrap(firstCommands.first(where: { $0.title == "First extension" }))
        registry.run(command.id, scope: secondHost.id)
        registry.run(command.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(first.view.title)
        XCTAssertNil(otherWindow.view.title)
        registry.run(command.id, scope: firstHost.id)
        try await eventually { first.view.title == "First extension" }
        XCTAssertNil(sibling.view.title)
        XCTAssertNil(otherWindow.view.title)
        XCTAssertTrue((firstHost.extensions + secondHost.extensions).allSatisfy { $0.session.isRunning })
    }

    func testRevokingBackgroundExecutionStopsOnlyThatPlugin() async throws {
        let firstPlugin = try install("revoked", source: commandSource(title: "Revoked extension"))
        let secondPlugin = try install("retained", source: commandSource(title: "Retained extension"))
        let host = try makeHost(MultiDocumentWorkspaceState())
        let revoked = try session(in: host, identifier: firstPlugin.id)
        let retained = try session(in: host, identifier: secondPlugin.id)
        let registry = PluginRuntimeCommandRegistry.shared
        try await eventually { registry.commands(in: host.id).count == 2 }
        host.show(firstPlugin.id)
        try manager.setCapabilityGranted(.backgroundExecution, granted: false, identifier: firstPlugin.id)
        try await eventually { !revoked.isRunning && host.extensions.count == 1 && registry.commands(in: host.id).count == 1 }
        XCTAssertEqual(host.extensions.first?.id, secondPlugin.id)
        XCTAssertNil(host.selectedIdentifier)
        XCTAssertTrue(retained.isRunning)
        let command = try XCTUnwrap(registry.commands(in: host.id).first)
        registry.run(command.id, scope: host.id)
        try await eventually { retained.view.title == "Retained extension" }
        XCTAssertFalse(manager.isRuntimeAuthorized(pluginIdentifier: firstPlugin.id, manifestDigest: firstPlugin.manifestDigest))
    }

    func testReadOnlyPresentationBlocksDocumentCommandsWithoutDisablingExtension() async throws {
        let plugin = try install("presentation-policy", source: """
        ember.commands.register({id:'next',title:'Next page',run:async()=>{
          try {
            await ember.call('commands.execute',{kind:'nextPage'});
            await ember.ui.render({title:'Moved'});
          } catch(error) {
            await ember.ui.render({title:'Blocked'});
          }
        }});
        """, capabilities: [.backgroundExecution, .workspaceNavigation])
        let workspace = PDFWorkspaceState()
        let url = try makePDF("read-only-presentation")
        XCTAssertTrue(workspace.open(url: url))
        let host = try makeHost(MultiDocumentWorkspaceState(initialWorkspace: workspace))
        let session = try session(in: host, identifier: plugin.id)
        host.documentCommandsAllowed = false
        try await eventually { session.commands.count == 1 }
        session.command("next")
        try await eventually { session.view.title == "Blocked" }
        XCTAssertEqual(workspace.currentPageIndex, 0)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(PluginRuntimeCommandRegistry.shared.commands(in: host.id).count, 1)

        host.documentCommandsAllowed = true
        session.command("next")
        try await eventually { workspace.currentPageIndex == 1 && session.view.title == "Moved" }
        XCTAssertTrue(session.isRunning)
        XCTAssertNil(session.errorMessage)
    }

    func testStoppingWindowRemovesItsWorkersAndCommandsWithoutStoppingOtherWindow() async throws {
        _ = try install("one", source: commandSource(title: "One"))
        _ = try install("two", source: commandSource(title: "Two"))
        let firstHost = try makeHost(MultiDocumentWorkspaceState())
        let secondHost = try makeHost(MultiDocumentWorkspaceState())
        let registry = PluginRuntimeCommandRegistry.shared
        try await eventually { registry.commands(in: firstHost.id).count == 2 && registry.commands(in: secondHost.id).count == 2 }
        let stopped = firstHost.extensions.map(\.session)
        firstHost.stop()
        XCTAssertTrue(stopped.allSatisfy { !$0.isRunning && $0.commands.isEmpty })
        XCTAssertTrue(firstHost.extensions.isEmpty)
        XCTAssertNil(firstHost.selectedIdentifier)
        XCTAssertTrue(registry.commands(in: firstHost.id).isEmpty)
        XCTAssertEqual(registry.commands(in: secondHost.id).count, 2)
        XCTAssertTrue(secondHost.extensions.allSatisfy { $0.session.isRunning })
        let command = try XCTUnwrap(registry.commands(in: secondHost.id).first)
        registry.run(command.id, scope: secondHost.id)
        try await eventually { secondHost.extensions.contains { $0.session.view.title == command.title } }
    }

    private func makeHost(_ collection: MultiDocumentWorkspaceState) throws -> PluginExtensionHost {
        let helper = try XCTUnwrap(PluginScriptSession.helperURL, "Build EmberPluginWorker before running host integration tests")
        let host = PluginExtensionHost(collection: collection, manager: manager, defaults: defaults, helperURL: helper)
        hosts.append(host)
        host.start()
        return host
    }

    private func session(in host: PluginExtensionHost, identifier: String) throws -> PluginScriptSession {
        try XCTUnwrap(host.extensions.first(where: { $0.id == identifier })?.session)
    }

    private func install(_ suffix: String, source: String,
                         capabilities: [PluginCapability] = [.backgroundExecution]) throws -> InstalledPlugin {
        let identifier = "org.emberpdf.tests." + suffix
        let bytes = Data(source.utf8)
        let manifest = PluginManifest(schemaVersion: 6, identifier: identifier, displayName: suffix,
            version: "1.0.0", author: "Tests", description: "Window extension integration fixture", minimumHostVersion: nil,
            capabilities: capabilities, actions: [],
            runtime: .init(apiVersion: 1, entry: "main.js", sha256: PluginPackageValidator.sha256Hex(bytes),
                           activation: "window", capabilities: capabilities))
        let package = root.appendingPathComponent(suffix + ".hwattakplugin")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        try bytes.write(to: package.appendingPathComponent("main.js"))
        try manager.install(manager.inspectPackage(at: package), replacingExisting: false)
        return try XCTUnwrap(manager.installedPlugins.first(where: { $0.id == identifier }))
    }

    private func makePDF(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name + ".pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for _ in 0..<3 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
        return url
    }

    private func commandSource(title: String) -> String {
        // Test titles above contain only ASCII letters/spaces.
        "ember.commands.register({id:'same',title:'\(title)',run:()=>ember.ui.render({title:'\(title)'})});"
    }

    private func occurrences(_ event: String, in text: String?) -> Int {
        (text ?? "").components(separatedBy: "|").filter { $0 == event }.count
    }

    private func eventually(seconds: Double = 4, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(condition(), "Host condition did not become true within \(seconds) seconds")
    }
}
