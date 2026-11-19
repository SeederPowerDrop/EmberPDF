// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import SwiftUI
import XCTest
@testable import HwattakPDF

// Run alone: SwiftUI field editors share process-wide AppKit state with PDFKit.
final class SearchToolbarInteractionTests: XCTestCase {
    @MainActor
    func testNativeSearchFieldReturnAndShiftReturnNavigateDuringAndAfterSearch() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberPDF-SearchToolbar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = PDFDocument()
        for index in 0..<3 {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 400, height: 500)
            let consumer = try XCTUnwrap(CGDataConsumer(data: data))
            let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 40, y: 400)
            let text = NSAttributedString(string: "needle on page \(index + 1)", attributes: [
                .font: NSFont.systemFont(ofSize: 18)
            ])
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
            context.closePDF()
            let pageDocument = try XCTUnwrap(PDFDocument(data: data as Data))
            document.insert(try XCTUnwrap(pageDocument.page(at: 0)), at: index)
        }
        let url = directory.appendingPathComponent("search.pdf")
        XCTAssertTrue(document.write(to: url))
        // Hold automatic search so this fixture isolates native Return handling.
        let workspace = PDFWorkspaceState(searchDebounceDelay: {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        })
        XCTAssertTrue(workspace.open(url: url))
        workspace.searchText = "needle"
        workspace.sidebarVisible = true

        let defaultsName = "EmberPDF-SearchToolbar-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let manager = PluginManager(
            pluginsDirectory: directory.appendingPathComponent("Plugins"),
            defaults: defaults, bundledPluginsDirectory: nil
        )
        let toolbar = WorkspaceToolbar(
            workspace: workspace,
            modeToolsVisible: .constant(false),
            sidebarVisible: Binding(get: { workspace.sidebarVisible }, set: { workspace.sidebarVisible = $0 }),
            pageOverviewPlacement: .constant(.left),
            gridLayoutMode: .constant(.balanced),
            gridPagingDirection: .constant(.vertical),
            aiPanelVisible: .constant(false),
            sidebarMode: .constant(.search),
            openDocument: {}, saveDocument: {}, mergeDocument: {},
            exportSelectedPagesCombined: {}, exportSelectedPagesIndividually: {},
            insertImage: {}, showSignature: {}, showOCR: {}, shareNote: {}, enterFocusMode: {}
        )
        .environmentObject(manager)
        let hostingView = NSHostingView(rootView: toolbar)
        let window = NSWindow(
            contentRect: CGRect(x: 20, y: 20, width: 1800, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let previousKeyWindow = NSApp.keyWindow
        defer {
            _ = window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            previousKeyWindow?.makeKey()
            workspace.closeDiscardingChanges()
        }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        // Mount SwiftUI's field and key handlers before sending actual AppKit
        // events; calling the model directly would miss native field handling.
        try await Task.sleep(nanoseconds: 20_000_000)
        hostingView.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(textFields(in: hostingView).first { $0.stringValue == "needle" })
        if let editor = window.fieldEditor(true, for: field) as? NSTextView {
            // The fixture tests key delivery, not the system's out-of-process
            // spell checker, which is unavailable in the test sandbox.
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
        }
        XCTAssertTrue(window.makeFirstResponder(field))
        sendReturn(to: window)
        XCTAssertTrue(workspace.isSearching, "Return in the native field must submit the initial query.")

        // No suspension here: Return must work before the scan can publish
        // anything, with isSearching true and an empty result array.
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertTrue(window.makeFirstResponder(field))
        sendReturn(to: window)
        await waitForToolbarSearch(workspace)
        XCTAssertEqual(workspace.searchResultIndex, 1, "A second Return queues the next occurrence without restarting.")
        let resultIDs = workspace.searchNavigatorResults.map(\.id)

        XCTAssertTrue(window.makeFirstResponder(field))
        sendReturn(to: window)
        XCTAssertEqual(workspace.searchResultIndex, 2, "Return after completion advances instead of searching again.")
        sendReturn(to: window, modifiers: .shift)
        XCTAssertEqual(workspace.searchResultIndex, 1, "Shift-Return in the native field goes backward.")
        XCTAssertEqual(workspace.searchNavigatorResults.map(\.id), resultIDs)
        XCTAssertFalse(workspace.isSearching)
    }

    @MainActor
    private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }

    @MainActor
    private func sendReturn(to window: NSWindow, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        )!
        window.sendEvent(event)
    }

    @MainActor
    private func waitForToolbarSearch(_ workspace: PDFWorkspaceState) async {
        for _ in 0..<1_000 {
            if !workspace.isSearching { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("The toolbar search did not finish before the test timeout.")
    }

}
