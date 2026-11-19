// SPDX-License-Identifier: MPL-2.0
import AppKit
import CryptoKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextOutlineDestinationTests: XCTestCase {
    private struct View {
        let mode: String
        let operands: [Double?]
        var program: String { mode + " " + operands.map { $0.map { String($0) } ?? "null" }.joined(separator: " ") }
    }
    private var views: [View] { [
        View(mode: "Fit", operands: []), View(mode: "FitH", operands: [1575]),
        View(mode: "FitV", operands: [21]), View(mode: "FitR", operands: [10, 20, 80, 90]),
        View(mode: "FitB", operands: []), View(mode: "FitBH", operands: [nil]),
        View(mode: "FitBV", operands: [35.5]), View(mode: "XYZ", operands: [nil, 288, 1.5])
    ] }

    func testAllViewModesSurviveBodyReplacementSaveUndoRedoAndReopen() throws {
        let (workspace, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document), original = try XCTUnwrap(document.page(at: 0))
        try commitBody(in: workspace)
        let replacement = try XCTUnwrap(document.page(at: 0))
        XCTAssertFalse(original === replacement)
        for index in views.indices { XCTAssertTrue(document.outlineRoot?.child(at: index)?.destination?.page === replacement) }
        XCTAssertTrue(workspace.saveSynchronously())
        try assertViews(at: url, expected: views)
        workspace.undo()
        XCTAssertTrue(document.page(at: 0) === original)
        XCTAssertTrue(workspace.saveSynchronously())
        try assertViews(at: url, expected: views)
        workspace.redo()
        XCTAssertTrue(document.page(at: 0) === replacement)
        XCTAssertTrue(workspace.saveSynchronously())
        try assertViews(at: url, expected: views)
    }

    func testCurrentBookmarkEditBeforeFirstCaptureWinsOverOriginalNativeMode() throws {
        let (workspace, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document), page = try XCTUnwrap(document.page(at: 0))
        let outline = try XCTUnwrap(document.outlineRoot?.child(at: 1))
        let destination = PDFDestination(page: page, at: CGPoint(x: 17, y: 39)); destination.zoom = 2
        outline.destination = destination
        try commitBody(in: workspace)
        XCTAssertTrue(workspace.saveSynchronously())
        var expected = views; expected[1] = View(mode: "XYZ", operands: [17, 39, 2])
        try assertViews(at: url, expected: expected)
    }

    func testExplicitSamePointBookmarkReplacementAfterCaptureWins() throws {
        let (workspace, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try commitBody(in: workspace)
        let document = try XCTUnwrap(workspace.document), page = try XCTUnwrap(document.page(at: 0))
        let outline = try XCTUnwrap(document.outlineRoot?.child(at: 1)), previous = try XCTUnwrap(outline.destination)
        // PDFKit exposes no FitH top through point/zoom. An explicit XYZ with
        // identical public values must not resurrect the earlier FitH mode.
        let explicit = PDFDestination(page: page, at: previous.point); explicit.zoom = previous.zoom
        outline.destination = explicit
        let plan = try PDFCatalogStructurePreserver.plan(for: document)
        XCTAssertNil(plan.outlineDestinations[[1]])
        XCTAssertTrue(workspace.saveSynchronously())
        var expected = views; expected[1] = View(mode: "XYZ", operands: [nil, nil, nil])
        try assertViews(at: url, expected: expected)
    }

    func testCaptureUsesCurrentOutlineObjectsAfterReordering() throws {
        let (workspace, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let root = try XCTUnwrap(workspace.document?.outlineRoot), moved = try XCTUnwrap(root.child(at: 1))
        moved.removeFromParent(); root.insertChild(moved, at: root.numberOfChildren)
        try commitBody(in: workspace)
        XCTAssertTrue(workspace.saveSynchronously())
        var expected = views; expected.append(expected.remove(at: 1))
        try assertViews(at: url, expected: expected)
    }

    func testLiveExtractionAfterBodyReplacementKeepsReboundOutlineModes() throws {
        let (workspace, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try commitBody(in: workspace)
        let document = try XCTUnwrap(workspace.document)
        let extracted = try PDFPageOperations.extract(from: document, indexes: [0])
        let repeated = try PDFPageOperations.extract(from: extracted, indexes: [0])
        let output = url.deletingLastPathComponent().appendingPathComponent("extracted.pdf")
        try AtomicPDFWriter.write(repeated, to: output)
        try assertViews(at: output, expected: views)
    }

    func testOnlyDestinationsWithVerifiedPageLineageCanInheritViewMode() throws {
        let (workspace, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        try PDFCatalogStructurePreserver.prepare(document)
        let outline = try XCTUnwrap(document.outlineRoot?.child(at: 1)), before = try XCTUnwrap(outline.destination)
        let unrelated = PDFDestination(page: try XCTUnwrap(document.page(at: 1)), at: before.point); unrelated.zoom = before.zoom
        PDFCatalogStructurePreserver.rebindOutlineDestination(outline, from: before, to: unrelated)
        outline.destination = unrelated
        XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: document).outlineDestinations[[1]])
    }

    func testPreparingUntouchedNavigationDoesNotReplaceSerializedActions() throws {
        let (workspace, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try XCTUnwrap(workspace.document)
        try PDFCatalogStructurePreserver.prepare(document)
        XCTAssertTrue(try PDFCatalogStructurePreserver.plan(for: document).outlineDestinations.isEmpty)
        try PDFCatalogStructurePreserver.prepare(document)
        XCTAssertTrue(try PDFCatalogStructurePreserver.plan(for: document).outlineDestinations.isEmpty)
    }

    func testPrivateFullBookWorkspaceSavesKeepEveryOutlineView() throws {
        guard let path = ProcessInfo.processInfo.environment["EMBER_BODY_OUTLINE_REPLAY_MANIFEST"] else {
            throw XCTSkip("Set EMBER_BODY_OUTLINE_REPLAY_MANIFEST for read-only private full-book replay inputs.")
        }
        let manifest = try JSONDecoder().decode(ReplayManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(manifest.cases.count, 2)
        let directory = URL(fileURLWithPath: manifest.outputDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var results: [[String: Any]] = []
        for entry in manifest.cases {
            let source = URL(fileURLWithPath: entry.source), bytes = try Data(contentsOf: source)
            let beforeHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(beforeHash, entry.sha256)
            let input = directory.appendingPathComponent(entry.id + "-input.pdf")
            try bytes.write(to: input, options: .withoutOverwriting)
            let original = try XCTUnwrap(PDFDocument(url: input))
            let expectedOutlines = try outlineSnapshot(original)
            let expectedRemoteActions = try remoteActionSnapshot(original)
            let originalPage = try XCTUnwrap(original.page(at: entry.page - 1))
            let originalText = compact(try XCTUnwrap(originalPage.string))
            let old = compact(entry.oldText)
            XCTAssertEqual(originalText.components(separatedBy: old).count, 2)
            var currentInput = input
            var stages: [[String: Any]] = []
            for (index, text) in [entry.newText, entry.againText].enumerated() {
                let workspace = PDFWorkspaceState()
                XCTAssertTrue(workspace.open(url: currentInput)); workspace.setMode(.editing)
                let document = try XCTUnwrap(workspace.document), page = try XCTUnwrap(document.page(at: entry.page - 1))
                let selected = index == 0 ? entry.oldText : entry.newText
                let coordinates = entry.bounds
                guard coordinates.count == 4 else { throw NSError(domain: "OutlineReplay", code: 1) }
                let bounds = CGRect(x: coordinates[0], y: coordinates[1], width: coordinates[2] - coordinates[0], height: coordinates[3] - coordinates[1])
                let selection = PDFRegionTextSelection(document: document, page: page,
                    fragments: [PDFRegionTextFragment(text: selected, bounds: bounds)])
                XCTAssertTrue(workspace.requestBodyTextEdit(selection: selection, preservesSelectionTool: false))
                let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
                XCTAssertEqual(compact(draft.text), compact(selected))
                workspace.commitPendingInlineText(id: draft.id, text: text, style: draft.style, bounds: draft.bounds)
                XCTAssertNil(workspace.presentedError); XCTAssertNil(workspace.pendingInlineTextEdit)
                let output = directory.appendingPathComponent(entry.id + (index == 0 ? "-after.pdf" : "-reedited.pdf"))
                let start = ProcessInfo.processInfo.systemUptime
                XCTAssertTrue(workspace.saveSynchronously(as: output), workspace.presentedError ?? "Save failed")
                let seconds = ProcessInfo.processInfo.systemUptime - start
                workspace.close()
                let reopened = try XCTUnwrap(PDFDocument(url: output)), reopenedPage = try XCTUnwrap(reopened.page(at: entry.page - 1))
                XCTAssertEqual(reopened.pageCount, original.pageCount)
                let outlines = try outlineSnapshot(reopened)
                let remoteActions = try remoteActionSnapshot(reopened)
                XCTAssertEqual(outlines, expectedOutlines, "All source bookmark view modes/operands must survive full-book workspace save")
                XCTAssertEqual(remoteActions, expectedRemoteActions, "Every original remote file/destination byte string must survive full-book workspace save")
                let expectedText = originalText.replacingOccurrences(of: old, with: compact(text))
                XCTAssertEqual(compact(try XCTUnwrap(reopenedPage.string)), expectedText)
                stages.append(["path": output.path, "saveSeconds": seconds, "outlineSnapshot": outlines,
                               "remoteActionSnapshot": remoteActions,
                               "nativeWholePageOrderExact": compact(reopenedPage.string ?? "") == expectedText,
                               "targetBounds": [draft.bounds.minX, draft.bounds.minY, draft.bounds.maxX, draft.bounds.maxY]])
                currentInput = output
            }
            let afterHash = SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(afterHash, beforeHash)
            results.append(["id": entry.id, "sourceSHA256": beforeHash, "sourceSHA256Unchanged": afterHash == beforeHash,
                            "pageCount": original.pageCount, "originalOutlineSnapshot": expectedOutlines,
                            "originalRemoteActionSnapshot": expectedRemoteActions, "stages": stages])
        }
        let data = try JSONSerialization.data(withJSONObject: ["cases": results], options: [.prettyPrinted, .sortedKeys])
        let report = directory.appendingPathComponent("results.json"); try data.write(to: report)
        print("Full-book outline workspace replay report: \(report.path)")
    }

    private struct ReplayManifest: Decodable {
        let outputDirectory: String
        let cases: [ReplayCase]
    }
    private struct ReplayCase: Decodable {
        let id: String, source: String, sha256: String, oldText: String, newText: String, againText: String
        let page: Int
        let bounds: [Double]
    }
    private func compact(_ text: String) -> String {
        String(text.precomposedStringWithCanonicalMapping.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }
    private func remoteActionSnapshot(_ document: PDFDocument) throws -> String {
        let native = try XCTUnwrap(document.documentRef)
        func signature(_ object: CGPDFObjectRef, depth: Int = 0) throws -> String {
            guard depth < 16 else { throw PDFPageStructurePreserver.Failure.tooComplex }
            switch CGPDFObjectGetType(object) {
            case .null: return "null"
            case .boolean:
                var value: CGPDFBoolean = 0; _ = CGPDFObjectGetValue(object, .boolean, &value)
                return value == 0 ? "false" : "true"
            case .integer:
                var value: CGPDFInteger = 0; _ = CGPDFObjectGetValue(object, .integer, &value)
                return String(format: "n%.8f", Double(value))
            case .real:
                var value: CGPDFReal = 0; _ = CGPDFObjectGetValue(object, .real, &value)
                return String(format: "n%.8f", Double(value))
            case .name:
                var value: UnsafePointer<CChar>?; _ = CGPDFObjectGetValue(object, .name, &value)
                return "/" + String(cString: try XCTUnwrap(value))
            case .string:
                var value: CGPDFStringRef?; _ = CGPDFObjectGetValue(object, .string, &value)
                let string = try XCTUnwrap(value), count = CGPDFStringGetLength(string)
                guard count <= 1_048_576 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                let bytes = count == 0 ? Data() : Data(bytes: try XCTUnwrap(CGPDFStringGetBytePtr(string)), count: count)
                return "<" + bytes.map { String(format: "%02x", $0) }.joined() + ">"
            case .array:
                var value: CGPDFArrayRef?; _ = CGPDFObjectGetValue(object, .array, &value)
                let array = try XCTUnwrap(value); guard CGPDFArrayGetCount(array) <= 1_024 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                var values: [String] = [], failure: Error?
                CGPDFArrayApplyBlock(array, { _, value, _ in
                    do { values.append(try signature(value, depth: depth + 1)); return true }
                    catch { failure = error; return false }
                }, nil)
                if let failure { throw failure }; return "[" + values.joined(separator: ",") + "]"
            case .dictionary:
                var value: CGPDFDictionaryRef?; _ = CGPDFObjectGetValue(object, .dictionary, &value)
                let dictionary = try XCTUnwrap(value); guard CGPDFDictionaryGetCount(dictionary) <= 64 else { throw PDFPageStructurePreserver.Failure.tooComplex }
                var values: [String: String] = [:], failure: Error?
                CGPDFDictionaryApplyBlock(dictionary, { key, value, _ in
                    do { values[String(cString: key)] = try signature(value, depth: depth + 1); return true }
                    catch { failure = error; return false }
                }, nil)
                if let failure { throw failure }
                return String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self)
            default: throw PDFPageStructurePreserver.Failure.unsupportedStructure
            }
        }
        var rows: [[String: Any]] = []
        for index in 0..<native.numberOfPages {
            guard let page = native.page(at: index + 1)?.dictionary,
                  let annotations = PDFCatalogStructurePreserver.array(page, "Annots") else { continue }
            var failure: Error?
            CGPDFArrayApplyBlock(annotations, { annotationIndex, value, _ in
                var annotation: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(value, .dictionary, &annotation), let annotation,
                      let action = PDFCatalogStructurePreserver.dictionary(annotation, "A") else { return true }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(action, "S", &subtype), let subtype, String(cString: subtype) == "GoToR",
                      let object = PDFCatalogStructurePreserver.object(annotation, "A") else { return true }
                do { rows.append(["page": index, "annotation": annotationIndex, "action": try signature(object)]); return true }
                catch { failure = error; return false }
            }, nil)
            if let failure { throw failure }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self)
    }
    /// Native snapshots compare destination semantics rather than PDF object
    /// numbers, which necessarily change during a full-document save.
    private func outlineSnapshot(_ document: PDFDocument) throws -> String {
        let native = try XCTUnwrap(document.documentRef), catalog = try XCTUnwrap(native.catalog)
        guard let root = PDFCatalogStructurePreserver.dictionary(catalog, "Outlines") else { return "[]" }
        var pageIndexes: [UInt: Int] = [:]
        for index in 0..<native.numberOfPages {
            pageIndexes[pdfReferenceIdentity(try XCTUnwrap(native.page(at: index + 1)?.dictionary))] = index
        }
        var rows: [[String: Any]] = [], seen = Set<UInt>()
        func walk(_ first: CGPDFDictionaryRef?, path: [Int]) throws {
            var next = first, index = 0
            while let node = next {
                guard path.count < 64, seen.insert(pdfReferenceIdentity(node)).inserted, seen.count <= 100_000 else {
                    throw PDFPageStructurePreserver.Failure.tooComplex
                }
                let currentPath = path + [index]
                var title: CGPDFStringRef?, flags: CGPDFInteger = 0
                _ = CGPDFDictionaryGetString(node, "Title", &title); _ = CGPDFDictionaryGetInteger(node, "F", &flags)
                var row: [String: Any] = ["path": currentPath, "title": title.flatMap(CGPDFStringCopyTextString).map { $0 as String } ?? "", "flags": flags]
                func number(_ array: CGPDFArrayRef, _ index: Int) -> String {
                    var value: CGPDFReal = 0
                    return index < CGPDFArrayGetCount(array) && CGPDFArrayGetNumber(array, index, &value)
                        ? String(format: "%.6f", Double(value)) : "null"
                }
                if let color = PDFCatalogStructurePreserver.array(node, "C") {
                    row["color"] = (0..<CGPDFArrayGetCount(color)).map { number(color, $0) }
                }
                let action = PDFCatalogStructurePreserver.dictionary(node, "A")
                let destination = PDFCatalogStructurePreserver.array(node, "Dest") ?? action.flatMap { PDFCatalogStructurePreserver.array($0, "D") }
                if let destination {
                    var mode: UnsafePointer<CChar>?, target: CGPDFDictionaryRef?
                    guard CGPDFArrayGetName(destination, 1, &mode), let mode,
                          CGPDFArrayGetDictionary(destination, 0, &target), let target,
                          let pageIndex = pageIndexes[pdfReferenceIdentity(target)] else { throw PDFPageStructurePreserver.Failure.invalidDestination }
                    let name = String(cString: mode), count = ["XYZ": 3, "Fit": 0, "FitH": 1, "FitV": 1, "FitR": 4, "FitB": 0, "FitBH": 1, "FitBV": 1][name]
                    guard let count else { throw PDFPageStructurePreserver.Failure.invalidDestination }
                    row["destination"] = ["page": pageIndex, "mode": name, "operands": (0..<count).map { number(destination, $0 + 2) }]
                }
                rows.append(row)
                try walk(PDFCatalogStructurePreserver.dictionary(node, "First"), path: currentPath)
                next = PDFCatalogStructurePreserver.dictionary(node, "Next"); index += 1
            }
        }
        try walk(PDFCatalogStructurePreserver.dictionary(root, "First"), path: [])
        return String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self)
    }

    private func commitBody(in workspace: PDFWorkspaceState) throws {
        XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        XCTAssertEqual(draft.text, "Original body")
        workspace.commitPendingInlineText(id: draft.id, text: "Updated body", style: draft.style, bounds: draft.bounds)
        XCTAssertNil(workspace.presentedError)
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertEqual(workspace.document?.findString("Updated body", withOptions: []).count, 1)
    }

    private func assertViews(at url: URL, expected: [View]) throws {
        let document = try XCTUnwrap(PDFDocument(url: url)), native = try XCTUnwrap(document.documentRef)
        let outlines = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(try XCTUnwrap(native.catalog), "Outlines"))
        var node = PDFCatalogStructurePreserver.dictionary(outlines, "First")
        XCTAssertEqual(document.outlineRoot?.numberOfChildren, expected.count)
        for view in expected {
            let item = try XCTUnwrap(node), array = try XCTUnwrap(PDFCatalogStructurePreserver.array(item, "Dest"))
            XCTAssertEqual(CGPDFArrayGetCount(array), view.operands.count + 2)
            var mode: UnsafePointer<CChar>?, page: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFArrayGetName(array, 1, &mode))
            XCTAssertEqual(String(cString: try XCTUnwrap(mode)), view.mode)
            XCTAssertTrue(CGPDFArrayGetDictionary(array, 0, &page))
            XCTAssertEqual(pdfReferenceIdentity(try XCTUnwrap(page)), pdfReferenceIdentity(try XCTUnwrap(native.page(at: 1)?.dictionary)))
            for (index, expected) in view.operands.enumerated() {
                if let expected {
                    var value: CGPDFReal = 0
                    XCTAssertTrue(CGPDFArrayGetNumber(array, index + 2, &value)); XCTAssertEqual(Double(value), expected, accuracy: 0.000001)
                } else {
                    var value: CGPDFObjectRef?
                    XCTAssertTrue(CGPDFArrayGetObject(array, index + 2, &value)); XCTAssertEqual(CGPDFObjectGetType(try XCTUnwrap(value)), .null)
                }
            }
            node = PDFCatalogStructurePreserver.dictionary(item, "Next")
        }
        XCTAssertNil(node)
    }

    private func fixture() throws -> (PDFWorkspaceState, URL) {
        let content = "BT /F1 20 Tf 40 300 Td (Original body) Tj ET"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 420] /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 420] /Resources << >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Outlines /First 8 0 R /Last \(7 + views.count) 0 R /Count \(views.count) >>"
        ]
        for (index, view) in views.enumerated() {
            let previous = index > 0 ? "/Prev \(index + 7) 0 R" : ""
            let next = index + 1 < views.count ? "/Next \(index + 9) 0 R" : ""
            objects.append("<< /Title (View \(index)) /Parent 7 0 R \(previous) \(next) /Dest [3 0 R /\(view.program)] >>")
        }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-body-outline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("body.pdf"); try data.write(to: url)
        let workspace = PDFWorkspaceState(); XCTAssertTrue(workspace.open(url: url)); workspace.setMode(.editing)
        return (workspace, url)
    }
}
