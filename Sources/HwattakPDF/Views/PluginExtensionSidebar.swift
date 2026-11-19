// SPDX-License-Identifier: MPL-2.0
import SwiftUI

private struct PluginCommandScopeKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var pluginCommandScope: UUID? {
        get { self[PluginCommandScopeKey.self] }
        set { self[PluginCommandScopeKey.self] = newValue }
    }
}
private struct PluginExtensionScopeKey: FocusedValueKey { typealias Value = UUID }
extension FocusedValues {
    var pluginExtensionScope: UUID? {
        get { self[PluginExtensionScopeKey.self] }
        set { self[PluginExtensionScopeKey.self] = newValue }
    }
}

struct PluginExtensionShelf: View {
    @ObservedObject var host: PluginExtensionHost
    @EmberTheme private var theme
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension").foregroundStyle(theme.accent)
            Text(L10n.string("plugins.extensions.title", defaultValue: "확장"))
                .font(.caption.weight(.medium)).foregroundStyle(theme.secondaryText)
            ForEach(host.extensions) { item in
                Button { host.show(item.id) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(item.session.isRunning ? theme.accent : theme.secondaryText).frame(width: 5, height: 5)
                        Text(item.name).lineLimit(1)
                    }
                }.buttonStyle(.plain).font(.caption)
                    .accessibilityIdentifier("extension-open-\(item.id)")
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 12).padding(.vertical, 6)
            .background(theme.panel).foregroundStyle(theme.primaryText)
    }
}

/// Closing this view changes presentation only. The window host owns execution.
struct PluginExtensionSidebar: View {
    @ObservedObject var host: PluginExtensionHost
    let item: PluginExtensionHost.Extension
    @ObservedObject var session: PluginScriptSession
    @State private var values: [String: String] = [:]
    @State private var inputTask: Task<Void, Never>?
    @EmberTheme private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "puzzlepiece.extension").foregroundStyle(theme.accent)
                Text(item.name).font(.headline).lineLimit(1)
                Spacer()
                Button { host.selectedIdentifier = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help(L10n.string("action.close"))
                    .accessibilityIdentifier("extension-sidebar-close")
            }.padding(14)
            HStack {
                Text(L10n.string(session.isRunning ? "plugins.script.running" : "plugins.script.stopped"))
                    .font(.caption).foregroundStyle(theme.secondaryText)
                Spacer()
                Button(L10n.string(session.isRunning ? "plugins.script.stop" : "plugins.script.restart")) {
                    if session.isRunning { host.pause(item.id) } else { host.restart(item.id) }
                }.controlSize(.small)
            }.padding(.horizontal, 14).padding(.bottom, 10)
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            if let detail = item.detail { Text(detail).font(.callout).foregroundStyle(theme.secondaryText).textSelection(.enabled) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.card, in: RoundedRectangle(cornerRadius: 9))
                    }
                    ForEach(session.view.actions ?? []) { action in
                        Button(action.label) { session.event("view.action", payload: ["id": action.id, "values": fieldValues]) }
                            .disabled(!session.isRunning)
                    }
                    if !session.commands.isEmpty {
                        Divider()
                        ForEach(session.commands) { command in
                            Button { session.command(command.id) } label: { Label(command.title, systemImage: "command") }
                                .disabled(!session.isRunning)
                        }
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 420, maxHeight: .infinity)
        .background(theme.panel).foregroundStyle(theme.primaryText).emberTint()
        .onAppear { values = fieldValues }
        .onDisappear { inputTask?.cancel() }
        .onChange(of: session.view.fields) { _, fields in
            values = Dictionary(uniqueKeysWithValues: (fields ?? []).map { ($0.id, $0.value ?? "") })
        }
        .accessibilityIdentifier("extension-sidebar")
    }

    private var fieldValues: [String: String] {
        Dictionary(uniqueKeysWithValues: (session.view.fields ?? []).map {
            ($0.id, values[$0.id] ?? $0.value ?? "")
        })
    }
}
