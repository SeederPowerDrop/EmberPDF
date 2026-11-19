// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import HwattakPDF

/// Opt-in native rendering: hidden windows do not interrupt an open document.
/// Run alone so process-wide localization and SwiftUI appearance stay stable.
final class WritingToolsVisualTests: XCTestCase {
    @MainActor
    func testWritingToolbarsAndSettingsFitInBothLanguagesAndAppearances() async throws {
        guard let output = ProcessInfo.processInfo.environment["EMBER_WRITING_QA_DIRECTORY"] else {
            throw XCTSkip("Set EMBER_WRITING_QA_DIRECTORY for native writing UI visual QA.")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("EmberWritingQA-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let suite = "EmberWritingQA-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(PDFReadingTheme.original.rawValue, forKey: PDFReadingTheme.defaultsKey)
        let standard = UserDefaults.standard
        let previousLanguage = standard.object(forKey: AppPreferences.languageDefaultsKey)
        defer {
            if let previousLanguage { standard.set(previousLanguage, forKey: AppPreferences.languageDefaultsKey) }
            else { standard.removeObject(forKey: AppPreferences.languageDefaultsKey) }
        }
        let workspace = PDFWorkspaceState()
        let source = temporary.appendingPathComponent("writing-fixture.pdf")
        try blankPDF().write(to: source)
        XCTAssertTrue(workspace.open(url: source))
        defer { workspace.closeDiscardingChanges() }
        let revision = workspace.revision
        let collection = MultiDocumentWorkspaceState(initialWorkspace: workspace)
        let providers = AIProviderSettingsStore(configurationStore: UserDefaultsAIProviderConfigurationStore(defaults: defaults),
            keyStore: InMemorySecureAIAPIKeyStore())
        let plugins = PluginManager(pluginsDirectory: temporary.appendingPathComponent("Plugins"),
            defaults: defaults, bundledPluginsDirectory: nil)

        for language in [AppLanguage.korean, .english] {
            standard.set(language.rawValue, forKey: AppPreferences.languageDefaultsKey)
            for appearance in [ColorScheme.light, .dark] {
                let suffix = "\(language.rawValue)-\(appearance == .dark ? "dark" : "light")"
                for width in [CGFloat(1_180), CGFloat(1_440)] {
                    workspace.setMode(.editing)
                    workspace.selectTool(.pen)
                    let toolbar = WorkspaceToolbar(workspace: workspace,
                        modeToolsVisible: .constant(true), sidebarVisible: .constant(true),
                        pageOverviewPlacement: .constant(.left), gridLayoutMode: .constant(.balanced),
                        gridPagingDirection: .constant(.vertical), aiPanelVisible: .constant(false),
                        sidebarMode: .constant(.search), openDocument: {}, saveDocument: {}, mergeDocument: {},
                        exportSelectedPagesCombined: {}, exportSelectedPagesIndividually: {}, insertImage: {},
                        showSignature: {}, showOCR: {}, shareNote: {}, enterFocusMode: {})
                        .environmentObject(plugins)
                    try await render(AnyView(toolbar), name: "editing-\(Int(width))-\(suffix)",
                        size: CGSize(width: width, height: 92), expectedHeight: 92,
                        language: language, appearance: appearance, defaults: defaults, directory: directory)

                    workspace.setMode(.study)
                    workspace.selectTool(.pen)
                    let study = StudyModePalette(workspace: workspace, providerSettings: providers,
                        documentCollection: collection, onOpenAssistant: {}, showOCR: {}, showStudyNotes: {}, shareNote: {})
                    try await render(AnyView(study), name: "study-\(Int(width))-\(suffix)",
                        size: CGSize(width: width, height: 46), expectedHeight: 46,
                        language: language, appearance: appearance, defaults: defaults, directory: directory)
                }

                // Keep a separate screenshot of the complete control cluster,
                // independent of the surrounding toolbar's horizontal scroll.
                try await render(AnyView(WritingToolStrip(workspace: workspace)), name: "writing-strip-\(suffix)",
                    size: CGSize(width: 850, height: 46), expectedHeight: nil,
                    language: language, appearance: appearance, defaults: defaults, directory: directory)

                var ink = InkSettings()
                ink.color = NSColor(deviceRed: 0.12, green: 0.36, blue: 0.85, alpha: 1)
                var rectangle = ink
                rectangle.drawingOptions.shape = .rectangle
                rectangle.drawingOptions.pattern = .dashed
                var highlighter = ink
                highlighter.selectStyle(.highlighter)
                highlighter.color = NSColor(deviceRed: 0.98, green: 0.82, blue: 0.08, alpha: 1)
                highlighter.drawingOptions.shape = .ellipse
                highlighter.drawingOptions.highlighterTip = .round
                for (name, settings) in [("ink", ink), ("rectangle", rectangle), ("highlighter", highlighter)] {
                    try await render(AnyView(PenSettingsPopover(settings: .constant(settings))),
                        name: "settings-\(name)-\(suffix)", size: CGSize(width: 350, height: 660), expectedHeight: 660,
                        language: language, appearance: appearance, defaults: defaults, directory: directory,
                        requiresNativePreview: true)
                }
            }
        }
        XCTAssertEqual(workspace.revision, revision, "Rendering or changing tool settings must not mutate the PDF.")
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(workspace.document?.page(at: 0)?.annotations.count, 0)
    }

    @MainActor
    private func render(_ view: AnyView, name: String, size: CGSize, expectedHeight: CGFloat?,
                        language: AppLanguage, appearance: ColorScheme, defaults: UserDefaults,
                        directory: URL, requiresNativePreview: Bool = false) async throws {
        let content = AnyView(view.environment(\.locale, language.locale)
            .environment(\.layoutDirection, language.layoutDirection)
            .environment(\.colorScheme, appearance).defaultAppStorage(defaults))
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.intrinsicContentSize]
        let host = controller.view
        host.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer {
            controller.rootView = AnyView(EmptyView())
            window.contentViewController = nil
            window.orderOut(nil)
            window.close()
        }
        try await Task.sleep(nanoseconds: 180_000_000)
        host.layoutSubtreeIfNeeded()
        let natural = controller.sizeThatFits(in: CGSize(width: size.width, height: 2_000))
        if let expectedHeight {
            XCTAssertEqual(natural.height, expectedHeight, accuracy: 1,
                "\(name) must retain its full intended height rather than a truncated host.")
        } else {
            let minimum = controller.sizeThatFits(in: CGSize(width: 1, height: 46))
            XCTAssertGreaterThan(minimum.width, 300, "The writing tools must actually be present.")
            XCTAssertLessThanOrEqual(minimum.width, size.width, "The complete writing cluster should fit comfortably on a laptop.")
        }
        XCTAssertLessThanOrEqual(natural.width, size.width + 1, "\(name) should respect the available viewport.")
        window.setContentSize(size)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        if requiresNativePreview {
            let preview = try XCTUnwrap(descendants(host).first {
                String(describing: type(of: $0)).contains("PenStrokeSampleView")
            }, "Render the real AppKit stroke sample, not a placeholder.")
            XCTAssertGreaterThan(preview.bounds.width, 200)
            XCTAssertGreaterThanOrEqual(preview.bounds.height, 59)
        }
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000, "A blank or missing toolbar is not visual validation.")
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        print("WRITING_UI_QA \(name): \(Int(size.width)) × \(Int(size.height)) pt; natural \(natural)")
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func blankPDF() throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 500, height: 650)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        return data as Data
    }
}
