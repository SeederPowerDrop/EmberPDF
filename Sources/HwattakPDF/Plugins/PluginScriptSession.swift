// SPDX-License-Identifier: MPL-2.0
import AppKit
import Darwin
import Foundation

/// An intentionally small JSON view vocabulary. Plug-ins compute freely in the
/// worker; SwiftUI owns controls and never interprets their text as HTML/URLs.
struct PluginScriptView: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id: String { title + (detail ?? "") }
        let title: String
        let detail: String?
    }
    struct Field: Codable, Equatable, Identifiable { let id: String; let label: String; let value: String? }
    struct Action: Codable, Equatable, Identifiable { let id: String; let label: String }
    var title: String?
    var text: String?
    var items: [Item]?
    var fields: [Field]?
    var actions: [Action]?
    static let empty = Self()

    static func decode(_ object: [String: Any]) throws -> Self {
        guard Set(object.keys).isSubset(of: ["title", "text", "items", "fields", "actions"]),
              JSONSerialization.isValidJSONObject(object) else { throw PluginScriptError.invalidMessage }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= 64 * 1_024 else { throw PluginScriptError.limit }
        let view = try JSONDecoder().decode(Self.self, from: data)
        guard (view.items?.count ?? 0) <= 100, (view.fields?.count ?? 0) <= 12,
              (view.actions?.count ?? 0) <= 24,
              Set((view.fields ?? []).map(\.id)).count == (view.fields?.count ?? 0),
              Set((view.actions ?? []).map(\.id)).count == (view.actions?.count ?? 0),
              (view.fields ?? []).allSatisfy({ validID($0.id) && $0.label.count <= 160 && ($0.value?.utf8.count ?? 0) <= 4_096 }),
              (view.actions ?? []).allSatisfy({ validID($0.id) && $0.label.count <= 160 }) else { throw PluginScriptError.limit }
        return view
    }
    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 80 && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
    }
}

struct PluginScriptCommand: Identifiable, Equatable {
    let id: String
    let title: String
    var ownerName: String? = nil
}
enum PluginScriptError: LocalizedError {
    case invalidMessage, limit, unavailable, revoked, contextChanged, timeout
    var errorDescription: String? {
        switch self {
        case .invalidMessage: L10n.string("plugins.script.invalid", defaultValue: "플러그인의 요청 형식이 올바르지 않습니다.")
        case .limit: L10n.string("plugins.script.limit", defaultValue: "플러그인이 허용된 크기나 실행 횟수를 초과했습니다.")
        case .unavailable: L10n.string("plugins.script.unavailable", defaultValue: "플러그인 실행 도우미를 찾지 못했습니다.")
        case .revoked: L10n.string("plugins.script.revoked", defaultValue: "권한 또는 문서가 변경되어 플러그인을 중지했습니다.")
        case .contextChanged: L10n.string("plugins.script.contextChanged", defaultValue: "문서 상태가 변경되어 이전 요청을 취소했습니다.")
        case .timeout: L10n.string("plugins.script.timeout", defaultValue: "플러그인이 응답하지 않아 실행을 중지했습니다. PDF 작업은 계속할 수 있습니다.")
        }
    }
}

/// Scoped JSON storage, never a path supplied by JavaScript.
struct PluginScriptStorage {
    let defaults: UserDefaults
    func get(identifier: String) throws -> Any {
        guard let data = defaults.data(forKey: key(identifier)) else { return NSNull() }
        guard data.count <= 64 * 1_024 else { throw PluginScriptError.limit }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    func set(_ value: Any, identifier: String) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        guard data.count <= 64 * 1_024 else { throw PluginScriptError.limit }
        defaults.set(data, forKey: key(identifier))
    }
    private func key(_ identifier: String) -> String { "plugins.scriptData.v1." + identifier }
}

@MainActor
final class PluginScriptSession: ObservableObject {
    /// Helpers are isolated from one another, but their aggregate count is bounded.
    /// Starting an extension never silently disposes another extension's work.
    static let maximumConcurrentSessions = 8
    private final class WeakSession {
        weak var value: PluginScriptSession?
        init(_ value: PluginScriptSession) { self.value = value }
    }
    private static var liveSessions: [UUID: WeakSession] = [:]
    let id = UUID()
    private(set) var commandScope: UUID?
    private(set) var commandOwnerName: String?
    @Published private(set) var view = PluginScriptView.empty
    @Published private(set) var commands: [PluginScriptCommand] = []
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    private var process: Process?
    private var input: FileHandle?
    /// Blocking POSIX pipe reads must not occupy Swift's cooperative executor:
    /// eight idle helpers would otherwise starve the very writes they await.
    private final class PipeReader: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    private final class ReadResult: @unchecked Sendable {
        let completion = DispatchSemaphore(value: 0)
        // Written before signal and read after wait; the semaphore establishes
        // the ordering while bounding each reader to one outstanding chunk.
        var keepReading = false
    }
    private var reader: PipeReader?
    private var watchdog: Task<Void, Never>?
    private var requests: [String: Task<Void, Never>] = [:]
    private var documentRequests: Set<String> = []
    private var buffer = Data()
    private struct OutgoingMessage {
        let data: Data
        let responseID: String?
        let requestContext: UUID?
        let isDeactivation: Bool
    }
    private var queue: [OutgoingMessage] = []
    private var awaitingIdle = false
    private var awaitingDeactivation = false
    private var isDeactivating = false
    private var generation = UUID()
    private var requestContext = UUID()
    private var rateStart = Date()
    private var messageCount = 0
    private var requestHandler: ((String, [String: Any]) async throws -> Any)?
    private var authorize: (() -> Bool)?
    private var loaded = false

    deinit {
        // A host normally calls stop() explicitly. Also close the owned helper
        // if a window/controller is released before its usual lifecycle hook.
        watchdog?.cancel(); reader?.cancel()
        requests.values.forEach { $0.cancel() }
        try? input?.close()
        process?.terminationHandler = nil
        if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    static var helperURL: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/EmberPluginWorker")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        #if DEBUG
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let debug = root.appendingPathComponent(".build/debug/EmberPluginWorker")
        if FileManager.default.isExecutableFile(atPath: debug.path) { return debug }
        #endif
        return nil
    }

    func start(source: String, helperURL: URL? = nil,
               commandScope: UUID? = nil, commandOwnerName: String? = nil,
               isAuthorized: @escaping () -> Bool,
               handler: @escaping (String, [String: Any]) async throws -> Any) throws {
        stop()
        guard isAuthorized() else { throw PluginScriptError.revoked }
        guard source.utf8.count <= 128 * 1_024, let executable = helperURL ?? Self.helperURL else { throw PluginScriptError.unavailable }
        Self.liveSessions = Self.liveSessions.filter { $0.value.value?.isRunning == true }
        guard Self.liveSessions.count < Self.maximumConcurrentSessions else { throw PluginScriptError.limit }
        let child = Process()
        let incoming = Pipe(), outgoing = Pipe()
        child.executableURL = executable
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        child.standardInput = incoming
        child.standardOutput = outgoing
        child.standardError = FileHandle.nullDevice
        self.authorize = isAuthorized
        self.requestHandler = handler
        self.commandScope = commandScope
        self.commandOwnerName = commandOwnerName.map { String($0.prefix(160)) }
        generation = UUID(); let id = generation
        rateStart = Date(); messageCount = 0; errorMessage = nil
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == id, self.isRunning else { return }
                self.stop(error: PluginScriptError.unavailable)
            }
        }
        try child.run()
        process = child; input = incoming.fileHandleForWriting; isRunning = true
        Self.liveSessions[self.id] = WeakSession(self)
        let output = outgoing.fileHandleForReading
        let pipeReader = PipeReader()
        reader = pipeReader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { try? output.close() }
            var bytes = [UInt8](repeating: 0, count: 4_096)
            while !pipeReader.isCancelled {
                // FileHandle.read(upToCount:) can wait to fill the requested
                // buffer on a pipe. POSIX read returns the available message
                // promptly, which is necessary for the idle/response handshake.
                let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                let chunk = Data(bytes.prefix(count))
                let result = ReadResult()
                Task { @MainActor [weak self] in
                    result.keepReading = self?.consume(chunk, generation: id) ?? false
                    result.completion.signal()
                }
                result.completion.wait()
                if !result.keepReading { break }
            }
        }
        send(["type": "load", "source": source])
    }

    func event(_ name: String, payload: [String: Any] = [:]) {
        guard isRunning, !isDeactivating else { return }
        send(["type": "event", "name": name, "payload": payload])
    }
    func command(_ id: String) {
        guard !isDeactivating, commands.contains(where: { $0.id == id }) else { return }
        send(["type": "command", "id": id])
    }

    /// A document switch invalidates document-scoped host requests, not the
    /// extension's registration, storage, window, or navigation operations.
    /// Discard queued old-context results too: a non-cooperative async handler
    /// must never return previously authorized document data after the switch.
    func cancelPendingRequests() {
        requestContext = UUID()
        var cancelled = documentRequests
        for id in documentRequests { requests.removeValue(forKey: id)?.cancel() }
        documentRequests = []
        for message in queue where message.requestContext != nil {
            if let id = message.responseID { cancelled.insert(id) }
        }
        queue.removeAll { $0.requestContext != nil }
        for id in cancelled.sorted() {
            send(["type": "response", "id": id, "error": "Document context changed", "errorCode": "CONTEXT_CHANGED"])
        }
    }

    /// Best-effort, bounded cooperative disposal. Revocation and failures use
    /// stop() directly; cleanup callbacks can never delay authoritative teardown.
    func deactivate() {
        guard isRunning, !isDeactivating else { return }
        isDeactivating = true
        requestContext = UUID()
        requests.values.forEach { $0.cancel() }; requests = [:]; documentRequests = []
        queue = []
        PluginRuntimeCommandRegistry.shared.remove(owner: self)
        send(["type": "deactivate"])
    }

    func stop(error: Error? = nil) {
        generation = UUID(); requestContext = UUID(); isRunning = false; loaded = false
        Self.liveSessions[id] = nil
        watchdog?.cancel(); watchdog = nil
        reader?.cancel(); reader = nil
        requests.values.forEach { $0.cancel() }; requests = [:]; documentRequests = []
        input.map { try? $0.close() }; input = nil
        if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        process?.terminationHandler = nil; process = nil
        queue = []; buffer = Data(); awaitingIdle = false; awaitingDeactivation = false; isDeactivating = false
        requestHandler = nil; authorize = nil
        commands = []; view = .empty
        PluginRuntimeCommandRegistry.shared.remove(owner: self)
        if let error { errorMessage = error.localizedDescription }
    }

    private func send(_ object: [String: Any], requestContext: UUID? = nil, priority: Bool = false) {
        guard isRunning else { return }
        guard authorize?() == true else { stop(error: PluginScriptError.revoked); return }
        do {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard data.count <= 256 * 1_024, queue.count < 32 else { throw PluginScriptError.limit }
            data.append(10)
            let message = OutgoingMessage(data: data,
                responseID: object["type"] as? String == "response" ? object["id"] as? String : nil,
                requestContext: requestContext, isDeactivation: object["type"] as? String == "deactivate")
            if priority { queue.insert(message, at: 0) }
            else { queue.append(message) }
            pump()
        } catch { stop(error: error) }
    }
    private func pump() {
        guard isRunning, !awaitingIdle, !queue.isEmpty, let input else { return }
        awaitingIdle = true
        let message = queue.removeFirst(), id = generation
        awaitingDeactivation = message.isDeactivation
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.generation == id, self.awaitingIdle else { return }
            self.stop(error: PluginScriptError.timeout)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do { try input.write(contentsOf: message.data) }
            catch { Task { @MainActor [weak self] in self?.failWrite(generation: id) } }
        }
    }
    private func failWrite(generation id: UUID) {
        if id == generation && isRunning { stop(error: PluginScriptError.unavailable) }
    }
    private func consume(_ data: Data, generation id: UUID) -> Bool {
        guard id == generation, isRunning else { return false }
        guard authorize?() == true else { stop(error: PluginScriptError.revoked); return false }
        buffer.append(data)
        guard buffer.count <= 256 * 1_024 else { stop(error: PluginScriptError.limit); return false }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            do {
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw PluginScriptError.invalidMessage }
                try receive(object)
            } catch { stop(error: error); return false }
            if !isRunning { return false }
        }
        return true
    }
    private func receive(_ message: [String: Any]) throws {
        switch message["type"] as? String {
        case "idle":
            guard awaitingIdle else { throw PluginScriptError.invalidMessage }
            awaitingIdle = false; watchdog?.cancel(); watchdog = nil
            if awaitingDeactivation { stop(); return }
            if !loaded {
                loaded = true
                // The source's synchronous load handler runs before events
                // queued during helper startup. This does not await promises
                // returned by an async load handler.
                if !isDeactivating {
                    send(["type": "event", "name": "load", "payload": [:]], priority: true)
                }
            }
            pump()
        case "error":
            let detail = String((message["message"] as? String ?? "Plugin error").prefix(512))
            throw PluginSystemError.actionFailed(detail)
        case "request":
            // Cooperative cleanup has no host authority. Its JavaScript-only
            // callbacks may run, but cannot perform late document operations.
            if isDeactivating { return }
            if Date().timeIntervalSince(rateStart) > 60 { rateStart = Date(); messageCount = 0 }
            messageCount += 1
            guard messageCount <= 240, requests.count < 16,
                  let id = message["id"] as? String, PluginScriptView.validID(id), requests[id] == nil,
                  let method = message["method"] as? String, method.utf8.count <= 80,
                  let params = message["params"] as? [String: Any] else { throw PluginScriptError.limit }
            let generation = self.generation
            let context: UUID? = Self.isDocumentScoped(method) ? self.requestContext : nil
            if context != nil { documentRequests.insert(id) }
            requests[id] = Task { @MainActor [weak self] in
                guard let self else { return }
                guard !Task.isCancelled, self.generation == generation,
                      context == nil || self.requestContext == context else { return }
                var response: [String: Any] = ["type": "response", "id": id]
                do {
                    guard self.authorize?() == true else { throw PluginScriptError.revoked }
                    let result = try await self.handle(method, params: params)
                    guard !Task.isCancelled, self.generation == generation,
                          context == nil || self.requestContext == context else { return }
                    response["result"] = result
                } catch {
                    response["error"] = String(error.localizedDescription.prefix(512))
                    if let scriptError = error as? PluginScriptError, case .contextChanged = scriptError {
                        response["errorCode"] = "CONTEXT_CHANGED"
                    }
                }
                guard !Task.isCancelled, self.generation == generation,
                      context == nil || self.requestContext == context else { return }
                self.requests[id] = nil
                self.documentRequests.remove(id)
                self.send(response, requestContext: context)
            }
        default: throw PluginScriptError.invalidMessage
        }
    }
    private static func isDocumentScoped(_ method: String) -> Bool {
        method.hasPrefix("document.") || method.hasPrefix("notes.") ||
        method == "workspace.search" || method == "commands.execute" || method == "ui.render"
    }
    private func handle(_ method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "runtime.error":
            let detail = String((params["message"] as? String ?? "Plugin error").prefix(512))
            stop(error: PluginSystemError.actionFailed(detail))
            return NSNull()
        case "ui.render":
            guard let value = params["view"] as? [String: Any], params.count == 1 else { throw PluginScriptError.invalidMessage }
            view = try PluginScriptView.decode(value)
            return NSNull()
        case "ui.commands":
            guard let values = params["commands"] as? [[String: Any]], values.count <= 24,
                  params.count == 1 else { throw PluginScriptError.limit }
            let parsed: [PluginScriptCommand] = try values.map { value in
                guard let id = value["id"] as? String, PluginScriptView.validID(id),
                      let title = value["title"] as? String, !title.isEmpty, title.count <= 160,
                      Set(value.keys) == ["id", "title"] else { throw PluginScriptError.invalidMessage }
                return .init(id: id, title: title)
            }
            guard Set(parsed.map(\.id)).count == parsed.count else { throw PluginScriptError.invalidMessage }
            commands = parsed
            PluginRuntimeCommandRegistry.shared.publish(parsed, owner: self)
            return NSNull()
        default:
            guard let handler = requestHandler else { throw PluginScriptError.revoked }
            return try await handler(method, params)
        }
    }
}

/// Runtime commands participate in the same palette while their owner is alive.
/// Disposing/revoking the worker removes them as one operation.
@MainActor
final class PluginRuntimeCommandRegistry: ObservableObject {
    static let shared = PluginRuntimeCommandRegistry()
    @Published private(set) var revision = UUID()
    private final class Entry {
        weak var owner: PluginScriptSession?
        let commands: [PluginScriptCommand]
        init(owner: PluginScriptSession, commands: [PluginScriptCommand]) {
            self.owner = owner; self.commands = commands
        }
    }
    private var entries: [UUID: Entry] = [:]

    /// Legacy consumers are deliberately limited to unscoped sessions. A nil
    /// scope is not a wildcard for commands belonging to other app windows.
    var commands: [PluginScriptCommand] { commands(in: nil) }
    func commands(in scope: UUID?) -> [PluginScriptCommand] {
        entries.values.compactMap { entry -> [PluginScriptCommand]? in
            guard let owner = entry.owner, owner.isRunning, owner.commandScope == scope else { return nil }
            return entry.commands.map { command in
                .init(id: Self.namespaced(command.id, owner: owner), title: command.title, ownerName: owner.commandOwnerName)
            }
        }.flatMap { $0 }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }
    func publish(_ commands: [PluginScriptCommand], owner: PluginScriptSession) {
        entries = entries.filter { $0.value.owner?.isRunning == true }
        entries[owner.id] = Entry(owner: owner, commands: commands)
        revision = UUID()
    }
    func remove(owner: PluginScriptSession) {
        guard entries.removeValue(forKey: owner.id) != nil else { return }
        revision = UUID()
    }
    func run(_ id: String, scope: UUID?) {
        for entry in entries.values {
            guard let owner = entry.owner, owner.isRunning, owner.commandScope == scope,
                  let command = entry.commands.first(where: { Self.namespaced($0.id, owner: owner) == id }) else { continue }
            owner.command(command.id)
            return
        }
    }
    func run(_ id: String) { run(id, scope: nil) }
    private static func namespaced(_ id: String, owner: PluginScriptSession) -> String {
        owner.id.uuidString + "." + id
    }
}
