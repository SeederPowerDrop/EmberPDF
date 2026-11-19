// SPDX-License-Identifier: MPL-2.0

import AppKit
import Dispatch
import PDFKit

/// Serial, cancellable page previews that never activate or resume a tab.
/// Resident PDFs render on their owner actor so unsaved edits remain visible;
/// lazy PDFs use a temporary background-owned document released after one page.
@MainActor
final class PDFDocumentGalleryPreviewService {
    static let shared = PDFDocumentGalleryPreviewService()

    private struct FileSignature: Hashable {
        let url: URL
        let size: UInt64
        let date: Date
        let device: UInt64?
        let inode: UInt64?

        init(_ version: PDFSourceFileVersion) {
            url = version.canonicalURL
            size = version.fileSize
            date = version.contentModificationDate
            device = version.fileSystemNumber
            inode = version.fileSystemNodeNumber
        }
    }

    private struct Key: Hashable {
        let workspace: ObjectIdentifier
        let revision: UUID
        let pageIndex: Int
        let highlightRange: NSRange?
        let highlightedText: String?
        let width: Int
        let residentDocument: ObjectIdentifier?
        let file: FileSignature?
    }

    private struct Entry {
        let preview: PDFDocumentGalleryPreview
        let cost: Int
        var sequence: UInt64
    }

    private let maximumCachedPreviews: Int
    private let maximumCacheBytes: Int
    private let debounceNanoseconds: UInt64
    private let reader = PDFDocumentGalleryTransientRenderer()
    private let gate = PDFDocumentGalleryRenderGate()
    private var cache: [Key: Entry] = [:]
    private var sequence: UInt64 = 0
    private var pressureSource: DispatchSourceMemoryPressure?
    private(set) var cachedByteCount = 0
    private(set) var renderCount = 0
    var cachedPreviewCount: Int { cache.count }

    init(maximumCachedPreviews: Int = PDFDocumentGalleryRenderingPolicy.maximumCachedPreviews,
         maximumCacheBytes: Int = PDFDocumentGalleryRenderingPolicy.maximumCacheBytes,
         debounceNanoseconds: UInt64 = 35_000_000) {
        self.maximumCachedPreviews = min(PDFDocumentGalleryRenderingPolicy.maximumCachedPreviews,
                                         max(1, maximumCachedPreviews))
        self.maximumCacheBytes = min(PDFDocumentGalleryRenderingPolicy.maximumCacheBytes,
                                    max(1, maximumCacheBytes))
        self.debounceNanoseconds = debounceNanoseconds
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.removeAllCachedPreviews() }
        pressureSource = source
        source.resume()
    }

    deinit { pressureSource?.cancel() }

    func preview(for workspace: PDFWorkspaceState, pageIndex requestedPageIndex: Int? = nil,
                 highlight: PDFSearchResult? = nil, width: CGFloat = 480) async -> PDFDocumentGalleryPreview? {
        let revision = workspace.revision
        let pageIndex = requestedPageIndex ?? workspace.currentPageIndex
        let pageHighlight = highlight.flatMap { $0.pageIndex == pageIndex ? $0 : nil }
        let url = workspace.documentURL
        do { try await Task.sleep(nanoseconds: debounceNanoseconds) } catch { return nil }
        guard !Task.isCancelled else { return nil }
        let ticket = UUID()
        guard await gate.acquire(ticket) else { return nil }
        defer { gate.release(ticket) }
        guard !Task.isCancelled, workspace.revision == revision,
              (requestedPageIndex != nil || workspace.currentPageIndex == pageIndex), workspace.documentURL == url,
              pageIndex >= 0, workspace.hasOpenDocument else { return nil }

        // This scope also covers metadata checks and the temporary reader's
        // access. A failed preview is local UI state, never a workspace error.
        let access = url.map(SecurityScopedAccess.init(url:))
        defer { withExtendedLifetime(access) {} }
        let residentID = workspace.document.map(ObjectIdentifier.init)
        let signature: FileSignature?
        if residentID == nil {
            guard let url, url.isFileURL,
                  let version = try? PDFSourceFileVersion.capture(at: url) else { return nil }
            signature = FileSignature(version)
        } else {
            signature = nil
        }
        let key = Key(workspace: ObjectIdentifier(workspace), revision: revision,
                      pageIndex: pageIndex, highlightRange: pageHighlight?.sourceRange, highlightedText: pageHighlight?.matchedText,
                      width: PDFDocumentGalleryRenderingPolicy.widthBucket(width),
                      residentDocument: residentID, file: signature)
        if var cached = cache[key] {
            sequence &+= 1
            cached.sequence = sequence
            cache[key] = cached
            return cached.preview
        }

        let raster: PDFDocumentGalleryRaster?
        renderCount += 1
        if let document = workspace.document {
            raster = autoreleasepool {
                guard !document.isLocked, let page = document.page(at: pageIndex) else { return nil }
                return PDFDocumentGalleryRaster.render(page: page, pageCount: document.pageCount,
                                                       width: CGFloat(key.width), highlightRange: key.highlightRange, highlightedText: key.highlightedText)
            }
        } else if let url {
            raster = await reader.render(url: url, pageIndex: pageIndex, width: CGFloat(key.width), highlightRange: key.highlightRange, highlightedText: key.highlightedText)
        } else { raster = nil }

        guard !Task.isCancelled, workspace.revision == revision,
              (requestedPageIndex != nil || workspace.currentPageIndex == pageIndex), workspace.documentURL == url,
              workspace.document.map(ObjectIdentifier.init) == residentID else { return nil }
        if let signature {
            guard let url, let after = try? PDFSourceFileVersion.capture(at: url),
                  signature == FileSignature(after) else { return nil }
        }
        guard let raster else { return nil }
        let image = NSImage(cgImage: raster.image, size: raster.size)
        image.cacheMode = .never
        let preview = PDFDocumentGalleryPreview(image: image, pageIndex: pageIndex,
                                                pageCount: raster.pageCount, revision: revision,
                                                pixelSize: raster.size)
        insert(preview, for: key, cost: raster.cost)
        return preview
    }

    func removeAllCachedPreviews() {
        cache.removeAll(keepingCapacity: false)
        cachedByteCount = 0
    }

    private func insert(_ preview: PDFDocumentGalleryPreview, for key: Key, cost: Int) {
        // Discard old versions of a tab instead of retaining every visited page.
        for old in cache.keys.filter({ $0.workspace == key.workspace && $0 != key }) {
            cachedByteCount -= cache.removeValue(forKey: old)?.cost ?? 0
        }
        guard cost <= maximumCacheBytes else { return }
        while !cache.isEmpty && (cache.count >= maximumCachedPreviews || cachedByteCount + cost > maximumCacheBytes) {
            guard let oldest = cache.min(by: { $0.value.sequence < $1.value.sequence })?.key else { break }
            cachedByteCount -= cache.removeValue(forKey: oldest)?.cost ?? 0
        }
        sequence &+= 1
        cache[key] = Entry(preview: preview, cost: cost, sequence: sequence)
        cachedByteCount += cost
    }
}

/// There is one in-flight raster across resident and transient paths. Queued
/// offscreen cells cancel without constructing a PDFDocument. PDFKit's single
/// synchronous draw cannot be interrupted, so cancellation is checked on both
/// sides and its result is discarded.
@MainActor
private final class PDFDocumentGalleryRenderGate {
    private var active: UUID?
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []

    func acquire(_ id: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                if active == nil {
                    active = id
                    continuation.resume(returning: true)
                } else { waiters.append((id, continuation)) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    func release(_ id: UUID) {
        guard active == id else { return }
        active = nil
        if !waiters.isEmpty {
            let (next, continuation) = waiters.removeFirst()
            active = next
            continuation.resume(returning: true)
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(returning: false)
    }
}

private actor PDFDocumentGalleryTransientRenderer {
    func render(url: URL, pageIndex: Int, width: CGFloat,
                highlightRange: NSRange?, highlightedText: String?) -> PDFDocumentGalleryRaster? {
        guard !Task.isCancelled, url.isFileURL else { return nil }
        let access = SecurityScopedAccess(url: url)
        return withExtendedLifetime(access) {
            autoreleasepool {
                guard !Task.isCancelled,
                      let loaded = try? PDFSourceFileAccess.loadDocument(at: url),
                      !loaded.document.isLocked,
                      let page = loaded.document.page(at: pageIndex) else { return nil }
                let raster = PDFDocumentGalleryRaster.render(page: page, pageCount: loaded.document.pageCount,
                                                             width: width, highlightRange: highlightRange, highlightedText: highlightedText)
                guard !Task.isCancelled,
                      (try? PDFSourceFileVersion.capture(at: url)) == loaded.version else { return nil }
                return raster
            }
        }
    }
}

/// A completed CGContext snapshot is immutable; only its bounded pixels cross
/// actors. PDFDocument, PDFPage, and the drawing context stay with their owner.
private struct PDFDocumentGalleryRaster: @unchecked Sendable {
    let image: CGImage
    let size: CGSize
    let pageCount: Int
    var cost: Int { image.bytesPerRow * image.height }

    static func render(page: PDFPage, pageCount: Int, width: CGFloat,
                       highlightRange: NSRange? = nil, highlightedText: String? = nil) -> Self? {
        let bounds = page.bounds(for: .cropBox)
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0 else { return nil }
        let size = PDFDocumentGalleryRenderingPolicy.targetSize(pageBounds: bounds, rotation: page.rotation, width: width)
        let rotation = CGAffineTransform(rotationAngle: -CGFloat(page.rotation % 360) * .pi / 180)
        let rotated = bounds.applying(rotation)
        guard rotated.width.isFinite, rotated.height.isFinite,
              rotated.width > 0, rotated.height > 0 else { return nil }
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: size.width / rotated.width, y: size.height / rotated.height)
        context.translateBy(x: -rotated.minX, y: -rotated.minY)
        context.concatenate(rotation)
        context.concatenate(page.transform(for: .cropBox).inverted())
        page.draw(with: .cropBox, to: context)
        // Compose a search marker into this bounded preview only. Never add a
        // PDF annotation or change the reader's native selection/current page.
        if let range = highlightRange, let text = highlightedText,
           let document = page.document,
           (document.allowsCopying || document.permissionsStatus == .owner),
           range.location >= 0, range.length > 0,
           range.location <= page.numberOfCharacters,
           range.length <= page.numberOfCharacters - range.location,
           let pageText = page.string as NSString?, range.location <= pageText.length,
           range.length <= pageText.length - range.location,
           pageText.substring(with: range) == text,
           let selection = page.selection(for: range) {
            context.saveGState()
            context.concatenate(page.transform(for: .cropBox))
            context.setBlendMode(.multiply)
            context.setFillColor(NSColor(srgbRed: 1, green: 0.71, blue: 0.23, alpha: 0.50).cgColor)
            for line in selection.selectionsByLine() {
                let rect = line.bounds(for: page).intersection(bounds)
                guard !rect.isNull, [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
                      rect.width > 0, rect.height > 0 else { continue }
                context.fill(rect.insetBy(dx: -1, dy: -1))
            }
            context.restoreGState()
        }
        guard !Task.isCancelled, let cgImage = context.makeImage() else { return nil }
        return Self(image: cgImage, size: size, pageCount: pageCount)
    }
}
