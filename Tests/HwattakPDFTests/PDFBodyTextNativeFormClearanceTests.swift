// SPDX-License-Identifier: MPL-2.0
// Owned structural fixtures only. No corpus input or private plan injection.
import AppKit
import CPDFium
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextNativeFormClearanceTests: XCTestCase {
    private let phrase = "Nested line"
    private let media = CGRect(x: 0, y: 0, width: 400, height: 500)

    func testFullySelectedSingleChildFormsHaveTheSameBlankClearanceAsRootText() throws {
        let root = try fixture(depth: 0)
        let rootPage = try XCTUnwrap(root.page(at: 0))
        let rootBefore = try PDFBodyTextPageSnapshot.data(for: rootPage)
        let rootTarget = try target(in: root)
        XCTAssertEqual(rootTarget.text, phrase)
        XCTAssertEqual(rootTarget.paintBounds, media)
        let rootGeometry = try nativeChainBounds(rootPage, expectedDepth: 0)

        for depth in [1, 2] {
            let wrapped = try fixture(depth: depth), page = try XCTUnwrap(wrapped.page(at: 0))
            let before = try PDFBodyTextPageSnapshot.data(for: page)
            // Admission executes existing resolve/validateNativeGraphics first.
            let selected = try target(in: wrapped)
            let geometry = try nativeChainBounds(page, expectedDepth: depth)
            XCTAssertEqual(selected.text, rootTarget.text)
            XCTAssertEqual(selected.baseline, rootTarget.baseline)
            XCTAssertEqual(geometry.leaf, rootGeometry.leaf)
            XCTAssertEqual(selected.bounds, rootTarget.bounds)
            emit(depth: depth, source: selected.bounds,
                rootObject: geometry.root, leaf: geometry.leaf, declared: selected.paintBounds)
            // This compares with an independent blank-page/root-text control,
            // not a declaration recovered from this Form's own metadata.
            XCTAssertEqual(selected.paintBounds, rootTarget.paintBounds,
                "A complete unshared text-only chain must not count itself as unrelated paint.")
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
        }
        XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: rootPage), rootBefore)
    }

    func testSingleChildFormClearanceStillStopsAtIndependentRootArtwork() throws {
        let root = try fixture(depth: 0, obstacle: true)
        let control = try target(in: root)
        XCTAssertLessThan(control.bounds.maxX, 170)
        XCTAssertEqual(control.paintBounds.maxX, 170)
        for depth in [1, 2] {
            let wrapped = try fixture(depth: depth, obstacle: true)
            let page = try XCTUnwrap(wrapped.page(at: 0))
            let before = try PDFBodyTextPageSnapshot.data(for: page)
            let selected = try target(in: wrapped)
            XCTAssertEqual(selected.paintBounds, control.paintBounds)
            XCTAssertEqual(selected.paintBounds.maxX, 170,
                "Removing a self obstacle must not remove an independent painted root.")
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
        }
    }

    func testUnselectedSharedClippedAndPaintedFormLookalikesRemainRefused() throws {
        for variant in [Variant.ancestorTextSibling, .sharedInvocation, .clip, .ancestorArtwork] {
            let document = try fixture(depth: 2, variant: variant)
            let page = try XCTUnwrap(document.page(at: 0))
            let before = try PDFBodyTextPageSnapshot.data(for: page)
            let textBefore = page.string
            let selection = try XCTUnwrap(document.findString(phrase, withOptions: []).first)
            var refused = false
            do { refused = try PDFBodyTextEditor.target(on: page, selection: selection) == nil }
            catch { refused = true }
            XCTAssertTrue(refused, "Unsafe Form control must remain unavailable: \(variant.rawValue)")
            XCTAssertEqual(try PDFBodyTextPageSnapshot.data(for: page), before)
            XCTAssertEqual(page.string, textBefore)
        }
    }

    private enum Variant: String { case plain, ancestorTextSibling, sharedInvocation, clip, ancestorArtwork }

    private func target(in document: PDFDocument) throws -> PDFBodyTextTarget {
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString(phrase, withOptions: []).first)
        return try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
    }

    private func fixture(depth: Int, obstacle: Bool = false, variant: Variant = .plain) throws -> PDFDocument {
        guard (0...2).contains(depth), variant == .plain || depth == 2 else {
            throw NSError(domain: "OwnedFormFixtureDepth", code: 1)
        }
        let text = "BT /F1 20 Tf 1 0 0 1 40 400 Tm (\(phrase)) Tj ET"
        let child = "/Inner Do"
        let outer: String
        switch variant {
        case .ancestorTextSibling:
            outer = "BT /F1 20 Tf 1 0 0 1 40 100 Tm (Unselected sibling) Tj ET " + child
        case .ancestorArtwork: outer = "q 1 0 0 rg 20 20 30 30 re f Q " + child
        default: outer = child
        }
        var contents = depth == 0 ? text : (depth == 1 ? "/Inner Do" : "/Outer Do")
        if variant == .sharedInvocation { contents += " q 1 0 0 1 0 -100 cm /Outer Do Q" }
        if variant == .clip { contents = "q 45 390 70 35 re W n " + contents + " Q" }
        if obstacle { contents += " q 0.7 g 170 390 20 40 re f Q" }
        // Unreferenced resources do not paint; every positive invocation chain
        // is uniquely invoked and contains exactly one child at each level.
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /Resources << /Font << /F1 4 0 R >> /XObject << /Outer 5 0 R /Inner 6 0 R >> >> /Contents 7 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            stream(outer, dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 400 500] /Resources << /Font << /F1 4 0 R >> /XObject << /Inner 6 0 R >> >>"),
            stream(text, dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 400 500] /Resources << /Font << /F1 4 0 R >> >>"),
            stream(contents)
        ]
        let data = PDFMalformedSelectionTestFixture.pdfData(objects: objects)
        guard data.count < 16 * 1_024 else { throw NSError(domain: "OwnedFormFixtureBytes", code: 1) }
        return try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: data))
    }

    private func stream(_ value: String, dictionary: String = "") -> String {
        "<< \(dictionary) /Length \(value.utf8.count) >>\nstream\n\(value)\nendstream"
    }

    /// Observe the actual loaded native object shape independently of target
    /// metadata. Called only after a product target initializes PDFium.
    private func nativeChainBounds(_ page: PDFPage, expectedDepth: Int) throws -> (root: CGRect, leaf: CGRect) {
        let data = try PDFBodyTextPageSnapshot.data(for: page)
        guard data.count < 64 * 1_024 else { throw NSError(domain: "OwnedNativeShapeBytes", code: 1) }
        return try data.withUnsafeBytes { bytes in
            let doc = try XCTUnwrap(FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil))
            defer { FPDF_CloseDocument(doc) }
            let native = try XCTUnwrap(FPDF_LoadPage(doc, 0))
            defer { FPDF_ClosePage(native) }
            XCTAssertEqual(FPDFPage_CountObjects(native), 1)
            var object = try XCTUnwrap(FPDFPage_GetObject(native, 0))
            let rootBounds = try bounds(object)
            for _ in 0..<expectedDepth {
                XCTAssertEqual(FPDFPageObj_GetType(object), FPDF_PAGEOBJ_FORM)
                XCTAssertEqual(FPDFFormObj_CountObjects(object), 1)
                object = try XCTUnwrap(FPDFFormObj_GetObject(object, 0))
            }
            XCTAssertEqual(FPDFPageObj_GetType(object), FPDF_PAGEOBJ_TEXT)
            XCTAssertEqual(FPDFTextObj_GetTextRenderMode(object), FPDF_TEXTRENDERMODE_FILL)
            return (rootBounds, try bounds(object))
        }
    }

    private func bounds(_ object: FPDF_PAGEOBJECT) throws -> CGRect {
        var l: Float = 0, b: Float = 0, r: Float = 0, t: Float = 0
        guard FPDFPageObj_GetBounds(object, &l, &b, &r, &t) != 0,
              [l, b, r, t].allSatisfy(\.isFinite), r >= l, t >= b else {
            throw NSError(domain: "OwnedNativeShapeBounds", code: 1)
        }
        return CGRect(x: CGFloat(l), y: CGFloat(b), width: CGFloat(r - l), height: CGFloat(t - b))
    }

    private func emit(depth: Int, source: CGRect, rootObject: CGRect, leaf: CGRect, declared: CGRect) {
        func rect(_ value: CGRect) -> [CGFloat] { [value.minX, value.minY, value.maxX, value.maxY] }
        let observation: [String: Any] = ["depth": depth, "targetBounds": rect(source),
            "rootObject": rect(rootObject), "leaf": rect(leaf), "declared": rect(declared)]
        guard let data = try? JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]),
              data.count <= 2048 else { XCTFail("Owned observation cap"); return }
        FileHandle.standardError.write(Data("OWNED_NATIVE_FORM_CLEARANCE ".utf8) + data + Data([10]))
    }
}
