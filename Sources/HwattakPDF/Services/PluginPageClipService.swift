// SPDX-License-Identifier: MPL-2.0

import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Host-owned raster export. Neither PDFKit objects nor filesystem authority
/// are exposed to a declarative plug-in. Coordinates are normalized from the
/// top-left corner of the displayed (cropped, rotated) page.
@MainActor
enum PluginPageClipService {
    static let maximumPixelCount = 6_000_000
    static let maximumPixelEdge = 4_096
    static let maximumPNGBytes = 24 * 1_024 * 1_024

    @MainActor final class Snapshot {
        let image: CGImage
        let pageIndex: Int
        let revision: UUID
        let sourceURL: URL?
        fileprivate weak var document: PDFDocument?

        fileprivate init(image: CGImage, pageIndex: Int, workspace: PDFWorkspaceState) {
            self.image = image
            self.pageIndex = pageIndex
            self.revision = workspace.revision
            self.sourceURL = workspace.documentURL
            self.document = workspace.document
        }

        var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
        var suggestedFilename: String { "EmberPDF-page-\(pageIndex + 1)-clip.png" }
    }

    enum ClipError: LocalizedError, Equatable {
        case unauthorized, unavailable, copyRestricted, stale, invalidGeometry, renderFailed, oversized, clipboardFailed, invalidDestination

        var errorDescription: String? {
            switch self {
            case .unauthorized: L10n.string("plugins.clip.error.authorization", defaultValue: "플러그인 권한이 변경되었습니다. 권한을 확인한 뒤 다시 열어주세요.")
            case .unavailable: L10n.string("plugins.clip.error.unavailable", defaultValue: "열려 있는 PDF 페이지가 필요합니다.")
            case .copyRestricted: L10n.string("plugins.clip.error.copy_restricted", defaultValue: "이 PDF는 이미지 복사를 허용하지 않습니다.")
            case .stale: L10n.string("plugins.clip.error.stale", defaultValue: "문서가 변경되었습니다. 페이지 클립을 다시 열어주세요.")
            case .invalidGeometry: L10n.string("plugins.clip.error.geometry", defaultValue: "페이지 안에서 복사할 영역을 선택해주세요.")
            case .renderFailed: L10n.string("plugins.clip.error.render", defaultValue: "페이지 이미지를 만들지 못했습니다.")
            case .oversized: L10n.string("plugins.clip.error.size", defaultValue: "이미지가 너무 큽니다. 더 작은 영역을 선택해주세요.")
            case .clipboardFailed: L10n.string("plugins.clip.error.clipboard", defaultValue: "이미지를 클립보드에 복사하지 못했습니다.")
            case .invalidDestination: L10n.string("plugins.clip.error.destination", defaultValue: "원본 PDF를 덮어쓰지 않는 PNG 파일을 선택해주세요.")
            }
        }
    }

    static func capture(workspace: PDFWorkspaceState, documentRevision: UUID,
                        isAuthorized: () -> Bool) throws -> Snapshot {
        guard isAuthorized() else { throw ClipError.unauthorized }
        guard workspace.revision == documentRevision else { throw ClipError.stale }
        let pageIndex = workspace.currentPageIndex
        guard let document = workspace.document, !document.isLocked,
              let page = document.page(at: pageIndex) else { throw ClipError.unavailable }
        guard document.allowsCopying || document.permissionsStatus == .owner else { throw ClipError.copyRestricted }
        let image = try render(page: page)
        guard isAuthorized(), workspace.revision == documentRevision,
              workspace.document === document, workspace.currentPageIndex == pageIndex else { throw ClipError.stale }
        return Snapshot(image: image, pageIndex: pageIndex, workspace: workspace)
    }

    static func validate(_ snapshot: Snapshot, workspace: PDFWorkspaceState,
                         isAuthorized: () -> Bool) throws {
        guard isAuthorized() else { throw ClipError.unauthorized }
        guard let document = workspace.document, document === snapshot.document,
              workspace.revision == snapshot.revision,
              workspace.documentURL == snapshot.sourceURL,
              !document.isLocked, document.page(at: snapshot.pageIndex) != nil else { throw ClipError.stale }
        guard document.allowsCopying || document.permissionsStatus == .owner else { throw ClipError.copyRestricted }
    }

    static func pngData(_ snapshot: Snapshot, normalizedRect: CGRect, workspace: PDFWorkspaceState,
                        isAuthorized: () -> Bool) throws -> Data {
        try validate(snapshot, workspace: workspace, isAuthorized: isAuthorized)
        let rect = try pixelRect(normalizedRect, pixelSize: snapshot.pixelSize)
        guard let clipped = snapshot.image.cropping(to: rect) else { throw ClipError.renderFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ClipError.renderFailed
        }
        CGImageDestinationAddImage(destination, clipped, nil)
        guard CGImageDestinationFinalize(destination) else { throw ClipError.renderFailed }
        guard data.length <= maximumPNGBytes else { throw ClipError.oversized }
        try validate(snapshot, workspace: workspace, isAuthorized: isAuthorized)
        return data as Data
    }

    /// Call only from an explicit copy button; injectable pasteboards keep tests
    /// and previews away from the user's general clipboard.
    static func copy(_ snapshot: Snapshot, normalizedRect: CGRect, workspace: PDFWorkspaceState,
                     isAuthorized: () -> Bool, pasteboard: NSPasteboard = .general) throws {
        let data = try pngData(snapshot, normalizedRect: normalizedRect, workspace: workspace, isAuthorized: isAuthorized)
        try validate(snapshot, workspace: workspace, isAuthorized: isAuthorized)
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else { throw ClipError.clipboardFailed }
    }

    /// The caller supplies a URL selected by NSSavePanel. Revalidate after the
    /// modal panel, because permission/document state may change while it is open.
    static func save(_ snapshot: Snapshot, normalizedRect: CGRect, to url: URL,
                     workspace: PDFWorkspaceState, isAuthorized: () -> Bool) throws {
        try validate(snapshot, workspace: workspace, isAuthorized: isAuthorized)
        guard url.isFileURL, url.pathExtension.lowercased() == "png",
              !PageTranslationExportPolicy.replacesSource(url, sourceURL: snapshot.sourceURL) else {
            throw ClipError.invalidDestination
        }
        let data = try pngData(snapshot, normalizedRect: normalizedRect, workspace: workspace, isAuthorized: isAuthorized)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Repeat the source/alias check at the actual write boundary.
        try validate(snapshot, workspace: workspace, isAuthorized: isAuthorized)
        guard !PageTranslationExportPolicy.replacesSource(url, sourceURL: snapshot.sourceURL) else {
            throw ClipError.invalidDestination
        }
        try data.write(to: url, options: .atomic)
    }

    /// Called by onDrag only. The provider owns bounded PNG bytes, never the
    /// original document, its path, a shell command, or arbitrary file access.
    static func dragProvider(_ snapshot: Snapshot, normalizedRect: CGRect, workspace: PDFWorkspaceState,
                             isAuthorized: @escaping () -> Bool) throws -> NSItemProvider {
        let data = try pngData(snapshot, normalizedRect: normalizedRect, workspace: workspace, isAuthorized: isAuthorized)
        let provider = NSItemProvider()
        provider.suggestedName = snapshot.suggestedFilename
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            // A receiver may request the promised data later. Revocation or a
            // changed source must also prevent this delayed transfer.
            Task { @MainActor in
                do {
                    try validate(snapshot, workspace: workspace, isAuthorized: isAuthorized)
                    completion(data, nil)
                } catch { completion(nil, error) }
            }
            return nil
        }
        return provider
    }

    static func pixelRect(_ normalizedRect: CGRect, pixelSize: CGSize) throws -> CGRect {
        guard [normalizedRect.origin.x, normalizedRect.origin.y, normalizedRect.size.width, normalizedRect.size.height,
               pixelSize.width, pixelSize.height].allSatisfy(\.isFinite),
              normalizedRect.size.width > 0, normalizedRect.size.height > 0,
              normalizedRect.origin.x >= 0, normalizedRect.origin.y >= 0,
              normalizedRect.maxX <= 1, normalizedRect.maxY <= 1,
              pixelSize.width > 0, pixelSize.height > 0,
              pixelSize.width <= CGFloat(maximumPixelEdge), pixelSize.height <= CGFloat(maximumPixelEdge),
              pixelSize.width * pixelSize.height <= CGFloat(maximumPixelCount) else { throw ClipError.invalidGeometry }
        let left = floor(normalizedRect.minX * pixelSize.width)
        let top = floor(normalizedRect.minY * pixelSize.height)
        let right = min(pixelSize.width, ceil(normalizedRect.maxX * pixelSize.width))
        let bottom = min(pixelSize.height, ceil(normalizedRect.maxY * pixelSize.height))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func targetSize(pageBounds: CGRect, rotation: Int) throws -> CGSize {
        guard [pageBounds.origin.x, pageBounds.origin.y, pageBounds.width, pageBounds.height].allSatisfy(\.isFinite),
              pageBounds.size.width > 0, pageBounds.size.height > 0,
              pageBounds.width <= 100_000, pageBounds.height <= 100_000,
              abs(pageBounds.origin.x) <= 1_000_000, abs(pageBounds.origin.y) <= 1_000_000,
              rotation % 90 == 0 else { throw ClipError.invalidGeometry }
        let quarterTurn = abs((rotation % 360) / 90) % 2 == 1
        let width = quarterTurn ? pageBounds.height : pageBounds.width
        let height = quarterTurn ? pageBounds.width : pageBounds.height
        let scale = min(2, CGFloat(maximumPixelEdge) / max(width, height),
                        sqrt(CGFloat(maximumPixelCount) / (width * height)))
        return CGSize(width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))
    }

    private static func render(page: PDFPage) throws -> CGImage {
        let bounds = page.bounds(for: .cropBox)
        let size = try targetSize(pageBounds: bounds, rotation: page.rotation)
        let rotation = CGAffineTransform(rotationAngle: -CGFloat(page.rotation % 360) * .pi / 180)
        let rotated = bounds.applying(rotation)
        guard rotated.width.isFinite, rotated.height.isFinite, rotated.width > 0, rotated.height > 0,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ClipError.renderFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: size.width / rotated.width, y: size.height / rotated.height)
        context.translateBy(x: -rotated.minX, y: -rotated.minY)
        context.concatenate(rotation)
        context.concatenate(page.transform(for: .cropBox).inverted())
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw ClipError.renderFailed }
        return image
    }
}
