// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreImage
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFReadingDisplayTests: XCTestCase {
    func testCoreImageOutputUsesSelectedPaperWithoutInvertingInkOrColoredFigures() throws {
        for theme in PDFReadingTheme.allCases where theme != .original {
            let filter = try XCTUnwrap(PDFReadingDisplayEffect.makeFilter(for: theme))
            let paper = try pixel(red: 1, green: 1, blue: 1, filter: filter)
            let expected = theme.paperRGB
            XCTAssertEqual(paper[0], expected.red, accuracy: 2 / 255.0, theme.rawValue)
            XCTAssertEqual(paper[1], expected.green, accuracy: 2 / 255.0, theme.rawValue)
            XCTAssertEqual(paper[2], expected.blue, accuracy: 2 / 255.0, theme.rawValue)
            let ink = try pixel(red: 0, green: 0, blue: 0, filter: filter)
            XCTAssertEqual(ink[0], 0)
            XCTAssertEqual(ink[1], 0)
            XCTAssertEqual(ink[2], 0)
            let redFigure = try pixel(red: 1, green: 0, blue: 0, filter: filter)
            XCTAssertEqual(redFigure[0], expected.red, accuracy: 2 / 255.0)
            XCTAssertEqual(redFigure[1], 0)
            XCTAssertEqual(redFigure[2], 0)
            XCTAssertEqual(redFigure[3], 1)
        }
        XCTAssertNil(PDFReadingDisplayEffect.makeFilter(for: .original))
    }

    func testFilteredClipCanvasCompensationKeepsTheOuterCanvasColor() throws {
        let canvas = NSColor(srgbRed: 0.24, green: 0.20, blue: 0.18, alpha: 1)
        for theme in PDFReadingTheme.allCases where theme != .original {
            let compensated = try XCTUnwrap(PDFReadingDisplayEffect.nativeCanvasColor(canvas, theme: theme)
                .usingColorSpace(.sRGB))
            let filter = try XCTUnwrap(PDFReadingDisplayEffect.makeFilter(for: theme))
            let output = try pixel(red: compensated.redComponent, green: compensated.greenComponent,
                                   blue: compensated.blueComponent, filter: filter)
            XCTAssertEqual(output[0], 0.24, accuracy: 2 / 255.0, theme.rawValue)
            XCTAssertEqual(output[1], 0.20, accuracy: 2 / 255.0, theme.rawValue)
            XCTAssertEqual(output[2], 0.18, accuracy: 2 / 255.0, theme.rawValue)
        }
    }

    @MainActor
    func testPDFViewportFiltersOnlyTheBoundedUnscaledScrollViewAndRestoresItsCanvas() throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 420, height: 560))
        view.backgroundColor = NSColor(srgbRed: 0.24, green: 0.20, blue: 0.18, alpha: 1)
        view.document = try XCTUnwrap(PDFDocument(url: source))
        let canvas = view.backgroundColor
        let documentView = try XCTUnwrap(view.documentView)
        let scroll = try XCTUnwrap(documentView.enclosingScrollView)
        let clip = scroll.contentView
        let overlay = NSView(frame: view.bounds)
        view.addSubview(overlay, positioned: .above, relativeTo: nil)
        let controller = PDFReadingDisplayFilterController()
        controller.apply(.soft, to: view, canvasColor: canvas)
        let filter = try XCTUnwrap(scroll.contentFilters.first)

        XCTAssertEqual(scroll.contentFilters.count, 1)
        XCTAssertTrue(clip.contentFilters.isEmpty)
        XCTAssertTrue(view.contentFilters.isEmpty)
        XCTAssertTrue(documentView.contentFilters.isEmpty)
        XCTAssertTrue(overlay.contentFilters.isEmpty)
        XCTAssertFalse(overlay.isDescendant(of: scroll), "Transient selection/editing UI must be outside the filtered subtree.")
        XCTAssertTrue(scroll.isDescendant(of: view))
        XCTAssertLessThanOrEqual(scroll.frame.height, view.bounds.height)
        XCTAssertLessThanOrEqual(scroll.frame.width, view.bounds.width)
        XCTAssertEqual(clip.backgroundColor, PDFReadingDisplayEffect.nativeCanvasColor(canvas, theme: .soft))
        for _ in 0..<100 {
            controller.apply(.soft, to: view, canvasColor: canvas)
            controller.refreshTarget()
        }
        XCTAssertTrue(scroll.contentFilters.first === filter)
        XCTAssertEqual(scroll.contentFilters.count, 1)
        XCTAssertEqual(clip.backgroundColor, PDFReadingDisplayEffect.nativeCanvasColor(canvas, theme: .soft),
                       "Repeated layout must not inverse-correct an already corrected color.")

        controller.detach()
        XCTAssertTrue(scroll.contentFilters.isEmpty)
        XCTAssertTrue(clip.contentFilters.isEmpty)
        XCTAssertEqual(clip.backgroundColor, canvas)
        XCTAssertEqual(view.backgroundColor, canvas)
    }

    @MainActor
    func testRebindingPDFViewportRestoresThePriorClipWithoutFilteringOverlays() throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let first = PDFView(frame: CGRect(x: 0, y: 0, width: 420, height: 560))
        let second = PDFView(frame: first.frame)
        first.backgroundColor = .darkGray
        second.backgroundColor = .gray
        first.document = try XCTUnwrap(PDFDocument(url: source))
        second.document = try XCTUnwrap(PDFDocument(url: source))
        let firstScroll = try XCTUnwrap(first.documentView?.enclosingScrollView)
        let secondScroll = try XCTUnwrap(second.documentView?.enclosingScrollView)
        let firstClip = firstScroll.contentView
        let secondClip = secondScroll.contentView
        let controller = PDFReadingDisplayFilterController()
        controller.apply(.night, to: first)
        controller.apply(.soft, to: second)
        XCTAssertTrue(first.contentFilters.isEmpty)
        XCTAssertTrue(second.contentFilters.isEmpty)
        XCTAssertTrue(firstClip.contentFilters.isEmpty)
        XCTAssertTrue(firstScroll.contentFilters.isEmpty)
        XCTAssertEqual(firstClip.backgroundColor, first.backgroundColor)
        XCTAssertEqual(secondScroll.contentFilters.count, 1)
        XCTAssertTrue(secondClip.contentFilters.isEmpty)
        controller.apply(.original, to: second)
        XCTAssertTrue(secondScroll.contentFilters.isEmpty)
        XCTAssertTrue(secondClip.contentFilters.isEmpty)
        XCTAssertEqual(secondClip.backgroundColor, second.backgroundColor)
        controller.detach()
    }

    @MainActor
    func testCanvasChangesUseTheSavedUnfilteredColorAcrossThemesAndNativeWrites() throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 420, height: 560))
        view.document = try XCTUnwrap(PDFDocument(url: source))
        let clip = try XCTUnwrap(view.documentView?.enclosingScrollView?.contentView)
        let canvas = NSColor(srgbRed: 0.24, green: 0.20, blue: 0.18, alpha: 1)
        let controller = PDFReadingDisplayFilterController()
        for theme in [.soft, .night, .sepia, .original, .soft] as [PDFReadingTheme] {
            controller.apply(theme, to: view, canvasColor: canvas)
            for _ in 0..<20 { controller.refreshTarget() }
            XCTAssertEqual(clip.backgroundColor, PDFReadingDisplayEffect.nativeCanvasColor(canvas, theme: theme))
        }

        let changed = NSColor(srgbRed: 0.12, green: 0.19, blue: 0.23, alpha: 1)
        view.backgroundColor = changed
        for _ in 0..<20 { controller.refreshTarget() }
        XCTAssertEqual(clip.backgroundColor, PDFReadingDisplayEffect.nativeCanvasColor(changed, theme: .soft))
        controller.apply(.night, to: view)
        XCTAssertEqual(clip.backgroundColor, PDFReadingDisplayEffect.nativeCanvasColor(changed, theme: .night))
        controller.detach()
        XCTAssertEqual(clip.backgroundColor, changed)

        controller.apply(.soft, to: view, canvasColor: canvas)
        view.backgroundColor = .blue
        controller.apply(.soft, to: view, canvasColor: canvas)
        XCTAssertEqual(clip.backgroundColor, PDFReadingDisplayEffect.nativeCanvasColor(canvas, theme: .soft),
                       "Explicit application canvas configuration must win over a native background write.")
        controller.detach()
        XCTAssertEqual(clip.backgroundColor, canvas)
    }

    @MainActor
    func testReplacementClipRetainsTheRequestedCanvasInsteadOfAdoptingItsDefault() throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 420, height: 560))
        view.document = try XCTUnwrap(PDFDocument(url: source))
        let documentView = try XCTUnwrap(view.documentView)
        let scroll = try XCTUnwrap(documentView.enclosingScrollView)
        let originalClip = scroll.contentView
        let canvas = NSColor(srgbRed: 0.24, green: 0.20, blue: 0.18, alpha: 1)
        let controller = PDFReadingDisplayFilterController()
        controller.apply(.sepia, to: view, canvasColor: canvas)
        let filter = try XCTUnwrap(scroll.contentFilters.first)
        let replacement = NSClipView(frame: originalClip.frame)
        replacement.backgroundColor = .white
        scroll.contentView = replacement
        replacement.documentView = documentView
        for _ in 0..<20 { controller.refreshTarget() }
        XCTAssertTrue(originalClip.contentFilters.isEmpty)
        XCTAssertEqual(originalClip.backgroundColor, canvas)
        XCTAssertTrue(replacement.contentFilters.isEmpty)
        XCTAssertEqual(scroll.contentFilters.count, 1)
        XCTAssertTrue(scroll.contentFilters.first === filter)
        XCTAssertEqual(replacement.backgroundColor, PDFReadingDisplayEffect.nativeCanvasColor(canvas, theme: .sepia))
        controller.detach()
        XCTAssertEqual(replacement.backgroundColor, canvas)
    }

    @MainActor
    func testReadingFilterRetainsScreenResolutionWhenPDFKitMagnifiesItsClip() throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        let page = try XCTUnwrap(document.page(at: 0))
        let originalText = page.string
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 420, height: 560))
        view.document = document
        view.displayMode = .singlePage
        view.autoScales = false
        let controller = PDFReadingDisplayFilterController()
        defer { controller.detach() }

        for theme in [PDFReadingTheme.soft, .sepia, .night] {
            controller.apply(theme, to: view)
            let scroll = try XCTUnwrap(view.documentView?.enclosingScrollView)
            let filter = try XCTUnwrap(scroll.contentFilters.first)
            for zoom: CGFloat in [0.5, 1, 2, 4, 8, 1] {
                view.scaleFactor = zoom
                view.layoutDocumentView()
                view.layoutSubtreeIfNeeded()
                controller.refreshTarget()
                let clip = scroll.contentView
                // A filter on the clip would render into these shrinking
                // bounds and then enlarge that bitmap, losing fine text/lines.
                XCTAssertEqual(clip.frame.width / clip.bounds.width, view.scaleFactor, accuracy: 0.001)
                XCTAssertEqual(scroll.bounds.width, scroll.frame.width, accuracy: 0.001)
                XCTAssertEqual(scroll.bounds.height, scroll.frame.height, accuracy: 0.001)
                XCTAssertEqual(scroll.convertToBacking(CGSize(width: 1, height: 1)).width,
                               view.convertToBacking(CGSize(width: 1, height: 1)).width, accuracy: 0.001)
                XCTAssertTrue(scroll.contentFilters.first === filter)
                XCTAssertTrue(clip.contentFilters.isEmpty)
                XCTAssertTrue(view.documentView?.contentFilters.isEmpty == true)
                XCTAssertFalse(scroll.layer?.shouldRasterize ?? true)
                XCTAssertTrue(view.document === document)
                XCTAssertTrue(document.page(at: 0) === page)
                XCTAssertEqual(page.string, originalText)
            }
        }
    }

    @MainActor
    func testThemeSwitchPreservesNativeDocumentSelectionFormHighlightsAndViewport() throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let originalBytes = try Data(contentsOf: source)
        let document = try XCTUnwrap(PDFDocument(url: source))
        let page = try XCTUnwrap(document.page(at: 1))
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 420, height: 560))
        view.document = document
        view.displayMode = .singlePage
        view.autoScales = false
        view.scaleFactor = 0.85
        view.go(to: page)
        let selection = try XCTUnwrap(document.findString("Readable", withOptions: []).first)
        view.setCurrentSelection(selection, animate: false)
        let selectionText = view.currentSelection?.string
        let currentPage = view.currentPage
        let scale = view.scaleFactor
        let destination = try XCTUnwrap(view.currentDestination?.point)
        let backingScale = view.convertToBacking(CGSize(width: 1, height: 1)).width
        let oneBackingPixelInPage = 1 / (max(1, backingScale) * scale)
        var layerAlignedDestination: CGPoint?
        let pageCount = document.pageCount
        let annotations = page.annotations
        let values = annotations.map { $0.widgetStringValue }
        let colors = annotations.map { $0.color }
        let controller = PDFReadingDisplayFilterController()

        let themes: [PDFReadingTheme] = [.soft, .sepia, .night, .original, .night, .original]
        for theme in (0..<5).flatMap({ _ in themes }) {
            controller.apply(theme, to: view)
            XCTAssertTrue(view.document === document)
            XCTAssertTrue(view.currentPage === currentPage)
            XCTAssertEqual(view.scaleFactor, scale)
            let currentDestination = try XCTUnwrap(view.currentDestination?.point)
            // Enabling layer backing can align existing view bounds
            // to the backing grid. Allow
            // that first subpixel alignment, but no cumulative theme drift.
            XCTAssertEqual(currentDestination.x, destination.x, accuracy: oneBackingPixelInPage)
            XCTAssertEqual(currentDestination.y, destination.y, accuracy: oneBackingPixelInPage)
            if let layerAlignedDestination {
                XCTAssertEqual(currentDestination.x, layerAlignedDestination.x, accuracy: 0.000_001)
                XCTAssertEqual(currentDestination.y, layerAlignedDestination.y, accuracy: 0.000_001)
            } else {
                layerAlignedDestination = currentDestination
            }
            XCTAssertEqual(view.currentSelection?.string, selectionText)
            XCTAssertEqual(document.pageCount, pageCount)
            XCTAssertEqual(page.annotations.map { $0.widgetStringValue }, values)
            XCTAssertEqual(page.annotations.map { $0.color }, colors)
            XCTAssertEqual(page.annotations.count, annotations.count)
            XCTAssertTrue(zip(page.annotations, annotations).allSatisfy { $0 === $1 })
            XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        }
        // Selection and form values remain editable through PDFKit; the effect
        // adds no intercepting view, replacement document or raster-only reader.
        let selected = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 8)))
        view.setCurrentSelection(selected, animate: false)
        XCTAssertTrue(view.currentSelection?.string?.contains("Readable") == true)
        let widget = try XCTUnwrap(page.annotations.first { $0.widgetFieldType == .text })
        widget.widgetStringValue = "User can still type"
        XCTAssertEqual(widget.widgetStringValue, "User can still type")
        XCTAssertTrue(view.contentFilters.isEmpty)
    }

    @MainActor
    func testDisplayEffectsLeaveExportAndSharedGalleryRastersOriginal() async throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: source))
        workspace.setCurrentPage(1)
        let revision = workspace.revision
        let document = try XCTUnwrap(workspace.document)
        let service = PDFDocumentGalleryPreviewService(debounceNanoseconds: 0)
        let previewResult = await service.preview(for: workspace, width: 200)
        let preview = try XCTUnwrap(previewResult)
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 420, height: 560))
        view.document = document
        let controller = PDFReadingDisplayFilterController()
        for theme in PDFReadingTheme.allCases { controller.apply(theme, to: view) }
        let cachedResult = await service.preview(for: workspace, width: 200)
        let cached = try XCTUnwrap(cachedResult)
        XCTAssertTrue(cached.image === preview.image)
        XCTAssertEqual(service.renderCount, 1)
        XCTAssertEqual(workspace.revision, revision)
        XCTAssertFalse(workspace.isDirty)
        let exported = try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation())))
        let originalRaster = try XCTUnwrap(document.page(at: 1)).thumbnail(of: CGSize(width: 200, height: 260), for: .cropBox)
        let exportedRaster = try XCTUnwrap(exported.page(at: 1)).thumbnail(of: CGSize(width: 200, height: 260), for: .cropBox)
        for image in [preview.image, originalRaster, exportedRaster] {
            let color = try centerColor(image)
            XCTAssertGreaterThan(color.redComponent, 0.98)
            XCTAssertGreaterThan(color.greenComponent, 0.98)
            XCTAssertGreaterThan(color.blueComponent, 0.98)
        }
        controller.detach()
    }

    @MainActor
    func testRepeatedUpdatesKeepOneFilterAndRestoreOtherEffects() throws {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        view.wantsLayer = true
        let unrelated = try XCTUnwrap(CIFilter(name: "CIGammaAdjust"))
        view.contentFilters = [unrelated]
        let controller = PDFReadingDisplayFilterController()
        controller.apply(.night, to: view)
        let firstFilter = try XCTUnwrap(view.contentFilters.last)
        for _ in 0..<100 { controller.apply(.night, to: view) }
        XCTAssertEqual(view.contentFilters.count, 2)
        XCTAssertTrue(view.contentFilters.last === firstFilter)
        controller.apply(.original, to: view)
        XCTAssertEqual(view.contentFilters.count, 1)
        XCTAssertTrue(view.contentFilters.first === unrelated)
        controller.apply(.sepia, to: view)
        let other = NSView(frame: view.frame)
        controller.apply(.soft, to: other)
        XCTAssertEqual(view.contentFilters.count, 1)
        XCTAssertEqual(other.contentFilters.count, 1)
        controller.detach()
        XCTAssertTrue(other.contentFilters.isEmpty)
    }

    private func pixel(red: CGFloat, green: CGFloat, blue: CGFloat, filter: CIFilter) throws -> [Double] {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                         .useSoftwareRenderer: true])
        let input = CIImage(color: try XCTUnwrap(CIColor(red: red, green: green, blue: blue, alpha: 1, colorSpace: colorSpace)))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        filter.setValue(input, forKey: kCIInputImageKey)
        let output = try XCTUnwrap(filter.outputImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &bytes, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: colorSpace)
        return bytes.map { Double($0) / 255 }
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingColor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("reading.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 520)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for index in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Readable page \(index + 1)",
                attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black]))
            context.textPosition = CGPoint(x: 32, y: 460)
            CTLineDraw(line, context)
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 32, y: 370, width: 90, height: 40))
            context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 1))
        let widget = PDFAnnotation(bounds: CGRect(x: 32, y: 310, width: 180, height: 30), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "reader-name"
        widget.widgetStringValue = "Unchanged form"
        // Give the form an explicit color: PDFKit's unspecified "no color"
        // sentinel does not compare equal even to another read of itself.
        widget.color = .gray
        page.addAnnotation(widget)
        let highlight = PDFAnnotation(bounds: CGRect(x: 32, y: 430, width: 180, height: 20), forType: .highlight, withProperties: nil)
        highlight.color = .yellow
        page.addAnnotation(highlight)
        XCTAssertTrue(document.write(to: url))
        return url
    }

    private func centerColor(_ image: NSImage) throws -> NSColor {
        var rectangle = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rectangle, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }
}
