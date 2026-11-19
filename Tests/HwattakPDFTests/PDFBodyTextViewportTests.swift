// SPDX-License-Identifier: MPL-2.0
import AppKit
import CoreText
import PDFKit
import SwiftUI
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextViewportTests: XCTestCase {
    func testApplyUndoRedoKeepZoomAndReadingPositionThroughSwiftUIUpdate() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 900)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for index in 0..<3 {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 90, y: 460)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
                string: "Original body on page \(index)", attributes: [.font: NSFont(name: "Times-Roman", size: 18)!])), context)
            context.endPDFPage()
        }
        context.closePDF()
        let url = folder.appendingPathComponent("viewport.pdf")
        try (bytes as Data).write(to: url)
        let state = PDFWorkspaceState()
        XCTAssertTrue(state.open(url: url))
        state.setMode(.editing)
        state.currentPageIndex = 1
        let host = NSHostingView(rootView: PDFKitViewer(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 550, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            state.cancelPendingInlineText()
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await settle()
        let view = try XCTUnwrap(descendant(InteractivePDFView.self, in: host))
        view.autoScales = false
        view.scaleFactor = 1.75
        let page = try XCTUnwrap(state.document?.page(at: 1))
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 60, y: 600)))
        view.layoutDocumentView()
        try await settle()
        let clip = try XCTUnwrap(view.firstDocumentScrollView()).contentView
        let origin = clip.bounds.origin
        XCTAssertTrue(state.requestBodyTextEdit(pageIndex: 1, point: CGPoint(x: 110, y: 466)))
        let draft = try XCTUnwrap(state.pendingInlineTextEdit)
        state.commitPendingInlineText(id: draft.id, text: "Updated body",
                                     style: draft.style, bounds: draft.bounds)
        XCTAssertNil(state.pendingInlineTextEdit)
        XCTAssertNil(state.presentedError)
        for action in 0..<3 {
            if action == 1 { state.undo() }
            if action == 2 { state.redo() }
            try await settle()
            let currentClip = try XCTUnwrap(view.firstDocumentScrollView()).contentView
            XCTAssertEqual(state.currentPageIndex, 1)
            XCTAssertEqual(view.scaleFactor, 1.75, accuracy: 0.001)
            XCTAssertEqual(currentClip.bounds.minX, origin.x, accuracy: 0.75)
            XCTAssertEqual(currentClip.bounds.minY, origin.y, accuracy: 0.75)
        }
    }

    func testWidthFitDoesNotRevealPageAgainAfterApplyingText() async throws {
        try await withViewer { state, view in
            state.selectPageFitMode(.width)
            try await settle()
            let page = try XCTUnwrap(state.document?.page(at: 1))
            view.go(to: PDFDestination(page: page, at: CGPoint(x: 30, y: 600)))
            try await settle()
            let scroll = try XCTUnwrap(view.firstDocumentScrollView())
            let origin = scroll.contentView.bounds.origin
            let scale = view.scaleFactor
            try applyText(in: state, pageIndex: 1)
            try await settle()
            XCTAssertEqual(state.pageFitMode, .width)
            XCTAssertEqual(view.scaleFactor, scale, accuracy: 0.001)
            XCTAssertEqual(scroll.contentView.bounds.minX, origin.x, accuracy: 0.75)
            XCTAssertEqual(scroll.contentView.bounds.minY, origin.y, accuracy: 0.75)
        }
    }

    func testRightPageOfPagedSpreadKeepsPositionOnApplyUndoAndRedo() async throws {
        try await withViewer(windowSize: CGSize(width: 1250, height: 500), configure: { state in
            state.pageColumns = 2
            state.twoPageDisplayMode = .paged
        }) { state, view in
            view.autoScales = false
            view.scaleFactor = 0.9
            let document = try XCTUnwrap(state.document)
            let leftPage = try XCTUnwrap(document.page(at: 0))
            let rightPage = try XCTUnwrap(document.page(at: 1))
            view.go(to: PDFDestination(page: leftPage, at: CGPoint(x: 0, y: 600)))
            try await settle()
            XCTAssertEqual(state.currentPageIndex, 1)
            XCTAssertTrue(view.visiblePages.contains(where: { $0 === rightPage }))
            XCTAssertTrue(view.currentPage === leftPage)
            let origin = try XCTUnwrap(view.firstDocumentScrollView()).contentView.bounds.origin
            try applyText(in: state, pageIndex: 1)
            for action in 0..<3 {
                if action == 1 { state.undo() }
                if action == 2 { state.redo() }
                try await settle()
                let clip = try XCTUnwrap(view.firstDocumentScrollView()).contentView
                XCTAssertEqual(state.currentPageIndex, 1)
                XCTAssertEqual(view.scaleFactor, 0.9, accuracy: 0.001)
                XCTAssertEqual(clip.bounds.minX, origin.x, accuracy: 0.75)
                XCTAssertEqual(clip.bounds.minY, origin.y, accuracy: 0.75)
            }
        }
    }

    func testNavigationAfterApplyingTextIsNotReversedByPendingRestore() async throws {
        try await withViewer { state, view in
            try applyText(in: state, pageIndex: 1)
            state.setCurrentPage(2)
            try await settle()
            XCTAssertEqual(state.currentPageIndex, 2)
            XCTAssertTrue(view.currentPage === state.document?.page(at: 2))
        }
    }

    func testManualZoomAfterApplyingTextIsNotReversedByPendingRestore() async throws {
        try await withViewer { state, view in
            try applyText(in: state, pageIndex: 1)
            view.autoScales = false
            view.scaleFactor = 2.1
            try await settle()
            XCTAssertEqual(view.scaleFactor, 2.1, accuracy: 0.001)
        }
    }

    private func applyText(in state: PDFWorkspaceState, pageIndex: Int) throws {
        XCTAssertTrue(state.requestBodyTextEdit(pageIndex: pageIndex, point: CGPoint(x: 110, y: 466)))
        let draft = try XCTUnwrap(state.pendingInlineTextEdit)
        state.commitPendingInlineText(id: draft.id, text: "Updated body", style: draft.style, bounds: draft.bounds)
        XCTAssertNil(state.pendingInlineTextEdit)
        XCTAssertNil(state.presentedError)
    }

    private func withViewer(windowSize: CGSize = CGSize(width: 550, height: 500),
                            configure: (PDFWorkspaceState) -> Void = { _ in },
                            body: (PDFWorkspaceState, InteractivePDFView) async throws -> Void) async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 900)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &box, nil))
        for index in 0..<3 {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 90, y: 460)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
                string: "Original body on page \(index)", attributes: [.font: NSFont(name: "Times-Roman", size: 18)!])), context)
            context.endPDFPage()
        }
        context.closePDF()
        let url = folder.appendingPathComponent("viewport.pdf")
        try (bytes as Data).write(to: url)
        let state = PDFWorkspaceState()
        XCTAssertTrue(state.open(url: url))
        state.setMode(.editing)
        state.currentPageIndex = 1
        configure(state)
        let host = NSHostingView(rootView: PDFKitViewer(state: state))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: windowSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            state.cancelPendingInlineText()
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await settle()
        try await body(state, XCTUnwrap(descendant(InteractivePDFView.self, in: host)))
    }

    private func settle() async throws { try await Task.sleep(nanoseconds: 100_000_000) }
    private func descendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let found = root as? T { return found }
        return root.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }
}
