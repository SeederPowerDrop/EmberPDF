// SPDX-License-Identifier: MPL-2.0

import CEmberPDFRawStreams
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFAnnotationRelationshipPreserverTests: XCTestCase {
    func testDirectAtomicSaveFindsAnUnregisteredNewTextPopupPair() throws {
        let document = try opened(), pair = try addNote(to: document)
        let before = document.page(at: 0)!.annotations.map(ObjectIdentifier.init)
        XCTAssertFalse(PDFCatalogStructurePreserver.needsMaterialization(document))
        let saved = try directSave(document)
        try assertPair(saved, contents: "Current note")
        XCTAssertEqual(document.page(at: 0)!.annotations.map(ObjectIdentifier.init), before)
        XCTAssertTrue(pair.note.popup === pair.popup)
        XCTAssertTrue(pair.popup.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")) as? PDFAnnotation === pair.note)
    }

    func testRecoverySerializedDataRepairsThePairWithoutMutatingLiveAnnotations() async throws {
        let document = try opened(), pair = try addNote(to: document)
        let before = document.page(at: 0)!.annotations.map(ObjectIdentifier.init)
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let saved = try await Task.detached { try snapshot.serializedData() }.value
        try assertPair(saved, contents: "Current note")
        XCTAssertEqual(document.page(at: 0)!.annotations.map(ObjectIdentifier.init), before)
        XCTAssertTrue(pair.note.popup === pair.popup)
    }

    func testSnapshotWorkerAtomicSaveRepairsCurrentRelations() async throws {
        let document = try opened(); _ = try addNote(to: document)
        let saved = try await workerSave(document)
        try assertPair(saved, contents: "Current note")
    }

    func testAlreadyValidLoadedNativePairSurvivesDirectAndSnapshotSave() async throws {
        let bytes = fixture(nativePair: true), document = try opened(bytes)
        try assertPair(bytes, contents: "Loaded note")
        let page = try XCTUnwrap(document.page(at: 0)), note = try XCTUnwrap(page.annotations.first { $0.type == "Text" })
        let popup = try XCTUnwrap(page.annotations.first { $0.type == "Popup" })
        XCTAssertTrue(note.popup === popup, "The valid loaded native fixture must expose exact current membership.")
        XCTAssertTrue(popup.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")) as? PDFAnnotation === note)
        try assertPair(directSave(document), contents: "Loaded note")
        let background = try await workerSave(document)
        try assertPair(background, contents: "Loaded note")
        XCTAssertTrue(note.popup === popup)
    }

    func testValidLoadedOptionalParentAbsentAndNullKeepTheirNativeRepresentation() async throws {
        for null in [false, true] {
            let bytes = fixture(nativePair: true, absentParent: !null, nullParent: null), document = try opened(bytes)
            try assertPair(bytes, contents: "Loaded note", hasParent: false, nullParent: null)
            let page = try XCTUnwrap(document.page(at: 0)), note = try XCTUnwrap(page.annotations.first { $0.type == "Text" })
            let popup = try XCTUnwrap(page.annotations.first { $0.type == "Popup" })
            XCTAssertTrue(note.popup === popup)
            XCTAssertTrue(popup.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")) as? PDFAnnotation === note,
                          "The SDK synthesizes this getter; only the native dictionary proves optional Parent presence.")
            XCTAssertThrowsError(try directSave(document), "A cold main save must not create a normalization reader.")
            let background = try await workerSave(document)
            try assertPair(background, contents: "Loaded note", hasParent: false, nullParent: null)
            try assertPair(directSave(document), contents: "Loaded note", hasParent: false, nullParent: null)
            XCTAssertTrue(popup.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")) as? PDFAnnotation === note)
        }
    }

    func testExactNativeFingerprintCanPreserveOptionalParentOnMainWithoutMeasurement() throws {
        let document = try opened(fixture(nativePair: true, absentParent: true, normalized: true))
        try assertPair(directSave(document), contents: "Loaded note", hasParent: false)
        XCTAssertEqual(PDFCatalogStructurePreserver.relationshipCacheFootprint(for: document)?.measurements, 0)
    }

    func testNoTextRecoveryAndSaveDoNotAllocateANormalizationCache() async throws {
        let document = try opened()
        _ = try await workerSave(document)
        XCTAssertNil(PDFCatalogStructurePreserver.relationshipCacheFootprint(for: document))
    }

    func testWorkerPreservesRawPopupAbsenceAndNullThroughExactCopy() async throws {
        for null in [false, true] { for hasPage in [false, true] {
            let bytes = fixture(nativePair: true, absentPopup: !null, nullPopup: null, noteExtra: hasPage ? "/P 3 0 R" : "")
            let document = try opened(bytes), page = try XCTUnwrap(document.page(at: 0))
            let note = try XCTUnwrap(page.annotations.first), target = try XCTUnwrap(note.popup)
            let ids = page.annotations.map(ObjectIdentifier.init)
            XCTAssertNotNil(PDFAnnotationRelationshipLifecycle.observation(for: note, on: page))
            let saved = try await workerSave(document)
            try assertNoPopup(saved, null: null)
            XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), ids)
            XCTAssertTrue(note.popup === target)
            XCTAssertEqual(note.contents, "Loaded note")
            try assertNoPopup(bytes, null: null)
        } }
    }

    func testLifecycleInstallationIsLazyAndPreservesAnExistingDelegate() throws {
        let bytes = fixture(), document = try XCTUnwrap(PDFDocument(data: bytes))
        PDFRawStreamProvenance.bindCreated(document, data: bytes)
        let installed = try XCTUnwrap(PDFAnnotationRelationshipLifecycle.footprint(for: document))
        XCTAssertEqual(installed.pages, 0); XCTAssertEqual(installed.annotationReads, 0)
        XCTAssertEqual(installed.captured, 0); XCTAssertEqual(installed.bytes, 0)
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(PDFAnnotationRelationshipLifecycle.footprint(for: document)?.annotationReads, 0)
        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertEqual(PDFAnnotationRelationshipLifecycle.footprint(for: document)?.captured, 0)
        XCTAssertEqual(PDFAnnotationRelationshipLifecycle.footprint(for: document)?.bytes, 0)
        XCTAssertNil(PDFCatalogStructurePreserver.relationshipCacheFootprint(for: document))
        let existing = ExistingDelegate(), delegated = try XCTUnwrap(PDFDocument(data: bytes))
        delegated.delegate = existing
        PDFRawStreamProvenance.bindCreated(delegated, data: bytes)
        XCTAssertTrue(delegated.delegate === existing)
        XCTAssertNil(PDFAnnotationRelationshipLifecycle.footprint(for: delegated))
    }

    func testPreloadedBasePageAndMissingFactoryCannotBorrowInitialSyntheticLineage() async throws {
        let bytes = fixture(nativePair: true, absentPopup: true)
        let document = try XCTUnwrap(PDFDocument(data: bytes)), page = try XCTUnwrap(document.page(at: 0))
        PDFRawStreamProvenance.bindCreated(document, data: bytes)
        let note = try XCTUnwrap(page.annotations.first)
        XCTAssertNil(PDFAnnotationRelationshipLifecycle.observation(for: note, on: page))
        do { _ = try await workerSave(document); XCTFail("A preloaded base page has no before-exposure observation.") } catch {}
        XCTAssertEqual(note.contents, "Loaded note")
    }

    func testHitDrawAndAddCaptureBeforeReturningPublicAnnotations() async throws {
        for exposure in ["hit", "draw", "add"] {
            let document = try opened(fixture(nativePair: true, absentPopup: true))
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertEqual(PDFAnnotationRelationshipLifecycle.footprint(for: document)?.annotationReads, 0)
            switch exposure {
            case "hit": _ = page.annotation(at: CGPoint(x: 15, y: 15))
            case "draw":
                let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                    bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                page.draw(with: .mediaBox, to: context)
            default:
                page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 80, y: 80, width: 20, height: 20), forType: .square, withProperties: nil))
            }
            XCTAssertEqual(PDFAnnotationRelationshipLifecycle.footprint(for: document)?.captured, 1, exposure)
            let note = try XCTUnwrap(page.annotations.first { $0.type == "Text" })
            XCTAssertNotNil(PDFAnnotationRelationshipLifecycle.observation(for: note, on: page))
            let saved = try await workerSave(document)
            try assertNoPopup(saved, null: false, count: exposure == "add" ? 2 : 1)
        }
    }

    func testInitialSyntheticMTargetAndOtherObservableEditsCannotBeDiscarded() async throws {
        for edit in ["M", "target", "color", "bounds", "contents", "Open", "extra"] {
            let document = try opened(fixture(nativePair: true, absentPopup: true))
            let page = try XCTUnwrap(document.page(at: 0)), note = try XCTUnwrap(page.annotations.first), popup = try XCTUnwrap(note.popup)
            let initial = try XCTUnwrap(PDFAnnotationRelationshipLifecycle.observation(for: note, on: page))
            XCTAssertTrue(initial.matches(note))
            switch edit {
            case "M": popup.modificationDate = Date(timeIntervalSince1970: 946_684_800)
            case "target":
                let replacement = PDFAnnotation(bounds: popup.bounds, forType: .popup, withProperties: nil)
                replacement.contents = popup.contents; replacement.modificationDate = popup.modificationDate
                replacement.isOpen = popup.isOpen
                XCTAssertTrue(note.setValue(replacement, forAnnotationKey: PDFAnnotationKey(rawValue: "/Popup")))
                note.contents = "Loaded note"
            case "color": popup.color = .systemRed
            case "bounds": popup.bounds = popup.bounds.offsetBy(dx: 7, dy: 9)
            case "contents": popup.contents = "A current popup edit"
            case "Open": popup.isOpen.toggle()
            default: XCTAssertTrue(popup.setValue("A current extra key", forAnnotationKey: PDFAnnotationKey(rawValue: "/CurrentExtra")))
            }
            XCTAssertFalse(initial.matches(note), edit)
            do { _ = try await workerSave(document); XCTFail("A current \(edit) edit must not be replaced by original absence.") } catch {}
        }
    }

    func test129RawNoPopupNotesRetainInitialLineageBeyondTheNormalizationLRU() async throws {
        let document = try opened(manyPairs(129, noPopup: true))
        for _ in 0..<2 {
            let saved = try await workerSave(document), native = try native(saved)
            XCTAssertEqual(native.numberOfPages, 129)
            for index in 0..<129 {
                let dictionary = try XCTUnwrap(native.page(at: index + 1)?.dictionary)
                let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "Annots"))
                XCTAssertEqual(CGPDFArrayGetCount(list), 1)
                var note: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &note))
                XCTAssertNil(PDFCatalogStructurePreserver.object(try XCTUnwrap(note), "Popup"))
            }
        }
        XCTAssertEqual(PDFAnnotationRelationshipLifecycle.footprint(for: document)?.captured, 129)
        XCTAssertLessThanOrEqual(try XCTUnwrap(PDFAnnotationRelationshipLifecycle.footprint(for: document)).bytes, 8 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(try XCTUnwrap(PDFCatalogStructurePreserver.relationshipCacheFootprint(for: document)).entries, 128)
    }

    func testSyntheticFloatingScalarsRetainTheirObservableBitsIncludingNextUpAndNegativeZero() throws {
        let document = try opened(fixture(nativePair: true, absentPopup: true))
        let note = try XCTUnwrap(document.page(at: 0)?.annotations.first), popup = try XCTUnwrap(note.popup)
        let key = PDFAnnotationKey(rawValue: "/NumericControl")
        var states: [PDFAnnotationRelationshipLifecycle.SyntheticState] = []
        for number in [NSNumber(value: Double(1.25)), NSNumber(value: Double(1.25).nextUp),
                       NSNumber(value: Float(1.25)), NSNumber(value: Float(1.25).nextUp),
                       NSNumber(value: Double(-0.0))] {
            XCTAssertTrue(popup.setValue(number, forAnnotationKey: key))
            let observed = try XCTUnwrap(popup.value(forAnnotationKey: key) as? NSNumber)
            let state = try XCTUnwrap(PDFAnnotationRelationshipLifecycle.SyntheticState(popup))
            let type = String(cString: observed.objCType)
            let bits = type == "f" ? UInt64(observed.floatValue.bitPattern) : type == "d" ? observed.doubleValue.bitPattern : nil
            XCTAssertEqual(state.values["/NumericControl"], .number(type, observed.stringValue, bits))
            states.append(state)
        }
        XCTAssertNotEqual(states[0], states[1]); XCTAssertNotEqual(states[2], states[3])
    }

    func testFailedOwnedMoveRestoresSourceWithoutDeletingAnUnownedTargetAnnotation() async throws {
        let document = try opened(fixture(nativePair: true, absentPopup: true))
        let source = try XCTUnwrap(document.page(at: 0)), originals = source.annotations
        let note = try XCTUnwrap(originals.first), popup = try XCTUnwrap(note.popup)
        note.modificationDate = Date(timeIntervalSince1970: 946_684_800)
        let bounds = note.bounds, contents = note.contents, date = note.modificationDate
        let popupDate = popup.modificationDate
        let handoff = try PDFAnnotationRelationshipPreserver.captureForMove(from: source)
        let target = PDFPage()
        originals.forEach { source.removeAnnotation($0) }; originals.forEach { target.addAnnotation($0) }
        let unowned = PDFAnnotation(bounds: CGRect(x: 70, y: 80, width: 20, height: 20), forType: .square, withProperties: nil)
        target.addAnnotation(unowned)
        XCTAssertThrowsError(try handoff.complete(on: target))
        originals.forEach { target.removeAnnotation($0) }; originals.forEach { source.addAnnotation($0) }
        try handoff.restore(on: source)
        XCTAssertEqual(source.annotations.map(ObjectIdentifier.init), originals.map(ObjectIdentifier.init))
        XCTAssertTrue(note.popup === popup)
        XCTAssertEqual(note.bounds, bounds); XCTAssertEqual(note.contents, contents); XCTAssertEqual(note.modificationDate, date)
        XCTAssertEqual(popup.modificationDate, popupDate)
        XCTAssertTrue(target.annotations.contains { $0 === unowned }, "Rollback must not delete a target annotation outside the captured SDK artifacts.")
        let saved = try await workerSave(document)
        try assertNoPopup(saved, null: false)
    }

    func testLegacyExclusionNeedsNativeAbsenceAndRejectsAnObservedTargetReplacement() async throws {
        let source = try opened(fixture(nativePair: true, absentPopup: true))
        let page = try XCTUnwrap(source.page(at: 0)), note = try XCTUnwrap(page.annotations.first)
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let copy = try XCTUnwrap(page.copy() as? PDFPage), copied = try XCTUnwrap(copy.annotations.first)
        try PDFAnnotationRelationshipPreserver.prepareOwnedCopy(from: page, to: copy)
        let nativeList = try XCTUnwrap(PDFCatalogStructurePreserver.array(XCTUnwrap(page.pageRef?.dictionary), "Annots"))
        var raw: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(nativeList, 0, &raw))
        try PDFAnnotationRelationshipPreserver.recordLegacyNoPopup(copied, on: copy, nativeOriginal: XCTUnwrap(raw))
        let output = PDFDocument(); output.insert(copy, at: 0)
        PDFCatalogStructurePreserver.inherit(from: page, to: copy)
        try PDFAnnotationRelationshipPreserver.inherit(from: page, to: copy)
        let saved = try await workerSave(output)
        try assertNoPopup(saved, null: false)
        let outside = PDFAnnotation(bounds: CGRect(x: 60, y: 80, width: 40, height: 50), forType: .popup, withProperties: nil)
        XCTAssertTrue(copied.setValue(outside, forAnnotationKey: PDFAnnotationKey(rawValue: "/Popup")))
        copied.contents = "Loaded note"
        XCTAssertTrue(copied.popup === outside)
        XCTAssertThrowsError(try directSave(output))
        XCTAssertEqual(note.contents, "Loaded note")
        let present = try opened(fixture(nativePair: true)), presentPage = try XCTUnwrap(present.page(at: 0))
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(XCTUnwrap(presentPage.pageRef?.dictionary), "Annots"))
        var original: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &original))
        XCTAssertThrowsError(try PDFAnnotationRelationshipPreserver.recordLegacyNoPopup(
            XCTUnwrap(presentPage.annotations.first), on: presentPage, nativeOriginal: XCTUnwrap(original)))
    }

    func testDuplicateNormalizedPairsAndUnboundSourceCannotBorrowOriginalAbsence() async throws {
        let duplicate = try opened(manyPairs(2, duplicate: true))
        do { _ = try await workerSave(duplicate); XCTFail("Duplicate source fingerprints grant no relationship origin.") } catch {}
        let bytes = fixture(nativePair: true, absentParent: true)
        let unbound = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertFalse(PDFRawStreamProvenance.hasKnownNativeInput(unbound))
        do { _ = try await workerSave(unbound); XCTFail("An arbitrary native/data similarity cannot grant source authority.") } catch {}
    }

    func testIsolatedProofRejectsAPActionsExternalReferencesUnknownGraphsAndOversizedStrings() async throws {
        for extra in ["/AP << /N << >> >>", "/A << /S /URI /URI (https://example.invalid) >>", "/P 8 0 R", "/Unknown 5 0 R",
                      "/UnknownContainer << /X [1 2] >>"] {
            let document = try opened(fixture(nativePair: true, absentParent: true, noteExtra: extra))
            let before = document.page(at: 0)!.annotations.map(ObjectIdentifier.init)
            do { _ = try await workerSave(document); XCTFail("Unsupported metadata must not be rewritten: \(extra.prefix(30))") } catch {}
            XCTAssertEqual(document.page(at: 0)!.annotations.map(ObjectIdentifier.init), before)
            XCTAssertEqual(PDFCatalogStructurePreserver.relationshipCacheFootprint(for: document)?.readers, 0)
        }
        let oversized = try opened(fixture(nativePair: true, absentParent: true, noteContents: String(repeating: "X", count: 9_000)))
        do { _ = try await workerSave(oversized); XCTFail("Oversized scalar metadata must be refused before a normalization reader.") } catch {}
        XCTAssertEqual(PDFCatalogStructurePreserver.relationshipCacheFootprint(for: oversized)?.readers, 0)
    }

    func testBudgetRefusalAndCancellationDoNotPoisonAWorkerRetry() async throws {
        let document = try opened(fixture(nativePair: true, absentParent: true)), page = try XCTUnwrap(document.page(at: 0))
        PDFCatalogStructurePreserver.prepareRelationshipSource(on: page)
        let source = try XCTUnwrap(PDFCatalogStructurePreserver.relationshipSource(for: page))
        let entry = try XCTUnwrap(PDFAnnotationRelationshipBaseline.entries(in: source, budget: nil).first)
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        let flags = try await Task.detached { () throws -> (Bool, Bool, Bool) in
            var refused = false, cancelled = false
            do { _ = try PDFAnnotationRelationshipBaseline.publicBaseline(for: entry, source: source,
                    budget: PDFAnnotationRelationshipBaseline.WorkBudget(bytes: 0)); } catch { refused = true }
            let first = source.cache.footprint
            do { _ = try PDFSaveCancellation.withCurrent(cancellation) {
                try PDFAnnotationRelationshipBaseline.publicBaseline(for: entry, source: source, budget: .init())
            } } catch is CancellationError { cancelled = true }
            let second = source.cache.footprint
            let result = try PDFAnnotationRelationshipBaseline.publicBaseline(for: entry, source: source, budget: .init())
            return (refused && first.entries == 0 && first.readers == 0, cancelled && second.entries == 0 && second.readers == 0, result?.parent == .absent)
        }.value
        XCTAssertTrue(flags.0); XCTAssertTrue(flags.1); XCTAssertTrue(flags.2)
    }

    func test129NormalizedNotesSaveAndRevisitBeyondResidentLRUCapacity() async throws {
        let document = try opened(manyPairs(129))
        let first = try await workerSave(document)
        let footprint = try XCTUnwrap(PDFCatalogStructurePreserver.relationshipCacheFootprint(for: document))
        XCTAssertEqual(footprint.entries, 128); XCTAssertLessThanOrEqual(footprint.bytes, 256 * 1_024)
        XCTAssertGreaterThanOrEqual(footprint.measurements, 129)
        let second = try await workerSave(document)
        let final = try XCTUnwrap(PDFCatalogStructurePreserver.relationshipCacheFootprint(for: document))
        XCTAssertEqual(final.entries, 128); XCTAssertLessThanOrEqual(final.bytes, 256 * 1_024)
        XCTAssertGreaterThan(final.measurements, footprint.measurements)
        for bytes in [first, second] {
            let native = try native(bytes); XCTAssertEqual(native.numberOfPages, 129)
            for index in 0..<129 {
                let dictionary = try XCTUnwrap(native.page(at: index + 1)?.dictionary)
                let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "Annots"))
                XCTAssertEqual(CGPDFArrayGetCount(list), 2)
                var note: CGPDFDictionaryRef?, popup: CGPDFDictionaryRef?, text: CGPDFStringRef?
                XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &note)); XCTAssertTrue(CGPDFArrayGetDictionary(list, 1, &popup))
                let n = try XCTUnwrap(note), p = try XCTUnwrap(popup)
                XCTAssertNil(PDFCatalogStructurePreserver.object(p, "Parent"))
                XCTAssertEqual(PDFCatalogStructurePreserver.dictionary(n, "Popup").map(pdfReferenceIdentity), pdfReferenceIdentity(p))
                XCTAssertTrue(CGPDFDictionaryGetString(n, "Contents", &text))
                XCTAssertEqual(CGPDFStringCopyTextString(try XCTUnwrap(text)) as String?, "Note \(index)")
            }
        }
    }

    func testUnobservableParentRemovalPreservesTheCurrentRelationAndObservableChangeIsRejected() throws {
        let source = try opened(); _ = try addNote(to: source)
        let copy = try PDFRecoverySnapshot(capturing: source).takeDocument(), page = try XCTUnwrap(copy.page(at: 0))
        let popup = try XCTUnwrap(page.annotations.first { $0.type == "Popup" })
        let note = try XCTUnwrap(page.annotations.first { $0.type == "Text" })
        popup.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent"))
        XCTAssertTrue(popup.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")) as? PDFAnnotation === note)
        XCTAssertTrue(popup.setValue(NSNull(), forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")))
        XCTAssertTrue(popup.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")) as? PDFAnnotation === note)
        try assertPair(directSave(copy), contents: "Current note")
        let other = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 20, height: 20), forType: .text, withProperties: nil)
        XCTAssertTrue(popup.setValue(other, forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")))
        XCTAssertTrue(popup.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")) as? PDFAnnotation === other)
        XCTAssertThrowsError(try directSave(copy), "A genuinely changed parent cannot be replaced with the old boundary record.")
    }

    func testExistingEraserTextRemovalSaveAndUndoSaveKeepCurrentMembership() throws {
        for loaded in [false, true] {
            let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
            try fixture(nativePair: loaded).write(to: url)
            let workspace = PDFWorkspaceState()
            XCTAssertTrue(workspace.open(url: url))
            workspace.setMode(.editing); workspace.activeTool = .eraser
            let document = try XCTUnwrap(workspace.document)
            if !loaded { _ = try addNote(to: document) }
            let page = try XCTUnwrap(document.page(at: 0)), before = page.annotations.map(ObjectIdentifier.init)
            let note = try XCTUnwrap(page.annotations.first { $0.type == "Text" })
            XCTAssertTrue(workspace.removeAnnotationWithEraser(note, from: page))
            XCTAssertFalse(page.annotations.contains { $0 === note })
            let removed = try directSave(document), nativeRemoved = try native(removed)
            if let list = PDFCatalogStructurePreserver.array(try XCTUnwrap(nativeRemoved.page(at: 1)?.dictionary), "Annots") {
                for index in 0..<CGPDFArrayGetCount(list) {
                    var annotation: CGPDFDictionaryRef?
                    XCTAssertTrue(CGPDFArrayGetDictionary(list, index, &annotation))
                    let item = try XCTUnwrap(annotation)
                    var subtype: UnsafePointer<CChar>?
                    XCTAssertTrue(CGPDFDictionaryGetName(item, "Subtype", &subtype))
                    XCTAssertNotEqual(String(cString: try XCTUnwrap(subtype)), "Text")
                    XCTAssertNil(PDFCatalogStructurePreserver.object(item, "Parent"), "Removing the note must never serialize another hidden Text owner.")
                }
            }
            XCTAssertTrue(workspace.canUndo)
            workspace.undo()
            XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), before)
            try assertPair(directSave(document), contents: loaded ? "Loaded note" : "Current note")
        }
    }

    func testExtractMergeUndoRedoReopenAndReeditKeepMutualCurrentReferences() async throws {
        let source = try opened(); _ = try addNote(to: source)
        let sourceIDs = source.page(at: 0)!.annotations.map(ObjectIdentifier.init)
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0]), merged = PDFDocument()
        let imported = try PDFPageStructurePreserver.prepareImport(from: extracted, indexes: [0])
        let transaction = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: merged, at: 0)
        try transaction.apply(); try transaction.undo(); XCTAssertEqual(merged.pageCount, 0); try transaction.redo()
        let first = try await workerSave(merged); try assertPair(first, contents: "Current note")
        let reopened = try opened(first)
        try XCTUnwrap(reopened.page(at: 0)?.annotations.first { $0.type == "Text" }).contents = "Edited again"
        let edited = try await workerSave(reopened)
        try assertPair(edited, contents: "Edited again")
        XCTAssertEqual(source.page(at: 0)!.annotations.map(ObjectIdentifier.init), sourceIDs)
        XCTAssertEqual(source.page(at: 0)?.annotations.first?.contents, "Current note")
    }

    func testUnlistedAndCrossPageRawTargetsFailClosedBeforeSave() throws {
        for mode in ["unlisted", "cross-page", "ambiguous"] {
            let document = try opened(fixture(nativePair: true, invalid: mode))
            let before = document.page(at: 0)!.annotations.map(ObjectIdentifier.init)
            XCTAssertThrowsError(try directSave(document), mode)
            XCTAssertEqual(document.page(at: 0)!.annotations.map(ObjectIdentifier.init), before)
        }
    }

    func testRemovingTheCurrentPopupNeverRestoresTheOldTarget() throws {
        let source = try opened(); _ = try addNote(to: source)
        let snapshot = try PDFRecoverySnapshot(capturing: source), copy = try snapshot.takeDocument()
        let page = try XCTUnwrap(copy.page(at: 0)), note = try XCTUnwrap(page.annotations.first { $0.type == "Text" })
        let popup = try XCTUnwrap(page.annotations.first { $0.type == "Popup" })
        page.removeAnnotation(popup)
        XCTAssertFalse(page.annotations.contains { $0 === popup })
        if note.popup == nil {
            let saved = try directSave(copy), native = try native(saved)
            let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(XCTUnwrap(native.page(at: 1)?.dictionary), "Annots"))
            var field: CGPDFDictionaryRef?; XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &field))
            XCTAssertNil(PDFCatalogStructurePreserver.object(try XCTUnwrap(field), "Popup"))
        } else { XCTAssertThrowsError(try directSave(copy), "A dangling observed target cannot authorize its resurrection.") }
    }

    func testNewCurrentPopupWinsOverCopiedRelationshipMetadata() throws {
        let source = try opened(); _ = try addNote(to: source)
        let copy = try PDFRecoverySnapshot(capturing: source).takeDocument(), page = try XCTUnwrap(copy.page(at: 0))
        let note = try XCTUnwrap(page.annotations.first { $0.type == "Text" }), old = try XCTUnwrap(page.annotations.first { $0.type == "Popup" })
        note.popup = nil; page.removeAnnotation(old)
        let replacement = PDFAnnotation(bounds: CGRect(x: 60, y: 50, width: 90, height: 70), forType: .popup, withProperties: nil)
        note.popup = replacement
        XCTAssertTrue(replacement.setValue(note, forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")))
        if !page.annotations.contains(where: { $0 === replacement }) { page.addAnnotation(replacement) }
        XCTAssertTrue(note.popup === replacement)
        // The SDK's popup=nil setter clears Contents before any writer runs.
        // This fixture explicitly requests the current replacement's text.
        note.contents = "Current note"
        XCTAssertEqual(note.contents, "Current note")
        let saved = try directSave(copy); try assertPair(saved, contents: "Current note")
        let reopened = try XCTUnwrap(PDFDocument(data: saved))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first { $0.type == "Popup" }?.bounds, replacement.bounds)
        XCTAssertFalse(page.annotations.contains { $0 === old })
    }

    func testChangedUnlistedCopyTargetDoesNotMatchTheCapturedBoundary() throws {
        let source = try opened(); _ = try addNote(to: source)
        let copy = try PDFRecoverySnapshot(capturing: source).takeDocument(), page = try XCTUnwrap(copy.page(at: 0))
        let note = try XCTUnwrap(page.annotations.first { $0.type == "Text" })
        let outside = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 20, height: 20), forType: .popup, withProperties: nil)
        XCTAssertTrue(note.setValue(outside, forAnnotationKey: PDFAnnotationKey(rawValue: "/Popup")))
        if page.annotations.contains(where: { $0 === outside }) { page.removeAnnotation(outside) }
        XCTAssertThrowsError(try directSave(copy))
    }

    func testOtherMarkupAndWidgetParentsStayOutsideThisRepair() throws {
        let document = try opened(), page = try XCTUnwrap(document.page(at: 0))
        let highlight = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 30, height: 10), forType: .highlight, withProperties: nil)
        let popup = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 30, height: 20), forType: .popup, withProperties: nil)
        page.addAnnotation(highlight); page.addAnnotation(popup)
        XCTAssertTrue(popup.setValue(highlight, forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")))
        let widget = PDFAnnotation(bounds: CGRect(x: 10, y: 40, width: 50, height: 20), forType: .widget, withProperties: nil)
        page.addAnnotation(widget)
        XCTAssertTrue(widget.setValue(highlight, forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")))
        var plan = PDFCatalogGraphPlan()
        try PDFAnnotationRelationshipPreserver.addCurrentRelationships(in: document, to: &plan)
        XCTAssertTrue(plan.annotationEntries.isEmpty)
        XCTAssertTrue(plan.annotationDrops.isEmpty)
        XCTAssertTrue(widget.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/Parent")) as? PDFAnnotation === highlight)
    }

    func testPasswordWriteOptionsKeepTheirExistingTransformBoundary() throws {
        let document = try opened(); _ = try addNote(to: document)
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        try AtomicPDFWriter.write(document, to: url,
            writeOptions: [.ownerPasswordOption: "owner-popup-90", .userPasswordOption: "reader-popup-90"],
            validateSerializedDocument: { staged, count in
                XCTAssertTrue(staged.isEncrypted)
                XCTAssertTrue(staged.unlock(withPassword: "owner-popup-90"))
                XCTAssertEqual(staged.pageCount, count)
            })
        let encrypted = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(encrypted.isEncrypted)
        XCTAssertTrue(encrypted.isLocked)
        XCTAssertTrue(encrypted.unlock(withPassword: "reader-popup-90"))
        XCTAssertEqual(encrypted.pageCount, 1)
        XCTAssertFalse(PDFCatalogStructurePreserver.needsMaterialization(document), "The relationship helper must not select plaintext graph rewriting for explicit write options.")
    }

    func testCancellationAndAnnotationBudgetRefuseBeforeRelationshipInference() throws {
        let document = try opened(); _ = try addNote(to: document)
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(cancellation) {
            try PDFAnnotationRelationshipPreserver.prepareForWriting(document)
        }) { XCTAssertTrue($0 is CancellationError) }
        var budget = 1
        XCTAssertThrowsError(try PDFAnnotationRelationshipPreserver.validate(XCTUnwrap(document.page(at: 0)), remainingAnnotations: &budget))
        XCTAssertEqual(budget, 1)
    }

    private func opened(_ data: Data? = nil) throws -> PDFDocument {
        let bytes = data ?? fixture(), document = try XCTUnwrap(PDFDocument(data: bytes))
        PDFRawStreamProvenance.bindCreated(document, data: bytes)
        return document
    }
    private final class ExistingDelegate: NSObject, PDFDocumentDelegate {}
    private func addNote(to document: PDFDocument) throws -> (note: PDFAnnotation, popup: PDFAnnotation) {
        let page = try XCTUnwrap(document.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Current note"; page.addAnnotation(note)
        let popup = try XCTUnwrap(note.popup)
        XCTAssertTrue(page.annotations.contains { $0 === popup })
        return (note, popup)
    }
    private func directSave(_ document: PDFDocument) throws -> Data {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        try AtomicPDFWriter.write(document, to: url)
        return try Data(contentsOf: url)
    }
    private func workerSave(_ document: PDFDocument) async throws -> Data {
        let snapshot = try PDFRecoverySnapshot(capturing: document), url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        return try await Task.detached {
            try AtomicPDFWriter.write(snapshot.takeDocument(), to: url)
            return try Data(contentsOf: url)
        }.value
    }
    private func temporaryURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("Ember-popup-\(UUID()).pdf") }
    private func native(_ data: Data) throws -> CGPDFDocument {
        try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: data as CFData))))
    }
    private func assertNoPopup(_ bytes: Data, null: Bool, count: Int = 1) throws {
        let document = try native(bytes), page = try XCTUnwrap(document.page(at: 1)?.dictionary)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
        XCTAssertEqual(CGPDFArrayGetCount(list), count)
        var note: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &note))
        let value = PDFCatalogStructurePreserver.object(try XCTUnwrap(note), "Popup")
        if null { XCTAssertEqual(CGPDFObjectGetType(try XCTUnwrap(value)), .null) } else { XCTAssertNil(value) }
        var status: Int32 = 0
        let context = bytes.withUnsafeBytes { ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, bytes.count, bytes.count, 100_000, &status) }
        XCTAssertEqual(status, Int32(EMBER_RAW_PDF_OK.rawValue)); let c = try XCTUnwrap(context); defer { ember_raw_pdf_destroy(c) }
        func get(_ owner: EmberRawPDFObject, _ key: String) -> EmberRawPDFObject {
            var result: EmberRawPDFObject = 0
            XCTAssertEqual(Array(key.utf8).withUnsafeBufferPointer { ember_raw_pdf_dictionary_get(c, owner, $0.baseAddress, $0.count, &result) }, Int32(EMBER_RAW_PDF_OK.rawValue))
            return result
        }
        var rawPage: EmberRawPDFObject = 0, rawNote: EmberRawPDFObject = 0
        XCTAssertEqual(ember_raw_pdf_page(c, 0, &rawPage), Int32(EMBER_RAW_PDF_OK.rawValue))
        XCTAssertEqual(ember_raw_pdf_array_item(c, get(rawPage, "/Annots"), 0, &rawNote), Int32(EMBER_RAW_PDF_OK.rawValue))
        var keys: UInt32 = 0, found = false
        XCTAssertEqual(ember_raw_pdf_dictionary_count(c, rawNote, &keys), Int32(EMBER_RAW_PDF_OK.rawValue))
        for index in 0..<keys {
            var key: UnsafeMutablePointer<UInt8>?, length = 0
            XCTAssertEqual(ember_raw_pdf_dictionary_key_copy(c, rawNote, index, &key, &length), Int32(EMBER_RAW_PDF_OK.rawValue))
            defer { if let key { ember_raw_pdf_free(key) } }
            if let key, Data(bytes: key, count: length) == Data("/Popup".utf8) { found = true }
        }
        XCTAssertEqual(found, null)
        if null {
            var kind: Int32 = -1
            XCTAssertEqual(ember_raw_pdf_kind(c, get(rawNote, "/Popup"), &kind), Int32(EMBER_RAW_PDF_OK.rawValue))
            XCTAssertEqual(kind, Int32(EMBER_RAW_PDF_NULL.rawValue))
        }
    }
    private func assertPair(_ data: Data, contents: String, hasParent: Bool = true, nullParent: Bool = false) throws {
        let document = try native(data), page = try XCTUnwrap(document.page(at: 1)?.dictionary)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
        XCTAssertEqual(CGPDFArrayGetCount(list), 2)
        var note: CGPDFDictionaryRef?, popup: CGPDFDictionaryRef?, value: CGPDFStringRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &note)); XCTAssertTrue(CGPDFArrayGetDictionary(list, 1, &popup))
        let n = try XCTUnwrap(note), p = try XCTUnwrap(popup)
        XCTAssertEqual(pdfReferenceIdentity(try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(n, "Popup"))), pdfReferenceIdentity(p))
        if hasParent {
            XCTAssertEqual(pdfReferenceIdentity(try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(p, "Parent"))), pdfReferenceIdentity(n))
        } else if nullParent {
            XCTAssertEqual(CGPDFObjectGetType(try XCTUnwrap(PDFCatalogStructurePreserver.object(p, "Parent"))), .null)
        } else { XCTAssertNil(PDFCatalogStructurePreserver.object(p, "Parent")) }
        XCTAssertTrue(CGPDFDictionaryGetString(n, "Contents", &value)); XCTAssertEqual(CGPDFStringCopyTextString(try XCTUnwrap(value)) as String?, contents)
        try assertIndependentRawPair(data, hasParent: hasParent, nullParent: nullParent)
        withExtendedLifetime(document) {}
    }
    private func assertIndependentRawPair(_ bytes: Data, hasParent: Bool, nullParent: Bool) throws {
        var status: Int32 = 0
        let context = bytes.withUnsafeBytes { ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, bytes.count, bytes.count, 100_000, &status) }
        XCTAssertEqual(status, Int32(EMBER_RAW_PDF_OK.rawValue)); let c = try XCTUnwrap(context); defer { ember_raw_pdf_destroy(c) }
        func get(_ dictionary: EmberRawPDFObject, _ key: String) -> EmberRawPDFObject {
            var value: EmberRawPDFObject = 0
            let result = Array(key.utf8).withUnsafeBufferPointer { ember_raw_pdf_dictionary_get(c, dictionary, $0.baseAddress, $0.count, &value) }
            XCTAssertEqual(result, Int32(EMBER_RAW_PDF_OK.rawValue)); return value
        }
        var page: EmberRawPDFObject = 0, note: EmberRawPDFObject = 0, popup: EmberRawPDFObject = 0
        XCTAssertEqual(ember_raw_pdf_page(c, 0, &page), Int32(EMBER_RAW_PDF_OK.rawValue))
        let list = get(page, "/Annots")
        XCTAssertEqual(ember_raw_pdf_array_item(c, list, 0, &note), Int32(EMBER_RAW_PDF_OK.rawValue))
        XCTAssertEqual(ember_raw_pdf_array_item(c, list, 1, &popup), Int32(EMBER_RAW_PDF_OK.rawValue))
        XCTAssertEqual(get(note, "/Popup"), popup)
        if hasParent { XCTAssertEqual(get(popup, "/Parent"), note) }
        else {
            var found = false
            var count: UInt32 = 0
            XCTAssertEqual(ember_raw_pdf_dictionary_count(c, popup, &count), Int32(EMBER_RAW_PDF_OK.rawValue))
            for index in 0..<count {
                var key: UnsafeMutablePointer<UInt8>?, length = 0
                XCTAssertEqual(ember_raw_pdf_dictionary_key_copy(c, popup, index, &key, &length), Int32(EMBER_RAW_PDF_OK.rawValue))
                defer { if let key { ember_raw_pdf_free(key) } }
                if let key, Data(bytes: key, count: length) == Data("/Parent".utf8) { found = true }
            }
            XCTAssertEqual(found, nullParent)
            if nullParent {
                var kind: Int32 = -1
                XCTAssertEqual(ember_raw_pdf_kind(c, get(popup, "/Parent"), &kind), Int32(EMBER_RAW_PDF_OK.rawValue))
                XCTAssertEqual(kind, Int32(EMBER_RAW_PDF_NULL.rawValue))
            }
        }
    }
    private func fixture(nativePair: Bool = false, invalid: String = "", absentParent: Bool = false,
                         nullParent: Bool = false, normalized: Bool = false, absentPopup: Bool = false,
                         nullPopup: Bool = false, noteExtra: String = "", noteContents: String = "Loaded note") -> Data {
        let cross = invalid == "cross-page", ambiguous = invalid == "ambiguous"
        let annots = nativePair ? " /Annots [5 0 R" + (ambiguous ? " 7 0 R" : "") + ((invalid == "unlisted" || cross || absentPopup || nullPopup) ? "" : " 6 0 R") + "]" : ""
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R\(cross ? " 8 0 R" : "")] /Count \(cross ? 2 : 1) >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << >> /Contents 4 0 R\(annots) >>",
                       "<< /Length 3 >>\nstream\nq Q\nendstream",
                       "<< /Type /Annot /Subtype /Text /Rect [\(normalized ? "10 6 34 30" : "10 10 30 30")] /Contents (\(noteContents))\(absentPopup ? "" : nullPopup ? " /Popup null" : " /Popup 6 0 R") \(noteExtra) >>",
                       "<< /Type /Annot /Subtype /Popup /Rect [40 40 90 90]\(absentParent ? "" : nullParent ? " /Parent null" : " /Parent 5 0 R")\(normalized ? " /Contents (Loaded note)" : "") >>",
                       "<< /Type /Annot /Subtype /Text /Rect [100 100 120 120] /Contents (Second) /Popup 6 0 R >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << >> /Contents 4 0 R /Annots [6 0 R] >>"]
        if !nativePair { objects = Array(objects.prefix(4)) }
        return pdf(objects)
    }
    private func manyPairs(_ count: Int, duplicate: Bool = false, noPopup: Bool = false) -> Data {
        if duplicate {
            return pdf(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << >> /Annots [4 0 R 5 0 R 6 0 R 7 0 R] >>",
                "<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (Same) /Popup 5 0 R >>",
                "<< /Type /Annot /Subtype /Popup /Rect [40 40 90 90] >>",
                "<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (Same) /Popup 7 0 R >>",
                "<< /Type /Annot /Subtype /Popup /Rect [40 40 90 90] >>"])
        }
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", ""], kids: [String] = []
        for index in 0..<count {
            let page = objects.count + 1; kids.append("\(page) 0 R")
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << >> /Annots [\(page + 1) 0 R\(noPopup ? "" : " \(page + 2) 0 R")] >>")
            objects.append("<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (Note \(index))\(noPopup ? "" : " /Popup \(page + 2) 0 R") >>")
            objects.append("<< /Type /Annot /Subtype /Popup /Rect [40 40 90 90] >>")
        }
        objects[1] = "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(count) >>"
        return pdf(objects)
    }
    private func pdf(_ objects: [String]) -> Data {
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let xref = data.count; data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)); return data
    }
}
