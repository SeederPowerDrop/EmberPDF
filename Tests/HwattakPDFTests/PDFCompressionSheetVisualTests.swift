// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI
import XCTest
@testable import HwattakPDF

final class PDFCompressionSheetVisualTests: XCTestCase {
    @MainActor
    func testQualitySheetsRenderAtNativeWidthInKoreanEnglishAndBothAppearances() async throws {
        guard let output = ProcessInfo.processInfo.environment["EMBER_COMPRESSION_UI_QA_DIRECTORY"] else {
            throw XCTSkip("Set EMBER_COMPRESSION_UI_QA_DIRECTORY for native sheet visual QA.")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let imageURL = root.appendingPathComponent("Resources/AppIcon-Ember-v1.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        let defaults = UserDefaults.standard
        let oldLanguage = defaults.object(forKey: AppPreferences.languageDefaultsKey)
        let oldTheme = defaults.object(forKey: PDFReadingTheme.defaultsKey)
        defer {
            if let oldLanguage { defaults.set(oldLanguage, forKey: AppPreferences.languageDefaultsKey) }
            else { defaults.removeObject(forKey: AppPreferences.languageDefaultsKey) }
            if let oldTheme { defaults.set(oldTheme, forKey: PDFReadingTheme.defaultsKey) }
            else { defaults.removeObject(forKey: PDFReadingTheme.defaultsKey) }
        }
        defaults.set(PDFReadingTheme.original.rawValue, forKey: PDFReadingTheme.defaultsKey)
        for language in [AppLanguage.korean, .english] {
            defaults.set(language.rawValue, forKey: AppPreferences.languageDefaultsKey)
            for appearance in [ColorScheme.light, .dark] {
                let suffix = "\(language.rawValue)-\(appearance == .dark ? "dark" : "light")"
                let views: [(String, AnyView)] = [
                    ("compression", AnyView(PDFCompressionSheet(documentData: Data(count: 2_180_000), onSave: { _ in }, onCancel: {}))),
                    ("image-insertion", AnyView(ImageInsertionOptionsSheet(urls: [imageURL], onCancel: {}, onInsert: { _ in })))
                ]
                for (name, view) in views {
                    let content = AnyView(view.environment(\.locale, language.locale)
                        .environment(\.layoutDirection, language.layoutDirection)
                        .environment(\.colorScheme, appearance))
                    let controller = NSHostingController(rootView: content)
                    controller.sizingOptions = [.intrinsicContentSize]
                    let host = controller.view
                    host.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
                    host.frame = CGRect(x: 0, y: 0, width: 530, height: 700)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentViewController = controller
                    defer {
                        controller.rootView = AnyView(EmptyView())
                        window.contentViewController = nil
                        window.orderOut(nil)
                        window.close()
                    }
                    // Let the image sheet's real background preparation and
                    // subsequent SwiftUI layout finish before taking its PNG.
                    try await Task.sleep(nanoseconds: 700_000_000)
                    host.layoutSubtreeIfNeeded()
                    let height = controller.sizeThatFits(in: CGSize(width: 530, height: 10_000)).height.rounded(.up)
                    XCTAssertGreaterThanOrEqual(height, 400, "A truncated hosting view cannot verify the full sheet.")
                    XCTAssertLessThan(height, 800, "\(name)-\(suffix) should fit a normal laptop window.")
                    window.setContentSize(CGSize(width: 530, height: height))
                    host.frame = CGRect(x: 0, y: 0, width: 530, height: height)
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    XCTAssertGreaterThan(png.count, 10_000)
                    try png.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
                    print("COMPRESSION_UI_QA \(name)-\(suffix): 530 × \(Int(height)) pt")
                }
            }
        }
    }
}
