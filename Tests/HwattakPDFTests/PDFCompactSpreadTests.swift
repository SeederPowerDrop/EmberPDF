// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFCompactSpreadTests: XCTestCase {
    func testWidePageOnlyChangesItsOwnSpreadScale() {
        var sizes = Array(repeating: CGSize(width: 500, height: 700), count: 8)
        sizes[5] = CGSize(width: 1_000, height: 700)
        let layout = PDFCompactSpreadGeometry(pageSizes: sizes, viewport: CGSize(width: 1_000, height: 700))
        XCTAssertEqual(layout.rows.count, 4)
        XCTAssertEqual(layout.rows[0].scale, 1, accuracy: 0.001)
        XCTAssertEqual(layout.rows[1].scale, 1, accuracy: 0.001)
        XCTAssertEqual(layout.rows[2].scale, 2 / 3, accuracy: 0.001)
        XCTAssertEqual(layout.rows[3].scale, 1, accuracy: 0.001)
        XCTAssertTrue(layout.rows.allSatisfy { abs($0.frame.width - 1_000) <= 1 })
        XCTAssertEqual(layout.rows[1].frame.minY - layout.rows[0].frame.maxY,
                       PDFCompactSpreadGeometry.rowSpacing, accuracy: 0.001)
    }

    func testSingleFinalPageAndInvalidSizesRemainFinite() {
        let layout = PDFCompactSpreadGeometry(pageSizes: [CGSize(width: 600, height: 800),
            CGSize(width: CGFloat.nan, height: CGFloat.infinity), CGSize(width: 900, height: 400)],
            viewport: CGSize(width: 900, height: 700))
        XCTAssertEqual(layout.rows.last?.pageCount, 1)
        XCTAssertEqual(layout.rows.last?.pageIndex, 2)
        XCTAssertEqual(layout.rows.last?.scale ?? 0, 1, accuracy: 0.001)
        XCTAssertTrue(layout.rows.allSatisfy { $0.frame.width.isFinite && $0.frame.height.isFinite })
    }

    func testVirtualizationSelectsVisibleSpreadsAndOneNeighborOnEachSide() {
        let layout = PDFCompactSpreadGeometry(pageSizes: Array(repeating: CGSize(width: 500, height: 700), count: 2_000),
                                             viewport: CGSize(width: 1_000, height: 700))
        let row = layout.rows[300]
        XCTAssertEqual(layout.materializedRows(in: CGRect(x: 0, y: row.frame.minY + 10, width: 1_000, height: 600)), 299..<302)
        XCTAssertEqual(layout.rowIndex(at: -100), 0)
        XCTAssertEqual(layout.rowIndex(at: layout.contentSize.height + 100), 999)
    }

    @MainActor
    func testHostedMixedSpreadsStayClosePreserveSourceAndRetireOffscreenRows() async throws {
        _ = NSApplication.shared
        let url = try makeDocument()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.pageColumns = 2
        workspace.twoPageDisplayMode = .continuous
        let document = try XCTUnwrap(workspace.document)
        let originalBounds = (0..<document.pageCount).map { document.page(at: $0)!.bounds(for: .cropBox) }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = PDFCompactSpreadHostView(frame: CGRect(x: 0, y: 0, width: 1_000, height: 700))
        window.contentView = host
        defer { host.tearDown(); window.contentView = nil; window.close(); workspace.closeDiscardingChanges() }
        host.update(workspace: workspace, canvasColor: .windowBackgroundColor, onScrollActivity: nil)
        await settle(host)
        let initial = try XCTUnwrap(host.nativePDFView(forPageIndex: 0))
        XCTAssertTrue(initial.document === document)
        XCTAssertEqual(initial.displayMode, .twoUp)
        let left = document.page(at: 0)!
        let right = document.page(at: 1)!
        let a = initial.convert(left.bounds(for: .cropBox), from: left)
        let b = initial.convert(right.bounds(for: .cropBox), from: right)
        XCTAssertLessThan(abs(b.minX - a.maxX), 5, "Unrelated wide pages must not create a gutter")
        XCTAssertGreaterThan(a.width, 450)
        XCTAssertLessThanOrEqual(host.materializedRowCount, 4)
        weak var retiredView = initial
        host.navigate(to: 21)
        await settle(host)
        XCTAssertEqual(workspace.currentPageIndex, 21)
        XCTAssertTrue(host.materializedPageIndices.contains(20))
        XCTAssertFalse(host.materializedPageIndices.contains(0))
        // `initial` deliberately retains the first view in this test; retirement
        // is verified by hierarchy rather than asserting its deallocation.
        XCTAssertFalse(retiredView?.isDescendant(of: host) ?? true)
        XCTAssertLessThanOrEqual(host.materializedRowCount, 4)
        host.zoom(by: 1.5)
        host.frame.size = CGSize(width: 760, height: 620)
        await settle(host)
        XCTAssertEqual(workspace.currentPageIndex, 21)
        XCTAssertTrue(workspace.pdfViewportState.usesCompactSpreads)
        // Exercise the actual native key handler after its owning row has
        // moved through several virtualized spreads, including Option+arrows.
        for target in [22, 24, 26] {
            let native = try XCTUnwrap(host.nativePDFView(forPageIndex: workspace.currentPageIndex))
            native.pageNavigationMode = .allDirectionsPaging
            XCTAssertTrue(window.makeFirstResponder(native))
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .option, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                isARepeat: false, keyCode: 125))
            XCTAssertTrue(native.handlePageNavigationKey(event))
            native.arrowKeyRepeater.stop()
            XCTAssertEqual(workspace.currentPageIndex, target)
            await settle(host)
        }
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual((0..<document.pageCount).map { document.page(at: $0)!.bounds(for: .cropBox) }, originalBounds)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor
    func testExplicitWidthFitOverridesSavedNativeManualScale() throws {
        _ = NSApplication.shared
        let url = try makeDocument()
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.pageColumns = 2
        workspace.twoPageDisplayMode = .continuous
        workspace.restorePageFitMode(.width)
        workspace.recordPDFViewport(autoScales: false, scaleFactor: 0.5, scrollProgress: nil)
        let host = PDFCompactSpreadHostView(frame: CGRect(x: 0, y: 0, width: 1_000, height: 700))
        defer { host.tearDown(); workspace.closeDiscardingChanges() }
        host.update(workspace: workspace, canvasColor: .windowBackgroundColor, onScrollActivity: nil)
        XCTAssertEqual(host.geometry.rows.first?.frame.width ?? 0, 1_000, accuracy: 1)
        XCTAssertEqual(host.geometry.rows.first?.scale ?? 0, 1, accuracy: 0.001)
    }

    @MainActor
    func testCompactAndNativeViewportProgressAreSeparated() throws {
        let workspace = PDFWorkspaceState()
        workspace.recordPDFViewport(autoScales: true, scaleFactor: 1,
                                    scrollProgress: PDFScrollProgress(horizontal: 0.2, vertical: 0.8), usesCompactSpreads: true)
        XCTAssertTrue(workspace.pdfViewportState.usesCompactSpreads)
        workspace.recordPDFViewport(autoScales: true, scaleFactor: 1, scrollProgress: nil)
        XCTAssertFalse(workspace.pdfViewportState.usesCompactSpreads)
        XCTAssertNil(workspace.pdfViewportState.scrollProgress)
        workspace.restorePDFViewport(autoScales: true, scaleFactor: 1,
            horizontalScrollProgress: 0.2, verticalScrollProgress: 0.8, usesCompactSpreads: true)
        XCTAssertTrue(workspace.pdfViewportState.usesCompactSpreads)
    }

    @MainActor
    private func settle(_ host: PDFCompactSpreadHostView) async {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func makeDocument() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EmberCompact-\(UUID()).pdf")
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        for index in 0..<30 {
            var box = CGRect(x: 0, y: 0, width: index == 8 ? 1_000 : 500, height: 700)
            let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: data] as CFDictionary)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            context.setFillColor(NSColor.blue.cgColor)
            context.fill(CGRect(x: 20, y: 20, width: box.width - 40, height: 40))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}
