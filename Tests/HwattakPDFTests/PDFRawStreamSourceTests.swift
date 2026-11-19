// SPDX-License-Identifier: MPL-2.0

import CEmberPDFRawStreams
import CoreGraphics
import CryptoKit
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFRawStreamSourceTests: XCTestCase {
    #if DEBUG
    func testPayloadCacheUsesByteBoundedLRUAndEvictedStreamsRereadExactly() throws {
        let bytes = fixture(), native = try document(bytes)
        let source = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: bytes))
        XCTAssertTrue(source.setPayloadCacheByteLimitForTesting(20))
        let page = try XCTUnwrap(native.page(at: 1))
        try source.preparePaintingResources(for: [page])
        let image = try imageStream(native), form = try formStream(native)
        let metadata = try stream(XCTUnwrap(page.dictionary), "Metadata")
        let retainedByCaller = try XCTUnwrap(source.payload(for: image)) //9 bytes
        XCTAssertEqual(try source.payload(for: form), Data("q /Im1 Do Q".utf8)) //11 bytes
        let full = source.payloadCacheFootprint
        XCTAssertEqual(full.entries, 2); XCTAssertEqual(full.retainedBytes, 20)
        XCTAssertEqual(full.copies, 2); XCTAssertTrue(full.contextLoaded)
        XCTAssertEqual(try source.payload(for: image), retainedByCaller) //touch: form is now LRU
        XCTAssertEqual(try source.payload(for: metadata), Data("<metadata/>".utf8))
        let evicted = source.payloadCacheFootprint
        XCTAssertEqual(evicted.entries, 2); XCTAssertEqual(evicted.retainedBytes, 20)
        XCTAssertEqual(evicted.evictions, 1); XCTAssertEqual(evicted.copies, 3)
        XCTAssertEqual(evicted.pairedStreams, full.pairedStreams)
        XCTAssertEqual(evicted.refusedKeys, 0)
        XCTAssertEqual(try source.payload(for: image), retainedByCaller) //still cached
        XCTAssertEqual(source.payloadCacheFootprint.copies, 3)
        XCTAssertEqual(try source.payload(for: form), Data("q /Im1 Do Q".utf8)) //re-copy evicted stream
        XCTAssertEqual(source.payloadCacheFootprint.copies, 4)
        XCTAssertEqual(source.payloadCacheFootprint.retainedBytes, 20)
        XCTAssertEqual(retainedByCaller, Data("00204080>".utf8), "Eviction cannot invalidate a caller's Data.")
        // A native alias has the same stream identity, not a second cache entry.
        let resources = try XCTUnwrap(CGPDFStreamGetDictionary(form))
        var formResources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?, alias: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(resources, "Resources", &formResources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(formResources), "XObject", &xobjects))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(xobjects), "Im2", &alias))
        let beforeAlias = source.payloadCacheFootprint
        XCTAssertEqual(try source.payload(for: XCTUnwrap(alias)), retainedByCaller)
        XCTAssertEqual(source.payloadCacheFootprint.entries, beforeAlias.entries)
        XCTAssertEqual(source.payloadCacheFootprint.retainedBytes, beforeAlias.retainedBytes)
        XCTAssertEqual(source.payloadCacheFootprint.copies, beforeAlias.copies)
    }

    func testPayloadCacheInsertionCanEvictMultipleEntriesWithoutLosingCallerBytes() throws {
        let bytes = fixture(), native = try document(bytes)
        let source = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: bytes))
        XCTAssertTrue(source.setPayloadCacheByteLimitForTesting(20))
        let page = try XCTUnwrap(native.page(at: 1))
        try source.preparePaintingResources(for: [page])
        let image = try imageStream(native), form = try formStream(native)
        let metadata = try stream(XCTUnwrap(page.dictionary), "Metadata")
        let retainedImage = try XCTUnwrap(source.payload(for: image)) //9 bytes, oldest
        let retainedForm = try XCTUnwrap(source.payload(for: form)) //11 bytes, newest
        let before = source.payloadCacheFootprint
        XCTAssertEqual(before.entries, 2); XCTAssertEqual(before.retainedBytes, 20)
        XCTAssertEqual(before.copies, 2); XCTAssertEqual(before.evictions, 0)
        // Removing only the 9-byte oldest entry still leaves 11+11 > 20.
        XCTAssertEqual(try source.payload(for: metadata), Data("<metadata/>".utf8))
        let after = source.payloadCacheFootprint
        XCTAssertEqual(after.entries, 1); XCTAssertEqual(after.retainedBytes, 11)
        XCTAssertEqual(after.evictions, before.evictions + 2)
        XCTAssertEqual(after.copies, before.copies + 1)
        XCTAssertEqual(after.pairedStreams, before.pairedStreams)
        XCTAssertEqual(after.refusedKeys, before.refusedKeys)
        XCTAssertTrue(after.contextLoaded)
        XCTAssertEqual(try source.payload(for: image), retainedImage)
        XCTAssertEqual(source.payloadCacheFootprint.copies, after.copies + 1)
        XCTAssertEqual(source.payloadCacheFootprint.entries, 2)
        XCTAssertEqual(source.payloadCacheFootprint.retainedBytes, 20)
        XCTAssertEqual(retainedImage, Data("00204080>".utf8))
        XCTAssertEqual(retainedForm, Data("q /Im1 Do Q".utf8))
    }

    func testPayloadLargerThanCacheBudgetReturnsExactlyWithoutNegativeCaching() throws {
        let bytes = fixture(), native = try document(bytes)
        let source = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: bytes))
        XCTAssertTrue(source.setPayloadCacheByteLimitForTesting(8))
        try source.preparePaintingResources(for: [XCTUnwrap(native.page(at: 1))])
        let image = try imageStream(native)
        let first = try XCTUnwrap(source.payload(for: image))
        XCTAssertEqual(first, Data("00204080>".utf8))
        XCTAssertEqual(try source.payload(for: image), first)
        let footprint = source.payloadCacheFootprint
        XCTAssertEqual(footprint.entries, 0); XCTAssertEqual(footprint.retainedBytes, 0)
        XCTAssertEqual(footprint.copies, 2); XCTAssertEqual(footprint.refusedKeys, 0)
        XCTAssertTrue(footprint.contextLoaded)
        var format = CGPDFDataFormat.raw
        XCTAssertEqual(CGPDFStreamCopyData(image, &format) as Data?, Data([0, 32, 64, 128]))
        let foreign = try document(bytes)
        XCTAssertNil(try source.payload(for: imageStream(foreign)), "Cache capacity cannot grant another native owner.")
    }

    func testPayloadCacheClearBudgetChangesAndCancellationKeepAuthorityAndAccounting() throws {
        let bytes = fixture(), native = try document(bytes)
        let source = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: bytes))
        XCTAssertTrue(source.setPayloadCacheByteLimitForTesting(20))
        try source.preparePaintingResources(for: [XCTUnwrap(native.page(at: 1))])
        let image = try imageStream(native)
        let first = try XCTUnwrap(source.payload(for: image))
        _ = try XCTUnwrap(source.payload(for: formStream(native)))
        let before = source.payloadCacheFootprint
        XCTAssertFalse(source.setPayloadCacheByteLimitForTesting(-1))
        XCTAssertFalse(source.setPayloadCacheByteLimitForTesting(32 * 1_024 * 1_024 + 1))
        XCTAssertEqual(source.payloadCacheFootprint, before)
        let cancelled = PDFSaveCancellation(); cancelled.cancel()
        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(cancelled) { try source.payload(for: image) }) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(source.payloadCacheFootprint, before, "Cancelled hits cannot change recency/cost or publish a negative.")
        source.releaseCachedPayloads()
        let cleared = source.payloadCacheFootprint
        XCTAssertEqual(cleared.entries, 0); XCTAssertEqual(cleared.retainedBytes, 0)
        XCTAssertEqual(cleared.pairedStreams, before.pairedStreams); XCTAssertTrue(cleared.contextLoaded)
        XCTAssertEqual(try source.payload(for: image), first)
        XCTAssertEqual(source.payloadCacheFootprint.retainedBytes, first.count)
        XCTAssertTrue(source.setPayloadCacheByteLimitForTesting(0))
        XCTAssertEqual(source.payloadCacheFootprint.retainedBytes, 0)
        XCTAssertEqual(try source.payload(for: image), first)
        XCTAssertEqual(source.payloadCacheFootprint.entries, 0)
        XCTAssertEqual(source.payloadCacheFootprint.refusedKeys, 0)
    }
    #endif

    @MainActor
    func testNormalDocumentLoaderBindsTheOpenedFileToItsRawStreamSource() throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let bytes = fixture(); try bytes.write(to: url)
        let loaded = try PDFSourceFileAccess.loadDocument(at: url)
        XCTAssertEqual(loaded.version, try PDFSourceFileVersion.capture(at: url))
        XCTAssertEqual(loaded.document.documentURL, url)
        XCTAssertTrue(PDFRawStreamProvenance.hasKnownNativeInput(loaded.document))
        let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: loaded.document))
        let native = try XCTUnwrap(loaded.document.documentRef)
        try source.preparePaintingResources(for: [XCTUnwrap(native.page(at: 1))])
        XCTAssertEqual(try source.payload(for: imageStream(native)), Data("00204080>".utf8))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testKnownNativeInputRequiresExactFactoryBindingAndDoesNotTransferToCopies() throws {
        let bytes = fixture(), source = try XCTUnwrap(PDFDocument(data: bytes))
        let identicalUnbound = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertFalse(PDFRawStreamProvenance.hasKnownNativeInput(source))
        XCTAssertFalse(PDFRawStreamProvenance.hasKnownNativeInput(identicalUnbound))
        PDFRawStreamProvenance.bindCreated(source, data: bytes)
        XCTAssertTrue(PDFRawStreamProvenance.hasKnownNativeInput(source))
        XCTAssertNotNil(PDFRawStreamProvenance.source(for: source))
        XCTAssertFalse(PDFRawStreamProvenance.hasKnownNativeInput(identicalUnbound),
                       "Identical bytes and dictionaries cannot confer another document's factory witness.")
        let copied = try XCTUnwrap(source.copy() as? PDFDocument)
        XCTAssertFalse(PDFRawStreamProvenance.hasKnownNativeInput(copied))
        XCTAssertNil(PDFRawStreamProvenance.source(for: copied))
        XCTAssertTrue(PDFRawStreamProvenance.hasKnownNativeInput(source))
    }

    func testKnownNativeInputRejectsAChangedNativeOwnerEvenWithIdenticalBytes() throws {
        let bytes = fixture(), source = try XCTUnwrap(NativeIdentityDocument(data: bytes))
        let original = try XCTUnwrap(source.documentRef)
        PDFRawStreamProvenance.bindCreated(source, data: bytes)
        XCTAssertTrue(PDFRawStreamProvenance.hasKnownNativeInput(source))
        let replacement = try document(bytes)
        XCTAssertFalse(original === replacement)
        source.replacementNative = replacement
        XCTAssertFalse(PDFRawStreamProvenance.hasKnownNativeInput(source))
        source.replacementNative = original
        XCTAssertTrue(PDFRawStreamProvenance.hasKnownNativeInput(source))
    }

    func testKnownOpenedNativeInputRejectsWrongCanonicalURLAndEmptyVersionBeforeMarking() throws {
        let url = temporaryURL(), otherURL = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: otherURL) }
        try fixture().write(to: url)
        try fixture(width: 9).write(to: otherURL)
        let version = try PDFSourceFileVersion.capture(at: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        PDFRawStreamProvenance.bindOpened(document, url: otherURL, version: version)
        XCTAssertFalse(PDFRawStreamProvenance.hasKnownNativeInput(document))
        XCTAssertNil(PDFRawStreamProvenance.source(for: document))
        let emptyVersion = PDFSourceFileVersion(canonicalURL: version.canonicalURL, fileSize: 0,
            contentModificationDate: version.contentModificationDate,
            fileSystemNumber: version.fileSystemNumber, fileSystemNodeNumber: version.fileSystemNodeNumber)
        PDFRawStreamProvenance.bindOpened(document, url: url, version: emptyVersion)
        XCTAssertFalse(PDFRawStreamProvenance.hasKnownNativeInput(document))
        PDFRawStreamProvenance.bindOpened(document, url: url, version: version)
        XCTAssertTrue(PDFRawStreamProvenance.hasKnownNativeInput(document))
        XCTAssertNotNil(PDFRawStreamProvenance.source(for: document))
    }

    @MainActor
    func testProductionLoaderKeepsLightNativeWitnessForValidSparsePDFBeyondRawByteCap() throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        try writeLargeSparseFixture(to: url)
        let before = try PDFSourceFileVersion.capture(at: url)
        XCTAssertGreaterThan(before.fileSize, PDFRawFileSnapshot.maximumFileBytes)
        let allocated = try XCTUnwrap(try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize)
        XCTAssertLessThan(allocated, 1 * 1_024 * 1_024, "The valid unused stream is a sparse hole.")
        let loaded = try PDFSourceFileAccess.loadDocument(at: url)
        XCTAssertEqual(loaded.version, before)
        XCTAssertEqual(loaded.document.pageCount, 1)
        XCTAssertEqual(loaded.document.documentRef?.numberOfPages, 1)
        XCTAssertTrue(PDFRawStreamProvenance.hasKnownNativeInput(loaded.document))
        XCTAssertNil(PDFRawStreamProvenance.source(for: loaded.document), "Files above the file-backed reader limit must not bind a raw source.")
        XCTAssertEqual(try PDFSourceFileVersion.capture(at: url), before)
    }

    func testLockedFactoryWitnessRequiresSameUnlockedOwnerAndNeverGrantsExtractionPermission() throws {
        let encrypted = try independentlyValidatedRestrictedFixture()
        let wrong = try XCTUnwrap(PDFDocument(data: encrypted))
        XCTAssertTrue(wrong.isLocked)
        XCTAssertFalse(wrong.unlock(withPassword: "WrongSyntheticPassword90"))
        XCTAssertTrue(wrong.isLocked)
        for owner in [false, true] {
            let source = try XCTUnwrap(PDFDocument(data: encrypted))
            XCTAssertTrue(source.isLocked)
            let nativeAtBoundary = source.documentRef
            PDFRawStreamProvenance.bindCreated(source, data: encrypted)
            XCTAssertFalse(PDFRawStreamProvenance.hasKnownNativeInput(source))
            XCTAssertThrowsError(try PDFDocumentSecurityPolicy.validateCanExtractPages(source))
            XCTAssertTrue(source.unlock(withPassword: owner ? "OwnerExport90" : "ReaderExport90"))
            XCTAssertFalse(source.isLocked)
            XCTAssertEqual(source.permissionsStatus, owner ? .owner : .user)
            if !owner {
                XCTAssertFalse(source.allowsCopying)
                XCTAssertFalse(source.allowsDocumentAssembly)
            }
            let sameNative = nativeAtBoundary.map { $0 === source.documentRef } ?? false
            XCTAssertEqual(PDFRawStreamProvenance.hasKnownNativeInput(source), sameNative,
                           "A missing or replaced locked native owner must remain unproven after unlock.")
            XCTAssertNil(PDFRawStreamProvenance.source(for: source), "Encrypted inputs still cannot enter the raw-payload/widget source.")
            if owner { XCTAssertNoThrow(try PDFDocumentSecurityPolicy.validateCanExtractPages(source)) }
            else { XCTAssertThrowsError(try PDFDocumentSecurityPolicy.validateCanExtractPages(source)) }
        }
    }

    @MainActor
    func testDocumentSnapshotPreservesEncodedPayloadAndItsOriginalFilterParameters() throws {
        let bytes = fixture(), live = try XCTUnwrap(PDFDocument(data: bytes))
        PDFRawStreamProvenance.bindCreated(live, data: bytes)
        let output = try PDFBodyTextPageSnapshot.preservingCatalog(in: bytes, from: live, plan: PDFCatalogGraphPlan())
        let native = try document(output), page = try XCTUnwrap(native.page(at: 1))
        let image = try imageStream(native), dictionary = try XCTUnwrap(CGPDFStreamGetDictionary(image))
        var filters: CGPDFArrayRef?, parameters: CGPDFArrayRef?, name: UnsafePointer<CChar>?
        XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "Filter", &filters))
        XCTAssertTrue(CGPDFArrayGetName(try XCTUnwrap(filters), 0, &name))
        XCTAssertEqual(name.map { String(cString: $0) }, "ASCIIHexDecode")
        XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "DecodeParms", &parameters))
        XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(parameters)), 1)
        let source = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: output))
        try source.preparePaintingResources(for: [page])
        XCTAssertEqual(try source.payload(for: image), Data("00204080>".utf8))
        var format = CGPDFDataFormat.raw
        XCTAssertEqual(CGPDFStreamCopyData(image, &format) as Data?, Data([0, 32, 64, 128]))
    }

    @MainActor
    func testSinglePageSnapshotStaysCanonicalWhenRawSourceBecomesAvailable() throws {
        let bytes = fixture(), live = try XCTUnwrap(PDFDocument(data: bytes))
        let page = try XCTUnwrap(live.page(at: 0)), reference = try XCTUnwrap(page.pageRef)
        let before = try PDFBodyTextPageSnapshot.originalPageData(for: page)
        PDFRawStreamProvenance.bindCreated(live, data: bytes)
        let source = try XCTUnwrap(PDFRawStreamProvenance.source(for: live))
        try source.preparePaintingResources(for: [reference])
        XCTAssertNotNil(try source.payload(for: imageStream(XCTUnwrap(live.documentRef))))
        XCTAssertEqual(try PDFBodyTextPageSnapshot.originalPageData(for: page), before)
    }

    func testNestedInheritedResourcesReturnOriginalEncodedBytesAndSharedObjects() throws {
        let bytes = fixture(), native = try document(bytes)
        let source = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: bytes))
        let page = try XCTUnwrap(native.page(at: 1))
        try source.preparePaintingResources(for: [page])
        let image = try imageStream(native)
        XCTAssertEqual(try source.payload(for: image), Data("00204080>".utf8))
        var format = CGPDFDataFormat.raw
        XCTAssertEqual(CGPDFStreamCopyData(image, &format) as Data?, Data([0, 32, 64, 128]))
        let form = try formStream(native)
        XCTAssertEqual(try source.payload(for: form), Data("q /Im1 Do Q".utf8))
        XCTAssertEqual(try source.payload(for: stream(try XCTUnwrap(page.dictionary), "Contents")),
                       Data("q /Fm1 Do Q".utf8))
        XCTAssertEqual(try source.payload(for: stream(try XCTUnwrap(page.dictionary), "Metadata")),
                       Data("<metadata/>".utf8))
        // Repeated preparation and shared Form/Image aliases cannot remap the
        // original stream to a different QPDF object or consume another buffer.
        try source.preparePaintingResources(for: [page, page])
        XCTAssertEqual(try source.payload(for: image), Data("00204080>".utf8))
    }

    func testForeignNativePageCannotAuthorizeEvenAnIdenticalResourceDictionary() throws {
        let bytes = fixture(), native = try document(bytes), foreign = try document(bytes)
        let source = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: bytes))
        try source.preparePaintingResources(for: [XCTUnwrap(foreign.page(at: 1))])
        XCTAssertNil(try source.payload(for: imageStream(foreign)))
        XCTAssertNil(try source.payload(for: imageStream(native)))
        try source.preparePaintingResources(for: [XCTUnwrap(native.page(at: 1))])
        XCTAssertEqual(try source.payload(for: imageStream(native)), Data("00204080>".utf8))
        XCTAssertNil(try source.payload(for: imageStream(foreign)))
    }

    func testDifferentDictionaryOrFilterAndExternalStreamFailClosed() throws {
        for bytes in [fixture(width: 9), fixture(filter: "/RunLengthDecode"), fixture(external: true)] {
            // Deliberate violation of the trusted constructor is used only to
            // verify the additional graph guard, never to claim that dictionary
            // comparisons could establish byte provenance on their own.
            let native = try document(fixture())
            let source = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: bytes))
            try source.preparePaintingResources(for: [XCTUnwrap(native.page(at: 1))])
            XCTAssertNil(try source.payload(for: imageStream(native)))
        }
        let bytes = fixture(external: true), native = try document(bytes)
        let source = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: bytes))
        try source.preparePaintingResources(for: [XCTUnwrap(native.page(at: 1))])
        XCTAssertNil(try source.payload(for: imageStream(native)))
    }

    func testChangedFileBeforeLazyReadFallsBackWithoutReadingReplacementPayload() throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let original = fixture(); try original.write(to: url)
        let native = try document(original), version = try PDFSourceFileVersion.capture(at: url)
        let source = try XCTUnwrap(PDFRawStreamSource.opened(native: native, url: url, version: version))
        try fixture(width: 9).write(to: url, options: .atomic)
        let changed = try Data(contentsOf: url)
        try source.preparePaintingResources(for: [XCTUnwrap(native.page(at: 1))])
        XCTAssertNil(try source.payload(for: imageStream(native)))
        XCTAssertEqual(try Data(contentsOf: url), changed)
    }

    func testWhollyForeignPagesDoNotReadOrPoisonAnUnavailableOriginalURL() throws {
        let url = temporaryURL(), backup = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: backup) }
        let original = fixture(); try original.write(to: url)
        let native = try document(original), foreign = try document(original)
        let version = try PDFSourceFileVersion.capture(at: url)
        let source = try XCTUnwrap(PDFRawStreamSource.opened(native: native, url: url, version: version))
        try FileManager.default.moveItem(at: url, to: backup)
        try fixture(width: 9).write(to: url)
        try source.preparePaintingResources(for: [XCTUnwrap(foreign.page(at: 1))])
        XCTAssertNil(try source.payload(for: imageStream(foreign)))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: backup, to: url)
        XCTAssertEqual(try PDFSourceFileVersion.capture(at: url), version)
        // If the foreign request had attempted the unavailable URL, this
        // source would have failed closed permanently rather than now working.
        try source.preparePaintingResources(for: [XCTUnwrap(native.page(at: 1))])
        XCTAssertEqual(try source.payload(for: imageStream(native)), Data("00204080>".utf8))
    }

    func testRetainedImmutableSourceSurvivesLaterAtomicOverwrite() throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let original = fixture(); try original.write(to: url)
        let native = try document(original), version = try PDFSourceFileVersion.capture(at: url)
        let source = try XCTUnwrap(PDFRawStreamSource.opened(native: native, url: url, version: version))
        try source.preparePaintingResources(for: [XCTUnwrap(native.page(at: 1))])
        // Load the context before our own future atomic save changes the URL.
        // The first payload request intentionally happens only after overwrite.
        try fixture(width: 9).write(to: url, options: .atomic)
        XCTAssertEqual(try source.payload(for: imageStream(native)), Data("00204080>".utf8))
        source.releaseCachedPayloads()
        XCTAssertEqual(try source.payload(for: imageStream(native)), Data("00204080>".utf8))
        XCTAssertEqual(try Data(contentsOf: url), fixture(width: 9))
    }

    func testCancellationIsPropagatedBeforePairingAndForCachedPayloads() throws {
        let bytes = fixture(), native = try document(bytes)
        let source = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: bytes))
        let token = PDFSaveCancellation(); token.cancel()
        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(token) {
            try source.preparePaintingResources(for: [XCTUnwrap(native.page(at: 1))])
        }) { XCTAssertTrue($0 is CancellationError) }
        try source.preparePaintingResources(for: [XCTUnwrap(native.page(at: 1))])
        _ = try XCTUnwrap(source.payload(for: imageStream(native)))
        XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(token) {
            try source.payload(for: imageStream(native))
        }) { XCTAssertTrue($0 is CancellationError) }
        source.releaseCachedPayloads()
        XCTAssertEqual(try source.payload(for: imageStream(native)), Data("00204080>".utf8),
                       "Releasing transient image copies must keep immutable source bytes available for re-saving.")
    }

    func testMalformedBytesAndOversizedExpectedSourceAreUnavailable() throws {
        let native = try document(fixture())
        let source = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: Data("not a pdf".utf8)))
        try source.preparePaintingResources(for: [XCTUnwrap(native.page(at: 1))])
        XCTAssertNil(try source.payload(for: imageStream(native)))
        let url = temporaryURL()
        let version = PDFSourceFileVersion(canonicalURL: url, fileSize: PDFRawFileSnapshot.maximumFileBytes + 1,
            contentModificationDate: Date(), fileSystemNumber: nil, fileSystemNodeNumber: nil)
        XCTAssertNil(PDFRawStreamSource.opened(native: native, url: url, version: version))
        XCTAssertNil(PDFRawStreamSource.created(native: native, data: Data()))
    }

    func testLaterGlobalAliasConflictQuarantinesPreviouslyPublishedPayload() throws {
        let bytes = aliasFixture(splitSecondImage: false), native = try document(bytes)
        // Intentional test-only constructor mismatch: page1 agrees completely;
        // page2 proves that one native stream cannot represent two QPDF streams.
        let source = try XCTUnwrap(PDFRawStreamSource.created(native: native, data: aliasFixture(splitSecondImage: true)))
        let first = try XCTUnwrap(native.page(at: 1)), second = try XCTUnwrap(native.page(at: 2))
        let image = try pageImage(first)
        try source.preparePaintingResources(for: [first])
        XCTAssertEqual(try source.payload(for: image), Data("00204080>".utf8))
        try source.preparePaintingResources(for: [second])
        XCTAssertNil(try source.payload(for: image))
        XCTAssertNil(try source.payload(for: pageImage(second)))
        try source.preparePaintingResources(for: [first])
        XCTAssertNil(try source.payload(for: image))
    }

    private func pageImage(_ page: CGPDFPage) throws -> CGPDFStreamRef {
        var resources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(page.dictionary), "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &xobjects))
        return try stream(XCTUnwrap(xobjects), "Im1")
    }

    @MainActor
    func testFactoryStructElemCryptMetadataKeepsEncodedBytesAndCompleteFilters() async throws {
        let xml = Data("<metadata>original-structure-owner</metadata>".utf8)
        for chained in [false, true] {
            let encoded = chained ? Data((xml.map { String(format: "%02x", $0) }.joined() + ">").utf8) : xml
            let bytes = structuralMetadataFixture(encoded: encoded, chained: chained)
            let live = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
            let native = try XCTUnwrap(live.documentRef), raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: live))
            var plan = PDFCatalogGraphPlan()
            let page = try XCTUnwrap(live.page(at: 0))
            try PDFTaggedStructurePreserver.addPreservedTags(from: [PDFCatalogSourceGroup(document: native,
                pages: [PDFCatalogPageOrigin(sourceIndex: 0, outputIndex: 0, livePage: page)], rawStreamSource: raw)], to: &plan)
            plan.rawStreamSources = [raw]
            let output = try await Task.detached {
                try PDFBodyTextPageSnapshot.preservingCatalog(in: bytes, from: live, plan: plan)
            }.value
            XCTAssertEqual(try independentStructuralMetadataBytes(output), encoded)
            let reopened = try document(output), metadata = try structuralMetadata(reopened)
            let dictionary = try XCTUnwrap(CGPDFStreamGetDictionary(metadata))
            var name: UnsafePointer<CChar>?, filters: CGPDFArrayRef?, parameters: CGPDFArrayRef?
            if chained {
                XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "Filter", &filters))
                XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(filters)), 2)
                XCTAssertTrue(CGPDFArrayGetName(try XCTUnwrap(filters), 0, &name))
                XCTAssertEqual(name.map { String(cString: $0) }, "Crypt")
                XCTAssertTrue(CGPDFArrayGetName(try XCTUnwrap(filters), 1, &name))
                XCTAssertEqual(name.map { String(cString: $0) }, "ASCIIHexDecode")
                XCTAssertTrue(CGPDFDictionaryGetArray(dictionary, "DecodeParms", &parameters))
                XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(parameters)), 2)
                var first: CGPDFDictionaryRef?
                XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(parameters), 0, &first))
                XCTAssertTrue(CGPDFDictionaryGetName(try XCTUnwrap(first), "Name", &name))
                XCTAssertEqual(name.map { String(cString: $0) }, "Identity")
                var second: CGPDFObjectRef?
                XCTAssertTrue(CGPDFArrayGetObject(try XCTUnwrap(parameters), 1, &second))
                XCTAssertEqual(CGPDFObjectGetType(try XCTUnwrap(second)), .null)
            } else {
                XCTAssertTrue(CGPDFDictionaryGetName(dictionary, "Filter", &name))
                XCTAssertEqual(name.map { String(cString: $0) }, "Crypt")
                XCTAssertNil(PDFCatalogStructurePreserver.object(dictionary, "DecodeParms"))
            }
            XCTAssertEqual(try independentStructuralMetadataBytes(bytes), encoded)
        }
    }

    @MainActor
    func testStructElemMetadataNeverBorrowsForeignOrReplacementPayloads() async throws {
        let old = Data("<metadata>original</metadata>".utf8), current = Data("<metadata>current</metadata>".utf8)
        let bytes = structuralMetadataFixture(encoded: old)
        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
        let foreign = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
        let replacement = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: structuralMetadataFixture(encoded: current)))
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
        let ownStream = try structuralMetadata(XCTUnwrap(source.documentRef))
        let otherStream = try structuralMetadata(XCTUnwrap(foreign.documentRef))
        let currentStream = try structuralMetadata(XCTUnwrap(replacement.documentRef))
        let legacy = try XCTUnwrap(PDFRawStreamSource.created(native: XCTUnwrap(source.documentRef), data: bytes))
        let values = try await Task.detached {
            let rejectedForeign = try raw.payload(for: otherStream)
            let rejectedCurrent = try raw.payload(for: currentStream)
            let rejectedLegacy = try legacy.payload(for: ownStream)
            let original = try raw.payload(for: ownStream)
            let currentRaw = try XCTUnwrap(PDFRawStreamProvenance.source(for: replacement))
            return (rejectedForeign, rejectedCurrent, rejectedLegacy, original, try currentRaw.payload(for: currentStream))
        }.value
        XCTAssertNil(values.0); XCTAssertNil(values.1); XCTAssertNil(values.2)
        XCTAssertEqual(values.3, old); XCTAssertEqual(values.4, current)
    }

    @MainActor
    func testStructElemMetadataMainMissAndCancellationDoNotPoisonRetry() async throws {
        let encoded = Data("<metadata>retry</metadata>".utf8), bytes = structuralMetadataFixture(encoded: encoded)
        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
        let stream = try structuralMetadata(XCTUnwrap(source.documentRef)), before = raw.widgetInputFootprint
        XCTAssertNil(try raw.payload(for: stream))
        XCTAssertEqual(raw.widgetInputFootprint.storage, before.storage)
        XCTAssertEqual(raw.widgetInputFootprint.ownedDataBytes, before.ownedDataBytes)
        let cancellation = PDFSaveCancellation(); cancellation.cancel()
        do {
            _ = try await Task.detached {
                try PDFSaveCancellation.withCurrent(cancellation) { try raw.payload(for: stream) }
            }.value
            XCTFail("Cancelled metadata proof must not publish")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(raw.widgetInputFootprint.storage, before.storage)
        let retried = try await Task.detached { try raw.payload(for: stream) }.value
        XCTAssertEqual(retried, encoded)
        XCTAssertEqual(try raw.payload(for: stream), encoded)
    }

    @MainActor
    func testStructElemMetadataSharedAliasAndDepthRefusalStayTransactional() async throws {
        let encoded = Data("<metadata>shared</metadata>".utf8)
        for overDepth in [false, true] {
            let bytes = structuralMetadataFixture(encoded: encoded, overDepth: overDepth)
            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
            let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
            let stream = try structuralMetadata(XCTUnwrap(source.documentRef))
            let actual = try await Task.detached { try raw.payload(for: stream) }.value
            if overDepth {
                XCTAssertNil(actual, "Later over-depth K cannot publish an earlier matching Metadata")
                XCTAssertNil(try raw.payload(for: stream), "A failed transaction leaves no Main cache hit")
            } else { XCTAssertEqual(actual, encoded, "Two StructElem owners may share one original Metadata stream") }
        }
    }

    @MainActor
    func testMetadataAbsentRawPrecheckAvoidsNativeKAndCachesOnlyCompleteAbsence() async throws {
        let bytes = metadataAbsentFixture()
        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
        let stream = try stream(XCTUnwrap(source.documentRef?.catalog), "Metadata")
        let cold = raw.widgetInputFootprint
        XCTAssertNil(try raw.payload(for: stream), "Main remains cache-only")
        XCTAssertEqual(raw.widgetInputFootprint.storage, cold.storage)
        XCTAssertEqual(raw.widgetInputFootprint.ownedDataBytes, cold.ownedDataBytes)
        XCTAssertEqual(raw.structuralMetadataPreparationFootprint.rawWalks, 0)
        XCTAssertFalse(raw.structuralMetadataPreparationFootprint.absenceProven)
        let first = try await Task.detached { try raw.payload(for: stream) }.value
        let second = try await Task.detached { try raw.payload(for: stream) }.value
        XCTAssertNil(first); XCTAssertNil(second)
        XCTAssertEqual(raw.structuralMetadataPreparationFootprint.rawWalks, 1)
        XCTAssertEqual(raw.structuralMetadataPreparationFootprint.nativeWalks, 0)
        XCTAssertTrue(raw.structuralMetadataPreparationFootprint.absenceProven)
        XCTAssertEqual(raw.numberCorrectionFootprint.entries, 0)
    }

    @MainActor
    func testMetadataAbsentPrecheckMidWalkCancellationDoesNotCacheOrPoisonRetry() async throws {
        let bytes = metadataAbsentFixture(nullCount: 2_048)
        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
        let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
        let stream = try stream(XCTUnwrap(source.documentRef?.catalog), "Metadata")
        let cancellation = PDFSaveCancellation()
        do {
            _ = try await Task.detached {
                try PDFRawStreamSource.$structuralMetadataRawVisitObserver.withValue({ visit in
                    if visit == 16 { cancellation.cancel() }
                }) {
                    try PDFSaveCancellation.withCurrent(cancellation) { try raw.payload(for: stream) }
                }
            }.value
            XCTFail("Mid-walk cancellation must escape without an absence cache")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(raw.structuralMetadataPreparationFootprint.rawWalks, 1)
        XCTAssertFalse(raw.structuralMetadataPreparationFootprint.absenceProven)
        XCTAssertEqual(raw.structuralMetadataPreparationFootprint.nativeWalks, 0)
        let retry = try await Task.detached { try raw.payload(for: stream) }.value
        XCTAssertNil(retry)
        XCTAssertEqual(raw.structuralMetadataPreparationFootprint.rawWalks, 2)
        XCTAssertTrue(raw.structuralMetadataPreparationFootprint.absenceProven)
        XCTAssertEqual(raw.numberCorrectionFootprint.entries, 0)
    }

    @MainActor
    func testMetadataAbsentPrecheckDepthCycleAndPendingBudgetNeverCachePartialAbsence() async throws {
        for bytes in [metadataAbsentFixture(overDepth: true), metadataAbsentFixture(cycle: true),
                      metadataAbsentFixture(nullCount: 250_001),
                      metadataAbsentFixture(nullCount: 249_995)] {
            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: bytes))
            let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
            let stream = try stream(XCTUnwrap(source.documentRef?.catalog), "Metadata")
            for _ in 0..<2 {
                let value = try await Task.detached { try raw.payload(for: stream) }.value
                XCTAssertNil(value)
                XCTAssertFalse(raw.structuralMetadataPreparationFootprint.absenceProven)
            }
            XCTAssertEqual(raw.structuralMetadataPreparationFootprint.rawWalks, 2)
            XCTAssertEqual(raw.structuralMetadataPreparationFootprint.nativeWalks, 0)
            XCTAssertLessThanOrEqual(raw.structuralMetadataPreparationFootprint.maximumPending, 250_000,
                "The near-cap array must not let a dictionary push exit+K beyond the shared pending ceiling")
            XCTAssertEqual(raw.numberCorrectionFootprint.entries, 0)
        }
    }

    @MainActor
    func testMetadataCandidateRetainsCompletePositiveTransactionAndLateDepthRefusal() async throws {
        let encoded = Data("<metadata>positive-unchanged</metadata>".utf8)
        for overDepth in [false, true] {
            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(
                data: structuralMetadataFixture(encoded: encoded, overDepth: overDepth)))
            let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
            let stream = try structuralMetadata(XCTUnwrap(source.documentRef))
            let actual = try await Task.detached { try raw.payload(for: stream) }.value
            if overDepth { XCTAssertNil(actual) } else { XCTAssertEqual(actual, encoded) }
            XCTAssertEqual(raw.structuralMetadataPreparationFootprint.rawWalks, 1)
            XCTAssertEqual(raw.structuralMetadataPreparationFootprint.nativeWalks, 1)
            XCTAssertFalse(raw.structuralMetadataPreparationFootprint.absenceProven)
            XCTAssertEqual(raw.numberCorrectionFootprint.entries, 0)
        }
    }

    private func metadataAbsentFixture(nullCount: Int = 0, overDepth: Bool = false, cycle: Bool = false) -> Data {
        let encoded = Data("<catalog-metadata/>".utf8)
        let content = "/P << /MCID 0 >> BDC EMC"
        let deep = overDepth ? String(repeating: "[", count: 65) + "null" + String(repeating: "]", count: 65) : ""
        let nulls = String(repeating: "null ", count: nullCount)
        var metadata = Data("<< /Type /Metadata /Subtype /XML /Length \(encoded.count) >>\nstream\n".utf8)
        metadata.append(encoded); metadata.append(Data("\nendstream".utf8))
        return assemble([
            Data("<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 4 0 R /Metadata 10 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 80 40] /Resources << >> /Contents 8 0 R /StructParents 0 >>".utf8),
            Data("<< /Type /StructTreeRoot /K 5 0 R /ParentTree 9 0 R /ParentTreeNextKey 1 >>".utf8),
            Data("<< /Type /StructElem /S /Document /P 4 0 R /K [6 0 R 6 0 R 11 0 R \(deep) \(nulls)] >>".utf8),
            Data("<< /Type /StructElem /S /Part /P 5 0 R /K [7 0 R] >>".utf8),
            Data("<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 0 >>".utf8),
            Data("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream".utf8),
            Data("<< /Nums [0 [7 0 R]] >>".utf8), metadata,
            Data("<< /Type /StructElem /S /Part /P 5 0 R /K [\(cycle ? "5 0 R" : "")] >>".utf8)
        ])
    }

    private func structuralMetadataFixture(encoded: Data, chained: Bool = false, overDepth: Bool = false) -> Data {
        let filters = chained ? "/Filter [/Crypt /ASCIIHexDecode] /DecodeParms [<< /Name /Identity >> null]" : "/Filter /Crypt"
        let deep = String(repeating: "[", count: 65) + "null" + String(repeating: "]", count: 65)
        let content = Data("/P << /MCID 0 >> BDC EMC".utf8)
        var metadata = Data("<< /Type /Metadata /Subtype /XML \(filters) /Length \(encoded.count) >>\nstream\n".utf8)
        metadata.append(encoded); metadata.append(Data("\nendstream".utf8))
        return assemble([
            Data("<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 4 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 80 40] /Resources << >> /Contents 8 0 R /StructParents 0 >>".utf8),
            Data("<< /Type /StructTreeRoot /K 5 0 R /ParentTree 9 0 R /ParentTreeNextKey 1 >>".utf8),
            Data("<< /Type /StructElem /S /Document /P 4 0 R /K [6 0 R 11 0 R \(overDepth ? deep : "")] >>".utf8),
            Data("<< /Type /StructElem /S /Part /P 5 0 R /K [7 0 R] /Metadata 10 0 R >>".utf8),
            Data("<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 0 >>".utf8),
            Data("<< /Length \(content.count) >>\nstream\n\(String(decoding: content, as: UTF8.self))\nendstream".utf8),
            Data("<< /Nums [0 [7 0 R]] >>".utf8), metadata,
            Data("<< /Type /StructElem /S /Part /P 5 0 R /K [] /Metadata 10 0 R >>".utf8)
        ])
    }

    private func structuralMetadata(_ native: CGPDFDocument) throws -> CGPDFStreamRef {
        let root = try XCTUnwrap(PDFCatalogStructurePreserver.dictionary(XCTUnwrap(native.catalog), "StructTreeRoot"))
        var node = root
        for _ in 0..<2 {
            let kids = try XCTUnwrap(PDFCatalogStructurePreserver.object(node, "K"))
            var dictionary: CGPDFDictionaryRef?
            if CGPDFObjectGetType(kids) == .array {
                var array: CGPDFArrayRef?
                XCTAssertTrue(CGPDFObjectGetValue(kids, .array, &array))
                XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(array), 0, &dictionary))
            } else { XCTAssertTrue(CGPDFObjectGetValue(kids, .dictionary, &dictionary)) }
            node = try XCTUnwrap(dictionary)
        }
        return try stream(node, "Metadata")
    }

    private func independentStructuralMetadataBytes(_ bytes: Data) throws -> Data {
        var status: Int32 = 9
        let context = try XCTUnwrap(bytes.withUnsafeBytes {
            ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, bytes.count, 4 * 1_024 * 1_024, 10_000, &status)
        })
        defer { ember_raw_pdf_destroy(context) }; XCTAssertEqual(status, 0)
        func value(_ object: EmberRawPDFObject, _ key: String) throws -> EmberRawPDFObject {
            var output: EmberRawPDFObject = 0
            let code = Array(("/" + key).utf8).withUnsafeBufferPointer {
                ember_raw_pdf_dictionary_get(context, object, $0.baseAddress, $0.count, &output)
            }
            XCTAssertEqual(code, 0); return output
        }
        var root: EmberRawPDFObject = 0; XCTAssertEqual(ember_raw_pdf_catalog(context, &root), 0)
        var node = try value(root, "StructTreeRoot")
        for _ in 0..<2 {
            var kids = try value(node, "K"), kind: Int32 = 0
            XCTAssertEqual(ember_raw_pdf_kind(context, kids, &kind), 0)
            if kind == Int32(EMBER_RAW_PDF_ARRAY.rawValue) {
                var first: EmberRawPDFObject = 0
                XCTAssertEqual(ember_raw_pdf_array_item(context, kids, 0, &first), 0); kids = first
            }
            node = kids
        }
        let metadata = try value(node, "Metadata")
        var pointer: UnsafeMutablePointer<UInt8>?, count = 0
        let code = ember_raw_pdf_stream_copy(context, metadata, 1_024 * 1_024, nil, nil, &pointer, &count)
        defer { if let pointer { ember_raw_pdf_free(pointer) } }
        XCTAssertEqual(code, 0)
        return pointer.map { Data(bytes: $0, count: count) } ?? Data()
    }

    private func aliasFixture(splitSecondImage: Bool) -> Data {
        let image = "<< /Type /XObject /Subtype /Image /Width 8 /Height 4 /BitsPerComponent 1 /ColorSpace /DeviceGray /Filter /ASCIIHexDecode /Length 9 >>\nstream\n00204080>\nendstream"
        return assemble([
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 80 40] >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /Resources << /XObject << /Im1 5 0 R >> >> >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /Resources << /XObject << /Im1 \(splitSecondImage ? 6 : 5) 0 R >> >> >>".utf8),
            Data(image.utf8), Data(image.utf8)
        ])
    }

    private func document(_ bytes: Data) throws -> CGPDFDocument {
        try XCTUnwrap(CGPDFDocument(CGDataProvider(data: bytes as CFData)!))
    }

    private func formStream(_ native: CGPDFDocument) throws -> CGPDFStreamRef {
        var parent: CGPDFDictionaryRef?, resources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?
        let page = try XCTUnwrap(native.page(at: 1)?.dictionary)
        if !CGPDFDictionaryGetDictionary(page, "Resources", &resources) {
            XCTAssertTrue(CGPDFDictionaryGetDictionary(page, "Parent", &parent))
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(parent), "Resources", &resources))
        }
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &xobjects))
        return try stream(XCTUnwrap(xobjects), "Fm1")
    }

    private func imageStream(_ native: CGPDFDocument) throws -> CGPDFStreamRef {
        let form = try formStream(native)
        var resources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(CGPDFStreamGetDictionary(form)), "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &xobjects))
        return try stream(XCTUnwrap(xobjects), "Im1")
    }

    private func stream(_ dictionary: CGPDFDictionaryRef, _ key: String) throws -> CGPDFStreamRef {
        var value: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetStream(dictionary, key, &value))
        return try XCTUnwrap(value)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
    }

    private final class NativeIdentityDocument: PDFDocument {
        var replacementNative: CGPDFDocument?
        override var documentRef: CGPDFDocument? { replacementNative ?? super.documentRef }
    }

    /// A valid xref/EOF and one real page with a small note. The unreferenced
    /// stream is sparse: no large Data, mapped buffer, or stream decode is used.
    private func writeLargeSparseFixture(to url: URL) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        var position: UInt64 = 0, offsets: [UInt64] = [0]
        func append(_ text: String) throws {
            let bytes = Data(text.utf8)
            try file.write(contentsOf: bytes)
            position += UInt64(bytes.count)
        }
        try append("%PDF-1.7\n")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 220 220] /Resources << >> /Contents 4 0 R /Annots [5 0 R] >>",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Type /Annot /Subtype /Text /Rect [20 20 40 40] /Contents (sparse-original-note) /F 4 >>"
        ]
        for (index, object) in objects.enumerated() {
            offsets.append(position)
            try append("\(index + 1) 0 obj\n\(object)\nendobj\n")
        }
        let unusedBytes = PDFRawFileSnapshot.maximumFileBytes
        offsets.append(position)
        try append("6 0 obj\n<< /Length \(unusedBytes) >>\nstream\n")
        position += unusedBytes
        try file.seek(toOffset: position)
        try append("\nendstream\nendobj\n")
        let xref = position
        try append("xref\n0 7\n0000000000 65535 f \n")
        for offset in offsets.dropFirst() { try append(String(format: "%010llu 00000 n \n", offset)) }
        try append("trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n")
    }

    /// Owned qpdf12.4.1 control independently verifies distinct owner/user
    /// credentials. Copying and assembly stay forbidden for the user. SDK
    /// distinct-owner generation failed before provenance was involved.
    private func independentlyValidatedRestrictedFixture() throws -> Data {
        let encoded = """
            JVBERi0xLjcKJb/3ov4KMSAwIG9iago8PCAvUGFnZXMgMiAwIFIgL1R5cGUgL0NhdGFsb2cgPj4KZW5kb2JqCjIgMCBvYmoKPDwg
            L0NvdW50IDIgL0tpZHMgWyAzIDAgUiA0IDAgUiBdIC9UeXBlIC9QYWdlcyA+PgplbmRvYmoKMyAwIG9iago8PCAvQW5ub3RzIFsg
            NSAwIFIgNiAwIFIgXSAvTWVkaWFCb3ggWyAwIDAgMjIwIDIyMCBdIC9QYXJlbnQgMiAwIFIgL1Jlc291cmNlcyA8PCA+PiAvVHlw
            ZSAvUGFnZSA+PgplbmRvYmoKNCAwIG9iago8PCAvQW5ub3RzIFsgNyAwIFIgXSAvTWVkaWFCb3ggWyAwIDAgMjIwIDIyMCBdIC9Q
            YXJlbnQgMiAwIFIgL1Jlc291cmNlcyA8PCA+PiAvVHlwZSAvUGFnZSA+PgplbmRvYmoKNSAwIG9iago8PCAvQ29udGVudHMgPDFl
            NmIxMzc3MzI5NTM5Y2U2ZjY4OTMwYWM1ODVkMmNjMmQwOTc2NzE0OTQ2YWFmNzRlNjI3OGE5MDY5MWFjNGI+IC9GIDQgL1BvcHVw
            IDYgMCBSIC9SZWN0IFsgMTAgMTAgMzAgMzAgXSAvU3VidHlwZSAvVGV4dCAvVHlwZSAvQW5ub3QgPj4KZW5kb2JqCjYgMCBvYmoK
            PDwgL1JlY3QgWyA0MCA0MCA5MCA5MCBdIC9TdWJ0eXBlIC9Qb3B1cCAvVHlwZSAvQW5ub3QgPj4KZW5kb2JqCjcgMCBvYmoKPDwg
            L0NvbnRlbnRzIDxiYmYxYjI0OWE3YTZiNTRhZTRkOTdmMDFjMzAyZThkYzIxYjZkY2I2Y2Q2M2E0YWI1NDZlMzg2NTQ3OTk4ZWY1
            PiAvRiA0IC9SZWN0IFsgMTAgMTAgMzAgMzAgXSAvU3VidHlwZSAvVGV4dCAvVHlwZSAvQW5ub3QgPj4KZW5kb2JqCjggMCBvYmoK
            PDwgL0NGIDw8IC9TdGRDRiA8PCAvQXV0aEV2ZW50IC9Eb2NPcGVuIC9DRk0gL0FFU1YyIC9MZW5ndGggMTYgPj4gPj4gL0ZpbHRl
            ciAvU3RhbmRhcmQgL0xlbmd0aCAxMjggL08gPGU3ZDc3ZGE1OWZhZGVjNTk4ZDhmZDM3M2RkZDgyZTg4M2ZkMWU1YjlmMWU4YTQy
            OWNkZGI3YTZiMDMyZmYxM2M+IC9PRSA8PiAvUCAtMzM5MiAvUiA0IC9TdG1GIC9TdGRDRiAvU3RyRiAvU3RkQ0YgL1UgPDNkZWEy
            NWM3MWNjZWNmNjZhZmNmMjkwNDU1YjQxNzE3MDAyMTQ0Njk5MGI5ZTQxMTQwNzFhNGQ5MTA0OTg0YzE+IC9VRSA8PiAvViA0ID4+
            CmVuZG9iagp4cmVmCjAgOQowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMTUgMDAwMDAgbiAKMDAwMDAwMDA2NCAwMDAwMCBu
            IAowMDAwMDAwMTI5IDAwMDAwIG4gCjAwMDAwMDAyNDMgMDAwMDAgbiAKMDAwMDAwMDM1MSAwMDAwMCBuIAowMDAwMDAwNTE3IDAw
            MDAwIG4gCjAwMDAwMDA1ODkgMDAwMDAgbiAKMDAwMDAwMDc0MiAwMDAwMCBuIAp0cmFpbGVyIDw8IC9Sb290IDEgMCBSIC9TaXpl
            IDkgL0lEIFs8MTZlNzhiMDkyMjY1MWRlOTBiNGNhM2NkNWFlMGU0YWU+PDE2ZTc4YjA5MjI2NTFkZTkwYjRjYTNjZDVhZTBlNGFl
            Pl0gL0VuY3J5cHQgOCAwIFIgPj4Kc3RhcnR4cmVmCjEwNTgKJSVFT0YK
            """
        let bytes = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        XCTAssertEqual(bytes.count, 1_392)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                       "2437c6b1da6bc5e8ad7452673ba2c903e1a6f0332d9f38a57dc7eb6ec4ffb473")
        return bytes
    }

    private func fixture(width: Int = 8, filter: String = "/ASCIIHexDecode", external: Bool = false) -> Data {
        func streamObject(_ dictionary: String, _ bytes: String) -> Data {
            Data(("<< " + dictionary + " /Length \(bytes.utf8.count) >>\nstream\n" + bytes + "\nendstream").utf8)
        }
        let objects = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 80 40] /Resources << /XObject << /Fm1 6 0 R /Fm2 6 0 R >> >> >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Metadata 7 0 R /Group << /S /Transparency /CS /DeviceGray >> >>".utf8),
            streamObject("", "q /Fm1 Do Q"),
            streamObject("/Type /XObject /Subtype /Image /Width \(width) /Height 4 /BitsPerComponent 1 /ColorSpace /DeviceGray /Filter [\(filter)] /DecodeParms [null] /Probe [/Esc#61ped 2 1.25 true false null <610062>]" + (external ? " /F (external.dat)" : ""), "00204080>"),
            streamObject("/Type /XObject /Subtype /Form /BBox [0 0 80 40] /Resources << /XObject << /Im1 5 0 R /Im2 5 0 R >> >>", "q /Im1 Do Q"),
            streamObject("/Type /Metadata /Subtype /XML", "<metadata/>")
        ]
        return assemble(objects)
    }

    private func assemble(_ objects: [Data]) -> Data {
        var result = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(result.count)
            result.append(Data("\(index + 1) 0 obj\n".utf8)); result.append(object); result.append(Data("\nendobj\n".utf8))
        }
        let xref = result.count
        result.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { result.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        result.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return result
    }
}
