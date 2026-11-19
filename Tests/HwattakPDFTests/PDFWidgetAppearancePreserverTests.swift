// SPDX-License-Identifier: MPL-2.0

import AppKit
import CEmberPDFRawStreams
import CoreGraphics
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFWidgetAppearancePreserverTests: XCTestCase {
    @MainActor
    func testMainPrepareReadsOnlyCacheAndBackgroundSnapshotResolvesAppearance() async throws {
        let document = try opened(prewarm: false)
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertNil(try raw.originalWidgetStates(onPage: 0))
        try PDFCatalogStructurePreserver.prepare(document, force: true)
        XCTAssertEqual(try PDFCatalogStructurePreserver.plan(for: document).widgetAppearanceCount, 0)
        let snapshot = try PDFRecoverySnapshot(capturing: document)
        let saved = try await Task.detached { try snapshot.serializedData() }.value
        XCTAssertNotNil(try raw.originalWidgetStates(onPage: 0), "Worker published scalar state is reusable on main.")
        XCTAssertEqual(try appearance(saved), try appearance(fixture()))
        XCTAssertEqual(try pixels(saved), try pixels(fixture()))
    }

    func testUnchangedOriginalReaderWidgetIsActuallyEligible() throws {
        let document = try opened()
        try PDFCatalogStructurePreserver.prepare(document, force: true)
        let plan = try PDFCatalogStructurePreserver.plan(for: document)
        XCTAssertEqual(plan.widgetAppearanceCount, 1)
        XCTAssertNotNil(plan.widgetFormDefaults)
        XCTAssertEqual(plan.widgetFormLocations.count, 1)
    }

    func testExtractSaveReopenPreservesCustomAppearanceDefaultResourcesAndActualFieldIdentity() throws {
        let data = fixture()
        let source = try opened(data)
        let output = try PDFPageOperations.extract(from: source, indexes: [0])
        XCTAssertEqual(try PDFCatalogStructurePreserver.plan(for: output).widgetAppearanceCount, 1)
        let saved = try save(output)
        XCTAssertEqual(try appearance(saved), try appearance(data))
        XCTAssertEqual(try pixels(saved), try pixels(data))
        let reopened = try XCTUnwrap(PDFDocument(data: saved))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.widgetStringValue, "Ada")
        try assertCanonicalFields(saved)
        let form = try formDictionary(saved)
        XCTAssertNotNil(PDFCatalogStructurePreserver.object(form.dictionary, "DA"))
        let resources = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(form.dictionary, "DR"))
        let fonts = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(resources, "Font"))
        XCTAssertNotNil(PDFCatalogStructurePreserver.object(fonts, "SourceFont"))
        withExtendedLifetime(form.document) {}
    }

    func testMergeUndoRedoPreservesAppearanceAndCanReeditAfterReopen() throws {
        let source = try opened()
        let target = PDFDocument()
        let imported = try PDFPageStructurePreserver.prepareImport(from: source, indexes: [0])
        let merge = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: target, at: 0)
        try merge.apply()
        try merge.undo()
        XCTAssertEqual(target.pageCount, 0)
        try merge.redo()
        XCTAssertEqual(try PDFCatalogStructurePreserver.plan(for: target).widgetAppearanceCount, 1)
        let first = try save(target)
        XCTAssertEqual(try appearance(first), try appearance(fixture()))
        let reopened = try opened(first)
        let field = try widget(reopened)
        field.widgetStringValue = "Grace"
        try PDFCatalogStructurePreserver.prepare(reopened, force: true)
        XCTAssertEqual(try PDFCatalogStructurePreserver.plan(for: reopened).widgetAppearanceCount, 0)
        let edited = try save(reopened)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(data: edited)).page(at: 0)?.annotations.first?.widgetStringValue, "Grace")
        XCTAssertNotEqual(try appearance(edited), try appearance(first))
        XCTAssertEqual(try widget(source).widgetStringValue, "Ada")
    }

    func testLateFirstPrepareValueAndDefaultChangesWin() throws {
        for changeDefault in [false, true] {
            let document = try opened()
            let field = try widget(document)
            if changeDefault { field.widgetDefaultStringValue = "Other default" }
            else { field.widgetStringValue = "Grace" }
            try PDFCatalogStructurePreserver.prepare(document, force: true)
            XCTAssertEqual(try PDFCatalogStructurePreserver.plan(for: document).widgetAppearanceCount, 0)
            let reopened = try XCTUnwrap(PDFDocument(data: save(document)))
            if changeDefault { XCTAssertEqual(try widget(reopened).widgetDefaultStringValue, "Other default") }
            else { XCTAssertEqual(try widget(reopened).widgetStringValue, "Grace") }
        }
    }

    @MainActor
    func testMainCaptureWorkerSaveKeepsEditedDefaultAndRejectsOldAppearance() async throws {
        let source = try opened(prewarm: false)
        try widget(source).widgetDefaultStringValue = "Other default"
        let inspection = try PDFRecoverySnapshot(capturing: source)
        let snapshot = try PDFRecoverySnapshot(capturing: source)
        let proof = try await Task.detached {
            let copy = try inspection.takeDocument()
            return (copy.page(at: 0)?.annotations.first?.widgetDefaultStringValue,
                    try PDFCatalogStructurePreserver.plan(for: copy).widgetAppearanceCount)
        }.value
        XCTAssertEqual(proof.0, "Other default", "The real main-to-worker copy must preserve the current DV before AP eligibility.")
        XCTAssertEqual(proof.1, 0, "A changed default must never qualify for the original appearance.")
        let saved = try await Task.detached { try snapshot.serializedData() }.value
        let reopened = try XCTUnwrap(PDFDocument(data: saved))
        XCTAssertEqual(try widget(reopened).widgetDefaultStringValue, "Other default")
        XCTAssertEqual(try widget(source).widgetDefaultStringValue, "Other default")
    }

    @MainActor
    func testCheckboxSnapshotKeepsCurrentValueStateRawNamesAndOriginalSource() async throws {
        let bytes = fixture(fieldType: "Btn"), source = try opened(bytes, prewarm: false)
        let field = try widget(source)
        let value = field.widgetStringValue, defaultValue = field.widgetDefaultStringValue
        let state = field.buttonWidgetState, stateString = field.buttonWidgetStateString
        let snapshot = try PDFRecoverySnapshot(capturing: source)
        XCTAssertEqual(field.widgetStringValue, value)
        XCTAssertEqual(field.widgetDefaultStringValue, defaultValue)
        XCTAssertEqual(field.buttonWidgetState, state)
        XCTAssertEqual(field.buttonWidgetStateString, stateString)
        let saved = try await Task.detached { try snapshot.serializedData() }.value
        let reopened = try widget(XCTUnwrap(PDFDocument(data: saved)))
        XCTAssertEqual(reopened.widgetStringValue, value)
        XCTAssertEqual(reopened.buttonWidgetState, state)
        XCTAssertEqual(reopened.buttonWidgetStateString, stateString)
        XCTAssertEqual(try rawButtonNames(saved).value, try rawButtonNames(bytes).value)
        XCTAssertEqual(try rawButtonNames(saved).appearance, try rawButtonNames(bytes).appearance)
        XCTAssertEqual(try pixels(saved), try pixels(bytes))
        XCTAssertEqual(field.widgetStringValue, value)
        XCTAssertEqual(field.buttonWidgetState, state)
    }

    @MainActor
    func testChangedCheckboxSnapshotPreservesCurrentOnStateWithoutRestoringOldAP() async throws {
        let source = try opened(fixture(fieldType: "Btn"), prewarm: false)
        let field = try widget(source)
        field.buttonWidgetStateString = "On"; field.buttonWidgetState = .onState
        let current = field.widgetStringValue
        let inspection = try PDFRecoverySnapshot(capturing: source)
        let snapshot = try PDFRecoverySnapshot(capturing: source)
        let count = try await Task.detached {
            try PDFCatalogStructurePreserver.plan(for: inspection.takeDocument()).widgetAppearanceCount
        }.value
        XCTAssertEqual(count, 0)
        let saved = try await Task.detached { try snapshot.serializedData() }.value
        let reopened = try widget(XCTUnwrap(PDFDocument(data: saved)))
        XCTAssertEqual(reopened.widgetStringValue, current)
        XCTAssertEqual(reopened.buttonWidgetState, .onState)
        XCTAssertEqual(try rawButtonNames(saved).value, "On")
        XCTAssertEqual(try rawButtonNames(saved).appearance, "On")
        XCTAssertEqual(field.widgetStringValue, current)
        XCTAssertEqual(field.buttonWidgetState, .onState)
    }

    @MainActor
    func testCheckboxSnapshotStaysOffWhileSourceChangesToOnBeforeWorkerSave() async throws {
        let bytes = fixture(fieldType: "Btn"), source = try opened(bytes, prewarm: false)
        let field = try widget(source)
        let snapshot = try PDFRecoverySnapshot(capturing: source)
        field.buttonWidgetStateString = "On"; field.buttonWidgetState = .onState
        let current = field.widgetStringValue
        let saved = try await Task.detached { try snapshot.serializedData() }.value
        let reopened = try widget(XCTUnwrap(PDFDocument(data: saved)))
        XCTAssertEqual(reopened.buttonWidgetState, .offState)
        XCTAssertEqual(try rawButtonNames(saved).value, "Off")
        XCTAssertEqual(try rawButtonNames(saved).appearance, "Off")
        XCTAssertEqual(try pixels(saved), try pixels(bytes))
        XCTAssertEqual(field.widgetStringValue, current)
        XCTAssertEqual(field.buttonWidgetState, .onState)
        XCTAssertEqual(field.buttonWidgetStateString, "On")
    }

    @MainActor
    func testAbsentAndExplicitEmptyDefaultsSurviveExtractMergeUndoRedoAndWorkerReopen() async throws {
        for absent in [true, false] {
            for value in ["", "Ada"] {
                let bytes = fixture(value: value, defaultToken: "()", omitDefault: absent)
                let source = try opened(bytes, prewarm: false), original = try widget(source)
                XCTAssertEqual(try hasRawDefault(bytes), !absent, "The immutable CG input is the stored-default presence oracle.")
                let originalDefault = original.widgetDefaultStringValue
                let independent = try widget(XCTUnwrap(PDFDocument(data: bytes)))
                XCTAssertEqual(originalDefault, independent.widgetDefaultStringValue)
                let originalPublic = PDFWidgetAppearancePreserver.boundedDefaultFingerprint(
                    original.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV")))
                if absent { XCTAssertEqual(originalDefault, value, "Independent SDK getter falls back to current V; it is not a stored DV.") }
                let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
                let merged = PDFDocument()
                let imported = try PDFPageStructurePreserver.prepareImport(from: extracted, indexes: [0])
                let transaction = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: merged, at: 0)
                try transaction.apply(); try transaction.undo(); XCTAssertEqual(merged.pageCount, 0); try transaction.redo()
                for output in [extracted, merged] {
                    XCTAssertEqual(try widget(output).widgetDefaultStringValue, originalDefault)
                    let snapshot = try PDFRecoverySnapshot(capturing: output)
                    let saved = try await Task.detached { try snapshot.serializedData() }.value
                    XCTAssertEqual(try hasRawDefault(saved), !absent)
                    if !absent { XCTAssertEqual(try rawDefaultString(saved), "") }
                    let reopened = try widget(XCTUnwrap(PDFDocument(data: saved)))
                    XCTAssertEqual(reopened.widgetStringValue, value)
                    XCTAssertEqual(reopened.widgetDefaultStringValue, originalDefault)
                }
                XCTAssertEqual(original.widgetStringValue, value)
                XCTAssertEqual(original.widgetDefaultStringValue, originalDefault)
                let originalRaw = original.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV"))
                XCTAssertEqual(PDFWidgetAppearancePreserver.boundedDefaultFingerprint(originalRaw), originalPublic,
                               "Public fallback properties stay unchanged; they do not establish native /DV presence.")
            }
        }
    }

    @MainActor
    func testCurrentEditedDefaultSurvivesStructuralAssemblyAndWorkerReopen() async throws {
        let source = try opened(fixture(omitDefault: true), prewarm: false)
        try widget(source).widgetDefaultStringValue = "Current edited default"
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0]), merged = PDFDocument()
        let imported = try PDFPageStructurePreserver.prepareImport(from: extracted, indexes: [0])
        let transaction = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: merged, at: 0)
        try transaction.apply(); try transaction.undo(); try transaction.redo()
        for output in [extracted, merged] {
            XCTAssertEqual(try widget(output).widgetDefaultStringValue, "Current edited default")
            let snapshot = try PDFRecoverySnapshot(capturing: output)
            let saved = try await Task.detached { try snapshot.serializedData() }.value
            XCTAssertEqual(try rawDefaultString(saved), "Current edited default")
            XCTAssertEqual(try widget(XCTUnwrap(PDFDocument(data: saved))).widgetDefaultStringValue, "Current edited default")
        }
        XCTAssertEqual(try widget(source).widgetDefaultStringValue, "Current edited default")
    }

    func testCompositeChoiceDefaultStaysTypedDuringUnchangedStructuralAssembly() throws {
        let bytes = fixture(fieldType: "Ch", defaultToken: "[(Ada) (Grace)]", flags: 1 << 21, properChoice: true)
        let source = try opened(bytes)
        XCTAssertEqual(source.pageCount, 1)
        XCTAssertEqual(source.page(at: 0)?.annotations.count, 1, "A valid multiselect fixture needs Opt, array V and matching I.")
        let before = try nativeChoiceDefault(try XCTUnwrap(source.page(at: 0)))
        XCTAssertEqual(before, ["Ada", "Grace"])
        let extracted = try PDFPageOperations.extract(from: source, indexes: [0]), merged = PDFDocument()
        let imported = try PDFPageStructurePreserver.prepareImport(from: extracted, indexes: [0])
        let transaction = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: merged, at: 0)
        try transaction.apply(); try transaction.undo(); try transaction.redo()
        for output in [extracted, merged] {
            let after = try nativeChoiceDefault(XCTUnwrap(output.page(at: 0)))
            XCTAssertEqual(after, before, "A choice array cannot be replaced by the scalar default getter.")
        }
        XCTAssertEqual(try nativeChoiceDefault(XCTUnwrap(source.page(at: 0))), before)
    }

    func testInterleavedScalarDefaultCopySurvivesEarlierWidgetReferenceInvalidation() throws {
        for token: String? in [nil, "null"] {
            let (source, page) = try interleavedCopySource(defaultToken: token)
            let original = try XCTUnwrap(page.annotations.last)
            let getter = original.widgetDefaultStringValue
            let before = try XCTUnwrap(PDFWidgetAppearancePreserver.boundedDefaultFingerprint(
                original.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV"))))
            if token == nil {
                XCTAssertEqual(original.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV")) as? String, "Ada",
                               "This fixture must exercise the SDK's public fallback, not a nil-only default.")
            }
            let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
            XCTAssertTrue(try XCTUnwrap(page.lastCopy).invalidatedByValueRestore,
                          "The first copied widget must invalidate the reference before the later default is restored.")
            XCTAssertNil(page.lastCopy?.pageRef)
            let current = try XCTUnwrap(extracted.page(at: 0)?.annotations.last)
            XCTAssertEqual(current.widgetStringValue, "Ada")
            XCTAssertEqual(current.widgetDefaultStringValue, getter)
            XCTAssertEqual(PDFWidgetAppearancePreserver.boundedDefaultFingerprint(
                current.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV"))), before)
            XCTAssertEqual(original.widgetStringValue, "Ada")
            XCTAssertEqual(original.widgetDefaultStringValue, getter)
            XCTAssertEqual(PDFWidgetAppearancePreserver.boundedDefaultFingerprint(
                original.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV"))), before)
        }
    }

    func testInterleavedSimpleDefaultCopyKeepsObservableCurrentDefaultEdits() throws {
        for current: String? in ["Other default", "", nil] {
            let (source, page) = try interleavedCopySource(defaultToken: nil)
            let original = try XCTUnwrap(page.annotations.last)
            original.widgetDefaultStringValue = current
            let getter = original.widgetDefaultStringValue
            let before = try XCTUnwrap(PDFWidgetAppearancePreserver.boundedDefaultFingerprint(
                original.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV"))))
            let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
            XCTAssertTrue(try XCTUnwrap(page.lastCopy).invalidatedByValueRestore)
            let copied = try XCTUnwrap(extracted.page(at: 0)?.annotations.last)
            XCTAssertEqual(copied.widgetDefaultStringValue, getter)
            XCTAssertEqual(PDFWidgetAppearancePreserver.boundedDefaultFingerprint(
                copied.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV"))), before)
            XCTAssertEqual(original.widgetDefaultStringValue, getter)
        }
    }

    func testInterleavedComplexDefaultCopyWithoutNativeReferenceStillFailsClosed() throws {
        for token in ["/OriginalDefault", "[(Ada) (Grace)]"] {
            let (source, page) = try interleavedCopySource(defaultToken: token, choice: token.hasPrefix("["))
            let original = try XCTUnwrap(page.annotations.last)
            let getter = original.widgetDefaultStringValue
            let before = PDFWidgetAppearancePreserver.boundedDefaultFingerprint(
                original.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV")))
            XCTAssertThrowsError(try PDFPageOperations.extract(from: source, indexes: [0])) { error in
                XCTAssertEqual(error as? PDFPageStructurePreserver.Failure, .invalidCopy)
            }
            XCTAssertTrue(try XCTUnwrap(page.lastCopy).invalidatedByValueRestore)
            XCTAssertNil(page.lastCopy?.pageRef)
            XCTAssertEqual(PDFWidgetAppearancePreserver.boundedDefaultFingerprint(
                original.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/DV"))), before)
            XCTAssertEqual(original.widgetDefaultStringValue, getter)
        }
    }

    @MainActor
    func testValueOnlyEditKeepsOriginalDefaultAbsenceThroughWorkerSave() async throws {
        let bytes = fixture(omitDefault: true), source = try opened(bytes, prewarm: false)
        XCTAssertFalse(try hasRawDefault(bytes))
        try widget(source).widgetStringValue = "Grace"
        let sourceDefault = try widget(source).widgetDefaultStringValue
        let snapshot = try PDFRecoverySnapshot(capturing: source)
        let saved = try await Task.detached { try snapshot.serializedData() }.value
        XCTAssertFalse(try hasRawDefault(saved), "A V-only edit cannot manufacture a stored DV from the SDK fallback.")
        let reopened = try widget(XCTUnwrap(PDFDocument(data: saved)))
        XCTAssertEqual(reopened.widgetStringValue, "Grace")
        let independent = try widget(XCTUnwrap(PDFDocument(data: fixture(value: "Grace", omitDefault: true))))
        XCTAssertEqual(reopened.widgetDefaultStringValue, independent.widgetDefaultStringValue)
        XCTAssertEqual(try widget(source).widgetStringValue, "Grace")
        XCTAssertEqual(try widget(source).widgetDefaultStringValue, sourceDefault)
    }

    @MainActor
    func testExplicitEmptyCurrentDefaultAfterAbsentInputRemainsPresent() async throws {
        let source = try opened(fixture(omitDefault: true), prewarm: false)
        try widget(source).widgetDefaultStringValue = ""
        let snapshot = try PDFRecoverySnapshot(capturing: source)
        let saved = try await Task.detached { try snapshot.serializedData() }.value
        XCTAssertTrue(try hasRawDefault(saved))
        XCTAssertEqual(try rawDefaultString(saved), "")
    }

    @MainActor
    func testUnobservableSameAsCurrentValueDefaultSetterDoesNotInventIntent() async throws {
        let source = try opened(fixture(omitDefault: true), prewarm: false), field = try widget(source)
        let before = try XCTUnwrap(PDFWidgetAppearancePreserver.State(field))
        field.widgetDefaultStringValue = field.widgetStringValue
        XCTAssertEqual(PDFWidgetAppearancePreserver.State(field), before,
                       "The pinned SDK exposes no observable distinction from an unchanged fallback.")
        let snapshot = try PDFRecoverySnapshot(capturing: source)
        let saved = try await Task.detached { try snapshot.serializedData() }.value
        XCTAssertFalse(try hasRawDefault(saved), "Preserve proven original absence rather than infer an unobservable setter call.")
        XCTAssertEqual(try widget(XCTUnwrap(PDFDocument(data: saved))).widgetStringValue, "Ada")
    }

    func testAbsentDefaultWithUnavailableIndependentBaselineFailsClosed() throws {
        let source = try XCTUnwrap(PDFDocument(data: fixture(omitDefault: true)))
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        XCTAssertTrue(PDFCatalogStructurePreserver.needsMaterialization(source))
        XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: source),
                             "A public fallback is not enough proof to drop or introduce DV.")
    }

    func testExplicitNativeNullDefaultSurvivesDirectSaveAsNull() throws {
        let bytes = fixture(defaultToken: "null")
        XCTAssertEqual(try rawDefaultType(bytes), .null, "The immutable native fixture must expose an explicit null object.")
        let source = try opened(bytes)
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let saved = try save(source)
        XCTAssertEqual(try rawDefaultType(saved), .null)
        XCTAssertEqual(try widget(XCTUnwrap(PDFDocument(data: saved))).widgetStringValue, "Ada")
        XCTAssertEqual(try rawDefaultType(bytes), .null)
    }

    @MainActor
    func testExplicitNativeNullDefaultSurvivesMainCaptureWorkerSaveAsNull() async throws {
        let bytes = fixture(defaultToken: "null"), source = try opened(bytes, prewarm: false)
        XCTAssertEqual(try rawDefaultType(bytes), .null)
        let before = try XCTUnwrap(PDFWidgetAppearancePreserver.DefaultState(widget(source)))
        let snapshot = try PDFRecoverySnapshot(capturing: source)
        let saved = try await Task.detached { try snapshot.serializedData() }.value
        XCTAssertEqual(try rawDefaultType(saved), .null)
        XCTAssertEqual(before.matches(try widget(source)), true)
    }

    @MainActor
    func testObservableCurrentEditsAndClearOverrideOriginalExplicitNull() async throws {
        let changes: [String?] = ["Other default", "", nil]
        for current in changes {
            let bytes = fixture(defaultToken: "null"), source = try opened(bytes, prewarm: false)
            XCTAssertEqual(try rawDefaultType(bytes), .null)
            let field = try widget(source), baseline = try XCTUnwrap(PDFWidgetAppearancePreserver.DefaultState(field))
            field.widgetDefaultStringValue = current
            XCTAssertEqual(baseline.matches(field), false, "This regression requires a truly observable SDK edit or clear.")
            let snapshot = try PDFRecoverySnapshot(capturing: source)
            let saved = try await Task.detached { try snapshot.serializedData() }.value
            if let current {
                XCTAssertEqual(try rawDefaultType(saved), .string)
                XCTAssertEqual(try rawDefaultString(saved), current)
            } else { XCTAssertNil(try rawDefaultType(saved), "An observable clear removes the key rather than preserving old null.") }
            XCTAssertEqual(try rawDefaultType(bytes), .null)
        }
    }

    func testUnboundExplicitNullDefaultCannotClaimIndependentBaseline() throws {
        let bytes = fixture(defaultToken: "null")
        XCTAssertEqual(try rawDefaultType(bytes), .null)
        let source = try XCTUnwrap(PDFDocument(data: bytes))
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        XCTAssertThrowsError(try PDFCatalogStructurePreserver.plan(for: source))
    }

    func testDefaultScalarProofDoesNotDependOnFullAppearanceState() throws {
        let document = try opened(fixture(omitDefault: true)), field = try widget(document)
        let baseline = try XCTUnwrap(PDFWidgetAppearancePreserver.DefaultState(field))
        field.contents = String(repeating: "x", count: 65_537)
        XCTAssertNil(PDFWidgetAppearancePreserver.State(field), "Unsupported whole-appearance state must remain ineligible for AP restoration.")
        XCTAssertEqual(baseline.matches(field), true)
        field.widgetStringValue = "Grace"
        XCTAssertEqual(baseline.matches(field), true, "Current V alone is not a default edit.")
        field.widgetDefaultStringValue = "Other default"
        XCTAssertEqual(baseline.matches(field), false)
    }

    @MainActor
    func testDefaultBaselineMainMissRemainsRetryableAndSharesTheAppearanceCache() async throws {
        let source = try opened(fixture(omitDefault: true), prewarm: false)
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
        XCTAssertNil(try raw.originalWidgetDefaultStates(onPage: 0))
        XCTAssertEqual(raw.widgetStateCacheFootprint.pages, 0)
        let count = try await Task.detached { try raw.originalWidgetDefaultStates(onPage: 0)?.count }.value
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try raw.originalWidgetDefaultStates(onPage: 0)?.count, 1)
        XCTAssertEqual(try raw.originalWidgetStates(onPage: 0)?.count, 1)
        XCTAssertEqual(raw.widgetStateCacheFootprint.pages, 1, "Both independent scalar proofs share one bounded entry.")
        XCTAssertEqual(raw.widgetStateCacheFootprint.refusedPages, 0)
    }

    @MainActor
    func testOrphanWidgetDefaultProofIsLazyAndDoesNotAuthorizeOriginalAppearance() async throws {
        let bytes = fixture(omitDefault: true, omitForm: true), source = try opened(bytes, prewarm: false)
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
        XCTAssertNil(try raw.originalWidgetDefaultStates(onPage: 0), "A cold main lookup must not open a new reader.")
        XCTAssertEqual(raw.widgetStateCacheFootprint.pages, 0)
        let snapshot = try PDFRecoverySnapshot(capturing: source)
        let saved = try await Task.detached { try snapshot.serializedData() }.value
        XCTAssertEqual(try raw.originalWidgetDefaultStates(onPage: 0)?.count, 1)
        XCTAssertNil(try raw.originalWidgetFormDefaults(), "An orphan widget does not prove a complete original form.")
        XCTAssertEqual(try PDFCatalogStructurePreserver.plan(for: source).widgetAppearanceCount, 0)
        XCTAssertFalse(try hasRawDefault(saved))
        XCTAssertEqual(try widget(XCTUnwrap(PDFDocument(data: saved))).widgetStringValue, "Ada")
        try assertCanonicalFields(saved)
    }

    @MainActor
    func testOrphanWidgetWithOversizedRawDefaultCannotWarmEitherScalarProof() async throws {
        let bytes = fixture(defaultToken: "(" + String(repeating: "x", count: 65_537) + ")", omitForm: true)
        let native = try native(bytes)
        let raw = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: bytes))
        XCTAssertNil(try raw.originalWidgetDefaultStates(onPage: 0))
        XCTAssertEqual(raw.widgetStateCacheFootprint.refusedPages, 0, "Main misses cannot inspect raw collections.")
        let refused = try await Task.detached {
            (try raw.originalWidgetDefaultStates(onPage: 0) == nil,
             try raw.originalWidgetStates(onPage: 0) == nil,
             raw.widgetStateCacheFootprint)
        }.value
        XCTAssertTrue(refused.0); XCTAssertTrue(refused.1)
        XCTAssertEqual(refused.2.pages, 0)
        XCTAssertEqual(refused.2.encodedBytes, 0)
        XCTAssertEqual(refused.2.refusedPages, 1)
    }

    func testRawWidgetTraversalCapacityMissRemainsRetryableWithoutRetainingScalarState() async throws {
        let bytes = fixture(omitForm: true, extraWidgetCount: 349, rawStyleBytes: 35_000)
        let native = try native(bytes)
        let raw = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: bytes))
        let proof = try await Task.detached {
            for _ in 0..<2 { XCTAssertNil(try raw.originalWidgetDefaultStates(onPage: 0)) }
            return raw.widgetStateCacheFootprint
        }.value
        XCTAssertEqual(proof.pages, 0)
        XCTAssertEqual(proof.encodedBytes, 0, "The retained AP/default LRU limit is 8MiB; raw traversal capacity retains no state.")
        XCTAssertEqual(proof.refusedPages, 0, "Valid raw fields beyond the separate 64MiB traversal charge remain retryable.")
    }

    @MainActor
    func testRawWidgetDictionaryKeysAreBudgetedBeforeReaderWithSmallControl() async throws {
        for oversized in [false, true] {
            let key = oversized ? String(repeating: "x", count: 4_097) : "CA"
            let bytes = fixture(omitForm: true, rawWidgetEntries: "/MK << /\(key) (caption) >>")
            let native = try native(bytes), raw = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: bytes))
            XCTAssertNil(try raw.originalWidgetDefaultStates(onPage: 0))
            XCTAssertEqual(raw.widgetStateCacheFootprint.refusedPages, 0)
            let count = try await Task.detached { try raw.originalWidgetDefaultStates(onPage: 0)?.count }.value
            XCTAssertEqual(count, oversized ? nil : 1)
            XCTAssertEqual(raw.widgetStateCacheFootprint.refusedPages, oversized ? 1 : 0)
            XCTAssertEqual(raw.widgetStateCacheFootprint.pages, oversized ? 0 : 1)
        }
    }

    @MainActor
    func testSnapshotRefusesOversizedWidgetNameAndValueBeforeCopy() throws {
        for oversizedName in [false, true] {
            let source = snapshotForm(widgetCount: 1, value: oversizedName ? "Current" : String(repeating: "x", count: 65_537))
            let field = try widget(source)
            if oversizedName { field.fieldName = String(repeating: "n", count: 4_097) }
            let name = field.fieldName, value = field.widgetStringValue
            XCTAssertThrowsError(try PDFRecoverySnapshot(capturing: source)) { error in
                guard case PDFPageStructurePreserver.Failure.tooComplex = error else {
                    return XCTFail("Expected bounded scalar rejection, received \(error)")
                }
            }
            XCTAssertEqual(field.fieldName, name)
            XCTAssertEqual(field.widgetStringValue, value)
        }
    }

    @MainActor
    func testSnapshotRefusesAggregateWidgetScalarsBeforeCopy() throws {
        let source = snapshotForm(widgetCount: 513, value: String(repeating: "v", count: 16_384))
        XCTAssertThrowsError(try PDFRecoverySnapshot(capturing: source)) { error in
            guard case PDFPageStructurePreserver.Failure.tooComplex = error else {
                return XCTFail("Expected aggregate scalar rejection, received \(error)")
            }
        }
        XCTAssertEqual(try widget(source).widgetStringValue?.utf8.count, 16_384)
    }

    @MainActor
    func testSnapshotRefusesMoreThanTenThousandWidgetsBeforeCopy() throws {
        let source = snapshotForm(widgetCount: 10_001, value: "v")
        XCTAssertThrowsError(try PDFRecoverySnapshot(capturing: source)) { error in
            guard case PDFPageStructurePreserver.Failure.tooComplex = error else {
                return XCTFail("Expected widget count rejection, received \(error)")
            }
        }
        XCTAssertEqual(source.pageCount, 101)
        XCTAssertEqual(source.page(at: 100)?.annotations.count, 1)
    }

    @MainActor
    func testSnapshotWidgetCaptureHonorsExplicitCancellation() throws {
        let source = snapshotForm(widgetCount: 1, value: "Current")
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(cancellation) {
            try PDFRecoverySnapshot(capturing: source)
        }) { error in XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try widget(source).widgetStringValue, "Current")
    }

    func testRemovedCurrentDefaultIsNotReplacedByOriginalDV() throws {
        let controlData = fixture(omitDefault: true)
        XCTAssertFalse(try hasRawDefault(controlData), "Independent fixture must have no /DV entry.")
        let control = try XCTUnwrap(PDFDocument(data: controlData))
        let expectedGetter = try widget(control).widgetDefaultStringValue
        let source = try opened()
        try widget(source).widgetDefaultStringValue = nil
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        XCTAssertEqual(try PDFCatalogStructurePreserver.plan(for: source).widgetAppearanceCount, 0)
        let saved = try save(source)
        XCTAssertFalse(try hasRawDefault(saved), "A clear must remove /DV, not replace it with an empty PDF string.")
        XCTAssertEqual(try widget(XCTUnwrap(PDFDocument(data: saved))).widgetDefaultStringValue, expectedGetter)
    }

    func testPresentEmptyStringDefaultIsDistinctFromRemovedDefault() throws {
        let source = try opened()
        try widget(source).widgetDefaultStringValue = ""
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let saved = try save(source)
        XCTAssertTrue(try hasRawDefault(saved), "Explicit empty default remains a present PDF string.")
        XCTAssertEqual(try widget(XCTUnwrap(PDFDocument(data: saved))).widgetDefaultStringValue, "")
    }

    func testMovedWidgetCannotSelectOldDocumentsDefaultMaterialization() throws {
        let source = try opened()
        let page = try XCTUnwrap(source.page(at: 0)), field = try widget(source)
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        XCTAssertFalse(PDFCatalogStructurePreserver.needsMaterialization(source))
        field.widgetDefaultStringValue = "Other default"
        XCTAssertTrue(PDFCatalogStructurePreserver.needsMaterialization(source))
        page.removeAnnotation(field)
        let target = PDFDocument(), targetPage = PDFPage()
        target.insert(targetPage, at: 0); targetPage.addAnnotation(field)
        XCTAssertFalse(PDFCatalogStructurePreserver.needsMaterialization(source), "Stale weak candidate now belongs to another document.")
    }

    func testCompositeChoiceDefaultIsNotReplacedOrDroppedThroughStringGetter() throws {
        let source = try opened(fixture(fieldType: "Ch", defaultToken: "[(Ada) (Grace)]", flags: 1 << 21, properChoice: true))
        XCTAssertEqual(source.page(at: 0)?.annotations.count, 1)
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let plan = try PDFCatalogStructurePreserver.plan(for: source)
        XCTAssertNil(plan.annotationEntries[0]?[0]?["DV"])
        XCTAssertFalse(plan.annotationDrops[0]?[0]?.contains("DV") ?? false)
    }

    func testLateFirstPrepareFontAndColorChangesWin() throws {
        for color in [false, true] {
            let document = try opened()
            let field = try widget(document)
            if color { field.fontColor = .systemRed }
            else { field.font = NSFont(name: "Helvetica-Bold", size: 19) }
            try PDFCatalogStructurePreserver.prepare(document, force: true)
            XCTAssertEqual(try PDFCatalogStructurePreserver.plan(for: document).widgetAppearanceCount, 0)
            let result = try widget(XCTUnwrap(PDFDocument(data: save(document))))
            if color {
                XCTAssertEqual(try XCTUnwrap(result.fontColor?.usingColorSpace(.sRGB)).redComponent,
                               try XCTUnwrap(NSColor.systemRed.usingColorSpace(.sRGB)).redComponent, accuracy: 0.002)
            } else { XCTAssertEqual(result.font?.pointSize ?? 0, 19, accuracy: 0.001) }
        }
    }

    func testLateFirstPrepareBoundsAlignmentAndExplicitAppearanceChangesAreNeverRestored() throws {
        for change in 0..<3 {
            let document = try opened()
            let field = try widget(document)
            if change == 0 { field.bounds = field.bounds.offsetBy(dx: 7, dy: 9) }
            if change == 1 { field.alignment = .right }
            if change == 2 { field.setValue([String: Any](), forAnnotationKey: PDFAnnotationKey(rawValue: "/AP")) }
            try PDFCatalogStructurePreserver.prepare(document, force: true)
            XCTAssertEqual(try PDFCatalogStructurePreserver.plan(for: document).widgetAppearanceCount, 0)
        }
    }

    func testChangesAfterCaptureAlsoInvalidateOldAppearance() throws {
        for change in 0..<5 {
            let document = try opened()
            try PDFCatalogStructurePreserver.prepare(document, force: true)
            XCTAssertEqual(try PDFCatalogStructurePreserver.plan(for: document).widgetAppearanceCount, 1)
            let field = try widget(document)
            switch change {
            case 0: field.widgetStringValue = "Grace"
            case 1: field.font = NSFont(name: "Helvetica", size: 21)
            case 2: field.fontColor = .systemBlue
            case 3: field.bounds = field.bounds.offsetBy(dx: 3, dy: 0)
            default: field.setValue([String: Any](), forAnnotationKey: PDFAnnotationKey(rawValue: "/AP"))
            }
            let plan = try PDFCatalogStructurePreserver.plan(for: document)
            XCTAssertEqual(plan.widgetAppearanceCount, 0)
            XCTAssertNil(plan.widgetFormDefaults)
        }
    }

    func testUnboundReaderCannotClaimTrustedOriginalState() throws {
        let document = try XCTUnwrap(PDFDocument(data: fixture()))
        try PDFCatalogStructurePreserver.prepare(document, force: true)
        XCTAssertEqual(try PDFCatalogStructurePreserver.plan(for: document).widgetAppearanceCount, 0)
    }

    func testConsumedCreatedInputStillProvidesOriginalReaderWithoutRetainingSecondData() throws {
        let document = try opened(prewarm: false)
        let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
        try source.preparePaintingResources(for: [XCTUnwrap(document.page(at: 0)?.pageRef)])
        try warm(source)
        XCTAssertEqual(try source.originalWidgetStates(onPage: 0)?.count, 1)
        try widget(document).widgetStringValue = "Later"
        try PDFCatalogStructurePreserver.prepare(document, force: true)
        XCTAssertEqual(try PDFCatalogStructurePreserver.plan(for: document).widgetAppearanceCount, 0)
    }

    func testVersionChangedOpenedFileRefusesBaseline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-widget-version-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.pdf")
        try fixture().write(to: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        PDFRawStreamProvenance.bindOpened(document, url: url, version: try PDFSourceFileVersion.capture(at: url))
        try fixture(value: "Changed on disk").write(to: url, options: .atomic)
        try warm(XCTUnwrap(PDFRawStreamProvenance.source(for: document)))
        try PDFCatalogStructurePreserver.prepare(document, force: true)
        XCTAssertEqual(try PDFCatalogStructurePreserver.plan(for: document).widgetAppearanceCount, 0)
        XCTAssertEqual(try widget(document).widgetStringValue, "Ada")
    }

    func testDistinctFormSourcesCannotOverwriteGlobalDefaultResourceNames() throws {
        let first = try opened(fixture(name: "first"))
        let second = try opened(fixture(name: "second", baseFont: "Helvetica"))
        let target = PDFDocument()
        let imports = try [first, second].map { try PDFPageStructurePreserver.prepareImport(from: $0, indexes: [0]) }
        let merge = try PDFPageStructurePreserver.prepareMerge(imports: imports, into: target, at: 0)
        try merge.apply()
        let plan = try PDFCatalogStructurePreserver.plan(for: target)
        XCTAssertEqual(plan.widgetAppearanceCount, 0, "Unproven AP resource closure must not mix old appearances with current DR.")
        XCTAssertNil(plan.widgetFormDefaults, "Distinct same-name DR resources must not be chosen arbitrarily.")
    }

    func testAggregateChoicePayloadIsRefusedBeforeEncodingWholeCollection() throws {
        let document = try opened()
        let field = try widget(document)
        field.widgetFieldType = .choice
        field.choices = (0..<128).map { String($0) + String(repeating: "x", count: 4_096) }
        XCTAssertNil(PDFWidgetAppearancePreserver.State(field))
    }

    func testHiddenSignatureExtraDuplicateAndNullFieldsCannotBeRebuiltFromPageSubset() throws {
        for extra in ["8 0 R", "4 0 R", "null"] {
            let bytes = fixture(extraField: extra)
            let document = try opened(bytes)
            try PDFCatalogStructurePreserver.prepare(document, force: true)
            XCTAssertEqual(try PDFCatalogStructurePreserver.plan(for: document).widgetAppearanceCount, 0)
            XCTAssertThrowsError(try PDFWidgetAppearancePreserver.formEntries(staged: native(bytes),
                defaults: [:], widgets: [(page: 0, index: 0)]))
        }
    }

    func testExtractionSubsetKeepsDefaultsAfterProvingEntireOriginalForm() throws {
        let source = try opened(fixture(secondPage: true))
        XCTAssertEqual(source.pageCount, 2)
        let selected = try PDFPageOperations.extract(from: source, indexes: [0])
        let plan = try PDFCatalogStructurePreserver.plan(for: selected)
        XCTAssertEqual(plan.widgetAppearanceCount, 1)
        XCTAssertNotNil(plan.widgetFormDefaults)
        let output = try save(selected)
        try assertCanonicalFields(output)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(data: output)).pageCount, 1)
        XCTAssertEqual(source.pageCount, 2)
    }

    @MainActor
    func testUnchangedDirectWidgetValuesKeepPresenceKindsBytesAcrossAssemblyAndRepeatedWorkerSave() async throws {
        let cases: [(type: String, token: String?, omitted: Bool, kind: Int32?, bytes: Data?)] = [
            ("Tx", nil, true, nil, nil),
            ("Tx", "null", false, Int32(EMBER_RAW_PDF_NULL.rawValue), nil),
            ("Tx", "<FEFF004100640061>", false, Int32(EMBER_RAW_PDF_STRING.rawValue), Data([0xfe, 0xff, 0, 65, 0, 100, 0, 97])),
            ("Tx", "(Ada)", false, Int32(EMBER_RAW_PDF_STRING.rawValue), Data("Ada".utf8)),
            ("Btn", "/Off", false, Int32(EMBER_RAW_PDF_NAME.rawValue), Data("/Off".utf8)),
            ("Btn", nil, true, nil, nil)
        ]
        for item in cases {
            let bytes = fixture(fieldType: item.type, rawValueToken: item.token, omitValue: item.omitted)
            let original = try rawWidgetValue(bytes)
            XCTAssertEqual(original.present, !item.omitted, "C key enumeration distinguishes missing from explicit null.")
            XCTAssertEqual(original.kind, item.kind)
            XCTAssertEqual(original.bytes, item.bytes)
            if item.token == "null" {
                let owner = try native(bytes)
                let annots = try XCTUnwrap(PDFCatalogStructurePreserver.array(XCTUnwrap(owner.page(at: 1)?.dictionary), "Annots"))
                var field: CGPDFDictionaryRef?
                XCTAssertTrue(CGPDFArrayGetDictionary(annots, 0, &field))
                XCTAssertEqual(PDFCatalogStructurePreserver.object(try XCTUnwrap(field), "V").map(CGPDFObjectGetType), .null,
                               "The exact originalGraph API must expose null; treating it as absence cannot pass this fixture.")
                withExtendedLifetime(owner) {}
            }
            let source = try opened(bytes, prewarm: false), field = try widget(source)
            let sourceValue = field.widgetStringValue, sourceDefault = field.widgetDefaultStringValue
            let sourceState = field.buttonWidgetState, sourceStateString = field.buttonWidgetStateString
            let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
            let merged = PDFDocument()
            let imported = try PDFPageStructurePreserver.prepareImport(from: extracted, indexes: [0])
            let transaction = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: merged, at: 0)
            try transaction.apply(); try transaction.undo(); XCTAssertEqual(merged.pageCount, 0); try transaction.redo()
            for output in [extracted, merged] {
                let inspection = try PDFRecoverySnapshot(capturing: output)
                let snapshot = try PDFRecoverySnapshot(capturing: output)
                let count = try await Task.detached {
                    try PDFCatalogStructurePreserver.plan(for: inspection.takeDocument()).widgetAppearanceCount
                }.value
                XCTAssertEqual(count, 1, "Positive coverage must actually use proven AP/form restoration.")
                let first = try await Task.detached { try snapshot.serializedData() }.value
                XCTAssertEqual(try rawWidgetValue(first), original)
                if item.type == "Tx" { XCTAssertEqual(try appearance(first), try appearance(bytes)) }
                else {
                    XCTAssertEqual(try rawWidgetValue(first, key: "AS"), try rawWidgetValue(bytes, key: "AS"))
                    XCTAssertEqual(try pixels(first), try pixels(bytes))
                }
                let reopened = try opened(first, prewarm: false)
                let repeated = try PDFRecoverySnapshot(capturing: reopened)
                let second = try await Task.detached { try repeated.serializedData() }.value
                XCTAssertEqual(try rawWidgetValue(second), original)
                if item.type == "Tx" { XCTAssertEqual(try appearance(second), try appearance(bytes)) }
                else {
                    XCTAssertEqual(try rawWidgetValue(second, key: "AS"), try rawWidgetValue(bytes, key: "AS"))
                    XCTAssertEqual(try pixels(second), try pixels(bytes))
                }
                XCTAssertEqual(try widget(XCTUnwrap(PDFDocument(data: second))).widgetStringValue, sourceValue)
                try assertCanonicalFields(second)
            }
            XCTAssertEqual(field.widgetStringValue, sourceValue)
            XCTAssertEqual(field.widgetDefaultStringValue, sourceDefault)
            XCTAssertEqual(field.buttonWidgetState, sourceState)
            XCTAssertEqual(field.buttonWidgetStateString, sourceStateString)
        }
    }

    @MainActor
    func testCurrentWidgetValueEditAndExplicitEmptyWinOverOriginalRawValue() async throws {
        for current in ["Grace", ""] {
            let bytes = fixture(rawValueToken: "<FEFF004100640061>")
            let previous = try rawWidgetValue(bytes)
            XCTAssertEqual(previous.bytes, Data([0xfe, 0xff, 0, 65, 0, 100, 0, 97]))
            let source = try opened(bytes, prewarm: false), field = try widget(source)
            field.widgetStringValue = current
            let inspection = try PDFRecoverySnapshot(capturing: source)
            let snapshot = try PDFRecoverySnapshot(capturing: source)
            let count = try await Task.detached {
                try PDFCatalogStructurePreserver.plan(for: inspection.takeDocument()).widgetAppearanceCount
            }.value
            XCTAssertEqual(count, 0, "A current value edit invalidates the all-widget original AP/V path.")
            let saved = try await Task.detached { try snapshot.serializedData() }.value
            let result = try rawWidgetValue(saved)
            XCTAssertTrue(result.present)
            XCTAssertEqual(result.kind, Int32(EMBER_RAW_PDF_STRING.rawValue))
            XCTAssertNotEqual(result.bytes, previous.bytes)
            XCTAssertEqual(try widget(XCTUnwrap(PDFDocument(data: saved))).widgetStringValue, current)
            XCTAssertEqual(field.widgetStringValue, current)
        }
    }

    func testComplexRawWidgetValueNeverAcquiresScalarOriginalOverride() throws {
        let bytes = fixture(fieldType: "Ch", flags: 1 << 21, properChoice: true)
        XCTAssertEqual(try rawWidgetValue(bytes).kind, Int32(EMBER_RAW_PDF_ARRAY.rawValue))
        let source = try opened(bytes)
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let plan = try PDFCatalogStructurePreserver.plan(for: source)
        XCTAssertEqual(plan.widgetAppearanceCount, 1, "Complex-value guard must be exercised inside eligible AP branch")
        XCTAssertNil(plan.annotationEntries[0]?[0]?["V"])
        XCTAssertFalse(plan.annotationDrops[0]?[0]?.contains("V") ?? false,
                       "Unsupported complex V is never imported/dropped by the new scalar-only repair.")
    }

    @MainActor
    func testUnchangedWidgetNameKeepsRawEncodingThroughAssemblyAndRepeatedWorkerSave() async throws {
        let cases: [(token: String, bytes: Data, name: String)] = [
            ("(student)", Data("student".utf8), "student"),
            ("<636166E9>", Data([0x63, 0x61, 0x66, 0xe9]), "café"),
            ("<FEFF00630061006600E9>", Data([0xfe, 0xff, 0, 0x63, 0, 0x61, 0, 0x66, 0, 0xe9]), "café")
        ]
        for item in cases {
            let bytes = fixture(rawNameToken: item.token)
            let original = try rawWidgetValue(bytes, key: "T")
            XCTAssertTrue(original.present)
            XCTAssertEqual(original.kind, Int32(EMBER_RAW_PDF_STRING.rawValue))
            XCTAssertEqual(original.bytes, item.bytes)
            let source = try opened(bytes, prewarm: false)
            XCTAssertEqual(try widget(source).fieldName, item.name)
            let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
            let merged = PDFDocument()
            let imported = try PDFPageStructurePreserver.prepareImport(from: extracted, indexes: [0])
            let merge = try PDFPageStructurePreserver.prepareMerge(imports: [imported], into: merged, at: 0)
            try merge.apply(); try merge.undo(); XCTAssertEqual(merged.pageCount, 0); try merge.redo()
            for output in [extracted, merged] {
                let inspection = try PDFRecoverySnapshot(capturing: output)
                let snapshot = try PDFRecoverySnapshot(capturing: output)
                let eligible = try await Task.detached {
                    try PDFCatalogStructurePreserver.plan(for: inspection.takeDocument()).widgetAppearanceCount
                }.value
                XCTAssertEqual(eligible, 1, "Exercise proven original AP/name restoration, not a staged-only save.")
                let first = try await Task.detached { try snapshot.serializedData() }.value
                XCTAssertEqual(try rawWidgetValue(first, key: "T"), original)
                XCTAssertEqual(try appearance(first), try appearance(bytes))
                let reopened = try opened(first, prewarm: false)
                XCTAssertEqual(try widget(reopened).fieldName, item.name)
                let repeated = try PDFRecoverySnapshot(capturing: reopened)
                let second = try await Task.detached { try repeated.serializedData() }.value
                XCTAssertEqual(try rawWidgetValue(second, key: "T"), original)
                XCTAssertEqual(try widget(XCTUnwrap(PDFDocument(data: second))).fieldName, item.name)
                try assertCanonicalFields(second)
            }
            XCTAssertEqual(try widget(source).fieldName, item.name)
        }
    }

    @MainActor
    func testCurrentWidgetRenameCannotBeReplacedByOriginalName() async throws {
        for captureBeforeRename in [false, true] {
            let source = try opened(fixture(rawNameToken: "<636166E9>"))
            if captureBeforeRename { try PDFCatalogStructurePreserver.prepare(source, force: true) }
            let field = try widget(source)
            field.fieldName = "renamed-field"
            let inspection = try PDFRecoverySnapshot(capturing: source)
            let snapshot = try PDFRecoverySnapshot(capturing: source)
            let proof = try await Task.detached {
                let plan = try PDFCatalogStructurePreserver.plan(for: inspection.takeDocument())
                return (plan.widgetAppearanceCount, plan.annotationEntries[0]?[0]?["T"] != nil,
                        plan.annotationDrops[0]?[0]?.contains("T") ?? false)
            }.value
            XCTAssertEqual(proof.0, 0)
            XCTAssertFalse(proof.1)
            XCTAssertFalse(proof.2)
            let saved = try await Task.detached { try snapshot.serializedData() }.value
            XCTAssertEqual(try widget(XCTUnwrap(PDFDocument(data: saved))).fieldName, "renamed-field")
            XCTAssertEqual(field.fieldName, "renamed-field")
            XCTAssertNotEqual(try rawWidgetValue(saved, key: "T").bytes, Data([0x63, 0x61, 0x66, 0xe9]))
        }
    }

    private func opened(_ data: Data? = nil, prewarm: Bool = true) throws -> PDFDocument {
        let bytes = data ?? fixture()
        let document = try XCTUnwrap(PDFDocument(data: bytes))
        PDFRawStreamProvenance.bindCreated(document, data: bytes)
        if prewarm { try warm(XCTUnwrap(PDFRawStreamProvenance.source(for: document))) }
        return document
    }

    private final class WarmupResult: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?
        func record(_ error: Error) { lock.lock(); self.error = error; lock.unlock() }
        func check() throws { lock.lock(); defer { lock.unlock() }; if let error { throw error } }
    }

    /// Test fixture setup only: the shared owner exposes immutable CG input
    /// under its lock. No live PDFPage/annotation/font is sent to this worker.
    private func warm(_ source: PDFRawStreamSource) throws {
        let completion = DispatchSemaphore(value: 0), result = WarmupResult()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { completion.signal() }
            do {
                _ = try source.originalWidgetStates(onPage: 0)
                _ = try source.originalWidgetFormDefaults()
            }
            catch { result.record(error) }
        }
        XCTAssertEqual(completion.wait(timeout: .now() + 10), .success)
        try result.check()
    }

    private func widget(_ document: PDFDocument) throws -> PDFAnnotation {
        try XCTUnwrap(document.page(at: 0)?.annotations.first)
    }

    /// Models the already-observed PDFKit copy boundary deterministically:
    /// restoring an earlier button clears only the copied page reference. The
    /// real importer must then restore the later widget without warming it.
    private final class InterleavedCopyPage: PDFPage {
        private let owner: CGPDFDocument
        private(set) var invalidatedByValueRestore = false
        private(set) var lastCopy: InterleavedCopyPage?

        init(owner: CGPDFDocument, annotations: [PDFAnnotation]) {
            self.owner = owner
            super.init()
            setBounds(CGRect(x: 0, y: 0, width: 220, height: 220), for: .mediaBox)
            for annotation in annotations { addAnnotation(annotation) }
        }

        override var pageRef: CGPDFPage? { invalidatedByValueRestore ? nil : owner.page(at: 1) }

        override func copy(with zone: NSZone? = nil) -> Any {
            let copied = InterleavedCopyPage(owner: owner, annotations: [])
            for (index, annotation) in annotations.enumerated() {
                if index == 0 {
                    let button = ReferenceInvalidatingWidget(bounds: annotation.bounds, forType: .widget, withProperties: nil)
                    button.widgetFieldType = annotation.widgetFieldType
                    button.fieldName = annotation.fieldName
                    button.widgetControlType = annotation.widgetControlType
                    button.buttonWidgetStateString = annotation.buttonWidgetStateString
                    button.buttonWidgetState = annotation.buttonWidgetState
                    copied.addAnnotation(button)
                    button.widgetStringValue = ""
                    XCTAssertEqual(button.widgetStringValue, "", "The copied widget must start with the observed missing current value.")
                    button.onValueRestore = { [weak copied] in copied?.invalidatedByValueRestore = true }
                } else if let detached = annotation.copy() as? PDFAnnotation {
                    copied.addAnnotation(detached)
                }
            }
            lastCopy = copied
            return copied
        }
    }

    private final class ReferenceInvalidatingWidget: PDFAnnotation {
        var onValueRestore: (() -> Void)?
        override var widgetStringValue: String? {
            get { super.widgetStringValue }
            set { super.widgetStringValue = newValue; onValueRestore?() }
        }
    }

    private func interleavedCopySource(defaultToken: String?, choice: Bool = false) throws -> (PDFDocument, InterleavedCopyPage) {
        let storedDefault = defaultToken.map { "/DV " + $0 } ?? ""
        let second = choice
            ? "/FT /Ch /V [(Ada)] /Opt [(Ada) (Grace)] /I [0] /Ff 2097152"
            : "/FT /Tx /V (Ada) /Ff 0"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 7 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << >> /Annots [4 0 R 5 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /T (first-button) /V /Off /AS /Off /Ff 0 /Rect [10 10 30 30] /F 4 >>",
            "<< /Type /Annot /Subtype /Widget \(second) /T (later-default) \(storedDefault) /Rect [30 100 180 125] /F 4 /DA (/SourceFont 13 Tf 0 g) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>",
            "<< /Fields [4 0 R 5 0 R] /DA (/SourceFont 13 Tf 0 g) /DR << /Font << /SourceFont 6 0 R >> >> >>"
        ]
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let reader = try XCTUnwrap(PDFDocument(data: bytes)), native = try native(bytes)
        let raw = try XCTUnwrap(native.page(at: 1)?.dictionary)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(raw, "Annots"))
        var later: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 1, &later))
        let rawDefault = PDFCatalogStructurePreserver.object(try XCTUnwrap(later), "DV")
        let expected: CGPDFObjectType? = defaultToken == nil ? nil : choice ? .array : defaultToken == "null" ? .null : .name
        XCTAssertEqual(rawDefault.map(CGPDFObjectGetType), expected, "The immutable fixture is the native default-type oracle.")
        let originalAnnotations = try XCTUnwrap(reader.page(at: 0)).annotations
        XCTAssertEqual(originalAnnotations.count, 2)
        let annotations = try originalAnnotations.map { try XCTUnwrap($0.copy() as? PDFAnnotation) }
        for (original, copy) in zip(originalAnnotations, annotations) where original.widgetStringValue != copy.widgetStringValue {
            copy.widgetStringValue = original.widgetStringValue
            if original.widgetFieldType == .button {
                copy.buttonWidgetStateString = original.buttonWidgetStateString
                copy.buttonWidgetState = original.buttonWidgetState
            }
        }
        let page = InterleavedCopyPage(owner: native, annotations: annotations)
        let document = PDFDocument(); document.insert(page, at: 0)
        XCTAssertEqual(page.annotations.first?.widgetStringValue, "Off", "The earlier widget must actually require value restoration.")
        return (document, page)
    }

    private func snapshotForm(widgetCount: Int, value: String) -> PDFDocument {
        let document = PDFDocument()
        for index in 0..<widgetCount {
            if index % 100 == 0 { document.insert(PDFPage(), at: document.pageCount) }
            let field = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 100, height: 20), forType: .widget, withProperties: nil)
            field.widgetFieldType = .text; field.fieldName = "field-\(index)"; field.widgetStringValue = value
            document.page(at: document.pageCount - 1)?.addAnnotation(field)
        }
        return document
    }

    private func save(_ document: PDFDocument) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-widget-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try AtomicPDFWriter.write(document, to: url)
        return try Data(contentsOf: url)
    }

    private func native(_ data: Data) throws -> CGPDFDocument {
        try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data: data as CFData))))
    }

    private func formDictionary(_ data: Data) throws -> (document: CGPDFDocument, dictionary: CGPDFDictionaryRef) {
        let document = try native(data)
        return (document, try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(XCTUnwrap(document.catalog), "AcroForm")))
    }

    private func appearance(_ data: Data) throws -> Data {
        let document = try native(data)
        let page = try XCTUnwrap(document.page(at: 1)?.dictionary)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
        var annotation: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &annotation))
        let ap = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(XCTUnwrap(annotation), "AP"))
        XCTAssertTrue(CGPDFDictionaryGetStream(ap, "N", &stream))
        var format = CGPDFDataFormat.raw
        return try XCTUnwrap(CGPDFStreamCopyData(XCTUnwrap(stream), &format)) as Data
    }

    private func hasRawDefault(_ data: Data) throws -> Bool {
        try rawDefaultType(data) != nil
    }

    private func rawDefaultType(_ data: Data) throws -> CGPDFObjectType? {
        let document = try native(data)
        let page = try XCTUnwrap(document.page(at: 1)?.dictionary)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(page, "Annots"))
        var annotation: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &annotation))
        let kind = PDFCatalogStructurePreserver.object(try XCTUnwrap(annotation), "DV").map(CGPDFObjectGetType)
        withExtendedLifetime(document) {}
        return kind
    }

    private func rawDefaultString(_ data: Data) throws -> String {
        let document = try native(data)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(XCTUnwrap(document.page(at: 1)?.dictionary), "Annots"))
        var field: CGPDFDictionaryRef?, value: CGPDFStringRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &field))
        XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(field), "DV", &value), "Expected a present PDF string default.")
        let string = try XCTUnwrap(CGPDFStringCopyTextString(try XCTUnwrap(value))) as String
        withExtendedLifetime(document) {}
        return string
    }

    private func nativeChoiceDefault(_ page: PDFPage) throws -> [String] {
        let dictionary = try XCTUnwrap(page.pageRef?.dictionary)
        let annotations = try XCTUnwrap(PDFCatalogStructurePreserver.array(dictionary, "Annots"))
        var field: CGPDFDictionaryRef?, values: CGPDFArrayRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(annotations, 0, &field))
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(field), "DV", &values), "A native choice default must remain an array.")
        let array = try XCTUnwrap(values)
        return try (0..<CGPDFArrayGetCount(array)).map { index in
            var string: CGPDFStringRef?
            XCTAssertTrue(CGPDFArrayGetString(array, index, &string))
            return try XCTUnwrap(CGPDFStringCopyTextString(XCTUnwrap(string))) as String
        }
    }

    private func rawButtonNames(_ data: Data) throws -> (value: String, appearance: String) {
        let document = try native(data)
        let list = try XCTUnwrap(PDFCatalogStructurePreserver.array(XCTUnwrap(document.page(at: 1)?.dictionary), "Annots"))
        var annotation: CGPDFDictionaryRef?, value: UnsafePointer<CChar>?, appearance: UnsafePointer<CChar>?
        XCTAssertTrue(CGPDFArrayGetDictionary(list, 0, &annotation))
        let field = try XCTUnwrap(annotation)
        XCTAssertTrue(CGPDFDictionaryGetName(field, "V", &value), "Button V must remain a PDF name.")
        XCTAssertTrue(CGPDFDictionaryGetName(field, "AS", &appearance), "Button AS must remain a PDF name.")
        let names = (String(cString: try XCTUnwrap(value)), String(cString: try XCTUnwrap(appearance)))
        withExtendedLifetime(document) {}
        return names
    }

    private func assertCanonicalFields(_ data: Data) throws {
        let document = try native(data)
        let form = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(XCTUnwrap(document.catalog), "AcroForm"))
        let fields = try XCTUnwrap(PDFCatalogStructurePreserver.array(form, "Fields"))
        let annotations = try XCTUnwrap(PDFCatalogStructurePreserver.array(XCTUnwrap(document.page(at: 1)?.dictionary), "Annots"))
        var field: CGPDFDictionaryRef?, annotation: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(fields, 0, &field))
        XCTAssertTrue(CGPDFArrayGetDictionary(annotations, 0, &annotation))
        XCTAssertEqual(field, annotation)
    }

    private struct RawWidgetValue: Equatable {
        let present: Bool
        let kind: Int32?
        let bytes: Data?
    }

    /// Independent C/QPDF dictionary enumeration: explicit null is present,
    /// while dictionary_get alone deliberately cannot distinguish absence.
    private func rawWidgetValue(_ data: Data, key: String = "V") throws -> RawWidgetValue {
        var status: Int32 = 0
        let owner = try XCTUnwrap(data.withUnsafeBytes {
            ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, data.count, data.count, 50_000, &status)
        })
        defer { ember_raw_pdf_destroy(owner) }
        func checked(_ status: Int32) throws {
            guard status == Int32(EMBER_RAW_PDF_OK.rawValue) else {
                throw NSError(domain: "EmberPDFRawWidgetValueTest", code: Int(status))
            }
        }
        try checked(status)
        func get(_ parent: EmberRawPDFObject, _ fieldKey: String) throws -> EmberRawPDFObject {
            var value: EmberRawPDFObject = 0
            let key = Data(("/" + fieldKey).utf8)
            try checked(key.withUnsafeBytes {
                ember_raw_pdf_dictionary_get(owner, parent, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &value)
            })
            return value
        }
        var page: EmberRawPDFObject = 0, annotation: EmberRawPDFObject = 0
        try checked(ember_raw_pdf_page(owner, 0, &page))
        try checked(ember_raw_pdf_array_item(owner, get(page, "Annots"), 0, &annotation))
        var catalog: EmberRawPDFObject = 0, canonicalField: EmberRawPDFObject = 0
        try checked(ember_raw_pdf_catalog(owner, &catalog))
        try checked(ember_raw_pdf_array_item(owner, get(get(catalog, "AcroForm"), "Fields"), 0, &canonicalField))
        XCTAssertEqual(canonicalField, annotation, "Raw Fields must reference the actual output widget.")
        var keyCount: UInt32 = 0
        try checked(ember_raw_pdf_dictionary_count(owner, annotation, &keyCount))
        guard keyCount <= 512 else { throw NSError(domain: "EmberPDFRawWidgetValueTest", code: -1) }
        var present = false
        for index in 0..<keyCount {
            var pointer: UnsafeMutablePointer<UInt8>?, count = 0
            let status = ember_raw_pdf_dictionary_key_copy(owner, annotation, index, &pointer, &count)
            defer { if let pointer { ember_raw_pdf_free(pointer) } }
            try checked(status)
            guard count <= 4_096, count == 0 || pointer != nil else {
                throw NSError(domain: "EmberPDFRawWidgetValueTest", code: -2)
            }
            if pointer.map({ Data(bytes: $0, count: count) }) == Data(("/" + key).utf8) { present = true }
        }
        guard present else { return RawWidgetValue(present: false, kind: nil, bytes: nil) }
        let value = try get(annotation, key)
        var kind: Int32 = 0
        try checked(ember_raw_pdf_kind(owner, value, &kind))
        if kind == Int32(EMBER_RAW_PDF_STRING.rawValue) || kind == Int32(EMBER_RAW_PDF_NAME.rawValue) {
            var pointer: UnsafeMutablePointer<UInt8>?, count = 0
            let status = kind == Int32(EMBER_RAW_PDF_STRING.rawValue)
                ? ember_raw_pdf_string_copy(owner, value, &pointer, &count)
                : ember_raw_pdf_name_copy(owner, value, &pointer, &count)
            defer { if let pointer { ember_raw_pdf_free(pointer) } }
            try checked(status)
            guard count <= 131_072, count == 0 || pointer != nil else {
                throw NSError(domain: "EmberPDFRawWidgetValueTest", code: -3)
            }
            return RawWidgetValue(present: true, kind: kind,
                                  bytes: pointer.map { Data(bytes: $0, count: count) } ?? Data())
        }
        return RawWidgetValue(present: true, kind: kind, bytes: nil)
    }

    private func pixels(_ data: Data) throws -> Data {
        let document = try native(data), size = 220
        var bytes = Data(count: size * size * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.drawPDFPage(try XCTUnwrap(document.page(at: 1)))
        }
        return bytes
    }

    private func fixture(name: String = "student", value: String = "Ada", baseFont: String = "Courier", extraField: String = "", secondPage: Bool = false,
                         fieldType: String = "Tx", defaultToken: String = "(Default)", flags: Int = 0, omitDefault: Bool = false,
                         properChoice: Bool = false, omitForm: Bool = false,
                         extraWidgetCount: Int = 0, rawStyleBytes: Int = 0, rawWidgetEntries: String = "",
                         rawValueToken: String? = nil, omitValue: Bool = false,
                         rawNameToken: String? = nil) -> Data {
        let appearance = "q 0.85 g 0 0 150 25 re f 0 g BT /SourceFont 13 Tf 4 7 Td (CUSTOM AP) Tj ET Q\n"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm 7 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << >> /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Widget /FT /\(fieldType) /T (\(name)) /V (\(value)) /DV \(defaultToken) /Ff \(flags) /Rect [30 100 180 125] /F 4 /DA (/SourceFont 13 Tf 0 g) /Q 1 /AP << /N 6 0 R >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /\(baseFont) /Encoding /WinAnsiEncoding >>",
            "<< /Type /XObject /Subtype /Form /BBox [0 0 150 25] /Resources << /Font << /SourceFont 5 0 R >> >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)endstream",
            "<< /Fields [4 0 R \(extraField)] /DA (/SourceFont 13 Tf 0 g) /DR << /Font << /SourceFont 5 0 R >> >> /Q 1 >>",
            "<< /FT /Sig /T (hidden signature field) >>"
        ]
        if omitForm { objects[0] = "<< /Type /Catalog /Pages 2 0 R >>" }
        if !rawWidgetEntries.isEmpty { objects[3] = String(objects[3].dropLast(2)) + " " + rawWidgetEntries + " >>" }
        if rawStyleBytes > 0 {
            objects[3] = objects[3].replacingOccurrences(of: "/F 4 /DA", with: "/DS (" + String(repeating: "x", count: rawStyleBytes) + ") /F 4 /DA")
        }
        if extraWidgetCount > 0 {
            let indexes = (0..<extraWidgetCount).map { "\(objects.count + $0 + 1) 0 R" }.joined(separator: " ")
            objects[2] = objects[2].replacingOccurrences(of: "/Annots [4 0 R]", with: "/Annots [4 0 R \(indexes)]")
            let template = objects[3]
            for index in 0..<extraWidgetCount {
                objects.append(template.replacingOccurrences(of: "/T (\(name))", with: "/T (\(name)-\(index))"))
            }
        }
        if omitDefault { objects[3] = objects[3].replacingOccurrences(of: " /DV \(defaultToken)", with: "") }
        if properChoice {
            objects[3] = objects[3].replacingOccurrences(of: "/V (\(value))",
                with: "/V [(Ada)] /Opt [(Ada) (Grace) (Linus)] /I [0]")
        }
        if fieldType == "Btn" {
            objects[3] = "<< /Type /Annot /Subtype /Widget /FT /Btn /T (\(name)) /V /Off /AS /Off /Ff 0 /Rect [30 100 180 125] /F 4 /AP << /N << /Off 6 0 R /On 6 0 R >> >> >>"
        }
        if let rawNameToken {
            let previous = "/T (\(name))"
            precondition(objects[3].components(separatedBy: previous).count == 2)
            objects[3] = objects[3].replacingOccurrences(of: previous, with: "/T " + rawNameToken)
        }
        if omitValue || rawValueToken != nil {
            let previous = fieldType == "Btn" ? " /V /Off" : " /V (\(value))"
            let replacement = omitValue ? "" : " /V " + rawValueToken!
            precondition(objects[3].components(separatedBy: previous).count == 2)
            objects[3] = objects[3].replacingOccurrences(of: previous, with: replacement)
        }
        if secondPage {
            objects[1] = "<< /Type /Pages /Kids [3 0 R 9 0 R] /Count 2 >>"
            objects[6] = "<< /Fields [4 0 R 10 0 R] /DA (/SourceFont 13 Tf 0 g) /DR << /Font << /SourceFont 5 0 R >> >> /Q 1 >>"
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << >> /Annots [10 0 R] >>")
            objects.append("<< /Type /Annot /Subtype /Widget /FT /Tx /T (teacher) /V (Grace) /Rect [30 100 180 125] /F 4 /AP << /N 6 0 R >> >>")
        }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let start = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n".utf8))
        return data
    }
}
