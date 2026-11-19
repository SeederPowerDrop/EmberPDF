// SPDX-License-Identifier: MPL-2.0
import Combine
import Foundation

/// Owns extension lifetimes for one window, independently of document views.
/// Only this broker translates extension requests into approved host operations.
@MainActor
final class PluginExtensionHost: ObservableObject {
    struct Extension: Identifiable {
        let id: String
        let digest: String
        let name: String
        let session: PluginScriptSession
    }
    let id = UUID()
    @Published private(set) var extensions: [Extension] = []
    @Published var selectedIdentifier: String?
    var documentCommandsAllowed = true
    private let collection: MultiDocumentWorkspaceState
    private let manager: PluginManager
    private let defaults: UserDefaults
    private let helperURL: URL?
    private var subscriptions: Set<AnyCancellable> = []
    private var sessionSubscriptions: [String: AnyCancellable] = [:]
    private var updateTask: Task<Void, Never>?
    private var paused: Set<String> = []
    private var active = false
    private var previous: Context?

    private struct Context: Equatable {
        let workspaceID: UUID
        let tabID: UUID?
        let document: ObjectIdentifier?
        let revision: UUID?
        let page: Int?
        let selection: ObjectIdentifier?
        let documents: [UUID]
    }

    init(collection: MultiDocumentWorkspaceState, manager: PluginManager = .shared,
         defaults: UserDefaults = .standard, helperURL: URL? = nil) {
        self.collection = collection; self.manager = manager
        self.defaults = defaults; self.helperURL = helperURL
    }

    var selectedExtension: Extension? { extensions.first { $0.id == selectedIdentifier } }

    func start() {
        guard !active else { return }
        active = true
        previous = context()
        collection.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &subscriptions)
        manager.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &subscriptions)
        synchronize()
    }

    func stop() {
        active = false
        updateTask?.cancel(); updateTask = nil
        subscriptions.removeAll(); sessionSubscriptions.removeAll()
        extensions.forEach { $0.session.stop() }
        extensions = []; selectedIdentifier = nil; previous = nil; paused = []
    }

    func pause(_ identifier: String) {
        paused.insert(identifier)
        extensions.first { $0.id == identifier }?.session.stop()
        objectWillChange.send()
    }

    func restart(_ identifier: String) {
        paused.remove(identifier)
        remove(identifier)
        synchronize()
    }

    func show(_ identifier: String) {
        guard let item = extensions.first(where: { $0.id == identifier }),
              manager.isRuntimeAuthorized(pluginIdentifier: item.id, manifestDigest: item.digest) else { return }
        selectedIdentifier = identifier
    }

    private func scheduleUpdate() {
        guard active, updateTask == nil else { return }
        updateTask = Task { @MainActor [weak self] in
            // ObservableObject sends before mutation. Coalesce bursts without
            // continually pushing the deadline back during scrolling/imports.
            do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
            guard let self, self.active else { return }
            self.updateTask = nil
            self.synchronize()
            self.publishChanges()
        }
    }

    private func synchronize() {
        guard active else { return }
        let eligible = manager.enabledPlugins.filter {
            $0.manifest.runtime != nil && manager.isRuntimeAuthorized(pluginIdentifier: $0.id, manifestDigest: $0.manifestDigest)
        }
        for item in extensions where !eligible.contains(where: { $0.id == item.id && $0.manifestDigest == item.digest }) {
            remove(item.id)
        }
        for plugin in eligible where !extensions.contains(where: { $0.id == plugin.id }) && !paused.contains(plugin.id) {
            launch(plugin)
        }
    }

    private func launch(_ plugin: InstalledPlugin) {
        guard let runtime = plugin.manifest.runtime else { return }
        let session = PluginScriptSession()
        let item = Extension(id: plugin.id, digest: plugin.manifestDigest,
                             name: plugin.manifest.displayName, session: session)
        extensions.append(item)
        sessionSubscriptions[item.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        do {
            let inspected = try PluginPackageValidator().inspectInstalledPackage(at: plugin.installURL)
            guard inspected.package.manifestDigest == item.digest,
                  let data = inspected.package.filePayloads[runtime.entry],
                  PluginPackageValidator.sha256Hex(data) == runtime.sha256,
                  let source = String(data: data, encoding: .utf8) else { throw PluginSystemError.packageChanged }
            let capabilities = Set(runtime.capabilities)
            let identifier = item.id, digest = item.digest
            try session.start(source: source, helperURL: helperURL, commandScope: id,
                              commandOwnerName: item.name, isAuthorized: { [weak self] in
                self?.authorized(identifier: identifier, digest: digest) == true
            }) { [weak self] method, params in
                guard let self else { throw PluginScriptError.revoked }
                return try await self.handle(method, params: params, identifier: identifier, digest: digest, capabilities: capabilities)
            }
            session.event("app.ready", payload: publicContext())
        } catch { session.stop(error: error) }
    }

    private func remove(_ identifier: String) {
        extensions.first { $0.id == identifier }?.session.stop()
        sessionSubscriptions[identifier] = nil
        extensions.removeAll { $0.id == identifier }
        if selectedIdentifier == identifier { selectedIdentifier = nil }
    }

    private func authorized(identifier: String, digest: String) -> Bool {
        active && !paused.contains(identifier)
            && manager.isRuntimeAuthorized(pluginIdentifier: identifier, manifestDigest: digest)
    }

    private func context() -> Context {
        let document = collection.activeWorkspace
        return Context(workspaceID: collection.activeWorkspaceID, tabID: collection.activeTabID,
                       document: document?.document.map(ObjectIdentifier.init), revision: document?.revision,
                       page: document?.currentPageIndex, selection: document?.currentSelection.map(ObjectIdentifier.init),
                       documents: collection.allTabs.filter { $0.workspace.hasOpenDocument }.map(\.id))
    }

    private func publicContext() -> [String: Any] {
        ["apiVersion": 1, "windowID": id.uuidString, "workspaceID": collection.activeWorkspaceID.uuidString,
         "tabID": collection.activeTabID.map { $0.uuidString as Any } ?? NSNull(),
         "hasDocument": collection.activeWorkspace?.hasOpenDocument == true]
    }

    private func publishChanges() {
        let next = context()
        guard let old = previous else { previous = next; return }
        previous = next
        let documentChanged = old.tabID != next.tabID || old.document != next.document || old.revision != next.revision
        var events: [String] = []
        if old.workspaceID != next.workspaceID { events.append("workspace.changed") }
        if old.documents != next.documents { events.append("documents.changed") }
        if documentChanged { events.append("document.changed") }
        if old.page != next.page { events.append("page.changed") }
        if old.selection != next.selection { events.append("selection.changed") }
        guard !events.isEmpty else { return }
        let payload = publicContext()
        for item in extensions where item.session.isRunning {
            // Page/selection/list changes can also invalidate an in-flight
            // read or search, without revoking this extension's permission.
            item.session.cancelPendingRequests()
            for event in events { item.session.event(event, payload: payload) }
        }
    }

    private func handle(_ method: String, params: [String: Any], identifier: String, digest: String,
                        capabilities: Set<PluginCapability>) async throws -> Any {
        guard authorized(identifier: identifier, digest: digest), !Task.isCancelled else { throw PluginScriptError.revoked }
        switch method {
        case "app.getContext":
            guard params.isEmpty else { throw PluginScriptError.invalidMessage }
            return publicContext()
        case "ui.open", "ui.close":
            guard params.isEmpty else { throw PluginScriptError.invalidMessage }
            if method == "ui.open" { selectedIdentifier = identifier }
            else if selectedIdentifier == identifier { selectedIdentifier = nil }
            return NSNull()
        case "storage.get":
            guard capabilities.contains(.pluginStorage), params.isEmpty else { throw PluginScriptError.revoked }
            return ["value": try PluginScriptStorage(defaults: defaults).get(identifier: identifier)]
        case "storage.set":
            guard capabilities.contains(.pluginStorage), Set(params.keys) == ["value"], let value = params["value"] else { throw PluginScriptError.revoked }
            try PluginScriptStorage(defaults: defaults).set(value, identifier: identifier)
            return ["saved": true]
        case "storage.compareAndSet":
            guard capabilities.contains(.pluginStorage), Set(params.keys) == ["expected", "value"],
                  let expected = params["expected"], let value = params["value"] else { throw PluginScriptError.revoked }
            return ["saved": try PluginScriptStorage(defaults: defaults).compareAndSet(expected: expected, value: value, identifier: identifier)]
        case "workspace.search":
            guard capabilities.contains(.openDocumentsRead), Set(params.keys) == ["query"],
                  let query = params["query"] as? String, !query.isEmpty, query.utf8.count <= 1_024 else { throw PluginScriptError.invalidMessage }
            var configuration = PDFGallerySearchConfiguration.standard
            configuration.maximumTotalResults = 24; configuration.maximumResultsPerDocument = 3
            configuration.debounceNanoseconds = 0
            let search = PDFGallerySearchController(configuration: configuration)
            let documents = collection.workspaces.flatMap { owner in
                owner.tabs.filter { $0.workspace.hasOpenDocument }.map {
                    PDFGalleryDocument(workspaceID: owner.id, workspaceTitle: owner.title, session: $0)
                }
            }
            let before = context()
            await search.search(query: query, documents: Array(documents.prefix(8)))
            defer { search.cancel() }
            guard authorized(identifier: identifier, digest: digest) else { throw PluginScriptError.revoked }
            guard !Task.isCancelled, context() == before else { throw PluginScriptError.contextChanged }
            let matches: [[String: Any]] = search.documentResults.filter(\.isMatch).map { result in
                ["workspaceID": result.document.workspaceID.uuidString, "tabID": result.id.uuidString,
                 "name": String(result.document.session.displayName.prefix(256)),
                 "matches": result.matches.map { ["pageNumber": $0.pageIndex + 1, "snippet": String($0.snippet.prefix(500))] as [String: Any] }]
            }
            return ["documents": matches, "partial": documents.count > 8 || search.progress.isTruncated || search.progress.skippedDocumentCount > 0,
                    "scannedDocuments": search.progress.scannedDocuments]
        default:
            if method == "commands.execute", !documentCommandsAllowed { throw PluginScriptHostAPI.Failure.unavailable }
            guard let workspace = collection.activeWorkspace else { throw PluginScriptHostAPI.Failure.unavailable }
            let document = workspace.document.map(ObjectIdentifier.init)
            let revision = workspace.revision
            let allowsContextChange = method == "workspace.navigate"
            let allowsRevisionChange = method == "commands.execute"
            return try await PluginScriptHostAPI.handle(method: method, params: params, workspace: workspace,
                collection: collection, isAuthorized: { [weak self] in
                    guard let self, self.authorized(identifier: identifier, digest: digest) else { return false }
                    if allowsContextChange { return true }
                    return self.collection.activeWorkspace === workspace
                        && workspace.document.map(ObjectIdentifier.init) == document
                        && (allowsRevisionChange || workspace.revision == revision)
                }, capabilities: capabilities)
        }
    }
}
