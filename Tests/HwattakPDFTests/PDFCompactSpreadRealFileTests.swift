// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

/// Explicitly supplied local PDF only; never saves or modifies the source.
final class PDFCompactSpreadRealFileTests: XCTestCase {
    @MainActor
    func testMixedWidthSourceHasCompactSpreadsAcrossResizes() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["EMBER_COMPACT_TEST_PDF"], path.hasPrefix("/") else {
            throw XCTSkip("Supply EMBER_COMPACT_TEST_PDF for read-only local PDF verification.")
        }
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let state = PDFWorkspaceState(pdfWriter: { _, _, _ in throw CocoaError(.fileWriteNoPermission) },
                                      passwordProvider: { _, _ in nil })
        XCTAssertTrue(state.open(url: url))
        state.pageColumns = 2
        state.twoPageDisplayMode = .continuous
        let document = try XCTUnwrap(state.document)
        let originalBoxes = (0..<document.pageCount).map { document.page(at: $0)!.bounds(for: .cropBox) }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = PDFCompactSpreadHostView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = host
        host.update(workspace: state, canvasColor: .darkGray, onScrollActivity: nil)
        defer {
            host.tearDown()
            window.contentView = nil
            window.close()
            state.closeDiscardingChanges()
        }
        var measurements: [[String: Double]] = []
        for width in [1200.0, 760.0, 1600.0] {
            host.setFrameSize(CGSize(width: width, height: 800))
            host.needsLayout = true
            await settle(host)
            for anchor in [0, 38, 140, 354] where anchor + 1 < document.pageCount {
                host.navigate(to: anchor + 1)
                await settle(host)
                let view = try XCTUnwrap(nativeViews(in: host).first { $0.compactSpread?.pageIndex == anchor })
                let left = try XCTUnwrap(document.page(at: anchor))
                let right = try XCTUnwrap(document.page(at: anchor + 1))
                let a = view.convert(left.bounds(for: .cropBox), from: left)
                let b = view.convert(right.bounds(for: .cropBox), from: right)
                let gap = b.minX - a.maxX
                XCTAssertLessThanOrEqual(abs(gap), 4, "A wide page elsewhere must not create a column-sized gutter.")
                XCTAssertGreaterThan(a.width + b.width, width * 0.95)
                XCTAssertEqual(view.displayMode, .twoUp)
                XCTAssertTrue(view.document === document)
                XCTAssertTrue(view.page(for: CGPoint(x: a.midX, y: a.midY), nearest: false) === left)
                let original = CGPoint(x: right.bounds(for: .cropBox).midX, y: right.bounds(for: .cropBox).midY)
                let roundTrip = view.convert(view.convert(original, from: right), to: right)
                XCTAssertEqual(roundTrip.x, original.x, accuracy: 0.01)
                XCTAssertEqual(roundTrip.y, original.y, accuracy: 0.01)
                XCTAssertEqual(state.currentPageIndex, anchor + 1)
                XCTAssertLessThanOrEqual(host.materializedRowCount, 6)
                XCTAssertFalse(state.isDirty)
                measurements.append(["viewportWidth": width, "pageIndex": Double(anchor),
                                     "gap": gap, "combinedPageWidth": a.width + b.width,
                                     "mountedRows": Double(host.materializedRowCount)])
                if width == 1200, anchor == 140, let directory = environment["EMBER_COMPACT_QA_DIRECTORY"] {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent("compact-spread.png"))
                }
            }
        }
        XCTAssertEqual((0..<document.pageCount).map { document.page(at: $0)!.bounds(for: .cropBox) }, originalBoxes)
        let after = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attributes[.size] as? UInt64, after[.size] as? UInt64)
        XCTAssertEqual(attributes[.modificationDate] as? Date, after[.modificationDate] as? Date)
        if let directory = environment["EMBER_COMPACT_QA_DIRECTORY"] {
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("geometry.json"))
        }
    }

    @MainActor private func nativeViews(in view: NSView) -> [InteractivePDFView] {
        if let pdf = view as? InteractivePDFView { return [pdf] }
        return view.subviews.flatMap { nativeViews(in: $0) }
    }

    @MainActor private func settle(_ host: NSView) async {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(35))
        }
    }
}
