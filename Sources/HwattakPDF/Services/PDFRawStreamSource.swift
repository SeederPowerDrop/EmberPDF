// SPDX-License-Identifier: MPL-2.0

import CEmberPDFRawStreams
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import PDFKit
import zlib

/// Original encoded streams for one immutable native PDF graph. The two
/// constructors are provenance boundaries: their caller must have created
/// `native` from these exact bytes, or opened it under the supplied before/after
/// file-version guard. Comparing dictionaries alone cannot prove stream bytes.
///
/// Painting resources may retain their encoded bytes. A separate number-tree
/// proof can validate sparse ParentTree slots through the same original bytes;
/// all tag remapping/serialization remains the existing writer's responsibility.
/// A failed proof leaves the existing CoreGraphics path in place.
final class PDFRawStreamSource: @unchecked Sendable {
    private static let maximumSourceBytes = 256 * 1_024 * 1_024
    private static let maximumStreamBytes = 64 * 1_024 * 1_024
    private static let maximumObjects: UInt32 = 500_000
    private static let maximumVisits = 250_000
    private let native: CGPDFDocument
    private let numberAuthority: PDFRawStreamProvenance.OriginalNumberAuthority?
    private let lock = NSLock()
#if DEBUG // QA_RAW_FAILURE_DIAGNOSTICS
    private var qaRawFailureMessageCount = 0
#endif // QA_RAW_FAILURE_DIAGNOSTICS
    private var input: Input
    private let tagReadOpenedFile: (url: URL, version: PDFSourceFileVersion)?
    private static let maximumWidgetStatePages = 64
    private static let maximumWidgetStateBytes = 8 * 1_024 * 1_024
    private struct WidgetPageStates {
        let appearances: [Int: PDFWidgetAppearancePreserver.State]
        let defaults: [Int: PDFWidgetAppearancePreserver.DefaultState]
        let byteCount: Int
    }
    // Successfully authorized original programs never evict/reparse. Once
    // this conservative source-owned capacity is exhausted, unknown programs
    // keep the existing CG path instead of consuming shared C handles forever.
    private static let maximumOriginalInkBytes = 8 * 1_024 * 1_024
    private static let maximumOriginalInkEntries = 4_096
    private struct OriginalInkKey: Hashable {
        let page: Int
        let annotation: Int
        let nativeIdentity: UInt
    }
    private struct OriginalInkEntry {
        let geometry: PDFPageGeometryPreserver.AnnotationGeometry
        let bytes: Int
        let numbers: Int
        let visits: Int
    }
    private var originalInkEntries: [OriginalInkKey: OriginalInkEntry] = [:]
    private var originalInkBytes = 0
    private var originalInkCapacityReached = false
    #if DEBUG
    private var originalInkReaderCalls = 0
    private var originalInkCacheHits = 0
    struct OriginalInkCacheFootprint: Sendable {
        let entries: Int
        let accountedBytes: Int
        let readerCalls: Int
        let cacheHits: Int
        let capacityReached: Bool
    }
    var originalInkCacheFootprint: OriginalInkCacheFootprint {
        lock.lock(); defer { lock.unlock() }
        return OriginalInkCacheFootprint(entries: originalInkEntries.count,
            accountedBytes: originalInkBytes, readerCalls: originalInkReaderCalls,
            cacheHits: originalInkCacheHits, capacityReached: originalInkCapacityReached)
    }
    #endif
    private var widgetStates: [Int: WidgetPageStates] = [:]
    private var widgetStateRecency: [Int] = []
    private var refusedWidgetPages = Set<Int>()
    private var widgetStateBytes = 0
    #if DEBUG
    /// Encoded payload accounting only, not total allocator/reader memory.
    struct WidgetStateCacheFootprint: Sendable {
        let pages: Int
        let encodedBytes: Int
        let refusedPages: Int
    }
    var widgetStateCacheFootprint: WidgetStateCacheFootprint {
        lock.lock(); defer { lock.unlock() }
        return WidgetStateCacheFootprint(pages: widgetStates.count,
            encodedBytes: widgetStateBytes, refusedPages: refusedWidgetPages.count)
    }
    struct NumberCorrectionFootprint: Sendable {
        let entries: Int
        let accountedBytes: Int
    }
    var numberCorrectionFootprint: NumberCorrectionFootprint {
        lock.lock(); defer { lock.unlock() }
        return NumberCorrectionFootprint(entries: numberCorrections.count, accountedBytes: numberCorrectionBytes)
    }
    struct WidgetInputFootprint: Sendable {
        let storage: String
        let ownedDataBytes: Int
    }
    var widgetInputFootprint: WidgetInputFootprint {
        lock.lock(); defer { lock.unlock() }
        switch input {
        case .file: return WidgetInputFootprint(storage: "versionGuardedFile", ownedDataBytes: 0)
        case .bytes(let data): return WidgetInputFootprint(storage: "ownedOriginalBytes", ownedDataBytes: data.count)
        case .consumed: return WidgetInputFootprint(storage: context != nil && !unavailable ? "immutableContext" : "unavailable", ownedDataBytes: 0)
        }
    }
    #endif
    private var widgetFormDefaults: [String: PDFCatalogGraphValue]?
    private var widgetFormDefaultsPrepared = false
    private var context: EmberRawPDFRef?
    private var fileSnapshot: PDFRawFileSnapshot?
    private var sourceByteCount = 0
    private var unavailable = false
    private var nativePages: [UInt: Int]?
    private var preparedPages = Set<UInt>()
    private var refusedPages = Set<UInt>()
    private var pairs: [NativeKey: EmberRawPDFObject] = [:]
    // Only parser discrepancies are retained, keyed by immutable container +
    // slot. Equal scalars need neither a cache entry nor a serializer C lookup.
    private static let maximumNumberCorrections = 16_384
    private static let maximumNumberCorrectionBytes = 1_024 * 1_024
    private var numberCorrections: [NumberSlot: NumberCorrection] = [:]
    private var numberCorrectionBytes = 0
    private var reversePairs: [EmberRawPDFObject: NativeKey] = [:]
    private var streams: [UInt: EmberRawPDFObject] = [:]
    // Memoization only: QPDF's immutable input and all pairing/provenance
    // tables stay authoritative after eviction. Data values share their COW
    // storage with the caller; the LRU never makes a second payload copy.
    private static let maximumPayloadCacheBytes = 32 * 1_024 * 1_024
    private static let maximumPayloadCacheEntries = 4_096
    private var payloadCacheByteLimit = PDFRawStreamSource.maximumPayloadCacheBytes
    private struct PayloadCacheLinks { var older: UInt?; var newer: UInt? }
    private var cachedPayloads: [UInt: Data] = [:]
    private var payloadCacheLinks: [UInt: PayloadCacheLinks] = [:]
    private var oldestPayloadCacheKey: UInt?, newestPayloadCacheKey: UInt?
    private var refusedPayloads = Set<UInt>()
    private var cachedByteCount = 0
    #if DEBUG
    private var payloadCacheHits = 0, payloadCopies = 0, payloadCacheEvictions = 0
    struct PayloadCacheFootprint: Equatable, Sendable {
        let entries: Int, retainedBytes: Int, byteLimit: Int
        let hits: Int, copies: Int, evictions: Int, refusedKeys: Int, pairedStreams: Int
        let contextLoaded: Bool
    }
    var payloadCacheFootprint: PayloadCacheFootprint {
        lock.lock(); defer { lock.unlock() }
        return PayloadCacheFootprint(entries: cachedPayloads.count, retainedBytes: cachedByteCount,
            byteLimit: payloadCacheByteLimit, hits: payloadCacheHits, copies: payloadCopies,
            evictions: payloadCacheEvictions, refusedKeys: refusedPayloads.count,
            pairedStreams: streams.count, contextLoaded: context != nil)
    }
    // A lower per-source budget makes byte eviction testable with tiny PDFs;
    // no production setting or proof/stream limit is changed by this hook.
    func setPayloadCacheByteLimitForTesting(_ limit: Int) -> Bool {
        guard (0...Self.maximumPayloadCacheBytes).contains(limit), acquireLock() else { return false }
        defer { lock.unlock() }
        if payloadCacheByteLimit != limit {
            clearPayloadCache(); payloadCacheByteLimit = limit
        }
        return true
    }
    #endif
    // A complete raw-only K walk may prove absence of optional StructElem
    // Metadata. This never authorizes a stream, painting or numeric reuse.
    private var structuralMetadataAbsenceProven = false
    #if DEBUG
    private var structuralMetadataRawWalks = 0
    private var structuralMetadataNativeWalks = 0
    private var structuralMetadataMaximumPending = 0
    @TaskLocal static var structuralMetadataRawVisitObserver: (@Sendable (Int) -> Void)?
    struct StructuralMetadataPreparationFootprint: Sendable {
        let rawWalks: Int
        let nativeWalks: Int
        let absenceProven: Bool
        let maximumPending: Int
    }
    var structuralMetadataPreparationFootprint: StructuralMetadataPreparationFootprint {
        lock.lock(); defer { lock.unlock() }
        return StructuralMetadataPreparationFootprint(rawWalks: structuralMetadataRawWalks,
            nativeWalks: structuralMetadataNativeWalks, absenceProven: structuralMetadataAbsenceProven,
            maximumPending: structuralMetadataMaximumPending)
    }
    #endif
    private var parentArrays: [Int: ParentArrayBinding]?
    private var parentArraysUnavailable = false
    private var cachedParentIndices: [UInt: [Int]] = [:]
    private var cachedParentIndexCount = 0
    // Positive scalar proofs only. Main-thread misses and cancellation never
    // publish a negative; no content bytes are retained in this cache.
    private var emptyContentProofs: [UInt: Int] = [:]
    private var provenEmptyOpeningActions = Set<UInt>()
    private var provenNullFitOpeningActions = Set<UInt>()
    private var storedDestinationNumbersPrepared = false
    private var provenInertOutlineParents = Set<UInt>()

    private enum Input { case file(URL, PDFSourceFileVersion), bytes(Data), consumed }
    private enum Unavailable: Error { case mismatch, limit, ambiguous }
    private struct NativeKey: Hashable { let kind: Int; let identity: UInt }
    private enum NumberSlot: Hashable {
        case dictionary(UInt, Data)
        case array(UInt, Int)
        // Conservative retained-key/record charge, not total allocator RSS.
        var accountedBytes: Int {
            switch self {
            case .dictionary(_, let key): return 128 + key.count
            case .array: return 128
            }
        }
    }
    private struct NumberCorrection: Equatable {
        let parsedBits: UInt64
        let original: Double
    }
    private struct SignatureNumber {
        let nativeKind: CGPDFObjectType
        let parsedBits: UInt64
        let integer: Int64?
        let token: String
        var bytes: Int { 160 + token.utf8.count }
    }
    private var signatureNumbers: [NumberSlot: SignatureNumber] = [:]
    private var signatureNumberBytes = 0
    private struct ParentArrayBinding {
        let nativeIdentity: UInt
        let original: EmberRawPDFObject
        let count: Int
    }
    private struct Pairing {
        var restoresOriginalNumbers = false
        var restoresSignatureTokens = false
        var signatureNumbers: [NumberSlot: SignatureNumber] = [:]
        var signatureNumberBytes = 0
        var numberCorrections: [NumberSlot: NumberCorrection] = [:]
        var numberCorrectionBytes = 0
        var pairs: [NativeKey: EmberRawPDFObject] = [:]
        var reverse: [EmberRawPDFObject: NativeKey] = [:]
        var streams: [UInt: EmberRawPDFObject] = [:]
        var visits = 0
    }

    private init(native: CGPDFDocument, input: Input,
                 numberAuthority: PDFRawStreamProvenance.OriginalNumberAuthority?) {
        self.native = native; self.input = input
        if case let .file(url, version) = input { tagReadOpenedFile = (url, version) }
        else { tagReadOpenedFile = nil }
        self.numberAuthority = numberAuthority?.matches(native) == true ? numberAuthority : nil
    }

    /// Called only after the normal document loader proves that its native
    /// graph was opened from `version`. Reading bytes is deferred to the worker.
    static func opened(native: CGPDFDocument, url: URL,
                       version: PDFSourceFileVersion,
                       numberAuthority: PDFRawStreamProvenance.OriginalNumberAuthority? = nil) -> PDFRawStreamSource? {
        guard !native.isEncrypted, version.fileSize <= PDFRawFileSnapshot.maximumFileBytes,
              version.canonicalURL == url.standardizedFileURL.resolvingSymlinksInPath() else { return nil }
        return PDFRawStreamSource(native: native, input: .file(url, version), numberAuthority: numberAuthority)
    }

    /// Called at the factory that constructs `native` from this exact Data.
    /// Arbitrary native/data pairs must never be passed to this constructor.
    static func created(native: CGPDFDocument, data: Data,
                        numberAuthority: PDFRawStreamProvenance.OriginalNumberAuthority? = nil) -> PDFRawStreamSource? {
        guard !native.isEncrypted, !data.isEmpty, data.count <= maximumSourceBytes else { return nil }
        return PDFRawStreamSource(native: native, input: .bytes(data), numberAuthority: numberAuthority)
    }

    /// Only an exact input factory can authorize a same-owner detached tag
    /// import. Existing bind-created/opened shapes alone cannot mint this proof.
    func provesExactFactoryOwner(_ owner: CGPDFDocument) -> Bool {
        owner === native && numberAuthority?.matches(owner) == true
    }


    private var signatureStates: [Int: [Int: PDFSignatureAppearancePreserver.State]] = [:]
    private var signatureStateRecency: [Int] = []
    private var signatureAppearances: [OriginalInkKey: ExactAnnotationAppearance] = [:]
    private var signatureProofBytes = 0
    private var signatureStateBytes = 0
    private var signatureInputHash: Data?
    private var signatureOriginals: [Data: PDFDocument] = [:]
    private var signatureOriginalBytes = 0

    /// Worker-only independent current-input state. Publication is positive,
    /// exact owner/slot bound and bounded; a main miss performs no reader work.
    func signatureState(in owner: CGPDFDocument, pageIndex: Int, annotationIndex: Int,
                        annotation: CGPDFDictionaryRef) throws -> PDFSignatureAppearancePreserver.State? {
        guard provesExactFactoryOwner(owner), !Thread.isMainThread, acquireLock() else { return nil }
        defer { lock.unlock() }
        guard !unavailable, pageIndex >= 0, pageIndex < native.numberOfPages,
              let page = native.page(at: pageIndex + 1)?.dictionary,
              let annotations = PDFCatalogStructurePreserver.array(page, "Annots"),
              CGPDFArrayGetCount(annotations) <= 10_000, annotationIndex >= 0,
              annotationIndex < CGPDFArrayGetCount(annotations) else { return nil }
        var original: CGPDFDictionaryRef?
        guard CGPDFArrayGetDictionary(annotations, annotationIndex, &original), original == annotation else { return nil }
        if let page = signatureStates[pageIndex] {
            signatureStateRecency.removeAll { $0 == pageIndex }; signatureStateRecency.append(pageIndex)
            return page[annotationIndex]
        }
        let bytes = try originalWidgetInput()
        guard let document = PDFDocument(data: bytes), document.pageCount == native.numberOfPages,
              let livePage = document.page(at: pageIndex), livePage.annotations.count == CGPDFArrayGetCount(annotations) else { return nil }
        var states: [Int: PDFSignatureAppearancePreserver.State] = [:], added = 0
        for (slot, live) in livePage.annotations.enumerated() where ["Stamp", "Widget"].contains(live.type ?? "") {
            if slot & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            var stored: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annotations, slot, &stored), let stored else { return nil }
            guard (try? PDFSignatureAppearancePreserver.storedDrawingDigest(stored)) != nil else { continue }
            guard let state = PDFSignatureAppearancePreserver.State(live) else { continue }
            guard state.bytes.count <= 8 * 1_024 * 1_024 - added else { return nil }
            added += state.bytes.count; states[slot] = state
        }
        try PDFSaveCancellation.checkCurrent()
        while signatureStates.count >= 64 || signatureStateBytes > 8 * 1_024 * 1_024 - added {
            guard let oldest = signatureStateRecency.first, let removed = signatureStates.removeValue(forKey: oldest) else { return nil }
            signatureStateRecency.removeFirst(); signatureStateBytes -= removed.values.reduce(0) { $0 + $1.bytes.count }
        }
        signatureStates[pageIndex] = states; signatureStateBytes += added; signatureStateRecency.append(pageIndex)
        return states[annotationIndex]
    }

    func signatureInputDigest(in owner: CGPDFDocument) throws -> Data? {
        guard provesExactFactoryOwner(owner), !Thread.isMainThread, acquireLock() else { return nil }
        defer { lock.unlock() }
        guard !unavailable else { return nil }
        if let signatureInputHash { return signatureInputHash }
        let bytes = try originalWidgetInput()
        try PDFSaveCancellation.checkCurrent()
        let result = Data(SHA256.hash(data: bytes)); signatureInputHash = result
        return result
    }

    struct ExactAnnotationAppearance {
        let appearance: CGPDFObjectRef
        let digest: Data
    }

    /// The raw digest bounds the graph BEFORE the existing bidirectional
    /// native/raw pairing runs. Nothing publishes until both proofs finish.
    func exactAnnotationAppearance(in owner: CGPDFDocument, pageIndex: Int, annotationIndex: Int,
                                   annotation: CGPDFDictionaryRef) throws -> ExactAnnotationAppearance? {
        guard provesExactFactoryOwner(owner), !Thread.isMainThread, acquireLock() else { return nil }
        defer { lock.unlock() }
        do {
            guard !unavailable, pageIndex >= 0, pageIndex < native.numberOfPages,
                  let page = native.page(at: pageIndex + 1)?.dictionary,
                  let annotations = PDFCatalogStructurePreserver.array(page, "Annots"),
                  CGPDFArrayGetCount(annotations) <= 10_000,
                  annotationIndex >= 0, annotationIndex < CGPDFArrayGetCount(annotations),
                  let ap = PDFCatalogStructurePreserver.object(annotation, "AP"), try loadContext() else { return nil }
            var original: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annotations, annotationIndex, &original), original == annotation else { return nil }
            let cacheKey = OriginalInkKey(page: pageIndex, annotation: annotationIndex, nativeIdentity: pdfReferenceIdentity(annotation))
            if let cached = signatureAppearances[cacheKey] { return cached }
            guard signatureAppearances.count < 4_096, signatureProofBytes < 64 * 1_024 * 1_024 else { return nil }
            let rawPage = try object { ember_raw_pdf_page($0, UInt32(pageIndex), &$1) }
            let rawAnnotations = try dictionaryValue(rawPage, key: Data("/Annots".utf8))
            var count: UInt32 = 0
            try checked(ember_raw_pdf_array_count(context, rawAnnotations, &count))
            guard count == CGPDFArrayGetCount(annotations) else { return nil }
            let rawAnnotation = try object { ember_raw_pdf_array_item($0, rawAnnotations, UInt32(annotationIndex), &$1) }
            let rawAP = try dictionaryValue(rawAnnotation, key: Data("/AP".utf8))
            var proofCost = 0
            let digest = try signatureGraphDigest(rawAP, totalLimit: min(16 * 1_024 * 1_024, 64 * 1_024 * 1_024 - signatureProofBytes), accountedBytes: &proofCost)
            var transaction = Pairing(); transaction.restoresOriginalNumbers = true; transaction.restoresSignatureTokens = true
            try pair(ap, rawAP, depth: 0, transaction: &transaction)
            try PDFSaveCancellation.checkCurrent()
            publishSignaturePair(transaction)
            let result = ExactAnnotationAppearance(appearance: ap, digest: digest)
            signatureAppearances[cacheKey] = result; signatureProofBytes += proofCost
            return result
        } catch is CancellationError { throw CancellationError() }
        catch Unavailable.ambiguous { quarantine(); return nil }
        catch { return nil }
    }

    /// Existing AF bytes are read without decoding. A marker is never proof:
    /// its hash must identify one exact bounded embedded Source PDF, opened by
    /// our data factory, and the original Widget/Sig AP must then match too.
    func embeddedSignatureOriginal(in owner: CGPDFDocument, digest: Data) throws -> PDFDocument? {
        guard provesExactFactoryOwner(owner), digest.count == 32, !Thread.isMainThread, acquireLock() else { return nil }
        defer { lock.unlock() }
        if let cached = signatureOriginals[digest] { return cached }
        do {
            guard !unavailable, signatureOriginals.count < 4, try loadContext(),
                  let catalog = native.catalog,
                  let nativeAF = PDFCatalogStructurePreserver.array(catalog, "AF"),
                  CGPDFArrayGetCount(nativeAF) <= 16 else { return nil }
            let rawCatalog = try object { ember_raw_pdf_catalog($0, &$1) }
            let rawAF = try dictionaryValue(rawCatalog, key: Data("/AF".utf8))
            var count: UInt32 = 0
            try checked(ember_raw_pdf_array_count(context, rawAF, &count))
            guard count == CGPDFArrayGetCount(nativeAF) else { return nil }
            var total = 0
            for index in 0..<Int(count) {
                try PDFSaveCancellation.checkCurrent()
                var specification: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(nativeAF, index, &specification), let specification,
                      let ef = PDFCatalogStructurePreserver.dictionary(specification, "EF"),
                      let nativeStream = PDFCatalogStructurePreserver.object(ef, "F") else { continue }
                var relationship: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(specification, "AFRelationship", &relationship), let relationship,
                      strcmp(relationship, "Source") == 0 else { continue }
                let rawSpec = try object { ember_raw_pdf_array_item($0, rawAF, UInt32(index), &$1) }
                let rawEF = try dictionaryValue(rawSpec, key: Data("/EF".utf8))
                let rawStream = try dictionaryValue(rawEF, key: Data("/F".utf8))
                let rawDictionary = try object { ember_raw_pdf_stream_dictionary($0, rawStream, &$1) }
                var keyCount: UInt32 = 0
                try checked(ember_raw_pdf_dictionary_count(context, rawDictionary, &keyCount))
                guard keyCount <= 4_096 else { return nil }
                var hasFilter = false, keyBytes = 0
                for keyIndex in 0..<keyCount {
                    let key = try copiedBytes { ember_raw_pdf_bounded_key_copy($0, rawDictionary, keyIndex, 4_096, &$1, &$2) }
                    guard key.count <= 65_536 - keyBytes else { return nil }
                    keyBytes += key.count
                    if [Data("/Filter".utf8), Data("/F".utf8)].contains(key) { hasFilter = true }
                }
                guard !hasFilter else { continue }
                let bytes = try signatureStreamBytes(rawStream, maximum: 64 * 1_024 * 1_024 - total)
                total += bytes.count
                guard total <= 64 * 1_024 * 1_024 else { return nil }
                guard Data(SHA256.hash(data: bytes)) == digest else { continue }
                // Bound all dictionary descendants before pair, too. This
                // proof includes Params and prevents a marker from enlarging
                // the graph/recursion contract through unrelated attachments.
                var proofCost = 0
                _ = try signatureGraphDigest(rawStream, streamLimit: 64 * 1_024 * 1_024, totalLimit: 65 * 1_024 * 1_024, accountedBytes: &proofCost)
                var transaction = Pairing(); transaction.restoresOriginalNumbers = true; transaction.restoresSignatureTokens = true
                try pair(nativeStream, rawStream, depth: 0, transaction: &transaction)
                guard bytes.count <= 64 * 1_024 * 1_024 - signatureOriginalBytes,
                      let document = PDFRawStreamProvenance.createdDocument(data: bytes) else { return nil }
                try PDFSaveCancellation.checkCurrent()
                publishSignaturePair(transaction)
                signatureOriginals[digest] = document; signatureOriginalBytes += bytes.count
                return document
            }
            return nil
        } catch is CancellationError { throw CancellationError() }
        catch Unavailable.ambiguous { quarantine(); return nil }
        catch { return nil }
    }

    private func publishSignaturePair(_ transaction: Pairing) {
        pairs.merge(transaction.pairs) { first, _ in first }
        reversePairs.merge(transaction.reverse) { first, _ in first }
        streams.merge(transaction.streams) { first, _ in first }
        numberCorrections.merge(transaction.numberCorrections) { first, _ in first }
        numberCorrectionBytes += transaction.numberCorrectionBytes
        signatureNumbers.merge(transaction.signatureNumbers) { first, _ in first }
        signatureNumberBytes += transaction.signatureNumberBytes
    }

    private func signatureStreamBytes(_ object: EmberRawPDFObject, maximum: Int) throws -> Data {
        guard maximum >= 0 else { throw Unavailable.limit }
        var pointer: UnsafeMutablePointer<UInt8>?, count = 0
        let status = ember_raw_pdf_stream_copy(context, object, maximum, { _ in
            do { try PDFSaveCancellation.checkCurrent(); return 0 } catch { return 1 }
        }, nil, &pointer, &count)
        defer { if let pointer { ember_raw_pdf_free(pointer) } }
        try checked(status)
        guard count <= maximum, count == 0 || pointer != nil else { throw Unavailable.limit }
        return pointer.map { Data(bytes: $0, count: count) } ?? Data()
    }

    /// Canonical exact graph, including alias/cycle topology, raw names,
    /// strings, encoded streams, filters and decoding parameters. Length is
    /// derived by the writer and is the sole omitted dictionary slot.
    private func signatureGraphDigest(_ root: EmberRawPDFObject,
                                      streamLimit: Int = 8 * 1_024 * 1_024,
                                      totalLimit: Int = 16 * 1_024 * 1_024, accountedBytes: inout Int) throws -> Data {
        var hasher = SHA256(), seen: [EmberRawPDFObject: Int] = [:], visits = 0, remaining = totalLimit
        func emit(_ data: Data) throws {
            guard data.count <= remaining else { throw Unavailable.limit }
            remaining -= data.count; hasher.update(data: data)
        }
        func atom(_ kind: String, _ data: Data) throws {
            try emit(Data((kind + String(data.count) + ":").utf8)); try emit(data)
        }
        func dictionary(_ object: EmberRawPDFObject, depth: Int, omittingLength: Bool = false) throws {
            var count: UInt32 = 0
            try checked(ember_raw_pdf_dictionary_count(context, object, &count))
            guard count <= 4_096 else { throw Unavailable.limit }
            var keys: [Data] = []
            for index in 0..<count {
                let key = try copiedBytes { ember_raw_pdf_bounded_key_copy($0, object, index, 4_096, &$1, &$2) }
                guard key.count <= 4_096, key.count <= remaining else { throw Unavailable.limit }
                remaining -= key.count
                if !omittingLength || key != Data("/Length".utf8) { keys.append(key) }
            }
            keys.sort { $0.lexicographicallyPrecedes($1) }
            for key in keys {
                try atom("k", key)
                try walk(try dictionaryValue(object, key: key), depth: depth + 1)
            }
            try emit(Data("}".utf8))
        }
        func walk(_ object: EmberRawPDFObject, depth: Int) throws {
            visits += 1
            if visits & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard depth <= 32, visits <= 8_192 else { throw Unavailable.limit }
            var kind: Int32 = 0
            try checked(ember_raw_pdf_kind(context, object, &kind))
            if (6...8).contains(kind) {
                if let existing = seen[object] { try atom("r", Data(String(existing).utf8)); return }
                seen[object] = seen.count
            }
            switch kind {
            case 0: try emit(Data("z".utf8))
            case 1:
                var value: Int32 = 0; try checked(ember_raw_pdf_boolean(context, object, &value))
                try emit(Data(value == 0 ? "f".utf8 : "t".utf8))
            case 2, 3:
                let token = try copiedBytes { ember_raw_pdf_number_token_copy($0, object, &$1, &$2) }
                try atom(kind == 2 ? "i" : "r", token)
            case 4: try atom("N", try copiedBytes { ember_raw_pdf_bounded_scalar_copy($0, object, min(65_536, remaining), &$1, &$2) })
            case 5: try atom("s", try copiedBytes { ember_raw_pdf_bounded_scalar_copy($0, object, min(65_536, remaining), &$1, &$2) })
            case 6:
                var count: UInt32 = 0; try checked(ember_raw_pdf_array_count(context, object, &count))
                guard count <= 4_096 else { throw Unavailable.limit }
                try emit(Data("[".utf8))
                for index in 0..<count { try walk(try self.object { ember_raw_pdf_array_item($0, object, index, &$1) }, depth: depth + 1) }
                try emit(Data("]".utf8))
            case 7: try emit(Data("d{".utf8)); try dictionary(object, depth: depth)
            case 8:
                try emit(Data("S{".utf8))
                try dictionary(try self.object { ember_raw_pdf_stream_dictionary($0, object, &$1) }, depth: depth, omittingLength: true)
                try atom("b", try signatureStreamBytes(object, maximum: min(streamLimit, remaining)))
            default: throw Unavailable.mismatch
            }
        }
        try walk(root, depth: 0); try PDFSaveCancellation.checkCurrent()
        accountedBytes = totalLimit - remaining
        return Data(hasher.finalize())
    }

    deinit { if let context { ember_raw_pdf_destroy(context) } }

    /// Only this exact guarded-file factory can mint a helper input. The
    /// digest comes from its immutable raw input, never a reopened URL alone.
    struct TagReadFileInput {
        let owner: CGPDFDocument
        let rawSource: PDFRawStreamSource
        let url: URL
        let version: PDFSourceFileVersion
        let digest: Data
        fileprivate init(owner: CGPDFDocument, rawSource: PDFRawStreamSource,
                         url: URL, version: PDFSourceFileVersion, digest: Data) {
            self.owner = owner; self.rawSource = rawSource; self.url = url
            self.version = version; self.digest = digest
        }
    }
    func tagReadFileInput(in owner: CGPDFDocument) throws -> TagReadFileInput? {
        try PDFSaveCancellation.checkCurrent()
        guard !Thread.isMainThread, provesExactFactoryOwner(owner),
              let file = tagReadOpenedFile, file.version.fileSize > 0,
              file.version.fileSize <= 128 * 1_024 * 1_024,
              try PDFSourceFileVersion.capture(at: file.url) == file.version,
              let digest = try signatureInputDigest(in: owner), digest.count == 32,
              try PDFSourceFileVersion.capture(at: file.url) == file.version else { return nil }
        try PDFSaveCancellation.checkCurrent()
        return TagReadFileInput(owner: owner, rawSource: self, url: file.url,
                                version: file.version, digest: digest)
    }

    /// Only already-owned immutable factory input can survive replacement of
    /// an opened URL. An unmaterialized .file is deliberately not reopened.
    struct TagReadImmutableInput {
        let owner: CGPDFDocument
        let rawSource: PDFRawStreamSource
        let bytes: Data
        let digest: Data
        fileprivate init(owner: CGPDFDocument, raw: PDFRawStreamSource, bytes: Data, digest: Data) {
            self.owner = owner; rawSource = raw; self.bytes = bytes; self.digest = digest
        }
        func fileInput(at url: URL, version: PDFSourceFileVersion) -> TagReadFileInput? {
            guard version.fileSize == UInt64(bytes.count), digest.count == 32 else { return nil }
            return TagReadFileInput(owner: owner, rawSource: rawSource, url: url, version: version, digest: digest)
        }
    }
    func tagReadImmutableInput(in owner: CGPDFDocument, maximumBytes: Int = 128 * 1_024 * 1_024) throws -> TagReadImmutableInput? {
        try PDFSaveCancellation.checkCurrent()
        guard !Thread.isMainThread, provesExactFactoryOwner(owner), maximumBytes > 0,
              maximumBytes <= 128 * 1_024 * 1_024, acquireLock() else { return nil }
        defer { lock.unlock() }
        guard !unavailable else { return nil }
        let bytes: Data
        switch input {
        case .file: return nil
        case .bytes(let original):
            guard !original.isEmpty, original.count <= maximumBytes else { return nil }
            bytes = original
        case .consumed:
            guard let context, sourceByteCount > 0, sourceByteCount <= maximumBytes else { return nil }
            var pointer: UnsafeMutablePointer<UInt8>?, count = 0
            let status = ember_raw_pdf_input_copy(context, maximumBytes, { _ in
                do { try PDFSaveCancellation.checkCurrent(); return 0 } catch { return 1 }
            }, nil, &pointer, &count)
            if status == Int32(EMBER_RAW_PDF_CANCELLED.rawValue) { throw CancellationError() }
            guard status == Int32(EMBER_RAW_PDF_OK.rawValue), let pointer,
                  count == sourceByteCount, count > 0, count <= maximumBytes else {
                if let pointer { ember_raw_pdf_free(pointer) }; return nil
            }
            bytes = Data(bytesNoCopy: pointer, count: count, deallocator: .custom { pointer, _ in
                ember_raw_pdf_free(pointer.assumingMemoryBound(to: UInt8.self))
            })
        }
        var hash = SHA256()
        for offset in stride(from: 0, to: bytes.count, by: 64 * 1_024) {
            try PDFSaveCancellation.checkCurrent()
            hash.update(data: bytes[offset..<min(bytes.count, offset + 64 * 1_024)])
        }
        let digest = Data(hash.finalize())
        guard signatureInputHash == nil || signatureInputHash == digest else { return nil }
        try PDFSaveCancellation.checkCurrent()
        signatureInputHash = digest
        return TagReadImmutableInput(owner: owner, raw: self, bytes: bytes, digest: digest)
    }

    /// The caller must additionally prove current contentUnchanged lineage
    /// and no live annotations. This method inspects only this owner's exact
    /// original page and Contents, never unrelated painting resources. The
    /// existing budget label now charges sum(max(encoded, decoded)) per stream;
    /// both accepted byte totals remain <=4096 across the complete plan.
    /// A neutral added page cannot introduce another document's Catalog or
    /// global metadata authority. Exact empty painting is proved by the same
    /// independently parsed input used by the existing preservation gate.
    func provesNeutralNativeStagingPage(_ page: CGPDFPage, remainingBytes: inout Int) throws -> Bool {
        guard !Thread.isMainThread, let catalog = native.catalog, CGPDFDictionaryGetCount(catalog) <= 8 else { return false }
        func keys(_ dictionary: CGPDFDictionaryRef, allowed: Set<String>) -> Bool {
            guard CGPDFDictionaryGetCount(dictionary) <= 32 else { return false }
            var result = true
            CGPDFDictionaryApplyBlock(dictionary, { key, _, _ in
                guard strnlen(key, 65) < 65, allowed.contains(String(cString: key)) else { result = false; return false }
                return true
            }, nil)
            return result
        }
        guard keys(catalog, allowed: ["Type", "Pages"]) else { return false }
        var pages: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "Pages", &pages), let pages,
              keys(pages, allowed: ["Type", "Kids", "Count", "Resources", "MediaBox", "CropBox", "BleedBox", "TrimBox", "ArtBox", "Rotate"]) else { return false }
        return try provesEmptyPageContents(for: page, remainingEncodedBytes: &remainingBytes)
    }

    func provesEmptyPageContents(for page: CGPDFPage, remainingEncodedBytes: inout Int) throws -> Bool {
        try PDFSaveCancellation.checkCurrent()
        guard (0...4_096).contains(remainingEncodedBytes), acquireLock() else { return false }
        defer { lock.unlock() }
        // A cold main call does not even construct a native page-index map.
        if Thread.isMainThread, emptyContentProofs.isEmpty { return false }
        guard let dictionary = page.dictionary else { return false }
        let identity = pdfReferenceIdentity(dictionary)
        if let cost = emptyContentProofs[identity] {
            guard cost <= remainingEncodedBytes else { return false }
            try PDFSaveCancellation.checkCurrent()
            remainingEncodedBytes -= cost
            return true
        }
        guard !Thread.isMainThread else { return false }
        do {
            if nativePages == nil {
                guard native.numberOfPages <= 100_000 else { return false }
                var indexes: [UInt: Int] = [:]
                for index in 0..<native.numberOfPages {
                    if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                    guard let original = native.page(at: index + 1)?.dictionary,
                          indexes.updateValue(index, forKey: pdfReferenceIdentity(original)) == nil else { return false }
                }
                nativePages = indexes
            }
            // Foreign pages must not initialize/read the original raw input.
            guard let index = nativePages?[identity], try loadContext() else { return false }
            let original = try object { ember_raw_pdf_page($0, UInt32(index), &$1) }
            guard try emptyProofDictionaryIsSmall(dictionary, original: original) else { return false }
            for key in ["AA", "PresSteps", "Group"] {
                guard emptyProofNativeValue(dictionary, key: key) == nil,
                      try emptyProofValue(original, key: key).kind == Int32(EMBER_RAW_PDF_NULL.rawValue) else { return false }
            }
            let localAnnotations = emptyProofNativeValue(dictionary, key: "Annots")
            if let localAnnotations {
                var array: CGPDFArrayRef?
                guard CGPDFObjectGetValue(localAnnotations, .array, &array), let array,
                      CGPDFArrayGetCount(array) == 0 else { return false }
            }
            let annotations = try emptyProofValue(original, key: "Annots")
            if annotations.kind != Int32(EMBER_RAW_PDF_NULL.rawValue) {
                var count: UInt32 = 0
                guard localAnnotations != nil, annotations.kind == Int32(EMBER_RAW_PDF_ARRAY.rawValue) else { return false }
                try checked(ember_raw_pdf_array_count(context, annotations.object, &count))
                guard count == 0 else { return false }
            } else if localAnnotations != nil { return false }
            let local = emptyProofNativeValue(dictionary, key: "Contents")
            let remoteContents = try emptyProofValue(original, key: "Contents")
            let hasOriginal = remoteContents.kind != Int32(EMBER_RAW_PDF_NULL.rawValue)
            guard (local != nil) == hasOriginal else { return false }
            var copied = Data()
            var proofCost = 0
            if let local {
                let contents = remoteContents.object
                var kind = remoteContents.kind
                var streamsToRead: [(CGPDFStreamRef, EmberRawPDFObject)] = []
                switch CGPDFObjectGetType(local) {
                case .stream:
                    var stream: CGPDFStreamRef?
                    guard CGPDFObjectGetValue(local, .stream, &stream), let stream,
                          kind == Int32(EMBER_RAW_PDF_STREAM.rawValue) else { return false }
                    streamsToRead.append((stream, contents))
                case .array:
                    var array: CGPDFArrayRef?, count: UInt32 = 0
                    guard CGPDFObjectGetValue(local, .array, &array), let array,
                          kind == Int32(EMBER_RAW_PDF_ARRAY.rawValue) else { return false }
                    try checked(ember_raw_pdf_array_count(context, contents, &count))
                    guard count <= 16, Int(count) == CGPDFArrayGetCount(array) else { return false }
                    for offset in 0..<Int(count) {
                        var stream: CGPDFStreamRef?
                        guard CGPDFArrayGetStream(array, offset, &stream), let stream else { return false }
                        let object = try self.object { ember_raw_pdf_array_item($0, contents, UInt32(offset), &$1) }
                        try checked(ember_raw_pdf_kind(context, object, &kind))
                        guard kind == Int32(EMBER_RAW_PDF_STREAM.rawValue) else { return false }
                        streamsToRead.append((stream, object))
                    }
                default: return false
                }
                for (stream, object) in streamsToRead {
                    try PDFSaveCancellation.checkCurrent()
                    guard let nativeDictionary = CGPDFStreamGetDictionary(stream) else { return false }
                    let remoteDictionary = try self.object { ember_raw_pdf_stream_dictionary($0, object, &$1) }
                    guard try emptyProofDictionaryIsSmall(nativeDictionary, original: remoteDictionary) else { return false }
                    for key in ["DecodeParms", "F", "FFilter", "FDecodeParms"] {
                        guard emptyProofNativeValue(nativeDictionary, key: key) == nil,
                              try emptyProofValue(remoteDictionary, key: key).kind == Int32(EMBER_RAW_PDF_NULL.rawValue) else { return false }
                    }
                    let nativeFilter = emptyProofNativeValue(nativeDictionary, key: "Filter")
                    let rawFilter = try emptyProofValue(remoteDictionary, key: "Filter")
                    let isFlate: Bool
                    if let nativeFilter {
                        var name: UnsafePointer<CChar>?
                        guard CGPDFObjectGetValue(nativeFilter, .name, &name), let name,
                              strcmp(name, "FlateDecode") == 0,
                              rawFilter.kind == Int32(EMBER_RAW_PDF_NAME.rawValue) else { return false }
                        isFlate = true
                    } else {
                        guard rawFilter.kind == Int32(EMBER_RAW_PDF_NULL.rawValue) else { return false }
                        isFlate = false
                    }
                    var pointer: UnsafeMutablePointer<UInt8>?, count = 0, encodedCount = 0
                    guard proofCost <= remainingEncodedBytes else { return false }
                    let streamBudget = remainingEncodedBytes - proofCost
                    let cancel: EmberRawPDFCancelCallback = { _ in
                        do { try PDFSaveCancellation.checkCurrent(); return 0 } catch { return 1 }
                    }
                    let status: Int32
                    if isFlate {
                        status = ember_raw_pdf_blank_flate_copy(context, object, streamBudget,
                            cancel, nil, &pointer, &count, &encodedCount)
                    } else {
                        status = ember_raw_pdf_stream_copy(context, object, streamBudget,
                            cancel, nil, &pointer, &count)
                        encodedCount = count
                    }
                    defer { if let pointer { ember_raw_pdf_free(pointer) } }
                    if status == Int32(EMBER_RAW_PDF_CANCELLED.rawValue) { throw CancellationError() }
                    guard status == Int32(EMBER_RAW_PDF_OK.rawValue), count >= 0, encodedCount >= 0,
                          count <= streamBudget, encodedCount <= streamBudget,
                          count == 0 || pointer != nil else { return false }
                    proofCost += max(encodedCount, count)
                    if let pointer { copied.append(pointer, count: count) }
                }
            }
            guard try PDFEmptyContentTokens.provesEmpty(copied) else { return false }
            try PDFSaveCancellation.checkCurrent()
            if emptyContentProofs.count >= 256 { emptyContentProofs.removeAll(keepingCapacity: true) }
            emptyContentProofs[identity] = proofCost
            remainingEncodedBytes -= proofCost
            return true
        } catch is CancellationError { throw CancellationError() }
        catch { return false }
    }

    /// Known-key lookup avoids allocating arbitrary original dictionary names.
    /// PDF dictionary null means absence for these non-painting optional keys.
    private func emptyProofValue(_ dictionary: EmberRawPDFObject, key: String) throws -> (object: EmberRawPDFObject, kind: Int32) {
        try PDFSaveCancellation.checkCurrent()
        let value = try dictionaryValue(dictionary, key: Data(("/" + key).utf8))
        var kind: Int32 = 0
        try checked(ember_raw_pdf_kind(context, value, &kind))
        return (value, kind)
    }

    private func emptyProofNativeValue(_ dictionary: CGPDFDictionaryRef, key: String) -> CGPDFObjectRef? {
        guard let value = PDFCatalogStructurePreserver.object(dictionary, key), CGPDFObjectGetType(value) != .null else { return nil }
        return value
    }

    private func emptyProofDictionaryIsSmall(_ native: CGPDFDictionaryRef, original: EmberRawPDFObject) throws -> Bool {
        guard CGPDFDictionaryGetCount(native) <= 128 else { return false }
        var total = 0, small = true
        CGPDFDictionaryApplyBlock(native, { key, _, _ in
            let count = strnlen(key, 4_097)
            guard count <= 4_096 - total else { small = false; return false }
            total += count
            return true
        }, nil)
        guard small else { return false }
        // dictionary_count builds QPDF's complete key cache. The native graph
        // already came from these exact bound bytes: inspect only its bounded
        // names, then use fixed source lookups and a scalar original kind check.
        var kind: Int32 = 0
        try checked(ember_raw_pdf_kind(context, original, &kind))
        return kind == Int32(EMBER_RAW_PDF_DICTIONARY.rawValue)
    }

    /// Prepare only stored null-target numeric definitions reached through
    /// this immutable factory owner's own catalog. No caller supplies an array.
    /// Main is cache-only; a worker failure is propagated before the writer
    /// snapshots correction containers, so a cold Main plan cannot round them.
    func prepareStoredDestinationNumbers() throws {
        try PDFSaveCancellation.checkCurrent()
        guard numberAuthority?.matches(native) == true, acquireLock() else { return }
        defer { lock.unlock() }
        guard !storedDestinationNumbersPrepared else { return }
        guard !Thread.isMainThread else { return }
        do {
            let candidates = try storedNullNumberCandidates()
            guard !candidates.isEmpty else { storedDestinationNumbersPrepared = true; return }
            guard !unavailable, try loadContext() else { throw Unavailable.mismatch }
            let catalog = try object { ember_raw_pdf_catalog($0, &$1) }
            var transaction = Pairing(); transaction.restoresOriginalNumbers = true
            for candidate in candidates {
                try PDFSaveCancellation.checkCurrent()
                let original: EmberRawPDFObject
                switch candidate.location {
                case .legacy(let dictionary, let key):
                    let remote = try dictionaryValue(catalog, key: Data("/Dests".utf8))
                    try pairStoredDictionaryIdentity(dictionary, remote, transaction: &transaction)
                    // Exact raw key bytes, not decoded display text.
                    // A missing key yields null and cannot pair with the
                    // required nonnull array/wrapper. No whole-table key copy.
                    original = try dictionaryValue(remote, key: key)
                case .modern(let names, let nodes, let children, let values, let offset, let key):
                    let remoteNames = try dictionaryValue(catalog, key: Data("/Names".utf8))
                    try pairStoredDictionaryIdentity(names, remoteNames, transaction: &transaction)
                    var remote = try dictionaryValue(remoteNames, key: Data("/Dests".utf8))
                    guard nodes.count == children.count + 1 else { throw Unavailable.mismatch }
                    for (index, node) in nodes.enumerated() {
                        try visitNumberTree(depth: index, transaction: &transaction)
                        try pairStoredDictionaryIdentity(node, remote, transaction: &transaction)
                        if index < children.count {
                            guard let kids = PDFCatalogStructurePreserver.object(node, "Kids") else { throw Unavailable.mismatch }
                            let other = try dictionaryValue(remote, key: Data("/Kids".utf8))
                            let paired = try pairedNumberTreeArray(kids, other, transaction: &transaction)
                            let slot = children[index]
                            guard slot >= 0, slot < CGPDFArrayGetCount(paired) else { throw Unavailable.mismatch }
                            remote = try object { ember_raw_pdf_array_item($0, other, UInt32(slot), &$1) }
                        }
                    }
                    guard let node = nodes.last,
                          let local = PDFCatalogStructurePreserver.object(node, "Names") else { throw Unavailable.mismatch }
                    let other = try dictionaryValue(remote, key: Data("/Names".utf8))
                    let paired = try pairedNumberTreeArray(local, other, transaction: &transaction)
                    guard paired == values, offset >= 0, offset + 1 < CGPDFArrayGetCount(values) else { throw Unavailable.mismatch }
                    let rawKey = try object { ember_raw_pdf_array_item($0, other, UInt32(offset), &$1) }
                    try requireKind(rawKey, Int32(EMBER_RAW_PDF_STRING.rawValue))
                    guard try copiedBytes({ ember_raw_pdf_string_copy($0, rawKey, &$1, &$2) }) == key else { throw Unavailable.mismatch }
                    original = try object { ember_raw_pdf_array_item($0, other, UInt32(offset + 1), &$1) }
                }
                try pair(candidate.value, original, depth: 0, transaction: &transaction)
            }
            try PDFSaveCancellation.checkCurrent()
            // The catalog path aliases above are partial shape proofs only.
            // Publish no painting pairs/streams, and no partial number proof.
            numberCorrections.merge(transaction.numberCorrections) { first, _ in first }
            numberCorrectionBytes += transaction.numberCorrectionBytes
            storedDestinationNumbersPrepared = true
        } catch is CancellationError { throw CancellationError() }
        catch Unavailable.ambiguous { quarantine(); throw Unavailable.ambiguous }
    }

    private enum StoredDestinationLocation {
        case legacy(CGPDFDictionaryRef, Data)
        case modern(CGPDFDictionaryRef, [CGPDFDictionaryRef], [Int], CGPDFArrayRef, Int, Data)
    }
    private struct StoredNullNumberCandidate {
        let value: CGPDFObjectRef
        let location: StoredDestinationLocation
    }

    /// Bounded preflight uses only this retained native catalog; the raw parser
    /// is never opened for documents without relevant stored real scalars.
    private func storedNullNumberCandidates() throws -> [StoredNullNumberCandidate] {
        guard let catalog = native.catalog else { throw Unavailable.mismatch }
        var result: [StoredNullNumberCandidate] = [], visits = 0, remainingBytes = 8 * 1_024 * 1_024
        func visit(_ depth: Int) throws {
            visits += 1
            if visits & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard depth < 64, visits <= Self.maximumVisits else { throw Unavailable.limit }
        }
        func append(_ value: CGPDFObjectRef, _ location: StoredDestinationLocation, bytes: Int) throws {
            guard result.count < Self.maximumNumberCorrections, bytes <= remainingBytes else { throw Unavailable.limit }
            remainingBytes -= bytes; result.append(StoredNullNumberCandidate(value: value, location: location))
        }
        if let legacy = PDFCatalogStructurePreserver.dictionary(catalog, "Dests") {
            guard CGPDFDictionaryGetCount(legacy) <= Self.maximumVisits else { throw Unavailable.limit }
            var failure: Error?
            CGPDFDictionaryApplyBlock(legacy, { key, value, _ in
                do {
                    try visit(0)
                    guard try self.storedNullDestinationHasReal(value) else { return true }
                    let count = strnlen(key, 4_097)
                    guard count <= 4_096 else { throw Unavailable.limit }
                    var bytes = Data([47]); bytes.append(contentsOf: UnsafeRawBufferPointer(start: key, count: count))
                    try append(value, .legacy(legacy, bytes), bytes: 128 + bytes.count)
                    return true
                } catch { failure = error; return false }
            }, nil)
            if let failure { throw failure }
        }
        guard let names = PDFCatalogStructurePreserver.dictionary(catalog, "Names"),
              let root = PDFCatalogStructurePreserver.dictionary(names, "Dests") else { return result }
        var pending: [(CGPDFDictionaryRef, [CGPDFDictionaryRef], [Int], Int)] = [(root, [root], [], 112)], seen = Set<UInt>()
        remainingBytes -= 112
        while let (node, nodes, children, charged) = pending.popLast() {
            remainingBytes += charged
            try visit(nodes.count - 1)
            guard seen.insert(pdfReferenceIdentity(node)).inserted else { throw Unavailable.ambiguous }
            if let values = PDFCatalogStructurePreserver.array(node, "Names") {
                let count = CGPDFArrayGetCount(values)
                guard count <= 2 * Self.maximumVisits, count % 2 == 0 else { throw Unavailable.limit }
                for offset in stride(from: 0, to: count, by: 2) {
                    try visit(nodes.count - 1)
                    var value: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(values, offset + 1, &value), let value else { throw Unavailable.mismatch }
                    guard try storedNullDestinationHasReal(value) else { continue }
                    var key: CGPDFStringRef?
                    guard CGPDFArrayGetString(values, offset, &key), let key else { throw Unavailable.mismatch }
                    let length = CGPDFStringGetLength(key)
                    guard length <= 4_096, length == 0 || CGPDFStringGetBytePtr(key) != nil else { throw Unavailable.limit }
                    let bytes = CGPDFStringGetBytePtr(key).map { Data(bytes: $0, count: length) } ?? Data()
                    try append(value, .modern(names, nodes, children, values, offset, bytes),
                               bytes: 192 + bytes.count + nodes.count * 16)
                }
            }
            if let kids = PDFCatalogStructurePreserver.array(node, "Kids") {
                let count = CGPDFArrayGetCount(kids)
                guard count <= Self.maximumVisits - pending.count else { throw Unavailable.limit }
                for offset in 0..<count {
                    var child: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(kids, offset, &child), let child else { throw Unavailable.mismatch }
                    let charge = 96 + (nodes.count + 1) * 16
                    guard charge <= remainingBytes else { throw Unavailable.limit }
                    remainingBytes -= charge
                    pending.append((child, nodes + [child], children + [offset], charge))
                }
            }
        }
        return result
    }

    private func storedNullDestinationHasReal(_ object: CGPDFObjectRef) throws -> Bool {
        var value = object
        if CGPDFObjectGetType(value) == .dictionary {
            var wrapper: CGPDFDictionaryRef?, nested: CGPDFObjectRef?
            guard CGPDFObjectGetValue(value, .dictionary, &wrapper), let wrapper,
                  CGPDFDictionaryGetCount(wrapper) == 1,
                  CGPDFDictionaryGetObject(wrapper, "D", &nested), let nested else { return false }
            value = nested
        }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetType(value) == .array, CGPDFObjectGetValue(value, .array, &array), let array else { return false }
        let count = CGPDFArrayGetCount(array)
        guard (2...6).contains(count) else { return false }
        var target: CGPDFObjectRef?, mode: UnsafePointer<CChar>?
        guard CGPDFArrayGetObject(array, 0, &target), let target, CGPDFObjectGetType(target) == .null,
              CGPDFArrayGetName(array, 1, &mode), let mode, strnlen(mode, 9) < 9 else { return false }
        let arities = ["XYZ": 5, "Fit": 2, "FitH": 3, "FitV": 3, "FitR": 6, "FitB": 2, "FitBH": 3, "FitBV": 3]
        guard let arity = arities[String(cString: mode)], count <= arity,
              String(cString: mode) != "FitR" || count == arity else { return false }
        var hasReal = false
        for index in 2..<count {
            var scalar: CGPDFObjectRef?, number: CGPDFReal = 0
            guard CGPDFArrayGetObject(array, index, &scalar), let scalar else { return false }
            switch CGPDFObjectGetType(scalar) {
            case .null: break
            case .integer, .real:
                guard CGPDFArrayGetNumber(array, index, &number), number.isFinite else { return false }
                hasReal = hasReal || CGPDFObjectGetType(scalar) == .real
            default: return false
            }
        }
        return hasReal
    }

    private func pairStoredDictionaryIdentity(_ dictionary: CGPDFDictionaryRef, _ original: EmberRawPDFObject,
                                              transaction: inout Pairing) throws {
        try requireKind(original, Int32(EMBER_RAW_PDF_DICTIONARY.rawValue))
        var count: UInt32 = 0
        try checked(ember_raw_pdf_dictionary_count(context, original, &count))
        guard Int(count) == CGPDFDictionaryGetCount(dictionary), Int(count) <= Self.maximumVisits else { throw Unavailable.mismatch }
        _ = try begin(NativeKey(kind: 7, identity: pdfReferenceIdentity(dictionary)), original, transaction: &transaction)
    }

    /// Only this exact factory-bound catalog may authorize copying its broken
    /// empty-name opening action. A cold main call never reads a file or starts
    /// the raw parser; the isolated writer may prepare one positive scalar proof.
    /// Final destination-map collision checks remain the caller's responsibility.
    func provesOriginalEmptyOpeningAction(in owner: CGPDFDocument,
                                          action: CGPDFDictionaryRef) throws -> Bool {
        try PDFSaveCancellation.checkCurrent()
        guard owner === native, numberAuthority?.matches(owner) == true,
              let catalog = owner.catalog,
              let original = PDFCatalogStructurePreserver.dictionary(catalog, "OpenAction"),
              original == action, CGPDFDictionaryGetCount(action) == 2,
              let destination = PDFCatalogStructurePreserver.object(action, "D"),
              CGPDFObjectGetType(destination) == .name else { return false }
        var name: UnsafePointer<CChar>?, subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(action, "S", &subtype), let subtype, strcmp(subtype, "GoTo") == 0,
              CGPDFObjectGetValue(destination, .name, &name), let name, name.pointee == 0,
              acquireLock() else { return false }
        defer { lock.unlock() }
        try PDFSaveCancellation.checkCurrent()
        guard !unavailable else { return false }
        let key = pdfReferenceIdentity(action)
        if provenEmptyOpeningActions.contains(key) { return true }
        guard !Thread.isMainThread else { return false }
        do {
            guard try loadContext() else { return false }
            let sourceCatalog = try object { ember_raw_pdf_catalog($0, &$1) }
            let sourceAction = try dictionaryValue(sourceCatalog, key: Data("/OpenAction".utf8))
            var matches: Int32 = 0
            try checked(ember_raw_pdf_exact_empty_goto_action(context, sourceAction, &matches))
            guard matches == 1 else { return false }
            try PDFSaveCancellation.checkCurrent()
            provenEmptyOpeningActions.insert(key)
            return true
        } catch is CancellationError { throw CancellationError() }
        catch { return false }
    }

    /// Only the exact original catalog action can authorize this otherwise
    /// unusable destination. This is a typed scalar proof, not a page mapping
    /// or painting/numeric authority. Main may reuse a positive worker proof.
    func provesOriginalNullFitOpeningAction(in owner: CGPDFDocument,
                                            action: CGPDFDictionaryRef) throws -> Bool {
        try PDFSaveCancellation.checkCurrent()
        guard owner === native, numberAuthority?.matches(owner) == true,
              let catalog = owner.catalog,
              let original = PDFCatalogStructurePreserver.dictionary(catalog, "OpenAction"),
              original == action, CGPDFDictionaryGetCount(action) == 2,
              let destination = PDFCatalogStructurePreserver.array(action, "D"),
              CGPDFArrayGetCount(destination) == 2 else { return false }
        var subtype: UnsafePointer<CChar>?, view: UnsafePointer<CChar>?, target: CGPDFObjectRef?
        guard CGPDFDictionaryGetName(action, "S", &subtype), let subtype, strcmp(subtype, "GoTo") == 0,
              CGPDFArrayGetObject(destination, 0, &target), let target, CGPDFObjectGetType(target) == .null,
              CGPDFArrayGetName(destination, 1, &view), let view, strcmp(view, "Fit") == 0,
              acquireLock() else { return false }
        defer { lock.unlock() }
        try PDFSaveCancellation.checkCurrent()
        guard !unavailable else { return false }
        let identity = pdfReferenceIdentity(action)
        if provenNullFitOpeningActions.contains(identity) { return true }
        guard !Thread.isMainThread else { return false }
        do {
            guard try loadContext() else { return false }
            let sourceCatalog = try object { ember_raw_pdf_catalog($0, &$1) }
            let sourceAction = try dictionaryValue(sourceCatalog, key: Data("/OpenAction".utf8))
            try requireKind(sourceAction, Int32(EMBER_RAW_PDF_DICTIONARY.rawValue))
            var count: UInt32 = 0
            try checked(ember_raw_pdf_dictionary_count(context, sourceAction, &count))
            guard count == 2 else { return false }
            var keys = Set<Data>()
            for index in 0..<count {
                keys.insert(try copiedBytes { ember_raw_pdf_bounded_key_copy($0, sourceAction, index, 2, &$1, &$2) })
            }
            guard keys == Set([Data("/S".utf8), Data("/D".utf8)]) else { return false }
            let rawSubtype = try dictionaryValue(sourceAction, key: Data("/S".utf8))
            try requireKind(rawSubtype, Int32(EMBER_RAW_PDF_NAME.rawValue))
            guard try copiedBytes({ ember_raw_pdf_bounded_scalar_copy($0, rawSubtype, 5, &$1, &$2) }) == Data("/GoTo".utf8) else { return false }
            let rawDestination = try dictionaryValue(sourceAction, key: Data("/D".utf8))
            try requireKind(rawDestination, Int32(EMBER_RAW_PDF_ARRAY.rawValue))
            try checked(ember_raw_pdf_array_count(context, rawDestination, &count))
            guard count == 2 else { return false }
            let rawTarget = try object { ember_raw_pdf_array_item($0, rawDestination, 0, &$1) }
            let rawView = try object { ember_raw_pdf_array_item($0, rawDestination, 1, &$1) }
            try requireKind(rawTarget, Int32(EMBER_RAW_PDF_NULL.rawValue))
            try requireKind(rawView, Int32(EMBER_RAW_PDF_NAME.rawValue))
            guard try copiedBytes({ ember_raw_pdf_bounded_scalar_copy($0, rawView, 4, &$1, &$2) }) == Data("/Fit".utf8) else { return false }
            try PDFSaveCancellation.checkCurrent()
            provenNullFitOpeningActions.insert(identity)
            return true
        } catch is CancellationError { throw CancellationError() }
        catch { return false }
    }

    /// An immutable candidate is not permission to serialize its native value.
    /// Only this source can construct it; the final writer must request the
    /// raw-byte proof, which is deferred off Main just like stored real numbers.
    struct PendingInertOutlineParent: @unchecked Sendable {
        fileprivate let source: PDFRawStreamSource
        fileprivate let node: CGPDFDictionaryRef
        fileprivate let path: [Int]
        fileprivate init(source: PDFRawStreamSource, node: CGPDFDictionaryRef, path: [Int]) {
            self.source = source; self.node = node; self.path = path
        }
        var retainedDocument: CGPDFDocument { source.native }
        func provenValue() throws -> PDFCatalogGraphValue? {
            guard try source.provesOriginalInertOutlineParent(node: node, path: path) else { return nil }
            // The fixed proof established every exact direct scalar. Keep the
            // original array direct; generic .original(array) graph encoding
            // intentionally promotes arrays to references and cannot do that.
            return .array([.null, .integer(0), .integer(0), .integer(1)])
        }
    }

    /// Native shape is only a cheap pending preflight. No raw parser, source
    /// bytes, painting pair map or output authority is created on this path.
    func pendingOriginalInertOutlineParent(in owner: CGPDFDocument, node: CGPDFDictionaryRef,
                                           path: [Int]) throws -> PendingInertOutlineParent? {
        try PDFSaveCancellation.checkCurrent()
        guard owner === native, numberAuthority?.matches(owner) == true,
              Self.isNativeInertOutlineParent(node),
              try nativeOutlineNode(at: path) == node else { return nil }
        return PendingInertOutlineParent(source: self, node: node, path: path)
    }

    private static func isNativeInertOutlineParent(_ node: CGPDFDictionaryRef) -> Bool {
        guard CGPDFDictionaryGetCount(node) <= 8,
              PDFCatalogStructurePreserver.object(node, "A") == nil,
              PDFCatalogStructurePreserver.dictionary(node, "First") != nil,
              PDFCatalogStructurePreserver.dictionary(node, "Last") != nil,
              let list = PDFCatalogStructurePreserver.array(node, "Dest"),
              CGPDFArrayGetCount(list) == 4 else { return false }
        var target: CGPDFObjectRef?
        guard CGPDFArrayGetObject(list, 0, &target), let target,
              CGPDFObjectGetType(target) == .null else { return false }
        for index in 1..<4 {
            var value: CGPDFInteger = -1
            guard CGPDFArrayGetInteger(list, index, &value), value == (index == 3 ? 1 : 0) else { return false }
        }
        return true
    }

    private func nativeOutlineNode(at path: [Int]) throws -> CGPDFDictionaryRef? {
        guard !path.isEmpty, path.count < 64, path.allSatisfy({ $0 >= 0 && $0 < 100_000 }),
              let catalog = native.catalog,
              var parent = PDFCatalogStructurePreserver.dictionary(catalog, "Outlines") else { return nil }
        var seen = Set<UInt>(), visits = 0
        for offset in path {
            var node = PDFCatalogStructurePreserver.dictionary(parent, "First")
            for index in 0...offset {
                visits += 1
                if visits & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                guard visits <= 100_000, let current = node,
                      seen.insert(pdfReferenceIdentity(current)).inserted else { return nil }
                if index == offset { parent = current }
                else { node = PDFCatalogStructurePreserver.dictionary(current, "Next") }
            }
        }
        return parent
    }

    private func provesOriginalInertOutlineParent(node: CGPDFDictionaryRef, path: [Int]) throws -> Bool {
        try PDFSaveCancellation.checkCurrent()
        guard numberAuthority?.matches(native) == true, Self.isNativeInertOutlineParent(node),
              try nativeOutlineNode(at: path) == node, acquireLock() else { return false }
        defer { lock.unlock() }
        try PDFSaveCancellation.checkCurrent()
        guard !unavailable else { return false }
        let identity = pdfReferenceIdentity(node)
        if provenInertOutlineParents.contains(identity) { return true }
        guard !Thread.isMainThread, provenInertOutlineParents.count < 4_096 else { return false }
        do {
            guard try loadContext() else { return false }
            let catalog = try object { ember_raw_pdf_catalog($0, &$1) }
            var parent = try dictionaryValue(catalog, key: Data("/Outlines".utf8))
            try requireKind(parent, Int32(EMBER_RAW_PDF_DICTIONARY.rawValue))
            var seen = Set<EmberRawPDFObject>(), visits = 0
            for offset in path {
                var current = try dictionaryValue(parent, key: Data("/First".utf8))
                for index in 0...offset {
                    visits += 1
                    if visits & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                    guard visits <= 100_000, seen.insert(current).inserted else { return false }
                    try requireKind(current, Int32(EMBER_RAW_PDF_DICTIONARY.rawValue))
                    if index == offset { parent = current }
                    else { current = try dictionaryValue(current, key: Data("/Next".utf8)) }
                }
            }
            let allowed = Set(["/Title", "/Parent", "/Prev", "/Next", "/Count", "/First", "/Last", "/Dest"].map { Data($0.utf8) })
            var count: UInt32 = 0
            try checked(ember_raw_pdf_dictionary_count(context, parent, &count))
            guard count <= 8 else { return false }
            let keys = try sourceKeys(parent)
            guard keys.isSubset(of: allowed),
                  Set(["/Title", "/Dest", "/First", "/Last"].map { Data($0.utf8) }).isSubset(of: keys) else { return false }
            for key in ["/First", "/Last"] {
                try requireKind(try dictionaryValue(parent, key: Data(key.utf8)), Int32(EMBER_RAW_PDF_DICTIONARY.rawValue))
            }
            let destination = try dictionaryValue(parent, key: Data("/Dest".utf8))
            var matches: Int32 = 0
            try checked(ember_raw_pdf_exact_inert_outline_destination(context, destination, &matches))
            guard matches == 1 else { return false }
            try PDFSaveCancellation.checkCurrent()
            provenInertOutlineParents.insert(identity)
            return true
        } catch is CancellationError { throw CancellationError() }
        catch { return false }
    }

    /// Independent original-reader state for a touched widget page. No live
    /// PDFDocument is retained. A worker freezes bounded file input once so
    /// later saves can revisit evicted state after replacing the original URL.
    /// Context replay borrows no C pointer beyond its owned Data lifetime.
    /// One temporary independent reader for all requested simple-Link pages.
    /// This is exact-input scalar evidence, never a late live-document baseline
    /// or AP/FS/tag authority. No reader or PDFKit object escapes the worker.
    func originalLinkControlStates(onPages requested: Set<Int>, maximumStateBytes: Int = 8 * 1_024 * 1_024) throws -> [Int: [Int: PDFCatalogStructurePreserver.LinkControlState]]? {
        try PDFSaveCancellation.checkCurrent()
        guard !Thread.isMainThread, provesExactFactoryOwner(native), native.numberOfPages <= 100_000, requested.count <= 100_000,
              maximumStateBytes > 0, maximumStateBytes <= 8 * 1_024 * 1_024,
              acquireLock() else { return nil }
        defer { lock.unlock() }
        do {
            var candidates: [(Int, CGPDFArrayRef)] = [], visits = 0
            for index in requested.sorted() {
                try PDFSaveCancellation.checkCurrent()
                guard index >= 0, index < native.numberOfPages,
                      let page = native.page(at: index + 1)?.dictionary else { return nil }
                guard let annotations = PDFCatalogStructurePreserver.array(page, "Annots") else { continue }
                let count = CGPDFArrayGetCount(annotations)
                guard count > 0, count <= 256 else { continue }
                visits += count
                guard visits <= 100_000 else { return nil }
                var supported = true
                for offset in 0..<count {
                    var annotation: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(annotations, offset, &annotation), let annotation,
                          PDFCatalogStructurePreserver.boundedOriginalLink(annotation, page: page) else {
                        supported = false; break
                    }
                }
                if supported { candidates.append((index, annotations)) }
            }
            guard !candidates.isEmpty else { return [:] }
            let bytes = try originalWidgetInput()
            guard let original = PDFDocument(data: bytes), !original.isEncrypted, !original.isLocked,
                  original.pageCount == native.numberOfPages else { return nil }
            var states: [Int: [Int: PDFCatalogStructurePreserver.LinkControlState]] = [:], retained = 0
            for (index, nativeAnnotations) in candidates {
                try PDFSaveCancellation.checkCurrent()
                guard let page = original.page(at: index), page.annotations.count == CGPDFArrayGetCount(nativeAnnotations) else { return nil }
                var measured: [Int: PDFCatalogStructurePreserver.LinkControlState] = [:]
                for (offset, annotation) in page.annotations.enumerated() {
                    try PDFSaveCancellation.checkCurrent()
                    var raw: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(nativeAnnotations, offset, &raw), let raw,
                          try PDFCatalogStructurePreserver.annotationFingerprint(raw) == PDFCatalogStructurePreserver.annotationFingerprint(annotation),
                          let state = PDFCatalogStructurePreserver.LinkControlState(annotation, destinationIndex: { target in
                              let index = original.index(for: target)
                              return index != NSNotFound && index >= 0 && index < original.pageCount ? index : nil
                          }) else { continue }
                    guard state.bytes.count <= maximumStateBytes - retained else { return nil }
                    retained += state.bytes.count; measured[offset] = state
                }
                states[index] = measured
            }
            try PDFSaveCancellation.checkCurrent()
            return states
        } catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    func originalWidgetStates(onPage index: Int) throws -> [Int: PDFWidgetAppearancePreserver.State]? {
        try originalWidgetPageStates(onPage: index)?.appearances
    }

    func originalWidgetDefaultStates(onPage index: Int) throws -> [Int: PDFWidgetAppearancePreserver.DefaultState]? {
        try originalWidgetPageStates(onPage: index)?.defaults
    }

    /// Both scalar proofs share one independent reader and one bounded LRU
    /// entry. A complete form/resource proof remains a separate AP gate.
    private func originalWidgetPageStates(onPage index: Int) throws -> WidgetPageStates? {
        try PDFSaveCancellation.checkCurrent()
        guard acquireLock() else { return nil }; defer { lock.unlock() }
        try PDFSaveCancellation.checkCurrent()
        if let cached = widgetStates[index] {
            widgetStateRecency.removeAll { $0 == index }
            widgetStateRecency.append(index)
            return cached
        }
        // Main-actor prepare/apply paths may reuse published scalar state, but
        // must never open another PDF, copy a book, or build the source proof.
        // A miss is deliberately retryable by the isolated background writer.
        guard !Thread.isMainThread else { return nil }
        guard !refusedWidgetPages.contains(index),
              index >= 0, index < native.numberOfPages else { return nil }
        do {
            // A complete Fields-tree proof is not required for default-only
            // state. Its resource bounds still apply before PDFKit can create
            // bridged choices/values from this touched native widget page.
            guard native.numberOfPages <= 100_000,
                  let dictionary = native.page(at: index + 1)?.dictionary,
                  let annotations = PDFCatalogStructurePreserver.array(dictionary, "Annots"),
                  CGPDFArrayGetCount(annotations) <= 10_000 else { throw Unavailable.mismatch }
            var rawScalarBudget = 64 * 1_024 * 1_024
            for offset in 0..<CGPDFArrayGetCount(annotations) {
                if offset & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                var annotation: CGPDFDictionaryRef?, subtype: UnsafePointer<CChar>?
                guard CGPDFArrayGetDictionary(annotations, offset, &annotation), let annotation else { throw Unavailable.mismatch }
                if CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype, strcmp(subtype, "Widget") == 0 {
                    var fieldBudget = 256 * 1_024
                    guard ["Parent", "Kids"].allSatisfy({ PDFCatalogStructurePreserver.object(annotation, $0) == nil }),
                          PDFWidgetAppearancePreserver.boundedPublicFieldValues(annotation,
                        remainingBudget: &fieldBudget) else { throw Unavailable.limit }
                    let cost = 256 * 1_024 - fieldBudget
                    // A field outside the scalar format/size contract above
                    // is refused; a valid page beyond working-set capacity
                    // remains retryable and is never cached as unsafe input.
                    guard cost <= rawScalarBudget else { return nil }
                    rawScalarBudget -= cost
                }
            }
            try PDFSaveCancellation.checkCurrent()
            let bytes = try originalWidgetInput()
            guard let original = PDFDocument(data: bytes), !original.isEncrypted, !original.isLocked,
                  original.pageCount == native.numberOfPages else { throw Unavailable.mismatch }
            guard let page = original.page(at: index),
                  CGPDFArrayGetCount(annotations) == page.annotations.count,
                  page.annotations.count <= 10_000 else { throw Unavailable.mismatch }
            var appearances: [Int: PDFWidgetAppearancePreserver.State] = [:]
            var defaults: [Int: PDFWidgetAppearancePreserver.DefaultState] = [:], added = 0
            for (offset, annotation) in page.annotations.enumerated() where annotation.type == "Widget" {
                try PDFSaveCancellation.checkCurrent()
                var raw: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annotations, offset, &raw), let raw,
                      try PDFCatalogStructurePreserver.annotationFingerprint(raw)
                        == PDFCatalogStructurePreserver.annotationFingerprint(annotation) else { continue }
                // A page must fit on its own. Capacity is not an unsafe-source
                // proof and must not permanently refuse this or later pages.
                if let state = PDFWidgetAppearancePreserver.DefaultState(annotation) {
                    guard state.byteCount <= Self.maximumWidgetStateBytes - added else { return nil }
                    added += state.byteCount; defaults[offset] = state
                }
                if let state = PDFWidgetAppearancePreserver.State(annotation) {
                    guard state.byteCount <= Self.maximumWidgetStateBytes - added else { return nil }
                    added += state.byteCount; appearances[offset] = state
                }
            }
            try PDFSaveCancellation.checkCurrent()
            // Publish only a complete verified page. Eviction changes the
            // working set, never coverage of a long form or a later revisit.
            while widgetStates.count >= Self.maximumWidgetStatePages
                    || widgetStateBytes > Self.maximumWidgetStateBytes - added {
                guard let oldest = widgetStateRecency.first else {
                    widgetStates.removeAll(); widgetStateBytes = 0
                    break
                }
                widgetStateRecency.removeFirst()
                if let removed = widgetStates.removeValue(forKey: oldest) {
                    widgetStateBytes -= removed.byteCount
                }
            }
            let result = WidgetPageStates(appearances: appearances, defaults: defaults, byteCount: added)
            widgetStates[index] = result; widgetStateBytes += added
            widgetStateRecency.append(index)
            return result
        } catch is CancellationError { throw CancellationError() }
        catch { refusedWidgetPages.insert(index); return nil }
    }

    /// Caller owns the source lock on a worker. Freeze the proven file input
    /// once, before a same-URL save can replace it. Evicted scalar baselines
    /// are re-read only from these immutable bytes or the existing context;
    /// a saved/current URL is never rebound to an older native graph.
    private func originalWidgetInput() throws -> Data {
        try PDFSaveCancellation.checkCurrent()
        switch input {
        case .file(let url, let expected):
            guard expected.fileSize <= UInt64(Self.maximumSourceBytes) else { throw Unavailable.limit }
            guard try PDFSourceFileVersion.capture(at: url) == expected else { throw Unavailable.mismatch }
            let bytes = try readBounded(url)
            guard !bytes.isEmpty, bytes.count <= Self.maximumSourceBytes,
                  UInt64(bytes.count) == expected.fileSize,
                  try PDFSourceFileVersion.capture(at: url) == expected else { throw Unavailable.mismatch }
            try PDFSaveCancellation.checkCurrent()
            input = .bytes(bytes)
            return bytes
        case .bytes(let bytes): return bytes
        case .consumed:
            guard let context, !unavailable else { throw Unavailable.mismatch }
            var pointer: UnsafeMutablePointer<UInt8>?, count = 0
            let status = ember_raw_pdf_input_copy(context, Self.maximumSourceBytes, { _ in
                do { try PDFSaveCancellation.checkCurrent(); return 0 } catch { return 1 }
            }, nil, &pointer, &count)
            if status == Int32(EMBER_RAW_PDF_CANCELLED.rawValue) { throw CancellationError() }
            guard status == Int32(EMBER_RAW_PDF_OK.rawValue), let pointer,
                  count > 0, count <= Self.maximumSourceBytes else {
                if let pointer { ember_raw_pdf_free(pointer) }; throw Unavailable.mismatch
            }
            // The existing C API owns one temporary <=256MiB copy, released
            // with this independent reader; no second input is retained here.
            return Data(bytesNoCopy: pointer, count: count, deallocator: .custom { pointer, _ in
                ember_raw_pdf_free(pointer.assumingMemoryBound(to: UInt8.self))
            })
        }
    }

    func originalWidgetFormDefaults() throws -> [String: PDFCatalogGraphValue]? {
        try PDFSaveCancellation.checkCurrent()
        guard acquireLock() else { return nil }; defer { lock.unlock() }
        return try prepareWidgetFormDefaults()
    }

    /// Caller owns lock. Only immutable native references are published; no
    /// PDFKit reader/font/color/page crosses from this worker into the cache.
    private func prepareWidgetFormDefaults() throws -> [String: PDFCatalogGraphValue]? {
        if widgetFormDefaultsPrepared { return widgetFormDefaults }
        guard !Thread.isMainThread else { return nil }
        let defaults = try PDFWidgetAppearancePreserver.defaults(from: native)
        widgetFormDefaults = defaults; widgetFormDefaultsPrepared = true
        return defaults
    }

    /// Only a genuine exact-input number factory can supply these original
    /// Ink coordinates. A caller must separately prove unchanged live geometry.
    /// The original native owner, page/Annots slot and dictionary identity are
    /// checked before input access. No generic binder, copied page or similar
    /// dictionary can acquire this authority. Main never initializes/reads a
    /// parser here; unsupported/capacity misses retain the existing CG path.
    func originalInkGeometry(in owner: CGPDFDocument, pageIndex: Int, annotationIndex: Int,
                             annotation: CGPDFDictionaryRef, budget: inout PDFInkGeometryWorkBudget) throws
        -> PDFPageGeometryPreserver.AnnotationGeometry? {
        try PDFSaveCancellation.checkCurrent()
        guard !Thread.isMainThread, owner === native, numberAuthority?.matches(native) == true,
              pageIndex >= 0, pageIndex < native.numberOfPages, pageIndex < 100_000,
              annotationIndex >= 0, budget.remainingBytes > 0,
              budget.remainingNumbers > 0, budget.remainingVisits > 0,
              acquireLock() else { return nil }
        defer { lock.unlock() }
        guard !unavailable,
              let page = native.page(at: pageIndex + 1)?.dictionary,
              let annotations = PDFCatalogStructurePreserver.array(page, "Annots") else { return nil }
        let count = CGPDFArrayGetCount(annotations)
        var expected: CGPDFDictionaryRef?, subtype: UnsafePointer<CChar>?
        guard count <= 100_000, annotationIndex < count,
              CGPDFArrayGetDictionary(annotations, annotationIndex, &expected), let expected,
              pdfReferenceIdentity(expected) == pdfReferenceIdentity(annotation),
              CGPDFDictionaryGetName(expected, "Subtype", &subtype), let subtype,
              strcmp(subtype, "Ink") == 0 else { return nil }
        let key = OriginalInkKey(page: pageIndex, annotation: annotationIndex,
                                 nativeIdentity: pdfReferenceIdentity(annotation))
        if let cached = originalInkEntries[key] {
            guard budget.consume(bytes: cached.bytes, numbers: cached.numbers, visits: cached.visits) else { return nil }
            try PDFSaveCancellation.checkCurrent()
            #if DEBUG
            originalInkCacheHits += 1
            #endif
            return cached.geometry
        }
        guard !originalInkCapacityReached else { return nil }
        guard originalInkEntries.count < Self.maximumOriginalInkEntries,
              originalInkBytes < Self.maximumOriginalInkBytes else {
            originalInkCapacityReached = true; return nil
        }
        guard try loadContext() else { return nil }
        do {
            var pageCount: UInt32 = 0
            try checked(ember_raw_pdf_page_count(context, &pageCount))
            guard Int(pageCount) == native.numberOfPages else { return nil }
            let rawPage = try object { ember_raw_pdf_page($0, UInt32(pageIndex), &$1) }
            let rawAnnotations = try dictionaryValue(rawPage, key: Data("/Annots".utf8))
            var kind: Int32 = 0, rawCount: UInt32 = 0
            try checked(ember_raw_pdf_kind(context, rawAnnotations, &kind))
            guard kind == Int32(EMBER_RAW_PDF_ARRAY.rawValue) else { return nil }
            try checked(ember_raw_pdf_array_count(context, rawAnnotations, &rawCount))
            guard Int(rawCount) == count else { return nil }
            let rawAnnotation = try object { ember_raw_pdf_array_item($0, rawAnnotations, UInt32(annotationIndex), &$1) }
            // The synchronous borrowed decoder cannot retain this context or
            // publish a partial geometry. Shared Catalog budget is charged even
            // on refused/cancelled attempts; it is not reset for another page.
            let before = budget
            #if DEBUG
            originalInkReaderCalls += 1
            #endif
            guard let result = try PDFInkGeometryNumericParser.read(annotation, raw: rawAnnotation,
                context: context, budget: &budget) else { return nil }
            // Precharge the published record as well as all parser work. Low
            // operation budget is retryable and never saturates source capacity.
            guard budget.consume(bytes: 256, numbers: 0, visits: 0) else { return nil }
            let cost = OriginalInkEntry(geometry: result,
                bytes: before.remainingBytes - budget.remainingBytes,
                numbers: before.remainingNumbers - budget.remainingNumbers,
                visits: before.remainingVisits - budget.remainingVisits)
            guard cost.bytes <= Self.maximumOriginalInkBytes - originalInkBytes else {
                originalInkCapacityReached = true; return nil
            }
            try PDFSaveCancellation.checkCurrent()
            originalInkEntries[key] = cost
            originalInkBytes += cost.bytes
            return result
        } catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    /// Exact original geometry numbers from the already provenance-bound
    /// bytes. CoreGraphics can parse485.4 as485.40000000000003; do not round
    /// that guess back to an invented value. Foreign parser pages are refused
    /// by identity before reading the input. Optional/default boxes stay absent.
    func originalPageGeometry(for page: CGPDFPage) throws -> [String: PDFCatalogGraphValue]? {
        try PDFSaveCancellation.checkCurrent()
        guard acquireLock() else { return nil }; defer { lock.unlock() }
        do {
            if nativePages == nil {
                guard native.numberOfPages <= 100_000 else { return nil }
                var indices: [UInt: Int] = [:]
                for index in 0..<native.numberOfPages {
                    if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                    guard let dictionary = native.page(at: index + 1)?.dictionary,
                          indices.updateValue(index, forKey: pdfReferenceIdentity(dictionary)) == nil else { return nil }
                }
                nativePages = indices
            }
            guard let dictionary = page.dictionary,
                  let index = nativePages?[pdfReferenceIdentity(dictionary)], try loadContext() else { return nil }
            let original = try object { ember_raw_pdf_page($0, UInt32(index), &$1) }
            var result: [String: PDFCatalogGraphValue] = [:]
            for name in ["MediaBox", "CropBox", "BleedBox", "TrimBox", "ArtBox", "Rotate"] {
                try PDFSaveCancellation.checkCurrent()
                guard let value = try geometryRoot(original, name: name) else { continue }
                var kind: Int32 = 0
                try checked(ember_raw_pdf_kind(context, value, &kind))
                if name == "Rotate" {
                    var number: Int64 = 0
                    guard kind == Int32(EMBER_RAW_PDF_INTEGER.rawValue) else { return nil }
                    try checked(ember_raw_pdf_integer(context, value, &number))
                    guard number % 90 == 0, let integer = Int(exactly: number) else { return nil }
                    result[name] = .integer(integer)
                    continue
                }
                guard kind == Int32(EMBER_RAW_PDF_ARRAY.rawValue) else { return nil }
                var count: UInt32 = 0
                try checked(ember_raw_pdf_array_count(context, value, &count))
                guard count == 4 else { return nil }
                var numbers: [PDFCatalogGraphValue] = [], coordinates: [Double] = []
                for item in 0..<count {
                    let member = try object { ember_raw_pdf_array_item($0, value, item, &$1) }
                    try checked(ember_raw_pdf_kind(context, member, &kind))
                    if kind == Int32(EMBER_RAW_PDF_INTEGER.rawValue) {
                        var number: Int64 = 0
                        try checked(ember_raw_pdf_integer(context, member, &number))
                        guard let integer = Int(exactly: number), abs(Double(number)) < 1_000_000_000 else { return nil }
                        numbers.append(.integer(integer)); coordinates.append(Double(number))
                    } else if kind == Int32(EMBER_RAW_PDF_REAL.rawValue) {
                        var number: Double = 0
                        try checked(ember_raw_pdf_real(context, member, &number))
                        guard number.isFinite, abs(number) < 1_000_000_000 else { return nil }
                        numbers.append(.real(number)); coordinates.append(number)
                    } else { return nil }
                }
                guard coordinates[2] != coordinates[0], coordinates[3] != coordinates[1] else { return nil }
                result[name] = .array(numbers)
            }
            guard result["MediaBox"] != nil else { return nil }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    private func geometryRoot(_ page: EmberRawPDFObject, name: String) throws -> EmberRawPDFObject? {
        var node = page, seen = Set<EmberRawPDFObject>()
        for _ in 0..<64 {
            guard seen.insert(node).inserted else { throw Unavailable.mismatch }
            let keys = try sourceKeys(node), key = Data(("/" + name).utf8)
            if keys.contains(key) {
                let value = try dictionaryValue(node, key: key)
                var kind: Int32 = 0; try checked(ember_raw_pdf_kind(context, value, &kind))
                if kind != Int32(EMBER_RAW_PDF_NULL.rawValue) { return value }
            }
            let parent = Data("/Parent".utf8)
            guard ["MediaBox", "CropBox", "Rotate"].contains(name), keys.contains(parent) else { return nil }
            node = try dictionaryValue(node, key: parent)
        }
        throw Unavailable.limit
    }

    /// Successful mappings are published only after the whole page's painting
    /// roots agree. A foreign native page is never paired by its page number.
    func preparePaintingResources(for pages: [CGPDFPage]) throws {
        try PDFSaveCancellation.checkCurrent()
        do {
            guard acquireLock() else { return }; defer { lock.unlock() }
            if nativePages == nil {
                guard native.numberOfPages <= 100_000 else { return }
                var indices: [UInt: Int] = [:]
                for index in 0..<native.numberOfPages {
                    if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                    guard let dictionary = native.page(at: index + 1)?.dictionary else { return }
                    let key = pdfReferenceIdentity(dictionary)
                    guard indices.updateValue(index, forKey: key) == nil else { return }
                }
                nativePages = indices
            }
            // PageWriter can have several independent original sources. A
            // wholly foreign request must not read or parse this source at all.
            guard pages.contains(where: { page in
                page.dictionary.map { nativePages?[pdfReferenceIdentity($0)] != nil } ?? false
            }), try loadContext() else { return }
        }
        for page in pages {
            try PDFSaveCancellation.checkCurrent()
            // A main-thread Apply must not wait behind a background Save. The
            // worker releases the shared context between pages as well.
            guard acquireLock() else { return }; defer { lock.unlock() }
            guard let dictionary = page.dictionary else { continue }
            let key = pdfReferenceIdentity(dictionary)
            guard !preparedPages.contains(key), !refusedPages.contains(key), let index = nativePages?[key] else { continue }
#if DEBUG // QA_RAW_FAILURE_DIAGNOSTICS
            var qaStreamPairs = 0
            func qaReport(_ kind: String) {
                guard self.qaRawFailureMessageCount < 16,
                      ProcessInfo.processInfo.environment["EMBER_QA_RAW_FAILURE_DIAGNOSTICS"] == "1" else { return }
                self.qaRawFailureMessageCount += 1
                FileHandle.standardError.write(Data("raw-painting-refused source=\(ObjectIdentifier(self)) page=\(index) kind=\(kind) partialStreamPairs=\(qaStreamPairs) publishedStreamPairs=\(self.streams.count)\n".utf8))
            }
#endif // QA_RAW_FAILURE_DIAGNOSTICS
            do {
                let original = try object { ember_raw_pdf_page($0, UInt32(index), &$1) }
                var transaction = Pairing()
#if DEBUG // QA_RAW_FAILURE_DIAGNOSTICS
                defer { qaStreamPairs = transaction.streams.count }
#endif // QA_RAW_FAILURE_DIAGNOSTICS
                transaction.restoresOriginalNumbers = numberAuthority?.matches(native) == true
                for name in ["Resources", "Group", "Contents", "Metadata"] {
                    let local = try nativeRoot(dictionary, name: name, inherited: name == "Resources")
                    let remote = try sourceRoot(original, name: name, inherited: name == "Resources")
                    switch (local, remote) {
                    case (nil, nil): break
                    case let (left?, right?): try pair(left, right, depth: 0, transaction: &transaction)
                    default: throw Unavailable.mismatch
                    }
                }
                try PDFSaveCancellation.checkCurrent()
                pairs.merge(transaction.pairs) { first, _ in first }
                reversePairs.merge(transaction.reverse) { first, _ in first }
                streams.merge(transaction.streams) { first, _ in first }
                // No partially checked root can publish a correction. The
                // existing alias checks above cover all four painting roots.
                numberCorrections.merge(transaction.numberCorrections) { first, _ in first }
                numberCorrectionBytes += transaction.numberCorrectionBytes
                preparedPages.insert(key)
            } catch is CancellationError { throw CancellationError() }
            catch Unavailable.ambiguous {
#if DEBUG // QA_RAW_FAILURE_DIAGNOSTICS
                qaReport("ambiguous")
#endif // QA_RAW_FAILURE_DIAGNOSTICS
                quarantine(); return
            }
            catch {
#if DEBUG // QA_RAW_FAILURE_DIAGNOSTICS
                qaReport((error as? Unavailable).map { String(describing: $0) } ?? "other")
#endif // QA_RAW_FAILURE_DIAGNOSTICS
                refusedPages.insert(key) /* An unproved page keeps the existing decoder. */
            }
        }
    }

    /// Complete cache success only, not partial resource-shape admission.
    /// The existing strict transaction checks all four painting roots against
    /// this exact immutable raw factory before it publishes preparedPages.
    func provesBodyTagPaintingRoots(_ page: CGPDFPage, in owner: CGPDFDocument) throws -> Bool {
        try PDFSaveCancellation.checkCurrent()
        guard !Thread.isMainThread else { return false }
        return try provesPaintingRoots(page, in: owner, preservingRawNumbers: false)
    }

    /// Glyph-only edits copy the exact source streams and restore paired raw
    /// numbers before writing their candidate. Other edits keep the old gate.
    func provesGlyphPaintingRoots(_ page: CGPDFPage, in owner: CGPDFDocument) throws -> Bool {
        // Apply performs at most a small original read. An optional edit
        // must not initialize the large-file reader on the main actor.
        if Thread.isMainThread, let file = tagReadOpenedFile, file.version.fileSize > 16 * 1_024 * 1_024 { return false }
        return try provesPaintingRoots(page, in: owner, preservingRawNumbers: true)
    }

    private func provesPaintingRoots(_ page: CGPDFPage, in owner: CGPDFDocument,
                                     preservingRawNumbers: Bool) throws -> Bool {
        guard provesExactFactoryOwner(owner), let dictionary = page.dictionary else { return false }
        try preparePaintingResources(for: [page])
        guard acquireLock() else { return false }; defer { lock.unlock() }
        return !unavailable && context != nil && preparedPages.contains(pdfReferenceIdentity(dictionary))
            && !refusedPages.contains(pdfReferenceIdentity(dictionary))
            // The Main single-page construction did not load raw numeric
            // tokens. If any retained source resource required a correction,
            // do not claim that this copy preserved its exact native meaning.
            // This global empty check is deliberately more conservative than
            // attempting to infer a per-page resource correction subset.
            && (preservingRawNumbers || numberCorrections.isEmpty)
    }

    /// Original-source metadata only. This does not publish any painting,
    /// stream, number or signature pairing. Previously paired ancestors still
    /// undergo direct bounded key/value checks on every proof.
    func provesBodyTagOwnerMetadata(in owner: CGPDFDocument, pageIndex: Int, mcid: Int,
                                    chain: [CGPDFDictionaryRef],
                                    paragraphStyleCommit: PDFBodyLosslessCommit? = nil) throws -> Bool {
        try PDFSaveCancellation.checkCurrent()
        guard !Thread.isMainThread, provesExactFactoryOwner(owner), pageIndex >= 0,
              pageIndex < native.numberOfPages, mcid >= 0, mcid < 100_000,
              !chain.isEmpty, chain.count <= 128, acquireLock() else { return false }
        defer { lock.unlock() }
        do {
            guard !unavailable, try loadContext(), let originalPage = native.page(at: pageIndex + 1),
                  let page = originalPage.dictionary, let catalog = native.catalog,
                  let root = PDFCatalogStructurePreserver.dictionary(catalog, "StructTreeRoot"),
                  chain.last == root else { return false }
            // This private Editor receipt is supplementary metadata evidence.
            // The caller must still prove the complete commit/owner graph.
            let retainParagraphStyle = paragraphStyleCommit.map {
                $0.retainsParagraphStyle(in: owner, page: originalPage, raw: self)
            } == true
            let rawPage = try object { ember_raw_pdf_page($0, UInt32(pageIndex), &$1) }
            var parentKey: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(page, "StructParents", &parentKey), parentKey >= 0,
                  try sourceInteger(dictionaryValue(rawPage, key: Data("/StructParents".utf8))) == parentKey else { return false }
            let bindings = try pairedParentArrays()
            guard let binding = bindings[Int(parentKey)], mcid < binding.count,
                  let array = try bodyTagParentArray(root: root, key: Int(parentKey)),
                  binding.nativeIdentity == pdfReferenceIdentity(array), binding.count == CGPDFArrayGetCount(array) else { return false }
            var nativeOwner: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, mcid, &nativeOwner), nativeOwner == chain.first else { return false }
            var rawNode = try object { ember_raw_pdf_array_item($0, binding.original, UInt32(mcid), &$1) }
            let rawCatalog = try object { ember_raw_pdf_catalog($0, &$1) }
            let rawRoot = try dictionaryValue(rawCatalog, key: Data("/StructTreeRoot".utf8))
            let rootEntries = try bodyTagEntries(root, rawRoot)
            var classEntries: [Data: CGPDFObjectRef] = [:], roleEntries: [Data: CGPDFObjectRef] = [:]
            var rawClasses: EmberRawPDFObject?, rawRoles: EmberRawPDFObject?
            if let value = rootEntries[Data("/ClassMap".utf8)] {
                var dictionary: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary else { return false }
                let raw = try dictionaryValue(rawRoot, key: Data("/ClassMap".utf8))
                classEntries = try bodyTagEntries(dictionary, raw); rawClasses = raw
            }
            if let value = rootEntries[Data("/RoleMap".utf8)] {
                var dictionary: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary else { return false }
                let raw = try dictionaryValue(rawRoot, key: Data("/RoleMap".utf8))
                roleEntries = try bodyTagEntries(dictionary, raw); rawRoles = raw
            }
            var seenRaw = Set<EmberRawPDFObject>(), seenNative = Set<UInt>(), remaining = 500_000
            let known = Set(["Type", "S", "P", "K", "Pg", "ID", "A", "C", "R", "Lang", "Info", "Metadata"].map { Data(("/" + $0).utf8) })
            let rootKnown = Set(["Type", "K", "IDTree", "ParentTree", "ParentTreeNextKey", "RoleMap", "ClassMap"].map { Data(("/" + $0).utf8) })
            let cached = Set(["ActualText", "Alt", "E", "T"].map { Data(("/" + $0).utf8) })
            for (index, node) in chain.enumerated() {
                try PDFSaveCancellation.checkCurrent()
                guard seenRaw.insert(rawNode).inserted, seenNative.insert(pdfReferenceIdentity(node)).inserted else { return false }
                let entries = try bodyTagEntries(node, rawNode), keys = Set(entries.keys)
                guard keys.isDisjoint(with: cached), keys.isSubset(of: node == root ? rootKnown : known) else { return false }
                if let value = entries[Data("/Type".utf8)] {
                    let name = try bodyTagName(value, dictionaryValue(rawNode, key: Data("/Type".utf8)))
                    guard name == Data((node == root ? "/StructTreeRoot" : "/StructElem").utf8) else { return false }
                }
                var documentAncestor = false
                if node != root {
                    guard let role = entries[Data("/S".utf8)] else { return false }
                    var name = try bodyTagName(role, dictionaryValue(rawNode, key: Data("/S".utf8)))
                    var roleSeen = Set<Data>()
                    while let mapped = roleEntries[name] {
                        guard let rawRoles, roleSeen.count < 64, roleSeen.insert(name).inserted else { return false }
                        name = try bodyTagName(mapped, dictionaryValue(rawRoles, key: name))
                    }
                    guard Self.bodyTagStandardRoles.contains(name) else { return false }
                    documentAncestor = index > 0 && name == Data("/Document".utf8)
                }
                if let value = entries[Data("/Info".utf8)] {
                    guard documentAncestor,
                          try bodyTagDocumentInfo(value, dictionaryValue(rawNode, key: Data("/Info".utf8))) else { return false }
                }
                if let value = entries[Data("/Metadata".utf8)] {
                    guard documentAncestor,
                          try bodyTagDocumentMetadata(value, dictionaryValue(rawNode, key: Data("/Metadata".utf8))) else { return false }
                }
                if let value = entries[Data("/A".utf8)] {
                    guard try bodyTagEmpty(value, dictionaryValue(rawNode, key: Data("/A".utf8))) else { return false }
                }
                if let value = entries[Data("/C".utf8)] {
                    let name = try bodyTagName(value, dictionaryValue(rawNode, key: Data("/C".utf8)))
                    // Undefined attribute classes add no attributes (ISO 32000-2, 14.7.6.2).
                    // Complete raw/native key equality above distinguishes absence from null or unreadable values.
                    if let attributes = classEntries[name] {
                        guard let rawClasses,
                              try bodyTagAttributes(attributes, dictionaryValue(rawClasses, key: name),
                                  retainParagraphStyle: retainParagraphStyle) else { return false }
                    }
                }
                // Bounded immutable scalar values only; no real-number or
                // container equality is inferred from a prior pairing cache.
                for key in ["ID", "Lang", "R"] {
                    let bytes = Data(("/" + key).utf8)
                    if let value = entries[bytes] {
                        let raw = try dictionaryValue(rawNode, key: bytes)
                        switch CGPDFObjectGetType(value) {
                        case .integer:
                            var local: CGPDFInteger = 0
                            guard CGPDFObjectGetValue(value, .integer, &local), try sourceInteger(raw) == local else { return false }
                        case .string:
                            var local: CGPDFStringRef?
                            guard CGPDFObjectGetValue(value, .string, &local), let local,
                                  CGPDFStringGetLength(local) <= 4_096 else { return false }
                            let count = CGPDFStringGetLength(local)
                            let bytes = CGPDFStringGetBytePtr(local).map { Data(bytes: $0, count: count) } ?? Data()
                            try requireKind(raw, Int32(EMBER_RAW_PDF_STRING.rawValue))
                            guard bytes.count == count,
                                  bytes == (try copiedBytes { ember_raw_pdf_bounded_scalar_copy($0, raw, 4_096, &$1, &$2) }) else { return false }
                        default: return false
                        }
                    }
                }
                if index == chain.count - 1 { return node == root && rawNode == rawRoot }
                guard node != root, let nativeParent = PDFCatalogStructurePreserver.dictionary(node, "P"),
                      nativeParent == chain[index + 1] else { return false }
                let rawParent = try dictionaryValue(rawNode, key: Data("/P".utf8))
                try requireKind(rawParent, Int32(EMBER_RAW_PDF_DICTIONARY.rawValue))
                let rawChildren = try dictionaryValue(rawParent, key: Data("/K".utf8))
                guard try bodyTagContains(rawChildren, child: rawNode, depth: 0, remaining: &remaining) else { return false }
                rawNode = rawParent
            }
            return false
        } catch is CancellationError { throw CancellationError() }
        catch { return false }
    }

    private static let bodyTagStandardRoles = Set(["Document", "Part", "Art", "Sect", "Div", "BlockQuote", "Caption", "TOC", "TOCI", "Index", "NonStruct", "Private", "H", "H1", "H2", "H3", "H4", "H5", "H6", "P", "L", "LI", "Lbl", "LBody", "Table", "TR", "TH", "TD", "THead", "TBody", "TFoot", "Span", "Quote", "Note", "Reference", "BibEntry", "Code", "Link", "Annot", "Ruby", "RB", "RT", "RP", "Warichu", "WT", "WP", "Figure", "Formula", "Form"].map { Data(("/" + $0).utf8) })

    private func bodyTagEntries(_ dictionary: CGPDFDictionaryRef, _ raw: EmberRawPDFObject) throws -> [Data: CGPDFObjectRef] {
        try requireKind(raw, Int32(EMBER_RAW_PDF_DICTIONARY.rawValue))
        var count: UInt32 = 0
        try checked(ember_raw_pdf_dictionary_count(context, raw, &count))
        guard count <= 4_096, CGPDFDictionaryGetCount(dictionary) == Int(count) else { throw Unavailable.limit }
        var names = Set<Data>(), total = 0
        for index in 0..<count {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            let key = try copiedBytes { ember_raw_pdf_bounded_key_copy($0, raw, index, 4_096, &$1, &$2) }
            guard key.first == 47, !key.contains(0), key.count <= 65_536 - total, names.insert(key).inserted else { throw Unavailable.mismatch }
            total += key.count
        }
        // Compare the native CString keys independently of value lookup.
        // Callback values may be null for malformed indirect objects and are
        // deliberately ignored here; every value is resolved below instead.
        var nativeNames = Set<Data>(), nativeCount = 0, nativeBytes = 0
        var nativeFailure: Error?
        CGPDFDictionaryApplyBlock(dictionary, { key, _, _ in
            do {
                if nativeCount & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                let count = strnlen(key, 4_097)
                guard count <= 4_096, nativeCount < 4_096 else { throw Unavailable.limit }
                var bytes = Data([47])
                bytes.append(contentsOf: UnsafeRawBufferPointer(start: key, count: count))
                guard bytes.count <= 65_536 - nativeBytes else { throw Unavailable.limit }
                guard nativeNames.insert(bytes).inserted else { throw Unavailable.mismatch }
                nativeBytes += bytes.count; nativeCount += 1
                return true
            } catch { nativeFailure = error; return false }
        }, nil)
        if let nativeFailure { throw nativeFailure }
        guard nativeCount == Int(count), nativeNames == names else { throw Unavailable.mismatch }

        var result: [Data: CGPDFObjectRef] = [:]
        for (index, key) in names.enumerated() {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            // Native enumeration may report a present key with a null object
            // for an unreadable indirect scalar. Require a real value before
            // optional metadata lookup can treat that key as absent. The raw
            // bytes above already proved the slash, size and absence of NUL.
            var cKey = key.dropFirst().map { CChar(bitPattern: $0) }
            cKey.append(0)
            var value: CGPDFObjectRef?
            let present = cKey.withUnsafeBufferPointer {
                CGPDFDictionaryGetObject(dictionary, $0.baseAddress!, &value)
            }
            guard present, let value,
                  result.updateValue(value, forKey: key) == nil else { throw Unavailable.mismatch }
        }
        guard Set(result.keys) == names else { throw Unavailable.mismatch }
        return result
    }

    private func bodyTagName(_ value: CGPDFObjectRef, _ raw: EmberRawPDFObject) throws -> Data {
        try requireKind(raw, Int32(EMBER_RAW_PDF_NAME.rawValue))
        var name: UnsafePointer<CChar>?
        guard CGPDFObjectGetType(value) == .name, CGPDFObjectGetValue(value, .name, &name), let name else { throw Unavailable.mismatch }
        let count = strnlen(name, 4_097)
        guard count <= 4_096 else { throw Unavailable.mismatch }
        var bytes = Data([47]); bytes.append(contentsOf: UnsafeRawBufferPointer(start: name, count: count))
        let original = try copiedBytes { ember_raw_pdf_bounded_scalar_copy($0, raw, 4_096, &$1, &$2) }
        guard !original.contains(0), bytes == original else { throw Unavailable.mismatch }
        return bytes
    }

    private func bodyTagEmpty(_ value: CGPDFObjectRef, _ raw: EmberRawPDFObject) throws -> Bool {
        switch CGPDFObjectGetType(value) {
        case .array:
            var array: CGPDFArrayRef?, count: UInt32 = 0
            guard CGPDFObjectGetValue(value, .array, &array), let array else { return false }
            try requireKind(raw, Int32(EMBER_RAW_PDF_ARRAY.rawValue))
            try checked(ember_raw_pdf_array_count(context, raw, &count))
            return count == 0 && CGPDFArrayGetCount(array) == 0
        case .dictionary:
            var dictionary: CGPDFDictionaryRef?, count: UInt32 = 0
            guard CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary else { return false }
            try requireKind(raw, Int32(EMBER_RAW_PDF_DICTIONARY.rawValue))
            try checked(ember_raw_pdf_dictionary_count(context, raw, &count))
            return count == 0 && CGPDFDictionaryGetCount(dictionary) == 0
        default: return false
        }
    }

    /// Retain a known ClassMap paragraph style; direct A stays inert-only.
    /// Do not claim equal ink or
    /// reinterpret geometry/cached text as a harmless style. The original
    /// class/inheritance objects are copied, never synthesized or edited.
    private func bodyTagAttributes(_ value: CGPDFObjectRef, _ raw: EmberRawPDFObject,
                                   retainParagraphStyle: Bool) throws -> Bool {
        if try bodyTagEmpty(value, raw) { return true }
        guard retainParagraphStyle, CGPDFObjectGetType(value) == .dictionary else { return false }
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary else { return false }
        let entries = try bodyTagEntries(dictionary, raw)
        let allowed = Set(["O", "LineHeight", "TextAlign", "TextIndent", "StartIndent", "SpaceBefore", "SpaceAfter"].map { Data(("/" + $0).utf8) })
        guard entries.count <= allowed.count, Set(entries.keys).isSubset(of: allowed),
              let owner = entries[Data("/O".utf8)],
              try bodyTagName(owner, dictionaryValue(raw, key: Data("/O".utf8))) == Data("/Layout".utf8) else { return false }
        for (key, attribute) in entries where key != Data("/O".utf8) {
            try PDFSaveCancellation.checkCurrent()
            let remote = try dictionaryValue(raw, key: key)
            if key == Data("/TextAlign".utf8) {
                let name = try bodyTagName(attribute, remote)
                guard ["/Start", "/Center", "/End", "/Justify"].contains(String(decoding: name, as: UTF8.self)) else { return false }
            } else if key == Data("/LineHeight".utf8), CGPDFObjectGetType(attribute) == .name {
                let name = try bodyTagName(attribute, remote)
                guard name == Data("/Normal".utf8) || name == Data("/Auto".utf8) else { return false }
            } else {
                let number: Double
                switch CGPDFObjectGetType(attribute) {
                case .integer:
                    var local: CGPDFInteger = 0
                    guard CGPDFObjectGetValue(attribute, .integer, &local), try sourceInteger(remote) == local else { return false }
                    number = Double(local)
                case .real:
                    try requireKind(remote, Int32(EMBER_RAW_PDF_REAL.rawValue))
                    var local: CGPDFReal = 0, stored = 0.0
                    guard CGPDFObjectGetValue(attribute, .real, &local) else { return false }
                    try checked(ember_raw_pdf_real(context, remote, &stored))
                    guard local.isFinite, stored.isFinite, Double(local) == stored else { return false }
                    number = stored
                default: return false
                }
                guard number.isFinite else { return false }
                // A conservative optional lane; no zero/negative preferred
                // line height is introduced as a newly supported shape.
                if key == Data("/LineHeight".utf8), number <= 0 { return false }
            }
        }
        return true
    }

    /// These are bibliographic document metadata, not marked-content text
    /// overrides. Only an ancestor whose resolved standard role is Document
    /// may retain this exact small conventional Info/XML shape unchanged.
    private func bodyTagDocumentInfo(_ value: CGPDFObjectRef, _ raw: EmberRawPDFObject) throws -> Bool {
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary else { return false }
        let entries = try bodyTagEntries(dictionary, raw)
        let allowed = Set(["Author", "CreationDate", "Creator", "Keywords", "ModDate", "Producer", "Subject", "Title"].map { Data(("/" + $0).utf8) })
        guard Set(entries.keys).isSubset(of: allowed), entries.count <= 8 else { return false }
        for (key, value) in entries {
            try PDFSaveCancellation.checkCurrent()
            let remote = try dictionaryValue(raw, key: key)
            try requireKind(remote, Int32(EMBER_RAW_PDF_STRING.rawValue))
            var text: CGPDFStringRef?
            guard CGPDFObjectGetType(value) == .string, CGPDFObjectGetValue(value, .string, &text), let text,
                  CGPDFStringGetLength(text) <= 4_096 else { return false }
            let count = CGPDFStringGetLength(text)
            let bytes = CGPDFStringGetBytePtr(text).map { Data(bytes: $0, count: count) } ?? Data()
            guard bytes.count == count,
                  bytes == (try copiedBytes { ember_raw_pdf_bounded_scalar_copy($0, remote, 4_096, &$1, &$2) }) else { return false }
        }
        return true
    }

    private func bodyTagDocumentMetadata(_ value: CGPDFObjectRef, _ raw: EmberRawPDFObject) throws -> Bool {
        try requireKind(raw, Int32(EMBER_RAW_PDF_STREAM.rawValue))
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetType(value) == .stream, CGPDFObjectGetValue(value, .stream, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return false }
        let rawDictionary = try object { ember_raw_pdf_stream_dictionary($0, raw, &$1) }
        let entries = try bodyTagEntries(dictionary, rawDictionary)
        let keys = Set(["Type", "Subtype", "Length"].map { Data(("/" + $0).utf8) })
        let filterKey = Data("/Filter".utf8)
        let hasFilter = entries[filterKey] != nil
        guard Set(entries.keys) == (hasFilter ? keys.union([filterKey]) : keys),
              let type = entries[Data("/Type".utf8)], let subtype = entries[Data("/Subtype".utf8)],
              try bodyTagName(type, dictionaryValue(rawDictionary, key: Data("/Type".utf8))) == Data("/Metadata".utf8),
              try bodyTagName(subtype, dictionaryValue(rawDictionary, key: Data("/Subtype".utf8))) == Data("/XML".utf8),
              let length = entries[Data("/Length".utf8)] else { return false }
        var localLength: CGPDFInteger = 0
        guard CGPDFObjectGetType(length) == .integer, CGPDFObjectGetValue(length, .integer, &localLength),
              localLength >= 0, localLength <= 65_536,
              try sourceInteger(dictionaryValue(rawDictionary, key: Data("/Length".utf8))) == localLength else { return false }
        let encoded = try signatureStreamBytes(raw, maximum: 65_536)
        guard encoded.count == localLength else { return false }
        let bytes: Data
        if let filter = entries[filterKey] {
            guard try bodyTagName(filter, dictionaryValue(rawDictionary, key: filterKey)) == Data("/FlateDecode".utf8)
            else { return false }
            bytes = try bodyTagInflatedMetadata(encoded)
        } else { bytes = encoded }
        // A scalar FlateDecode stream is fully checked under both byte caps
        // before the native decoder runs. Other filters and DecodeParms/F
        // fields are excluded by the exact dictionary shape above.
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format), format == .raw,
              CFDataGetLength(data) == bytes.count else { return false }
        let nativeBytes = CFDataGetBytePtr(data).map { Data(bytes: $0, count: CFDataGetLength(data)) } ?? Data()
        return bytes == nativeBytes
    }

    private func bodyTagInflatedMetadata(_ encoded: Data) throws -> Data {
        guard encoded.count <= 65_536 else { throw Unavailable.limit }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw Unavailable.mismatch }
        defer { inflateEnd(&stream) }
        return try encoded.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(input.count)
            var result = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                try PDFSaveCancellation.checkCurrent()
                let before = stream.avail_in
                let status = buffer.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let made = buffer.count - Int(stream.avail_out)
                guard made <= 65_536 - result.count else { throw Unavailable.limit }
                result.append(contentsOf: buffer.prefix(made))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw Unavailable.mismatch }
                    return result
                }
                guard status == Z_OK, made > 0 || stream.avail_in < before else { throw Unavailable.mismatch }
            }
        }
    }

    private func bodyTagParentArray(root: CGPDFDictionaryRef, key: Int) throws -> CGPDFArrayRef? {
        guard let tree = PDFCatalogStructurePreserver.dictionary(root, "ParentTree") else { return nil }
        var pending = [(tree, 0)], seen = Set<UInt>(), remaining = 500_000, found: CGPDFArrayRef?
        while let (node, depth) = pending.popLast() {
            try PDFSaveCancellation.checkCurrent()
            guard remaining > 0, depth < 64, seen.insert(pdfReferenceIdentity(node)).inserted else { throw Unavailable.limit }; remaining -= 1
            if let nums = PDFCatalogStructurePreserver.array(node, "Nums") {
                let count = CGPDFArrayGetCount(nums)
                guard count <= 200_000, count % 2 == 0, count <= remaining else { throw Unavailable.limit }; remaining -= count
                for index in stride(from: 0, to: count, by: 2) where try nativeInteger(nums, at: index) == key {
                    var array: CGPDFArrayRef?
                    guard found == nil, CGPDFArrayGetArray(nums, index + 1, &array), let array else { throw Unavailable.mismatch }
                    found = array
                }
            }
            if let kids = PDFCatalogStructurePreserver.array(node, "Kids") {
                let count = CGPDFArrayGetCount(kids)
                guard count <= 4_096, count <= remaining else { throw Unavailable.limit }; remaining -= count
                for index in 0..<count {
                    var child: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(kids, index, &child), let child else { throw Unavailable.mismatch }
                    pending.append((child, depth + 1))
                }
            }
        }
        return found
    }

    private func bodyTagContains(_ object: EmberRawPDFObject, child: EmberRawPDFObject,
                                 depth: Int, remaining: inout Int) throws -> Bool {
        guard remaining > 0, depth < 64 else { throw Unavailable.limit }; remaining -= 1
        if remaining & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
        var kind: Int32 = 0
        try checked(ember_raw_pdf_kind(context, object, &kind))
        if kind == Int32(EMBER_RAW_PDF_DICTIONARY.rawValue) { return object == child }
        guard kind == Int32(EMBER_RAW_PDF_ARRAY.rawValue) else { return false }
        var count: UInt32 = 0
        try checked(ember_raw_pdf_array_count(context, object, &count))
        guard count <= 100_000, Int(count) <= remaining else { throw Unavailable.limit }
        for index in 0..<count {
            let member = try self.object { ember_raw_pdf_array_item($0, object, index, &$1) }
            if try bodyTagContains(member, child: child, depth: depth + 1, remaining: &remaining) { return true }
        }
        return false
    }

    /// Bounded source-Form program bytes after complete exact page pairing.
    /// No extra parser, decoded resource or cross-context handle is published.
    func bodyTagEncodedProgram(for stream: CGPDFStreamRef, in owner: CGPDFDocument) throws -> Data? {
        try PDFSaveCancellation.checkCurrent()
        guard !Thread.isMainThread, provesExactFactoryOwner(owner), acquireLock() else { return nil }
        defer { lock.unlock() }
        guard !unavailable, context != nil, let object = streams[pdfReferenceIdentity(stream)] else { return nil }
        do { return try signatureStreamBytes(object, maximum: 2 * 1_024 * 1_024) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    /// Returns exact encoded bytes; the caller must retain the original Filter
    /// and DecodeParms dictionary values when writing them. No decoded bytes or
    /// partial native-pipeline output can escape this API.
    func payload(for stream: CGPDFStreamRef) throws -> Data? {
        try PDFSaveCancellation.checkCurrent()
        guard acquireLock() else { return nil }; defer { lock.unlock() }
        let key = pdfReferenceIdentity(stream)
        if let cached = cachedPayloads[key] {
            promotePayloadCache(key)
            #if DEBUG
            payloadCacheHits += 1
            #endif
            return cached
        }
        if streams[key] == nil { try prepareStructuralMetadata(for: stream) }
        guard !refusedPayloads.contains(key), let context, let object = streams[key] else { return nil }
        var bytes: UnsafeMutablePointer<UInt8>?, count = 0
        let status = ember_raw_pdf_stream_copy(context, object, Self.maximumStreamBytes, { _ in
            do { try PDFSaveCancellation.checkCurrent(); return 0 }
            catch { return 1 }
        }, nil, &bytes, &count)
        defer { if let bytes { ember_raw_pdf_free(bytes) } }
        if status == Int32(EMBER_RAW_PDF_CANCELLED.rawValue) { throw CancellationError() }
        try PDFSaveCancellation.checkCurrent()
        guard status == Int32(EMBER_RAW_PDF_OK.rawValue), count <= Self.maximumStreamBytes,
              count <= sourceByteCount + 1_024 * 1_024 - cachedByteCount,
              count == 0 || bytes != nil else {
            refusedPayloads.insert(key); return nil
        }
        let result = bytes.map { Data(bytes: $0, count: count) } ?? Data()
        #if DEBUG
        payloadCopies += 1
        #endif
        rememberPayload(result, key: key)
        return result
    }

    // Every cache operation runs under the existing source lock. Links are
    // value-only key IDs, so eviction cannot create a retaining node cycle.
    private func promotePayloadCache(_ key: UInt) {
        guard newestPayloadCacheKey != key, let links = payloadCacheLinks[key] else { return }
        if let older = links.older { payloadCacheLinks[older]?.newer = links.newer }
        else { oldestPayloadCacheKey = links.newer }
        if let newer = links.newer { payloadCacheLinks[newer]?.older = links.older }
        let previous = newestPayloadCacheKey
        if let previous { payloadCacheLinks[previous]?.newer = key }
        payloadCacheLinks[key] = PayloadCacheLinks(older: previous, newer: nil)
        newestPayloadCacheKey = key
        if oldestPayloadCacheKey == nil { oldestPayloadCacheKey = key }
    }

    private func rememberPayload(_ payload: Data, key: UInt) {
        guard payloadCacheByteLimit > 0, payload.count <= payloadCacheByteLimit else { return }
        while cachedByteCount > payloadCacheByteLimit - payload.count
            || cachedPayloads.count >= Self.maximumPayloadCacheEntries {
            guard let oldest = oldestPayloadCacheKey,
                  let evicted = cachedPayloads.removeValue(forKey: oldest),
                  let links = payloadCacheLinks.removeValue(forKey: oldest) else {
                // A cache bookkeeping failure cannot affect raw authority.
                clearPayloadCache(); return
            }
            cachedByteCount -= evicted.count
            oldestPayloadCacheKey = links.newer
            if let next = links.newer { payloadCacheLinks[next]?.older = nil }
            else { newestPayloadCacheKey = nil }
            #if DEBUG
            payloadCacheEvictions += 1
            #endif
        }
        let previous = newestPayloadCacheKey
        if let previous { payloadCacheLinks[previous]?.newer = key }
        cachedPayloads[key] = payload
        payloadCacheLinks[key] = PayloadCacheLinks(older: previous, newer: nil)
        newestPayloadCacheKey = key
        if oldestPayloadCacheKey == nil { oldestPayloadCacheKey = key }
        cachedByteCount += payload.count
    }

    private func clearPayloadCache() {
        cachedPayloads.removeAll(); payloadCacheLinks.removeAll()
        oldestPayloadCacheKey = nil; newestPayloadCacheKey = nil; cachedByteCount = 0
    }

    /// A payload miss can reach non-painting StructElem Metadata. This exact
    /// factory owns both graphs; no arbitrary dictionary or caller path is an
    /// authority. Main remains cache-only, and only a complete bounded K walk
    /// may publish the requested stream's ordinary full pairing transaction.
    private func prepareStructuralMetadata(for requested: CGPDFStreamRef) throws {
        func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
            var value: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, key, &value), let value,
                  strnlen(value, 65) <= 64 else { return nil }
            return String(cString: value)
        }
        guard !Thread.isMainThread, !unavailable, provesExactFactoryOwner(native),
              !structuralMetadataAbsenceProven,
              let requestedDictionary = CGPDFStreamGetDictionary(requested),
              name(requestedDictionary, "Type") == "Metadata",
              name(requestedDictionary, "Subtype") == "XML" else { return }
        do {
            guard try loadContext() else { return }
            let rawCatalog = try object { ember_raw_pdf_catalog($0, &$1) }
            let rawRoot = try dictionaryValue(rawCatalog, key: Data("/StructTreeRoot".utf8))
            guard try rawStructureMayContainMetadata(rawRoot) else {
                try PDFSaveCancellation.checkCurrent()
                structuralMetadataAbsenceProven = true
                return
            }
            // Positive authority still uses the original complete native/raw
            // transaction below. The precheck publishes no graph bindings.
            #if DEBUG
            structuralMetadataNativeWalks += 1
            #endif
            guard let catalog = native.catalog,
                  let root = PDFCatalogStructurePreserver.dictionary(catalog, "StructTreeRoot"),
                  let localKids = PDFCatalogStructurePreserver.object(root, "K") else { return }
            var pathProof = Pairing(), metadataProof = Pairing()
            // Revisit earlier partial container bindings, without ever pairing
            // scalars in this path-only transaction or publishing its aliases.
            pathProof.restoresSignatureTokens = true
            // Late payload lookup must not mint correction containers after
            // the writer built its index. Metadata scalars must pair exactly.
            try pairStoredDictionaryIdentity(root, rawRoot, transaction: &pathProof)
            let rawKids = try dictionaryValue(rawRoot, key: Data("/K".utf8))
            var pending = [(localKids, rawKids, 0)], found = false, seen = Set<NativeKey>()
            while let (local, raw, depth) = pending.popLast() {
                try visitNumberTree(depth: depth, transaction: &pathProof)
                switch CGPDFObjectGetType(local) {
                case .array:
                    let array = try pairedNumberTreeArray(local, raw, transaction: &pathProof)
                    let count = CGPDFArrayGetCount(array)
                    guard count <= Self.maximumVisits - pending.count else { throw Unavailable.limit }
                    // A repeated exact K alias is finite; all Metadata aliases
                    // still share one full transaction below before commit.
                    let key = NativeKey(kind: 6, identity: pdfReferenceIdentity(array))
                    guard seen.insert(key).inserted else { continue }
                    for index in (0..<count).reversed() {
                        var child: CGPDFObjectRef?
                        guard CGPDFArrayGetObject(array, index, &child), let child else { throw Unavailable.mismatch }
                        let other = try object { ember_raw_pdf_array_item($0, raw, UInt32(index), &$1) }
                        pending.append((child, other, depth + 1))
                    }
                case .dictionary:
                    var node: CGPDFDictionaryRef?
                    guard CGPDFObjectGetValue(local, .dictionary, &node), let node else { throw Unavailable.mismatch }
                    try pairStoredDictionaryIdentity(node, raw, transaction: &pathProof)
                    let id = pdfReferenceIdentity(node)
                    guard seen.insert(NativeKey(kind: 7, identity: id)).inserted else { continue }
                    let type = name(node, "Type")
                    if type == "MCR" || type == "OBJR" { continue }
                    guard (type == nil && !hasKey(node, "Type")) || type == "StructElem",
                          let role = PDFCatalogStructurePreserver.object(node, "S") else { throw Unavailable.mismatch }
                    let rawRole = try dictionaryValue(raw, key: Data("/S".utf8))
                    // A role is a scalar name; never follow P, Pg, Parent,
                    // annotation, resource, attribute or arbitrary backedges.
                    guard CGPDFObjectGetType(role) == .name else { throw Unavailable.mismatch }
                    try pair(role, rawRole, depth: depth, transaction: &pathProof)
                    if let value = PDFCatalogStructurePreserver.object(node, "Metadata") {
                        var stream: CGPDFStreamRef?
                        if CGPDFObjectGetType(value) == .stream,
                           CGPDFObjectGetValue(value, .stream, &stream), stream == requested {
                            let other = try dictionaryValue(raw, key: Data("/Metadata".utf8))
                            metadataProof.visits = pathProof.visits
                            try pair(value, other, depth: depth + 1, transaction: &metadataProof)
                            pathProof.visits = metadataProof.visits; found = true
                        }
                    }
                    let other = try dictionaryValue(raw, key: Data("/K".utf8))
                    if let kids = PDFCatalogStructurePreserver.object(node, "K") {
                        pending.append((kids, other, depth + 1))
                    } else { try requireKind(other, Int32(EMBER_RAW_PDF_NULL.rawValue)) }
                case .integer, .null:
                    // K's terminal MCIDs/nulls are checked, not traversed.
                    try pair(local, raw, depth: depth, transaction: &pathProof)
                default: throw Unavailable.mismatch
                }
            }
            guard found else { return }
            // Full Metadata aliases must also agree with every partial path
            // binding, but a path binding never becomes a general graph proof.
            for (key, value) in metadataProof.pairs {
                if let prior = pathProof.pairs[key], prior != value { throw Unavailable.ambiguous }
            }
            for (key, value) in metadataProof.reverse {
                if let prior = pathProof.reverse[key], prior != value { throw Unavailable.ambiguous }
            }
            try PDFSaveCancellation.checkCurrent()
            pairs.merge(metadataProof.pairs) { first, _ in first }
            reversePairs.merge(metadataProof.reverse) { first, _ in first }
            streams.merge(metadataProof.streams) { first, _ in first }
        } catch is CancellationError { throw CancellationError() }
        catch Unavailable.ambiguous { quarantine() }
        catch { /* No partial pairing or negative cache from a failed proof. */ }
    }

    /// Negative filter only: inspect raw K edges before asking CoreGraphics
    /// to materialize potentially expensive object streams. Every dictionary
    /// reachable by K is checked, including MCR/OBJR dictionaries. A nonnull
    /// Metadata value conservatively keeps the original positive proof path.
    /// Completion proves only absence; malformed/limited/cancelled walks throw
    /// without setting the source-owned cache or publishing any Pairing.
    private func rawStructureMayContainMetadata(_ rawRoot: EmberRawPDFObject) throws -> Bool {
        #if DEBUG
        structuralMetadataRawWalks += 1
        #endif
        var kind: Int32 = 0
        try checked(ember_raw_pdf_kind(context, rawRoot, &kind))
        if kind == Int32(EMBER_RAW_PDF_NULL.rawValue) { return false }
        try requireKind(rawRoot, Int32(EMBER_RAW_PDF_DICTIONARY.rawValue))
        let kids = try dictionaryValue(rawRoot, key: Data("/K".utf8))
        var pending = [(object: kids, depth: 0, leaving: false)]
        var active = Set<EmberRawPDFObject>(), completed = Set<EmberRawPDFObject>()
        var visits = 0
        while let entry = pending.popLast() {
            if entry.leaving {
                active.remove(entry.object); completed.insert(entry.object)
                continue
            }
            visits += 1
            guard entry.depth < 64, visits <= Self.maximumVisits else { throw Unavailable.limit }
            #if DEBUG
            Self.structuralMetadataRawVisitObserver?(visits)
            #endif
            try PDFSaveCancellation.checkCurrent()
            try checked(ember_raw_pdf_kind(context, entry.object, &kind))
            switch kind {
            case Int32(EMBER_RAW_PDF_ARRAY.rawValue), Int32(EMBER_RAW_PDF_DICTIONARY.rawValue):
                if completed.contains(entry.object) { continue }
                guard active.insert(entry.object).inserted else { throw Unavailable.mismatch }
                if kind == Int32(EMBER_RAW_PDF_ARRAY.rawValue) {
                    guard pending.count < Self.maximumVisits else { throw Unavailable.limit }
                    pending.append((entry.object, entry.depth, true))
                    var count: UInt32 = 0
                    try checked(ember_raw_pdf_array_count(context, entry.object, &count))
                    guard pending.count <= Self.maximumVisits,
                          Int(count) <= Self.maximumVisits - pending.count else { throw Unavailable.limit }
                    for index in (0..<count).reversed() {
                        let child = try object { ember_raw_pdf_array_item($0, entry.object, index, &$1) }
                        pending.append((child, entry.depth + 1, false))
                    }
                } else {
                    // Reserve BOTH the exit marker and next K before either
                    // push; a nearly full sibling array leaves no spare slot.
                    guard pending.count <= Self.maximumVisits - 2 else { throw Unavailable.limit }
                    pending.append((entry.object, entry.depth, true))
                    let metadata = try dictionaryValue(entry.object, key: Data("/Metadata".utf8))
                    var metadataKind: Int32 = 0
                    try checked(ember_raw_pdf_kind(context, metadata, &metadataKind))
                    if metadataKind != Int32(EMBER_RAW_PDF_NULL.rawValue) { return true }
                    let next = try dictionaryValue(entry.object, key: Data("/K".utf8))
                    pending.append((next, entry.depth + 1, false))
                }
                #if DEBUG
                structuralMetadataMaximumPending = max(structuralMetadataMaximumPending, pending.count)
                #endif
            case Int32(EMBER_RAW_PDF_INTEGER.rawValue), Int32(EMBER_RAW_PDF_NULL.rawValue):
                break
            default: throw Unavailable.mismatch
            }
        }
        try PDFSaveCancellation.checkCurrent()
        return false
    }

    struct NumberCorrectionContainers {
        let dictionaries: Set<UInt>
        let arrays: Set<UInt>
    }

    /// Used once after all painting roots have been prepared. This exports
    /// candidate identities only, never a detached numeric authority. A later
    /// query still checks this source's lock/quarantine and current slot bits.
    func numberCorrectionContainers() throws -> NumberCorrectionContainers? {
        try PDFSaveCancellation.checkCurrent()
        guard numberAuthority != nil, acquireLock() else { return nil }; defer { lock.unlock() }
        guard context != nil, !unavailable else { return nil }
        var dictionaries = Set<UInt>(), arrays = Set<UInt>()
        for (offset, slot) in Set(numberCorrections.keys).union(signatureNumbers.keys).enumerated() {
            if offset & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            switch slot {
            case .dictionary(let identity, _): dictionaries.insert(identity)
            case .array(let identity, _): arrays.insert(identity)
            }
        }
        return NumberCorrectionContainers(dictionaries: dictionaries, arrays: arrays)
    }

    /// Cache-only on every thread, including Main. A complete painting
    /// transaction published each correction; this lookup does not call QPDF,
    /// initialize a parser, or read an input. A changed slot keeps its value.
    func originalNumber(in dictionary: CGPDFDictionaryRef, key: UnsafePointer<CChar>) throws -> PDFCatalogGraphValue? {
        try PDFSaveCancellation.checkCurrent()
        guard numberAuthority != nil, acquireLock() else { return nil }; defer { lock.unlock() }
        guard context != nil, !unavailable, !numberCorrections.isEmpty else { return nil }
        let count = strnlen(key, 4096)
        guard count < 4096 else { return nil }
        var name = Data([47]); name.append(contentsOf: UnsafeRawBufferPointer(start: key, count: count))
        guard let correction = numberCorrections[.dictionary(pdfReferenceIdentity(dictionary), name)] else { return nil }
        var current: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, key, &current), let current else { return nil }
        return correctedNumber(current, correction: correction)
    }

    func originalNumber(in array: CGPDFArrayRef, index: Int) throws -> PDFCatalogGraphValue? {
        try PDFSaveCancellation.checkCurrent()
        guard numberAuthority != nil, acquireLock() else { return nil }; defer { lock.unlock() }
        guard context != nil, !unavailable, index >= 0, index < CGPDFArrayGetCount(array),
              let correction = numberCorrections[.array(pdfReferenceIdentity(array), index)] else { return nil }
        var current: CGPDFObjectRef?
        guard CGPDFArrayGetObject(array, index, &current), let current else { return nil }
        return correctedNumber(current, correction: correction)
    }

    private func correctedNumber(_ current: CGPDFObjectRef, correction: NumberCorrection) -> PDFCatalogGraphValue? {
        var value: CGPDFReal = 0
        guard CGPDFObjectGetType(current) == .real, CGPDFObjectGetValue(current, .real, &value),
              value.isFinite, Double(value).bitPattern == correction.parsedBits else { return nil }
        return .real(correction.original)
    }

    /// The number tree is paired from this exact retained parser's own catalog,
    /// never by comparing an arbitrary caller array's shape. Once key, identity
    /// and count agree, QPDF validates EVERY original slot as null/dictionary in
    /// one native call. This is a second parser of the same immutable bytes,
    /// not a shortcut that assumes skipped native slots were valid nulls.
    func parentArrayMemberIndices(for array: CGPDFArrayRef, key: Int,
                                  in document: CGPDFDocument) throws -> [Int]? {
        try PDFSaveCancellation.checkCurrent()
        guard document === native, key >= 0 else { return nil }
        guard acquireLock() else { return nil }; defer { lock.unlock() }
        guard !parentArraysUnavailable, try loadContext() else { return nil }
        do {
            if parentArrays == nil { parentArrays = try pairedParentArrays() }
            let identity = pdfReferenceIdentity(array)
            guard let binding = parentArrays?[key], binding.nativeIdentity == identity,
                  binding.count == CGPDFArrayGetCount(array), binding.count <= 100_000 else { return nil }
            if let cached = cachedParentIndices[identity] { return cached }
            var sourceCount: UInt32 = 0
            try checked(ember_raw_pdf_array_count(context, binding.original, &sourceCount))
            guard Int(sourceCount) == binding.count else { throw Unavailable.mismatch }
            var indices: UnsafeMutablePointer<UInt32>?, count = 0
            let status = ember_raw_pdf_sparse_parent_members(context, binding.original, UInt32(binding.count), { _ in
                do { try PDFSaveCancellation.checkCurrent(); return 0 }
                catch { return 1 }
            }, nil, &indices, &count)
            defer { if let indices { ember_raw_pdf_indices_free(indices) } }
            try checked(status)
            try PDFSaveCancellation.checkCurrent()
            guard count <= binding.count, count == 0 || indices != nil else { throw Unavailable.mismatch }
            let result = indices.map { Array(UnsafeBufferPointer(start: $0, count: count)).map(Int.init) } ?? []
            var previous = -1
            for (offset, index) in result.enumerated() {
                if offset & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                guard index > previous, index < binding.count else { throw Unavailable.mismatch }
                previous = index
            }
            if result.count <= Self.maximumVisits - cachedParentIndexCount {
                cachedParentIndices[identity] = result; cachedParentIndexCount += result.count
            }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch Unavailable.ambiguous { quarantine(); return nil }
        catch {
            parentArraysUnavailable = true; parentArrays = nil
            cachedParentIndices.removeAll(); cachedParentIndexCount = 0
            return nil
        }
    }

    /// Full-document writers already deduplicate each encoded stream. Keep
    /// the immutable parser for a future save, but release temporary payload
    /// copies once this writer ends so many open books cannot retain a second
    /// whole encoded image set each. Another writer's local Data stays valid.
    func releaseCachedPayloads() {
        guard acquireLock() else { return }; defer { lock.unlock() }
        clearPayloadCache()
    }

    private func pairedParentArrays() throws -> [Int: ParentArrayBinding] {
        guard let catalog = native.catalog else { throw Unavailable.mismatch }
        var nativeRoot: CGPDFDictionaryRef?, nativeTree: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "StructTreeRoot", &nativeRoot), let nativeRoot,
              CGPDFDictionaryGetDictionary(nativeRoot, "ParentTree", &nativeTree), let nativeTree else { throw Unavailable.mismatch }
        let sourceCatalog = try object { ember_raw_pdf_catalog($0, &$1) }
        let sourceRoot = try dictionaryValue(sourceCatalog, key: Data("/StructTreeRoot".utf8))
        try requireKind(sourceRoot, Int32(EMBER_RAW_PDF_DICTIONARY.rawValue))
        let sourceTree = try dictionaryValue(sourceRoot, key: Data("/ParentTree".utf8))
        try requireKind(sourceTree, Int32(EMBER_RAW_PDF_DICTIONARY.rawValue))
        var bindings: [Int: ParentArrayBinding] = [:], keys = Set<Int>()
        var nativeNodes = Set<UInt>(), sourceNodes = Set<EmberRawPDFObject>(), transaction = Pairing()
        _ = try pairNumberTree(nativeTree, sourceTree, depth: 0, bindings: &bindings, keys: &keys,
                               nativeNodes: &nativeNodes, sourceNodes: &sourceNodes, transaction: &transaction)
        // These aliases establish number-tree shape, not recursively validated
        // painting dictionaries. Do not publish them into the painting cache.
        return bindings
    }

    private func pairNumberTree(_ node: CGPDFDictionaryRef, _ original: EmberRawPDFObject,
                                depth: Int, bindings: inout [Int: ParentArrayBinding], keys: inout Set<Int>,
                                nativeNodes: inout Set<UInt>, sourceNodes: inout Set<EmberRawPDFObject>,
                                transaction: inout Pairing) throws -> (Int, Int)? {
        try visitNumberTree(depth: depth, transaction: &transaction)
        let identity = pdfReferenceIdentity(node)
        guard nativeNodes.insert(identity).inserted, sourceNodes.insert(original).inserted else { throw Unavailable.ambiguous }
        _ = try begin(NativeKey(kind: 7, identity: identity), original, transaction: &transaction)
        try requireKind(original, Int32(EMBER_RAW_PDF_DICTIONARY.rawValue))
        let values = try dictionaryEntries(node), sourceNames = try sourceKeys(original)
        let typeKey = Data("/Type".utf8)
        let permitted = Set([Data("/Kids".utf8), Data("/Nums".utf8), Data("/Limits".utf8), typeKey])
        guard Set(values.keys) == sourceNames, sourceNames.isSubset(of: permitted) else { throw Unavailable.mismatch }
        if let type = values[typeKey] {
            guard depth == 0, try bodyTagName(type, dictionaryValue(original, key: typeKey)) == Data("/ParentTree".utf8)
            else { throw Unavailable.mismatch }
        }
        let nums = values[Data("/Nums".utf8)], kids = values[Data("/Kids".utf8)]
        guard (nums != nil) != (kids != nil) else { throw Unavailable.mismatch }
        var range: (Int, Int)?
        if let nums {
            let remote = try dictionaryValue(original, key: Data("/Nums".utf8))
            let array = try pairedNumberTreeArray(nums, remote, transaction: &transaction)
            let count = CGPDFArrayGetCount(array)
            guard count % 2 == 0, count <= Self.maximumVisits else { throw Unavailable.limit }
            var previous: Int?
            for offset in stride(from: 0, to: count, by: 2) {
                try visitNumberTree(depth: depth, transaction: &transaction)
                let localKey = try nativeInteger(array, at: offset)
                let sourceKey = try object { ember_raw_pdf_array_item($0, remote, UInt32(offset), &$1) }
                guard localKey >= 0, try sourceInteger(sourceKey) == localKey,
                      keys.count < 100_000, keys.insert(localKey).inserted,
                      previous.map({ localKey > $0 }) ?? true else { throw Unavailable.mismatch }
                previous = localKey
                if let current = range { range = (current.0, localKey) } else { range = (localKey, localKey) }
                var value: CGPDFObjectRef?
                guard CGPDFArrayGetObject(array, offset + 1, &value), let value else { throw Unavailable.mismatch }
                let other = try object { ember_raw_pdf_array_item($0, remote, UInt32(offset + 1), &$1) }
                switch CGPDFObjectGetType(value) {
                case .array:
                    let members = try pairedNumberTreeArray(value, other, transaction: &transaction)
                    let slots = CGPDFArrayGetCount(members)
                    guard slots <= 100_000 else { throw Unavailable.limit }
                    bindings[localKey] = ParentArrayBinding(nativeIdentity: pdfReferenceIdentity(members), original: other, count: slots)
                case .dictionary:
                    var dictionary: CGPDFDictionaryRef?
                    guard CGPDFObjectGetValue(value, .dictionary, &dictionary), let dictionary else { throw Unavailable.mismatch }
                    try requireKind(other, Int32(EMBER_RAW_PDF_DICTIONARY.rawValue))
                    _ = try begin(NativeKey(kind: 7, identity: pdfReferenceIdentity(dictionary)), other, transaction: &transaction)
                default: throw Unavailable.mismatch
                }
            }
        } else if let kids {
            let remote = try dictionaryValue(original, key: Data("/Kids".utf8))
            let array = try pairedNumberTreeArray(kids, remote, transaction: &transaction)
            let count = CGPDFArrayGetCount(array)
            guard count <= Self.maximumVisits else { throw Unavailable.limit }
            for offset in 0..<count {
                var child: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(array, offset, &child), let child else { throw Unavailable.mismatch }
                let other = try object { ember_raw_pdf_array_item($0, remote, UInt32(offset), &$1) }
                let childRange = try pairNumberTree(child, other, depth: depth + 1, bindings: &bindings, keys: &keys,
                                                    nativeNodes: &nativeNodes, sourceNodes: &sourceNodes, transaction: &transaction)
                if let childRange {
                    if let current = range {
                        guard childRange.0 > current.1 else { throw Unavailable.mismatch }
                        range = (current.0, childRange.1)
                    } else { range = childRange }
                }
            }
        }
        if let limits = values[Data("/Limits".utf8)] {
            let remote = try dictionaryValue(original, key: Data("/Limits".utf8))
            let array = try pairedNumberTreeArray(limits, remote, transaction: &transaction)
            guard CGPDFArrayGetCount(array) == 2, let range else { throw Unavailable.mismatch }
            let low = try nativeInteger(array, at: 0), high = try nativeInteger(array, at: 1)
            let sourceLow = try object { ember_raw_pdf_array_item($0, remote, 0, &$1) }
            let sourceHigh = try object { ember_raw_pdf_array_item($0, remote, 1, &$1) }
            guard low == range.0, high == range.1,
                  try sourceInteger(sourceLow) == low, try sourceInteger(sourceHigh) == high else { throw Unavailable.mismatch }
        }
        return range
    }

    private func pairedNumberTreeArray(_ value: CGPDFObjectRef, _ original: EmberRawPDFObject,
                                       transaction: inout Pairing) throws -> CGPDFArrayRef {
        var array: CGPDFArrayRef?, count: UInt32 = 0
        guard CGPDFObjectGetType(value) == .array, CGPDFObjectGetValue(value, .array, &array), let array else { throw Unavailable.mismatch }
        try requireKind(original, Int32(EMBER_RAW_PDF_ARRAY.rawValue))
        try checked(ember_raw_pdf_array_count(context, original, &count))
        guard CGPDFArrayGetCount(array) == Int(count) else { throw Unavailable.mismatch }
        _ = try begin(NativeKey(kind: 6, identity: pdfReferenceIdentity(array)), original, transaction: &transaction)
        return array
    }

    private func nativeInteger(_ array: CGPDFArrayRef, at index: Int) throws -> Int {
        var object: CGPDFObjectRef?, value: CGPDFInteger = 0
        guard CGPDFArrayGetObject(array, index, &object), let object, CGPDFObjectGetType(object) == .integer,
              CGPDFObjectGetValue(object, .integer, &value) else { throw Unavailable.mismatch }
        return Int(value)
    }

    private func sourceInteger(_ object: EmberRawPDFObject) throws -> Int {
        try requireKind(object, Int32(EMBER_RAW_PDF_INTEGER.rawValue))
        var value: Int64 = 0
        try checked(ember_raw_pdf_integer(context, object, &value))
        guard let result = Int(exactly: value) else { throw Unavailable.limit }; return result
    }

    private func requireKind(_ object: EmberRawPDFObject, _ expected: Int32) throws {
        var kind: Int32 = 0; try checked(ember_raw_pdf_kind(context, object, &kind))
        guard kind == expected else { throw Unavailable.mismatch }
    }

    private func visitNumberTree(depth: Int, transaction: inout Pairing) throws {
        transaction.visits += 1
        if transaction.visits & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
        guard depth < 64, transaction.visits <= Self.maximumVisits else { throw Unavailable.limit }
    }

    private func loadContext() throws -> Bool {
        if context != nil { return true }
        guard !unavailable else { return false }
        try PDFSaveCancellation.checkCurrent()
        if case let .file(url, expected) = input, expected.fileSize > UInt64(Self.maximumSourceBytes) {
            return try loadFileContext(url: url, expected: expected)
        }
        do {
            let bytes: Data
            switch input {
            case let .bytes(data): bytes = data
            case let .file(url, expected):
                guard try PDFSourceFileVersion.capture(at: url) == expected else { throw Unavailable.mismatch }
                // An owned read, never a mutable mapping of a file later saved.
                bytes = try readBounded(url)
                guard bytes.count <= Self.maximumSourceBytes,
                      UInt64(bytes.count) == expected.fileSize,
                      try PDFSourceFileVersion.capture(at: url) == expected else { throw Unavailable.mismatch }
            case .consumed: throw Unavailable.mismatch
            }
            try PDFSaveCancellation.checkCurrent()
            var status: Int32 = 0
            context = bytes.withUnsafeBytes {
                ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                                     Self.maximumSourceBytes, Self.maximumObjects, &status)
            }
            guard status == Int32(EMBER_RAW_PDF_OK.rawValue), context != nil else { throw Unavailable.mismatch }
            var count: UInt32 = 0
            try checked(ember_raw_pdf_page_count(context, &count))
            guard Int(count) == native.numberOfPages else { throw Unavailable.mismatch }
            sourceByteCount = bytes.count; input = .consumed
            return true
        } catch is CancellationError { throw CancellationError() }
        catch {
            if let context { ember_raw_pdf_destroy(context); self.context = nil }
            unavailable = true; input = .consumed
            return false
        }
    }

    private func loadFileContext(url: URL, expected: PDFSourceFileVersion) throws -> Bool {
        // Never materialize a whole large input, including widget/signature
        // independent-reader fallbacks. Their original Data limit stays256MiB.
        do {
            guard let snapshot = try PDFRawFileSnapshot.create(url: url, expected: expected) else {
                throw Unavailable.limit
            }
            var status: Int32 = 0
            context = ember_raw_pdf_create_snapshot(snapshot.descriptor, snapshot.byteCount,
                Int(PDFRawFileSnapshot.maximumFileBytes), Self.maximumObjects, { _ in
                    do { try PDFSaveCancellation.checkCurrent(); return 0 } catch { return 1 }
                }, nil, &status)
            snapshot.closeDescriptor()
            if status == Int32(EMBER_RAW_PDF_CANCELLED.rawValue) { throw CancellationError() }
            guard status == Int32(EMBER_RAW_PDF_OK.rawValue), context != nil else { throw Unavailable.mismatch }
            var count: UInt32 = 0
            try checked(ember_raw_pdf_page_count(context, &count))
            guard Int(count) == native.numberOfPages else { throw Unavailable.mismatch }
            try PDFSaveCancellation.checkCurrent()
            sourceByteCount = snapshot.byteCount; fileSnapshot = snapshot; input = .consumed
            return true
        } catch {
            if let context { ember_raw_pdf_destroy(context); self.context = nil }
            if error is CancellationError { throw error }
            if let changed = error as? WorkspaceError { throw changed }
            unavailable = true; input = .consumed
            return false
        }
    }

    private func pair(_ nativeObject: CGPDFObjectRef, _ original: EmberRawPDFObject,
                      depth: Int, transaction: inout Pairing, numberSlot: NumberSlot? = nil) throws {
        transaction.visits += 1
        if transaction.visits & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
        guard depth < 64, transaction.visits <= Self.maximumVisits else { throw Unavailable.limit }
        var kind: Int32 = 0
        try checked(ember_raw_pdf_kind(context, original, &kind))
        let type = CGPDFObjectGetType(nativeObject)
        switch type {
        case .null: guard kind == Int32(EMBER_RAW_PDF_NULL.rawValue) else { throw Unavailable.mismatch }
        case .boolean:
            var left: CGPDFBoolean = 0, right: Int32 = 0
            guard kind == Int32(EMBER_RAW_PDF_BOOLEAN.rawValue), CGPDFObjectGetValue(nativeObject, type, &left) else { throw Unavailable.mismatch }
            try checked(ember_raw_pdf_boolean(context, original, &right))
            guard (left != 0) == (right != 0) else { throw Unavailable.mismatch }
        case .integer:
            var left: CGPDFInteger = 0, right: Int64 = 0
            guard kind == Int32(EMBER_RAW_PDF_INTEGER.rawValue), CGPDFObjectGetValue(nativeObject, type, &left) else { throw Unavailable.mismatch }
            try checked(ember_raw_pdf_integer(context, original, &right))
            guard Int64(left) == right else { throw Unavailable.mismatch }
            if transaction.restoresSignatureTokens, let numberSlot {
                try rememberSignatureNumber(numberSlot, object: original, kind: .integer,
                    parsedBits: 0, integer: right, transaction: &transaction)
            }
        case .real:
            var left: CGPDFReal = 0, right: Double = 0
            guard kind == Int32(EMBER_RAW_PDF_REAL.rawValue), CGPDFObjectGetValue(nativeObject, type, &left) else { throw Unavailable.mismatch }
            try checked(ember_raw_pdf_real(context, original, &right))
            guard left.isFinite, right.isFinite else { throw Unavailable.mismatch }
            if transaction.restoresSignatureTokens, let numberSlot {
                try rememberSignatureNumber(numberSlot, object: original, kind: .real,
                    parsedBits: Double(left).bitPattern, integer: nil, transaction: &transaction)
            }
            if Double(left) != right {
                guard transaction.restoresOriginalNumbers, let numberSlot else { throw Unavailable.mismatch }
                try rememberNumberCorrection(numberSlot, parsed: Double(left), original: right, transaction: &transaction)
            }
        case .name:
            var name: UnsafePointer<CChar>?
            guard kind == Int32(EMBER_RAW_PDF_NAME.rawValue), CGPDFObjectGetValue(nativeObject, type, &name), let name else { throw Unavailable.mismatch }
            var left = Data([47]); left.append(contentsOf: UnsafeRawBufferPointer(start: name, count: strlen(name)))
            guard left == (try copiedBytes { ember_raw_pdf_name_copy($0, original, &$1, &$2) }) else { throw Unavailable.mismatch }
        case .string:
            var string: CGPDFStringRef?
            guard kind == Int32(EMBER_RAW_PDF_STRING.rawValue), CGPDFObjectGetValue(nativeObject, type, &string), let string else { throw Unavailable.mismatch }
            let count = CGPDFStringGetLength(string)
            guard count <= Self.maximumStreamBytes else { throw Unavailable.limit }
            let left = CGPDFStringGetBytePtr(string).map { Data(bytes: $0, count: count) } ?? Data()
            guard left.count == count,
                  left == (try copiedBytes { ember_raw_pdf_string_copy($0, original, &$1, &$2) }) else { throw Unavailable.mismatch }
        case .array:
            var array: CGPDFArrayRef?
            guard kind == Int32(EMBER_RAW_PDF_ARRAY.rawValue), CGPDFObjectGetValue(nativeObject, type, &array), let array else { throw Unavailable.mismatch }
            let arrayKey = NativeKey(kind: 6, identity: pdfReferenceIdentity(array))
            guard try begin(arrayKey, original, transaction: &transaction) else { return }
            var count: UInt32 = 0
            try checked(ember_raw_pdf_array_count(context, original, &count))
            guard Int(count) == CGPDFArrayGetCount(array), Int(count) <= Self.maximumVisits else { throw Unavailable.mismatch }
            for index in 0..<Int(count) {
                var value: CGPDFObjectRef?
                guard CGPDFArrayGetObject(array, index, &value), let value else { throw Unavailable.mismatch }
                let other = try object { ember_raw_pdf_array_item($0, original, UInt32(index), &$1) }
                let slot: NumberSlot? = transaction.restoresOriginalNumbers ? .array(arrayKey.identity, index) : nil
                try pair(value, other, depth: depth + 1, transaction: &transaction, numberSlot: slot)
            }
        case .dictionary:
            var dictionary: CGPDFDictionaryRef?
            guard kind == Int32(EMBER_RAW_PDF_DICTIONARY.rawValue), CGPDFObjectGetValue(nativeObject, type, &dictionary), let dictionary else { throw Unavailable.mismatch }
            guard try begin(NativeKey(kind: 7, identity: pdfReferenceIdentity(dictionary)), original, transaction: &transaction) else { return }
            try pairDictionary(dictionary, original, depth: depth, transaction: &transaction)
        case .stream:
            var stream: CGPDFStreamRef?
            guard kind == Int32(EMBER_RAW_PDF_STREAM.rawValue), CGPDFObjectGetValue(nativeObject, type, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream), !hasKey(dictionary, "F") else { throw Unavailable.mismatch }
            let key = pdfReferenceIdentity(stream)
            guard try begin(NativeKey(kind: 8, identity: key), original, transaction: &transaction) else { return }
            let other = try object { ember_raw_pdf_stream_dictionary($0, original, &$1) }
            try pairDictionary(dictionary, other, depth: depth, transaction: &transaction)
            transaction.streams[key] = original
        @unknown default: throw Unavailable.mismatch
        }
    }

    private func readBounded(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while true {
            try PDFSaveCancellation.checkCurrent()
            let chunk = try handle.read(upToCount: min(1_024 * 1_024, Self.maximumSourceBytes - result.count + 1)) ?? Data()
            if chunk.isEmpty { return result }
            guard chunk.count <= Self.maximumSourceBytes - result.count else { throw Unavailable.limit }
            result.append(chunk)
        }
    }

    private func begin(_ key: NativeKey, _ original: EmberRawPDFObject,
                       transaction: inout Pairing) throws -> Bool {
        if let previous = transaction.pairs[key] {
            guard previous == original else { throw Unavailable.ambiguous }; return false
        }
        if let previous = pairs[key] {
            guard previous == original else { throw Unavailable.ambiguous }
            // An earlier ordinary painting proof did not mint exact numeric
            // tokens. Traverse its already matched graph once in this AP
            // transaction, with its own cycle/visit and aggregate budget.
            guard transaction.restoresSignatureTokens else { return false }
            transaction.pairs[key] = original; transaction.reverse[original] = key
            return true
        }
        if let previous = transaction.reverse[original] ?? reversePairs[original], previous != key { throw Unavailable.ambiguous }
        transaction.pairs[key] = original; transaction.reverse[original] = key
        return true
    }

    private func pairDictionary(_ dictionary: CGPDFDictionaryRef, _ original: EmberRawPDFObject,
                                depth: Int, transaction: inout Pairing) throws {
        let values = try dictionaryEntries(dictionary)
        var count: UInt32 = 0
        try checked(ember_raw_pdf_dictionary_count(context, original, &count))
        guard values.count == Int(count), Int(count) <= Self.maximumVisits else { throw Unavailable.mismatch }
        var remote: [Data: EmberRawPDFObject] = [:]
        for index in 0..<count {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            let key = try copiedBytes { ember_raw_pdf_dictionary_key_copy($0, original, index, &$1, &$2) }
            guard key.first == 47, !key.dropFirst().contains(0), remote[key] == nil else { throw Unavailable.mismatch }
            remote[key] = try dictionaryValue(original, key: key)
        }
        for (key, value) in values {
            guard let other = remote.removeValue(forKey: key) else { throw Unavailable.mismatch }
            let slot: NumberSlot? = transaction.restoresOriginalNumbers ? .dictionary(pdfReferenceIdentity(dictionary), key) : nil
            try pair(value, other, depth: depth + 1, transaction: &transaction, numberSlot: slot)
        }
        guard remote.isEmpty else { throw Unavailable.mismatch }
    }

    private func rememberSignatureNumber(_ slot: NumberSlot, object: EmberRawPDFObject,
                                         kind: CGPDFObjectType, parsedBits: UInt64, integer: Int64?, transaction: inout Pairing) throws {
        let bytes = try copiedBytes { ember_raw_pdf_number_token_copy($0, object, &$1, &$2) }
        guard let token = String(data: bytes, encoding: .ascii), !token.isEmpty, token.utf8.count <= 128 else { throw Unavailable.mismatch }
        let value = SignatureNumber(nativeKind: kind, parsedBits: parsedBits, integer: integer, token: token)
        if let prior = transaction.signatureNumbers[slot] ?? signatureNumbers[slot] {
            guard prior.nativeKind == kind, prior.parsedBits == parsedBits, prior.integer == integer, prior.token == token else { throw Unavailable.ambiguous }
            return
        }
        guard signatureNumbers.count + transaction.signatureNumbers.count < 16_384,
              value.bytes + slot.accountedBytes <= 1_024 * 1_024 - signatureNumberBytes - transaction.signatureNumberBytes else { throw Unavailable.limit }
        transaction.signatureNumbers[slot] = value
        transaction.signatureNumberBytes += value.bytes + slot.accountedBytes
    }

    /// Cache-only, typed immutable-slot lookup. These strings are minted only
    /// by bounded numeric-token pairing and cannot contain PDF syntax other
    /// than one validated scalar. Native kind/bits still have to match now.
    func signatureNumberToken(in array: CGPDFArrayRef, index: Int) throws -> String? {
        guard acquireLock() else { return nil }; defer { lock.unlock() }
        guard !unavailable, context != nil, let entry = signatureNumbers[.array(pdfReferenceIdentity(array), index)] else { return nil }
        var object: CGPDFObjectRef?
        guard CGPDFArrayGetObject(array, index, &object), let object else { return nil }
        return signatureNumberToken(entry, matches: object)
    }
    func signatureNumberToken(in dictionary: CGPDFDictionaryRef, key: UnsafePointer<CChar>) throws -> String? {
        guard acquireLock() else { return nil }; defer { lock.unlock() }
        guard !unavailable, context != nil, strnlen(key, 4_097) <= 4_096 else { return nil }
        var name = Data([47]); name.append(contentsOf: UnsafeRawBufferPointer(start: key, count: strlen(key)))
        guard let entry = signatureNumbers[.dictionary(pdfReferenceIdentity(dictionary), name)] else { return nil }
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, key, &object), let object else { return nil }
        return signatureNumberToken(entry, matches: object)
    }
    private func signatureNumberToken(_ entry: SignatureNumber, matches object: CGPDFObjectRef) -> String? {
        guard CGPDFObjectGetType(object) == entry.nativeKind else { return nil }
        if entry.nativeKind == .integer {
            var value: CGPDFInteger = 0
            return CGPDFObjectGetValue(object, .integer, &value) && Int64(value) == entry.integer ? entry.token : nil
        }
        var value: CGPDFReal = 0
        return CGPDFObjectGetValue(object, .real, &value) && Double(value).bitPattern == entry.parsedBits ? entry.token : nil
    }

    private func rememberNumberCorrection(_ slot: NumberSlot, parsed: Double, original: Double,
                                          transaction: inout Pairing) throws {
        let correction = NumberCorrection(parsedBits: parsed.bitPattern, original: original)
        if let previous = transaction.numberCorrections[slot] ?? numberCorrections[slot] {
            guard previous == correction else { throw Unavailable.ambiguous }
            return
        }
        if case .dictionary(_, let key) = slot, key.count > 4096 { throw Unavailable.limit }
        let bytes = slot.accountedBytes
        guard numberCorrections.count < Self.maximumNumberCorrections - transaction.numberCorrections.count,
              bytes <= Self.maximumNumberCorrectionBytes - numberCorrectionBytes - transaction.numberCorrectionBytes else {
            throw Unavailable.limit
        }
        transaction.numberCorrections[slot] = correction
        transaction.numberCorrectionBytes += bytes
    }

    private func nativeRoot(_ page: CGPDFDictionaryRef, name: String, inherited: Bool) throws -> CGPDFObjectRef? {
        var node = page, seen = Set<UInt>()
        for _ in 0..<64 {
            guard seen.insert(pdfReferenceIdentity(node)).inserted else { throw Unavailable.mismatch }
            var value: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(node, name, &value) { return value }
            var parent: CGPDFDictionaryRef?
            guard inherited, CGPDFDictionaryGetDictionary(node, "Parent", &parent), let parent else { return nil }
            node = parent
        }
        throw Unavailable.limit
    }

    private func sourceRoot(_ page: EmberRawPDFObject, name: String, inherited: Bool) throws -> EmberRawPDFObject? {
        var node = page, seen = Set<EmberRawPDFObject>()
        for _ in 0..<64 {
            guard seen.insert(node).inserted else { throw Unavailable.mismatch }
            let keys = try sourceKeys(node)
            let key = Data(("/" + name).utf8)
            if keys.contains(key) { return try dictionaryValue(node, key: key) }
            let parent = Data("/Parent".utf8)
            guard inherited, keys.contains(parent) else { return nil }
            node = try dictionaryValue(node, key: parent)
        }
        throw Unavailable.limit
    }

    private func sourceKeys(_ object: EmberRawPDFObject) throws -> Set<Data> {
        var count: UInt32 = 0
        try checked(ember_raw_pdf_dictionary_count(context, object, &count))
        guard Int(count) <= Self.maximumVisits else { throw Unavailable.limit }
        var result = Set<Data>()
        for index in 0..<count {
            if index & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            result.insert(try copiedBytes { ember_raw_pdf_dictionary_key_copy($0, object, index, &$1, &$2) })
        }
        return result
    }

    private func dictionaryValue(_ object: EmberRawPDFObject, key: Data) throws -> EmberRawPDFObject {
        try self.object { context, result in
            key.withUnsafeBytes { ember_raw_pdf_dictionary_get(context, object, $0.bindMemory(to: UInt8.self).baseAddress, key.count, &result) }
        }
    }

    private func hasKey(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
        var object: CGPDFObjectRef?; return CGPDFDictionaryGetObject(dictionary, key, &object)
    }

    private func acquireLock() -> Bool {
        if Thread.isMainThread { return lock.try() }
        lock.lock(); return true
    }

    /// A later alias conflict also invalidates an earlier published stream.
    /// Refusing only the new page would leave that old payload reachable from
    /// the very same ambiguous native pointer during document serialization.
    private func quarantine() {
        if let context { ember_raw_pdf_destroy(context); self.context = nil }
        unavailable = true; input = .consumed
        pairs.removeAll(); reversePairs.removeAll(); streams.removeAll()
        signatureStates.removeAll(); signatureStateRecency.removeAll(); signatureStateBytes = 0
        signatureAppearances.removeAll(); signatureProofBytes = 0
        signatureNumbers.removeAll(); signatureNumberBytes = 0
        signatureOriginals.removeAll(); signatureOriginalBytes = 0; signatureInputHash = nil
        numberCorrections.removeAll(); numberCorrectionBytes = 0
        clearPayloadCache(); refusedPayloads.removeAll()
        structuralMetadataAbsenceProven = false
        preparedPages.removeAll(); refusedPages.removeAll()
        parentArrays = nil; parentArraysUnavailable = true
        cachedParentIndices.removeAll(); cachedParentIndexCount = 0
        emptyContentProofs.removeAll()
        provenEmptyOpeningActions.removeAll()
        provenNullFitOpeningActions.removeAll()
        provenInertOutlineParents.removeAll()
        storedDestinationNumbersPrepared = false
        originalInkEntries.removeAll(); originalInkBytes = 0
        originalInkCapacityReached = true
    }

    private func dictionaryEntries(_ dictionary: CGPDFDictionaryRef) throws -> [Data: CGPDFObjectRef] {
        var result: [Data: CGPDFObjectRef] = [:]
        var failure: Error?
        CGPDFDictionaryApplyBlock(dictionary, { key, value, _ in
            do {
                if result.count & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
                guard result.count < Self.maximumVisits else { throw Unavailable.limit }
                let count = strlen(key)
                guard count <= Self.maximumStreamBytes else { throw Unavailable.limit }
                var name = Data([47]); name.append(contentsOf: UnsafeRawBufferPointer(start: key, count: count))
                guard result.updateValue(value, forKey: name) == nil else { throw Unavailable.mismatch }
                return true
            } catch { failure = error; return false }
        }, nil)
        if let failure { throw failure }
        return result
    }

    private func object(_ operation: (EmberRawPDFRef?, inout EmberRawPDFObject) -> Int32) throws -> EmberRawPDFObject {
        var value: EmberRawPDFObject = 0; try checked(operation(context, &value))
        guard value != 0 else { throw Unavailable.mismatch }; return value
    }

    private func copiedBytes(_ operation: (EmberRawPDFRef?, inout UnsafeMutablePointer<UInt8>?, inout Int) -> Int32) throws -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?, count = 0
        let status = operation(context, &bytes, &count)
        defer { if let bytes { ember_raw_pdf_free(bytes) } }
        try checked(status)
        guard count <= Self.maximumStreamBytes, count == 0 || bytes != nil else { throw Unavailable.limit }
        return bytes.map { Data(bytes: $0, count: count) } ?? Data()
    }

    private func checked(_ status: Int32) throws {
        if status == Int32(EMBER_RAW_PDF_CANCELLED.rawValue) { throw CancellationError() }
        guard status == Int32(EMBER_RAW_PDF_OK.rawValue) else { throw Unavailable.mismatch }
    }
}
