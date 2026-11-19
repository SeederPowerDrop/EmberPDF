// SPDX-License-Identifier: MPL-2.0

import SwiftUI

struct PluginCommandPalette: View {
    @ObservedObject private var runtimeCommands = PluginRuntimeCommandRegistry.shared
    @ObservedObject var manager: PluginManager
    @ObservedObject var workspace: PDFWorkspaceState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pluginCommandScope) private var commandScope
    @State private var query = ""
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    private struct Command: Identifiable {
        let plugin: InstalledPlugin
        let action: PluginActionManifest
        var id: String { plugin.id + "/" + action.id }
    }
    private var commands: [Command] {
        manager.enabledPlugins.flatMap { plugin in
            plugin.manifest.actions.map { Command(plugin: plugin, action: $0) }
        }.filter {
            query.isEmpty || "\($0.plugin.manifest.displayName) \($0.action.title) \($0.action.description ?? "")"
                .localizedStandardContains(query)
        }
    }
    private var filteredRuntimeCommands: [PluginScriptCommand] {
        runtimeCommands.commands(in: commandScope).filter {
            query.isEmpty || $0.title.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("plugins.palette.title")).font(.title2.bold())
            TextField(L10n.string("plugins.palette.search"), text: $query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .onSubmit {
                    if let first = commands.first(where: { isAvailable($0) }) {
                        run(first)
                    } else if let first = filteredRuntimeCommands.first {
                        runRuntimeCommand(first)
                    }
                }
            List {
                ForEach(commands) { command in
                Button { run(command) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(BundledPluginPresentation.actionTitle(command.action, in: command.plugin.manifest))
                        Text(BundledPluginPresentation.displayName(for: command.plugin.manifest))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(!isAvailable(command))
                }
                ForEach(filteredRuntimeCommands) { command in
                    Button { runRuntimeCommand(command) } label: {
                        Label(command.title, systemImage: "puzzlepiece.extension")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Text(L10n.string("plugins.palette.help")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("action.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 580, height: 470)
        .onAppear { searchFocused = true }
    }

    private func isAvailable(_ command: Command) -> Bool {
        PluginCommandAvailability.isAvailable(command.action, workspace: workspace)
            && manager.isAuthorized(pluginIdentifier: command.plugin.id,
                manifestDigest: command.plugin.manifestDigest, actionID: command.action.id)
    }

    private func run(_ command: Command) {
        do {
            try PluginActionLauncher.run(manager: manager, plugin: command.plugin, action: command.action, workspace: workspace)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func runRuntimeCommand(_ command: PluginScriptCommand) {
        runtimeCommands.run(command.id, scope: commandScope)
        dismiss()
    }
}
