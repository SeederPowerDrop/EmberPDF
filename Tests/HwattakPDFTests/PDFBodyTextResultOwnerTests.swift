// SPDX-License-Identifier: MPL-2.0
import AppKit
import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

#if DEBUG
/// Owned font bytes and raw page assembly reproduce PDFKit's detached-page
/// lifetime boundary. No original-code editing adapter is required by this suite.
@MainActor
final class PDFBodyTextResultOwnerTests: XCTestCase {
    private typealias WeakOwner = PDFRawStreamProvenance.BodyResultFactory.LifetimeReferences
    func testDetachedResultAndInheritedCopyKeepExactTextUntilLastPageDies() throws {
        var owner: WeakOwner?
        var first: PDFPage? = try autoreleasepool {
            let factory = try XCTUnwrap(PDFRawStreamProvenance.bodyResultFactory(data: mixedFixture()))
            owner = factory.debugLifetimeReferences()
            return try XCTUnwrap(factory.copyPage())
        }
        XCTAssertNotNil(owner?.document); XCTAssertNotNil(owner?.factory)
        XCTAssertEqual(first?.string, "问文说\n123")
        var second: PDFPage? = try autoreleasepool {
            let original = try XCTUnwrap(first)
            let copy = try XCTUnwrap(original.copy() as? PDFPage)
            PDFRawStreamProvenance.inherit(from: original, to: copy)
            return copy
        }
        autoreleasepool { first = nil }
        XCTAssertNotNil(owner?.document)
        XCTAssertEqual(second?.string, "问文说\n123")
        autoreleasepool { second = nil }
        XCTAssertNil(owner?.factory, "No global map or factory-to-detached-page cycle may retain the holder.")
        XCTAssertNil(owner?.document)
        XCTAssertNil(owner?.originalPage)
    }

    func testInheritNeverCreatesFactoryMemberCycleOrRetainsOwnerForForeignGraph() throws {
        var owner: WeakOwner?
        let foreignDocument = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: mixedFixture(operand: "020503030205")))
        let foreignPage = try XCTUnwrap(foreignDocument.page(at: 0))
        var detached: PDFPage? = try autoreleasepool {
            let factory = try XCTUnwrap(PDFRawStreamProvenance.bodyResultFactory(data: mixedFixture()))
            owner = factory.debugLifetimeReferences()
            let copy = try XCTUnwrap(factory.copyPage())
            // Equal native graph alone must not attach holder to the member
            // page already owned by that holder's document.
            PDFRawStreamProvenance.inherit(from: copy, to: try XCTUnwrap(owner?.originalPage))
            PDFRawStreamProvenance.inherit(from: copy, to: foreignPage)
            return copy
        }
        XCTAssertNotNil(owner?.document)
        XCTAssertEqual(detached?.string, "问文说\n123")
        autoreleasepool { detached = nil }
        XCTAssertNil(owner?.factory)
        XCTAssertNil(owner?.document, "The still-live foreign page must not retain the old factory.")
        XCTAssertNil(owner?.originalPage)
        XCTAssertEqual(foreignPage.string, "说文说\n123")
    }

    func testFactoryRejectsEmptyOversizedAndMultiPageInput() throws {
        XCTAssertNil(PDFRawStreamProvenance.bodyResultFactory(data: Data()))
        autoreleasepool {
            XCTAssertNil(PDFRawStreamProvenance.bodyResultFactory(data: Data(repeating: 0, count: 64 * 1_024 * 1_024 + 1)))
        }
        let multiple = try latinFixture(pageCount: 2)
        XCTAssertEqual(PDFDocument(data: multiple)?.pageCount, 2)
        XCTAssertNil(PDFRawStreamProvenance.bodyResultFactory(data: multiple))
        XCTAssertNotNil(PDFRawStreamProvenance.bodyResultFactory(data: try mixedFixture()))
    }

    func testFixedFactoryOutputSurvivesPageInsertionHistoryAndTwoAtomicColdCycles() throws {
        let directory = try temporaryDirectory()
        let owners = try autoreleasepool { () throws -> [WeakOwner] in
            let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: mixedFixture()))
            let history = PDFEditHistory()
            let navigation = PDFEditNavigationSnapshot(currentPageIndex: 0, selectedPages: [0])
            var owners: [WeakOwner] = []
            for (cycle, entry) in [("020503030205", "说文说\n123"), ("020502050205", "说说说\n123")].enumerated() {
                let original = try XCTUnwrap(document.page(at: 0))
                let before = try XCTUnwrap(original.string)
                let replacement = try autoreleasepool { () throws -> PDFPage in
                    let factory = try XCTUnwrap(PDFRawStreamProvenance.bodyResultFactory(data: mixedFixture(operand: entry.0)))
                    owners.append(factory.debugLifetimeReferences())
                    return try XCTUnwrap(factory.copyPage())
                }
                XCTAssertEqual(replacement.string, entry.1)
                func swap(_ expected: PDFPage, _ target: PDFPage) throws {
                    XCTAssertTrue(document.page(at: 0) === expected)
                    XCTAssertEqual(document.index(for: target), NSNotFound)
                    document.removePage(at: 0); document.insert(target, at: 0)
                }
                try swap(original, replacement)
                XCTAssertEqual(document.page(at: 0)?.string, entry.1)
                XCTAssertTrue(history.register(actionName: "Owned body result", beforeNavigation: navigation,
                    afterNavigation: navigation, retainedPageCost: 1,
                    undo: { try swap(replacement, original) }, redo: { try swap(original, replacement) }))
                _ = try history.undo(); XCTAssertTrue(document.page(at: 0) === original)
                XCTAssertEqual(original.string, before)
                _ = try history.redo(); XCTAssertTrue(document.page(at: 0) === replacement)
                XCTAssertEqual(replacement.string, entry.1)
                let output = directory.appendingPathComponent("fixed-cold-\(cycle).pdf")
                try atomicSave(document, to: output)
                let cold = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Data(contentsOf: output)))
                XCTAssertEqual(cold.page(at: 0)?.string, entry.1)
                XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(cold.page(at: 0))),
                    try PDFBodyTextPageSnapshot.contentData(for: replacement))
            }
            history.reset()
            document.removePage(at: 0)
            return owners
        }
        XCTAssertEqual(owners.count, 2)
        for owner in owners {
            XCTAssertNil(owner.factory); XCTAssertNil(owner.document); XCTAssertNil(owner.originalPage)
        }
    }

    func testWorkspaceBodyEditUndoRedoAndTwoAtomicColdReopensKeepExactText() throws {
        let directory = try temporaryDirectory()
        let input = directory.appendingPathComponent("workspace-original.pdf")
        let bytes = try latinFixture(pageCount: 1)
        try bytes.write(to: input, options: .withoutOverwriting)
        var current = input
        for (cycle, pair) in [("Original text", "Changed text"), ("Changed text", "Updated text")].enumerated() {
            try autoreleasepool {
                let workspace = PDFWorkspaceState()
                XCTAssertTrue(workspace.open(url: current)); workspace.setMode(.editing)
                let document = try XCTUnwrap(workspace.document), original = try XCTUnwrap(document.page(at: 0))
                let before = try XCTUnwrap(original.string)
                let boxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
                let originalBounds = boxes.map { original.bounds(for: $0) }
                let originalRotation = original.rotation
                XCTAssertEqual(before.components(separatedBy: pair.0).count, 2)
                let expected = before.replacingOccurrences(of: pair.0, with: pair.1)
                let selection = try XCTUnwrap(document.findString(pair.0, withOptions: []).first)
                XCTAssertTrue(workspace.requestBodyTextEdit(selection: selection))
                let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
                XCTAssertEqual(draft.text, pair.0)
                let note: PDFAnnotation
                if let existing = original.annotations.first(where: { $0.contents == "Owned note" }) {
                    note = existing
                } else {
                    note = PDFAnnotation(bounds: CGRect(x: 5, y: 5, width: 10, height: 10), forType: .square, withProperties: nil)
                    note.contents = "Owned note"; original.addAnnotation(note)
                }
                workspace.commitPendingInlineText(id: draft.id, text: pair.1, style: draft.style, bounds: draft.bounds)
                XCTAssertNil(workspace.pendingInlineTextEdit); XCTAssertNil(workspace.presentedError)
                let edited = try XCTUnwrap(document.page(at: 0))
                XCTAssertFalse(edited === original)
                XCTAssertEqual(boxes.map { edited.bounds(for: $0) }, originalBounds)
                XCTAssertEqual(edited.rotation, originalRotation)
                XCTAssertEqual(edited.string, expected)
                XCTAssertTrue(edited.annotations.contains { $0 === note })
                XCTAssertEqual(note.bounds, CGRect(x: 5, y: 5, width: 10, height: 10))
                XCTAssertEqual(note.contents, "Owned note")
                workspace.undo(); XCTAssertTrue(document.page(at: 0) === original)
                XCTAssertEqual(original.string, before)
                workspace.redo(); XCTAssertTrue(document.page(at: 0) === edited)
                XCTAssertEqual(edited.string, expected)
                let output = directory.appendingPathComponent("workspace-cold-\(cycle).pdf")
                try atomicSave(document, to: output)
                PDFBodyTextDocumentFonts.invalidate(document)
                let cold = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Data(contentsOf: output)))
                let coldPage = try XCTUnwrap(cold.page(at: 0))
                XCTAssertEqual(coldPage.string, expected)
                XCTAssertEqual(boxes.map { coldPage.bounds(for: $0) }, originalBounds)
                XCTAssertEqual(coldPage.rotation, originalRotation)
                let coldNotes = coldPage.annotations.filter { $0.contents == "Owned note" }
                XCTAssertEqual(coldNotes.count, 1)
                XCTAssertEqual(coldNotes.first?.bounds, note.bounds)
                current = output
                workspace.closeDiscardingChanges()
                XCTAssertNil(workspace.document)
            }
        }
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-Owned-BodyOwner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { [weak self] in
            guard (self?.testRun?.totalFailureCount ?? 1) == 0 else { return }
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
    private func latinFixture(pageCount: Int) throws -> Data {
        let bytes = NSMutableData(); var media = CGRect(x: 0, y: 0, width: 400, height: 420)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &media, nil))
        let font = try XCTUnwrap(NSFont(name: "Helvetica", size: 18))
        for _ in 0..<pageCount {
            context.beginPDFPage(nil)
            for (text, y) in [("Original text", 300.0), ("Unaffected text", 150.0)] {
                context.textPosition = CGPoint(x: 50, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), context)
            }
            context.endPDFPage()
        }
        context.closePDF(); return bytes as Data
    }
    private final class Completion: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0), lock = NSLock()
        var result: Result<Void, Error>?
        func publish(_ value: Result<Void, Error>) { lock.lock(); result = value; lock.unlock(); ready.signal() }
        func take() -> Result<Void, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    }
    private func atomicSave(_ document: PDFDocument, to url: URL) throws {
        let snapshot = try PDFRecoverySnapshot(capturing: document), completion = Completion()
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, Error> = autoreleasepool {
                Result { _ = try AtomicPDFWriter.write(snapshot.takeDocument(), to: url) }
            }
            completion.publish(result)
        }
        let deadline = Date().addingTimeInterval(30)
        while completion.ready.wait(timeout: .now()) != .success {
            guard Date() < deadline else { throw NSError(domain: "OwnedBodyResultWriterTimeout", code: 1) }
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
        try XCTUnwrap(completion.take()).get()
    }

    // Three tiny FontTools-created programs/maps copied from the owned
    // nonidentity fixture. Raw assembly is independent of any CJK edit engine.
    private func mixedFixture(operand: String = "011103030205") throws -> Data {
        XCTAssertTrue(["011103030205", "020503030205", "020502050205"].contains(operand))
        let program = try XCTUnwrap(Data(base64Encoded: "AQAEAQABAQERT3duZWRDSUREaXN0aW5jdAABAQEe+Bv4HIsMHouL+bT5UAX5mAwi2w/iDCX3Jgwk5xEAAgEBBg5BZG9iZUlkZW50aXR5AAAAARECBQMDAAAAAAAABAEBChcjL/p8ixbv7ycGDvp8ixb5tAb8JPlQBQ76fO8W+Oz5UPzsBg76fL0W+VD47P1QBg4AAQEBBYv3LxI="))
        let cmap = try XCTUnwrap(Data(base64Encoded: "YmVnaW5jbWFwCi9DTWFwVHlwZSAyIGRlZgoxIGJlZ2luY29kZXNwYWNlcmFuZ2UKPDAwMDA+IDxGRkZGPgplbmRjb2Rlc3BhY2VyYW5nZQozIGJlZ2luYmZjaGFyCjwwMTExPiA8OTVFRT4KPDAyMDU+IDw4QkY0Pgo8MDMwMz4gPDY1ODc+CmVuZGJmY2hhcgplbmRjbWFwCg=="))
        let simple = try XCTUnwrap(Data(base64Encoded: "AQAEAQABAQEPV09SS19DRkZfTGF0aW4AAQEBGfgeAvgeA/gYBL2L+Lr5UAXdD4v3KhLhEQAEAQEDBQcVZzFnMmczV09SS19DRkZfTGF0aW4AAAEBhwIABAEBDRotOfjs2xb4TPlQ/EwGDvjsvRb4iAb7jvlQBQ747O8W+CT3jvsq+FYn/Fb7KgYO+OzbFvhM+VD8TAYO"))
        let content = Data(("0 g BT /F1 20 Tf 0 Tc 0 Tw 100 Tz 0 Ts 0 Tr 1 0 0 1 40 40 Tm <" + operand
            + "> Tj ET\nBT /F2 12 Tf 0 Tc 0 Tw 100 Tz 0 Ts 0 Tr 1 0 0 1 20 15 Tm <010203> Tj ET\n").utf8)
        func stream(_ bytes: Data, extra: String = "") -> Data {
            var out = Data("<< /Length \(bytes.count) \(extra)>>\nstream\n".utf8)
            out.append(bytes); out.append(Data("\nendstream".utf8)); return out
        }
        let simpleMap = Data("begincmap\n/CMapType 2 def\n1 begincodespacerange\n<00> <FF>\nendcodespacerange\n3 beginbfchar\n<01> <0031>\n<02> <0032>\n<03> <0033>\nendbfchar\nendcmap\n".utf8)
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 140 100] /Resources << /Font << /F1 5 0 R /F2 10 0 R >> >> /Contents 4 0 R >>".utf8),
            stream(content),
            Data("<< /Type /Font /Subtype /Type0 /BaseFont /OwnedCIDDistinct /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 9 0 R >>".utf8),
            Data("<< /Type /Font /Subtype /CIDFontType0 /BaseFont /OwnedCIDDistinct /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor 7 0 R /DW 1000 /W [273 [1000] 517 [1000] 771 [1000]] >>".utf8),
            Data("<< /Type /FontDescriptor /FontName /OwnedCIDDistinct /Flags 4 /FontBBox [-250 0 800 700] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 /FontFile3 8 0 R >>".utf8),
            stream(program, extra: "/Subtype /CIDFontType0C "), stream(cmap),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /WORK_CFF_Latin /EmberPDFBodyOriginalBaseFont /DoNotInterpretInputMarker /Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [1 /g1 /g2 /g3] >> /FirstChar 1 /LastChar 3 /Widths [600 600 600] /FontDescriptor 11 0 R /ToUnicode 13 0 R >>".utf8),
            Data("<< /Type /FontDescriptor /FontName /WORK_CFF_Latin /Flags 32 /FontBBox [0 -100 600 700] /ItalicAngle 0 /Ascent 700 /Descent -100 /CapHeight 700 /StemV 80 /FontFile3 12 0 R >>".utf8),
            stream(simple, extra: "/Subtype /Type1C "), stream(simpleMap)]
        var out = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(out.count); out.append(Data("\(index + 1) 0 obj\n".utf8))
            out.append(object); out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        out.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { out.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        out.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return out
    }
}

#endif
