// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

/// Owned PDFs only. These tests separate unchanged Link OBJR authority from
/// the edited page's old MCIDs and Form resources.
@MainActor
final class PDFBodyEditedAnnotationTagTests: XCTestCase {
    func testUnchangedLinkTagSurvivesTwoColdBodyEditsOnAnnotationOnlyPage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var bytes = fixture(formTag: false, pageTag: false)
        for (index, pair) in [("Body one", "Body two"), ("Body two", "Body one")].enumerated() {
            let workspace = try opened(bytes, in: directory, name: "cold-\(index)")
            let source = try XCTUnwrap(workspace.document)
            let before = try XCTUnwrap(source.page(at: 0)?.annotations.first)
            try edit(pair.0, to: pair.1, in: workspace)
            XCTAssertTrue(source.page(at: 0)?.annotations.first === before)
            bytes = try await saved(source, in: directory, name: "cycle-\(index)")
            let cold = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
            XCTAssertTrue(cold.page(at: 0)?.string?.contains(pair.1) == true)
            try assertTags(cold, links: 1)
        }
    }

    func testDetachedLinkForestAndPureAnnotationAltSurviveWithoutInventingARootEdge() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try opened(fixture(detached: true, formTag: false, pageTag: false), in: directory, name: "detached")
        try edit("Body one", to: "Body two", in: workspace)
        let bytes = try await saved(XCTUnwrap(workspace.document), in: directory, name: "detached-saved")
        let cold = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
        try assertTags(cold, links: 1, detached: true)
        let owner = try taggedLinkOwner(cold)
        XCTAssertNotNil(PDFCatalogStructurePreserver.object(owner, "Alt"))
        XCTAssertNil(PDFCatalogStructurePreserver.object(owner, "P"))
    }

    func testMovedDeletedForeignAndChangedLinksCannotBorrowTheOldOBJR() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for mutation in ["move", "delete", "foreign", "changed", "explicitIntent"] {
            let workspace = try opened(fixture(), in: directory, name: mutation)
            let document = try XCTUnwrap(workspace.document)
            let page = try XCTUnwrap(document.page(at: 0))
            let link = try XCTUnwrap(page.annotations.first)
            try PDFCatalogStructurePreserver.prepare(document, force: true)
            switch mutation {
            case "move":
                page.removeAnnotation(link)
                try XCTUnwrap(document.page(at: 1)).addAnnotation(link)
            case "delete": page.removeAnnotation(link)
            case "foreign":
                page.removeAnnotation(link)
                let foreign = PDFAnnotation(bounds: link.bounds, forType: .link, withProperties: nil)
                foreign.contents = link.contents
                foreign.action = PDFActionURL(url: URL(string: "https://example.invalid/")!)
                foreign.setValue(3, forAnnotationKey: .init(rawValue: "/StructParent"))
                page.addAnnotation(foreign)
            case "changed": link.bounds = link.bounds.offsetBy(dx: 1, dy: 0)
            default: PDFCatalogStructurePreserver.recordExplicitAnnotationEdit(in: document)
            }
            try edit("Body one", to: "Body two", in: workspace)
            try await assertTagSaveRefused(document, in: directory, name: mutation + "-saved")
        }
    }

    func testSharedRemovedBodySemanticOverridesDoNotSurviveThroughTheLink() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for key in ["ActualText", "Alt", "E", "T"] {
            let workspace = try opened(fixture(sharedSemantic: key), in: directory, name: key)
            try edit("Body one", to: "Body two", in: workspace)
            let document = try XCTUnwrap(workspace.document)
            try await assertTagSaveRefused(document, in: directory, name: key + "-saved")
            XCTAssertTrue(document.page(at: 0)?.string?.contains("Body two") == true)
        }
    }

    func testQualifiedAuxiliaryRebindsOnlyTheProvenLinkAndOriginalFallbackStillWorks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try opened(fixture(detached: true, formTag: false), in: directory, name: "auxiliary")
        try edit("Body one", to: "Body two", in: workspace)
        let snapshot = try PDFRecoverySnapshot(capturing: XCTUnwrap(workspace.document))
        let result = try await Task.detached { () throws -> (Bool, Int, Int, Bool) in
            let document = try snapshot.takeDocument()
            let originalPlan = try PDFCatalogStructurePreserver.plan(for: document)
            let proof = try XCTUnwrap(originalPlan.linkControlProofs.first)
            // The helper is a separately bounded process; an unavailable helper
            // is an explicit skip, never a successful auxiliary test.
            guard let auxiliary = try PDFTagReadAuxiliary.create(immutableSource: proof.originalRaw, owner: proof.originalDocument) else {
                return (false, originalPlan.annotationTagPermissions.count, 0, false)
            }
            let rebound = try PDFCatalogStructurePreserver.plan(for: document, tagReadAuxiliary: auxiliary)
            return (true, originalPlan.annotationTagPermissions.count, rebound.annotationTagPermissions.count,
                    rebound.annotationTagPermissions[0]?.tagDocument === auxiliary.document)
        }.value
        guard result.0 else { throw XCTSkip("Qualified tag reader helper unavailable; original-reader admission was exercised only.") }
        XCTAssertEqual(result.1, 1)
        XCTAssertEqual(result.2, 1)
        XCTAssertTrue(result.3, "An original-reader fallback is not auxiliary rebind proof.")
    }

    func testUntaggedLinkAndEmptyMetadataSiblingDoNotExpandOrCancelTheTaggedLinkPermission() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try opened(fixture(formTag: false, extraLinkKey: -1, emptySibling: true, pageTag: false), in: directory, name: "mixed-links")
        try edit("Body one", to: "Body two", in: workspace)
        let bytes = try await saved(XCTUnwrap(workspace.document), in: directory, name: "mixed-links-saved")
        let cold = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
        XCTAssertEqual(cold.page(at: 0)?.annotations.count, 2)
        try assertTags(cold, links: 1)
        let root = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(XCTUnwrap(cold.documentRef?.catalog), "StructTreeRoot"))
        let kids = try XCTUnwrap(PDFCatalogStructurePreserver.array(root, "K"))
        XCTAssertEqual(CGPDFArrayGetCount(kids), 1, "No old MCIDs or unrelated empty metadata sibling")
    }

    func testSharedSemanticConflictsAcrossTwoSourceGroupsAreRemovedInOneRetry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try opened(fixture(sharedSemantic: "Alt"), in: directory, name: "group-one")
        let second = try opened(fixture(sharedSemantic: "ActualText"), in: directory, name: "group-two")
        try edit("Body one", to: "Body two", in: first)
        try edit("Body one", to: "Body two", in: second)
        let destination = try XCTUnwrap(first.document)
        XCTAssertEqual(try PDFPageOperations.append(contentsOf: XCTUnwrap(second.document), to: destination), 2)
        try await assertTagSaveRefused(destination, in: directory, name: "two-groups-saved")
        XCTAssertEqual(destination.pageCount, 4)
        XCTAssertTrue(destination.page(at: 0)?.string?.contains("Body two") == true)
        XCTAssertTrue(destination.page(at: 2)?.string?.contains("Body two") == true)
    }

    func testDuplicateOriginalTagKeysRefuseTheOptionalLinkLane() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try opened(fixture(extraLinkKey: 3), in: directory, name: "duplicate-key")
        try edit("Body one", to: "Body two", in: workspace)
        try await assertTagSaveRefused(XCTUnwrap(workspace.document), in: directory, name: "duplicate-key-saved")
    }

    func testCapturedPermissionRefusesLateMembershipOrLinkControlChange() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for mutation in ["delete", "move", "changed"] {
            let workspace = try opened(fixture(), in: directory, name: "late-" + mutation)
            try edit("Body one", to: "Body two", in: workspace)
            let snapshot = try PDFRecoverySnapshot(capturing: XCTUnwrap(workspace.document))
            let refused = try await Task.detached { () throws -> Bool in
                let document = try snapshot.takeDocument()
                let plan = try PDFCatalogStructurePreserver.plan(for: document)
                let permission = try XCTUnwrap(plan.annotationTagPermissions[0])
                XCTAssertTrue(permission.matches())
                let page = try XCTUnwrap(document.page(at: 0))
                let link = try XCTUnwrap(page.annotations.first)
                if mutation == "changed" { link.contents = "Later control change" }
                else {
                    page.removeAnnotation(link)
                    if mutation == "move" { try XCTUnwrap(document.page(at: 1)).addAnnotation(link) }
                }
                return !permission.matches()
            }.value
            XCTAssertTrue(refused, mutation)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-LinkTag-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func opened(_ bytes: Data, in directory: URL, name: String) throws -> PDFWorkspaceState {
        let input = directory.appendingPathComponent(name + ".pdf")
        try bytes.write(to: input, options: .withoutOverwriting)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: input)); workspace.setMode(.editing)
        return workspace
    }
    private func edit(_ old: String, to new: String, in workspace: PDFWorkspaceState) throws {
        let document = try XCTUnwrap(workspace.document)
        let selection = try XCTUnwrap(document.findString(old, withOptions: []).first)
        XCTAssertTrue(workspace.requestBodyTextEdit(selection: selection))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        XCTAssertEqual(draft.text.components(separatedBy: old).count, 2)
        let replacement = draft.text.replacingOccurrences(of: old, with: new)
        workspace.commitPendingInlineText(id: draft.id, text: replacement, style: draft.style, bounds: draft.bounds)
        XCTAssertNil(workspace.pendingInlineTextEdit); XCTAssertNil(workspace.presentedError)
    }
    private func saved(_ document: PDFDocument, in directory: URL, name: String) async throws -> Data {
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let output = directory.appendingPathComponent(name + ".pdf")
        return try await Task.detached {
            try AtomicPDFWriter.write(snapshot.takeDocument(), to: output)
            return try Data(contentsOf: output)
        }.value
    }
    private func assertTagSaveRefused(_ document: PDFDocument, in directory: URL, name: String) async throws {
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let output = directory.appendingPathComponent(name + ".pdf")
        try await Task.detached {
            let staged = try snapshot.takeDocument()
            let plan = try PDFCatalogStructurePreserver.plan(for: staged)
            XCTAssertTrue(plan.annotationTagPermissions.isEmpty)
            XCTAssertNil(plan.pageEntries[0]?["StructParents"])
            XCTAssertThrowsError(try AtomicPDFWriter.write(staged, to: output)) { error in
                XCTAssertEqual((error as? PDFCatalogStructurePreserver.EditedPageTagSaveFailure)?.pageNumber, 1)
            }
        }.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    private func taggedLinkOwner(_ document: PDFDocument) throws -> CGPDFDictionaryRef {
        let native = try XCTUnwrap(document.documentRef)
        let page = try XCTUnwrap(native.page(at: 1)?.dictionary)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
        var link: CGPDFDictionaryRef?, key: CGPDFInteger = -1
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &link))
        XCTAssertTrue(CGPDFDictionaryGetInteger(try XCTUnwrap(link), "StructParent", &key))
        let root = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(try XCTUnwrap(native.catalog), "StructTreeRoot"))
        let tree = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(root, "ParentTree"))
        let nums = try XCTUnwrap(PDFCatalogStructurePreserver.array(tree, "Nums"))
        for index in stride(from: 0, to: CGPDFArrayGetCount(nums), by: 2) {
            var candidate: CGPDFInteger = -1, owner: CGPDFDictionaryRef?
            if CGPDFArrayGetInteger(nums, index, &candidate), candidate == key,
               CGPDFArrayGetDictionary(nums, index + 1, &owner), let owner { return owner }
        }
        throw NSError(domain: "OwnedLinkTagTests", code: 1)
    }
    private func assertTags(_ document: PDFDocument, links expected: Int, detached: Bool = false) throws {
        let native = try XCTUnwrap(document.documentRef), page = try XCTUnwrap(native.page(at: 1)?.dictionary)
        XCTAssertNil(PDFCatalogStructurePreserver.object(page, "StructParents"), "No old page MCID authority")
        if let resources = PDFCatalogStructurePreserver.dictionary(page, "Resources"),
           let forms = PDFCatalogStructurePreserver.dictionary(resources, "XObject") {
            var form: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(forms, "Fm", &form), let form, let dictionary = CGPDFStreamGetDictionary(form) {
                XCTAssertNil(PDFCatalogStructurePreserver.object(dictionary, "StructParents"), "No old Form MCID authority")
            }
        }
        let root = PDFCatalogStructurePreserver.dictionary(try XCTUnwrap(native.catalog), "StructTreeRoot")
        var visited = Set<UInt>(), objrs = 0, mcids = 0
        func walk(_ value: CGPDFObjectRef?, depth: Int) throws {
            guard let value else { return }
            guard depth < 64 else { throw NSError(domain: "OwnedLinkTagTests", code: 2) }
            if CGPDFObjectGetType(value) == .integer { mcids += 1; return }
            if CGPDFObjectGetType(value) == .array {
                var list: CGPDFArrayRef?
                guard CGPDFObjectGetValue(value, .array, &list), let list, CGPDFArrayGetCount(list) < 100 else {
                    throw NSError(domain: "OwnedLinkTagTests", code: 3)
                }
                for index in 0..<CGPDFArrayGetCount(list) {
                    var child: CGPDFObjectRef?
                    XCTAssertTrue(CGPDFArrayGetObject(list, index, &child))
                    try walk(child, depth: depth + 1)
                }
            } else if CGPDFObjectGetType(value) == .dictionary {
                var dictionary: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary else { return XCTFail("Invalid dictionary") }
                guard visited.insert(pdfReferenceIdentity(dictionary)).inserted else { return }
                if PDFCatalogStructurePreserver.object(dictionary, "MCID") != nil { mcids += 1 }
                if let target = PDFCatalogStructurePreserver.dictionary(dictionary, "Obj") {
                    objrs += 1
                    XCTAssertEqual(PDFCatalogStructurePreserver.dictionary(dictionary, "Pg"), page)
                    let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
                    var original: CGPDFDictionaryRef?
                    XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &original)); XCTAssertEqual(original, target)
                }
                try walk(PDFCatalogStructurePreserver.object(dictionary, "K"), depth: depth + 1)
            }
        }
        try walk(root.flatMap { PDFCatalogStructurePreserver.object($0, "K") }, depth: 0)
        XCTAssertEqual(mcids, 0)
        if detached, expected == 1 {
            XCTAssertEqual(objrs, 0, "A detached forest must not acquire a Root.K edge")
            let owner = try taggedLinkOwner(document)
            try walk(PDFCatalogStructurePreserver.object(owner, "K"), depth: 0)
        }
        XCTAssertEqual(objrs, expected)
        if expected == 0, let list = PDFCatalogStructurePreserver.array(page, "Annots") {
            for index in 0..<CGPDFArrayGetCount(list) {
                var annotation: CGPDFDictionaryRef?
                XCTAssertTrue(CGPDFArrayGetDictionary(list, index, &annotation))
                XCTAssertNil(PDFCatalogStructurePreserver.object(try XCTUnwrap(annotation), "StructParent"))
            }
        } else if expected == 1 { _ = try taggedLinkOwner(document) }
    }
    private func fixture(detached: Bool = false, sharedSemantic: String? = nil,
                         formTag: Bool = true, extraLinkKey: Int? = nil, emptySibling: Bool = false,
                         pageTag: Bool = true) -> Data {
        Self.ownedFixture(detached: detached, sharedSemantic: sharedSemantic, formTag: formTag,
                          extraLinkKey: extraLinkKey, emptySibling: emptySibling, pageTag: pageTag)
    }
    nonisolated private static func ownedFixture(detached: Bool = false, sharedSemantic: String? = nil,
                                               formTag: Bool = true, extraLinkKey: Int? = nil,
                                               emptySibling: Bool = false, pageTag: Bool = true) -> Data {
        func stream(_ text: String, entries: String = "") -> String {
            "<< /Length \(text.utf8.count) \(entries) >>\nstream\n\(text)\nendstream"
        }
        let shared = sharedSemantic != nil
        let parent = shared ? "15 0 R" : "8 0 R"
        let pageRoot = pageTag ? "9 0 R " : ""
        var roots = shared ? "15 0 R" : pageRoot + (detached ? "" : "10 0 R")
        if formTag && !shared { roots += " 13 0 R" }
        if emptySibling { roots += " 17 0 R" }
        let annots = extraLinkKey != nil ? "11 0 R 16 0 R" : "11 0 R"
        let formParent = formTag ? "/StructParents 2" : ""
        let formTree = formTag ? "2 [13 0 R]" : ""
        let pageParent = pageTag ? "/StructParents 0" : ""
        let pageTree = pageTag ? "0 [9 0 R]" : ""
        let pageMark = pageTag ? "/P << /MCID 0 >> BDC 0.2 0.3 0.4 rg 10 10 10 10 re f EMC " : ""
        let extraParent = extraLinkKey.flatMap { $0 >= 0 ? "/StructParent \($0)" : nil } ?? ""
        let linkParent = detached ? "" : "/P \(parent)"
        let semantic = sharedSemantic.map { "/\($0) (stale body semantic)" } ?? ""
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 8 0 R /MarkInfo << /Marked true >> >>",
            "<< /Type /Pages /Count 2 /Kids [3 0 R 4 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 420] /Resources << /Font << /F1 7 0 R >> /XObject << /Fm 12 0 R >> >> /Contents 5 0 R \(pageParent) /Annots [\(annots)] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 420] /Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R >>",
            stream(pageMark + "BT /F1 20 Tf 1 0 0 1 40 300 Tm (Body one) Tj ET q /Fm Do Q"),
            stream("BT /F1 20 Tf 1 0 0 1 40 300 Tm (Untouched page) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /StructTreeRoot /K [\(roots)] /ParentTree 14 0 R /ParentTreeNextKey 4 >>",
            "<< /Type /StructElem /S /P /P \(parent) /Pg 3 0 R /K 0 >>",
            "<< /Type /StructElem /S /Link \(linkParent) /Pg 3 0 R /Alt (annotation description) /K << /Type /OBJR /Obj 11 0 R >> >>",
            "<< /Type /Annot /Subtype /Link /Rect [20 50 100 70] /Border [0 0 0] /StructParent 3 /NM (stable-link) /Contents (link) /A << /S /URI /URI (https://example.invalid/) >> >>",
            stream("/Figure << /MCID 0 >> BDC 0.1 0.2 0.8 rg 280 20 70 50 re f EMC", entries: "/Type /XObject /Subtype /Form /BBox [0 0 400 420] /Resources << >> \(formParent)"),
            "<< /Type /StructElem /S /Figure /P \(parent) /Pg 3 0 R /K << /Type /MCR /Pg 3 0 R /Stm 12 0 R /MCID 0 >> >>",
            "<< /Nums [\(pageTree) \(formTree) 3 10 0 R] >>",
            "<< /Type /StructElem /S /Div /P 8 0 R /Pg 3 0 R /K [9 0 R 10 0 R 13 0 R] \(semantic) >>",
            "<< /Type /Annot /Subtype /Link /Rect [120 50 180 70] /Border [0 0 0] \(extraParent) /A << /S /URI /URI (https://example.invalid/other) >> >>",
            "<< /Type /StructElem /S /Span /P 8 0 R /Pg 3 0 R /K [] /ActualText (unrelated empty sibling) >>"
        ]
        var bytes = Data("%PDF-1.7\n".utf8), offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count); bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return bytes
    }
}
