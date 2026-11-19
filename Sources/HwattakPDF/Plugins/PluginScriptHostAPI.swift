// SPDX-License-Identifier: MPL-2.0

import CoreFoundation
import Foundation
import PDFKit

/// The only native data surface available to an isolated script. Return values
/// contain JSON primitives, never PDFKit/AppKit objects, security bookmarks,
/// arbitrary URLs, defaults stores, or filesystem paths.
@MainActor
enum PluginScriptHostAPI {
    static let maximumListedDocuments = 128
    static let maximumInputBytes = 64 * 1_024
    private static let shortTextBudget = EncodedTextBudget(maximumCharacters: 256, maximumUTF8Bytes: 1_024)

    enum Failure: String, LocalizedError {
        case permissionDenied, invalidParameters, unavailable, copyRestricted, selectionNotOwned,
             resultTooLarge, unsupportedMethod

        var errorDescription: String? { "EmberPDF API: \(rawValue)" }
    }

    static func handle(method: String, params: [String: Any], workspace: PDFWorkspaceState,
                       collection: MultiDocumentWorkspaceState, isAuthorized: () -> Bool,
                       capabilities: Set<PluginCapability>, preferences: AppPreferences? = nil) async throws -> Any {
        try checkAuthorization(isAuthorized)
        guard method.utf8.count <= 128, params.count <= 8,
              JSONSerialization.isValidJSONObject(params),
              let input = try? JSONSerialization.data(withJSONObject: params),
              input.count <= maximumInputBytes else { throw Failure.invalidParameters }

        func require(_ capability: PluginCapability) throws {
            try checkAuthorization(isAuthorized)
            guard capabilities.contains(capability) else { throw Failure.permissionDenied }
        }
        func keys(_ allowed: Set<String> = []) throws {
            guard Set(params.keys).isSubset(of: allowed) else { throw Failure.invalidParameters }
        }
        func bounded(_ value: String) -> String { EncodedTextLimiter.limit(value, budget: shortTextBudget).text }
        func textResult(_ text: String, pageNumber: Int? = nil) -> [String: Any] {
            let limited = EncodedTextLimiter.limit(text, budget: HwattakPluginLimits.renderedTextBudget)
            var result: [String: Any] = ["text": limited.text, "truncated": limited.wasTruncated,
                                         "revision": workspace.revision.uuidString]
            if let pageNumber { result["pageNumber"] = pageNumber }
            return result
        }

        let result: Any
        switch method {
        case "document.getInfo":
            try keys(); try require(.documentMetadata)
            guard workspace.hasOpenDocument else { throw Failure.unavailable }
            var info: [String: Any] = ["name": bounded(workspace.displayName),
                "pageNumber": workspace.currentPageIndex + 1, "pageCount": workspace.pageCount,
                "revision": workspace.revision.uuidString,
                "copyAllowed": workspace.document.map { !$0.isLocked && ($0.allowsCopying || $0.permissionsStatus == .owner) } ?? false]
            if let owner = collection.workspaces.first(where: { $0.tabs.contains { $0.workspace === workspace } }),
               let tab = owner.tabs.first(where: { $0.workspace === workspace }) {
                info["workspaceID"] = owner.id.uuidString
                info["tabID"] = tab.id.uuidString
            }
            result = info

        case "document.getSelection":
            try keys(); try require(.selectedText)
            let document = try readableDocument(workspace)
            guard let selection = workspace.currentSelection else { return textResult("") }
            guard !selection.pages.isEmpty,
                  selection.pages.allSatisfy({ page in
                      let index = document.index(for: page)
                      return index != NSNotFound && document.page(at: index) === page
                  }) else { throw Failure.selectionNotOwned }
            // Refuse unusually large framework extraction before requesting its
            // complete string; the returned string has a separate encoded cap.
            guard selection.pages.count <= 16,
                  selection.pages.allSatisfy({ $0.numberOfCharacters <= 1_000_000 }) else { throw Failure.resultTooLarge }
            result = textResult(selection.string ?? "")

        case "document.getPageText":
            try keys(["pageNumber"])
            let pageNumber = try optionalPositiveInteger(params["pageNumber"]) ?? workspace.currentPageIndex + 1
            if pageNumber == workspace.currentPageIndex + 1 {
                guard capabilities.contains(.currentPageText) || capabilities.contains(.documentTextRead) else {
                    throw Failure.permissionDenied
                }
            } else {
                try require(.documentTextRead)
            }
            let document = try readableDocument(workspace)
            guard pageNumber <= document.pageCount, let page = document.page(at: pageNumber - 1) else {
                throw Failure.invalidParameters
            }
            guard page.numberOfCharacters <= 1_000_000 else { throw Failure.resultTooLarge }
            result = textResult(page.string ?? "", pageNumber: pageNumber)

        case "commands.execute":
            try keys(["kind", "color", "width", "opacity"])
            let command: PluginDocumentCommand
            do {
                command = try JSONDecoder().decode(PluginDocumentCommand.self, from: input)
                try command.validate()
            } catch {
                throw Failure.invalidParameters
            }
            try require(command.capability)
            guard let document = workspace.document, !document.isLocked else { throw Failure.unavailable }
            if command.needsSelection {
                try require(.selectedText)
                _ = try readableDocument(workspace)
                guard let selection = workspace.currentSelection, !selection.pages.isEmpty else { throw Failure.unavailable }
                guard selection.pages.allSatisfy({ page in
                    let index = document.index(for: page)
                    return index != NSNotFound && document.page(at: index) === page
                }) else { throw Failure.selectionNotOwned }
                guard selection.pages.count <= 16 else { throw Failure.resultTooLarge }
            }
            guard command.isAvailable(in: workspace) else { throw Failure.unavailable }
            try checkAuthorization(isAuthorized)
            try command.apply(to: workspace)
            result = ["executed": true, "kind": command.kind.rawValue,
                      "revision": workspace.revision.uuidString, "pageNumber": workspace.currentPageIndex + 1]

        case "workspace.listDocuments":
            try keys(); try require(.openDocumentsRead)
            var documents: [[String: Any]] = []
            var truncated = false
            outer: for owner in collection.workspaces {
                for tab in owner.tabs where tab.workspace.hasOpenDocument {
                    guard documents.count < maximumListedDocuments else { truncated = true; break outer }
                    documents.append(["workspaceID": owner.id.uuidString, "workspaceName": bounded(owner.title),
                        "tabID": tab.id.uuidString, "name": bounded(tab.displayName),
                        "pageNumber": tab.workspace.currentPageIndex + 1, "pageCount": tab.workspace.pageCount,
                        "active": collection.activeWorkspaceID == owner.id && collection.activeTabID == tab.id])
                }
            }
            result = ["documents": documents, "truncated": truncated]

        case "workspace.navigate":
            try keys(["workspaceID", "tabID", "pageNumber"]); try require(.workspaceNavigation)
            guard let workspaceIDString = params["workspaceID"] as? String, let workspaceID = UUID(uuidString: workspaceIDString),
                  let tabIDString = params["tabID"] as? String, let tabID = UUID(uuidString: tabIDString),
                  let owner = collection.workspaces.first(where: { $0.id == workspaceID }),
                  let tab = owner.tabs.first(where: { $0.id == tabID }), tab.workspace.hasOpenDocument else {
                throw Failure.invalidParameters
            }
            let pageNumber = try optionalPositiveInteger(params["pageNumber"])
            if let pageNumber, pageNumber > tab.workspace.pageCount { throw Failure.invalidParameters }
            try checkAuthorization(isAuthorized)
            guard collection.selectGalleryDocument(workspaceID: workspaceID, tabID: tabID) else { throw Failure.unavailable }
            try checkAuthorization(isAuthorized)
            if let pageNumber {
                guard pageNumber <= tab.workspace.pageCount else { throw Failure.unavailable }
                // Discard a stale saved scroll position while retaining zoom.
                let viewport = tab.workspace.pdfViewportState
                tab.workspace.restorePDFViewport(autoScales: viewport.autoScales, scaleFactor: viewport.scaleFactor,
                    horizontalScrollProgress: nil, verticalScrollProgress: nil, navigationMode: viewport.navigationMode)
                tab.workspace.setCurrentPage(pageNumber - 1)
            }
            result = ["workspaceID": workspaceID.uuidString, "tabID": tabID.uuidString,
                      "pageNumber": tab.workspace.currentPageIndex + 1]

        case "notes.get":
            try keys(); try require(.notesWrite)
            let session = workspace.pluginNotesSession
            // A Markdown file opened by another panel is not implicitly a
            // script-owned note. Its file grant is required as well.
            if session.fileURL != nil { try require(.fileReadWrite) }
            let limited = EncodedTextLimiter.limit(session.text, budget: HwattakPluginLimits.renderedTextBudget)
            result = ["text": limited.text, "truncated": limited.wasTruncated, "modified": session.isModified]

        case "notes.append":
            try keys(["text"]); try require(.notesWrite)
            let session = workspace.pluginNotesSession
            if session.fileURL != nil { try require(.fileReadWrite) }
            guard let text = params["text"] as? String, !text.isEmpty, !text.contains("\0"),
                  text.utf8.count <= maximumInputBytes else { throw Failure.invalidParameters }
            let resultingByteCount = session.text.utf8.count + (session.text.isEmpty ? 0 : 2) + text.utf8.count + 1
            guard resultingByteCount <= PluginNotesFileStore.maximumFileBytes else { throw Failure.resultTooLarge }
            try checkAuthorization(isAuthorized)
            session.append(text)
            result = ["modified": session.isModified, "byteCount": session.text.utf8.count]

        case "appearance.get":
            try keys(); try require(.appearanceWrite)
            result = appearanceValue(preferences ?? .shared)

        case "appearance.set":
            try keys(["mode", "paper"]); try require(.appearanceWrite)
            guard !params.isEmpty else { throw Failure.invalidParameters }
            let mode: AppAppearance?
            let paper: PDFReadingTheme?
            if let value = params["mode"] {
                guard let string = value as? String, let parsed = AppAppearance(rawValue: string) else { throw Failure.invalidParameters }
                mode = parsed
            } else { mode = nil }
            if let value = params["paper"] {
                guard let string = value as? String, let parsed = PDFReadingTheme(rawValue: string) else { throw Failure.invalidParameters }
                paper = parsed
            } else { paper = nil }
            let preferences = preferences ?? .shared
            try checkAuthorization(isAuthorized)
            if let mode { preferences.appearance = mode }
            if let paper { preferences.readingTheme = paper }
            result = appearanceValue(preferences)

        default:
            throw Failure.unsupportedMethod
        }

        try checkAuthorization(isAuthorized)
        guard JSONSerialization.isValidJSONObject(result),
              let data = try? JSONSerialization.data(withJSONObject: result),
              data.count <= 192 * 1_024 else { throw Failure.resultTooLarge }
        return result
    }

    private static func checkAuthorization(_ isAuthorized: () -> Bool) throws {
        guard !Task.isCancelled, isAuthorized() else { throw Failure.permissionDenied }
    }

    private static func readableDocument(_ workspace: PDFWorkspaceState) throws -> PDFDocument {
        guard let document = workspace.document, !document.isLocked else { throw Failure.unavailable }
        guard document.allowsCopying || document.permissionsStatus == .owner else { throw Failure.copyRestricted }
        return document
    }

    private static func appearanceValue(_ preferences: AppPreferences) -> [String: Any] {
        ["mode": preferences.appearance.rawValue, "paper": preferences.readingTheme.rawValue,
         "effectiveMode": preferences.effectiveAppearance.rawValue]
    }

    private static func optionalPositiveInteger(_ value: Any?) throws -> Int? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 1, number.doubleValue <= 1_000_000,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { throw Failure.invalidParameters }
        return number.intValue
    }
}
