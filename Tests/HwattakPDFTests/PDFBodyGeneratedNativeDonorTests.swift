// SPDX-License-Identifier: MPL-2.0

import AppKit
import CPDFium
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyGeneratedNativeDonorTests: XCTestCase {
    func testOnlyTheFreshNativeDonorGainsAnOwnershipMarker() throws {
        let document = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        let original = try PDFBodyTextPageSnapshot.originalPageData(for: page)
        XCTAssertEqual(try markerCount(page), 0)
        let fixedMask = CGRect(x: 30, y: 165, width: 110, height: 35)
        let outside = try pixelsOutside(page, mask: fixedMask)
        let target = try selected("beta", page: page, document: document)
        XCTAssertEqual(target.text, "alpha beta")
        let originalShape = try formSummary(page)
        XCTAssertEqual(originalShape.formCount, 2)
        XCTAssertEqual(originalShape.childCounts, [2, 1],
            "The independently read original has two editable text children and one unrelated sibling.")
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
            text: target.text.replacingOccurrences(of: "beta", with: "zeta"),
            style: target.style, bounds: target.bounds)
        XCTAssertEqual(try markerCount(edited), 1,
            "Only the Form created during this native Apply may acquire the marker.")
        XCTAssertEqual(try pixelsOutside(edited, mask: fixedMask), outside)
        XCTAssertEqual(try PDFBodyTextPageSnapshot.originalPageData(for: page), original)
        XCTAssertEqual(try markerCount(page), 0)
        let structure = try formSummary(edited)
        XCTAssertEqual(structure.formCount, 2)
        XCTAssertGreaterThanOrEqual(structure.inertChildrenInMarkedForms, 1,
            "The positive fixture must include the real unowned, no-ink space child.")
    }

    func testGeneratedSpaceKeepsExactTextAndTwoAtomicColdEdits() throws {
        let original = try fixture()
        let page = try XCTUnwrap(original.page(at: 0))
        let first = try selected("beta", page: page, document: original)
        let baselineText = try XCTUnwrap(page.string)
        let expected = baselineText.replacingOccurrences(of: "beta", with: "zeta")
        let edited = try PDFBodyTextEditor.replacementPage(for: page, target: first,
            text: first.text.replacingOccurrences(of: "beta", with: "zeta"),
            style: first.style, bounds: first.bounds)
        XCTAssertEqual(edited.string, expected)
        XCTAssertGreaterThanOrEqual(try formSummary(edited).inertChildrenInMarkedForms, 1)
        let document = PDFDocument(); document.insert(edited, at: 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GeneratedDonor-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var current = document
        for (index, pair) in [("zeta", "beta"), ("beta", "zeta")].enumerated() {
            let url = folder.appendingPathComponent("cold-\(index).pdf")
            try atomicSave(current, to: url)
            let cold = try XCTUnwrap(PDFDocument(url: url)), coldPage = try XCTUnwrap(cold.page(at: 0))
            XCTAssertEqual(coldPage.string, index == 0 ? expected : baselineText)
            XCTAssertEqual(try markerCount(coldPage), 1)
            let target = try selected(pair.0, page: coldPage, document: cold)
            let replacement = try PDFBodyTextEditor.replacementPage(for: coldPage, target: target,
                text: target.text.replacingOccurrences(of: pair.0, with: pair.1),
                style: target.style, bounds: target.bounds)
            XCTAssertEqual(replacement.string, index == 0 ? baselineText : expected)
            cold.removePage(at: 0); cold.insert(replacement, at: 0); current = cold
        }
        XCTAssertEqual(original.page(at: 0)?.string, baselineText)
    }

    func testForeignVisibleEmptyTextAndRepeatedFormsStayUnmarkedAndRefused() throws {
        for options in [(true, false), (false, true)] {
            let document = try fixture(visibleEmptyText: options.0, repeated: options.1)
            let page = try XCTUnwrap(document.page(at: 0))
            let before = try PDFBodyTextPageSnapshot.originalPageData(for: page)
            let selection = try XCTUnwrap(document.findString("beta", withOptions: []).first)
            do {
                if let target = try PDFBodyTextEditor.target(on: page, selection: selection) {
                    XCTAssertThrowsError(try PDFBodyTextEditor.replacementPage(for: page, target: target,
                        text: target.text.replacingOccurrences(of: "beta", with: "zeta"),
                        style: target.style, bounds: target.bounds))
                }
            } catch { /* Existing refusal remains valid; no new ownership is issued. */ }
            XCTAssertEqual(try markerCount(page), 0)
            XCTAssertEqual(try PDFBodyTextPageSnapshot.originalPageData(for: page), before)
        }
    }

    private func selected(_ text: String, page: PDFPage, document: PDFDocument) throws -> PDFBodyTextTarget {
        let selection = try XCTUnwrap(document.findString(text, withOptions: []).first)
        return try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
    }

    private func markerCount(_ page: PDFPage) throws -> Int {
        let stream = try PDFBodyTextContentStream.parse(PDFBodyTextPageSnapshot.contentData(for: page))
        return stream.forms.filter { PDFBodyTextPageSnapshot.isBodyTextXObject(named: $0.name, on: page) }.count
    }

    private func formSummary(_ page: PDFPage) throws -> (formCount: Int, childCounts: [Int], inertChildrenInMarkedForms: Int) {
        let data = try PDFBodyTextPageSnapshot.originalPageData(for: page)
        let stream = try PDFBodyTextContentStream.parse(PDFBodyTextPageSnapshot.contentData(for: page))
        XCTAssertEqual(stream.forms.count, 2)
        let markedOrdinals = Set(stream.forms.indices.filter {
            PDFBodyTextPageSnapshot.isBodyTextXObject(named: stream.forms[$0].name, on: page)
        })
        return try data.withUnsafeBytes { bytes in
            let document = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(document) }
            let native = try XCTUnwrap(FPDF_LoadPage(document, 0)); defer { FPDF_ClosePage(native) }
            let text = try XCTUnwrap(FPDFText_LoadPage(native)); defer { FPDFText_ClosePage(text) }
            let count = FPDFText_CountChars(text); XCTAssertGreaterThanOrEqual(count, 0)
            let owners = Set((0..<count).compactMap { FPDFText_GetTextObject(text, $0) })
            XCTAssertEqual(FPDFPage_CountObjects(native), 2,
                "This controlled fixture has only two root Form invocations and no inline images.")
            var forms = 0, inert = 0
            var childCounts: [Int] = []
            for index in 0..<FPDFPage_CountObjects(native) {
                let object = try XCTUnwrap(FPDFPage_GetObject(native, index))
                guard FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_FORM else { continue }
                childCounts.append(Int(FPDFFormObj_CountObjects(object)))
                let marked = markedOrdinals.contains(forms); forms += 1
                guard marked else { continue }
                for childIndex in 0..<FPDFFormObj_CountObjects(object) {
                    let child = try XCTUnwrap(FPDFFormObj_GetObject(object, UInt(childIndex)))
                    if PDFBodyTextEditor.isInertEmptySpace(child, in: text, hasOwnedCharacters: owners.contains(child)) {
                        inert += 1
                    }
                }
            }
            return (forms, childCounts, inert)
        }
    }

    private func fixture(visibleEmptyText: Bool = false, repeated: Bool = false) throws -> PDFDocument {
        let hidden = visibleEmptyText
            ? " /Span << /ActualText ( ) >> BDC BT /F1 11 Tf 1 0 0 1 68 180 Tm (X) Tj ET EMC " : " "
        let edited = "BT /F1 11 Tf 1 0 0 1 40 180 Tm (alpha) Tj ET" + hidden
            + "BT /F1 11 Tf 1 0 0 1 72 180 Tm (beta) Tj ET"
        let foreign = "BT /F1 11 Tf 1 0 0 1 40 100 Tm (KEEP) Tj ET"
        let root = "q /Editable Do Q q /Foreign Do Q" + (repeated ? " q 1 0 0 1 150 0 cm /Editable Do Q" : "")
        return try XCTUnwrap(PDFDocument(data: PDFMalformedSelectionTestFixture.pdfData(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /XObject << /Editable 6 0 R /Foreign 7 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(root.utf8.count) >>\nstream\n\(root)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> >> /Length \(edited.utf8.count) >>\nstream\n\(edited)\nendstream",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> >> /Length \(foreign.utf8.count) >>\nstream\n\(foreign)\nendstream"
        ])))
    }

    private func pixelsOutside(_ page: PDFPage, mask: CGRect) throws -> Data {
        let width = 800, height = 600, stride = width * 4
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 2, y: 2); context.drawPDFPage(try XCTUnwrap(page.pageRef))
        context.setFillColor(NSColor.white.cgColor); context.fill(mask)
        return Data(bytes: try XCTUnwrap(context.data), count: stride * height)
    }

    private final class Completion: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0), lock = NSLock()
        var result: Result<Void, Error>?
        func publish(_ value: Result<Void, Error>) { lock.lock(); result = value; lock.unlock(); semaphore.signal() }
        func take() -> Result<Void, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    }
    private func atomicSave(_ document: PDFDocument, to url: URL) throws {
        let snapshot = try PDFRecoverySnapshot(capturing: document), completion = Completion()
        DispatchQueue.global(qos: .userInitiated).async {
            do { try AtomicPDFWriter.write(snapshot.takeDocument(), to: url); completion.publish(.success(())) }
            catch { completion.publish(.failure(error)) }
        }
        while completion.semaphore.wait(timeout: .now()) != .success { CFRunLoopRunInMode(.defaultMode, 0.01, true) }
        try XCTUnwrap(completion.take()).get()
    }
}
