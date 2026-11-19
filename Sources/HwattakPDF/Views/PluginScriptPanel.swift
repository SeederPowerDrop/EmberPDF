// SPDX-License-Identifier: MPL-2.0
import SwiftUI

@MainActor
struct PluginScriptPanel: View {
    let request: PluginPanelRequest
    @ObservedObject var workspace: PDFWorkspaceState
    let collection: MultiDocumentWorkspaceState
    let isAuthorized: () -> Bool
    @EnvironmentObject private var manager: PluginManager
    @Environment(\.pluginCommandScope) private var commandScope
    @StateObject private var session = PluginScriptSession()
    @State private var values: [String: String] = [:]
    @State private var inputTask: Task<Void, Never>?
    @EmberTheme private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.string(session.isRunning ? "plugins.script.running" : "plugins.script.stopped",
                    defaultValue: session.isRunning ? "플러그인 실행 중" : "플러그인 중지됨"), systemImage: "puzzlepiece.extension")
                    .font(.caption).foregroundStyle(theme.secondaryText)
                Spacer()
                Button(L10n.string(session.isRunning ? "plugins.script.stop" : "plugins.script.restart",
                    defaultValue: session.isRunning ? "중지" : "다시 실행")) {
                    if session.isRunning { session.stop() } else { start() }
                }.controlSize(.small)
            }.padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = session.errorMessage { Text(error).font(.callout).foregroundStyle(theme.accent) }
                    if let title = session.view.title { Text(title).font(.title3.bold()) }
                    if let text = session.view.text { Text(text).textSelection(.enabled) }
                    ForEach(session.view.fields ?? []) { field in
                        TextField(field.label, text: Binding(get: { values[field.id] ?? field.value ?? "" }, set: { value in
                            values[field.id] = String(value.prefix(1_000))
                            inputTask?.cancel()
                            inputTask = Task { @MainActor in
                                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                                session.event("view.input", payload: ["id": field.id, "value": values[field.id] ?? ""])
                            }
                        })).textFieldStyle(.roundedBorder)
                    }
                    ForEach(Array((session.view.items ?? []).enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(.headline)
                            if let detail = item.detail { Text(detail).font(.callout).foregroundStyle(theme.secondaryText).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(theme.card, in: RoundedRectangle(cornerRadius: 9))
                    }
                    ForEach(session.view.actions ?? []) { action in
                        Button(action.label) {
                            guard isAuthorized() else { return }
                            session.event("view.action", payload: ["id": action.id, "values": values])
                        }.disabled(!session.isRunning)
                    }
                    if !session.commands.isEmpty {
                        Divider()
                        ForEach(session.commands) { command in
                            Button { session.command(command.id) } label: {
                                Label(command.title, systemImage: "command")
                            }.disabled(!session.isRunning)
                        }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { start() }
        .onDisappear { inputTask?.cancel(); session.stop() }
        .onChange(of: session.view.fields) { _, fields in
            values = Dictionary(uniqueKeysWithValues: (fields ?? []).map { ($0.id, $0.value ?? "") })
        }
        .onChange(of: workspace.currentPageIndex) { _, _ in session.event("page.changed") }
        .onChange(of: workspace.currentSelection.map(ObjectIdentifier.init)) { _, _ in session.event("selection.changed") }
        .accessibilityIdentifier("plugin-script-panel")
    }

    private func start() {
        guard isAuthorized(), let plugin = manager.installedPlugins.first(where: {
            $0.id == request.pluginIdentifier && $0.manifestDigest == request.manifestDigest
        }), let action = plugin.manifest.actions.first(where: { $0.id == request.actionID && $0.output == .scriptPanel }) else { return }
        do {
            let inspected = try PluginPackageValidator().inspectInstalledPackage(at: plugin.installURL)
            guard inspected.package.manifestDigest == request.manifestDigest,
                  let data = inspected.package.filePayloads["main.js"],
                  PluginPackageValidator.sha256Hex(data) == action.scriptSHA256,
                  let source = String(data: data, encoding: .utf8) else { throw PluginSystemError.packageChanged }
            let capabilities = Set(action.scriptCapabilities ?? [])
            try session.start(source: source, commandScope: commandScope, commandOwnerName: plugin.manifest.displayName,
                              isAuthorized: isAuthorized) { method, params in
                guard isAuthorized() else { throw PluginScriptError.revoked }
                switch method {
                case "storage.get":
                    guard capabilities.contains(.pluginStorage), params.isEmpty else { throw PluginScriptError.revoked }
                    return ["value": try PluginScriptStorage(defaults: .standard).get(identifier: plugin.id)]
                case "storage.set":
                    guard capabilities.contains(.pluginStorage), Set(params.keys) == ["value"], let value = params["value"] else { throw PluginScriptError.revoked }
                    try PluginScriptStorage(defaults: .standard).set(value, identifier: plugin.id)
                    return ["saved": true]
                case "storage.compareAndSet":
                    guard capabilities.contains(.pluginStorage), Set(params.keys) == ["expected", "value"],
                          let expected = params["expected"], let value = params["value"] else { throw PluginScriptError.revoked }
                    return ["saved": try PluginScriptStorage(defaults: .standard)
                        .compareAndSet(expected: expected, value: value, identifier: plugin.id)]
                case "workspace.search":
                    guard capabilities.contains(.openDocumentsRead), Set(params.keys) == ["query"],
                          let query = params["query"] as? String, !query.isEmpty, query.utf8.count <= 1_024 else { throw PluginScriptError.revoked }
                    var configuration = PDFGallerySearchConfiguration.standard
                    configuration.maximumTotalResults = 24; configuration.maximumResultsPerDocument = 3
                    configuration.debounceNanoseconds = 0
                    let search = PDFGallerySearchController(configuration: configuration)
                    let all = collection.workspaces.flatMap { owner in
                        owner.tabs.filter { $0.workspace.hasOpenDocument }.map {
                            PDFGalleryDocument(workspaceID: owner.id, workspaceTitle: owner.title, session: $0)
                        }
                    }
                    await search.search(query: query, documents: Array(all.prefix(8)))
                    guard !Task.isCancelled, isAuthorized() else { search.cancel(); throw PluginScriptError.revoked }
                    let matches: [[String: Any]] = search.documentResults.filter(\.isMatch).map { result in
                        ["workspaceID": result.document.workspaceID.uuidString, "tabID": result.id.uuidString,
                         "name": String(result.document.session.displayName.prefix(256)),
                         "matches": result.matches.map { match in
                             ["pageNumber": match.pageIndex + 1, "snippet": String(match.snippet.prefix(500))] as [String: Any]
                         }]
                    }
                    return ["documents": matches, "partial": all.count > 8 || search.progress.isTruncated || search.progress.skippedDocumentCount > 0,
                            "scannedDocuments": search.progress.scannedDocuments]
                default:
                    return try await PluginScriptHostAPI.handle(method: method, params: params,
                        workspace: workspace, collection: collection, isAuthorized: isAuthorized, capabilities: capabilities)
                }
            }
        } catch { session.stop(error: error) }
    }
}
