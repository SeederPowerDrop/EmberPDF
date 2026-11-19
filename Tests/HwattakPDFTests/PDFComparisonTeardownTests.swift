// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFComparisonTeardownTests: XCTestCase {
    @MainActor
    func testReadOnlyTeardownDoesNotRescanPreviouslyVisitedFormPages() throws {
        let workspace = try makeWorkspace()
        let document = try XCTUnwrap(workspace.document)
        let pages = (0..<64).map { _ in AnnotationReadProbePage() }
        for page in pages {
            page.setBounds(CGRect(x: 0, y: 0, width: 400, height: 600), for: .mediaBox)
            document.insert(page, at: document.pageCount)
            workspace.primeWidgetValues(on: page)
        }
        workspace.setCurrentPage(18)
        workspace.recordPDFViewport(autoScales: false, scaleFactor: 2, scrollProgress: nil, context: .normal)
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 700))
        view.viewportContext = .comparison
        view.document = document
        view.autoScales = false
        view.comparisonAutomaticallyFitsPage = false
        view.scaleFactor = 1.4
        let coordinator = PDFKitViewer.Coordinator(state: workspace, viewportContext: .comparison)
        coordinator.attach(to: view)
        defer { coordinator.detach() }

        pages.forEach { $0.annotationReadCount = 0 }
        workspace.synchronizeWidgetValues()
        XCTAssertEqual(pages.reduce(0) { $0 + $1.annotationReadCount }, 128,
                       "The former teardown scanned values and undo values on every visited page.")
        pages.forEach { $0.annotationReadCount = 0 }
        let revision = workspace.revision

        coordinator.prepareForDismantling()

        XCTAssertEqual(pages.reduce(0) { $0 + $1.annotationReadCount }, 0)
        XCTAssertEqual(workspace.currentPageIndex, 18)
        XCTAssertEqual(workspace.revision, revision)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(workspace.pdfViewportState(for: .comparison).scaleFactor ?? 0, 1.4, accuracy: 0.001)
        XCTAssertEqual(workspace.pdfViewportState(for: .normal).scaleFactor ?? 0, 2, accuracy: 0.001)
    }

    @MainActor
    func testNormalTeardownStillCommitsNativeFormChanges() throws {
        let workspace = try makeWorkspace()
        let document = try XCTUnwrap(workspace.document)
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 400, height: 600), for: .mediaBox)
        let widget = PDFAnnotation(bounds: CGRect(x: 20, y: 100, width: 140, height: 24),
                                   forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "native-field"
        widget.widgetStringValue = "before"
        page.addAnnotation(widget)
        document.insert(page, at: document.pageCount)
        workspace.primeWidgetValues(on: page)
        let view = InteractivePDFView(frame: .zero)
        let coordinator = PDFKitViewer.Coordinator(state: workspace)
        coordinator.attach(to: view)
        defer { coordinator.detach() }
        widget.widgetStringValue = "after"

        coordinator.prepareForDismantling()

        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(widget.widgetStringValue, "after")
        XCTAssertTrue(workspace.canUndo)
        workspace.undo()
        XCTAssertEqual(widget.widgetStringValue, "before")
    }

    @MainActor
    private func makeWorkspace() throws -> PDFWorkspaceState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberPDF-Comparison-Teardown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.pdf")
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 400, height: 600), for: .mediaBox)
        document.insert(page, at: 0)
        XCTAssertTrue(document.write(to: url))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        return workspace
    }
}

private final class AnnotationReadProbePage: PDFPage {
    var annotationReadCount = 0

    override var annotations: [PDFAnnotation] {
        annotationReadCount += 1
        return super.annotations
    }
}
