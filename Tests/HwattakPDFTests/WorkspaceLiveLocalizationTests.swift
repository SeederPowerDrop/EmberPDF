// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import HwattakPDF

/// Run in the native desktop lane, alone. This examines already-mounted
/// NSSegmentedControl labels instead of checking translation tables only.
final class WorkspaceLiveLocalizationTests: XCTestCase {
    @MainActor
    func testOpeningDocumentMountsResponsiveSidebarAndKeepsBothVariantsStableAcrossLanguages() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.object(forKey: AppPreferences.languageDefaultsKey)
        defer {
            if let previousLanguage { defaults.set(previousLanguage, forKey: AppPreferences.languageDefaultsKey) }
            else { defaults.removeObject(forKey: AppPreferences.languageDefaultsKey) }
            NotificationCenter.default.post(name: .appLanguageDidChange, object: AppPreferences.savedLanguage)
        }
        let preferences = AppPreferences(defaults: defaults, appearanceDidChange: { _ in })
        preferences.language = .korean
        let suiteName = "EmberPDF-ResponsiveSidebar-" + UUID().uuidString
        let sidebarDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { sidebarDefaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.pdf")
        try fixture().write(to: url)
        let original = try Data(contentsOf: url)
        let workspace = PDFWorkspaceState()
        defer { workspace.closeDiscardingChanges() }
        let sidebar = SidebarSelection()
        sidebar.binding.wrappedValue = .pages
        let writesBeforeMount = sidebar.writeCount
        let host = NSHostingView(rootView: ResponsiveSidebarFixture(preferences: preferences,
            workspace: workspace, sidebar: sidebar, defaults: sidebarDefaults))
        host.frame = CGRect(x: 0, y: 0, width: 240, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            _ = window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        // Mount the actual PageSidebarView after an empty document view. Its
        // ViewThatFits owns both text and icon alternatives simultaneously;
        // the former standalone-control test could not catch colliding IDs.
        XCTAssertTrue(workspace.open(url: url))
        let document = try XCTUnwrap(workspace.document)
        workspace.setMode(.editing)
        workspace.setCurrentPage(1)
        workspace.selectedPages = [0, 1]
        workspace.recordPDFViewport(autoScales: false, scaleFactor: 1.37,
            scrollProgress: PDFScrollProgress(horizontal: 0.23, vertical: 0.67))
        XCTAssertTrue(workspace.requestInlineTextEdit(pageIndex: 1, point: CGPoint(x: 40, y: 240), annotation: nil))
        let initialDraft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.updatePendingInlineTextDraft(id: initialDraft.id, text: "Unapplied draft — 漢字",
                                               style: initialDraft.style, bounds: initialDraft.bounds)
        workspace.selectedPages = [0, 1]
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        let viewport = workspace.pdfViewportState
        var sawTextVariant = false
        var sawIconVariant = false
        for language in [AppLanguage.korean, .english, .japanese, .arabic, .korean] {
            preferences.language = language
            workspace.refreshLocalization()
            let expectedLabels = DocumentSidebarMode.allCases.map(\.title)
            for width: CGFloat in [240, 124, 640, 120, 240] {
                host.frame.size.width = width
                window.setContentSize(host.frame.size)
                var controls: [NSSegmentedControl] = []
                for _ in 0..<80 {
                    await Task.yield()
                    try await Task.sleep(nanoseconds: 10_000_000)
                    host.layoutSubtreeIfNeeded()
                    controls = descendants(of: NSSegmentedControl.self, in: host)
                        .filter { $0.segmentCount == 2 && !$0.isHiddenOrHasHiddenAncestor }
                    let matching = width >= 500
                        ? controls.contains { labels($0) == expectedLabels }
                        : !controls.isEmpty
                    if matching { break }
                }
                XCTAssertFalse(controls.isEmpty, "The production responsive sidebar must stay mounted.")
                if width >= 500 {
                    XCTAssertTrue(controls.contains { labels($0) == expectedLabels },
                                  "The text alternative must relocalize after \(language.rawValue).")
                }
                sawTextVariant = sawTextVariant || controls.contains { labels($0) == expectedLabels }
                sawIconVariant = sawIconVariant || controls.contains { control in
                    (0..<control.segmentCount).allSatisfy { control.image(forSegment: $0) != nil }
                }
                XCTAssertTrue(controls.allSatisfy { $0.selectedSegment == 0 })
                XCTAssertTrue(window.contentView === host)
                XCTAssertTrue(workspace.document === document)
                XCTAssertEqual(workspace.pendingInlineTextEdit, draft)
                XCTAssertEqual(workspace.currentPageIndex, 1)
                XCTAssertEqual(workspace.selectedPages, [0, 1])
                XCTAssertEqual(workspace.pdfViewportState, viewport)
                XCTAssertEqual(sidebar.value, .pages)
                XCTAssertEqual(sidebar.writeCount, writesBeforeMount,
                               "Recreating either locale variant must not write its selection binding.")
                XCTAssertFalse(workspace.isDirty)
                XCTAssertFalse(workspace.canUndo)
                XCTAssertNil(workspace.presentedError)
            }
        }
        XCTAssertTrue(sawTextVariant)
        XCTAssertTrue(sawIconVariant)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor
    func testMountedModeAndSidebarControlsRelocalizeWithoutChangingDocumentOrDraft() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.object(forKey: AppPreferences.languageDefaultsKey)
        defer {
            if let previousLanguage { defaults.set(previousLanguage, forKey: AppPreferences.languageDefaultsKey) }
            else { defaults.removeObject(forKey: AppPreferences.languageDefaultsKey) }
            NotificationCenter.default.post(name: .appLanguageDidChange, object: AppPreferences.savedLanguage)
        }
        let preferences = AppPreferences(defaults: defaults, appearanceDidChange: { _ in })
        preferences.language = .korean
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-LiveLocalization-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "EmberPDF-LiveLocalization-" + UUID().uuidString
        let isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }
        let plugins = PluginManager(pluginsDirectory: directory.appendingPathComponent("Plugins"),
                                    defaults: isolatedDefaults, bundledPluginsDirectory: nil)
        let url = directory.appendingPathComponent("fixture.pdf")
        try fixture().write(to: url)
        let sourceBytes = try Data(contentsOf: url)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        defer { workspace.closeDiscardingChanges() }
        let document = try XCTUnwrap(workspace.document)
        workspace.setMode(.editing)
        workspace.setCurrentPage(1)
        workspace.selectedPages = [0, 1]
        workspace.recordPDFViewport(autoScales: false, scaleFactor: 1.37,
            scrollProgress: PDFScrollProgress(horizontal: 0.23, vertical: 0.67))
        XCTAssertTrue(workspace.requestInlineTextEdit(pageIndex: 1, point: CGPoint(x: 40, y: 240), annotation: nil))
        let initialDraft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.updatePendingInlineTextDraft(id: initialDraft.id, text: "Unapplied draft — 한자 漢字", style: initialDraft.style,
                                               bounds: initialDraft.bounds)
        workspace.selectedPages = [0, 1]
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        let viewport = workspace.pdfViewportState
        let comparisonRevision = workspace.comparisonRevision
        let collection = MultiDocumentWorkspaceState(initialWorkspace: workspace)
        let tabIDs = collection.tabs.map(\.id)
        let activeTabID = collection.activeTabID
        let sidebar = SidebarSelection()
        let root = LanguageFixture(preferences: preferences, workspace: workspace, plugins: plugins, sidebar: sidebar)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 1800, height: 150)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            _ = window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        let hostIdentity = ObjectIdentifier(host)
        // The same hosting root stays mounted for every transition. Rebuilding
        // an entire window for each language would hide the reported bug.
        for language in [AppLanguage.korean, .english, .japanese, .arabic, .korean] {
            preferences.language = language
            workspace.refreshLocalization()
            let expectedModes = PDFWorkspaceMode.allCases.map(\.shortTitle)
            let expectedSidebar = DocumentSidebarMode.allCases.map(\.title)
            var modeControl: NSSegmentedControl?
            var sidebarControl: NSSegmentedControl?
            for _ in 0..<80 {
                await Task.yield()
                try await Task.sleep(nanoseconds: 10_000_000)
                host.layoutSubtreeIfNeeded()
                let controls = descendants(of: NSSegmentedControl.self, in: host)
                modeControl = controls.first { $0.segmentCount == 3 }
                sidebarControl = controls.first { $0.segmentCount == 2 }
                if modeControl.map(labels) == expectedModes, sidebarControl.map(labels) == expectedSidebar { break }
            }
            let modes = try XCTUnwrap(modeControl, "The actual mode NSSegmentedControl must be mounted.")
            let sidebarModes = try XCTUnwrap(sidebarControl, "The actual sidebar NSSegmentedControl must be mounted.")
            XCTAssertEqual(labels(modes), expectedModes, "Already-mounted mode labels must follow \(language.rawValue).")
            XCTAssertEqual(labels(sidebarModes), expectedSidebar, "Already-mounted sidebar labels must follow \(language.rawValue).")
            XCTAssertEqual(modes.selectedSegment, 1)
            XCTAssertEqual(sidebarModes.selectedSegment, 1)
            XCTAssertTrue(window.contentView === host)
            XCTAssertEqual(ObjectIdentifier(host), hostIdentity)
            XCTAssertTrue(workspace.document === document)
            XCTAssertEqual(workspace.pendingInlineTextEdit, draft)
            XCTAssertEqual(workspace.mode, .editing)
            XCTAssertEqual(workspace.currentPageIndex, 1)
            XCTAssertEqual(workspace.selectedPages, [0, 1])
            XCTAssertEqual(workspace.pdfViewportState, viewport)
            XCTAssertEqual(workspace.comparisonRevision, comparisonRevision)
            XCTAssertEqual(collection.tabs.map(\.id), tabIDs)
            XCTAssertEqual(collection.activeTabID, activeTabID)
            XCTAssertEqual(sidebar.value, .search)
            XCTAssertEqual(sidebar.writeCount, 0, "Language changes must not synthesize a sidebar selection action.")
            XCTAssertFalse(workspace.isDirty)
            XCTAssertFalse(workspace.canUndo)
            XCTAssertNil(workspace.presentedError)
        }
        XCTAssertEqual(try Data(contentsOf: url), sourceBytes)
    }

    @MainActor
    private func labels(_ control: NSSegmentedControl) -> [String] {
        (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
    }

    @MainActor
    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func fixture() throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 400, height: 500)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    @MainActor
    private final class SidebarSelection: ObservableObject {
        @Published private(set) var value: DocumentSidebarMode = .search
        private(set) var writeCount = 0

        var binding: Binding<DocumentSidebarMode> {
            Binding(get: { self.value }, set: { self.writeCount += 1; self.value = $0 })
        }
    }

    @MainActor
    private struct LanguageFixture: View {
        @ObservedObject var preferences: AppPreferences
        @ObservedObject var workspace: PDFWorkspaceState
        let plugins: PluginManager
        @ObservedObject var sidebar: SidebarSelection

        var body: some View {
            VStack {
                WorkspaceToolbar(workspace: workspace,
                    modeToolsVisible: .constant(false), sidebarVisible: .constant(true),
                    pageOverviewPlacement: .constant(.left), gridLayoutMode: .constant(.balanced),
                    gridPagingDirection: .constant(.vertical), aiPanelVisible: .constant(false),
                    sidebarMode: sidebar.binding, openDocument: {}, saveDocument: {}, mergeDocument: {},
                    exportSelectedPagesCombined: {}, exportSelectedPagesIndividually: {}, insertImage: {},
                    showSignature: {}, showOCR: {}, shareNote: {}, enterFocusMode: {})
                DocumentSidebarModePicker(selection: sidebar.binding)
                    .frame(width: 240)
            }
            .environmentObject(plugins)
            .environment(\.locale, preferences.language.locale)
            .environment(\.layoutDirection, preferences.language.layoutDirection)
        }
    }

    @MainActor
    private struct ResponsiveSidebarFixture: View {
        @ObservedObject var preferences: AppPreferences
        @ObservedObject var workspace: PDFWorkspaceState
        @ObservedObject var sidebar: SidebarSelection
        let defaults: UserDefaults

        var body: some View {
            Group {
                if workspace.hasOpenDocument {
                    PageSidebarView(workspace: workspace, placement: .left, sidebarMode: sidebar.binding)
                } else {
                    Color.clear
                }
            }
            .defaultAppStorage(defaults)
            .environment(\.locale, preferences.language.locale)
            .environment(\.layoutDirection, preferences.language.layoutDirection)
        }
    }
}
