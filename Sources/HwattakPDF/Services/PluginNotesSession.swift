// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// Recomputed by the host only after checking the current grant and PDF rights.
/// No document URL, PDFKit object, or arbitrary file path enters the notes UI.
struct PluginNoteSource: Equatable {
    let documentName: String
    let pageNumber: Int
    let selectedText: String?

    var citation: String {
        let name = Self.literal(documentName.prefix(512).description)
        let page = String(format: L10n.string("plugins.notes.page", defaultValue: "%d페이지"), max(1, pageNumber))
        return "**\(name)** · \(page)"
    }

    var quotation: String? {
        guard let selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let bounded = EncodedTextLimiter.limit(selectedText, budget: HwattakPluginLimits.renderedTextBudget).text
        let quoted = bounded.components(separatedBy: .newlines).map { "> " + Self.literal($0) }.joined(separator: "\n")
        return quoted + "\n\n" + citation
    }

    /// PDF content is quoted literally; it cannot manufacture links or images
    /// when the user later opens this Markdown note in a different editor.
    private static func literal(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["`", "*", "_", "[", "]", "!", "<", ">", "#", "|"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

/// Owned by a PDF workspace, not a view. Switching tabs, hiding/replacing the
/// companion, or revoking a plug-in does not deallocate an unsaved note.
@MainActor
final class PluginNotesSession: ObservableObject {
    enum CloseChoice { case save, discard, cancel }

    @Published private(set) var text = ""
    @Published private(set) var fileURL: URL?
    @Published private(set) var message: String?
    @Published private(set) var isModified = false
    private var savedText = ""
    private var version: PluginNotesFileStore.Version?
    private var access: SecurityScopedAccess?

    var displayName: String {
        fileURL?.lastPathComponent ?? L10n.string("plugins.notes.untitled", defaultValue: "새 노트.md")
    }

    func updateText(_ value: String) {
        guard value.utf8.count <= PluginNotesFileStore.maximumFileBytes else {
            message = PluginNotesFileStore.Failure.tooLarge.localizedDescription
            return
        }
        guard !value.contains("\0") else {
            message = PluginNotesFileStore.Failure.invalidText.localizedDescription
            return
        }
        text = value
        isModified = text != savedText
        message = nil
    }

    func append(_ value: String) {
        updateText(text + (text.isEmpty ? "" : "\n\n") + value + "\n")
    }

    func newNote(authorization: () -> Bool = { true }) {
        guard authorization(), confirmCanClose(authorization: authorization), authorization() else { return }
        text = ""
        savedText = ""
        fileURL = nil
        version = nil
        access = nil
        isModified = false
        message = nil
    }

    func chooseAndOpen(authorization: () -> Bool = { true }) {
        guard authorization() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.markdownTypes
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.title = L10n.string("plugins.notes.open", defaultValue: "Markdown 열기")
        if panel.runModal() == .OK, authorization(), let url = panel.url,
           confirmCanClose(authorization: authorization), authorization() {
            _ = open(url: url, authorization: authorization)
        }
    }

    /// URL is host-only, selected by NSOpenPanel (injectable for file tests).
    @discardableResult
    func open(url: URL, authorization: () -> Bool = { true }) -> Bool {
        guard authorization() else { return false }
        let newAccess = SecurityScopedAccess(url: url)
        do {
            guard authorization() else { return false }
            let loaded = try withExtendedLifetime(newAccess) { try PluginNotesFileStore.load(from: url) }
            text = loaded.text
            savedText = loaded.text
            fileURL = url
            version = loaded.version
            access = newAccess
            isModified = false
            message = nil
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func save(asCopy: Bool = false, authorization: () -> Bool = { true }) -> Bool {
        guard authorization() else { return false }
        if !asCopy, let fileURL { return save(to: fileURL, expectedVersion: version, authorization: authorization) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.markdownTypes
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = displayName
        panel.title = L10n.string("plugins.notes.save", defaultValue: "Markdown 저장")
        guard panel.runModal() == .OK, authorization(), let url = panel.url else { return false }
        let newAccess = SecurityScopedAccess(url: url)
        do {
            guard authorization() else { return false }
            let approvedVersion = try withExtendedLifetime(newAccess) { try PluginNotesFileStore.version(at: url) }
            // Save As to the current path must not refresh away an external
            // edit conflict merely because a panel approved that same name.
            let expected = fileURL.map { PDFSourceFileVersion.refersToSameLocation($0, url) } == true
                ? version : approvedVersion
            return withExtendedLifetime(newAccess) { save(to: url, expectedVersion: expected, authorization: authorization) }
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func save(to url: URL, expectedVersion: PluginNotesFileStore.Version?, authorization: () -> Bool = { true }) -> Bool {
        guard authorization() else { return false }
        let newAccess = SecurityScopedAccess(url: url)
        do {
            guard authorization() else { return false }
            let savedVersion = try withExtendedLifetime(newAccess) {
                try PluginNotesFileStore.save(text, to: url, expectedVersion: expectedVersion)
            }
            savedText = text
            version = savedVersion
            fileURL = url
            access = newAccess
            isModified = false
            message = nil
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func closeDecision() -> CloseChoice {
        guard isModified else { return .discard }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("plugins.notes.unsaved.title", defaultValue: "노트의 변경 내용을 저장할까요?")
        alert.informativeText = displayName
        alert.addButton(withTitle: L10n.string("action.save", defaultValue: "저장"))
        alert.addButton(withTitle: L10n.string("action.cancel", defaultValue: "취소"))
        alert.addButton(withTitle: L10n.string("action.dont_save", defaultValue: "저장 안 함"))
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.buttons[2].hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Immediate single-panel flow. Multi-tab close collects decisions first,
    /// then invokes discardChanges only after every tab has accepted closing.
    func confirmCanClose(authorization: () -> Bool = { true }) -> Bool {
        guard authorization() else { return false }
        guard isModified else { return true }
        let choice = closeDecision()
        guard authorization() else { return false }
        switch choice {
        case .save: return save(authorization: authorization)
        case .discard: discardChanges(); return true
        case .cancel: return false
        }
    }

    func discardChanges() {
        text = savedText
        isModified = false
        message = nil
    }

    private static var markdownTypes: [UTType] {
        ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
    }
}
