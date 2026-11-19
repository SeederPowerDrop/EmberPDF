// SPDX-License-Identifier: MPL-2.0
import AppKit
import CryptoKit
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

/// Explicitly opt-in, read-only original. Output belongs to the caller's new
/// WORK directory. Main extraction/capture and confined worker times separate.
@MainActor
final class PDFNativeStagingRealCorpusTests: XCTestCase {
    func testReal092SelectedAndUnchangedCGAnchorMerge() async throws {
        guard let path = ProcessInfo.processInfo.environment["EMBER_NATIVE_STAGING_ACTUAL_PLAN"] else { throw XCTSkip("Explicit bounded real-corpus plan required") }
        let planURL = URL(fileURLWithPath: path), config = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: planURL))
        guard config.id == "audit-092", config.selected == [0, 387, 774], config.expectedSHA256 == "56d7ba607ff25d79c67791e8e6a62365b4a7af800e4899578b85ffc6f3c24b9a" else { throw ProbeFailure.plan }
        let sourceURL = URL(fileURLWithPath: config.source), output = URL(fileURLWithPath: config.output)
        guard FileManager.default.fileExists(atPath: output.path) else { throw ProbeFailure.plan }
        let before = try PDFSourceFileVersion.capture(at: sourceURL)
        XCTAssertEqual(try Self.digest(sourceURL), config.expectedSHA256)
        Self.event("main-load.begin")
        let began = ProcessInfo.processInfo.systemUptime
        let source = try PDFSourceFileAccess.loadDocument(at: sourceURL).document
        XCTAssertEqual(source.pageCount, 775)
        Self.event("main-extract.begin")
        let extractionBegan = ProcessInfo.processInfo.systemUptime
        let extracted = try PDFPageOperations.extract(from: source, indexes: config.selected)
        let extractionSeconds = ProcessInfo.processInfo.systemUptime - extractionBegan
        Self.event("main-extract.end")
        let selected = try await saveSnapshot(extracted, stem: "selected", output: output)
        Self.event("main-realCG-anchor.begin")
        let storage = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: storage))
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let exactBytes = storage as Data
        let anchor = try XCTUnwrap(PDFDocument(data: exactBytes))
        PDFRawStreamProvenance.bindCreated(anchor, data: exactBytes)
        try exactBytes.write(to: output.appendingPathComponent("anchor-input.pdf"), options: .withoutOverwriting)
        let beforeAttributes = NSDictionary(dictionary: anchor.documentAttributes ?? [:])
        let imported = try PDFPageStructurePreserver.prepareImport(from: extracted, indexes: Array(0..<extracted.pageCount))
        let transaction = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: anchor, at: 1)
        try transaction.apply(); try transaction.undo(); XCTAssertEqual(anchor.pageCount, 1); try transaction.redo()
        let merged = try await saveSnapshot(anchor, stem: "merged", output: output)
        let reopened = try XCTUnwrap(PDFDocument(url: output.appendingPathComponent("merged.pdf")))
        XCTAssertEqual(reopened.pageCount, 4)
        XCTAssertTrue(NSDictionary(dictionary: reopened.documentAttributes ?? [:]).isEqual(to: beforeAttributes as! [AnyHashable: Any]))
        XCTAssertEqual(try PDFSourceFileVersion.capture(at: sourceURL), before)
        XCTAssertEqual(try Self.digest(sourceURL), config.expectedSHA256)
        let report: [String: Any] = ["id": config.id, "source": config.source, "sourceSHA256": config.expectedSHA256,
            "selectedIndexes": config.selected, "mainExtractionSeconds": extractionSeconds,
            "selected": selected, "merged": merged, "wallSeconds": ProcessInfo.processInfo.systemUptime - began,
            "anchorFactory": "unchanged200x200BlankCGPDFContext", "currentTargetAttributesEqual": true,
            "originalVersionAndSHAExact": true, "isProductReleaseQualification": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("actual.json"), options: .withoutOverwriting)
    }
    func testRealBookWholeBodyEditedAndRepeatedSaves() async throws {
        guard let path = ProcessInfo.processInfo.environment["EMBER_NATIVE_STAGING_ACTUAL_PLAN"] else { throw XCTSkip("Explicit bounded real-corpus plan required") }
        let config = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard ["audit-063", "audit-333"].contains(config.id) else { throw ProbeFailure.plan }
        let german = config.id == "audit-063", index = german ? 183 : 171, pages = german ? 408 : 357
        let output = URL(fileURLWithPath: config.output), original = URL(fileURLWithPath: config.source)
        XCTAssertEqual(try Self.digest(original), config.expectedSHA256)
        let before = try PDFSourceFileVersion.capture(at: original)
        let copy = output.appendingPathComponent("working.pdf")
        try FileManager.default.copyItem(at: original, to: copy)
        _ = NSApplication.shared
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: copy)); defer { workspace.closeDiscardingChanges() }
        let document = try XCTUnwrap(workspace.document)
        XCTAssertEqual(document.pageCount, pages)
        let initial = try await saveBook(document, stem: "whole", working: copy, output: output)
        let page = try XCTUnwrap(document.page(at: index)), content = try XCTUnwrap(page.string) as NSString
        let start = content.range(of: german ? "einschränkten" : "이 테이블")
        guard start.location != NSNotFound else { throw ProbeFailure.plan }
        let tail = content.range(of: german ? "Arminia-Präsident" : "그림 8-1", options: [],
            range: NSRange(location: start.location, length: content.length - start.location))
        guard tail.location != NSNotFound else { throw ProbeFailure.plan }
        let length = (german ? NSMaxRange(tail) : tail.location) - start.location
        workspace.setCurrentPage(index); workspace.setMode(.editing)
        workspace.currentSelection = try XCTUnwrap(page.selection(for: NSRange(location: start.location, length: length)))
        let editorBegan = ProcessInfo.processInfo.systemUptime
        workspace.selectTool(.text)
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit, workspace.presentedError ?? "No body draft")
        let editorSeconds = ProcessInfo.processInfo.systemUptime - editorBegan
        let beforeText = german ? "einschränkten" : "오랜 시간", afterText = german ? "begrenzten" : "긴 시간"
        let revised = draft.text.replacingOccurrences(of: beforeText, with: afterText)
        XCTAssertNotEqual(draft.text, revised)
        let editPlan: [String: Any] = ["id": config.id, "source": config.source, "sourceSHA256": config.expectedSHA256,
            "bodyPage": index, "targetBefore": draft.text, "targetAfter": revised,
            "oldText": beforeText, "newText": afterText,
            "bounds": [Double(draft.bounds.minX), Double(draft.bounds.minY), Double(draft.bounds.width), Double(draft.bounds.height)]]
        try JSONSerialization.data(withJSONObject: editPlan, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("body-edit-plan.json"), options: .withoutOverwriting)
        let applyBegan = ProcessInfo.processInfo.systemUptime
        workspace.commitPendingInlineText(id: draft.id, text: revised, style: draft.style, bounds: draft.bounds)
        let applySeconds = ProcessInfo.processInfo.systemUptime - applyBegan
        XCTAssertNil(workspace.presentedError); XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertTrue(document.page(at: index)?.string?.contains(afterText) == true)
        try PDFBodyTextPageSnapshot.originalPageData(for: XCTUnwrap(document.page(at: index)))
            .write(to: output.appendingPathComponent("expected-edited-page.pdf"), options: .withoutOverwriting)
        let edited = try await saveBook(document, stem: "edited", working: copy, output: output)
        let repeated = try await saveBook(document, stem: "repeated", working: copy, output: output)
        let reopened = try PDFSourceFileAccess.loadDocument(at: copy).document
        XCTAssertEqual(reopened.pageCount, pages)
        let changed = try XCTUnwrap(reopened.page(at: index)), text = try XCTUnwrap(changed.string) as NSString
        let editedRange = text.range(of: afterText); XCTAssertNotEqual(editedRange.location, NSNotFound)
        let editableAgain = try XCTUnwrap(PDFBodyTextEditor.target(on: changed,
            selection: XCTUnwrap(changed.selection(for: editedRange))))
        XCTAssertTrue(editableAgain.text.contains(afterText))
        XCTAssertEqual(try PDFSourceFileVersion.capture(at: original), before)
        XCTAssertEqual(try Self.digest(original), config.expectedSHA256)
        let report: [String: Any] = ["id": config.id, "originalSHA256": config.expectedSHA256,
            "pages": pages, "bodyPage": index, "editorSeconds": editorSeconds, "applyMainSeconds": applySeconds,
            "whole": initial, "edited": edited, "repeated": repeated, "reopenedBodyEditableAgain": true,
            "originalSHAStatExact": true, "scope": "WORK Native route and actual Main RecoverySnapshot, not final UI release qualification"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("actual.json"), options: .withoutOverwriting)
    }

    private func saveBook(_ document: PDFDocument, stem: String, working: URL, output: URL) async throws -> [String: Any] {
        Self.event(stem + ".main-RecoverySnapshot.begin")
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let capture = ProcessInfo.processInfo.systemUptime - start
        Self.event(stem + ".main-RecoverySnapshot.end")
        let row = try await Task.detached(priority: .userInitiated) { () throws -> [String: Any] in
            let owned = try snapshot.takeDocument(), expected = try Self.currentState(owned)
            let begin = ProcessInfo.processInfo.systemUptime
            Self.event(stem + ".native-proof.begin")
            let proof = try XCTUnwrap(PDFNativeStagingWriter.dataIfEligible(owned), "Whole/edited/repeated native route must be proven, never timed fallback")
            let route = ProcessInfo.processInfo.systemUptime - begin
            try proof.write(to: output.appendingPathComponent(stem + "-proof.pdf"), options: .withoutOverwriting)
            Self.event(stem + ".native-proof.end")
            let atomicBegan = ProcessInfo.processInfo.systemUptime
            try AtomicPDFWriter.write(owned, to: working)
            let atomic = ProcessInfo.processInfo.systemUptime - atomicBegan
            Self.event(stem + ".Atomic.end")
            let saved = output.appendingPathComponent(stem + ".pdf")
            try FileManager.default.copyItem(at: working, to: saved)
            let reopened = try XCTUnwrap(PDFDocument(url: saved)), actual = try Self.currentState(reopened)
            XCTAssertTrue(NSDictionary(dictionary: expected).isEqual(to: actual), "Current state must survive whole, body-modified and repeated saves")
            return ["nativeRouteSeconds": route, "workerAtomicSeconds": atomic,
                    "expectedCurrentState": expected, "reopenedCurrentState": actual,
                    "path": saved.path, "sha256": try Self.digest(saved), "nativeRouteQualified": true]
        }.value
        var report = row; report["mainRecoverySnapshotSeconds"] = capture
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(stem + "-current.json"), options: .withoutOverwriting)
        return report
    }

    private func saveSnapshot(_ document: PDFDocument, stem: String, output: URL) async throws -> [String: Any] {
        Self.event(stem + ".main-RecoverySnapshot.begin")
        let captureBegan = ProcessInfo.processInfo.systemUptime
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let captureSeconds = ProcessInfo.processInfo.systemUptime - captureBegan
        Self.event(stem + ".main-RecoverySnapshot.end")
        let destination = output.appendingPathComponent(stem + ".pdf")
        let proofDestination = output.appendingPathComponent(stem + "-native-proof.pdf")
        var row = try await Task.detached(priority: .userInitiated) { () throws -> [String: Any] in
            guard !Thread.isMainThread else { throw ProbeFailure.thread }
            let start = ProcessInfo.processInfo.systemUptime
            let owned = try snapshot.takeDocument()
            let expected = (0..<owned.pageCount).map { owned.page(at: $0)?.annotations.count ?? -1 }
            let currentState = try Self.currentState(owned)
            if let admission = try PDFCatalogStructurePreserver.nativeStagingSource(for: owned) {
                Self.event(stem + ".admission-eligible")
                XCTAssertTrue(try PDFBodyTextPageSnapshot.metadataMatches(owned, source: admission), "Current metadata must equal explicit donor baseline")
                if admission.hasTags { XCTAssertNotNil(try admission.rawSource.tagReadFileInput(in: admission.owner), "Aux input must match frozen factory bytes") }
            } else { Self.event(stem + ".admission-refused") }
            Self.event(stem + ".native-route-proof.begin")
            let routeStart = ProcessInfo.processInfo.systemUptime
            let data = try XCTUnwrap(PDFNativeStagingWriter.dataIfEligible(owned), "Real route must be eligible; ordinary fallback is not speed qualification")
            let routeSeconds = ProcessInfo.processInfo.systemUptime - routeStart
            try data.write(to: proofDestination, options: .withoutOverwriting)
            Self.event(stem + ".native-route-proof.end")
            Self.event(stem + ".worker-AtomicPDFWriter.begin")
            let atomicStart = ProcessInfo.processInfo.systemUptime
            try AtomicPDFWriter.write(owned, to: destination)
            let atomicSeconds = ProcessInfo.processInfo.systemUptime - atomicStart
            Self.event(stem + ".worker-AtomicPDFWriter.end")
            let reopened = try XCTUnwrap(PDFDocument(url: destination))
            XCTAssertEqual(reopened.pageCount, owned.pageCount)
            XCTAssertEqual((0..<reopened.pageCount).map { reopened.page(at: $0)?.annotations.count ?? -1 }, expected)
            let reopenedState = try Self.currentState(reopened)
            XCTAssertTrue(NSDictionary(dictionary: currentState).isEqual(to: reopenedState), "Full current annotations/navigation/outline/attributes must survive")
            return ["mainThread": false, "nativeRouteQualified": true, "nativeRouteSeconds": routeSeconds,
                "workerAtomicSeconds": atomicSeconds, "workerTotalSeconds": ProcessInfo.processInfo.systemUptime - start,
                "currentAnnotationCounts": expected, "expectedCurrentState": currentState, "reopenedCurrentState": reopenedState,
                "path": destination.path, "sha256": try Self.digest(destination)]
        }.value
        row["mainRecoverySnapshotSeconds"] = captureSeconds
        return row
    }
    nonisolated private static func currentState(_ document: PDFDocument) throws -> [String: Any] {
        func navigation(_ action: PDFAction?, _ destination: PDFDestination?) -> [String: Any] {
            if let d = (action as? PDFActionGoTo)?.destination ?? destination {
                return ["type": "GoTo", "target": d.page.map { document.index(for: $0) } ?? -1,
                        "point": [Double(d.point.x), Double(d.point.y)], "zoom": Double(d.zoom)]
            }
            if let action = action as? PDFActionURL { return ["type": "URL", "url": action.url?.absoluteString ?? "nil"] }
            return ["type": action.map { String(describing: type(of: $0)) } ?? "nil"]
        }
        var pages: [[String: Any]] = []
        guard document.pageCount <= 4_096 else { throw ProbeFailure.plan }
        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            let annotations = page.annotations.map { a -> [String: Any] in
                ["type": a.type ?? "nil", "contents": a.contents ?? "nil", "display": a.shouldDisplay, "print": a.shouldPrint,
                 "rect": [Double(a.bounds.minX), Double(a.bounds.minY), Double(a.bounds.width), Double(a.bounds.height)],
                 "navigation": navigation(a.action, a.destination)]
            }
            pages.append(["rotation": page.rotation, "boxes": PDFPageGeometryPreserver.boxes.map {
                let r = page.bounds(for: $0.1); return [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
            }, "annotations": annotations])
        }
        var attributes: [String: Any] = [:]
        for (key, value) in document.documentAttributes ?? [:] {
            let name = (key.base as? PDFDocumentAttribute)?.rawValue ?? String(describing: key)
            if let v = value as? String { attributes[name] = ["type": "string", "value": v] }
            else if let v = value as? Date { attributes[name] = ["type": "date", "value": v.timeIntervalSince1970] }
            else if let v = value as? [String] { attributes[name] = ["type": "strings", "value": v] }
            else { throw ProbeFailure.plan }
        }
        var outline: [[String: Any]] = [], stack: [(PDFOutline, [Int])] = []
        if let root = document.outlineRoot { stack.append((root, [])) }
        var seen = Set<ObjectIdentifier>()
        while let (node, path) = stack.popLast() {
            guard seen.insert(ObjectIdentifier(node)).inserted, seen.count <= 100_000, path.count < 64 else { throw ProbeFailure.plan }
            outline.append(["path": path, "label": node.label ?? "nil", "children": node.numberOfChildren,
                            "open": node.isOpen, "navigation": navigation(node.action, node.destination)])
            for index in (0..<node.numberOfChildren).reversed() {
                stack.append((try XCTUnwrap(node.child(at: index)), path + [index]))
            }
        }
        return ["pages": pages, "attributes": attributes, "outline": outline]
    }
    nonisolated private static func event(_ name: String) {
        let row: [String: Any] = ["checkpoint": name, "uptime": ProcessInfo.processInfo.systemUptime,
                                 "mainThread": Thread.isMainThread]
        if let bytes = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            FileHandle.standardError.write(bytes); FileHandle.standardError.write(Data([10]))
        }
    }
    nonisolated private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 64 * 1_024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private struct Plan: Decodable { let id: String; let source: String; let selected: [Int]; let expectedSHA256: String; let output: String }
    private enum ProbeFailure: Error { case plan, thread }
}
