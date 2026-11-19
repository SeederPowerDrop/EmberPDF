// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI
import XCTest
@testable import HwattakPDF

final class AboutWindowChromeTests: XCTestCase {
    @MainActor
    func testCustomTitleBarHasNoHorizontalRuleInNativeWindowInBothAppearances() async throws {
        _ = NSApplication.shared
        let previewDirectory = ProcessInfo.processInfo.environment["HWATTAK_ABOUT_PREVIEWS"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let previewDirectory {
            try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        }

        for scheme in [ColorScheme.light, .dark] {
            let variant = scheme == .dark ? "dark" : "light"
            let root = AboutView(authorImage: AboutContent.authorImage(), version: "0.9.0")
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: AboutContent.windowSize)
            let window = NSWindow(
                contentRect: host.frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            // A windowless bitmap cannot exercise native titlebar safe areas.
            // Also start with a visible native separator instead of relying on
            // an OS-dependent default.
            window.titlebarSeparatorStyle = .line
            window.contentView = host
            defer {
                window.contentView = nil
                window.close()
            }

            // SwiftUI installs its NSViewRepresentable during layout. Yield to
            // AppKit so viewDidMoveToWindow and the next layout pass both run.
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            // The initializer's contentRect excludes the native titlebar; the
            // About scene instead fills a fixed-size full-content window.
            window.setFrame(CGRect(origin: window.frame.origin, size: AboutContent.windowSize), display: false)
            host.layoutSubtreeIfNeeded()

            XCTAssertTrue(host.window === window, variant)
            XCTAssertEqual(window.titlebarSeparatorStyle, .none, variant)
            XCTAssertEqual(window.titleVisibility, .hidden, variant)
            XCTAssertTrue(window.titlebarAppearsTransparent, variant)
            XCTAssertTrue(window.styleMask.contains(.fullSizeContentView), variant)
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                XCTAssertTrue(try XCTUnwrap(window.standardWindowButton(type)).isHidden, variant)
            }
            XCTAssertEqual(host.bounds.width, AboutContent.windowSize.width, accuracy: 0.01, variant)
            XCTAssertEqual(host.bounds.height, AboutContent.windowSize.height, accuracy: 0.01, variant)

            // Include the native frame/titlebar, which lives outside the
            // NSHostingView. This is an AppKit render, not a screen capture.
            let frameView = try XCTUnwrap(window.contentView?.superview)
            frameView.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)

            // The blue gradient varies only horizontally. Every row across
            // the empty center band should therefore have the same mean RGB.
            // Averaging the band removes gradient dithering without hiding a
            // horizontal rule, which changes every pixel across that band.
            // The previous outer-border overlay honored the native safe area
            // and drew a solid horizontal rule through the title at ~28pt.
            let scaleX = CGFloat(bitmap.pixelsWide) / frameView.bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / frameView.bounds.height
            let centerX = frameView.bounds.width / 2
            let sampleXs = Int((centerX - 32) * scaleX)..<Int((centerX + 32) * scaleX)
            let referenceY = Int(10 * scaleY)
            let sampleYs = Int(4 * scaleY)..<Int(44 * scaleY)
            let largestColorDelta = try largestRowColorDelta(
                in: bitmap, sampleXs: sampleXs, sampleYs: sampleYs, referenceY: referenceY
            )
            XCTAssertLessThanOrEqual(largestColorDelta, 1.0 / 255.0,
                "\(variant): a horizontal rule or misplaced border crosses the custom titlebar")

            // A one-pixel rule just two sRGB levels above the reference green
            // must still fail the same metric and unchanged one-level limit.
            // AppKit's capture can have a custom device color space that does
            // not support setColor. Copy only the sampled band into explicit
            // sRGB bytes before inserting the control rule.
            let controlSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let controlContext = try XCTUnwrap(CGContext(data: nil,
                width: sampleXs.count, height: sampleYs.count, bitsPerComponent: 8,
                bytesPerRow: sampleXs.count * 4, space: controlSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let controlBytes = try XCTUnwrap(controlContext.data).assumingMemoryBound(to: UInt8.self)
            for (localY, y) in sampleYs.enumerated() {
                for (localX, x) in sampleXs.enumerated() {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    let offset = localY * controlContext.bytesPerRow + localX * 4
                    for (channel, component) in [color.redComponent, color.greenComponent, color.blueComponent].enumerated() {
                        controlBytes[offset + channel] = UInt8((min(1, max(0, component)) * 255).rounded())
                    }
                    controlBytes[offset + 3] = 255
                }
            }
            let reference = try meanRowColor(in: bitmap, sampleXs: sampleXs, y: referenceY)
            let ruleComponents = [reference.red, reference.green + 2.0 / 255.0, reference.blue]
            let ruleY = Int(28 * scaleY) - sampleYs.lowerBound
            for x in 0..<sampleXs.count {
                let offset = ruleY * controlContext.bytesPerRow + x * 4
                for (channel, component) in ruleComponents.enumerated() {
                    controlBytes[offset + channel] = UInt8((min(1, max(0, component)) * 255).rounded())
                }
            }
            let control = NSBitmapImageRep(cgImage: try XCTUnwrap(controlContext.makeImage()))
            XCTAssertGreaterThan(try largestRowColorDelta(
                in: control, sampleXs: 0..<sampleXs.count, sampleYs: 0..<sampleYs.count,
                referenceY: referenceY - sampleYs.lowerBound
            ), 1.0 / 255.0, "\(variant): the titlebar metric must detect a two-level horizontal rule")

            if let previewDirectory {
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 10_000, variant)
                try png.write(to: previewDirectory.appendingPathComponent("about-native-window-\(variant).png"))
            }
        }
    }

    private func largestRowColorDelta(
        in bitmap: NSBitmapImageRep,
        sampleXs: Range<Int>,
        sampleYs: Range<Int>,
        referenceY: Int
    ) throws -> CGFloat {
        let reference = try meanRowColor(in: bitmap, sampleXs: sampleXs, y: referenceY)
        var largestDelta: CGFloat = 0
        for y in sampleYs {
            let color = try meanRowColor(in: bitmap, sampleXs: sampleXs, y: y)
            largestDelta = max(largestDelta,
                abs(color.red - reference.red),
                abs(color.green - reference.green),
                abs(color.blue - reference.blue))
        }
        return largestDelta
    }

    private func meanRowColor(
        in bitmap: NSBitmapImageRep,
        sampleXs: Range<Int>,
        y: Int
    ) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        for x in sampleXs {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            red += color.redComponent
            green += color.greenComponent
            blue += color.blueComponent
        }
        let count = CGFloat(sampleXs.count)
        return (red / count, green / count, blue / count)
    }
}
