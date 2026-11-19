// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreImage
import PDFKit
import SwiftUI

/// Display-only multiplication: white becomes the selected paper color while
/// black ink stays black. Positive factors preserve color order without turning
/// photographs into negatives. Neither PDF pages nor shared rasters are edited.
enum PDFReadingDisplayEffect {
    static func paperColor(for theme: PDFReadingTheme) -> Color {
        let rgb = theme.paperRGB
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }

    static func makeFilter(for theme: PDFReadingTheme) -> CIFilter? {
        guard theme != .original, let filter = CIFilter(name: "CIColorMatrix") else { return nil }
        let rgb = theme.paperRGB
        // Core Image's working space is linear RGB. Converting these sRGB
        // paper colors avoids making a dim paper choice unexpectedly bright.
        filter.setValue(CIVector(x: linear(rgb.red), y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: linear(rgb.green), z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: linear(rgb.blue), w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        return filter
    }

    /// The bounded PDF clip view also paints the surrounding canvas. Only
    /// that filtered background needs compensation; outer chrome stays native.
    static func nativeCanvasColor(_ color: Color, theme: PDFReadingTheme) -> NSColor {
        nativeCanvasColor(NSColor(color), theme: theme)
    }

    static func nativeCanvasColor(_ native: NSColor, theme: PDFReadingTheme) -> NSColor {
        guard theme != .original, let rgb = native.usingColorSpace(.sRGB) else { return native }
        let paper = theme.paperRGB
        func component(_ value: CGFloat, _ multiplier: Double) -> CGFloat {
            encoded(min(1, linear(Double(value)) / max(0.001, linear(multiplier))))
        }
        return NSColor(srgbRed: component(rgb.redComponent, paper.red),
                       green: component(rgb.greenComponent, paper.green),
                       blue: component(rgb.blueComponent, paper.blue), alpha: rgb.alphaComponent)
    }

    private static func linear(_ component: Double) -> CGFloat {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ component: CGFloat) -> CGFloat {
        component <= 0.0031308 ? component * 12.92 : 1.055 * pow(component, 1 / 2.4) - 0.055
    }
}

/// Filter the bounded, unscaled PDF scroll view, below the app's transient
/// selection/ink and editing overlays. PDFKit magnifies the clip view itself:
/// filtering that clip composites at its smaller, unzoomed bounds resolution
/// and then stretches the result, blurring even vector text. The scroll view
/// keeps screen-sized bounds at every zoom. The unbounded document view is
/// never filtered: it can extend across thousands of pages.
@MainActor
final class PDFReadingDisplayFilterController {
    private weak var owner: NSView?
    private weak var view: NSView?
    private var requestedTheme: PDFReadingTheme?
    private var requestedCanvasColor: NSColor?
    private var needsCanvasReset = false
    private var appliedTheme: PDFReadingTheme?
    private var ownedFilter: CIFilter?
    private weak var backgroundClip: NSClipView?
    private var unfilteredBackground: NSColor?
    private var compensatedBackground: NSColor?
    private var isRefreshing = false

    func apply(_ theme: PDFReadingTheme, to target: NSView, canvasColor: NSColor? = nil) {
        if owner !== target {
            removeOwnedEffects()
            owner = target
            view = nil
            appliedTheme = nil
            requestedCanvasColor = nil
            needsCanvasReset = false
        }
        if let canvasColor {
            setRequestedCanvasColor(canvasColor)
            // Explicit app configuration wins over an intervening native
            // background write, even when its requested color is unchanged.
            if let pdfView = target as? PDFView, let compensatedBackground,
               pdfView.backgroundColor != compensatedBackground { needsCanvasReset = true }
        } else {
            adoptExternalCanvasColorIfNeeded()
        }
        requestedTheme = theme
        refreshTarget(observingExternalCanvas: false)
    }

    /// PDFKit may replace its scroll/clip views after document, display-mode,
    /// or layout changes. Rebind to those public view relationships while
    /// leaving the overlay hierarchy and pointer handling untouched.
    func refreshTarget() {
        refreshTarget(observingExternalCanvas: true)
    }

    private func refreshTarget(observingExternalCanvas: Bool) {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let owner, let theme = requestedTheme else { return }
        if observingExternalCanvas { adoptExternalCanvasColorIfNeeded() }
        let target: NSView?
        if let pdfView = owner as? PDFView {
            if let scroll = pdfView.documentView?.enclosingScrollView,
               scroll.isDescendant(of: pdfView) {
                target = scroll
            } else {
                // Before PDFKit creates its document hierarchy, wait for the
                // next layout. Never temporarily filter the overlay parent.
                target = nil
            }
        } else {
            target = owner
        }
        if view !== target {
            removeOwnedEffects()
            view = target
            appliedTheme = nil
            needsCanvasReset = true
        }
        guard let target else { return }
        if let pdfView = owner as? PDFView, let scroll = target as? NSScrollView,
           let canvas = requestedCanvasColor {
            let clip = scroll.contentView
            if let backgroundClip, backgroundClip !== clip {
                restoreOwnedCanvas()
                needsCanvasReset = true
            }
            // PDFView.backgroundColor reads the clip's color on some macOS
            // versions. Never feed that compensated getter back into this
            // calculation: repeated layout would brighten it toward white.
            if needsCanvasReset {
                if pdfView.backgroundColor != canvas { pdfView.backgroundColor = canvas }
                needsCanvasReset = false
            }
            let compensated = PDFReadingDisplayEffect.nativeCanvasColor(canvas, theme: theme)
            backgroundClip = clip
            unfilteredBackground = canvas
            compensatedBackground = compensated
            if clip.backgroundColor != compensated { clip.backgroundColor = compensated }
        }
        if appliedTheme == theme {
            if let ownedFilter, target.contentFilters.contains(where: { $0 === ownedFilter }) { return }
            if theme == .original { return }
        }
        removeOwnedFilter()
        appliedTheme = theme
        guard let filter = PDFReadingDisplayEffect.makeFilter(for: theme) else { return }
        target.wantsLayer = true
        target.contentFilters = target.contentFilters + [filter]
        ownedFilter = filter
    }

    func detach() {
        removeOwnedEffects()
        owner = nil
        view = nil
        requestedTheme = nil
        requestedCanvasColor = nil
        needsCanvasReset = false
        appliedTheme = nil
    }

    private func setRequestedCanvasColor(_ color: NSColor) {
        if requestedCanvasColor != color {
            requestedCanvasColor = color
            needsCanvasReset = true
        }
    }

    private func adoptExternalCanvasColorIfNeeded() {
        guard let pdfView = owner as? PDFView else { return }
        if requestedCanvasColor == nil {
            setRequestedCanvasColor(pdfView.backgroundColor)
        } else if let backgroundClip,
                  backgroundClip === pdfView.documentView?.enclosingScrollView?.contentView,
                  let compensatedBackground, pdfView.backgroundColor != compensatedBackground {
            // A caller changed this same native viewport's background. A new
            // clip instead inherits our saved canvas, never its default color.
            setRequestedCanvasColor(pdfView.backgroundColor)
        }
    }

    private func removeOwnedEffects() {
        removeOwnedFilter()
        restoreOwnedCanvas()
    }

    private func restoreOwnedCanvas() {
        if let backgroundClip, let unfilteredBackground, let compensatedBackground,
           backgroundClip.backgroundColor == compensatedBackground {
            backgroundClip.backgroundColor = unfilteredBackground
        }
        backgroundClip = nil
        unfilteredBackground = nil
        compensatedBackground = nil
    }

    private func removeOwnedFilter() {
        if let view, let ownedFilter {
            view.contentFilters = view.contentFilters.filter { $0 !== ownedFilter }
        }
        ownedFilter = nil
    }
}

/// Raster caches retain their original colors. Changing the reading theme
/// updates only composition and does not schedule another thumbnail render.
private struct PDFReadingAppearanceModifier: ViewModifier {
    @AppStorage(PDFReadingTheme.defaultsKey) private var themeValue = PDFReadingTheme.original.rawValue

    func body(content: Content) -> some View {
        content.colorMultiply(PDFReadingDisplayEffect.paperColor(
            for: PDFReadingTheme(rawValue: themeValue) ?? .original
        ))
    }
}

extension View {
    func pdfReadingAppearance() -> some View {
        modifier(PDFReadingAppearanceModifier())
    }
}
