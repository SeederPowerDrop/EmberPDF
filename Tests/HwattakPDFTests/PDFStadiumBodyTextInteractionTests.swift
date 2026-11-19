// SPDX-License-Identifier: MPL-2.0

import AppKit
import CryptoKit
import PDFKit
import XCTest
@testable import HwattakPDF

/// The reported book remains outside the repository. Every write targets a
/// disposable copy, including the full-book save/reopen check.
@MainActor
final class PDFStadiumBodyTextInteractionTests: XCTestCase {
    func testPage184DragThenTextButtonEditsAcrossLanguagesAndPreservesTheBook() async throws {
        guard let path = ProcessInfo.processInfo.environment["EMBER_STADIUM_PDF"], path.hasPrefix("/") else {
            throw XCTSkip("Set EMBER_STADIUM_PDF to the reported German stadium book.")
        }
        _ = NSApplication.shared
        let source = URL(fileURLWithPath: path)
        let sourceHash = try hash(source)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-stadium-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("Stadium-test-copy.pdf")
        try FileManager.default.copyItem(at: source, to: copy)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: copy))
        defer { workspace.closeDiscardingChanges() }
        let document = try XCTUnwrap(workspace.document)
        XCTAssertEqual(document.pageCount, 408)
        let page = try XCTUnwrap(document.page(at: 183))
        let originalText = try XCTUnwrap(page.string)
        let originalSnapshot = try PDFBodyTextPageSnapshot.data(for: page)
        let unaffectedIndices = [0, 182, 184, 407]
        let unaffectedSnapshots = try unaffectedIndices.map {
            try PDFBodyTextPageSnapshot.data(for: XCTUnwrap(document.page(at: $0)))
        }
        let first = (originalText as NSString).range(of: "einschränkten")
        let last = (originalText as NSString).range(of: "Arminia-Präsident", options: [],
            range: NSRange(location: first.location, length: (originalText as NSString).length - first.location))
        XCTAssertNotEqual(first.location, NSNotFound)
        XCTAssertNotEqual(last.location, NSNotFound)
        let selectedRange = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let referenceSelection = try XCTUnwrap(page.selection(for: selectedRange))
        let expectedSelection = try XCTUnwrap(referenceSelection.string)
        let firstGlyph = try XCTUnwrap(page.selection(for: NSRange(location: first.location, length: 1)))
            .bounds(for: page)
        let lastGlyph = try XCTUnwrap(page.selection(for: NSRange(location: NSMaxRange(last) - 1, length: 1)))
            .bounds(for: page)
        let start = CGPoint(x: firstGlyph.minX + 0.05, y: firstGlyph.midY)
        let end = CGPoint(x: lastGlyph.maxX - 0.05, y: lastGlyph.midY)
        workspace.setCurrentPage(183)
        workspace.setMode(.editing)
        workspace.activeTool = .select
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.document = document
        view.displayMode = .singlePage
        view.autoScales = false
        view.scaleFactor = 1.1
        view.go(to: page)
        view.configure(with: workspace)
        let coordinator = PDFKitViewer.Coordinator(state: workspace, viewportContext: .normal)
        coordinator.attach(to: view)
        defer {
            workspace.cancelPendingInlineText()
            view.finishNativeSelectionPreview()
            coordinator.detach()
            view.regionSelection.cancel()
            view.prepareInlineTextEditingOverlayForRemoval()
            view.prepareAnnotationEditingOverlayForRemoval()
            view.workspaceState = nil
            view.document = nil
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(view)
        let dragged = try event(.leftMouseDragged, at: end, in: view, page: page)
        let released = try event(.leftMouseUp, at: end, in: view, page: page)
        // PDFKit's native mouseDown enters a tracking loop and consumes the
        // following events itself. Enqueue the complete gesture before entry.
        NSApplication.shared.postEvent(released, atStart: true)
        NSApplication.shared.postEvent(dragged, atStart: true)
        view.mouseDown(with: try event(.leftMouseDown, at: start, in: view, page: page))
        view.mouseUp(with: released)
        await drainMainQueue()
        let selection = try XCTUnwrap(workspace.currentSelection)
        XCTAssertEqual(normalized(selection.string), normalized(expectedSelection))
        XCTAssertNil(workspace.pendingInlineTextEdit)
        let editorStarted = ProcessInfo.processInfo.systemUptime
        workspace.selectTool(.text)
        XCTAssertNil(workspace.presentedError)
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit,
            "The reported four-line drag must open a body editor rather than an unsupported alert.")
        let editorSeconds = ProcessInfo.processInfo.systemUptime - editorStarted
        XCTAssertEqual(draft.purpose, .bodyText)
        XCTAssertEqual(draft.pageIndex, 183)
        XCTAssertEqual(normalized(draft.text), normalized(expectedSelection))
        view.configure(with: workspace)
        view.revealPendingBodyTextSelection()
        await drainMainQueue()
        let panel = try XCTUnwrap(descendant(PDFInlineTextEditorPanel.self, in: view))
        XCTAssertTrue(window.firstResponder === panel.textView)
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.object(forKey: AppPreferences.languageDefaultsKey)
        defer {
            if let previousLanguage { defaults.set(previousLanguage, forKey: AppPreferences.languageDefaultsKey) }
            else { defaults.removeObject(forKey: AppPreferences.languageDefaultsKey) }
        }
        let preferences = AppPreferences(defaults: defaults, appearanceDidChange: { _ in })
        for language in AppLanguage.allCases {
            preferences.language = language
            workspace.refreshLocalization()
            view.configure(with: workspace)
            XCTAssertEqual(L10n.currentLanguage, language)
            XCTAssertEqual(workspace.pendingInlineTextEdit?.id, draft.id)
            XCTAssertEqual(panel.currentText, draft.text)
            XCTAssertNil(workspace.presentedError)
            XCTAssertFalse(workspace.isDirty)
        }
        preferences.language = .korean
        workspace.refreshLocalization()
        view.configure(with: workspace)
        let replacement = draft.text.replacingOccurrences(of: "einschränkten", with: "begrenzten")
        panel.textView.setSelectedRange(NSRange(location: 0, length: (draft.text as NSString).length))
        panel.textView.insertText(replacement, replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(panel.currentText, replacement)
        if let destination = ProcessInfo.processInfo.environment["EMBER_STADIUM_QA_DIRECTORY"] {
            try capture(view, name: "stadium-page184-editor", directory: destination)
        }
        let commitStarted = ProcessInfo.processInfo.systemUptime
        view.commitInlineTextEditorBeforePointerAction()
        let commitSeconds = ProcessInfo.processInfo.systemUptime - commitStarted
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertNil(workspace.presentedError)
        XCTAssertTrue(workspace.isDirty)
        let changed = try XCTUnwrap(workspace.document?.page(at: 183))
        XCTAssertTrue(changed.string?.contains("begrenzten") == true)
        XCTAssertFalse(changed.string?.contains("einschränkten") == true)
        XCTAssertTrue(changed.annotations.isEmpty)
        if let destination = ProcessInfo.processInfo.environment["EMBER_STADIUM_QA_DIRECTORY"] {
            let output = URL(fileURLWithPath: destination, isDirectory: true)
            try originalSnapshot.write(to: output.appendingPathComponent("stadium-page184-before.pdf"))
            try PDFBodyTextPageSnapshot.data(for: changed)
                .write(to: output.appendingPathComponent("stadium-page184-committed.pdf"))
        }
        let exclusion = draft.bounds.insetBy(dx: -5, dy: -5)
        XCTAssertEqual(try pixels(page, excluding: exclusion), try pixels(changed, excluding: exclusion),
            "Every rendered pixel outside the selected text region must remain identical.")
        for phrase in ["Holzpfeiler", "Otto Höxtermann", "Oberliga Nord-Rekord", "Hausmannskost"] {
            XCTAssertEqual(searchCount(phrase, page: changed), searchCount(phrase, page: page), phrase)
            XCTAssertGreaterThan(searchCount(phrase, page: page), 0)
        }
        let saveStarted = ProcessInfo.processInfo.systemUptime
        let saved = await workspace.saveAsynchronously()
        XCTAssertTrue(saved, workspace.presentedError ?? "save failed")
        let saveSeconds = ProcessInfo.processInfo.systemUptime - saveStarted
        let sourceBytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let savedBytes = try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertLessThan(savedBytes, sourceBytes * 7 / 4,
            "A four-line scan edit must not expand hundreds of decoded image masks into a huge book.")
        let reopened = try XCTUnwrap(PDFDocument(url: copy))
        XCTAssertEqual(reopened.pageCount, 408)
        let reopenedPage = try XCTUnwrap(reopened.page(at: 183))
        XCTAssertTrue(reopenedPage.string?.contains("begrenzten") == true)
        XCTAssertFalse(reopenedPage.string?.contains("einschränkten") == true)
        XCTAssertEqual(try pixels(changed, excluding: .null), try pixels(reopenedPage, excluding: .null))
        for (index, before) in zip(unaffectedIndices, unaffectedSnapshots) {
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: XCTUnwrap(reopened.page(at: index))), before,
                "Saving must preserve the source graph of untouched page \(index + 1).")
        }
        workspace.undo()
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: XCTUnwrap(workspace.document?.page(at: 183))), originalSnapshot)
        workspace.redo()
        XCTAssertTrue(workspace.document?.page(at: 183)?.string?.contains("begrenzten") == true)
        XCTAssertNil(workspace.presentedError)
        XCTAssertEqual(try hash(source), sourceHash)
        if let destination = ProcessInfo.processInfo.environment["EMBER_STADIUM_QA_DIRECTORY"] {
            let output = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try originalSnapshot.write(to: output.appendingPathComponent("stadium-page184-before.pdf"))
            try PDFBodyTextPageSnapshot.data(for: reopenedPage).write(to: output.appendingPathComponent("stadium-page184-after.pdf"))
            let savedBook = output.appendingPathComponent("stadium-edited-book.pdf")
            if FileManager.default.fileExists(atPath: savedBook.path) { try FileManager.default.removeItem(at: savedBook) }
            try FileManager.default.copyItem(at: copy, to: savedBook)
            let report: [String: Any] = ["pageCount": document.pageCount, "humanPage": 184,
                "selectedLines": selection.selectionsByLine().count, "languages": AppLanguage.allCases.map(\.rawValue),
                "editorSeconds": editorSeconds, "commitSeconds": commitSeconds, "saveSeconds": saveSeconds,
                "sourceBytes": sourceBytes, "savedBytes": savedBytes,
                "outsidePixelsIdentical": true, "untouchedPages": unaffectedIndices.map { $0 + 1 },
                "sourceSHA256": sourceHash.map { String(format: "%02x", $0) }.joined()]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("stadium-interaction-report.json"))
        }
    }

    private func normalized(_ text: String?) -> String {
        (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func hash(_ url: URL) throws -> SHA256.Digest {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    private func searchCount(_ text: String, page: PDFPage) -> Int {
        let document = PDFDocument()
        document.insert(page.copy() as! PDFPage, at: 0)
        return document.findString(text, withOptions: []).count
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint,
                       in view: InteractivePDFView, page: PDFPage) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type,
            location: view.convert(view.convert(point, from: page), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = descendant(type, in: child) { return match }
        }
        return nil
    }

    private func capture(_ view: NSView, name: String, directory: String) throws {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent(name + ".png"))
    }

    private func pixels(_ page: PDFPage, excluding rectangle: CGRect) throws -> Data {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(ceil(bounds.width * 2)), height = Int(ceil(bounds.height * 2))
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: 2, y: 2)
            context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        var result = Data(capacity: bytes.count)
        for y in 0..<height {
            let offset = (height - y - 1) * width * 4
            if !rectangle.isNull, CGFloat(y) / 2 >= rectangle.minY, CGFloat(y) / 2 < rectangle.maxY {
                let first = min(width, max(0, Int(ceil(rectangle.minX * 2))))
                let last = min(width, max(first, Int(ceil(rectangle.maxX * 2))))
                result.append(contentsOf: bytes[offset..<offset + first * 4])
                result.append(contentsOf: bytes[(offset + last * 4)..<(offset + width * 4)])
            } else {
                result.append(contentsOf: bytes[offset..<(offset + width * 4)])
            }
        }
        return result
    }
}
