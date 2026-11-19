// SPDX-License-Identifier: MPL-2.0

import AppKit
import Dispatch
import ObjectiveC
import PDFKit
import SwiftUI

private struct PDFViewportResizingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Live layout may stretch a cached preview, but must not rasterize every
    /// intermediate divider/zoom position. The final size renders on release.
    var isPDFViewportResizing: Bool {
        get { self[PDFViewportResizingKey.self] }
        set { self[PDFViewportResizingKey.self] = newValue }
    }
}

struct PageThumbnailImageRequest: Equatable {
    let targetSize: CGSize
    let rotation: Int
    let revision: UUID
    let pageIndex: Int
    let efficientRenderingEnabled: Bool

    init(pageBounds: CGRect, rotation: Int, pageIndex: Int, width: CGFloat,
         displayScale: CGFloat, revision: UUID, efficientRenderingEnabled: Bool) {
        self.rotation = rotation
        self.revision = revision
        self.pageIndex = pageIndex
        self.efficientRenderingEnabled = efficientRenderingEnabled
        targetSize = PDFThumbnailRenderingPolicy(efficientRenderingEnabled: efficientRenderingEnabled)
            .targetSize(pageBounds: pageBounds, rotation: rotation,
                        requestedWidth: width, displayScale: displayScale)
    }

    var cacheKey: NSString {
        "\(revision.uuidString)-\(pageIndex)-\(Int(targetSize.width))-\(Int(targetSize.height))-\(rotation)-\(efficientRenderingEnabled)" as NSString
    }
}

/// 렌더링된 페이지 썸네일을 재사용하는 메모리 cache다.
///
/// PDFKit thumbnail 생성은 비싸므로 같은 revision·page·pixel size·rotation 조합을
/// 다시 그리지 않는다. `NSCache`는 메모리 압력 때 항목을 자동 방출하며, count와
/// pixel cost 상한이 많은 페이지를 연 문서의 RSS를 제한한다.
@MainActor
final class PageImageCache {
    static let shared = PageImageCache()

    private struct Geometry: Equatable {
        let boxes: [CGRect]
        let rotation: Int

        init?(page: PDFPage) {
            let boxes = [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox].map {
                page.bounds(for: $0)
            }
            guard boxes.allSatisfy({
                [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite)
                    && $0.width > 0 && $0.height > 0
            }) else { return nil }
            self.boxes = boxes
            rotation = page.rotation
        }
    }

    /// The page owns this witness. The cache only refers to it weakly, so a
    /// thumbnail cannot keep a closed document's native resource graph alive.
    private final class PaintingWitness {
        let id = UUID()
        let native: CGPDFPage
        let geometry: Geometry

        init(native: CGPDFPage, geometry: Geometry) {
            self.native = native
            self.geometry = geometry
        }
    }

    private final class Entry {
        final class AnnotationReference {
            weak var value: PDFAnnotation?
            init(_ value: PDFAnnotation) { self.value = value }
        }

        let image: NSImage
        weak var page: PDFPage?
        weak var document: PDFDocument?
        let hadDocument: Bool
        weak var witness: PaintingWitness?
        let usesPaintingWitness: Bool
        let geometry: Geometry?
        let request: PageThumbnailImageRequest
        let annotations: [AnnotationReference]

        init(image: NSImage, page: PDFPage, request: PageThumbnailImageRequest,
             witness: PaintingWitness?) {
            self.image = image
            self.page = page
            document = page.document
            hadDocument = page.document != nil
            self.witness = witness
            usesPaintingWitness = witness != nil
            geometry = Geometry(page: page)
            self.request = request
            annotations = page.annotations.map(AnnotationReference.init)
        }
    }

    private final class IndexedEntry {
        let key: NSString
        weak var value: Entry?
        init(key: NSString, value: Entry) { self.key = key; self.value = value }
    }

    private static let paintingKey = NSObject()
    private static var paintingAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(paintingKey).toOpaque())
    }

    private static let generationKey = NSObject()
    private static var generationAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(generationKey).toOpaque())
    }

    private let cache = NSCache<NSString, Entry>()
    // NSCache has no key enumeration. This count-bounded weak index permits
    // targeted removal without retaining entries, images or PDF documents.
    private var indexedEntries: [IndexedEntry] = []
    // Aliases carry no image or native page. Multiple revisions of an
    // unchanged painting still consume just one image-cache cost/count slot.
    private let aliases = NSCache<NSString, NSString>()
    private let fileRenderer: any PDFThumbnailFileRendering
    private var pressureSource: DispatchSourceMemoryPressure?
    private var activePolicy: PDFThumbnailRenderingPolicy?

    init(fileRenderer: any PDFThumbnailFileRendering = PDFThumbnailFileRenderer()) {
        self.fileRenderer = fileRenderer
        configure(
            policy: PDFThumbnailRenderingPolicy(
                efficientRenderingEnabled: AppPerformanceSettings.isEfficientRenderingEnabled
            )
        )
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // Thumbnail pixels are entirely recreatable. Releasing them before
            // PDF documents gives the active reading surface more headroom.
            self?.removeAllImages()
        }
        pressureSource = source
        source.resume()
    }

    /// A workspace identity change retires only that document's pixels. Other
    /// live documents keep their previews; in-flight work for this generation
    /// cannot publish a replacement entry after this removal.
    func removeImages(for document: PDFDocument) {
        objc_setAssociatedObject(document, Self.generationAssociation, NSObject(), .OBJC_ASSOCIATION_RETAIN)
        pruneEntries(removing: document)
    }

    private func generation(for document: PDFDocument?) -> NSObject? {
        guard let document else { return nil }
        if let value = objc_getAssociatedObject(document, Self.generationAssociation) as? NSObject { return value }
        let value = NSObject()
        objc_setAssociatedObject(document, Self.generationAssociation, value, .OBJC_ASSOCIATION_RETAIN)
        return value
    }

    private func pruneEntries(removing document: PDFDocument? = nil) {
        indexedEntries.removeAll { slot in
            guard let entry = slot.value else { return true }
            if entry.page == nil || (entry.hadDocument && entry.document == nil)
                || (document != nil && entry.document === document) {
                cache.removeObject(forKey: slot.key)
                return true
            }
            return false
        }
    }

    private func removeAllImages() {
        cache.removeAllObjects()
        aliases.removeAllObjects()
        indexedEntries.removeAll()
    }

    /// revision이 바뀌면 key도 바뀌므로 회전·편집 뒤 오래된 이미지가 보이지 않는다.
    func image(
        for page: PDFPage,
        pageIndex: Int,
        width: CGFloat,
        displayScale: CGFloat,
        revision: UUID,
        efficientRenderingEnabled: Bool
    ) -> NSImage {
        let request = PageThumbnailImageRequest(
            pageBounds: page.bounds(for: .cropBox),
            rotation: page.rotation,
            pageIndex: pageIndex, width: width, displayScale: displayScale,
            revision: revision, efficientRenderingEnabled: efficientRenderingEnabled
        )
        return image(for: page, request: request)
    }

    func cachedImage(for request: PageThumbnailImageRequest) -> NSImage? {
        configure(policy: PDFThumbnailRenderingPolicy(
            efficientRenderingEnabled: request.efficientRenderingEnabled
        ))
        guard let key = aliases.object(forKey: request.cacheKey),
              let entry = cache.object(forKey: key), matches(entry, request: request) else { return nil }
        return entry.image
    }

    private func paintingWitness(for page: PDFPage) -> PaintingWitness? {
        // An annotation's complete painted state is not represented by a few
        // scalar properties. Keep its existing revision-scoped route instead
        // of guessing an appearance fingerprint, including custom PDF pages.
        guard type(of: page) == PDFPage.self, let document = page.document,
              !document.isLocked, !document.isEncrypted, page.annotations.isEmpty,
              let native = page.pageRef, let dictionary = native.dictionary,
              let geometry = Geometry(page: page) else {
            objc_setAssociatedObject(page, Self.paintingAssociation, nil, .OBJC_ASSOCIATION_RETAIN)
            return nil
        }
        if let previous = objc_getAssociatedObject(page, Self.paintingAssociation) as? PaintingWitness,
           previous.native.dictionary == dictionary, previous.geometry == geometry { return previous }
        let witness = PaintingWitness(native: native, geometry: geometry)
        objc_setAssociatedObject(page, Self.paintingAssociation, witness, .OBJC_ASSOCIATION_RETAIN)
        return witness
    }

    private func matches(_ entry: Entry, request: PageThumbnailImageRequest) -> Bool {
        guard let page = entry.page, page.document === entry.document,
              entry.geometry == Geometry(page: page),
              entry.request.targetSize == request.targetSize,
              entry.request.rotation == request.rotation,
              entry.request.efficientRenderingEnabled == request.efficientRenderingEnabled else { return false }
        let annotations = page.annotations
        guard entry.annotations.count == annotations.count,
              zip(entry.annotations, annotations).allSatisfy({ $0.0.value === $0.1 }) else { return false }
        if entry.usesPaintingWitness {
            guard let witness = entry.witness else { return false }
            return paintingWitness(for: page) === witness
        }
        return entry.request == request
    }

    private func canonicalKey(for page: PDFPage, request: PageThumbnailImageRequest,
                              witness: PaintingWitness?) -> NSString {
        guard let witness else { return "\(request.cacheKey)-\(ObjectIdentifier(page))" as NSString }
        let width = Double(request.targetSize.width).bitPattern
        let height = Double(request.targetSize.height).bitPattern
        return "painting-\(witness.id)-\(width)-\(height)-\(request.efficientRenderingEnabled)" as NSString
    }

    private func cachedImage(for page: PDFPage, request: PageThumbnailImageRequest) -> NSImage? {
        if let key = aliases.object(forKey: request.cacheKey), let entry = cache.object(forKey: key),
           entry.page === page, matches(entry, request: request) { return entry.image }
        let key = canonicalKey(for: page, request: request, witness: paintingWitness(for: page))
        guard let entry = cache.object(forKey: key), entry.page === page,
              matches(entry, request: request) else { return nil }
        aliases.setObject(key, forKey: request.cacheKey)
        return entry.image
    }

    /// Unchanged, annotation-free file pages use a separate background-owned
    /// PDFKit document. Live edits keep the owning actor's current page. During
    /// live resizing only an existing raster is returned.
    func loadImage(for page: PDFPage, request: PageThumbnailImageRequest,
                   isResizing: Bool, fileSource: PDFThumbnailFileSource? = nil) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        configure(policy: PDFThumbnailRenderingPolicy(efficientRenderingEnabled: request.efficientRenderingEnabled))
        if let cached = cachedImage(for: page, request: request) { return cached }
        guard !isResizing else { return nil }
        let document = page.document
        let capturedGeneration = generation(for: document)
        // Visible controls paint first; quickly scrolled-away cells cancel
        // before the expensive synchronous PDFKit call begins.
        do { try await Task.sleep(nanoseconds: 35_000_000) } catch { return nil }
        guard !Task.isCancelled, page.rotation == request.rotation,
              page.document === document, generation(for: document) === capturedGeneration else { return nil }
        if let fileSource, let document,
           !document.isLocked, !document.isEncrypted,
           document.index(for: page) == request.pageIndex, page.annotations.isEmpty {
            let bounds = page.bounds(for: .cropBox)
            let raster = await fileRenderer.render(
                source: fileSource, pageIndex: request.pageIndex,
                pageBounds: bounds, rotation: request.rotation,
                targetSize: request.targetSize
            )
            guard !Task.isCancelled, page.document === document,
                  generation(for: document) === capturedGeneration,
                  document.index(for: page) == request.pageIndex,
                  page.rotation == request.rotation, page.bounds(for: .cropBox) == bounds,
                  page.annotations.isEmpty else { return nil }
            if let raster {
                let image = NSImage(cgImage: raster.image, size: raster.size)
                cacheImage(image, page: page, request: request)
                return image
            }
        }
        guard !Task.isCancelled else { return nil }
        return image(for: page, request: request)
    }

    private func image(for page: PDFPage, request: PageThumbnailImageRequest) -> NSImage {
        configure(policy: PDFThumbnailRenderingPolicy(efficientRenderingEnabled: request.efficientRenderingEnabled))
        if let cached = cachedImage(for: page, request: request) { return cached }
        let image = page.thumbnail(of: request.targetSize, for: .cropBox)
        cacheImage(image, page: page, request: request)
        return image
    }

    private func cacheImage(_ image: NSImage, page: PDFPage, request: PageThumbnailImageRequest) {
        let policy = PDFThumbnailRenderingPolicy(
            efficientRenderingEnabled: request.efficientRenderingEnabled
        )
        // This image already owns a raster at the display's backing resolution.
        // Avoid additional NSImage draw caches at each intermediate resize size.
        image.cacheMode = .never
        let pixelCost = policy.estimatedBitmapCost(for: request.targetSize)
        let witness = paintingWitness(for: page)
        let key = canonicalKey(for: page, request: request, witness: witness)
        pruneEntries()
        indexedEntries.removeAll { $0.key == key }
        // Keep index metadata finite even if NSCache delays its advisory count
        // eviction. Removing a recreatable raster never affects another page.
        while indexedEntries.count >= policy.cacheCountLimit {
            cache.removeObject(forKey: indexedEntries.removeFirst().key)
        }
        let entry = Entry(image: image, page: page, request: request, witness: witness)
        cache.setObject(entry, forKey: key, cost: pixelCost)
        indexedEntries.append(IndexedEntry(key: key, value: entry))
        aliases.setObject(key, forKey: request.cacheKey)
    }

    private func configure(policy: PDFThumbnailRenderingPolicy) {
        guard activePolicy != policy else { return }
        activePolicy = policy
        cache.countLimit = policy.cacheCountLimit
        cache.totalCostLimit = policy.cacheCostLimit
        aliases.countLimit = policy.cacheCountLimit * 2
        // Switching quality modes must not retain both raster populations.
        removeAllImages()
    }
}

/// PDFPage를 사이드바/개요에서 사용할 그림과 사람용 1-based 번호로 표시한다.
struct PageThumbnailView: View {
    let page: PDFPage
    let pageIndex: Int
    let width: CGFloat
    let revision: UUID
    var showPageNumber = true
    var fileSource: PDFThumbnailFileSource? = nil
    @State private var renderedImage: NSImage?
    @State private var renderedContentID: String?

    private var contentID: String {
        "\(revision)-\(pageIndex)-\(page.rotation)-\(efficientRenderingEnabled)"
    }

    private var requestID: String {
        // Subpixel layout changes that resolve to the same raster do not need
        // another task. Include resizing so release requests the final image.
        "\(imageRequest.cacheKey)-\(isPDFViewportResizing)"
    }

    private var imageRequest: PageThumbnailImageRequest {
        PageThumbnailImageRequest(
            pageBounds: page.bounds(for: .cropBox), rotation: page.rotation,
            pageIndex: pageIndex, width: width, displayScale: displayScale,
            revision: revision, efficientRenderingEnabled: efficientRenderingEnabled
        )
    }

    private var pageAspectRatio: CGFloat {
        let size = page.bounds(for: .cropBox).size
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return 1 }
        let aspect = abs(page.rotation % 180) == 90
            ? size.height / size.width : size.width / size.height
        return aspect.isFinite && aspect > 0 ? aspect : 1
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.isPDFViewportResizing) private var isPDFViewportResizing
    @EmberTheme private var theme
    @AppStorage(AppPerformanceSettings.efficientRenderingEnabledKey)
    private var efficientRenderingEnabled = AppPerformanceSettings.defaultEfficientRenderingEnabled

    var body: some View {
        VStack(spacing: 9) {
            Group {
                // Keep the last raster visible while a resize requests a new
                // resolution. A changed page/revision still clears stale content.
                if renderedContentID == contentID, let renderedImage {
                    Image(nsImage: renderedImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(pageAspectRatio, contentMode: .fit)
                } else {
                    Rectangle().fill(Color.white).aspectRatio(pageAspectRatio, contentMode: .fit)
                }
            }
                .background(Color.white)
                .pdfReadingAppearance()
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.black.opacity(colorScheme == .dark ? 0.24 : 0.08), lineWidth: 0.75)
                }
                .shadow(color: theme.elevatedShadow, radius: 3, y: 1)
                .accessibilityLabel(L10n.format("page.number", pageIndex + 1))

            if showPageNumber {
                Text("\(pageIndex + 1)")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .task(id: requestID) { @MainActor in
            guard let image = await PageImageCache.shared.loadImage(
                for: page, request: imageRequest, isResizing: isPDFViewportResizing,
                fileSource: fileSource
            ), !Task.isCancelled else { return }
            renderedImage = image
            renderedContentID = contentID
        }
        .onDisappear {
            renderedImage = nil
            renderedContentID = nil
        }
    }
}
