// SPDX-License-Identifier: MPL-2.0
import Foundation
import Combine
import XCTest
@testable import HwattakPDF

@MainActor
final class PluginScriptSessionTests: XCTestCase {
    func testWorkerAsyncAPICommandsAndEventsRenderNativeJSON() async throws {
        let session = PluginScriptSession()
        defer { session.stop() }
        var called = 0
        try session.start(source: """
        ember.on('load', async () => {
          const info = await ember.call('document.getInfo');
          await ember.ui.render({title:info.name, text:typeof fetch + '/' + typeof require + '/' + typeof __post});
          await ember.commands.register({id:'test',title:'Test',run:()=>ember.ui.render({title:'command'})});
        });
        ember.on('page.changed', () => ember.ui.render({title:'changed'}));
        """, isAuthorized: { true }) { method, _ in
            XCTAssertEqual(method, "document.getInfo"); called += 1
            return ["name": "Example"]
        }
        try await eventually { session.commands.count == 1 }
        XCTAssertEqual(session.view.title, "Example")
        XCTAssertEqual(session.view.text, "undefined/undefined/undefined")
        XCTAssertEqual(called, 1)
        session.command("test")
        try await eventually { session.view.title == "command" }
        session.event("page.changed")
        try await eventually { session.view.title == "changed" }
    }

    func testInfiniteLoopIsKilledAndAnotherPluginCanStart() async throws {
        let session = PluginScriptSession()
        defer { session.stop() }
        try session.start(source: "while (true) {}", isAuthorized: { true }) { _, _ in NSNull() }
        try await eventually(seconds: 5) { !session.isRunning }
        XCTAssertEqual(session.errorMessage, PluginScriptError.timeout.localizedDescription)
        try session.start(source: "ember.on('load',()=>ember.ui.render({title:'Recovered'}));", isAuthorized: { true }) { _, _ in NSNull() }
        try await eventually { session.view.title == "Recovered" }
    }

    func testRevocationStopsOnlyItsOwnerWhileAnotherSessionContinues() async throws {
        var allowed = true
        let first = PluginScriptSession(), second = PluginScriptSession()
        defer { first.stop(); second.stop() }
        try first.start(source: "ember.on('load',()=>ember.ui.render({title:'First'}));", isAuthorized: { allowed }) { _, _ in NSNull() }
        try second.start(source: """
        ember.on('load',()=>ember.ui.render({title:'Second'}));
        ember.on('page.changed',()=>ember.ui.render({title:'Still active'}));
        """, isAuthorized: { true }) { _, _ in NSNull() }
        try await eventually { first.view.title == "First" && second.view.title == "Second" }
        XCTAssertTrue(first.isRunning)
        allowed = false
        first.event("page.changed")
        XCTAssertFalse(first.isRunning)
        second.event("page.changed")
        try await eventually { second.view.title == "Still active" }
        XCTAssertTrue(second.isRunning)
    }

    func testCommandsAreNamespacedAndRoutedToExactlyOneWindow() async throws {
        let first = PluginScriptSession(), second = PluginScriptSession(), third = PluginScriptSession()
        defer { first.stop(); second.stop(); third.stop() }
        let window = UUID(), otherWindow = UUID()
        let source = "ember.commands.register({id:'same',title:'Same command',run:()=>ember.ui.render({title:'Invoked'})});"
        try first.start(source: source, commandScope: window, commandOwnerName: "First", isAuthorized: { true }) { _, _ in NSNull() }
        try second.start(source: source, commandScope: window, commandOwnerName: "Second", isAuthorized: { true }) { _, _ in NSNull() }
        try third.start(source: source, commandScope: otherWindow, commandOwnerName: "Other window", isAuthorized: { true }) { _, _ in NSNull() }
        let registry = PluginRuntimeCommandRegistry.shared
        try await eventually { registry.commands(in: window).count == 2 && registry.commands(in: otherWindow).count == 1 }
        let commands = registry.commands(in: window)
        XCTAssertEqual(Set(commands.map(\.id)).count, 2)
        XCTAssertTrue(registry.commands.isEmpty)
        let command = try XCTUnwrap(commands.first(where: { $0.ownerName == "First" }))
        registry.run(command.id, scope: otherWindow)
        registry.run(command.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(first.view.title)
        XCTAssertNil(third.view.title)
        registry.run(command.id, scope: window)
        try await eventually { first.view.title == "Invoked" }
        XCTAssertNil(second.view.title)
        first.stop()
        XCTAssertEqual(registry.commands(in: window).map(\.ownerName), ["Second"])
        XCTAssertEqual(registry.commands(in: otherWindow).count, 1)
    }

    func testWorkerFailureDoesNotRemoveAnotherOwnersCommands() async throws {
        let failed = PluginScriptSession(), healthy = PluginScriptSession()
        defer { failed.stop(); healthy.stop() }
        let scope = UUID()
        try healthy.start(source: "ember.commands.register({id:'ok',title:'Healthy',run:()=>ember.ui.render({title:'Alive'})});",
                          commandScope: scope, isAuthorized: { true }) { _, _ in NSNull() }
        try failed.start(source: """
        ember.commands.register({id:'bad',title:'Failure',run:()=>{throw new Error('isolated failure')}});
        """, commandScope: scope, isAuthorized: { true }) { _, _ in NSNull() }
        let registry = PluginRuntimeCommandRegistry.shared
        try await eventually { registry.commands(in: scope).count == 2 }
        failed.command("bad")
        try await eventually { !failed.isRunning }
        XCTAssertTrue(failed.errorMessage?.contains("isolated failure") == true)
        XCTAssertTrue(healthy.isRunning)
        let command = try XCTUnwrap(registry.commands(in: scope).first)
        XCTAssertEqual(command.title, "Healthy")
        registry.run(command.id, scope: scope)
        try await eventually { healthy.view.title == "Alive" }
    }

    func testConcurrentSessionBudgetRejectsNewWorkerWithoutStoppingExistingWorkers() async throws {
        let sessions = (0..<PluginScriptSession.maximumConcurrentSessions).map { _ in PluginScriptSession() }
        let extra = PluginScriptSession()
        defer { sessions.forEach { $0.stop() }; extra.stop() }
        for session in sessions {
            try session.start(source: "ember.on('load',()=>ember.ui.render({title:'Ready'}));", isAuthorized: { true }) { _, _ in NSNull() }
        }
        try await eventually { sessions.allSatisfy { $0.view.title == "Ready" } }
        XCTAssertThrowsError(try extra.start(source: "", isAuthorized: { true }) { _, _ in NSNull() }) { error in
            XCTAssertEqual(error.localizedDescription, PluginScriptError.limit.localizedDescription)
        }
        XCTAssertTrue(sessions.allSatisfy(\.isRunning))
        sessions[0].stop()
        try extra.start(source: "ember.ui.render({title:'Replacement'});", isAuthorized: { true }) { _, _ in NSNull() }
        try await eventually { extra.view.title == "Replacement" }
        XCTAssertTrue(sessions.dropFirst().allSatisfy(\.isRunning))
    }

    func testDocumentChangeCancelsStaleResponseWithoutTerminatingExtension() async throws {
        let session = PluginScriptSession()
        var delayed: CheckedContinuation<Any, Never>?
        defer { delayed?.resume(returning: NSNull()); session.stop() }
        try session.start(source: """
        ember.on('load', async () => {
          const value = await ember.call('document.getPageText');
          await ember.ui.render({title:value});
        });
        ember.on('document.changed', async () => {
          const value = await ember.call('document.getInfo');
          await ember.ui.render({title:value});
        });
        """, isAuthorized: { true }) { method, _ in
            if method == "document.getPageText" { return await withCheckedContinuation { delayed = $0 } }
            XCTAssertEqual(method, "document.getInfo")
            return "Fresh document"
        }
        try await eventually { delayed != nil }
        session.cancelPendingRequests()
        delayed?.resume(returning: "STALE DOCUMENT DATA"); delayed = nil
        session.event("document.changed")
        try await eventually { session.view.title == "Fresh document" }
        XCTAssertTrue(session.isRunning)
        XCTAssertNil(session.errorMessage)
    }

    func testTypedHostContextChangeIsCancellationAndKeepsNextCommandAvailable() async throws {
        let session = PluginScriptSession()
        defer { session.stop() }
        var called = false
        try session.start(source: """
        ember.commands.register({id:'next',title:'Next operation',run:()=>ember.ui.render({title:'Still active'})});
        ember.on('load',async()=>{
          await ember.call('document.getPageText');
          await ember.ui.render({title:'Stale continuation must not run'});
        });
        """, isAuthorized: { true }) { method, _ in
            XCTAssertEqual(method, "document.getPageText")
            called = true
            throw PluginScriptError.contextChanged
        }
        try await eventually { called && session.commands.count == 1 }
        session.command("next")
        try await eventually { session.view.title == "Still active" }
        XCTAssertTrue(session.isRunning)
        XCTAssertNil(session.errorMessage)
    }

    func testPendingCommandRegistrationSurvivesConcurrentDocumentCancellation() async throws {
        let session = PluginScriptSession()
        defer { session.stop() }
        var cancelledDuringRegistration = false
        // @Published emits synchronously while ui.commands is being handled:
        // cancel before its host response is generated, not after startup.
        let observation = session.$commands.sink { commands in
            guard !cancelledDuringRegistration, commands.contains(where: { $0.id == "retained" }) else { return }
            cancelledDuringRegistration = true
            session.cancelPendingRequests()
        }
        defer { observation.cancel() }
        try session.start(source: """
        ember.on('load', async () => {
          await ember.call('ui.commands', {commands:[{id:'retained',title:'Retained command'}]});
          await ember.ui.render({title:'Registration survived'});
        });
        """, isAuthorized: { true }) { _, _ in NSNull() }
        try await eventually { session.view.title == "Registration survived" }
        XCTAssertTrue(cancelledDuringRegistration)
        XCTAssertEqual(session.commands.map(\.id), ["retained"])
        XCTAssertEqual(PluginRuntimeCommandRegistry.shared.commands.count, 1)
        XCTAssertTrue(session.isRunning)
    }

    func testPendingStorageAndWindowOperationsSurviveDocumentCancellation() async throws {
        let session = PluginScriptSession()
        var continuations: [String: CheckedContinuation<Any, Never>] = [:]
        defer { continuations.values.forEach { $0.resume(returning: NSNull()) }; session.stop() }
        let methods = ["storage.get", "storage.set", "app.getContext", "ui.open", "ui.close", "workspace.navigate"]
        try session.start(source: """
        ember.on('load', async () => {
          const values = await Promise.all(['storage.get','storage.set','app.getContext','ui.open','ui.close','workspace.navigate'].map(method=>ember.call(method)));
          await ember.ui.render({title:values.join(',')});
        });
        """, isAuthorized: { true }) { method, _ in
            await withCheckedContinuation { continuations[method] = $0 }
        }
        try await eventually { continuations.count == methods.count }
        session.cancelPendingRequests()
        for method in methods { continuations.removeValue(forKey: method)?.resume(returning: method) }
        try await eventually { session.view.title == methods.joined(separator: ",") }
        XCTAssertTrue(session.isRunning)
        XCTAssertNil(session.errorMessage)
    }

    func testPanelVisibilityIsAnExplicitHostAPIAndAPIVersionIsStable() async throws {
        let session = PluginScriptSession()
        defer { session.stop() }
        var calls: [String] = []
        try session.start(source: """
        ember.on('load', async () => {
          await ember.ui.open();
          await ember.ui.close();
          await ember.ui.render({title:String(ember.apiVersion)});
        });
        """, isAuthorized: { true }) { method, params in
            XCTAssertTrue(params.isEmpty)
            calls.append(method)
            return NSNull()
        }
        try await eventually { session.view.title == "1" }
        XCTAssertEqual(calls, ["ui.open", "ui.close"])
    }

    func testCooperativeDeactivationRemovesCommandsAndCannotHangApp() async throws {
        let session = PluginScriptSession()
        defer { session.stop() }
        try session.start(source: """
        ember.commands.register({id:'command',title:'Command',run:()=>{}});
        ember.dispose(()=>{while(true){}});
        """, isAuthorized: { true }) { _, _ in NSNull() }
        try await eventually { session.commands.count == 1 }
        session.deactivate()
        XCTAssertTrue(PluginRuntimeCommandRegistry.shared.commands.isEmpty)
        try await eventually(seconds: 5) { !session.isRunning }
        // Timing out proves the cleanup callback ran, while host teardown stays
        // authoritative even when a plugin refuses to finish cleanup.
        XCTAssertEqual(session.errorMessage, PluginScriptError.timeout.localizedDescription)
        try session.start(source: "ember.dispose(()=>{}); ember.ui.render({title:'Ready'});", isAuthorized: { true }) { _, _ in NSNull() }
        try await eventually { session.view.title == "Ready" }
        session.deactivate()
        try await eventually { !session.isRunning }
        XCTAssertNil(session.errorMessage)
    }

    func testTwentyFourCommandsCoalesceAndAreRemovedOnStop() async throws {
        let session = PluginScriptSession()
        defer { session.stop() }
        try session.start(source: """
        ember.on('load', () => {
          for(let i=0;i<24;i++) ember.commands.register({id:'cmd'+i,title:'Command '+i,run:()=>{}});
        });
        """, isAuthorized: { true }) { _, _ in NSNull() }
        try await eventually { session.commands.count == 24 }
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(PluginRuntimeCommandRegistry.shared.commands.count, 24)
        session.stop()
        XCTAssertTrue(PluginRuntimeCommandRegistry.shared.commands.isEmpty)
    }

    func testAsyncFailureIsReportedWithoutLeavingWorkerAlive() async throws {
        let session = PluginScriptSession()
        defer { session.stop() }
        try session.start(source: "ember.on('load',async()=>{throw new Error('example failure')});", isAuthorized: { true }) { _, _ in NSNull() }
        try await eventually { !session.isRunning }
        XCTAssertTrue(session.errorMessage?.contains("example failure") == true)
    }

    func testUIAndStorageAreBoundedAndNamespaced() throws {
        XCTAssertThrowsError(try PluginScriptView.decode(["html": "<script>alert(1)</script>"]))
        XCTAssertThrowsError(try PluginScriptView.decode(["fields": [["id":"same","label":"A"],["id":"same","label":"B"]]]))
        let inert = try PluginScriptView.decode(["text": "<img src='https://example.org'>", "actions": [["id":"click","label":"Click"]]])
        XCTAssertEqual(inert.text, "<img src='https://example.org'>")
        let suite = "PluginScriptSessionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = PluginScriptStorage(defaults: defaults)
        try storage.set(["answer":42], identifier: "org.example.one")
        XCTAssertEqual((try storage.get(identifier: "org.example.one") as? [String:Int])?["answer"],42)
        XCTAssertTrue(try storage.get(identifier: "org.example.two") is NSNull)
        XCTAssertThrowsError(try storage.set(String(repeating:"x",count:70_000), identifier: "org.example.one"))
        XCTAssertEqual((try storage.get(identifier: "org.example.one") as? [String:Int])?["answer"],42)
    }

    private func eventually(seconds: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(condition(), "Condition did not become true within \(seconds) seconds")
    }
}
