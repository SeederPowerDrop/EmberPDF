// SPDX-License-Identifier: MPL-2.0

import AppKit
import IOSurface

/// PDFKit's tiled renderer needs IOSurface access. A restricted execution
/// environment can deny even a 64×64 surface; entering the tile renderer in
/// that environment can trap inside PDFTileSurface.releaseSurface instead of
/// returning a recoverable error. Probe this actual prerequisite once, before
/// constructing a native PDF view. Metal availability alone is not a gate.
enum PDFNativeRenderingAvailability: Equatable {
    enum Failure: String { case allocation, lock, unlock }
    case available
    case unavailable(Failure)

    static let current = probe()

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    static func probe(
        createSurface: () -> IOSurfaceRef? = {
            let properties: [String: Any] = [kIOSurfaceWidth as String: 64,
                                           kIOSurfaceHeight as String: 64,
                                           kIOSurfaceBytesPerElement as String: 4]
            return IOSurfaceCreate(properties as CFDictionary)
        },
        lockSurface: (IOSurfaceRef) -> Int32 = { IOSurfaceLock($0, [], nil) },
        unlockSurface: (IOSurfaceRef) -> Int32 = { IOSurfaceUnlock($0, [], nil) }
    ) -> PDFNativeRenderingAvailability {
        guard let surface = createSurface() else { return .unavailable(.allocation) }
        guard lockSurface(surface) == 0 else { return .unavailable(.lock) }
        guard unlockSurface(surface) == 0 else { return .unavailable(.unlock) }
        return .available
    }
}

@MainActor
enum PDFNativeViewFactory {
    /// The successful path returns the original PDFView directly: no wrapper,
    /// extra layer, frame conversion, delayed release, or document replacement.
    static func makeView(
        availability: PDFNativeRenderingAvailability = .current,
        makePDFView: () -> NSView
    ) -> NSView {
        guard availability.isAvailable else { return PDFNativeRenderingUnavailableView(frame: .zero) }
        return makePDFView()
    }
}

@MainActor
final class PDFNativeRenderingUnavailableView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
        refreshMessage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refreshMessage() {
        label.stringValue = L10n.string(
            "pdf.rendering_unavailable",
            defaultValue: "현재 환경에서 PDF 화면을 그릴 수 없습니다. 일반 macOS 데스크톱 세션에서 EmberPDF를 다시 열어 주세요."
        )
        label.setAccessibilityLabel(label.stringValue)
    }
}
