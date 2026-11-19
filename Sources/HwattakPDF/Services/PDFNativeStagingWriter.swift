// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// An optional confined-worker save route. Original paintings and current
/// geometry/annotations still pass through the existing native graph writer.
/// The temporary SDK document contains no original paintings or tag tree.
enum PDFNativeStagingWriter {
    static func dataIfEligible(_ document: PDFDocument, helperURL: URL? = nil,
                              helperLimits: PDFTagReadAuxiliary.Limits = .standard) throws -> Data? {
        try PDFSaveCancellation.checkCurrent()
        guard !Thread.isMainThread, let proof = try PDFCatalogStructurePreserver.nativeStagingSource(for: document),
              try PDFBodyTextPageSnapshot.metadataMatches(document, source: proof) else { return nil }
        var auxiliary: PDFTagReadAuxiliary?
        if proof.hasTags {
            do {
            let file: PDFRawStreamSource.TagReadFileInput?
            do { file = try proof.rawSource.tagReadFileInput(in: proof.owner) }
            catch is CancellationError { throw CancellationError() }
            catch { file = nil }
            if let file {
                guard let result = try PDFTagReadAuxiliary.create(input: file, helperURL: helperURL, limits: helperLimits) else { return nil }
                auxiliary = result
            } else {
                guard let result = try PDFTagReadAuxiliary.create(immutableSource: proof.rawSource, owner: proof.owner,
                    helperURL: helperURL, limits: helperLimits) else { return nil }
                auxiliary = result
            }
            } catch is PDFTagReadAuxiliary.OriginalTagReaderFallback {
                // The auxiliary comparator rejected this graph. Preserve the
                // exact original reader and let the established tag builder
                // enforce its own reference/MCID/stream/resource limits.
                // Resource, timeout, cancellation and untrusted receipts never
                // grant this outcome. No auxiliary graph is used here.
                auxiliary = nil
            }
        }
        // Re-evaluate current page/annotation authority after the subprocess.
        // A cancellation must propagate before any ordinary-save fallback.
        try PDFSaveCancellation.checkCurrent()
        guard try PDFCatalogStructurePreserver.matches(proof, document: document) else { return nil }
        do {
        let originalReader = proof.hasTags && auxiliary == nil
        let projectionBegan = ProcessInfo.processInfo.systemUptime
        #if DEBUG
        if originalReader, ProcessInfo.processInfo.environment["EMBER_NATIVE_STAGING_TRACE"] == "1" {
            FileHandle.standardError.write(Data("native-staging-original-tag-reader.begin\n".utf8))
        }
        #endif
        var plan = try PDFCatalogStructurePreserver.plan(for: document, tagReadAuxiliary: auxiliary)
        guard try PDFCatalogStructurePreserver.preserveNativeStagingAppearanceAbsence(in: &plan,
            document: document, proof: proof) else { return nil }
        if originalReader {
            // The established builder's visits/depth/array/dictionary/byte
            // gates and cancellation checks remain unchanged. A completed
            // projection outside this optional route's time budget falls back.
            guard ProcessInfo.processInfo.systemUptime - projectionBegan < helperLimits.seconds else { return nil }
            #if DEBUG
            if ProcessInfo.processInfo.environment["EMBER_NATIVE_STAGING_TRACE"] == "1" {
                FileHandle.standardError.write(Data("native-staging-original-tag-reader.end seconds=\(ProcessInfo.processInfo.systemUptime - projectionBegan)\n".utf8))
            }
            #endif
        }
        try PDFSaveCancellation.checkCurrent()
        let carrier = try PDFPageStructurePreserver.nativeStagingCarrier(from: document, proof: proof)
        guard let serialized = carrier.dataRepresentation(), serialized.count <= 64 * 1_024 * 1_024 else { return nil }
        try PDFSaveCancellation.checkCurrent()
        guard try PDFCatalogStructurePreserver.matches(proof, document: document) else { return nil }
        let output = try PDFBodyTextPageSnapshot.preservingCatalog(in: serialized, from: document,
            plan: plan, metadataSource: proof)
        try PDFSaveCancellation.checkCurrent()
        guard try PDFCatalogStructurePreserver.matches(proof, document: document) else { return nil }
        return output
        } catch is CancellationError { throw CancellationError() }
        catch { return nil } // Optional staging never widens the normal writer's support gates.
    }
}
