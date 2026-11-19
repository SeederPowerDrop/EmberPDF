// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

/// Only an unchanged on-disk generation may be reopened by a preview worker.
/// The owning workspace keeps the original security-scoped grant alive.
struct PDFThumbnailFileSource: Equatable, @unchecked Sendable {
    let url: URL
    let version: PDFSourceFileVersion
}

@MainActor
extension PDFWorkspaceState {
    var thumbnailFileSource: PDFThumbnailFileSource? {
        guard let version = reusableOCRSourceVersion, let url = documentURL,
              url.isFileURL, document?.isEncrypted == false else { return nil }
        return PDFThumbnailFileSource(url: url, version: version)
    }
}

/// A completed, immutable bitmap crosses actors; live PDFKit objects do not.
struct PDFThumbnailRaster: @unchecked Sendable {
    let image: CGImage
    let size: CGSize
}

protocol PDFThumbnailFileRendering: Sendable {
    func render(source: PDFThumbnailFileSource, pageIndex: Int,
                pageBounds: CGRect, rotation: Int, targetSize: CGSize) async -> PDFThumbnailRaster?
}

/// Small visible thumbnails used to call `PDFPage.thumbnail` in the main
/// actor. Twenty scanned pages can consume several seconds there at launch.
/// One transient document at a time now owns that blocking call in this actor;
/// it is released after the page, including cancellation and failed checks.
actor PDFThumbnailFileRenderer: PDFThumbnailFileRendering {
    func render(source: PDFThumbnailFileSource, pageIndex: Int,
                pageBounds: CGRect, rotation: Int, targetSize: CGSize) -> PDFThumbnailRaster? {
        guard !Task.isCancelled, source.url.isFileURL, pageIndex >= 0,
              targetSize.width.isFinite, targetSize.height.isFinite,
              min(targetSize.width, targetSize.height) >= 1,
              max(targetSize.width, targetSize.height) <= 2_400,
              targetSize.width * targetSize.height <= 5_000_000 else { return nil }
        let access = SecurityScopedAccess(url: source.url)
        return withExtendedLifetime(access) {
            autoreleasepool {
                guard !Task.isCancelled,
                      (try? PDFSourceFileVersion.capture(at: source.url)) == source.version,
                      let loaded = try? PDFSourceFileAccess.loadDocument(at: source.url),
                      loaded.version == source.version, !loaded.document.isLocked,
                      !loaded.document.isEncrypted,
                      let page = loaded.document.page(at: pageIndex),
                      page.rotation == rotation,
                      page.bounds(for: .cropBox) == pageBounds,
                      page.annotations.isEmpty else { return nil }
                let preview = page.thumbnail(of: targetSize, for: .cropBox)
                var proposed = CGRect(origin: .zero, size: preview.size)
                guard !Task.isCancelled,
                      let image = preview.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
                      (try? PDFSourceFileVersion.capture(at: source.url)) == source.version else { return nil }
                return PDFThumbnailRaster(image: image, size: preview.size)
            }
        }
    }
}
