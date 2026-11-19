// SPDX-License-Identifier: MPL-2.0

import AppKit

/// Decorative search locations. Native PDF selection and scroller tracking
/// retain their event handling; this view never takes focus or hit tests.
@MainActor
final class PDFSearchLocationOverlay: NSView {
    var matchRects: [CGRect] = [] { didSet { needsDisplay = true } }
    var markerProgresses: [CGFloat] = [] { didSet { needsDisplay = true } }
    var activeMarkerProgress: CGFloat? { didSet { needsDisplay = true } }
    var markerTrack: CGRect = .zero { didSet { needsDisplay = true } }
    var markerAxis: PDFSearchScrollAxis = .vertical { didSet { needsDisplay = true } }
    var contentClip: CGRect = .zero { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureDecorativeView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureDecorativeView()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawMatchOutlines()
        drawLocationMarkers()
    }

    private func configureDecorativeView() {
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    private func drawMatchOutlines() {
        guard Self.isUsable(contentClip) else { return }
        let clip = contentClip.intersection(bounds)
        guard Self.isUsable(clip) else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: clip).addClip()

        for rectangle in matchRects where Self.isUsable(rectangle) {
            let expanded = rectangle.insetBy(dx: -2, dy: -2)
            guard Self.isUsable(expanded), expanded.intersects(clip) else { continue }
            let outline = NSBezierPath(roundedRect: expanded, xRadius: 2, yRadius: 2)
            NSColor.controlAccentColor.withAlphaComponent(0.035).setFill()
            outline.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.42).setStroke()
            outline.lineWidth = 1
            outline.setLineDash([3, 3], count: 2, phase: 0)
            outline.stroke()
        }
    }

    private func drawLocationMarkers() {
        guard Self.isUsable(markerTrack), markerTrack.intersects(bounds) else { return }
        // Only small ticks are drawn. There is no track background to cover
        // PDFKit's native thumb or make its auto-hidden scroller opaque.
        NSColor.systemOrange.withAlphaComponent(0.75).setFill()
        for progress in markerProgresses {
            guard let rectangle = markerRect(at: progress, thickness: 2) else { continue }
            NSBezierPath(roundedRect: rectangle, xRadius: 1, yRadius: 1).fill()
        }
        if let progress = activeMarkerProgress,
           let rectangle = markerRect(at: progress, thickness: 3) {
            NSColor.controlAccentColor.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: rectangle, xRadius: 1, yRadius: 1).fill()
        }
    }

    private func markerRect(at progress: CGFloat, thickness: CGFloat) -> CGRect? {
        guard progress.isFinite, (0...1).contains(progress) else { return nil }
        let rectangle: CGRect
        switch markerAxis {
        case .vertical:
            let width = min(5, markerTrack.width)
            let height = min(thickness, markerTrack.height)
            rectangle = CGRect(
                x: markerTrack.midX - width / 2,
                y: markerTrack.minY + progress * (markerTrack.height - height),
                width: width,
                height: height
            )
        case .horizontal:
            let width = min(thickness, markerTrack.width)
            let height = min(5, markerTrack.height)
            rectangle = CGRect(
                x: markerTrack.minX + progress * (markerTrack.width - width),
                y: markerTrack.midY - height / 2,
                width: width,
                height: height
            )
        }
        return Self.isUsable(rectangle) ? rectangle : nil
    }

    private static func isUsable(_ rectangle: CGRect) -> Bool {
        rectangle.origin.x.isFinite && rectangle.origin.y.isFinite
            && rectangle.width.isFinite && rectangle.height.isFinite
            && rectangle.minX.isFinite && rectangle.maxX.isFinite
            && rectangle.minY.isFinite && rectangle.maxY.isFinite
            && rectangle.width > 0 && rectangle.height > 0
    }
}
