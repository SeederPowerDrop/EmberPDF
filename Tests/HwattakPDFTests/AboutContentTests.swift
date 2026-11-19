// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import HwattakPDF

final class AboutContentTests: XCTestCase {
    func testIntroductionExplainsTheNameAndItsPurpose() {
        let story = AboutContent.introductionParagraphs.joined(separator: "\n")
        XCTAssertTrue(story.contains("구독제"))
        XCTAssertTrue(story.contains("바이브 코딩"))
        XCTAssertTrue(story.contains("잉걸불"))
        XCTAssertTrue(story.contains("Obsidian"))
        XCTAssertTrue(story.contains("제가 할 수 있는 한"))
        XCTAssertTrue(story.hasSuffix("그리고 ERW FWS WRG"))
        XCTAssertEqual(
            AboutContent.introductionLocalizationKeys,
            (1...5).map { "about.introduction.\($0)" }
        )
    }

    func testIntroductionAndSupportCopyAreLocalizedInEveryAppLanguage() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppPreferences.languageDefaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppPreferences.languageDefaultsKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.languageDefaultsKey)
            }
        }

        var localizedIntroductions = Set<[String]>()
        var localizedSupportTitles = Set<String>()
        for language in AppLanguage.allCases {
            defaults.set(language.rawValue, forKey: AppPreferences.languageDefaultsKey)
            let paragraphs = AboutContent.localizedIntroductionParagraphs

            XCTAssertEqual(paragraphs.count, 5)
            XCTAssertTrue(paragraphs[0].contains("EmberPDF"), language.rawValue)
            XCTAssertTrue(paragraphs[2].contains("Obsidian"), language.rawValue)
            XCTAssertTrue(
                paragraphs.allSatisfy {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            )
            XCTAssertFalse(AboutContent.supportTitle.isEmpty)
            XCTAssertFalse(AboutContent.supportDetail.isEmpty)
            XCTAssertFalse(AboutContent.rightsDetail.isEmpty)
            XCTAssertTrue(paragraphs[4].contains("ERW FWS WRG"), language.rawValue)

            if language != .korean {
                XCTAssertNotEqual(paragraphs, AboutContent.introductionParagraphs)
                XCTAssertFalse(
                    AboutContent.supportDetail.contains("유일한 지원 수단"),
                    "\(language.rawValue) must not show the Korean support appeal"
                )
            }

            localizedIntroductions.insert(paragraphs)
            localizedSupportTitles.insert(AboutContent.supportTitle)
        }

        XCTAssertEqual(localizedIntroductions.count, AppLanguage.allCases.count)
        XCTAssertEqual(localizedSupportTitles.count, AppLanguage.allCases.count)
    }

    @MainActor
    func testAboutViewRendersAtReleaseWindowSizeInEveryAppLanguageAndAppearance() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppPreferences.languageDefaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppPreferences.languageDefaultsKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.languageDefaultsKey)
            }
        }

        let previewDirectory = ProcessInfo.processInfo.environment["HWATTAK_ABOUT_PREVIEWS"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let previewDirectory {
            try FileManager.default.createDirectory(
                at: previewDirectory,
                withIntermediateDirectories: true
            )
        }

        for language in AppLanguage.allCases {
            defaults.set(language.rawValue, forKey: AppPreferences.languageDefaultsKey)
            for colorScheme in [ColorScheme.light, .dark] {
                let variant = "\(language.rawValue)-\(colorScheme == .dark ? "dark" : "light")"
                let rootView = AboutView(authorImage: AboutContent.authorImage(), version: "0.9.0")
                    .environment(\.locale, language.locale)
                    .environment(\.layoutDirection, language.layoutDirection)
                    .environment(\.colorScheme, colorScheme)
                let hostingView = NSHostingView(rootView: rootView)
                hostingView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
                hostingView.frame = NSRect(origin: .zero, size: AboutContent.windowSize)
                hostingView.layoutSubtreeIfNeeded()

                let representation = try XCTUnwrap(
                    hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
                )
                hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
                let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
                let backingBounds = hostingView.convertToBacking(hostingView.bounds)

                XCTAssertGreaterThan(png.count, 10_000, variant)
                XCTAssertEqual(
                    representation.pixelsWide,
                    Int(backingBounds.width.rounded()),
                    variant
                )
                XCTAssertEqual(
                    representation.pixelsHigh,
                    Int(backingBounds.height.rounded()),
                    variant
                )
                XCTAssertEqual(hostingView.bounds.width, AboutContent.windowSize.width, accuracy: 0.01, variant)
                XCTAssertEqual(hostingView.bounds.height, AboutContent.windowSize.height, accuracy: 0.01, variant)

                // Sample the empty dialog margin, clear of content in both
                // layout directions, to catch a window stuck in one appearance.
                let canvasColor = try XCTUnwrap(
                    representation.colorAt(
                        x: Int(CGFloat(representation.pixelsWide) * 10 / AboutContent.windowSize.width),
                        y: Int(CGFloat(representation.pixelsHigh) * 200 / AboutContent.windowSize.height)
                    )?.usingColorSpace(.sRGB)
                )
                let brightness = (canvasColor.redComponent + canvasColor.greenComponent + canvasColor.blueComponent) / 3
                if colorScheme == .dark {
                    XCTAssertLessThan(brightness, 0.25, variant)
                } else {
                    XCTAssertGreaterThan(brightness, 0.80, variant)
                }

                if let previewDirectory {
                    let suffix = colorScheme == .dark ? "-dark" : ""
                    try png.write(
                        to: previewDirectory.appendingPathComponent("about-\(language.rawValue)\(suffix).png")
                    )
                }
            }
        }
    }

    @MainActor
    func testSupportAndLicensePanelsRenderInBothAppearances() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppPreferences.languageDefaultsKey)
        defaults.set(AppLanguage.korean.rawValue, forKey: AppPreferences.languageDefaultsKey)
        defer {
            if let previous { defaults.set(previous, forKey: AppPreferences.languageDefaultsKey) }
            else { defaults.removeObject(forKey: AppPreferences.languageDefaultsKey) }
        }
        for scheme in [ColorScheme.light, .dark] {
            let panels: [(String, AnyView, CGSize)] = [
                ("bitcoin", AnyView(AboutBitcoinSupportView()), CGSize(width: 400, height: 510)),
                ("licenses", AnyView(AboutLicensesView()), CGSize(width: 740, height: 560))
            ]
            for (name, panel, size) in panels {
                let host = NSHostingView(rootView: panel.environment(\.colorScheme, scheme))
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = CGRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 10_000)
                if let output = ProcessInfo.processInfo.environment["HWATTAK_ABOUT_PREVIEWS"] {
                    let suffix = scheme == .dark ? "dark" : "light"
                    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name)-\(suffix).png"))
                }
            }
        }
    }

    func testPublishedLinksUseExactExpectedWebDestinations() throws {
        let githubURL = try XCTUnwrap(AboutContent.githubURL)
        let supportURL = try XCTUnwrap(AboutContent.supportURL)

        XCTAssertEqual(
            githubURL.absoluteString,
            "https://github.com/SeederPowerDrop/HwattakPDF"
        )
        XCTAssertEqual(supportURL.absoluteString, "https://buymeacoffee.com/master_chief")
    }

    func testDonationQRCodeDecodesToTheDisplayedPublicReceivingAddress() throws {
        XCTAssertEqual(AboutSupport.koFiURL.absoluteString, "https://ko-fi.com/seederpower")
        XCTAssertEqual(AboutSupport.bitcoinAddress, "BC1QUEUAX3FJP77NZUKF732AEWVFE0YVS9ZPKUMLTV")
        let image = CIImage(cgImage: try XCTUnwrap(AboutSupport.makeBitcoinQRCode()))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode,
            context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let codes = detector.features(in: image).compactMap { $0 as? CIQRCodeFeature }
        XCTAssertEqual(codes.count, 1)
        XCTAssertEqual(codes.first?.messageString, "bitcoin:" + AboutSupport.bitcoinAddress)
    }

    func testLocalLicensePanelsIncludeTheProjectAndBundledComponents() {
        let project = AboutLicenseContent.combinedText(AboutLicenseContent.projectDocuments())
        XCTAssertTrue(project.contains("Mozilla Public License Version 2.0"))
        XCTAssertTrue(project.contains("SeederPowerDrop"))
        let components = AboutLicenseContent.componentDocuments()
        for name in ["KaTeX", "Marked", "DOMPurify", "PDFium"] {
            XCTAssertTrue(components.contains { $0.title.contains(name) && !$0.text.isEmpty }, name)
        }
        XCTAssertTrue(components.contains { $0.title == "PDFium · pdfium.txt" })
    }

    func testExternalLinkValidationAllowsOnlyHTTPWebOriginsWithoutUserInfo() {
        XCTAssertNotNil(AboutContent.validatedExternalURL("https://example.com/path?q=1"))
        XCTAssertNotNil(AboutContent.validatedExternalURL("http://example.com"))

        XCTAssertNil(AboutContent.validatedExternalURL("file:///tmp/private.pdf"))
        XCTAssertNil(AboutContent.validatedExternalURL("javascript:alert(1)"))
        XCTAssertNil(AboutContent.validatedExternalURL("mailto:owner@example.com"))
        XCTAssertNil(AboutContent.validatedExternalURL("https://user@example.com/path"))
        XCTAssertNil(AboutContent.validatedExternalURL("https:///missing-host"))
    }

    func testUserProvidedArtworkIsReadableAndSquare() throws {
        let artworkURL = Self.projectRoot
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(AboutContent.imageResourceName)
            .appendingPathExtension(AboutContent.imageResourceExtension)
        let image = try XCTUnwrap(NSImage(contentsOf: artworkURL))

        XCTAssertEqual(image.size.width, image.size.height)
        XCTAssertEqual(image.size.width, 640)
        XCTAssertGreaterThan(try Data(contentsOf: artworkURL).count, 10_000)
        XCTAssertNotNil(AboutContent.authorImage())
    }

    func testReleasePackagingScriptCopiesAndVerifiesArtworkAndLegalNotices() throws {
        let scriptURL = Self.projectRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("build_app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("ABOUT_IMAGE=\"AboutAuthor-SeederPowerDrop-UserProvided.jpg\""))
        XCTAssertTrue(script.contains("VERIFIED_APP}/Contents/Resources/${ABOUT_IMAGE}"))
        XCTAssertTrue(script.contains("LEGAL_DOCUMENTS=("))
        XCTAssertTrue(script.contains("\"TranslationCompanion.hwattakplugin\""))
        XCTAssertTrue(script.contains("\"WebBrowser.hwattakplugin\""))
        XCTAssertTrue(script.contains("SOURCE_ONLY_PLUGIN_NAMES=("))
        XCTAssertTrue(script.contains("\"YouTubeStudy.hwattakplugin\""))
        XCTAssertTrue(script.contains("Source-only plugin must not be packaged"))
        XCTAssertTrue(script.contains("Archived app contains source-only plugin"))
        XCTAssertTrue(script.contains("Contents/Resources/Legal/${legal_document}"))
        XCTAssertTrue(script.contains("AboutAuthor-UserProvided-NOTICE.txt"))
        XCTAssertTrue(script.contains("ARCHIVE_CHECKSUM_PATH=\"${ARCHIVE_PATH}.sha256\""))
        XCTAssertTrue(script.contains("rm -f \"${ARCHIVE_PATH}\" \"${ARCHIVE_CHECKSUM_PATH}\" \"${ARCHIVE_TEMPORARY}\""))
        XCTAssertTrue(script.contains("shasum -a 256"))
        XCTAssertTrue(script.contains("-file-prefix-map"))
        XCTAssertTrue(script.contains("strip -S -x"))
        XCTAssertTrue(script.contains("Release executable contains a local build path"))
        XCTAssertTrue(script.contains("grep -E '/Users/|/private/var/folders/|/var/folders/' >/dev/null"))
        XCTAssertFalse(script.contains("grep -Eq '/Users/|/private/var/folders/|/var/folders/'"))
        XCTAssertTrue(script.contains("--norsrc"))
        XCTAssertTrue(script.contains("--noextattr"))
        XCTAssertTrue(script.contains("Archive contains AppleDouble metadata"))
    }

    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
