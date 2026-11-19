// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import HwattakPDF

final class PDFComparisonDisplayTests: XCTestCase {
    @MainActor
    func testThreeHostedComparisonPanesStaySingleColumnAcrossResizeAndReflow() async throws {
        try await assertHostedComparisonPanes(pageSize: CGSize(width: 612, height: 792))
    }

    @MainActor
    func testLandscapeComparisonPagesStaySelectedAndVisibleAcrossResize() async throws {
        // Scanned spreads and art books often contain short, wide pages. At
        // the initial 520 × 720 pane size a fitted page is shorter than half
        // the viewport. Top-aligning it puts the next page at the reading
        // midpoint and can silently replace the requested page before resize.
        try await assertHostedComparisonPanes(
            pageSize: CGSize(width: 1_200, height: 600),
            verifyFittedPagePosition: true,
            scrollerStyle: .legacy
        )
    }

    @MainActor
    func testLandscapeComparisonPagesStaySelectedAndVisibleWithOverlayScrollersAcrossResize() async throws {
        try await assertHostedComparisonPanes(
            pageSize: CGSize(width: 1_200, height: 600),
            verifyFittedPagePosition: true,
            scrollerStyle: .overlay
        )
    }

    @MainActor
    private func assertHostedComparisonPanes(
        pageSize: CGSize,
        verifyFittedPagePosition: Bool = false,
        scrollerStyle: NSScroller.Style? = nil
    ) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberPDF-ComparisonDisplay-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let columnCounts = [1, 2, 4]
        let startingPages = [3, 6, 9]
        let states = try columnCounts.enumerated().map { index, columns in
            let state = PDFWorkspaceState()
            XCTAssertTrue(state.open(url: try makeDocument(in: directory, index: index, pageSize: pageSize)))
            state.pageColumns = columns
            state.twoPageDisplayMode = index == 1 ? .paged : .continuous
            state.setCurrentPage(startingPages[index])
            state.recordPDFViewport(autoScales: false, scaleFactor: 1.3 + CGFloat(index) / 10,
                                    scrollProgress: PDFScrollProgress(horizontal: 0.2, vertical: 0.4))
            return state
        }
        let normalViewports = states.map(\.pdfViewportState)
        let normalSpreadModes = states.map(\.twoPageDisplayMode)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_560, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = try XCTUnwrap(window.contentView)
        let sync = PDFScrollSyncCoordinator()
        let syncIDs = states.map { _ in UUID() }
        let hosts = states.enumerated().map { index, state in
            NSHostingView(rootView: PDFKitViewer(
                workspace: state, scrollSyncCoordinator: sync, scrollSyncID: syncIDs[index],
                viewportContext: .comparison
            ))
        }
        defer {
            hosts.forEach { $0.removeFromSuperview() }
            window.contentView = nil
            window.close()
            states.forEach { $0.closeDiscardingChanges() }
        }
        for (index, host) in hosts.enumerated() {
            host.sizingOptions = []
            host.frame = CGRect(x: index * 520, y: 0, width: 520, height: 720)
            content.addSubview(host)
        }
        await settleLayout(hosts)
        let pdfViews = try hosts.map { try XCTUnwrap(findPDFView(in: $0)) }
        if let scrollerStyle {
            for view in pdfViews {
                let scroll = try XCTUnwrap(view.firstDocumentScrollView())
                scroll.scrollerStyle = scrollerStyle
                scroll.tile()
                view.needsLayout = true
            }
            await settleLayout(hosts)
        }
        if verifyFittedPagePosition {
            for (index, view) in pdfViews.enumerated() {
                try assertFittedPagePosition(in: view, state: states[index], pageIndex: startingPages[index])
            }
        }

        // Exercise the actual NSViewRepresentable update path, not a fixture
        // that assigns displayMode itself. A saved 2-up or 4-page overview
        // previously leaked into these comparison PDFViews as twoUpContinuous.
        let layouts: [[CGRect]] = [
            [CGRect(x: 0, y: 0, width: 950, height: 720),
             CGRect(x: 958, y: 0, width: 290, height: 720),
             CGRect(x: 1_256, y: 0, width: 304, height: 720)],
            [CGRect(x: 0, y: 0, width: 260, height: 720),
             CGRect(x: 268, y: 0, width: 580, height: 720),
             CGRect(x: 856, y: 0, width: 704, height: 720)],
            [CGRect(x: 0, y: 488, width: 1_560, height: 232),
             CGRect(x: 0, y: 244, width: 1_560, height: 232),
             CGRect(x: 0, y: 0, width: 1_560, height: 232)]
        ]
        for (layoutIndex, frames) in layouts.enumerated() {
            for (host, frame) in zip(hosts, frames) { host.frame = frame }
            await settleLayout(hosts)
            for (index, view) in pdfViews.enumerated() {
                XCTAssertTrue(findPDFView(in: hosts[index]) === view,
                              "Resizing must retain the existing native PDF view.")
                XCTAssertEqual(view.displayMode, .singlePageContinuous)
                XCTAssertEqual(view.displayDirection, .vertical)
                let document = try XCTUnwrap(states[index].document)
                let page = try XCTUnwrap(document.page(at: startingPages[index]))
                let nextPage = try XCTUnwrap(document.page(at: startingPages[index] + 1))
                let pageRect = view.convert(page.bounds(for: .cropBox), from: page)
                let nextRect = view.convert(nextPage.bounds(for: .cropBox), from: nextPage)
                XCTAssertEqual(pageRect.minX, nextRect.minX, accuracy: 0.5,
                               "Consecutive pages must share one column, without a spread gutter.")
                XCTAssertEqual(pageRect.width, nextRect.width, accuracy: 0.5)
                XCTAssertGreaterThan(abs(pageRect.midY - nextRect.midY), pageRect.height * 0.9)
                XCTAssertEqual(states[index].currentPageIndex, startingPages[index])
                XCTAssertEqual(states[index].pageColumns, columnCounts[index])
                XCTAssertEqual(states[index].twoPageDisplayMode, normalSpreadModes[index])
                XCTAssertEqual(states[index].pdfViewportState, normalViewports[index],
                               "Comparison fitting must not overwrite the normal reading viewport.")
                XCTAssertFalse(states[index].isDirty)
                if verifyFittedPagePosition {
                    try assertFittedPagePosition(in: view, state: states[index], pageIndex: startingPages[index])
                }
            }
            if let path = ProcessInfo.processInfo.environment["COMPARISON_QA_DIRECTORY"] {
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let prefix = verifyFittedPagePosition ? "comparison-landscape" : "comparison"
                try data.write(to: URL(fileURLWithPath: path)
                    .appendingPathComponent("\(prefix)-layout-\(layoutIndex).png"))
            }
        }
        if verifyFittedPagePosition {
            // Explicit page jumps use a separate update path from resizing.
            // Keep the same short-page geometry that previously put the next
            // page at the reading midpoint when go(to:) top-aligned a page.
            for (index, host) in hosts.enumerated() {
                host.frame = CGRect(x: index * 520, y: 0, width: 520, height: 720)
            }
            await settleLayout(hosts)
            sync.enabled = false
            states[0].setCurrentPage(5)
            await settleLayout(hosts)
            for (index, expected) in [5, startingPages[1], startingPages[2]].enumerated() {
                try assertFittedPagePosition(in: pdfViews[index], state: states[index], pageIndex: expected)
            }

            XCTAssertTrue(sync.stepPages(by: 1, sourceID: syncIDs[0]))
            await settleLayout(hosts)
            for (index, expected) in [6, startingPages[1], startingPages[2]].enumerated() {
                try assertFittedPagePosition(in: pdfViews[index], state: states[index], pageIndex: expected)
            }

            // A fixed pane must stay at its own position when group movement
            // is enabled. Updating the actual representable also verifies the
            // model's locked flag reaches the native scroll registration.
            hosts[2].rootView = PDFKitViewer(
                workspace: states[2], scrollSyncCoordinator: sync, scrollSyncID: syncIDs[2],
                scrollSyncLocked: true, viewportContext: .comparison
            )
            await settleLayout(hosts)
            XCTAssertTrue(findPDFView(in: hosts[2]) === pdfViews[2])
            let fixedClip = try XCTUnwrap(pdfViews[2].firstDocumentScrollView()?.contentView)
            let fixedOrigin = fixedClip.bounds.origin
            let fixedScale = pdfViews[2].scaleFactor
            sync.enabled = true
            XCTAssertTrue(sync.stepPages(by: 1, sourceID: syncIDs[0]))
            await settleLayout(hosts)
            for (index, expected) in [7, startingPages[1] + 1, startingPages[2]].enumerated() {
                try assertFittedPagePosition(in: pdfViews[index], state: states[index], pageIndex: expected)
                XCTAssertEqual(states[index].pdfViewportState, normalViewports[index])
                XCTAssertFalse(states[index].isDirty)
            }
            XCTAssertEqual(fixedClip.bounds.origin, fixedOrigin)
            XCTAssertEqual(pdfViews[2].scaleFactor, fixedScale)
            XCTAssertFalse(sync.stepPages(by: 1, sourceID: syncIDs[2]),
                           "A fixed source must not drive page movement.")

            // At either end, native clip bounds prevent a short page from
            // reaching the viewport midpoint. Explicit navigation still has
            // to retain the first/last page and step from that exact page.
            sync.enabled = false
            let lastPage = states[0].pageCount - 1
            states[0].setCurrentPage(0)
            await settleLayout(hosts)
            try assertFittedPagePosition(in: pdfViews[0], state: states[0], pageIndex: 0)
            for width in [260, 520] {
                hosts[0].frame = CGRect(x: 0, y: 0, width: width, height: 720)
                await settleLayout(hosts)
                try assertFittedPagePosition(in: pdfViews[0], state: states[0], pageIndex: 0)
            }

            // Scroll the native clip rather than asking the navigation API to
            // change pages. A retained explicit first-page destination must
            // stop taking precedence once the viewport actually moves.
            let panningView = pdfViews[0]
            let panningClip = try XCTUnwrap(panningView.firstDocumentScrollView()?.contentView)
            let pannedPage = try XCTUnwrap(states[0].document?.page(at: 3))
            let pannedPageRect = panningView.convert(pannedPage.bounds(for: .cropBox), from: pannedPage)
            let targetInClip = panningClip.convert(pannedPageRect, from: panningView)
            let proposed = CGRect(
                x: panningClip.bounds.minX,
                y: targetInClip.midY - panningClip.bounds.height / 2,
                width: panningClip.bounds.width, height: panningClip.bounds.height
            )
            panningClip.setBoundsOrigin(panningClip.constrainBoundsRect(proposed).origin)
            panningClip.enclosingScrollView?.reflectScrolledClipView(panningClip)
            let geometricPage = panningView.page(
                for: CGPoint(x: panningView.bounds.midX, y: panningView.bounds.midY), nearest: true
            )
            XCTAssertTrue(geometricPage === pannedPage, "The test pan must reach the intended page.")
            XCTAssertTrue(PDFScrollSyncCoordinator.readingPage(in: panningView) === geometricPage,
                          "A real pan must release the prior explicit page and follow viewport geometry.")
            await settleLayout(hosts)

            states[0].setCurrentPage(lastPage)
            await settleLayout(hosts)
            try assertFittedPagePosition(in: pdfViews[0], state: states[0], pageIndex: lastPage)
            XCTAssertTrue(sync.stepPages(by: -1, sourceID: syncIDs[0]))
            await settleLayout(hosts)
            try assertFittedPagePosition(in: pdfViews[0], state: states[0], pageIndex: lastPage - 1)
            XCTAssertEqual(states[0].pdfViewportState, normalViewports[0])
            XCTAssertEqual(states[1].currentPageIndex, startingPages[1] + 1)
            XCTAssertEqual(states[2].currentPageIndex, startingPages[2])
        }
    }

    @MainActor
    private func assertFittedPagePosition(
        in view: InteractivePDFView,
        state: PDFWorkspaceState,
        pageIndex: Int
    ) throws {
        let document = try XCTUnwrap(state.document)
        let page = try XCTUnwrap(document.page(at: pageIndex))
        let clip = try XCTUnwrap(view.firstDocumentScrollView()?.contentView)
        let viewport = view.convert(clip.bounds, from: clip).intersection(view.bounds)
        let pageRect = view.convert(page.bounds(for: .cropBox), from: page)
        XCTAssertEqual(state.currentPageIndex, pageIndex,
                       "Fitting or resizing a short page must not select its neighbour.")
        XCTAssertTrue(PDFScrollSyncCoordinator.readingPage(in: view) === page,
                      "The requested page must remain the reading page after fitting or navigation.")
        XCTAssertTrue(view.comparisonAutomaticallyFitsPage)
        XCTAssertGreaterThan(pageRect.width, 0)
        XCTAssertGreaterThan(viewport.width, 0)
        XCTAssertGreaterThanOrEqual(pageRect.minX, viewport.minX - 1,
                                    "Automatic fitting must keep the page's left edge visible.")
        XCTAssertLessThanOrEqual(pageRect.maxX, viewport.maxX + 1,
                                 "Automatic fitting must keep the page's right edge visible.")
        XCTAssertEqual(pageRect.midX, viewport.midX, accuracy: 1,
                       "A narrow pane must not retain an obsolete horizontal scroll offset.")
    }

    @MainActor
    private func settleLayout(_ hosts: [NSView]) async {
        for _ in 0..<4 {
            hosts.forEach { $0.layoutSubtreeIfNeeded() }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @MainActor
    private func findPDFView(in view: NSView) -> InteractivePDFView? {
        if let pdf = view as? InteractivePDFView { return pdf }
        return view.subviews.lazy.compactMap { self.findPDFView(in: $0) }.first
    }

    private func makeDocument(in directory: URL, index: Int, pageSize: CGSize) throws -> URL {
        let url = directory.appendingPathComponent("comparison-\(index).pdf")
        var bounds = CGRect(origin: .zero, size: pageSize)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for page in 0..<12 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            context.setFillColor(CGColor(red: 0.15 + CGFloat(index) * 0.2,
                                         green: 0.3 + CGFloat(page) * 0.025, blue: 0.65, alpha: 1))
            context.fill(CGRect(x: 24, y: bounds.height - 112, width: bounds.width - 48, height: 88))
            for row in 0..<18 {
                context.fill(CGRect(x: 24, y: 40 + row * 32, width: 360 + (row % 3) * 60, height: 8))
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}
