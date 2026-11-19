// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import SwiftUI
import XCTest
@testable import HwattakPDF

/// Exercises the integration's new copy through the real preferences and
/// localization path. Every defaults mutation is restored, even on failure.
final class PDFIntegrationLocalizationTests: XCTestCase {
    private static let differenceSuffixes = [
        "title", "close", "scope", "before", "after", "start", "restart", "cancel", "navigation", "ready",
        "reading", "comparing", "cancelled", "changed", "identical", "count", "textless", "truncated",
        "whole_page", "page", "added", "removed", "modified", "unavailable", "restricted", "too_large", "no_text", "timed_out"
    ]
    private static let structureSuffixes = [
        "error.unsupported", "error.page_labels", "error.destination", "error.form_fields", "error.too_complex", "error.copy", "imported_document", "signed_original_notice"
    ]
    private static var requiredKeys: Set<String> {
        Set(differenceSuffixes.map { "comparison.difference." + $0 } + structureSuffixes.map { "page_structure." + $0 } + ["pdf.rendering_unavailable"])
    }

    func testAllThirtySevenIntegrationKeysExistWithMatchingIntegerFormatsInTenLanguages() throws {
        XCTAssertEqual(Self.requiredKeys.count, 37)
        XCTAssertEqual(AppLanguage.allCases.count, 10)
        let english = try Self.table(.english)
        let expectedFormats = ["comparison.difference.reading": 2, "comparison.difference.count": 1,
                               "comparison.difference.textless": 1, "comparison.difference.page": 1]
        for language in AppLanguage.allCases {
            let table = try Self.table(language)
            for key in Self.requiredKeys.sorted() {
                let value = try XCTUnwrap(table[key], "Missing \(language.rawValue): \(key)")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
                XCTAssertNotEqual(value, key, "A raw localization key cannot be visible copy.")
                XCTAssertFalse(value.contains("comparison.difference.") || value.contains("page_structure."), key)
                let actual = try Self.integerFormatCount(value)
                XCTAssertEqual(actual, expectedFormats[key] ?? 0, "\(language.rawValue): \(key)")
                XCTAssertEqual(actual, try Self.integerFormatCount(try XCTUnwrap(english[key])), key)
            }
        }
    }

    @MainActor
    func testPreferenceLanguageChangesNotifyAndRefreshActualLookupAndFormatting() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppPreferences.languageDefaultsKey)
        defer { Self.restore(previous, in: defaults) }
        let preferences = AppPreferences(defaults: defaults, appearanceDidChange: { _ in })
        preferences.language = .english
        let received = NotificationLog()
        let observer = NotificationCenter.default.addObserver(forName: .appLanguageDidChange, object: nil, queue: nil) { notification in
            if let language = notification.object as? AppLanguage { received.append(language.rawValue) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var titles = Set<String>()
        for language in AppLanguage.allCases {
            preferences.language = language
            XCTAssertEqual(defaults.string(forKey: AppPreferences.languageDefaultsKey), language.rawValue)
            XCTAssertEqual(L10n.currentLanguage, language)
            let table = try Self.table(language)
            for key in Self.requiredKeys {
                XCTAssertEqual(L10n.string(key), table[key], "Runtime lookup must follow \(language.rawValue): \(key)")
            }
            let reading = try XCTUnwrap(table["comparison.difference.reading"])
            XCTAssertEqual(L10n.format("comparison.difference.reading", 3, 9),
                           String(format: reading, locale: language.locale, arguments: [3, 9]))
            let count = try XCTUnwrap(table["comparison.difference.count"])
            XCTAssertEqual(PDFDocumentDifferenceText.format("count", "untranslated", 7),
                           String(format: count, locale: language.locale, arguments: [7]))
            XCTAssertEqual(PDFDocumentDifferenceText.string("title", "untranslated"), table["comparison.difference.title"])
            titles.insert(L10n.string("comparison.difference.title"))
        }
        XCTAssertEqual(received.values, AppLanguage.allCases.map(\.rawValue))
        XCTAssertGreaterThan(titles.count, 5)
        let beforeUnchangedAssignment = received.values.count
        preferences.language = .arabic
        XCTAssertEqual(received.values.count, beforeUnchangedAssignment, "Assigning the current language must not announce another change.")
    }

    @MainActor
    func testOneCompletedComparisonPanelSurvivesTenLanguagesAndArabicLayoutDirection() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppPreferences.languageDefaultsKey)
        defer { Self.restore(previous, in: defaults) }
        let preferences = AppPreferences(defaults: defaults, appearanceDidChange: { _ in })
        preferences.language = .english
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-integration-language-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try fixture(text: "Original paragraph with one changed word.", name: "Original.pdf", directory: directory)
        let after = try fixture(text: "Revised paragraph with one changed word.", name: "Revised.pdf", directory: directory)
        let originals = try [before, after].map { try Data(contentsOf: XCTUnwrap($0.workspace.documentURL)) }
        let comparisonRevisions = [before.workspace.comparisonRevision, after.workspace.comparisonRevision]
        let initialRenderingRevisions = [before.workspace.revision, after.workspace.revision]
        let pageIdentities = [before, after].map { ObjectIdentifier($0.workspace.document!) }
        let service = PDFDocumentDifferenceService()
        service.start(before: before, after: after)
        await service.waitForCompletion()
        XCTAssertEqual(service.phase, .completed)
        let report = try XCTUnwrap(service.report)
        XCTAssertFalse(report.changes.isEmpty)
        let direction = DirectionCapture()
        let panel = PDFDocumentDifferenceView(documents: [before, after], lockedIDs: [], service: service, reveal: { _ in }, close: {})
        let host = NSHostingView(rootView: LanguageContainer(preferences: preferences, panel: panel, direction: direction))
        let identity = ObjectIdentifier(host)
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 760)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        let output = ProcessInfo.processInfo.environment["EMBER_INTEGRATION_LANGUAGE_QA_DIRECTORY"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        var measurements: [[String: Any]] = []
        for (index, language) in AppLanguage.allCases.enumerated() {
            let renderingRevisions = [before.workspace.revision, after.workspace.revision]
            preferences.language = language
            // The real app refreshes every workspace after changing language.
            // Rendering must refresh without invalidating text-only reports.
            before.workspace.refreshLocalization()
            after.workspace.refreshLocalization()
            service.invalidateIfNeeded(availableIDs: [before.id, after.id])
            XCTAssertEqual([before.workspace.comparisonRevision, after.workspace.comparisonRevision], comparisonRevisions)
            XCTAssertNotEqual(before.workspace.revision, renderingRevisions[0])
            XCTAssertNotEqual(after.workspace.revision, renderingRevisions[1])
            let width: CGFloat = index.isMultiple(of: 2) ? 300 : 340
            window.setContentSize(CGSize(width: width, height: 760))
            host.setFrameSize(CGSize(width: width, height: 760))
            for _ in 0..<5 {
                await Task.yield()
                try await Task.sleep(nanoseconds: 10_000_000)
                host.layoutSubtreeIfNeeded()
            }
            host.displayIfNeeded()
            XCTAssertTrue(window.contentView === host)
            XCTAssertEqual(ObjectIdentifier(host), identity)
            XCTAssertEqual(direction.value, language.layoutDirection)
            XCTAssertEqual(service.phase, .completed)
            XCTAssertEqual(service.beforeID, before.id)
            XCTAssertEqual(service.afterID, after.id)
            XCTAssertEqual(service.report?.changes, report.changes)
            XCTAssertEqual(service.report?.beforePageCount, report.beforePageCount)
            XCTAssertEqual(service.report?.afterPageCount, report.afterPageCount)
            XCTAssertEqual(service.report?.textlessPageCount, report.textlessPageCount)
            XCTAssertEqual(service.report?.isTruncated, report.isTruncated)
            let labels = Self.accessibleStrings(in: host)
            XCTAssertFalse(labels.contains { $0.contains("comparison.difference.") || $0.contains("page_structure.") },
                           "Raw localization keys appeared in the actual panel's accessibility tree: \(language.rawValue)")
            let png = try autoreleasepool {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 4_000, "The completed sidebar must render its content.")
                return png
            }
            if let output { try png.write(to: output.appendingPathComponent("comparison-language-\(language.rawValue).png")) }
            measurements.append(["language": language.rawValue, "width": Double(width), "height": 760,
                                 "direction": language == .arabic ? "rightToLeft" : "leftToRight", "phase": "completed",
                                 "changeCount": report.changes.count, "title": L10n.string("comparison.difference.title"),
                                 "accessibilityStrings": labels, "pngBytes": png.count])
        }
        XCTAssertEqual([before.workspace.comparisonRevision, after.workspace.comparisonRevision], comparisonRevisions)
        XCTAssertNotEqual(before.workspace.revision, initialRenderingRevisions[0])
        XCTAssertNotEqual(after.workspace.revision, initialRenderingRevisions[1])
        XCTAssertEqual([before, after].map { ObjectIdentifier($0.workspace.document!) }, pageIdentities)
        for (index, source) in [before, after].enumerated() {
            XCTAssertFalse(source.workspace.isDirty)
            XCTAssertFalse(source.workspace.canUndo)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(source.workspace.documentURL)), originals[index])
        }
        if let output {
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("comparison-language-report.json"))
        }
    }

    @MainActor private func fixture(text: String, name: String, directory: URL) throws -> ComparisonDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 480, height: 320)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 35, y: 240)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        let url = directory.appendingPathComponent(name)
        try (data as Data).write(to: url)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        return ComparisonDocument(id: UUID(), workspace: workspace)
    }

    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private static func table(_ language: AppLanguage) throws -> [String: String] {
        let url = projectRoot.appendingPathComponent("Resources/Localization/\(language.rawValue).lproj/Localizable.strings")
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: String])
    }
    private static func integerFormatCount(_ value: String) throws -> Int {
        let withoutLiteralPercent = value.replacingOccurrences(of: "%%", with: "")
        let expression = try NSRegularExpression(pattern: "%([0-9]+\\$)?d")
        let range = NSRange(location: 0, length: withoutLiteralPercent.utf16.count)
        let matches = expression.matches(in: withoutLiteralPercent, range: range)
        let allPercentCount = withoutLiteralPercent.filter { $0 == "%" }.count
        XCTAssertEqual(matches.count, allPercentCount, "New integration strings must use only matching integer formats: \(value)")
        return matches.count
    }
    private static func restore(_ previous: Any?, in defaults: UserDefaults) {
        if let previous { defaults.set(previous, forKey: AppPreferences.languageDefaultsKey) }
        else { defaults.removeObject(forKey: AppPreferences.languageDefaultsKey) }
        NotificationCenter.default.post(name: .appLanguageDidChange, object: AppPreferences.savedLanguage)
    }

    /// SwiftUI accessibility elements need not be NSViews. Walk their public
    /// accessibility selectors as well as materialized AppKit subviews.
    @MainActor private static func accessibleStrings(in root: NSView) -> [String] {
        var pending: [NSObject] = [root], visited: Set<ObjectIdentifier> = [], values: Set<String> = []
        while let object = pending.popLast(), visited.count < 5_000 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                let selector = NSSelectorFromString(name)
                if object.responds(to: selector), let result = object.perform(selector)?.takeUnretainedValue() as? String, !result.isEmpty {
                    values.insert(result)
                }
            }
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                pending.append(contentsOf: children)
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return values.sorted()
    }

    private final class NotificationLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }
    @MainActor private final class DirectionCapture { var value: LayoutDirection? }
    @MainActor private struct LanguageContainer: View {
        @ObservedObject var preferences: AppPreferences
        let panel: PDFDocumentDifferenceView
        let direction: DirectionCapture
        var body: some View {
            panel.background(DirectionProbe { direction.value = $0 })
                .environment(\.locale, preferences.language.locale)
                .environment(\.layoutDirection, preferences.language.layoutDirection)
                .environment(\.colorScheme, .light)
        }
    }
    @MainActor private struct DirectionProbe: NSViewRepresentable {
        @Environment(\.layoutDirection) private var direction
        let capture: (LayoutDirection) -> Void
        init(capture: @escaping (LayoutDirection) -> Void) { self.capture = capture }
        func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
        func updateNSView(_ nsView: NSView, context: Context) { capture(direction) }
    }
}
