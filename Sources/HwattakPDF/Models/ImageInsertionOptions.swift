// SPDX-License-Identifier: MPL-2.0

import AppKit

enum ImageInsertionQuality: String, CaseIterable, Identifiable {
    case original, balanced, small

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: L10n.string("image.insert.quality.original", defaultValue: "원본 우선")
        case .balanced: L10n.string("image.insert.quality.balanced", defaultValue: "균형")
        case .small: L10n.string("image.insert.quality.small", defaultValue: "작은 용량")
        }
    }

    var detail: String {
        switch self {
        case .original:
            L10n.string("image.insert.quality.original.detail", defaultValue: "가능한 경우 원본 JPEG를 재압축 없이 유지합니다. 큰 이미지는 안전한 크기로 조정됩니다.")
        case .balanced:
            L10n.string("image.insert.quality.balanced.detail", defaultValue: "최대 2,400px로 줄이고 사진을 다시 압축합니다. 세부 표현이 일부 달라질 수 있습니다.")
        case .small:
            L10n.string("image.insert.quality.small.detail", defaultValue: "최대 1,600px로 줄이고 사진을 더 강하게 압축합니다. 확대하면 화질 저하가 보일 수 있습니다.")
        }
    }

    var rasterBudget: PDFRasterBudget? {
        switch self {
        case .original: nil
        case .balanced: PDFRasterBudget(maximumDimension: 2_400, maximumPixelCount: 5_760_000)
        case .small: PDFRasterBudget(maximumDimension: 1_600, maximumPixelCount: 2_560_000)
        }
    }

    var jpegQuality: CGFloat? {
        switch self {
        case .original: nil
        case .balanced: 0.85
        case .small: 0.65
        }
    }
}

/// The preview and committed annotation share this immutable prepared image;
/// confirming never reloads a file that may have changed while the sheet was open.
struct PreparedImageInsertion {
    let sourceURL: URL
    let image: NSImage
    let originalJPEG: PDFOriginalJPEG?
    let sourceBytes: Int
    let estimatedAddedBytes: Int
    let sourcePixelSize: CGSize
    let pixelSize: CGSize
    let isResized: Bool
    let preservesTransparency: Bool
    let isRecompressed: Bool
    let option: ImageInsertionQuality
}
