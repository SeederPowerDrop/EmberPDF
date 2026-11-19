// SPDX-License-Identifier: MPL-2.0
import CEmberPDFRawStreams
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextOutlineGraphIdentityTests: XCTestCase {
    func testRawAndSDKStagesKeepCanonicalRelationshipsAndSemanticFields() throws {
        let original = fixture(), live = try XCTUnwrap(PDFDocument(data: original))
        let raw = try Reader(original).audit()
        XCTAssertEqual(raw.nodes, 4); XCTAssertEqual(raw.invalidEdges, 0)
        let staged = try XCTUnwrap(live.dataRepresentation())
        let sdk = try Reader(staged).audit()
        // An OS repair must not break this regression: only the writer's result
        // is required to be correct. This diagnostic localizes staging changes.
        print("Outline stages rawInvalid=\(raw.invalidEdges) sdkInvalid=\(sdk.invalidEdges)")
        let wrongBacklinks = fixture(mutation: "backlinks")
        XCTAssertGreaterThan(try Reader(wrongBacklinks).audit().invalidEdges, 0)
        for bytes in [original, staged, wrongBacklinks, fixture(mutation: "externalAlias"), fixture(mutation: "customType")] {
            let before = try Reader(bytes).audit()
            let saved = try PDFBodyTextPageSnapshot.preservingPageContents(in: bytes, from: live)
            let after = try Reader(saved).audit()
            XCTAssertEqual(after.nodes, before.nodes)
            XCTAssertEqual(after.invalidEdges, 0)
            XCTAssertEqual(after.semanticFields, before.semanticFields)
            let beforeReader = try Reader(bytes), afterReader = try Reader(saved)
            let originalAlias = try beforeReader.value(beforeReader.catalog, "ForeignOutlineAlias")
            if try !beforeReader.absent(originalAlias) {
                let savedAlias = try afterReader.value(afterReader.catalog, "ForeignOutlineAlias")
                let originalParent = try beforeReader.value(originalAlias, "Parent")
                let savedParent = try afterReader.value(savedAlias, "Parent")
                XCTAssertEqual(try afterReader.audit(savedParent), try beforeReader.audit(originalParent))
                let newRoot = try afterReader.value(afterReader.catalog, "Outlines")
                XCTAssertNotEqual(savedAlias, try afterReader.value(newRoot, "First"))
                XCTAssertNotEqual(savedParent, newRoot)
            }
        }
    }

    func testCurrentReorderedAndRetitledForwardTreeIsAuthoritative() throws {
        let live = try XCTUnwrap(PDFDocument(data: fixture()))
        let root = try XCTUnwrap(live.outlineRoot), moved = try XCTUnwrap(root.child(at: 0))
        moved.removeFromParent(); root.insertChild(moved, at: root.numberOfChildren)
        moved.label = "Current group"
        let staged = try XCTUnwrap(live.dataRepresentation())
        let before = try Reader(staged).audit()
        let saved = try PDFBodyTextPageSnapshot.preservingPageContents(in: staged, from: live)
        let after = try Reader(saved).audit()
        XCTAssertEqual(after.invalidEdges, 0); XCTAssertEqual(after.semanticFields, before.semanticFields)
        let reopened = try XCTUnwrap(PDFDocument(data: saved))
        XCTAssertEqual(reopened.outlineRoot?.child(at: 0)?.label, "Last")
        XCTAssertEqual(reopened.outlineRoot?.child(at: 1)?.label, "Current group")
        XCTAssertEqual(reopened.outlineRoot?.child(at: 1)?.numberOfChildren, 2)
    }

    func testBodyEditUndoRedoAndTwoColdSavesKeepEveryCanonicalEdge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-outline-edges-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("owned.pdf"), original = fixture()
        try original.write(to: url)
        let expected = try Reader(original, canonicalDefaults: true).audit()
        for (old, new) in [("Original body", "Updated body"), ("Updated body", "Altered body")] {
            let workspace = PDFWorkspaceState()
            XCTAssertTrue(workspace.open(url: url)); workspace.setMode(.editing)
            XCTAssertTrue(workspace.requestBodyTextEdit(pageIndex: 0, point: CGPoint(x: 70, y: 307)))
            let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
            XCTAssertEqual(draft.text, old)
            workspace.commitPendingInlineText(id: draft.id, text: new, style: draft.style, bounds: draft.bounds)
            XCTAssertNil(workspace.presentedError); XCTAssertNil(workspace.pendingInlineTextEdit)
            workspace.undo(); XCTAssertEqual(workspace.document?.findString(old, withOptions: []).count, 1)
            workspace.redo(); XCTAssertEqual(workspace.document?.findString(new, withOptions: []).count, 1)
            XCTAssertTrue(workspace.saveSynchronously(), workspace.presentedError ?? "Save failed")
            workspace.close()
            let bytes = try Data(contentsOf: url), saved = try Reader(bytes, canonicalDefaults: true).audit()
            // Keep raw spelling visible. /Type is optional; only a proven
            // childless leaf makes integer /Count 0 equivalent to absence.
            print("Outline cold raw fields=\(try Reader(bytes).audit().semanticFields)")
            XCTAssertEqual(saved.invalidEdges, 0); XCTAssertEqual(saved.nodes, expected.nodes)
            XCTAssertEqual(saved.semanticFields, expected.semanticFields)
            let cold = try XCTUnwrap(PDFDocument(data: bytes))
            XCTAssertEqual(cold.findString(new, withOptions: []).count, 1)
        }
    }

    func testFactoryBoundStyleFollowsRenamedReorderedObjectAcrossRecoveryAndTwoSaves() async throws {
        let original = fixture(mutation: "duplicateStyled")
        let expected = try Reader(original).styleFields(at: [0])
        let siblingStyle = try Reader(original).styleFields(at: [1])
        XCTAssertNotEqual(expected, siblingStyle)
        var live = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: original))
        let root = try XCTUnwrap(live.outlineRoot), moved = try XCTUnwrap(root.child(at: 0))
        moved.removeFromParent(); moved.label = "Moved styled group"
        root.insertChild(moved, at: root.numberOfChildren)
        moved.destination = PDFDestination(page: try XCTUnwrap(live.page(at: 0)), at: CGPoint(x: 99, y: 123))
        moved.destination?.zoom = 1.25
        for _ in 0..<2 {
            let bytes = try await savedStyleBytes(live)
            assertStyleSemantics(try Reader(bytes).styleFields(at: [1]), expected)
            assertStyleSemantics(try Reader(bytes).styleFields(at: [0]), siblingStyle)
            live = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
            XCTAssertEqual(live.outlineRoot?.child(at: 1)?.label, "Moved styled group")
            XCTAssertEqual(live.outlineRoot?.child(at: 1)?.numberOfChildren, 2)
            XCTAssertEqual(live.outlineRoot?.child(at: 1)?.destination?.point, CGPoint(x: 99, y: 123))
            XCTAssertEqual(live.outlineRoot?.child(at: 1)?.destination?.zoom, 1.25)
        }
    }

    func testExtractionCopyKeepsBoundOriginalStyleAcrossRecovery() async throws {
        let original = fixture(mutation: "inactiveStyleGroup")
        let expected = try Reader(original).styleFields(at: [0])
        let live = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: original))
        let extracted = try PDFPageOperations.extract(from: live, indexes: [0])
        let bytes = try await savedStyleBytes(extracted)
        XCTAssertEqual(try Reader(bytes).styleFields(at: [0]), expected)
        XCTAssertEqual(try Reader(bytes).audit().invalidEdges, 0)
    }

    func testNewSameLabelOutlineCannotAcquireRemovedOriginalStyleAtLatePrepare() async throws {
        let original = fixture()
        let expected = try Reader(original).styleFields(at: [0])
        let live = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: original))
        let root = try XCTUnwrap(live.outlineRoot), removed = try XCTUnwrap(root.child(at: 0))
        let replacement = PDFOutline(); replacement.label = removed.label; replacement.destination = removed.destination
        removed.removeFromParent(); root.insertChild(replacement, at: 0)
        // Factory capture is terminal. This later native/path/title match must
        // not mint the removed item's C/F onto a newly created object.
        if let native = live.documentRef {
            PDFCatalogStructurePreserver.rememberFactoryOutlineStyles(in: live, native: native)
        }
        try PDFCatalogStructurePreserver.prepare(live, force: true)
        let bytes = try await savedStyleBytes(live)
        let actual = try Reader(bytes).styleFields(at: [0])
        XCTAssertNil(actual["C"])
        XCTAssertNotEqual(actual["F"], expected["F"])
        XCTAssertEqual(try Reader(bytes).audit().invalidEdges, 0)
    }

    func testMalformedFactoryStyleRefusesReconstructionButKeepsRawForwarding() throws {
        for mutation in ["invalidColor", "invalidFlags"] {
            let bytes = fixture(mutation: mutation)
            let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
            XCTAssertThrowsError(try PDFRecoverySnapshot(capturing: document), mutation)
            XCTAssertThrowsError(try PDFPageOperations.extract(from: document, indexes: [0]), mutation)
            XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: document), mutation)
            // The unchanged raw graph route neither reconstructs SDK outlines
            // nor grants fresh style authority. Preserve malformed bytes too.
            let forwarded = try PDFBodyTextPageSnapshot.preservingPageContents(in: bytes, from: document)
            XCTAssertEqual(try Reader(forwarded).styleFields(at: [0]), try Reader(bytes).styleFields(at: [0]))
            XCTAssertEqual(try Reader(forwarded).audit().invalidEdges, 0)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-style-refusal-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("preserved.pdf")
            try bytes.write(to: destination)
            XCTAssertThrowsError(try AtomicPDFWriter.write(document, to: destination), mutation)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
        }
    }

    func testFactoryStyleLimitRefusalSurvivesMetadataCopyAndCannotBeReminted() throws {
        for bytes in [deepFixture(depth: 65), wideStyleFixture(count: 4_096)] {
            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
            XCTAssertThrowsError(try PDFCatalogStructurePreserver.validateOutlineStyleReconstruction(in: source))
            let native = try XCTUnwrap(source.documentRef)
            PDFCatalogStructurePreserver.rememberFactoryOutlineStyles(in: source, native: native)
            XCTAssertThrowsError(try PDFCatalogStructurePreserver.validateOutlineStyleReconstruction(in: source))
            // Carry only the refusal to an independently factory-created copy;
            // a successful later parser must not erase the earlier uncertainty.
            let copy = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
            XCTAssertNoThrow(try PDFCatalogStructurePreserver.validateOutlineStyleReconstruction(in: copy))
            PDFCatalogStructurePreserver.inheritDocumentMetadata(from: source, to: copy)
            XCTAssertThrowsError(try PDFRecoverySnapshot(capturing: copy))
            XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: copy))
            let unrelated = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
            XCTAssertNoThrow(try PDFCatalogStructurePreserver.validateOutlineStyleReconstruction(in: unrelated))
        }
    }

    func testCompleteNoStyleAndStyledFactoriesKeepTwoColdSaves() async throws {
        // The independent raw reader and CoreGraphics decimal parser can
        // disagree by one adjacent Double. Keep raw values visible, accept only
        // that numeric representation boundary, and reject actual style loss.
        let style = ["C": "[n:0.8,n:0.7,n:0.6]", "F": "n:2.0"]
        XCTAssertTrue(stylesMatch(style, ["C": "[n:0.8,n:\(0.7.nextUp),n:0.6]", "F": "n:2.0"]))
        XCTAssertFalse(stylesMatch(style, ["C": "[n:0.8,n:\(0.7.nextUp.nextUp),n:0.6]", "F": "n:2.0"]))
        XCTAssertFalse(stylesMatch(style, ["C": "[n:0.8,n:0.7,n:0.6]", "F": "n:3.0"]))
        XCTAssertFalse(stylesMatch(style, ["F": "n:2.0"]))
        XCTAssertFalse(stylesMatch(style, ["C": "[n:0.8,n:0.7]", "F": "n:2.0"]))
        XCTAssertFalse(stylesMatch(style, ["C": "[n:0.8,n:nan,n:0.6]", "F": "n:2.0"]))
        for mutation in ["noStyles", "nullOutlines", "nullOptionalStyles", "duplicateStyled"] {
            let originalBytes = fixture(mutation: mutation)
            var live = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: originalBytes))
            let original = try Reader(originalBytes)
            let expectedNodes = try original.audit().nodes
            let expected = mutation == "duplicateStyled" ? try (0..<2).map { try original.styleFields(at: [$0]) } : []
            for _ in 0..<2 {
                XCTAssertNoThrow(try PDFCatalogStructurePreserver.validateOutlineStyleReconstruction(in: live))
                let bytes = try await savedStyleBytes(live)
                let reader = try Reader(bytes)
                if mutation == "duplicateStyled" {
                    for index in 0..<2 { assertStyleSemantics(try reader.styleFields(at: [index]), expected[index]) }
                }
                XCTAssertEqual(try reader.audit().invalidEdges, 0)
                XCTAssertEqual(try reader.audit().nodes, expectedNodes)
                live = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
            }
        }
    }

    func testNullPaddedOriginalColorSurvivesFileLoaderAndTwoColdSaves() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-outline-padding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for paddingCount in [0, 1, 13] {
            let original = fixture(outlineColor: (["0.25", "0.5", "0.75"] + Array(repeating: "null", count: paddingCount)).joined(separator: " "))
            let expected = try Reader(original).styleFields(at: [0])
            let input = directory.appendingPathComponent("original-\(paddingCount).pdf")
            try original.write(to: input)
            let output = directory.appendingPathComponent("saved-\(paddingCount).pdf")
            for pass in 0..<4 {
                // Exercise the public model without a manually prepared graph:
                // Save As, cold-open overwrite, then the low-level writer with
                // both nil and empty ordinary-save options.
                if pass < 2 {
                    let workspace = PDFWorkspaceState()
                    XCTAssertTrue(workspace.open(url: pass == 0 ? input : output))
                    XCTAssertTrue(workspace.saveSynchronously(as: pass == 0 ? output : nil), workspace.presentedError ?? "Save failed")
                    workspace.close()
                } else {
                    let live = try PDFSourceFileAccess.loadDocument(at: output).document
                    try AtomicPDFWriter.write(live, to: output, writeOptions: pass == 2 ? nil : [:])
                }
                let bytes = try Data(contentsOf: output), reader = try Reader(bytes)
                // Exact binary RGB values isolate preservation of every null
                // element and F. The existing numeric comparator is unchanged.
                XCTAssertEqual(try reader.styleFields(at: [0]), expected)
                XCTAssertEqual(try reader.audit().invalidEdges, 0)
                let cold = try PDFSourceFileAccess.loadDocument(at: output).document
                XCTAssertNoThrow(try PDFCatalogStructurePreserver.validateOutlineStyleReconstruction(in: cold))
                XCTAssertEqual(cold.outlineRoot?.child(at: 0)?.numberOfChildren, 2)
            }
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }

    func testNullPaddedOriginalColorSurvivesRecoveryExtractionMergeAndReopen() async throws {
        for paddingCount in [0, 1, 13] {
            let original = fixture(outlineColor: (["0.25", "0.5", "0.75"] + Array(repeating: "null", count: paddingCount)).joined(separator: " "))
            let expected = try Reader(original).styleFields(at: [0])
            var live = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: original))
            for _ in 0..<2 {
                let bytes = try await savedStyleBytes(live)
                XCTAssertEqual(try Reader(bytes).styleFields(at: [0]), expected)
                XCTAssertEqual(try Reader(bytes).audit().invalidEdges, 0)
                live = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
                XCTAssertNoThrow(try PDFCatalogStructurePreserver.validateOutlineStyleReconstruction(in: live))
            }
            let extracted = try PDFPageOperations.extract(from: live, indexes: [0])
            let extractedBytes = try await savedStyleBytes(extracted)
            XCTAssertEqual(try Reader(extractedBytes).styleFields(at: [0]), expected)
            let coldExtracted = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: extractedBytes))
            let imported = try PDFPageStructurePreserver.prepareImport(from: coldExtracted, indexes: [0])
            let merged = PDFDocument()
            let transaction = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: merged, at: 0)
            try transaction.apply(); try transaction.undo()
            XCTAssertEqual(merged.pageCount, 0)
            try transaction.redo()
            let mergedBytes = try await savedStyleBytes(merged), reader = try Reader(mergedBytes)
            XCTAssertEqual(try reader.styleFields(at: [0, 0]), expected)
            XCTAssertEqual(try reader.audit().invalidEdges, 0)
            let cold = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: mergedBytes))
            XCTAssertNoThrow(try PDFCatalogStructurePreserver.validateOutlineStyleReconstruction(in: cold))
            XCTAssertEqual(cold.pageCount, 1)
            XCTAssertEqual(cold.outlineRoot?.child(at: 0)?.child(at: 0)?.numberOfChildren, 2)
        }
    }

    func testNonNullColorPaddingInvalidRGBAndExcessPaddingStillRefuseWithoutOverwriting() throws {
        let invalid = [
            "0.25 0.5 0.75 0", "0.25 0.5 0.75 /None", "0.25 0.5 0.75 [null]",
            "0.25 0.5 0.75 true", "0.25 null 0.75 null", "0.25 /None 0.75 null",
            "0.25 0.5 1.25 null", "0.25 0.5", "0.25 0.5 0.75 " + Array(repeating: "null", count: 14).joined(separator: " ")
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-outline-padding-refusal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, color) in invalid.enumerated() {
            let original = fixture(outlineColor: color)
            let live = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: original))
            XCTAssertThrowsError(try PDFCatalogStructurePreserver.validateOutlineStyleReconstruction(in: live))
            XCTAssertThrowsError(try PDFRecoverySnapshot(capturing: live))
            XCTAssertThrowsError(try PDFPageOperations.extract(from: live, indexes: [0]))
            XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: live))
            let destination = directory.appendingPathComponent("unchanged-\(index).pdf")
            try original.write(to: destination)
            XCTAssertThrowsError(try AtomicPDFWriter.write(live, to: destination))
            XCTAssertEqual(try Data(contentsOf: destination), original)
        }
    }

    private func assertStyleSemantics(_ actual: [String: String], _ expected: [String: String],
                                      file: StaticString = #filePath, line: UInt = #line) {
        print("Outline raw style actual=\(actual) expected=\(expected)")
        XCTAssertTrue(stylesMatch(actual, expected), "Outline style changed: \(actual) vs \(expected)", file: file, line: line)
    }

    private func stylesMatch(_ actual: [String: String], _ expected: [String: String]) -> Bool {
        guard Set(actual.keys) == Set(expected.keys), actual["F"] == expected["F"] else { return false }
        func color(_ raw: String?) -> [Double]? {
            guard let raw, raw.hasPrefix("["), raw.hasSuffix("]") else { return nil }
            let components = raw.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
            guard components.count == 3 else { return nil }
            var values: [Double] = []
            for component in components {
                guard component.hasPrefix("n:"), let value = Double(component.dropFirst(2)),
                      value.isFinite, (0...1).contains(value) else { return nil }
                values.append(value)
            }
            return values
        }
        if actual["C"] == nil { return true }
        guard let left = color(actual["C"]), let right = color(expected["C"]) else { return false }
        for index in left.indices {
            let a: Double = left[index]
            let b: Double = right[index]
            if a == b { continue }
            if a.nextUp == b { continue }
            if a.nextDown == b { continue }
            return false
        }
        return true
    }

    private func savedStyleBytes(_ document: PDFDocument) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-outline-style-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("saved.pdf")
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        return try await Task.detached {
            let owned = try snapshot.takeDocument()
            try AtomicPDFWriter.write(owned, to: url)
            return try Data(contentsOf: url)
        }.value
    }

    func testForwardCycleAndSharedNodeAreRejected() throws {
        let live = try XCTUnwrap(PDFDocument(data: fixture()))
        for mutation in ["cycle", "shared"] {
            XCTAssertThrowsError(try PDFBodyTextPageSnapshot.preservingPageContents(in: fixture(mutation: mutation), from: live), mutation)
        }
    }

    func testInvalidForwardTypeAndExcessiveDepthAreRejected() throws {
        let live = try XCTUnwrap(PDFDocument(data: fixture()))
        for mutation in ["type", "foreignRole", "pageTypedItem", "catalogTypedItem"] {
            XCTAssertThrowsError(try PDFBodyTextPageSnapshot.preservingPageContents(in: fixture(mutation: mutation), from: live), mutation)
        }
        XCTAssertThrowsError(try PDFBodyTextPageSnapshot.preservingPageContents(in: deepFixture(depth: 66), from: live))
    }

    func testMissingAndEmptyOutlinesDoNotInventRelationshipsOrCount() throws {
        for mutation in ["missing", "empty"] {
            let bytes = fixture(mutation: mutation), live = try XCTUnwrap(PDFDocument(data: bytes))
            let before = try Reader(bytes).audit()
            let saved = try PDFBodyTextPageSnapshot.preservingPageContents(in: bytes, from: live)
            let after = try Reader(saved).audit()
            XCTAssertEqual(after, before); XCTAssertEqual(after.invalidEdges, 0)
        }
    }

    private func fixture(mutation: String = "", outlineColor: String? = nil) -> Data {
        var objects = pageObjects(outline: mutation != "missing")
        let first = mutation == "type" ? "42" : (mutation == "foreignRole" ? "3 0 R" : "7 0 R")
        objects.append(mutation == "empty" ? "<< /Type /Outlines /Count 0 /Title (Empty) >>" :
            "<< /Type /Outlines /First \(first) /Last 10 0 R /Count 2 >>")
        objects += [
            "<< /Title (Group) /Parent 6 0 R /Next 10 0 R /First 8 0 R /Last 9 0 R /Count -2 /Dest [3 0 R /Fit] /C [0.1 0.2 0.3] /F 3 >>",
            "<< /Title (Child one) /Parent 7 0 R /Next 9 0 R /Dest [3 0 R /XYZ 10 20 1.5] >>",
            "<< /Title (Child two) /Parent 7 0 R /Prev 8 0 R /Dest [3 0 R /FitH 300] >>",
            "<< /Title (Last) /Parent 6 0 R /Prev 7 0 R /Dest [3 0 R /FitV 40] \(mutation == "cycle" ? "/Next 7 0 R" : "") \(mutation == "shared" ? "/First 8 0 R /Last 9 0 R /Count 2" : "") >>"
        ]
        if mutation == "nullOutlines" {
            objects[0] = objects[0].replacingOccurrences(of: "/Outlines 6 0 R", with: "/Outlines null")
        }
        if mutation == "nullOptionalStyles" {
            objects[6] = objects[6].replacingOccurrences(of: "/C [0.1 0.2 0.3] /F 3", with: "/C null /F null")
            // Keep actual forward children/siblings intact; only absent edges
            // receive explicit null, including the terminal sibling pointers.
            objects[7] = objects[7].replacingOccurrences(of: "/Title (Child one)", with: "/Title (Child one) /First null /C null /F null")
            objects[8] = objects[8].replacingOccurrences(of: "/Title (Child two)", with: "/Title (Child two) /First null /Next null /C null /F null")
            objects[9] = objects[9].replacingOccurrences(of: "/Title (Last)", with: "/Title (Last) /First null /Next null /C null /F null")
        }
        if mutation == "invalidColor" {
            objects[6] = objects[6].replacingOccurrences(of: "/C [0.1 0.2 0.3]", with: "/C [0.1 0.2 2]")
        }
        if let outlineColor {
            objects[6] = objects[6].replacingOccurrences(of: "/C [0.1 0.2 0.3]", with: "/C [\(outlineColor)]")
        }
        if mutation == "invalidFlags" {
            objects[6] = objects[6].replacingOccurrences(of: "/F 3", with: "/F 8")
        }
        if mutation == "noStyles" {
            objects[6] = objects[6].replacingOccurrences(of: "/C [0.1 0.2 0.3] /F 3", with: "")
        }
        if mutation == "inactiveStyleGroup" {
            objects[6] = objects[6].replacingOccurrences(of: "/Dest [3 0 R /Fit]", with: "")
        }
        if mutation == "duplicateStyled" {
            objects[9] = objects[9].replacingOccurrences(of: "/Title (Last)",
                with: "/Title (Group) /C [0.8 0.7 0.6] /F 2")
        }
        if ["customType", "pageTypedItem", "catalogTypedItem"].contains(mutation) {
            let type = mutation == "customType" ? "CustomOutlineName" : (mutation == "pageTypedItem" ? "Page" : "Catalog")
            objects[6] = objects[6].replacingOccurrences(of: "/Title (Group)", with: "/Title (Group) /Type /\(type)")
        }
        if mutation == "externalAlias" {
            objects[0] = objects[0].replacingOccurrences(of: "/Outlines 6 0 R", with: "/Outlines 6 0 R /ForeignOutlineAlias 7 0 R")
        }
        if mutation == "backlinks" {
            objects[5] = objects[5].replacingOccurrences(of: "/Last 10 0 R", with: "/Last 7 0 R")
            objects[6] = objects[6].replacingOccurrences(of: "/Parent 6 0 R", with: "/Parent 10 0 R")
            objects[7] = objects[7].replacingOccurrences(of: "/Parent 7 0 R", with: "/Parent 10 0 R")
            objects[8] = objects[8].replacingOccurrences(of: "/Prev 8 0 R", with: "/Prev 7 0 R")
            objects[9] = objects[9].replacingOccurrences(of: "/Prev 7 0 R", with: "/Prev 9 0 R")
        }
        return pdf(objects)
    }
    private func deepFixture(depth: Int) -> Data {
        var objects = pageObjects(outline: true)
        objects.append("<< /Type /Outlines /First 7 0 R /Last 7 0 R /Count \(depth) >>")
        for index in 0..<depth {
            let parent = index == 0 ? 6 : index + 6
            let children = index + 1 < depth ? "/First \(index + 8) 0 R /Last \(index + 8) 0 R /Count 1" : ""
            objects.append("<< /Title (Level) /Parent \(parent) 0 R \(children) /Dest [3 0 R /Fit] >>")
        }
        return pdf(objects)
    }
    private func wideStyleFixture(count: Int) -> Data {
        var objects = pageObjects(outline: true)
        objects.append("<< /Type /Outlines /First 7 0 R /Last \(count + 6) 0 R /Count \(count) >>")
        for index in 0..<count {
            let previous = index > 0 ? "/Prev \(index + 6) 0 R" : ""
            let next = index + 1 < count ? "/Next \(index + 8) 0 R" : ""
            objects.append("<< /Title (Level) /Parent 6 0 R \(previous) \(next) /Dest [3 0 R /Fit] /C [0.1 0.2 0.3] /F 3 >>")
        }
        return pdf(objects)
    }
    private func pageObjects(outline: Bool) -> [String] {
        let content = "BT /F1 20 Tf 40 300 Td (Original body) Tj ET"
        return [
            "<< /Type /Catalog /Pages 2 0 R \(outline ? "/Outlines 6 0 R" : "") >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 600] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ]
    }
    private func pdf(_ objects: [String]) -> Data {
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }

    private struct Audit: Equatable {
        var nodes = 0, invalidEdges = 0
        var semanticFields: [String: String] = [:]
    }
    // QPDF's canonical object handles are independent of CGPDF dictionary
    // addresses and distinguish a backlink into a duplicate, unreachable tree.
    private final class Reader {
        let context: EmberRawPDFRef, catalog: EmberRawPDFObject
        let canonicalDefaults: Bool
        init(_ bytes: Data, canonicalDefaults: Bool = false) throws {
            self.canonicalDefaults = canonicalDefaults
            var status: Int32 = 9
            let pointer = bytes.withUnsafeBytes { ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, bytes.count, 4 * 1024 * 1024, 10_000, &status) }
            guard status == 0, let pointer else { throw NSError(domain: "OutlineFixture", code: Int(status)) }
            context = pointer
            var root: EmberRawPDFObject = 0
            guard ember_raw_pdf_catalog(pointer, &root) == 0 else { ember_raw_pdf_destroy(pointer); throw NSError(domain: "OutlineRoot", code: 1) }
            catalog = root
        }
        deinit { ember_raw_pdf_destroy(context) }
        func value(_ object: EmberRawPDFObject, _ key: String) throws -> EmberRawPDFObject {
            var result: EmberRawPDFObject = 0
            let status = Array(("/" + key).utf8).withUnsafeBufferPointer { ember_raw_pdf_dictionary_get(context, object, $0.baseAddress, $0.count, &result) }
            guard status == 0 else { throw NSError(domain: "OutlineKey", code: Int(status)) }; return result
        }
        func kind(_ object: EmberRawPDFObject) throws -> Int32 {
            var result: Int32 = -1
            guard ember_raw_pdf_kind(context, object, &result) == 0 else { throw NSError(domain: "OutlineKind", code: 1) }; return result
        }
        func absent(_ object: EmberRawPDFObject) throws -> Bool { try kind(object) == 0 }
        func audit(_ explicitRoot: EmberRawPDFObject? = nil) throws -> Audit {
            var result = Audit(), seen = Set<EmberRawPDFObject>()
            let root = try explicitRoot ?? value(catalog, "Outlines")
            if try absent(root) { result.semanticFields["root"] = "absent"; return result }
            guard try kind(root) == 7 else { throw NSError(domain: "OutlineType", code: 1) }
            seen.insert(root)
            result.semanticFields["root"] = try fields(root, isRoot: true)
            for key in ["Parent", "Prev", "Next"] { if try !absent(value(root, key)) { result.invalidEdges += 1 } }
            var pending: [(EmberRawPDFObject, String, Int)] = [(root, "", 0)]
            while let (parent, path, depth) = pending.popLast() {
                guard depth < 80 else { throw NSError(domain: "OutlineDepth", code: 1) }
                var node = try value(parent, "First"), previous: EmberRawPDFObject?, last: EmberRawPDFObject?, index = 0
                while try !absent(node) {
                    guard try kind(node) == 7, seen.insert(node).inserted, seen.count <= 1000 else { throw NSError(domain: "OutlineForward", code: 1) }
                    result.nodes += 1
                    let nodePath = path + "/" + String(index)
                    let noFirst = try absent(value(node, "First"))
                    let noLast = try absent(value(node, "Last"))
                    // With no forward child and no terminal child, the independent
                    // audit's child loop has zero children; inconsistent edges fail.
                    let isLeaf = noFirst && noLast
                    result.semanticFields[nodePath] = try fields(node, isLeaf: isLeaf)
                    if try value(node, "Parent") != parent { result.invalidEdges += 1 }
                    let prev = try value(node, "Prev")
                    if let previous { if prev != previous { result.invalidEdges += 1 } }
                    else if try !absent(prev) { result.invalidEdges += 1 }
                    pending.append((node, nodePath, depth + 1))
                    previous = node; last = node; node = try value(node, "Next"); index += 1
                }
                let actualLast = try value(parent, "Last")
                if let last { if actualLast != last { result.invalidEdges += 1 } }
                else if try !absent(actualLast) { result.invalidEdges += 1 }
            }
            return result
        }
        func styleFields(at path: [Int]) throws -> [String: String] {
            var current = try value(catalog, "Outlines")
            for index in path {
                current = try value(current, "First")
                for _ in 0..<index { current = try value(current, "Next") }
                guard try kind(current) == 7 else { throw NSError(domain: "OutlineStylePath", code: 1) }
            }
            var result: [String: String] = [:]
            for key in ["C", "F"] {
                let item = try value(current, key)
                if try !absent(item) { result[key] = try scalarTree(item, depth: 0) }
            }
            return result
        }
        private func fields(_ object: EmberRawPDFObject, isRoot: Bool = false, isLeaf: Bool = false) throws -> String {
            let ignored: Set<String> = ["First", "Last", "Next", "Prev", "Parent"]
            var values: [String] = []
            for key in try keys(object).sorted() where !ignored.contains(key) {
                let item = try value(object, key)
                if canonicalDefaults, isRoot, key == "Type" {
                    if try kind(item) == 4, try copied(item, name: true) == Data("/Outlines".utf8) { continue }
                }
                if canonicalDefaults, isLeaf, key == "Count", try kind(item) == 2 {
                    var count: Int64 = 1
                    guard ember_raw_pdf_integer(context, item, &count) == 0 else { throw NSError(domain: "OutlineCount", code: 1) }
                    if count == 0 { continue }
                }
                values.append(key + "=" + (try scalarTree(item, depth: 0)))
            }
            return values.joined(separator: "|")
        }
        private func scalarTree(_ object: EmberRawPDFObject, depth: Int) throws -> String {
            guard depth < 16 else { throw NSError(domain: "OutlineValueDepth", code: 1) }
            var page: EmberRawPDFObject = 0
            guard ember_raw_pdf_page(context, 0, &page) == 0 else { throw NSError(domain: "OutlinePage", code: 1) }
            if object == page { return "page:0" }
            switch try kind(object) {
            case 0: return "null"
            case 1:
                var value: Int32 = 0; guard ember_raw_pdf_boolean(context, object, &value) == 0 else { throw NSError(domain: "OutlineBool", code: 1) }; return value == 0 ? "false" : "true"
            case 2:
                var value: Int64 = 0; guard ember_raw_pdf_integer(context, object, &value) == 0 else { throw NSError(domain: "OutlineInt", code: 1) }; return "n:" + String(Double(value))
            case 3:
                var value = Double.nan; guard ember_raw_pdf_real(context, object, &value) == 0, value.isFinite else { throw NSError(domain: "OutlineReal", code: 1) }; return "n:" + String(value)
            case 4: return "name:" + (try copied(object, name: true)).base64EncodedString()
            case 5:
                let bytes = try copied(object, name: false)
                if bytes.starts(with: [0xfe, 0xff]), let text = String(data: bytes.dropFirst(2), encoding: .utf16BigEndian) { return "text:" + text }
                if let text = String(data: bytes, encoding: .ascii) { return "text:" + text }
                return "bytes:" + bytes.base64EncodedString()
            case 6:
                var count: UInt32 = 0; guard ember_raw_pdf_array_count(context, object, &count) == 0, count <= 64 else { throw NSError(domain: "OutlineArray", code: 1) }
                var values: [String] = []
                for index in 0..<count {
                    var item: EmberRawPDFObject = 0; guard ember_raw_pdf_array_item(context, object, index, &item) == 0 else { throw NSError(domain: "OutlineArrayItem", code: 1) }
                    values.append(try scalarTree(item, depth: depth + 1))
                }
                return "[" + values.joined(separator: ",") + "]"
            case 7:
                var values: [String] = []
                for key in try keys(object).sorted() { values.append(key + "=" + (try scalarTree(value(object, key), depth: depth + 1))) }
                return "{" + values.joined(separator: ",") + "}"
            default: throw NSError(domain: "OutlineValueKind", code: 1)
            }
        }
        private func keys(_ object: EmberRawPDFObject) throws -> [String] {
            var count: UInt32 = 0; guard ember_raw_pdf_dictionary_count(context, object, &count) == 0, count <= 64 else { throw NSError(domain: "OutlineKeys", code: 1) }
            var result: [String] = []
            for index in 0..<count {
                var pointer: UnsafeMutablePointer<UInt8>?, length = 0
                let status = ember_raw_pdf_dictionary_key_copy(context, object, index, &pointer, &length)
                defer { if let pointer { ember_raw_pdf_free(pointer) } }
                guard status == 0, length > 0, length <= 4096, let pointer else { throw NSError(domain: "OutlineKeyBytes", code: 1) }
                result.append(String(decoding: UnsafeBufferPointer(start: pointer.advanced(by: 1), count: length - 1), as: UTF8.self))
            }
            return result
        }
        private func copied(_ object: EmberRawPDFObject, name: Bool) throws -> Data {
            var pointer: UnsafeMutablePointer<UInt8>?, count = 0
            let status = name ? ember_raw_pdf_name_copy(context, object, &pointer, &count) : ember_raw_pdf_string_copy(context, object, &pointer, &count)
            defer { if let pointer { ember_raw_pdf_free(pointer) } }
            guard status == 0, count <= 4096, count == 0 || pointer != nil else { throw NSError(domain: "OutlineBytes", code: 1) }
            return pointer.map { Data(bytes: $0, count: count) } ?? Data()
        }
    }
}
