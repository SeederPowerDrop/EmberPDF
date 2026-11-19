// SPDX-License-Identifier: MPL-2.0

import AppKit
import CPDFium
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextSelectionTests: XCTestCase {
    func testNativePhrasePreservesPrefixSuffixAndUnrelatedContent() throws {
        let document = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString("chosen phrase", withOptions: []).first)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        let range = try XCTUnwrap(target.initialSelectedRange)
        XCTAssertEqual((target.text as NSString).substring(with: range), "chosen phrase")
        XCTAssertEqual(target.text, "Before chosen phrase after")
        let replacement = (target.text as NSString).replacingCharacters(in: range, with: "revised")
        let result = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: replacement, style: target.style, bounds: target.bounds)
        XCTAssertTrue(result.string?.contains("Before revised after") == true)
        XCTAssertTrue(result.string?.contains("Unrelated caption") == true)
        XCTAssertFalse(result.string?.contains("chosen phrase") == true)
        XCTAssertTrue(page.string?.contains("chosen phrase") == true)
    }

    func testRegionGeometryDoesNotPullInCaptionWithSameWords() throws {
        let document = try fixture(caption: "chosen phrase")
        let page = try XCTUnwrap(document.page(at: 0))
        let source = try XCTUnwrap(document.findString("chosen phrase", withOptions: [])
            .first(where: { $0.bounds(for: page).minY > 200 }))
        let selection = PDFRegionTextSelection(document: document, page: page,
            fragments: [.init(text: "chosen phrase", bounds: source.bounds(for: page))])
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        let range = try XCTUnwrap(target.initialSelectedRange)
        let result = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: (target.text as NSString).replacingCharacters(in: range, with: "new words"),
            style: target.style, bounds: target.bounds)
        let reopened = PDFDocument()
        reopened.insert(result, at: 0)
        XCTAssertEqual(reopened.findString("chosen phrase", withOptions: []).count, 1)
        XCTAssertEqual(reopened.findString("Before new words after", withOptions: []).count, 1)
    }

    func testCompatibleMultipleLinesKeepBothUnselectedEnds() throws {
        let document = try fixture(first: "Before chosen phrase", second: "continues after")
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try regionSelection(["chosen phrase", "continues"], document: document)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        let range = try XCTUnwrap(target.initialSelectedRange)
        XCTAssertEqual((target.text as NSString).substring(with: range), "chosen phrase\ncontinues")
        let result = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: (target.text as NSString).replacingCharacters(in: range, with: "new words"),
            style: target.style, bounds: target.bounds)
        let compact = (result.string ?? "").components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertTrue(compact.contains("Before new words after"))
        XCTAssertFalse(compact.contains("chosen"))
        XCTAssertFalse(compact.contains("continues"))
        XCTAssertTrue(compact.contains("Unrelated caption"))
    }

    func testPhraseAcrossCompatibleRunsIsNotTruncatedToFirstRun() throws {
        let document = try fixture(splitFirst: true)
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString("chosen phrase", withOptions: []).first)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        let range = try XCTUnwrap(target.initialSelectedRange)
        XCTAssertEqual((target.text as NSString).substring(with: range), "chosen phrase")
        XCTAssertEqual(target.text, "Before chosen phrase after")
        let result = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: (target.text as NSString).replacingCharacters(in: range, with: "revised"),
            style: target.style, bounds: target.bounds)
        XCTAssertTrue(result.string?.contains("Before revised after") == true)
        XCTAssertFalse(result.string?.contains("phrase") == true)
    }

    func testGeneratedMultilineTextCanBeSelectedAndEditedAgain() throws {
        let document = try fixture(first: "Before chosen phrase", second: "continues after")
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try regionSelection(["chosen phrase", "continues"], document: document)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        let result = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: "Before new words\ncontinue after", style: target.style, bounds: target.bounds)
        let edited = PDFDocument()
        edited.insert(result, at: 0)
        let nextSelection = try regionSelection(["new words", "continue"], document: edited)
        let nextTarget = try XCTUnwrap(PDFBodyTextEditor.target(on: result, selection: nextSelection))
        let nextRange = try XCTUnwrap(nextTarget.initialSelectedRange)
        XCTAssertEqual((nextTarget.text as NSString).substring(with: nextRange), "new words\ncontinue")
    }

    func testInterveningGraphicsRefuseWholeSelectionEvenWithCompatibleFonts() throws {
        for bold in [false, true] {
            let document = try fixture(first: "Before chosen phrase", second: "continues after",
                                       secondIsBold: bold, interveningGraphic: true)
            let page = try XCTUnwrap(document.page(at: 0))
            let selection = try regionSelection(["chosen phrase", "continues"], document: document)
            XCTAssertNil(try PDFBodyTextEditor.target(on: page, selection: selection))
            XCTAssertTrue(page.string?.contains("Before chosen phrase") == true)
            XCTAssertTrue(page.string?.contains("continues after") == true)
        }
    }

    func testCompatibleBoldLineKeepsItsFontWhenEarlierTextChanges() throws {
        let document = try fixture(first: "Before chosen phrase", second: "continues after", secondIsBold: true)
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try regionSelection(["chosen phrase", "continues"], document: document)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: target.text.replacingOccurrences(of: "chosen", with: "edited"),
            style: target.style, bounds: target.bounds)
        let result = PDFDocument()
        result.insert(edited, at: 0)
        let next = try XCTUnwrap(PDFBodyTextEditor.target(on: edited,
            selection: regionSelection(["edited phrase", "continues"], document: result)))
        let bold = try XCTUnwrap(next.sourceRuns.first { $0.style.fontName == "Helvetica-Bold" })
        XCTAssertTrue((next.text as NSString).substring(with: bold.range).contains("continues after"))
        XCTAssertEqual(bold.style.fontSize, 18, accuracy: 0.01)
    }

    func testRegionTextMismatchNeverEditsAConvenientNearbyObject() throws {
        let document = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let native = try XCTUnwrap(document.findString("chosen phrase", withOptions: []).first)
        let selection = PDFRegionTextSelection(document: document, page: page,
            fragments: [.init(text: "chosen phrase and absent words", bounds: native.bounds(for: page))])
        XCTAssertNil(try PDFBodyTextEditor.target(on: page, selection: selection))
    }

    func testDragDraftCancelCommitAndUndoKeepOrdinarySelectionTool() throws {
        let source = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("selection.pdf")
        XCTAssertTrue(source.write(to: url))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        let document = try XCTUnwrap(workspace.document)
        let original = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString("chosen phrase", withOptions: []).first)
        workspace.currentSelection = selection
        XCTAssertFalse(workspace.requestBodyTextEdit(selection: selection), "Viewer does not enter editing")
        workspace.setMode(.study)
        XCTAssertFalse(workspace.requestBodyTextEdit(selection: selection), "Study selection remains selection")
        workspace.setMode(.editing)
        XCTAssertTrue(workspace.requestBodyTextEdit(selection: selection))
        XCTAssertEqual(workspace.activeTool, .select)
        workspace.cancelPendingInlineText()
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertTrue(document.page(at: 0) === original)

        XCTAssertTrue(workspace.requestBodyTextEdit(selection: selection))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        let range = try XCTUnwrap(draft.initialSelectedRange)
        XCTAssertEqual((draft.text as NSString).substring(with: range), "chosen phrase")
        workspace.commitPendingInlineText(id: draft.id,
            text: (draft.text as NSString).replacingCharacters(in: range, with: "revised"),
            style: draft.style, bounds: draft.bounds)
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertEqual(workspace.activeTool, .select)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Before revised after") == true)
        workspace.undo()
        XCTAssertTrue(document.page(at: 0) === original)
        XCTAssertFalse(workspace.isDirty)
        workspace.redo()
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Before revised after") == true)
    }

    func testSwitchingToolSettlesAutomaticallyOpenedDraft() throws {
        let source = try fixture()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drag-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(source.write(to: url))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.editing)
        let document = try XCTUnwrap(workspace.document)
        let selection = try XCTUnwrap(document.findString("chosen phrase", withOptions: []).first)
        XCTAssertTrue(workspace.requestBodyTextEdit(selection: selection))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        let range = try XCTUnwrap(draft.initialSelectedRange)
        workspace.updatePendingInlineTextDraft(id: draft.id,
            text: (draft.text as NSString).replacingCharacters(in: range, with: "revised"),
            style: draft.style, bounds: draft.bounds)
        workspace.activeTool = .pen
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertEqual(workspace.activeTool, .pen)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Before revised after") == true)
    }

    func testFailedAutomaticDraftKeepsToolAndDraftWithoutRecursiveSwitch() throws {
        let source = try fixture()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stale-drag-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(source.write(to: url))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.editing)
        let document = try XCTUnwrap(workspace.document)
        let selection = try XCTUnwrap(document.findString("chosen phrase", withOptions: []).first)
        XCTAssertTrue(workspace.requestBodyTextEdit(selection: selection))
        let original = try XCTUnwrap(document.page(at: 0))
        let copy = try XCTUnwrap(original.copy() as? PDFPage)
        document.removePage(at: 0)
        document.insert(copy, at: 0)
        workspace.activeTool = .pen
        XCTAssertEqual(workspace.activeTool, .select)
        XCTAssertNotNil(workspace.pendingInlineTextEdit)
        XCTAssertNotNil(workspace.presentedError)
        workspace.cancelPendingInlineText()
    }

    func testAdjacentUntouchedRowKeepsRawNativeSeparatorThroughTwoAtomicSaves() throws {
        for editingFirst in [false, true] {
            let first = editingFirst ? "Alpha first row" : "Keep first row"
            let second = editingFirst ? "Keep next row" : "Alpha next row"
            let source = try fixture(first: first, second: second)
            try assertRawSeparatorRoundtrip(source, selectedTerms: ["Alpha"],
                firstLine: first, secondLine: second, requireMultilineDraft: false,
                label: editingFirst ? "edited-before-neighbor" : "edited-after-neighbor")
        }
    }

    func testMultilineOwnedDonorKeepsRawNativeSeparatorsThroughTwoAtomicSaves() throws {
        let plain = try fixture(first: "Before chosen phrase", second: "continues after")
        let source = try separatorRowsInOneTextBlock(plain)
        try assertRawSeparatorRoundtrip(source, selectedTerms: ["chosen phrase", "continues"],
            firstLine: "Before chosen phrase", secondLine: "continues after", requireMultilineDraft: true,
            label: "two-row-owned-donor", editSource: "chosen", editReplacement: "choseo")
    }

    private func assertRawSeparatorRoundtrip(_ initial: PDFDocument, selectedTerms: [String],
        firstLine: String, secondLine: String, requireMultilineDraft: Bool, label: String,
        editSource: String = "Alpha", editReplacement: String = "Alpho") throws {
        let original = try XCTUnwrap(initial.page(at: 0))
        let originalContent = try PDFBodyTextPageSnapshot.contentData(for: original)
        let selected = try regionSelection(selectedTerms, document: initial)
        // Product target initializes the shared native library before the
        // independent public PDFium text getter below; no repeated InitLibrary.
        let prerequisite = try XCTUnwrap(PDFBodyTextEditor.target(on: original, selection: selected))
        XCTAssertEqual(prerequisite.text.components(separatedBy: editSource).count - 1, 1)
        if requireMultilineDraft { XCTAssertTrue(prerequisite.text.contains("\n")) }
        let originalKit = try XCTUnwrap(original.string), originalNative = try separatorNativeText(original)
        try requireSeparator(firstLine, secondLine, in: originalKit)
        try requireSeparator(firstLine, secondLine, in: originalNative)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ember-Native-Separator-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = initial
        for (cycle, pair) in [(editSource, editReplacement), (editReplacement, editSource)].enumerated() {
            let page = try XCTUnwrap(source.page(at: 0))
            let terms = selectedTerms.map { $0.replacingOccurrences(of: editSource, with: pair.0) }
            let selection = try regionSelection(terms, document: source)
            let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
            XCTAssertEqual(target.text.components(separatedBy: pair.0).count - 1, 1)
            if requireMultilineDraft { XCTAssertTrue(target.text.contains("\n")) }
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: target.text.replacingOccurrences(of: pair.0, with: pair.1),
                style: target.style, bounds: target.bounds)
            let expectedKit = cycle == 0 ? originalKit.replacingOccurrences(of: editSource, with: editReplacement) : originalKit
            let expectedNative = cycle == 0 ? originalNative.replacingOccurrences(of: editSource, with: editReplacement) : originalNative
            let liveKit = try XCTUnwrap(edited.string), liveNative = try separatorNativeText(edited)
            XCTAssertEqual(liveKit, expectedKit, "Live native PDFKit separator: \(label), cycle \(cycle)")
            XCTAssertEqual(liveNative, expectedNative, "Live PDFium separator: \(label), cycle \(cycle)")
            let stream = try PDFBodyTextContentStream.parse(PDFBodyTextPageSnapshot.contentData(for: edited))
            XCTAssertEqual(stream.forms.count, 1, "The fixture must exercise the new owned donor invocation.")
            source.removePage(at: 0)
            source.insert(edited, at: 0)
            let destination = directory.appendingPathComponent("cycle-\(cycle).pdf")
            try separatorAtomicSave(source, to: destination)
            source = try XCTUnwrap(PDFSourceFileAccess.loadDocument(at: destination).document)
            let cold = try XCTUnwrap(source.page(at: 0)), coldKit = try XCTUnwrap(cold.string)
            let coldNative = try separatorNativeText(cold)
            XCTAssertEqual(coldKit, expectedKit, "Cold PDFKit raw separator: \(label), cycle \(cycle)")
            XCTAssertEqual(coldNative, expectedNative, "Cold PDFium raw separator: \(label), cycle \(cycle)")
            XCTAssertEqual(source.findString("Unrelated caption", withOptions: []).count, 1)
            let next = try XCTUnwrap(PDFBodyTextEditor.target(on: cold,
                selection: regionSelection(selectedTerms.map { $0.replacingOccurrences(of: editSource, with: pair.1) }, document: source)))
            if requireMultilineDraft { XCTAssertTrue(next.text.contains("\n")) }
            if liveKit != expectedKit || liveNative != expectedNative || coldKit != expectedKit || coldNative != expectedNative {
                try separatorExport(source: original, saved: destination, label: label, cycle: cycle)
            }
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: original), originalContent)
    }

    private func separatorRowsInOneTextBlock(_ original: PDFDocument) throws -> PDFDocument {
        let page = try XCTUnwrap(original.page(at: 0))
        let content = try PDFBodyTextPageSnapshot.contentData(for: page)
        let blocks = try PDFBodyTextContentStream.parse(content).blocks
        guard blocks.count == 3 else { throw NSError(domain: "SeparatorFixtureBlockCount", code: 1) }
        let end = (blocks[0].range.upperBound - 2)..<blocks[0].range.upperBound
        let start = blocks[1].range.lowerBound..<(blocks[1].range.lowerBound + 2)
        guard content.subdata(in: end) == Data("ET".utf8), content.subdata(in: start) == Data("BT".utf8) else {
            throw NSError(domain: "SeparatorFixtureDelimiter", code: 1)
        }
        var joined = content
        for range in [end, start].sorted(by: { $0.lowerBound > $1.lowerBound }) {
            joined.replaceSubrange(range, with: Data("  ".utf8))
        }
        let parsed = try PDFBodyTextContentStream.parse(joined)
        XCTAssertEqual(parsed.blocks.count, 2)
        XCTAssertEqual(try XCTUnwrap(parsed.blocks.first).showRanges.count, 2)
        XCTAssertTrue(try XCTUnwrap(parsed.blocks.first).isSupported)
        let result = try XCTUnwrap(PDFDocument(data: PDFBodyTextPageSnapshot.data(for: page, contentOverride: joined)))
        XCTAssertEqual(try XCTUnwrap(result.page(at: 0)).string, page.string)
        return result
    }

    private func requireSeparator(_ first: String, _ second: String, in text: String) throws {
        let a = try XCTUnwrap(text.range(of: first)), b = try XCTUnwrap(text.range(of: second))
        XCTAssertLessThan(a.upperBound, b.lowerBound, "Owned rows must already be separate in the baseline reader.")
        guard a.upperBound < b.lowerBound else { throw NSError(domain: "SeparatorFixtureMissingRows", code: 1) }
        let gap = text[a.upperBound..<b.lowerBound]
        let hasNewline = gap.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
        let onlyWhitespace = gap.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        XCTAssertTrue(hasNewline, "Baseline newline prerequisite.")
        XCTAssertTrue(onlyWhitespace)
        guard hasNewline, onlyWhitespace else { throw NSError(domain: "SeparatorFixtureMissingNativeNewline", code: 1) }
    }

    private func separatorNativeText(_ page: PDFPage) throws -> String {
        let data = try PDFBodyTextPageSnapshot.data(for: page)
        return try data.withUnsafeBytes { bytes in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(document) }
            let native = try XCTUnwrap(FPDF_LoadPage(document, 0)); defer { FPDF_ClosePage(native) }
            let text = try XCTUnwrap(FPDFText_LoadPage(native)); defer { FPDFText_ClosePage(text) }
            let count = FPDFText_CountChars(text)
            guard count >= 0, count <= 10_000 else { throw NSError(domain: "SeparatorFixtureCharacterBudget", code: 1) }
            var buffer = [UInt16](repeating: 0, count: Int(count) + 2)
            let read = FPDFText_GetText(text, 0, count, &buffer)
            return String(decoding: buffer.prefix(max(0, Int(read) - 1)), as: UTF16.self)
        }
    }

    private final class SeparatorSaveCompletion: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0), lock = NSLock()
        private var result: Result<Void, Error>?
        func publish(_ value: Result<Void, Error>) { lock.lock(); result = value; lock.unlock(); ready.signal() }
        func take() -> Result<Void, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    }
    private func separatorAtomicSave(_ document: PDFDocument, to destination: URL) throws {
        let snapshot = try PDFRecoverySnapshot(capturing: document), completion = SeparatorSaveCompletion()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard !Thread.isMainThread else { throw NSError(domain: "SeparatorWriterMustBeOffMain", code: 1) }
                try AtomicPDFWriter.write(snapshot.takeDocument(), to: destination, allowDirectOverwriteFallback: false)
                completion.publish(.success(()))
            } catch { completion.publish(.failure(error)) }
        }
        let deadline = Date().addingTimeInterval(20)
        while completion.ready.wait(timeout: .now()) != .success {
            guard Date() < deadline else { throw NSError(domain: "SeparatorWriterTimeout", code: 1) }
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
        try XCTUnwrap(completion.take()).get()
    }
    private func separatorExport(source: PDFPage, saved: URL, label: String, cycle: Int) throws {
        guard let root = ProcessInfo.processInfo.environment["EMBER_BODY_SOURCE_QA_DIRECTORY"] else { return }
        let folder = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("newline-\(label)-\(cycle)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let before = try PDFBodyTextPageSnapshot.data(for: source)
        guard before.count <= 256 * 1024, (try saved.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 256 * 1024 else {
            throw NSError(domain: "SeparatorFixtureExportBudget", code: 1)
        }
        try before.write(to: folder.appendingPathComponent("before.pdf"), options: .withoutOverwriting)
        try FileManager.default.copyItem(at: saved, to: folder.appendingPathComponent("after.pdf"))
    }

    private func regionSelection(_ terms: [String], document: PDFDocument) throws -> PDFSelection {
        let page = try XCTUnwrap(document.page(at: 0))
        let fragments = try terms.map { term in
            let match = try XCTUnwrap(document.findString(term, withOptions: []).first)
            return PDFRegionTextFragment(text: term, bounds: match.bounds(for: page))
        }
        return PDFRegionTextSelection(document: document, page: page, fragments: fragments)
    }

    private func fixture(first: String = "Before chosen phrase after", second: String? = nil,
                         caption: String = "Unrelated caption", secondIsBold: Bool = false,
                         interveningGraphic: Bool = false, splitFirst: Bool = false) throws -> PDFDocument {
        var stream = "BT /F1 18 Tf 1 0 0 1 40 280 Tm (\(first)) Tj ET\n"
        if splitFirst {
            let font = try XCTUnwrap(NSFont(name: "Helvetica", size: 18))
            let x = 40 + ("Before chosen" as NSString).size(withAttributes: [.font: font]).width
            stream = "BT /F1 18 Tf 1 0 0 1 40 280 Tm (Before chosen) Tj ET\n"
                + "BT /F1 18 Tf 1 0 0 1 \(x) 280 Tm ( phrase after) Tj ET\n"
        }
        if interveningGraphic { stream += "q 0 0 1 rg 300 250 20 20 re f Q\n" }
        if let second { stream += "BT /\(secondIsBold ? "F2" : "F1") 18 Tf 1 0 0 1 40 258 Tm (\(second)) Tj ET\n" }
        stream += "BT /F1 18 Tf 1 0 0 1 40 100 Tm (\(caption)) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 400] /Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"
        ]
        var data = Data("%PDF-1.7\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return try XCTUnwrap(PDFDocument(data: data))
    }
}
