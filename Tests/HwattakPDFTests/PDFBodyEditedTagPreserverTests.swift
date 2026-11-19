// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import PDFKit
import XCTest
import zlib
@testable import HwattakPDF

/// Exercises the actual editor/serializer boundary as well as independently
/// rejecting malformed receipts and raw/native metadata disagreements.
@MainActor
final class PDFBodyEditedTagPreserverTests: XCTestCase {
    func testExactSingleMCIDRewriteRetainsEveryUntouchedProgramByte() throws {
        let receipt = try rewrite(program())
        var budget = PDFBodyEditedTagPreserver.Budget()
        let result = try PDFBodyEditedTagPreserver.validateRewrite(receipt, donorName: "Fresh", budget: &budget)
        XCTAssertEqual(result.changed, 0)
        XCTAssertEqual(result.mcids, [0, 1, 2])
        XCTAssertTrue(result.removedForms.isEmpty)
        XCTAssertTrue(String(decoding: receipt.rewritten, as: UTF8.self).contains("(Keep this line) Tj"))
        XCTAssertTrue(String(decoding: receipt.rewritten, as: UTF8.self).contains("/P << /MCID 1 >> BDC"))
    }

    func testTwoChangedMCIDsCannotShareOnePermission() throws {
        let receipt = try rewrite(program(), blocks: [0, 2])
        var budget = PDFBodyEditedTagPreserver.Budget()
        XCTAssertThrowsError(try PDFBodyEditedTagPreserver.validateRewrite(receipt, donorName: "Fresh", budget: &budget))
    }

    func testGlyphRewriteKeepsMarkedContentAndRejectsMultipleCodeChanges() throws {
        let original = Data("/P << /MCID 4 >> BDC BT /F1 18 Tf 50 180 Td <000100020003> Tj ET EMC".utf8)
        let stream = try PDFBodyTextContentStream.parse(original)
        let record = try XCTUnwrap(stream.records.first)
        for (command, isValid) in [("<000100040003> Tj", true), ("<000400040003> Tj", false),
                                   ("<000100040003> Tj 0 0 10 10 re f", false)] {
            var captured: PDFBodyLosslessRewriteReceipt?
            let patch = PDFBodyTextGlyphSubstitution.Patch(range: record.showRange,
                command: Data(command.utf8), characterIndex: 1)
            _ = try stream.replacingGlyph(patch, capture: { captured = $0 })
            let receipt = try XCTUnwrap(captured)
            var budget = PDFBodyEditedTagPreserver.Budget()
            if isValid {
                let delta = try PDFBodyEditedTagPreserver.validateRewrite(receipt, donorName: nil, budget: &budget)
                XCTAssertEqual(delta.changed, 4)
                XCTAssertEqual(delta.mcids, [4])
            } else {
                XCTAssertThrowsError(try PDFBodyEditedTagPreserver.validateRewrite(receipt, donorName: nil, budget: &budget))
            }
        }
    }

    func testTypedParentTreeRetainsEditedPageOwnership() async throws {
        let context = try edit(fixture(typedParentTree: true))
        let plan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: context.assembled) }.value
        XCTAssertEqual(plan.bodyTagPermissions.count, 1)
        XCTAssertNotNil(plan.pageEntries[0]?["StructParents"])
    }

    func testRemovedActualTextWrapperDoesNotSilentlyRetainItsOldMeaning() throws {
        let text = "/P << /MCID 0 >> BDC BT /F1 18 Tf (Old) Tj /Span << /ActualText ( ) >> BDC ( ) Tj EMC ET EMC"
        let receipt = try rewrite(text)
        var budget = PDFBodyEditedTagPreserver.Budget()
        XCTAssertThrowsError(try PDFBodyEditedTagPreserver.validateRewrite(receipt, donorName: "Fresh", budget: &budget))
    }

    func testDonorInvocationCannotAddPaintingOutsideItsScopedDo() throws {
        for invocation in ["q 1 0 0 1 0 0 cm /Wrong Do Q", "q 1 0 0 1 0 0 cm /Fresh Do Q 0 0 10 10 re f",
                           "q 0 0 0 0 0 0 cm /Fresh Do Q", "/Fresh Do"] {
            let receipt = try rewrite(program(), invocation: invocation)
            var budget = PDFBodyEditedTagPreserver.Budget()
            XCTAssertThrowsError(try PDFBodyEditedTagPreserver.validateRewrite(receipt, donorName: "Fresh", budget: &budget), invocation)
        }
    }

    func testDonorGrammarRejectsOwnMarksNestedFormsClippingAndInlineImages() throws {
        for program in ["/P << /MCID 0 >> BDC BT (bad) Tj ET EMC", "q /Nested Do Q", "BT 7 Tr (bad) Tj ET",
                        "0 0 10 10 re W n BT (bad) Tj ET", "BI /W 1 /H 1 ID x EI"] {
            var budget = PDFBodyEditedTagPreserver.Budget()
            XCTAssertThrowsError(try PDFBodyEditedTagPreserver.validateDonor(Data(program.utf8), budget: &budget), program)
        }
        var budget = PDFBodyEditedTagPreserver.Budget()
        XCTAssertNoThrow(try PDFBodyEditedTagPreserver.validateDonor(Data("q 1 0 0 1 0 0 cm BT /TT1 12 Tf 0 Tr (new) Tj ET Q".utf8), budget: &budget))
    }

    func testReeditFormPatchAllowsOnlyExistingEmptyGraphicsShells() throws {
        let source = "/P << /MCID 0 >> BDC BT /F1 18 Tf [] TJ ET q 1 0 0 1 0 0 cm Q q 1 0 0 1 0 0 cm /Previous Do Q EMC"
        let parsed = try PDFBodyTextContentStream.parse(Data(source.utf8))
        var receipt: PDFBodyLosslessRewriteReceipt?
        _ = try parsed.rewritingForms(recordIndices: [0], donorInvocation: "q 1 0 0 1 0 0 cm /Fresh Do Q") { receipt = $0 }
        var budget = PDFBodyEditedTagPreserver.Budget()
        let delta = try PDFBodyEditedTagPreserver.validateRewrite(XCTUnwrap(receipt), donorName: "Fresh", budget: &budget)
        XCTAssertEqual(delta.removedForms, ["Previous"])
        XCTAssertEqual(delta.changed, 0)
    }

    func testLargeProgramDoesNotCapturePendingProofOrRaiseEditorLimit() throws {
        let source = "%" + String(repeating: "x", count: 2 * 1_024 * 1_024) + "\n" + program()
        let stream = try PDFBodyTextContentStream.parse(Data(source.utf8))
        var captured = false
        _ = try stream.rewritingBlocks(blockIndices: [0], donorInvocation: nil) { _ in captured = true }
        XCTAssertFalse(captured, "The normal editor can finish while optional evidence stays bounded.")
    }

    func testMainColdPlanDoesNoTagProofButKeepsPendingActualEditorCommit() throws {
        let context = try edit(fixture())
        let commit = try XCTUnwrap(PDFBodyLosslessProvenance.commit(for: context.replacement))
        XCTAssertGreaterThan(commit.retainedTranscriptBytes, 0)
        XCTAssertLessThanOrEqual(commit.retainedTranscriptBytes, 5 * 1_024 * 1_024 + 256 * 16 * 1_024)
        let plan = try PDFCatalogStructurePreserver.plan(for: context.assembled)
        XCTAssertTrue(plan.bodyTagPermissions.isEmpty)
        XCTAssertNil(plan.pageEntries[0]?["StructParents"])
        XCTAssertNil(plan.paintingSources[0], "Tag-only evidence cannot revive old painting.")
    }

    func testWorkerKeepsForwardAndReverseMCIDsIncludingUntouchedCachedNewline() async throws {
        let context = try edit(fixture())
        let plan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: context.assembled) }.value
        XCTAssertEqual(plan.bodyTagPermissions.count, 1)
        XCTAssertNil(plan.paintingSources[0])
        let root = try node(plan.catalogEntries["StructTreeRoot"])
        let nums = try array(dictionary(root.entries["ParentTree"])["Nums"])
        let members = try array(nums[1])
        XCTAssertEqual(members.count, 3)
        let changed = try node(members[0]), cached = try node(members[1])
        XCTAssertTrue(changed === (try node(members[2])), "Shared owner cannot lose its unaffected reverse slot.")
        guard case .original(let original)? = cached.entries["ActualText"] else { return XCTFail("Untouched semantic bytes must be retained") }
        var text: CGPDFStringRef?
        XCTAssertTrue(CGPDFObjectGetValue(original, .string, &text))
        XCTAssertEqual(CGPDFStringGetLength(try XCTUnwrap(text)), 1)
        XCTAssertEqual(CGPDFStringGetBytePtr(try XCTUnwrap(text))?.pointee, 10)
    }

    func testSaveReopenAndOneMoreLosslessEditUsesNewCurrentBaseline() async throws {
        let first = try edit(fixture())
        let saved = try await save(first.assembled)
        let reopened = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: saved))
        XCTAssertTrue((reopened.string ?? "").contains("Changed text"))
        XCTAssertFalse((reopened.string ?? "").contains("Original text"))
        let second = try edit(document: reopened, before: "Changed text", after: "Edited twice")
        let plan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: second.assembled) }.value
        XCTAssertEqual(plan.bodyTagPermissions.count, 1)
        XCTAssertNotNil(plan.pageEntries[0]?["StructParents"])
        let result = try await save(second.assembled)
        let final = try XCTUnwrap(PDFDocument(data: result))
        XCTAssertTrue((final.string ?? "").contains("Edited twice"))
        XCTAssertTrue((final.string ?? "").contains("Keep this line"))
    }

    func testUnprovenEditedPageTagsPreventCommitAndKeepAppliedEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let workspace = PDFWorkspaceState()
        defer {
            workspace.closeDiscardingChanges()
            try? FileManager.default.removeItem(at: directory)
        }
        let source = directory.appendingPathComponent("source.pdf")
        let newCopy = directory.appendingPathComponent("new.pdf")
        let original = fixture(ownerExtra: "/ActualText (stale)")
        try original.write(to: source)
        XCTAssertTrue(workspace.open(url: source))
        workspace.setMode(.editing)
        let selection = try XCTUnwrap(workspace.document?.findString("Original text", withOptions: []).first)
        XCTAssertTrue(workspace.requestBodyTextEdit(selection: selection, preservesSelectionTool: false))
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        let range = try XCTUnwrap(draft.initialSelectedRange)
        let text = (draft.text as NSString).replacingCharacters(in: range, with: "Changed text")
        workspace.updatePendingInlineTextDraft(id: draft.id, text: text, style: draft.style, bounds: draft.bounds)
        workspace.commitPendingInlineTextDraftIfNeeded()
        XCTAssertNil(workspace.pendingInlineTextEdit, workspace.presentedError ?? "")
        XCTAssertTrue(workspace.isDirty)

        let overwritten = await workspace.saveAsynchronously()
        XCTAssertFalse(overwritten)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let copied = await workspace.saveAsynchronously(as: newCopy)
        XCTAssertFalse(copied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newCopy.path))
        XCTAssertEqual(workspace.presentedError,
                       PDFCatalogStructurePreserver.EditedPageTagSaveFailure(pageNumber: 1).localizedDescription)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.document?.page(at: 0)?.string?.contains("Changed text") == true)

        workspace.undo()
        let recovered = await workspace.saveAsynchronously(as: newCopy)
        XCTAssertTrue(recovered, workspace.presentedError ?? "")
        let reopened = try XCTUnwrap(PDFDocument(url: newCopy))
        let page = try XCTUnwrap(reopened.page(at: 0)?.pageRef?.dictionary)
        XCTAssertNotNil(PDFCatalogStructurePreserver.object(page, "StructParents"))
    }

    func testSecondUnsavedEditRetainsEstablishedDropPolicy() async throws {
        let first = try edit(fixture())
        let second = try edit(document: first.assembled, before: "Changed text", after: "Edited twice", prepare: false)
        let plan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: second.assembled) }.value
        XCTAssertTrue(plan.bodyTagPermissions.isEmpty)
        XCTAssertNil(plan.pageEntries[0]?["StructParents"])
        XCTAssertTrue((second.replacement.string ?? "").contains("Edited twice"))
    }

    func testGenericAndForgedBindingsNeverMintActualEditorCommit() async throws {
        for supplied in [fixture(), fixture(ownerExtra: "/ActualText (stale)")] {
            let document = try XCTUnwrap(PDFDocument(data: fixture()))
            PDFRawStreamProvenance.bindCreated(document, data: supplied)
            let context = try edit(document: document)
            XCTAssertNil(PDFBodyLosslessProvenance.commit(for: context.replacement))
            let plan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: context.assembled) }.value
            XCTAssertTrue(plan.bodyTagPermissions.isEmpty)
        }
    }

    func testForeignCurrentGraphCannotConsumePrivateCommit() async throws {
        let context = try edit(fixture())
        let commit = try XCTUnwrap(PDFBodyLosslessProvenance.commit(for: context.replacement))
        let foreign = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
        let page = try XCTUnwrap(foreign.page(at: 0))
        let permission = try await Task.detached {
            try PDFBodyEditedTagPreserver.prove(commit, source: context.owner, sourceIndex: 0,
                painting: context.originalRef, livePage: page)
        }.value
        XCTAssertNil(permission)
    }

    func testStaleOutputPlanFailsWhenPageIsReplacedAfterProof() async throws {
        let context = try edit(fixture())
        let plan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: context.assembled) }.value
        XCTAssertEqual(plan.bodyTagPermissions.count, 1)
        let foreign = try XCTUnwrap(PDFDocument(data: fixture()))
        context.assembled.removePage(at: 0)
        context.assembled.insert(try XCTUnwrap(foreign.page(at: 0)?.copy() as? PDFPage), at: 0)
        let staged = try XCTUnwrap(context.assembled.dataRepresentation())
        do {
            _ = try await Task.detached { try PDFBodyTextPageSnapshot.preservingCatalog(in: staged, from: context.assembled, plan: plan) }.value
            XCTFail("Permission must stay tied to the actual current native page.")
        } catch { }
    }

    func testOptionalAuxiliaryOwnerLookupRefusesMissingSlotLimitAndPreservesCancellation() throws {
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
        let owner = try XCTUnwrap(document.documentRef)
        var missing = PDFBodyEditedTagPreserver.Budget()
        XCTAssertNil(try PDFBodyEditedTagPreserver.reboundOwners(in: owner, pageIndex: 0, mcids: [99], budget: &missing))
        var limited = PDFBodyEditedTagPreserver.Budget(); limited.remaining = 0
        XCTAssertNil(try PDFBodyEditedTagPreserver.reboundOwners(in: owner, pageIndex: 0, mcids: [0], budget: &limited))
        var valid = PDFBodyEditedTagPreserver.Budget()
        XCTAssertEqual(try PDFBodyEditedTagPreserver.reboundOwners(in: owner, pageIndex: 0, mcids: [0, 1, 2], budget: &valid)?.count, 3)
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        var cancelled = PDFBodyEditedTagPreserver.Budget()
        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(cancellation) {
            try PDFBodyEditedTagPreserver.reboundOwners(in: owner, pageIndex: 0, mcids: [0], budget: &cancelled)
        }) { XCTAssertTrue($0 is CancellationError) }
    }

    func testRawMetadataAllowsEmptyAttributesAndExactByteClassRoleNames() async throws {
        let result = try await metadata(fixture(ownerExtra: "/A << >> /C /Pa19", rootExtra: "/ClassMap << /Pa19 [] >> /RoleMap << /Custom /P >>", role: "Custom"))
        XCTAssertTrue(result)
    }

    func testRawMetadataTreatsUndefinedClassAsEmptyAfterExactMapProof() async throws {
        for rootExtra in ["", "/ClassMap << >>", "/ClassMap << /Other [] >>",
                          "/ClassMap << /Other << /O /Layout >> >>"] {
            let allowed = try await metadata(fixture(ownerExtra: "/C /Missing", rootExtra: rootExtra))
            XCTAssertTrue(allowed, rootExtra)
        }
    }

    func testUndefinedClassPreservesItsNameAndUnrelatedDefinedAttributesAfterSave() async throws {
        let context = try edit(fixture(ownerExtra: "/C /Missing", rootExtra: "/ClassMap << /Other << /O /Layout >> >>"))
        let plan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: context.assembled) }.value
        XCTAssertEqual(plan.bodyTagPermissions.count, 1)
        let saved = try await save(context.assembled)
        let native = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: saved)?.documentRef)
        let path = try chain(native)
        var className: UnsafePointer<CChar>?
        XCTAssertTrue(CGPDFDictionaryGetName(path[0], "C", &className))
        XCTAssertEqual(String(cString: try XCTUnwrap(className)), "Missing")
        let classes = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(path[1], "ClassMap"))
        XCTAssertEqual(CGPDFDictionaryGetCount(classes), 1)
        XCTAssertNil(PDFCatalogStructurePreserver.object(classes, "Missing"), "The undefined class must not be synthesized.")
        var retained: CGPDFObjectRef?
        CGPDFDictionaryApplyBlock(classes, { _, value, _ in retained = value; return true }, nil)
        var attributes: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFObjectGetValue(try XCTUnwrap(retained), .dictionary, &attributes))
        let defined = try XCTUnwrap(attributes)
        XCTAssertEqual(CGPDFDictionaryGetCount(defined), 1)
        var owner: UnsafePointer<CChar>?
        XCTAssertTrue(CGPDFDictionaryGetName(defined, "O", &owner))
        XCTAssertEqual(String(cString: try XCTUnwrap(owner)), "Layout")
    }

    func testDocumentAncestorRetainsExactSmallBibliographicInfoAndXML() async throws {
        let context = try edit(fixture(documentMetadata: true))
        let plan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: context.assembled) }.value
        XCTAssertEqual(plan.bodyTagPermissions.count, 1)
        let saved = try await save(context.assembled)
        let native = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: saved)?.documentRef)
        let root = try XCTUnwrap(native.catalog.flatMap { PDFCatalogStructurePreserver.dictionary($0, "StructTreeRoot") })
        let kids = try XCTUnwrap(PDFCatalogStructurePreserver.array(root, "K")); var ancestor: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(kids, 0, &ancestor))
        let doc = try XCTUnwrap(ancestor)
        XCTAssertNotNil(PDFCatalogStructurePreserver.dictionary(doc, "Info"))
        XCTAssertNotNil(PDFCatalogStructurePreserver.object(doc, "Metadata"))
    }

    func testDocumentMetadataCannotHideAlternateTextOrFilteredStreams() async throws {
        for (info, metadata) in [("/ActualText (stale)", ""), ("", "/Filter /ASCIIHexDecode"), ("/Unknown (stale)", "")] {
            let context = try edit(fixture(documentMetadata: true, infoExtra: info, metadataExtra: metadata))
            let plan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: context.assembled) }.value
            XCTAssertTrue(plan.bodyTagPermissions.isEmpty)
            XCTAssertNil(plan.pageEntries[0]?["StructParents"])
        }
    }

    func testCompressedDocumentMetadataSurvivesSaveReopenAndAnotherLosslessEdit() async throws {
        let xml = Data(("<x:xmpmeta xmlns:x='adobe:ns:meta/'>" + String(repeating: "Bibliographic metadata. ", count: 300) + "</x:xmpmeta>").utf8)
        let bytes = fixture(FixtureOptions(documentMetadata: true, metadataExtra: "/Filter /FlateDecode", metadataBytes: try compressedMetadata(xml)))
        let originallyAllowed = try await documentMetadataAllowed(bytes)
        XCTAssertTrue(originallyAllowed)
        let first = try edit(bytes)
        let firstPlan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: first.assembled) }.value
        XCTAssertEqual(firstPlan.bodyTagPermissions.count, 1)
        let saved = try await save(first.assembled)
        let reopened = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: saved))
        XCTAssertEqual(try documentMetadataBytes(reopened), xml)
        let second = try edit(document: reopened, before: "Changed text", after: "Edited twice")
        let secondPlan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: second.assembled) }.value
        XCTAssertEqual(secondPlan.bodyTagPermissions.count, 1)
        XCTAssertNotNil(secondPlan.pageEntries[0]?["StructParents"])
        let secondSaved = try await save(second.assembled)
        let final = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: secondSaved))
        XCTAssertEqual(try documentMetadataBytes(final), xml)
        XCTAssertTrue((final.string ?? "").contains("Edited twice"))
        XCTAssertTrue((final.string ?? "").contains("Keep this line"))
    }

    func testDocumentFlateMetadataBoundsOutputAndRefusesCorruptionTruncationAndTrailingInput() async throws {
        let boundary = Data(repeating: 120, count: 65_536)
        let allowed = try await documentMetadataAllowed(fixture(FixtureOptions(documentMetadata: true,
            metadataExtra: "/Filter /FlateDecode", metadataBytes: try compressedMetadata(boundary))))
        XCTAssertTrue(allowed, "The existing 64KiB decoded limit is inclusive.")
        let valid = try compressedMetadata(Data("<metadata/>".utf8))
        var corrupted = valid; corrupted[corrupted.count - 1] ^= 1
        let cases: [(String, Data)] = [
            ("expansion", try compressedMetadata(Data(repeating: 120, count: 65_537))),
            ("corrupt checksum", corrupted), ("truncated", Data(valid.dropLast())),
            ("trailing input", valid + Data([0])), ("encoded limit", Data(repeating: 0, count: 65_537))
        ]
        for (name, encoded) in cases {
            let rejected = try await documentMetadataAllowed(fixture(FixtureOptions(documentMetadata: true,
                metadataExtra: "/Filter /FlateDecode", metadataBytes: encoded)))
            XCTAssertFalse(rejected, name)
        }
    }

    func testDocumentFlateMetadataRejectsFilterArraysParametersAndExternalSources() async throws {
        let encoded = try compressedMetadata(Data("<metadata/>".utf8))
        for extra in ["/Filter [/FlateDecode]", "/Filter null", "/Filter /FlateDecode#00",
                      "/Filter /FlateDecode /DecodeParms null", "/Filter /FlateDecode /DecodeParms << >>",
                      "/Filter /FlateDecode /F (external.xml)"] {
            let allowed = try await documentMetadataAllowed(fixture(FixtureOptions(documentMetadata: true,
                metadataExtra: extra, metadataBytes: encoded)))
            XCTAssertFalse(allowed, extra)
        }
    }

    func testRawMetadataRejectsCachedSemanticPresenceIncludingExplicitNull() async throws {
        for key in ["ActualText", "Alt", "E", "T"] {
            for value in ["null", "(stale)"] {
                let ownerAllowed = try await metadata(fixture(ownerExtra: "/\(key) \(value)"))
                let rootAllowed = try await metadata(fixture(rootExtra: "/\(key) \(value)"))
                XCTAssertFalse(ownerAllowed, key); XCTAssertFalse(rootAllowed, "root " + key)
            }
        }
    }

    func testRawMetadataRejectsNonemptyUnknownAndNullAttributes() async throws {
        for extra in ["/A null", "/A [<< /O /Layout >>]", "/A << /O /Layout >>", "/C null", "/C [/Pa19]", "/UnknownSemantic (stale)"] {
            let allowed = try await metadata(fixture(ownerExtra: extra))
            XCTAssertFalse(allowed, extra)
        }
        for value in ["null", "[<< /O /Layout >>]", "<< /O /Layout >>"] {
            let allowed = try await metadata(fixture(ownerExtra: "/C /Pa19", rootExtra: "/ClassMap << /Pa19 \(value) >>"))
            XCTAssertFalse(allowed, value)
        }
    }

    func testRawMetadataRejectsNULKeysAndNamesEvenAfterPaintingWasPaired() async throws {
        let control = try await metadataObservation(fixture(FixtureOptions(ownerExtra: "/C 10 0 R", rootExtra: "/ClassMap << /Pa19 [] >>", extraObjects: ["/Pa19"])), warmOwner: true)
        XCTAssertTrue(control.nativeOwnerReadable); XCTAssertTrue(control.allowed)
        var reachableRawCases = 0, nativeUnreadableCases = 0
        let cases = [
            FixtureOptions(ownerExtra: "/Actual#00Text null"),
            FixtureOptions(ownerExtra: "/C /Pa19#00Hidden", rootExtra: "/ClassMap << /Pa19 [] >>"),
            FixtureOptions(ownerExtra: "/C /Pa19", rootExtra: "/ClassMap << /Pa19#00Hidden [] >>"),
            FixtureOptions(rootExtra: "/RoleMap << /Custom /P#00Hidden >>", role: "Custom"),
            FixtureOptions(ownerExtra: "/C 10 0 R", rootExtra: "/ClassMap << /Pa19 [] >>", extraObjects: ["/Pa19#00Hidden"])
        ]
        for (index, options) in cases.enumerated() {
            let observation = try await metadataObservation(fixture(options), warmOwner: true)
            XCTAssertFalse(observation.allowed)
            if observation.nativeOwnerReadable { reachableRawCases += 1 }
            else { nativeUnreadableCases += 1 }
            print("TAG_NUL_OBSERVATION case=\(index) nativeOwnerReadable=\(observation.nativeOwnerReadable) rawMetadataBodyReachable=\(observation.nativeOwnerReadable) allowed=\(observation.allowed)")
        }
        XCTAssertGreaterThan(reachableRawCases, 0, "At least one NUL fixture must reach the actual raw metadata body; native parse refusal is a separate closed path.")
        print("TAG_NUL_COUNTS reachableRaw=\(reachableRawCases) nativeUnreadable=\(nativeUnreadableCases)")
    }

    func testMetadataSemanticPresenceIsRecheckedAfterItsWholeDictionaryWasPaired() async throws {
        let bytes = fixture(ownerExtra: "/ActualText null", resourceOwnerAlias: true)
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
        let owner = try XCTUnwrap(document.documentRef), page = try XCTUnwrap(owner.page(at: 1))
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: document)), path = try chain(owner)
        try await Task.detached {
            XCTAssertTrue(try raw.provesBodyTagPaintingRoots(page, in: owner), "The owner is reached through Resources.Properties.")
            XCTAssertFalse(try raw.provesBodyTagOwnerMetadata(in: owner, pageIndex: 0, mcid: 0, chain: path),
                "The existing global pair cache cannot suppress the metadata presence check.")
        }.value
    }

    func testResourceNumberCorrectionCannotAuthorizeAnEarlierRoundedConstruction() async throws {
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture(fontExtra: "/FontMatrix [0.96 0 0 0.96 0 0]")))
        let owner = try XCTUnwrap(document.documentRef), page = try XCTUnwrap(owner.page(at: 1))
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let allowed = try await Task.detached { try raw.provesBodyTagPaintingRoots(page, in: owner) }.value
        if raw.numberCorrectionFootprint.entries > 0 { XCTAssertFalse(allowed) }
        else { XCTAssertTrue(allowed, "SDKs parsing the stored value exactly need no correction.") }
    }

    func testMetadataWrongSlotWrongPathAndForeignFactoryRefuse() async throws {
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
        let owner = try XCTUnwrap(document.documentRef), raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let path = try chain(owner)
        let foreign = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
        let other = try XCTUnwrap(foreign.documentRef)
        try await Task.detached {
            XCTAssertFalse(try raw.provesBodyTagOwnerMetadata(in: owner, pageIndex: 0, mcid: 1, chain: path))
            XCTAssertFalse(try raw.provesBodyTagOwnerMetadata(in: owner, pageIndex: 0, mcid: 0, chain: [path[0], path[0], path[1]]))
            XCTAssertFalse(try raw.provesBodyTagOwnerMetadata(in: other, pageIndex: 0, mcid: 0, chain: path))
            XCTAssertFalse(try raw.provesBodyTagOwnerMetadata(in: owner, pageIndex: -1, mcid: 0, chain: path))
        }.value
    }

    func testCancellationPropagatesBeforeMetadataOrPermissionPublication() async throws {
        let context = try edit(fixture()), token = PDFSaveCancellation()
        let commit = try XCTUnwrap(PDFBodyLosslessProvenance.commit(for: context.replacement)); token.cancel()
        do {
            _ = try await Task.detached {
                try PDFSaveCancellation.withCurrent(token) {
                    try PDFBodyEditedTagPreserver.prove(commit, source: context.owner, sourceIndex: 0,
                        painting: context.originalRef, livePage: context.replacement)
                }
            }.value
            XCTFail("Cancellation is not an optional-proof refusal.")
        } catch is CancellationError { } catch { XCTFail("Wrong failure: \(error)") }
    }

    func testConstructionCopyDoesNotAttestFontNameRestorationOrForeignBytes() throws {
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture(fontExtra: "/EmberPDFBodyOriginalBaseFont /Courier")))
        let copied = try PDFBodyTextPageSnapshot.losslessData(for: XCTUnwrap(document.page(at: 0)), contentOverride: Data(program().utf8), donorPDF: nil, donorName: nil, droppingXObjectNames: [])
        XCTAssertNotNil(copied.witness)
        let restored = try PDFBodyTextPageSnapshot.restoringFontNamesPreservingBodyCopy(copied)
        XCTAssertNil(restored.witness, "A changed original font cannot acquire structural permission.")
        let foreign = PDFBodyResourceCopyOutput(data: fixture(), witness: copied.witness)
        XCTAssertNil(try PDFBodyTextPageSnapshot.restoringFontNamesPreservingBodyCopy(foreign).witness)
        let plain = try XCTUnwrap(PDFDocument(data: copied.data)?.page(at: 0))
        XCTAssertNil(PDFBodyLosslessProvenance.commit(for: plain), "A construction receipt alone cannot mint the private Editor commit.")
    }

    func testRawMetadataDoesNotPublishResourceOrNumberAuthority() async throws {
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
        let owner = try XCTUnwrap(document.documentRef), raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: document)), path = try chain(owner)
        let before = raw.numberCorrectionFootprint
        let allowed = try await Task.detached { try raw.provesBodyTagOwnerMetadata(in: owner, pageIndex: 0, mcid: 0, chain: path) }.value
        XCTAssertTrue(allowed)
        let after = raw.numberCorrectionFootprint
        XCTAssertEqual(before.entries, after.entries); XCTAssertEqual(before.accountedBytes, after.accountedBytes)
        let incomplete = try await Task.detached { try raw.provesBodyTagOwnerMetadata(in: owner, pageIndex: 0, mcid: 0, chain: [path[0]]) }.value
        XCTAssertFalse(incomplete)
    }

    func testTextCorrectionRetainsSeparateParagraphLayoutOwnersThroughTwoAtomicSaves() async throws {
        try await layoutRoundTrip(.separate)
    }

    func testTextCorrectionRetainsSharedParagraphLayoutOwnerThroughTwoAtomicSaves() async throws {
        try await layoutRoundTrip(.shared)
    }

    func testTextCorrectionRetainsInheritedParagraphLayoutClassThroughTwoAtomicSaves() async throws {
        try await layoutRoundTrip(.inherited)
    }

    func testParagraphStyleIntentDoesNotAuthorizeExplicitFormatOrBoundsChanges() async throws {
        let bytes = layoutFixture(.shared)
        for variant in 0..<2 {
            let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
            let context = try layoutEdit(document: document) { style, bounds in
                if variant == 0 { style.textColor = PDFTextColor(.blue) }
                else { bounds.size.width += 2 }
            }
            let commit = try XCTUnwrap(PDFBodyLosslessProvenance.commit(for: context.replacement))
            XCTAssertFalse(commit.retainsParagraphStyle(in: context.owner, page: context.originalRef,
                raw: try XCTUnwrap(PDFRawStreamProvenance.source(for: context.source))))
            let plan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: context.assembled) }.value
            XCTAssertTrue(plan.bodyTagPermissions.isEmpty)
        }
        // This policy cannot mint a receipt or a Permission. Test the same
        // bounded separator predicate the fileprivate initializer consumes.
        XCTAssertTrue(PDFBodyLosslessCommit.preservesParagraphSeparators(before: "word\nnext", after: "longer\nnext"))
        for (before, after) in [("ab\ncd", "abc\nd"), ("ab\ncd", "abcd"), ("abcd", "ab\ncd"),
                                ("ab\r\ncd", "ab\ncd"), ("ab\u{2028}cd", "ab cd"), ("ab\u{2029}cd", "ab cd")] {
            XCTAssertFalse(PDFBodyLosslessCommit.preservesParagraphSeparators(before: before, after: after))
        }
    }

    func testParagraphLayoutReceiptCannotAuthorizeAStaleOrForeignCurrentGraph() async throws {
        let context = try edit(layoutFixture(.shared))
        let commit = try XCTUnwrap(PDFBodyLosslessProvenance.commit(for: context.replacement))
        let positive = try await Task.detached {
            try PDFBodyEditedTagPreserver.prove(commit, source: context.owner, sourceIndex: 0,
                painting: context.originalRef, livePage: context.replacement)
        }.value
        XCTAssertNotNil(positive, "The stale control must first reach the qualified Layout branch.")
        let other = try edit(layoutFixture(.shared))
        let rejected = try await Task.detached {
            try PDFBodyEditedTagPreserver.prove(commit, source: context.owner, sourceIndex: 0,
                painting: context.originalRef, livePage: other.replacement)
        }.value
        XCTAssertNil(rejected)
        let originalPlan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: context.assembled) }.value
        XCTAssertEqual(originalPlan.bodyTagPermissions.count, 1)
        context.assembled.removePage(at: 0); context.assembled.insert(other.replacement, at: 0)
        let staged = try XCTUnwrap(context.assembled.dataRepresentation())
        do {
            _ = try await Task.detached {
                try PDFBodyTextPageSnapshot.preservingCatalog(in: staged, from: context.assembled, plan: originalPlan)
            }.value
            XCTFail("A Layout receipt cannot survive a different current page.")
        } catch { }
    }

    func testParagraphLayoutRejectsUnknownGeometryCachedAndRevisionAttributes() async throws {
        let unsupported = [
            "<< /O /Layout /LineHeight 20 /Unknown 1 >>",
            "<< /O /Layout /BBox [0 0 400 300] >>",
            "<< /O /Layout /Width 100 >>", "<< /O /Layout /Height 20 >>",
            "<< /O /Layout /ActualText (stale) >>", "<< /O /Layout /TextAlign /Unknown >>",
            "<< /O /Layout /LineHeight (20) >>", "<< /O /Layout /StartIndent null >>",
            "[<< /O /Layout /LineHeight 20 >> 1]", "<< /O /Other /LineHeight 20 >>"
        ]
        let direct = try edit(layoutFixture(.shared, directAttributes: true))
        let directPlan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: direct.assembled) }.value
        XCTAssertTrue(directPlan.bodyTagPermissions.isEmpty, "Direct A remains guarded by the existing inert-only ancestry proof.")
        for attributes in unsupported {
            let context = try edit(layoutFixture(.shared, attributes: attributes))
            let commit = try XCTUnwrap(PDFBodyLosslessProvenance.commit(for: context.replacement))
            XCTAssertTrue(commit.retainsParagraphStyle(in: context.owner, page: context.originalRef,
                raw: try XCTUnwrap(PDFRawStreamProvenance.source(for: context.source))),
                "The unknown control must not fail at the style-intent prerequisite.")
            let plan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: context.assembled) }.value
            XCTAssertTrue(plan.bodyTagPermissions.isEmpty, attributes)
        }
    }

    private enum LayoutOwnerKind: String { case separate, shared, inherited }
    private func layoutRoundTrip(_ kind: LayoutOwnerKind) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-Layout-Style-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: layoutFixture(kind)))
        let sourceString = try XCTUnwrap(document.page(at: 0)?.string)
        var className = "Paragraph"
        try assertLayoutOwners(document, kind: kind, className: className)
        for (cycle, before, after) in [(0, "Original text", "Changed text"), (1, "Changed text", "Edited twice")] {
            let sourceContent = try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(document.page(at: 0)))
            let context = try layoutEdit(document: document, before: before, after: after)
            let commit = try XCTUnwrap(PDFBodyLosslessProvenance.commit(for: context.replacement))
            XCTAssertTrue(commit.retainsParagraphStyle(in: context.owner, page: context.originalRef,
                raw: try XCTUnwrap(PDFRawStreamProvenance.source(for: context.source))))
            let plan = try await Task.detached { try PDFCatalogStructurePreserver.plan(for: context.assembled) }.value
            XCTAssertEqual(plan.bodyTagPermissions.count, 1)
            XCTAssertNotNil(plan.pageEntries[0]?["StructParents"])
            let snapshot = try PDFRecoverySnapshot(capturing: context.assembled)
            let destination = directory.appendingPathComponent("cycle-\(cycle).pdf")
            let saved = try await Task.detached { () throws -> Data in
                try AtomicPDFWriter.write(snapshot.takeDocument(), to: destination)
                return try Data(contentsOf: destination)
            }.value
            document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: saved))
            XCTAssertEqual(document.pageCount, 1)
            XCTAssertEqual(document.page(at: 0)?.string, sourceString.replacingOccurrences(of: "Original text", with: after))
            XCTAssertEqual(try PDFBodyTextPageSnapshot.contentData(for: XCTUnwrap(context.source.page(at: 0))), sourceContent)
            // The existing single-source tag builder namespaces defined
            // classes on each save; owner C and ClassMap must stay joined.
            className = "EmberTag0_" + className
            try assertLayoutOwners(document, kind: kind, className: className)
            let page = try XCTUnwrap(document.page(at: 0))
            let content = try PDFBodyTextPageSnapshot.contentData(for: page)
            XCTAssertTrue(String(decoding: content, as: UTF8.self).contains("(Keep this line) Tj"))
            let selection = try XCTUnwrap(document.findString(after, withOptions: []).first)
            XCTAssertNotNil(try PDFBodyTextEditor.target(on: page, selection: selection), "Cold reedit remains available.")
        }
    }

    private func layoutEdit(document: PDFDocument, before: String = "Original text", after: String = "Changed text",
                            mutate: (inout InlineTextStyle, inout CGRect) -> Void = { _, _ in }) throws -> Context {
        try PDFCatalogStructurePreserver.prepare(document)
        let page = try XCTUnwrap(document.page(at: 0)), reference = try XCTUnwrap(page.pageRef)
        let owner = try XCTUnwrap(reference.document)
        let selection = try XCTUnwrap(document.findString(before, withOptions: []).first)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
        var style = target.style, bounds = target.bounds; mutate(&style, &bounds)
        let replacement = try PDFBodyTextEditor.replacementPage(for: page, target: target, text: after, style: style, bounds: bounds)
        PDFCatalogStructurePreserver.inheritMetadata(from: page, to: replacement)
        let assembled = PDFDocument(); assembled.insert(replacement, at: 0)
        return Context(source: document, assembled: assembled, replacement: replacement, owner: owner, originalRef: reference)
    }

    private func assertLayoutOwners(_ document: PDFDocument, kind: LayoutOwnerKind, className: String) throws {
        let owner = try XCTUnwrap(document.documentRef), page = try XCTUnwrap(owner.page(at: 1)?.dictionary)
        let root = try XCTUnwrap(owner.catalog.flatMap { PDFCatalogStructurePreserver.dictionary($0, "StructTreeRoot") })
        var key: CGPDFInteger = -1; XCTAssertTrue(CGPDFDictionaryGetInteger(page, "StructParents", &key))
        let parentTree = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(root, "ParentTree"))
        let nums = try XCTUnwrap(PDFCatalogStructurePreserver.array(parentTree, "Nums"))
        var parents: CGPDFArrayRef?
        for index in stride(from: 0, to: CGPDFArrayGetCount(nums), by: 2) {
            var candidate: CGPDFInteger = -1
            if CGPDFArrayGetInteger(nums, index, &candidate), candidate == key {
                XCTAssertTrue(CGPDFArrayGetArray(nums, index + 1, &parents)); break
            }
        }
        let slots = try XCTUnwrap(parents); XCTAssertEqual(CGPDFArrayGetCount(slots), 3)
        var first: CGPDFDictionaryRef?, cached: CGPDFDictionaryRef?, last: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(slots, 0, &first)); XCTAssertTrue(CGPDFArrayGetDictionary(slots, 1, &cached))
        XCTAssertTrue(CGPDFArrayGetDictionary(slots, 2, &last))
        let a = try XCTUnwrap(first), c = try XCTUnwrap(last)
        XCTAssertEqual(a == c, kind == .shared)
        func integerKids(_ dictionary: CGPDFDictionaryRef) throws -> [Int] {
            let value = try XCTUnwrap(PDFCatalogStructurePreserver.object(dictionary, "K"))
            if CGPDFObjectGetType(value) == .integer {
                var integer: CGPDFInteger = -1; XCTAssertTrue(CGPDFObjectGetValue(value, .integer, &integer))
                return [integer]
            }
            let array = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "K"))
            return try (0..<CGPDFArrayGetCount(array)).map { index in
                var value: CGPDFObjectRef?
                guard CGPDFArrayGetObject(array, index, &value), let value else { throw TestError.shape }
                var integer: CGPDFInteger = -1
                if CGPDFObjectGetType(value) == .integer {
                    guard CGPDFObjectGetValue(value, .integer, &integer) else { throw TestError.shape }
                    return integer
                }
                // The existing tag writer converts page MCIDs into explicit
                // MCR children. Verify that complete standard representation,
                // including its exact current page; do not accept arbitrary
                // dictionaries or an MCID borrowed from another page/Form.
                var item: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(value, .dictionary, &item), let item,
                      CGPDFDictionaryGetCount(item) == 3 else { throw TestError.shape }
                var type: UnsafePointer<CChar>?, boundPage: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetName(item, "Type", &type), let type,
                      String(cString: type) == "MCR",
                      CGPDFDictionaryGetDictionary(item, "Pg", &boundPage), boundPage == page,
                      CGPDFDictionaryGetInteger(item, "MCID", &integer), integer >= 0 else { throw TestError.shape }
                return integer
            }
        }
        XCTAssertEqual(try integerKids(a), kind == .shared ? [0, 2] : [0])
        if kind != .shared { XCTAssertEqual(try integerKids(c), [2]) }
        XCTAssertEqual(try integerKids(XCTUnwrap(cached)), [1])
        var text: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(cached), "ActualText", &text))
        XCTAssertEqual(CGPDFStringGetLength(try XCTUnwrap(text)), 1)
        XCTAssertEqual(CGPDFStringGetBytePtr(try XCTUnwrap(text))?.pointee, 10)
        var classOwner = a
        if kind == .inherited {
            XCTAssertNil(PDFCatalogStructurePreserver.object(a, "C"))
            classOwner = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(a, "P"))
            let kids = try XCTUnwrap(PDFCatalogStructurePreserver.array(classOwner, "K"))
            var child: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(kids, 0, &child)); XCTAssertEqual(child, a)
        }
        let classes = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(root, "ClassMap"))
        var name: UnsafePointer<CChar>?
        XCTAssertTrue(CGPDFDictionaryGetName(classOwner, "C", &name)); XCTAssertEqual(String(cString: try XCTUnwrap(name)), className)
        let attributes = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(classes, className))
        if kind != .shared {
            var name: UnsafePointer<CChar>?
            XCTAssertTrue(CGPDFDictionaryGetName(c, "C", &name)); XCTAssertEqual(String(cString: try XCTUnwrap(name)), className)
        }
        let rootKids = try XCTUnwrap(PDFCatalogStructurePreserver.array(root, "K"))
        let directChildren = (0..<CGPDFArrayGetCount(rootKids)).compactMap { index -> CGPDFDictionaryRef? in
            var child: CGPDFDictionaryRef?; return CGPDFArrayGetDictionary(rootKids, index, &child) ? child : nil
        }
        XCTAssertTrue(directChildren.contains(classOwner))
        XCTAssertTrue(directChildren.contains(try XCTUnwrap(cached)))
        if kind != .shared { XCTAssertTrue(directChildren.contains(c)) }
        XCTAssertEqual(CGPDFDictionaryGetCount(attributes), 7)
        for (key, expected) in [("LineHeight", 20), ("TextIndent", 0), ("StartIndent", 0), ("SpaceBefore", 3), ("SpaceAfter", 4)] {
            let value = try XCTUnwrap(PDFCatalogStructurePreserver.object(attributes, key))
            XCTAssertEqual(CGPDFObjectGetType(value), .integer)
            var number: CGPDFInteger = -1; XCTAssertTrue(CGPDFObjectGetValue(value, .integer, &number)); XCTAssertEqual(number, expected)
        }
        for (key, expected) in [("O", "Layout"), ("TextAlign", "Start")] {
            var value: UnsafePointer<CChar>?
            XCTAssertTrue(CGPDFDictionaryGetName(attributes, key, &value)); XCTAssertEqual(String(cString: try XCTUnwrap(value)), expected)
        }
    }

    private func layoutFixture(_ kind: LayoutOwnerKind, attributes: String = "<< /O /Layout /LineHeight 20 /TextAlign /Start /TextIndent 0 /StartIndent 0 /SpaceBefore 3 /SpaceAfter 4 >>", directAttributes: Bool = false) -> Data {
        let source = program(), shared = kind == .shared, inherited = kind == .inherited
        let rootKids = inherited ? "11 0 R 8 0 R 10 0 R" : (shared ? "7 0 R 8 0 R" : "7 0 R 8 0 R 10 0 R")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo << /Marked true >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R /StructParents 0 >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(source.utf8.count) >>\nstream\n\(source)\nendstream",
            "<< /Type /StructTreeRoot /K [\(rootKids)] /ParentTree 9 0 R /ParentTreeNextKey 1 /ClassMap << /Paragraph \(attributes) >> >>",
            "<< /Type /StructElem /S /P /P \(inherited ? 11 : 6) 0 R /Pg 3 0 R /K \(shared ? "[0 2]" : "0") \(inherited ? "" : (directAttributes ? "/A " + attributes : "/C /Paragraph")) >>",
            "<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 1 /ActualText (\\n) >>",
            "<< /Nums [0 [7 0 R 8 0 R \(shared ? 7 : 10) 0 R]] >>",
            "<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 2 /C /Paragraph >>"
        ]
        if inherited { objects.append("<< /Type /StructElem /S /Sect /P 6 0 R /K [7 0 R] /C /Paragraph >>") }
        var data = Data("%PDF-1.7\n".utf8), offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count; data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    private struct Context: @unchecked Sendable {
        let source: PDFDocument; let assembled: PDFDocument; let replacement: PDFPage
        let owner: CGPDFDocument; let originalRef: CGPDFPage
    }
    private func edit(_ data: Data) throws -> Context { try edit(document: XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: data))) }
    private func edit(document: PDFDocument, before: String = "Original text", after: String = "Changed text", prepare: Bool = true) throws -> Context {
        if prepare { try PDFCatalogStructurePreserver.prepare(document) }
        let original = try XCTUnwrap(document.page(at: 0)), reference = try XCTUnwrap(original.pageRef)
        let owner = try XCTUnwrap(reference.document)
        let selection = try XCTUnwrap(document.findString(before, withOptions: []).first)
        let target = try XCTUnwrap(PDFBodyTextEditor.target(on: original, selection: selection))
        let replacement = try PDFBodyTextEditor.replacementPage(for: original, target: target, text: after, style: target.style, bounds: target.bounds)
        PDFCatalogStructurePreserver.inheritMetadata(from: original, to: replacement)
        let assembled = PDFDocument(); assembled.insert(replacement, at: 0)
        return Context(source: document, assembled: assembled, replacement: replacement, owner: owner, originalRef: reference)
    }
    private func save(_ document: PDFDocument) async throws -> Data {
        let staged = try XCTUnwrap(document.dataRepresentation())
        return try await Task.detached {
            let plan = try PDFCatalogStructurePreserver.plan(for: document)
            return try PDFBodyTextPageSnapshot.preservingCatalog(in: staged, from: document, plan: plan)
        }.value
    }
    private func rewrite(_ source: String, blocks: [Int] = [0], invocation: String = "q 1 0 0 1 0 0 cm /Fresh Do Q") throws -> PDFBodyLosslessRewriteReceipt {
        let parsed = try PDFBodyTextContentStream.parse(Data(source.utf8))
        var receipt: PDFBodyLosslessRewriteReceipt?
        _ = try parsed.rewritingBlocks(blockIndices: blocks, donorInvocation: invocation) { receipt = $0 }
        return try XCTUnwrap(receipt)
    }
    private struct MetadataObservation: Sendable { let allowed: Bool; let nativeOwnerReadable: Bool }
    private func metadata(_ bytes: Data, warmOwner: Bool = false) async throws -> Bool {
        let result = try await metadataObservation(bytes, warmOwner: warmOwner)
        guard result.nativeOwnerReadable else { throw TestError.shape }
        return result.allowed
    }
    private func metadataObservation(_ bytes: Data, warmOwner: Bool = false) async throws -> MetadataObservation {
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
        let owner = try XCTUnwrap(document.documentRef), raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let page = try XCTUnwrap(owner.page(at: 1))
        let candidate: [CGPDFDictionaryRef]?
        if let catalog = owner.catalog, let root = PDFCatalogStructurePreserver.dictionary(catalog, "StructTreeRoot"),
           let kids = PDFCatalogStructurePreserver.array(root, "K") {
            var first: CGPDFDictionaryRef?
            candidate = CGPDFArrayGetDictionary(kids, 0, &first) ? first.map { [$0, root] } : nil
        } else { candidate = nil }
        return try await Task.detached {
            if warmOwner { _ = try raw.provesBodyTagPaintingRoots(page, in: owner) }
            let allowed = try raw.provesBodyTagOwnerMetadata(in: owner, pageIndex: 0, mcid: 0, chain: candidate ?? [])
            return MetadataObservation(allowed: allowed, nativeOwnerReadable: candidate != nil)
        }.value
    }

    private func chain(_ owner: CGPDFDocument) throws -> [CGPDFDictionaryRef] {
        let catalog = try XCTUnwrap(owner.catalog), root = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(catalog, "StructTreeRoot"))
        let kids = try XCTUnwrap(PDFCatalogStructurePreserver.array(root, "K")); var child: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(kids, 0, &child))
        return [try XCTUnwrap(child), root]
    }
    private func documentMetadataAllowed(_ bytes: Data) async throws -> Bool {
        let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
        let owner = try XCTUnwrap(document.documentRef), raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        let root = try XCTUnwrap(owner.catalog.flatMap { PDFCatalogStructurePreserver.dictionary($0, "StructTreeRoot") })
        let roots = try XCTUnwrap(PDFCatalogStructurePreserver.array(root, "K")); var ancestor: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(roots, 0, &ancestor))
        let doc = try XCTUnwrap(ancestor), kids = try XCTUnwrap(PDFCatalogStructurePreserver.array(doc, "K"))
        var child: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(kids, 0, &child))
        let path = [try XCTUnwrap(child), doc, root]
        return try await Task.detached {
            try raw.provesBodyTagOwnerMetadata(in: owner, pageIndex: 0, mcid: 0, chain: path)
        }.value
    }
    private func documentMetadataBytes(_ document: PDFDocument) throws -> Data {
        let owner = try XCTUnwrap(document.documentRef)
        let root = try XCTUnwrap(owner.catalog.flatMap { PDFCatalogStructurePreserver.dictionary($0, "StructTreeRoot") })
        let kids = try XCTUnwrap(PDFCatalogStructurePreserver.array(root, "K")); var ancestor: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(kids, 0, &ancestor))
        let object = try XCTUnwrap(PDFCatalogStructurePreserver.object(XCTUnwrap(ancestor), "Metadata"))
        var stream: CGPDFStreamRef?; XCTAssertTrue(CGPDFObjectGetValue(object, .stream, &stream))
        let dictionary = try XCTUnwrap(CGPDFStreamGetDictionary(XCTUnwrap(stream)))
        var filter: UnsafePointer<CChar>?; XCTAssertTrue(CGPDFDictionaryGetName(dictionary, "Filter", &filter))
        XCTAssertEqual(String(cString: try XCTUnwrap(filter)), "FlateDecode")
        var format = CGPDFDataFormat.raw
        let decoded = try XCTUnwrap(CGPDFStreamCopyData(XCTUnwrap(stream), &format))
        XCTAssertEqual(format, .raw)
        return decoded as Data
    }
    private func compressedMetadata(_ bytes: Data) throws -> Data {
        var length = compressBound(uLong(bytes.count)), output = Data(count: Int(compressBound(uLong(bytes.count))))
        let status = output.withUnsafeMutableBytes { target in bytes.withUnsafeBytes { source in
            compress2(target.bindMemory(to: Bytef.self).baseAddress, &length,
                source.bindMemory(to: Bytef.self).baseAddress, uLong(bytes.count), Z_BEST_COMPRESSION)
        } }
        XCTAssertEqual(status, Z_OK)
        guard status == Z_OK else { throw TestError.shape }
        output.removeSubrange(Int(length)..<output.count)
        return output
    }
    private struct FixtureOptions {
        var ownerExtra = ""; var rootExtra = ""; var role = "P"; var fontExtra = ""; var resourceOwnerAlias = false; var documentMetadata = false; var infoExtra = ""; var metadataExtra = ""; var metadataBytes: Data? = nil; var extraObjects: [String] = []; var typedParentTree = false
    }
    private func fixture(ownerExtra: String = "", rootExtra: String = "", role: String = "P", fontExtra: String = "", resourceOwnerAlias: Bool = false, documentMetadata: Bool = false, infoExtra: String = "", metadataExtra: String = "", typedParentTree: Bool = false) -> Data {
        fixture(FixtureOptions(ownerExtra: ownerExtra, rootExtra: rootExtra, role: role, fontExtra: fontExtra, resourceOwnerAlias: resourceOwnerAlias, documentMetadata: documentMetadata, infoExtra: infoExtra, metadataExtra: metadataExtra, typedParentTree: typedParentTree))
    }
    private func fixture(_ options: FixtureOptions) -> Data {
        let program = program()
        let alias = options.resourceOwnerAlias ? "/Properties << /Owner 7 0 R >>" : ""
        let firstRootChild = options.documentMetadata ? 10 : 7
        let firstParent = options.documentMetadata ? 10 : 6
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo << /Marked true >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 4 0 R >> \(alias) >> /Contents 5 0 R /StructParents 0 >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica \(options.fontExtra) >>",
            "<< /Length \(program.utf8.count) >>\nstream\n\(program)\nendstream",
            "<< /Type /StructTreeRoot /K [\(firstRootChild) 0 R 8 0 R] /ParentTree 9 0 R /ParentTreeNextKey 1 \(options.rootExtra) >>",
            "<< /Type /StructElem /S /\(options.role) /P \(firstParent) 0 R /Pg 3 0 R /K [0 2] \(options.ownerExtra) >>",
            "<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 1 /ActualText (\\n) >>",
            "<< \(options.typedParentTree ? "/Type /ParentTree " : "")/Nums [0 [7 0 R 8 0 R 7 0 R]] >>"
        ].map { Data($0.utf8) }
        if options.documentMetadata {
            let xml = "<?xpacket begin='x'?><x:xmpmeta xmlns:x='adobe:ns:meta/'></x:xmpmeta>"
            objects.append(Data("<< /Type /StructElem /S /Document /P 6 0 R /K [7 0 R] /Info 11 0 R /Metadata 12 0 R >>".utf8))
            objects.append(Data("<< /Author (Author) /Title () /Subject (Bibliographic abstract) \(options.infoExtra) >>".utf8))
            let defaultXML = options.metadataExtra.contains("ASCIIHexDecode") ? xml.utf8.map { String(format: "%02X", $0) }.joined() + ">" : xml
            let storedXML = options.metadataBytes ?? Data(defaultXML.utf8)
            var metadata = Data("<< /Type /Metadata /Subtype /XML /Length \(storedXML.count) \(options.metadataExtra) >>\nstream\n".utf8)
            metadata.append(storedXML); metadata.append(Data("\nendstream".utf8)); objects.append(metadata)
        }
        objects.append(contentsOf: options.extraObjects.map { Data($0.utf8) })
        var data = Data("%PDF-1.7\n".utf8), offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(i + 1) 0 obj\n".utf8)); data.append(body); data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
    private func program() -> String {
        "/P << /MCID 0 >> BDC BT /F1 18 Tf 50 180 Td (Original text) Tj ET EMC\n"
            + "/P << /MCID 1 >> BDC BT /F1 18 Tf 50 155 Td ( ) Tj ET EMC\n"
            + "/P << /MCID 2 >> BDC BT /F1 18 Tf 50 130 Td (Keep this line) Tj ET EMC"
    }
    private func node(_ value: PDFCatalogGraphValue?) throws -> PDFCatalogGraphNode {
        guard case .node(let result)? = value else { throw TestError.shape }; return result
    }
    private func array(_ value: PDFCatalogGraphValue?) throws -> [PDFCatalogGraphValue] {
        switch value {
        case .array(let result)?: return result
        case .sparseArray(let count, let members)?:
            guard count <= 100 else { throw TestError.shape }
            return (0..<count).map { members[$0] ?? .null }
        default: throw TestError.shape
        }
    }
    private func dictionary(_ value: PDFCatalogGraphValue?) throws -> [String: PDFCatalogGraphValue] {
        guard case .dictionary(let result)? = value else { throw TestError.shape }; return result
    }
    private enum TestError: Error { case shape }
}
