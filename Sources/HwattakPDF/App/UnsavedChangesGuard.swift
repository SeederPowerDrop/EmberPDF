// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

@MainActor
final class HwattakPDFAppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: MultiDocumentWorkspaceState?
    private var terminationTask: Task<Void, Never>?
    private let menuLanguageController = AppMenuLanguageController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppPreferences.shared.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIconManager.shared.applySavedSelection()
        menuLanguageController.start()
    }

    /// AppKit can deliver Finder's native open-document request directly to
    /// the delegate rather than through an existing SwiftUI scene. Both paths
    /// share the same lifetime, sandbox scopes, and burst deduplication.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppExternalFileOpenCoordinator.shared.enqueue(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        sender.keyWindow?.makeFirstResponder(nil)
        guard let workspace else { return .terminateNow }
        let windowWorkspaces = PDFTabTearOutStore.shared.allWindowWorkspaces
        let documents = workspace.allTabs.map(\.workspace)
            + windowWorkspaces.flatMap { $0.allTabs.map(\.workspace) }
        let windowIdentities = Set(windowWorkspaces.map(ObjectIdentifier.init))
        let documentIdentities = Set(documents.map(ObjectIdentifier.init))
        terminationTask = Task { @MainActor [weak self] in
            let accepted = await UnsavedChangesGuard.confirmAndCloseAsync(
                workspaces: documents,
                validateBeforeClosing: {
                    let windows = PDFTabTearOutStore.shared.allWindowWorkspaces
                    let current = workspace.allTabs.map(\.workspace)
                        + windows.flatMap { $0.allTabs.map(\.workspace) }
                    return Set(windows.map(ObjectIdentifier.init)) == windowIdentities
                        && Set(current.map(ObjectIdentifier.init)) == documentIdentities
                },
                beforeClosing: {
                    // Persist topology before accepted scene teardown, after
                    // every asynchronous save and final state recheck.
                    workspace.freezeSessionPersistenceAfterFlushing(including: windowWorkspaces)
                    windowWorkspaces.forEach { $0.freezeSessionPersistenceAfterFlushing() }
                }
            )
            self?.terminationTask = nil
            sender.reply(toApplicationShouldTerminate: accepted)
        }
        return .terminateLater
    }
}

@MainActor
enum WorkspaceSaveCoordinator {
    private static var pendingRequests: [ObjectIdentifier: Task<Void, Never>] = [:]

    enum Purpose {
        case explicitSave
        case closing
    }

    enum Choice: Equatable {
        case overwriteOriginal
        case saveCopy
        case dontSave
        case cancel
    }

    enum Outcome: Equatable {
        case saved
        case discarded
        case cancelled
    }

    /// Presents one consistent save decision for the toolbar and Command-S.
    /// A clean document does not need another PDFKit serialization pass.
    @discardableResult
    static func requestSave(
        workspace: PDFWorkspaceState,
        decisionProvider: ((PDFWorkspaceState) -> Choice)? = nil,
        copyDestination: (() -> URL?)? = nil
    ) -> Bool {
        guard !hasPendingSave(workspace: workspace) else { return false }
        workspace.prepareForDeactivation()
        // A failed body edit can leave an unapplied draft on a clean PDF.
        // Do not report "no changes" while that input is still unsaved.
        guard workspace.pendingInlineTextEdit == nil else { return false }
        guard workspace.document != nil else {
            workspace.presentedError = WorkspaceError.noDocument.localizedDescription
            return false
        }
        guard workspace.isDirty || workspace.requiresSaveDestination else {
            workspace.statusMessage = L10n.string("status.no_changes_to_save")
            return true
        }

        return startRequest(workspace: workspace, copyDestination: copyDestination) {
            workspace.requiresSaveDestination ? .saveCopy
                : (decisionProvider?(workspace) ?? decision(for: workspace, purpose: .explicitSave))
        }
    }

    /// Command-Shift-S enters the copy flow directly, while using the same
    /// destination validation as the save confirmation dialog.
    @discardableResult
    static func requestSaveCopy(
        workspace: PDFWorkspaceState,
        copyDestination: (() -> URL?)? = nil
    ) -> Bool {
        guard !hasPendingSave(workspace: workspace) else { return false }
        workspace.prepareForDeactivation()
        guard workspace.pendingInlineTextEdit == nil else { return false }
        guard workspace.document != nil else {
            workspace.presentedError = WorkspaceError.noDocument.localizedDescription
            return false
        }
        return startRequest(workspace: workspace, copyDestination: copyDestination) { .saveCopy }
    }

    static func hasPendingSave(workspace: PDFWorkspaceState) -> Bool {
        workspace.isSaving || pendingRequests[ObjectIdentifier(workspace)] != nil
    }

    /// Includes a UI request queued before its model task gets its first turn.
    static func waitForPendingSave(workspace: PDFWorkspaceState) async {
        if let request = pendingRequests[ObjectIdentifier(workspace)] { await request.value }
        await workspace.waitForSave()
    }

    private static func startRequest(
        workspace: PDFWorkspaceState,
        copyDestination: (() -> URL?)?,
        choice: @escaping () -> Choice
    ) -> Bool {
        let id = ObjectIdentifier(workspace)
        guard pendingRequests[id] == nil, !workspace.isSaving else { return false }
        pendingRequests[id] = Task { @MainActor in
            defer { pendingRequests.removeValue(forKey: id) }
            _ = await applyAsync(choice(), to: workspace, copyDestination: copyDestination)
        }
        return true
    }

    /// Native dialogs stay on main; the model owns the detached save worker.
    static func applyAsync(
        _ choice: Choice,
        to workspace: PDFWorkspaceState,
        copyDestination: (() -> URL?)? = nil
    ) async -> Outcome {
        if choice == .overwriteOriginal || choice == .saveCopy {
            guard !workspace.isSaving else { return .cancelled }
            workspace.prepareForDeactivation()
            guard workspace.pendingInlineTextEdit == nil else { return .cancelled }
        }
        switch choice {
        case .overwriteOriginal:
            guard workspace.documentURL != nil, !workspace.requiresSaveDestination,
                  workspace.resumeIfNeeded() else { return .cancelled }
            return await workspace.saveAsynchronously() ? .saved : .cancelled
        case .saveCopy:
            let destination: URL?
            if let copyDestination { destination = copyDestination() }
            else { destination = chooseCopyDestination(for: workspace) }
            guard let destination else { return .cancelled }
            let access = SecurityScopedAccess(url: destination)
            defer { withExtendedLifetime(access) {} }
            if let original = workspace.documentURL,
               PDFSourceFileVersion.refersToSameLocation(original, destination) {
                workspace.presentedError = L10n.string("error.save_copy_same_as_original")
                return .cancelled
            }
            guard workspace.resumeIfNeeded() else { return .cancelled }
            return await workspace.saveAsynchronously(as: destination) ? .saved : .cancelled
        case .dontSave: return .discarded
        case .cancel: return .cancelled
        }
    }

    /// Performs a previously chosen action. Keeping this operation separate
    /// from the AppKit alert makes overwrite/copy/cancel behavior testable.
    static func apply(
        _ choice: Choice,
        to workspace: PDFWorkspaceState,
        copyDestination: (() -> URL?)? = nil
    ) -> Outcome {
        if choice == .overwriteOriginal || choice == .saveCopy {
            workspace.prepareForDeactivation()
            // Resolve the draft before asking for a destination or writing.
            // Keep the engine's actionable error and the original draft.
            guard workspace.pendingInlineTextEdit == nil else { return .cancelled }
        }
        switch choice {
        case .overwriteOriginal:
            guard workspace.documentURL != nil, !workspace.requiresSaveDestination else { return .cancelled }
            guard workspace.resumeIfNeeded() else { return .cancelled }
            return workspace.saveSynchronously() ? .saved : .cancelled
        case .saveCopy:
            let destination: URL?
            if let copyDestination {
                destination = copyDestination()
            } else {
                destination = chooseCopyDestination(for: workspace)
            }
            guard let destination else { return .cancelled }
            // NSSavePanel grants a security-scoped destination. Keep that
            // grant alive while the shared resolver reads device/inode metadata
            // so aliases, symlinks, and hard links cannot bypass copy safety.
            let destinationAccess = SecurityScopedAccess(url: destination)
            let isOriginal = withExtendedLifetime(destinationAccess) {
                guard let original = workspace.documentURL else { return false }
                return PDFSourceFileVersion.refersToSameLocation(original, destination)
            }
            if isOriginal {
                workspace.presentedError = L10n.string("error.save_copy_same_as_original")
                return .cancelled
            }
            // Lazy recovery tabs still own unsaved content on disk. Load only
            // when Save was chosen; Cancel/Discard must not prompt to reopen.
            guard workspace.resumeIfNeeded() else { return .cancelled }
            return workspace.saveSynchronously(as: destination) ? .saved : .cancelled
        case .dontSave:
            return .discarded
        case .cancel:
            return .cancelled
        }
    }

    static func decision(for workspace: PDFWorkspaceState, purpose: Purpose) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("alert.save_changes.title", workspace.displayName)
        alert.informativeText = purpose == .closing
            ? L10n.string("alert.save_changes.message")
            : L10n.string("alert.save_options.message")

        var choices: [Choice] = []
        if workspace.documentURL != nil && !workspace.requiresSaveDestination {
            add(
                .overwriteOriginal,
                title: L10n.string("action.overwrite_original"),
                to: alert,
                choices: &choices
            )
        }
        add(
            .saveCopy,
            title: L10n.string("action.save_copy"),
            to: alert,
            choices: &choices
        )
        add(
            .cancel,
            title: L10n.string("action.cancel"),
            to: alert,
            choices: &choices
        )
        if purpose == .closing {
            add(
                .dontSave,
                title: L10n.string("action.dont_save"),
                to: alert,
                choices: &choices
            )
        }

        for (index, choice) in choices.enumerated() {
            let button = alert.buttons[index]
            switch choice {
            case .overwriteOriginal:
                button.keyEquivalent = "\r"
            case .cancel:
                button.keyEquivalent = "\u{1b}"
            case .dontSave:
                button.hasDestructiveAction = true
            case .saveCopy:
                break
            }
        }

        let choiceIndex = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard choices.indices.contains(choiceIndex) else { return .cancel }
        return choices[choiceIndex]
    }

    private static func add(
        _ choice: Choice,
        title: String,
        to alert: NSAlert,
        choices: inout [Choice]
    ) {
        alert.addButton(withTitle: title)
        choices.append(choice)
    }

    private static func chooseCopyDestination(for workspace: PDFWorkspaceState) -> URL? {
        let baseName = workspace.documentURL?.deletingPathExtension().lastPathComponent
            ?? "EmberPDF"
        return WorkspaceFilePanels.chooseSavePDF(suggestedName: "\(baseName)-copy.pdf")
    }

}

@MainActor
enum UnsavedChangesGuard {
    private enum PendingAction {
        case keepSaved(PDFWorkspaceState)
        case discard(PDFWorkspaceState)

        var workspace: PDFWorkspaceState {
            switch self {
            case let .keepSaved(workspace), let .discard(workspace):
                return workspace
            }
        }
    }

    /// Resolves dirty documents one at a time. Discard choices are only
    /// committed after every tab has been accepted, so cancelling a later
    /// alert never destroys changes from an earlier tab.
    static func confirmAndClose(
        workspaces: [PDFWorkspaceState],
        beforeClosing: (() -> Void)? = nil,
        closeDocuments: Bool = true
    ) -> Bool {
        confirmAndClose(
            workspaces: workspaces,
            decisionProvider: {
                WorkspaceSaveCoordinator.decision(for: $0, purpose: .closing)
            },
            beforeClosing: beforeClosing,
            closeDocuments: closeDocuments
        )
    }

    /// Injectable variant used by safety tests to exercise multi-document
    /// cancellation without displaying a modal NSAlert.
    static func confirmAndClose(
        workspaces: [PDFWorkspaceState],
        decisionProvider: (PDFWorkspaceState) -> WorkspaceSaveCoordinator.Choice,
        copyDestinationProvider: ((PDFWorkspaceState) -> URL?)? = nil,
        notesDecisionProvider: ((PDFWorkspaceState) -> PluginNotesSession.CloseChoice)? = nil,
        notesSaveProvider: ((PDFWorkspaceState) -> Bool)? = nil,
        beforeClosing: (() -> Void)? = nil,
        closeDocuments: Bool = true
    ) -> Bool {
        let uniqueWorkspaces = unique(workspaces)
        // A PDFKit form control can still hold its newest text in AppKit's
        // field editor. Commit that responder before looking at `isDirty`, or
        // a tab-X/Cmd-W close could incorrectly classify it as clean.
        uniqueWorkspaces.forEach { $0.prepareForDeactivation() }

        // Native body edits can fail to fit or refer to a replaced page while
        // the PDF itself is still clean. A remaining draft must not enter the
        // clean-document discard path below, including window/app teardown.
        if let workspace = uniqueWorkspaces.first(where: { $0.pendingInlineTextEdit != nil }) {
            if workspace.presentedError == nil {
                workspace.presentedError = L10n.string("error.unsaved_close")
            }
            return false
        }

        // A review/AI draft has not been applied to the PDF and must not be
        // silently promoted merely because the app/window is closing. Cancel
        // the close so the existing sheet can return to the front and the user
        // can explicitly Apply or Cancel it.
        if let workspace = uniqueWorkspaces.first(where: \.hasPendingReviewTextDraft) {
            workspace.presentedError = L10n.string("error.unsaved_close")
            return false
        }

        var pendingActions: [PendingAction] = []
        pendingActions.reserveCapacity(uniqueWorkspaces.count)
        var pendingNoteDiscards: [PluginNotesSession] = []

        // A note belongs to the tab even when its PDF is closed, hibernated or
        // the plugin panel was hidden. Stage all discard choices: a later
        // cancel must preserve notes just as it preserves PDF edits.
        for workspace in uniqueWorkspaces where workspace.pluginNotesSession.isModified {
            let session = workspace.pluginNotesSession
            let choice = notesDecisionProvider?(workspace) ?? session.closeDecision()
            switch choice {
            case .cancel: return false
            case .save:
                guard notesSaveProvider?(workspace) ?? session.save() else { return false }
            case .discard: pendingNoteDiscards.append(session)
            }
        }

        // Document identity outlives the resident PDFKit graph. Include lazy
        // recovery tabs in decisions and clean hibernated tabs in cleanup.
        for workspace in uniqueWorkspaces where workspace.hasOpenDocument || workspace.document != nil {
            guard workspace.isDirty else {
                pendingActions.append(.discard(workspace))
                continue
            }

            let choice = decisionProvider(workspace)
            let outcome: WorkspaceSaveCoordinator.Outcome
            if let copyDestinationProvider, choice == .saveCopy {
                outcome = WorkspaceSaveCoordinator.apply(
                    choice,
                    to: workspace,
                    copyDestination: { copyDestinationProvider(workspace) }
                )
            } else {
                outcome = WorkspaceSaveCoordinator.apply(choice, to: workspace)
            }
            switch outcome {
            case .saved:
                pendingActions.append(.keepSaved(workspace))
            case .discarded:
                pendingActions.append(.discard(workspace))
            case .cancelled:
                return false
            }
        }

        // Saving has already committed durable bytes, but all document state
        // remains live until this point. This makes a later Cancel lossless.
        beforeClosing?()
        pendingNoteDiscards.forEach { $0.discardChanges() }
        if closeDocuments {
            pendingActions.forEach { $0.workspace.closeDiscardingChanges() }
        }
        return true
    }

    static func confirmAndClose(workspace: PDFWorkspaceState) -> Bool {
        confirmAndClose(workspaces: [workspace])
    }

    private static var pendingCloseWorkspaces: Set<ObjectIdentifier> = []

    @MainActor
    private struct AsyncCloseAction {
        let workspace: PDFWorkspaceState
        let documentID: ObjectIdentifier?
        let editStateID: UUID
        let discard: Bool

        init(_ workspace: PDFWorkspaceState, discard: Bool) {
            self.workspace = workspace
            documentID = workspace.document.map(ObjectIdentifier.init)
            editStateID = workspace.editStateID
            self.discard = discard
        }
    }

    /// A close transaction yields while saving, but never commits a discard or
    /// releases a document until all target states have been checked again.
    static func confirmAndCloseAsync(
        workspaces: [PDFWorkspaceState],
        decisionProvider: ((PDFWorkspaceState) -> WorkspaceSaveCoordinator.Choice)? = nil,
        copyDestinationProvider: ((PDFWorkspaceState) -> URL?)? = nil,
        notesDecisionProvider: ((PDFWorkspaceState) -> PluginNotesSession.CloseChoice)? = nil,
        notesSaveProvider: ((PDFWorkspaceState) -> Bool)? = nil,
        validateBeforeClosing: (() -> Bool)? = nil,
        beforeClosing: (() -> Void)? = nil,
        closeDocuments: Bool = true
    ) async -> Bool {
        let targets = unique(workspaces)
        let identities = Set(targets.map(ObjectIdentifier.init))
        guard pendingCloseWorkspaces.isDisjoint(with: identities) else { return false }
        pendingCloseWorkspaces.formUnion(identities)
        defer { pendingCloseWorkspaces.subtract(identities) }
        // An empty tab is still part of the close scope. While another tab's
        // save yields, the person can open a different PDF in that same model
        // without changing tab/container membership. Retain its empty identity
        // before the first await, so the new document is never silently closed.
        let emptyTargets = Dictionary(uniqueKeysWithValues: targets.compactMap { workspace in
            !workspace.hasOpenDocument && workspace.document == nil
                ? (ObjectIdentifier(workspace), AsyncCloseAction(workspace, discard: true)) : nil
        })

        // A queued toolbar request may not have set model.isSaving yet.
        // Await its actual result instead of prompting or starting a second
        // serialization. New edits made during that wait must remain open.
        for workspace in targets where WorkspaceSaveCoordinator.hasPendingSave(workspace: workspace) {
            let originalDocument = workspace.document
            await WorkspaceSaveCoordinator.waitForPendingSave(workspace: workspace)
            workspace.prepareForDeactivation()
            guard !Task.isCancelled, !workspace.isDirty,
                  originalDocument == nil || workspace.document === originalDocument,
                  workspace.pendingInlineTextEdit == nil,
                  !workspace.hasPendingReviewTextDraft else {
                return rejectAsyncClose(workspace)
            }
        }
        targets.forEach { $0.prepareForDeactivation() }
        guard !Task.isCancelled else { return false }
        if let workspace = targets.first(where: {
            $0.pendingInlineTextEdit != nil || $0.hasPendingReviewTextDraft
        }) { return rejectAsyncClose(workspace) }

        var noteDiscards: [ObjectIdentifier: String] = [:]
        for workspace in targets where workspace.pluginNotesSession.isModified {
            let session = workspace.pluginNotesSession
            switch notesDecisionProvider?(workspace) ?? session.closeDecision() {
            case .cancel: return false
            case .save:
                guard notesSaveProvider?(workspace) ?? session.save() else { return false }
            case .discard:
                noteDiscards[ObjectIdentifier(session)] = session.text
            }
        }

        var actions: [AsyncCloseAction] = []
        for workspace in targets {
            workspace.prepareForDeactivation()
            guard workspace.pendingInlineTextEdit == nil,
                  !workspace.hasPendingReviewTextDraft else { return rejectAsyncClose(workspace) }
            if let empty = emptyTargets[ObjectIdentifier(workspace)] {
                guard !workspace.hasOpenDocument, workspace.document == nil,
                      workspace.editStateID == empty.editStateID else { return rejectAsyncClose(workspace) }
                actions.append(empty)
                continue
            }
            guard workspace.isDirty else {
                actions.append(AsyncCloseAction(workspace, discard: true))
                continue
            }
            let choice = decisionProvider?(workspace)
                ?? WorkspaceSaveCoordinator.decision(for: workspace, purpose: .closing)
            let copyDestination = copyDestinationProvider.map { provider in
                { provider(workspace) }
            }
            let originalDocument = workspace.document
            let outcome = await WorkspaceSaveCoordinator.applyAsync(
                choice, to: workspace, copyDestination: copyDestination
            )
            // A newly opened inline/form editor can still own unregistered
            // input even when the captured history checkpoint was just saved.
            workspace.prepareForDeactivation()
            guard !Task.isCancelled,
                  originalDocument == nil || workspace.document === originalDocument,
                  workspace.pendingInlineTextEdit == nil,
                  !workspace.hasPendingReviewTextDraft else { return rejectAsyncClose(workspace) }
            switch outcome {
            case .saved:
                guard !workspace.isDirty else { return rejectAsyncClose(workspace) }
                actions.append(AsyncCloseAction(workspace, discard: false))
            case .discarded:
                actions.append(AsyncCloseAction(workspace, discard: true))
            case .cancelled:
                return false
            }
        }

        // An earlier accepted tab or note may have changed while a later tab
        // was being written. Re-prepare every target, then validate all states
        // without another await before committing any destructive operation.
        targets.forEach { $0.prepareForDeactivation() }
        guard !Task.isCancelled else { return false }
        for action in actions {
            let workspace = action.workspace
            guard workspace.document.map(ObjectIdentifier.init) == action.documentID,
                  workspace.editStateID == action.editStateID,
                  workspace.pendingInlineTextEdit == nil,
                  !workspace.hasPendingReviewTextDraft,
                  !WorkspaceSaveCoordinator.hasPendingSave(workspace: workspace),
                  action.discard || !workspace.isDirty else { return rejectAsyncClose(workspace) }
        }
        for workspace in targets {
            let session = workspace.pluginNotesSession
            if let original = noteDiscards[ObjectIdentifier(session)] {
                guard session.text == original else { return rejectAsyncClose(workspace) }
            } else if session.isModified { return rejectAsyncClose(workspace) }
        }
        guard validateBeforeClosing?() != false else { return false }
        beforeClosing?()
        for workspace in targets where noteDiscards[ObjectIdentifier(workspace.pluginNotesSession)] != nil {
            workspace.pluginNotesSession.discardChanges()
        }
        if closeDocuments { actions.forEach { $0.workspace.closeDiscardingChanges() } }
        return true
    }

    static func confirmAndCloseAsync(workspace: PDFWorkspaceState) async -> Bool {
        await confirmAndCloseAsync(workspaces: [workspace])
    }

    private static func rejectAsyncClose(_ workspace: PDFWorkspaceState) -> Bool {
        if workspace.presentedError == nil { workspace.presentedError = L10n.string("error.unsaved_close") }
        return false
    }

    private static func unique(_ workspaces: [PDFWorkspaceState]) -> [PDFWorkspaceState] {
        var seen: Set<ObjectIdentifier> = []
        return workspaces.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}

/// A zero-sized bridge that guards the native red close button while
/// forwarding SwiftUI's other NSWindowDelegate callbacks unchanged.
@MainActor
struct WindowCloseGuard: NSViewRepresentable {
    let workspace: MultiDocumentWorkspaceState

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace: workspace)
    }

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView(frame: .zero)
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: GuardView, context: Context) {
        context.coordinator.workspace = workspace
        view.coordinator = context.coordinator
        if let window = view.window {
            context.coordinator.attach(to: window)
        }
    }

    static func dismantleNSView(_ view: GuardView, coordinator: Coordinator) {
        coordinator.detach()
        view.coordinator = nil
    }

    final class GuardView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                coordinator?.attach(to: window)
            } else {
                coordinator?.detach()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var workspace: MultiDocumentWorkspaceState?
        private weak var guardedWindow: NSWindow?
        private weak var forwardedDelegate: (any NSWindowDelegate)?
        private var closeTask: Task<Void, Never>?
        private var allowsAcceptedClose = false

        init(workspace: MultiDocumentWorkspaceState) {
            self.workspace = workspace
        }

        func attach(to window: NSWindow) {
            guard guardedWindow !== window else { return }
            detach()
            guardedWindow = window
            forwardedDelegate = window.delegate
            window.delegate = self
        }

        func detach() {
            if guardedWindow?.delegate === self {
                guardedWindow?.delegate = forwardedDelegate
            }
            guardedWindow = nil
            forwardedDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if allowsAcceptedClose {
                allowsAcceptedClose = false
                return true
            }
            guard closeTask == nil else { return false }
            sender.makeFirstResponder(nil)
            if forwardedDelegate?.windowShouldClose?(sender) == false {
                return false
            }
            guard let workspace else { return true }
            let documents = workspace.allTabs.map(\.workspace)
            let identities = Set(documents.map(ObjectIdentifier.init))
            closeTask = Task { @MainActor [weak self, weak sender] in
                let accepted = await UnsavedChangesGuard.confirmAndCloseAsync(
                    workspaces: documents,
                    validateBeforeClosing: {
                        Set(workspace.allTabs.map { ObjectIdentifier($0.workspace) }) == identities
                    },
                    beforeClosing: {
                        let detachedWindowWorkspaces = PDFTabTearOutStore.shared
                            .allWindowWorkspaces.filter { $0 !== workspace }
                        workspace.freezeSessionPersistenceAfterFlushing(including: detachedWindowWorkspaces)
                    }
                )
                guard let self else { return }
                self.closeTask = nil
                guard accepted, let sender, self.guardedWindow === sender else { return }
                self.allowsAcceptedClose = true
                sender.performClose(nil)
                self.allowsAcceptedClose = false
            }
            return false
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (forwardedDelegate?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if forwardedDelegate?.responds(to: selector) == true {
                return forwardedDelegate
            }
            return super.forwardingTarget(for: selector)
        }
    }
}
