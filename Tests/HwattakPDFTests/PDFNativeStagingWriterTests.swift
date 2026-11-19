// SPDX-License-Identifier: MPL-2.0
import AppKit
import CryptoKit
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFNativeStagingWriterTests: XCTestCase {
    func testCurrentLinksGeometryOutlineAndRawGlobalMetadataSurviveBlankSDKCarrier() async throws {
        let data = try await Task.detached { try Self.runFixture(.current) }.value
        let saved = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(saved.pageCount, 2)
        XCTAssertEqual(saved.findString("First current body", withOptions: []).count, 1)
        XCTAssertEqual(saved.findString("Second current body", withOptions: []).count, 1)
        XCTAssertEqual(saved.page(at: 0)?.rotation, 90)
        XCTAssertEqual(saved.page(at: 0)?.bounds(for: .cropBox), CGRect(x: 2, y: 3, width: 390, height: 280))
        let link = try XCTUnwrap(saved.page(at: 0)?.annotations.first)
        XCTAssertEqual(link.contents, "Current link text")
        let destination = try XCTUnwrap((link.action as? PDFActionGoTo)?.destination ?? link.destination)
        XCTAssertTrue(destination.page === saved.page(at: 0))
        XCTAssertEqual(destination.point, CGPoint(x: 30, y: 70))
        XCTAssertEqual(saved.outlineRoot?.child(at: 0)?.label, "Current bookmark")
        let owner = try XCTUnwrap(saved.documentRef), info = try XCTUnwrap(owner.info)
        XCTAssertEqual(try Self.nativeString(info, "PrivateUnknown"), Data([0xfe, 0xff, 0x6f, 0x22]))
        XCTAssertEqual(try Self.nativeString(info, "Keywords"), Data())
        XCTAssertEqual(try Self.nativeString(try XCTUnwrap(Self.dictionary(try XCTUnwrap(owner.catalog), "Pages")), "ITXT"), Data("opaque-root".utf8))
        XCTAssertNotNil(owner.fileIdentifier)
        XCTAssertEqual(try Self.nativeString(try XCTUnwrap(Self.dictionary(try XCTUnwrap(owner.catalog), "Outlines")), "Title"), Data("Original root".utf8))
    }

    func testBodyReplacementKeepsCurrentPaintingAndDropsOriginalTaggedParentAuthority() async throws {
        let data = try await Task.detached { try Self.runFixture(.body) }.value
        let saved = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(saved.findString("Changed replacement body", withOptions: []).count, 1)
        XCTAssertTrue(saved.findString("First current body", withOptions: []).isEmpty)
        XCTAssertEqual(saved.findString("Second current body", withOptions: []).count, 1)
    }

    func testCurrentOutlineRootTitleEditEmptyAndRemovedRootAreDistinct() async throws {
        for label: String? in ["Changed root", "", nil] {
            let data = try await Task.detached { try Self.runFixture(.root(label)) }.value
            let owner = try XCTUnwrap(PDFDocument(data: data)?.documentRef)
            let root = Self.dictionary(try XCTUnwrap(owner.catalog), "Outlines")
            if let label {
                let raw = try Self.nativeString(XCTUnwrap(root), "Title")
                XCTAssertEqual(Self.decodeUTF16(raw), label)
            } else { XCTAssertNil(root) }
        }
    }

    func testChangedAttributesNonLinkAppearanceAndUnprovenBodyKeepOrdinaryRoute() async throws {
        for mutation in [Mutation.metadata, .note, .appearance, .unprovenBody] {
            let refused = try await Task.detached { try Self.refuses(mutation) }.value
            XCTAssertTrue(refused, String(describing: mutation))
        }
    }

    func testRootTitleChangedBeforeProvenanceCaptureWinsOverOriginalAndAbsentStaysAbsent() async throws {
        for absent in [false, true] {
            let data = try await Task.detached { () throws -> Data in
                let document = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture(rootTitle: absent ? nil : "Original root")))
                if !absent { document.outlineRoot?.label = "Before first preparation" }
                XCTAssertEqual(document.outlineRoot?.numberOfChildren, 1, "Original outline child must be visible, absentTitle=\(absent)")
                try PDFCatalogStructurePreserver.prepare(document, force: true)
                return try XCTUnwrap(PDFNativeStagingWriter.dataIfEligible(document))
            }.value
            let saved = try XCTUnwrap(PDFDocument(data: data)), owner = try XCTUnwrap(saved.documentRef)
            XCTAssertEqual(saved.outlineRoot?.numberOfChildren, 1, "Current child must survive, absentTitle=\(absent)")
            let root = try XCTUnwrap(Self.dictionary(try XCTUnwrap(owner.catalog), "Outlines"), "absentTitle=\(absent)")
            if absent {
                var title: CGPDFObjectRef?
                XCTAssertFalse(CGPDFDictionaryGetObject(root, "Title", &title))
            } else { XCTAssertEqual(Self.decodeUTF16(try Self.nativeString(root, "Title")), "Before first preparation") }
        }
    }

    func testTwoNonneutralOriginalsCannotChooseTheFirstCatalogAsAuthority() async throws {
        let refused = try await Task.detached { () throws -> Bool in
            let first = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture()))
            let other = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture(first: "Another original")))
            _ = try PDFPageOperations.append(contentsOf: other, to: first)
            return try PDFNativeStagingWriter.dataIfEligible(first) == nil
        }.value
        XCTAssertTrue(refused)
    }

    func testActualCGContextAnchorUsesExplicitTargetMetadataAndCurrentMergeRoot() async throws {
        let bytes = try await Task.detached { () throws -> Data in
            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture()))
            let storage = NSMutableData(), consumer = try XCTUnwrap(CGDataConsumer(data: storage))
            var box = CGRect(x: 0, y: 0, width: 200, height: 200)
            let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
            context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
            let anchor = try XCTUnwrap(PDFDocument(data: storage as Data))
            PDFRawStreamProvenance.bindCreated(anchor, data: storage as Data)
            let attributes = anchor.documentAttributes ?? [:]
            _ = try PDFPageOperations.append(contentsOf: source, to: anchor)
            let data = try XCTUnwrap(PDFNativeStagingWriter.dataIfEligible(anchor))
            let saved = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertTrue(NSDictionary(dictionary: saved.documentAttributes ?? [:]).isEqual(to: attributes))
            XCTAssertEqual(saved.pageCount, 3)
            XCTAssertEqual(saved.page(at: 0)?.bounds(for: .mediaBox), box)
            XCTAssertEqual(saved.findString("First current body", withOptions: []).count, 1)
            XCTAssertEqual(saved.findString("Second current body", withOptions: []).count, 1)
            return data
        }.value
        XCTAssertNotNil(PDFDocument(data: bytes))
    }

    func testCancellationIsPropagatedBeforeAnyHelperOrOrdinaryFallback() async throws {
        let cancelled = try await Task.detached { () throws -> Bool in
            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture()))
            try PDFCatalogStructurePreserver.prepare(source, force: true)
            let token = PDFSaveCancellation(); token.cancel()
            do { _ = try PDFSaveCancellation.withCurrent(token) { try PDFNativeStagingWriter.dataIfEligible(source) }; return false }
            catch is CancellationError { return true }
        }.value
        XCTAssertTrue(cancelled)
    }

    func testTaggedFileUsesVerifiedAuxiliaryAndOriginalMetadataDonor() async throws {
        let helper = try helperURL()
        let result = try await Task.detached { try Self.runTagged(helper: helper, replaceURL: false, lowerLimit: nil) }.value
        let data = try XCTUnwrap(result)
        let owner = try XCTUnwrap(PDFDocument(data: data)?.documentRef)
        XCTAssertNotNil(Self.dictionary(try XCTUnwrap(owner.catalog), "StructTreeRoot"))
        XCTAssertEqual(try Self.nativeString(try XCTUnwrap(owner.info), "PrivateUnknown"), Data([0xfe, 0xff, 0x6f, 0x22]))
    }

    func testNativeStagingRefusesEditedPaintingWithUnprovenPageParents() async throws {
        let helper = try helperURL()
        let result = try await Task.detached { try Self.runTagged(helper: helper, replaceURL: false, lowerLimit: nil, editBody: true) }.value
        XCTAssertNil(result)
    }

    func testFrozenInputDigestRefusesReplacedFileAndLowerOutputLimit() async throws {
        let helper = try helperURL()
        let replaced = try await Task.detached { try Self.runTagged(helper: helper, replaceURL: true, lowerLimit: nil) }.value
        XCTAssertNil(replaced)
        let bounded = try await Task.detached { try Self.runTagged(helper: helper, replaceURL: false,
            lowerLimit: .init(residentBytes: 1_024 * 1_024 * 1_024, seconds: 10, outputBytes: 128)) }.value
        XCTAssertNil(bounded)
    }

    func testCapturedProofRefusesSameSourceReorderDeleteLinkGeometryMetadataAndBodyMutation() async throws {
        let count = try await Task.detached { () throws -> Int in
            var checked = 0
            for mutation in ["reorder", "delete", "link", "geometry", "metadata", "body"] {
                let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture()))
                try PDFCatalogStructurePreserver.prepare(source, force: true)
                let proof = try XCTUnwrap(PDFCatalogStructurePreserver.nativeStagingSource(for: source))
                XCTAssertTrue(try PDFCatalogStructurePreserver.matches(proof, document: source))
                let first = try XCTUnwrap(source.page(at: 0))
                switch mutation {
                case "reorder": source.exchangePage(at: 0, withPageAt: 1)
                case "delete": source.removePage(at: 1)
                case "link": first.annotations.first?.action = PDFActionGoTo(destination: PDFDestination(page: first, at: CGPoint(x: 9, y: 90)))
                case "geometry": first.rotation = 90
                case "metadata": source.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Post helper change"]
                default:
                    let replacement = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture(first: "Post helper body", marker: true))?.page(at: 0))
                    PDFCatalogStructurePreserver.inheritMetadata(from: first, to: replacement)
                    source.removePage(at: 0); source.insert(replacement, at: 0)
                }
                XCTAssertFalse(try PDFCatalogStructurePreserver.matches(proof, document: source), mutation)
                checked += 1
            }
            return checked
        }.value
        XCTAssertEqual(count, 6)
    }

    func testAfterHelperCurrentLinkMutationAndCancellationDiscardItsProof() async throws {
        let helper = try helperURL()
        let checked = try await Task.detached { () throws -> Bool in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AfterTagHelper-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("input.pdf")
            try Self.fixture(tagged: true).write(to: url, options: .withoutOverwriting)
            let document = try PDFSourceFileAccess.loadDocument(at: url).document
            try PDFCatalogStructurePreserver.prepare(document, force: true)
            let proof = try XCTUnwrap(PDFCatalogStructurePreserver.nativeStagingSource(for: document))
            let input = try XCTUnwrap(proof.rawSource.tagReadFileInput(in: proof.owner))
            let auxiliary = try XCTUnwrap(PDFTagReadAuxiliary.create(input: input, helperURL: helper))
            XCTAssertTrue(auxiliary.matches(original: proof.owner, raw: proof.rawSource))
            document.page(at: 0)?.annotations.first?.contents = "After helper current edit"
            XCTAssertFalse(try PDFCatalogStructurePreserver.matches(proof, document: document))
            let cancellation = PDFSaveCancellation(); cancellation.cancel()
            do {
                _ = try PDFSaveCancellation.withCurrent(cancellation) { try PDFCatalogStructurePreserver.plan(for: document, tagReadAuxiliary: auxiliary) }
                return false
            } catch is CancellationError { return true }
        }.value
        XCTAssertTrue(checked)
    }

    func testSemanticUnsupportedReceiptCannotAdmitChangedURLOrInPlaceInput() async throws {
        for replaceNode in [false, true] {
            try await Task.detached {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TagRefusalInputMutation-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: folder) }
                let input = folder.appendingPathComponent("input.pdf"), changed = folder.appendingPathComponent("changed.pdf")
                let replacement = Self.fixture(first: "Mutation while helper is active", tagged: true)
                try Self.fixture(tagged: true).write(to: input, options: .withoutOverwriting)
                try replacement.write(to: changed, options: .withoutOverwriting)
                let source = try PDFSourceFileAccess.loadDocument(at: input).document
                try PDFCatalogStructurePreserver.prepare(source, force: true)
                let wrapper = folder.appendingPathComponent("mutation-worker")
                func shell(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                let script = "#!/bin/sh\n/bin/sleep 0.1\n/bin/" + (replaceNode ? "mv" : "cp") + " " + shell(changed.path) + " " + shell(input.path)
                    + "\nprintf '%s\\n' '{\"type\":\"tag-read-auxiliary-error\",\"protocolVersion\":1,\"status\":7}' >&2\nexit 65\n"
                try Data(script.utf8).write(to: wrapper, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
                XCTAssertNil(try PDFNativeStagingWriter.dataIfEligible(source, helperURL: wrapper),
                    "Input mutation cannot receive original-reader admission, replaceNode=\(replaceNode)")
                XCTAssertEqual(try Data(contentsOf: input), replacement)
            }.value
        }
    }

    func testOnlyExactSemanticUnsupportedReceiptSelectsOriginalTagBuilder() async throws {
        let cases: [(String, Int, Bool)] = [
            (#"{"type":"tag-read-auxiliary-error","protocolVersion":1,"status":7}"#, 65, true),
            (#"{"type":"tag-read-auxiliary-error","protocolVersion":1,"status":3}"#, 65, false),
            (#"{"type":"tag-read-auxiliary-error","protocolVersion":2,"status":7}"#, 65, false),
            (#"{"type":"different-error","protocolVersion":1,"status":7}"#, 65, false),
            (#"{"type":"tag-read-auxiliary-error","protocolVersion":1,"status":7}"#, 0, false),
            (#"{"type":"tag-read-auxiliary-error","protocolVersion":1,"status":7,"extra":true}"#, 65, false)
        ]
        for (receipt, status, allowed) in cases {
            try await Task.detached {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TagStatusFixture-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: folder) }
                let wrapper = folder.appendingPathComponent("receipt-worker")
                let script = "#!/bin/sh\n/bin/sleep 0.1\nprintf '%s\\n' '" + receipt + "' >&2\nexit " + String(status) + "\n"
                try Data(script.utf8).write(to: wrapper, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
                let output = try Self.runTagged(helper: wrapper, replaceURL: false, lowerLimit: nil)
                if allowed {
                    let saved = try XCTUnwrap(PDFDocument(data: XCTUnwrap(output)))
                    XCTAssertEqual(saved.findString("First current body", withOptions: []).count, 1)
                    let owner = try XCTUnwrap(saved.documentRef)
                    XCTAssertNotNil(Self.dictionary(try XCTUnwrap(owner.catalog), "StructTreeRoot"))
                } else { XCTAssertNil(output) }
            }.value
        }
    }

    func testCurrentAnnotationMetadataAndCustomScalarKeysAreBoundAndPreserved() async throws {
        try await Task.detached {
            for key in ["/T", "/Lang", "/QAExtension"] {
                let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture()))
                try PDFCatalogStructurePreserver.prepare(source, force: true)
                let annotation = try XCTUnwrap(source.page(at: 0)?.annotations.first)
                XCTAssertTrue(annotation.setValue("Before " + key, forAnnotationKey: .init(rawValue: key)))
                let proof = try XCTUnwrap(PDFCatalogStructurePreserver.nativeStagingSource(for: source))
                XCTAssertTrue(annotation.setValue("Current " + key, forAnnotationKey: .init(rawValue: key)))
                XCTAssertFalse(try PDFCatalogStructurePreserver.matches(proof, document: source), key)
                let bytes = try XCTUnwrap(PDFNativeStagingWriter.dataIfEligible(source))
                let saved = try XCTUnwrap(PDFDocument(data: bytes))
                let copied = try XCTUnwrap(saved.page(at: 0)?.annotations.first)
                XCTAssertEqual(copied.value(forAnnotationKey: .init(rawValue: key)) as? String, "Current " + key)
            }
            let dated = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture()))
            try PDFCatalogStructurePreserver.prepare(dated, force: true)
            let annotation = try XCTUnwrap(dated.page(at: 0)?.annotations.first)
            annotation.modificationDate = Date(timeIntervalSince1970: 1_792_548_000)
            let proof = try XCTUnwrap(PDFCatalogStructurePreserver.nativeStagingSource(for: dated))
            annotation.modificationDate = Date(timeIntervalSince1970: 1_792_548_060)
            XCTAssertFalse(try PDFCatalogStructurePreserver.matches(proof, document: dated))
            let bytes = try XCTUnwrap(PDFNativeStagingWriter.dataIfEligible(dated))
            let saved = try XCTUnwrap(PDFDocument(data: bytes))
            XCTAssertEqual(saved.page(at: 0)?.annotations.first?.modificationDate, annotation.modificationDate)
            XCTAssertTrue(annotation.setValue("Invalid date input", forAnnotationKey: .init(rawValue: "/M")))
            XCTAssertNil(try PDFNativeStagingWriter.dataIfEligible(dated), "SDK-unrepresentable current M cannot qualify")
        }.value
    }

    func testImmutableFactoryInputSurvivesURLReplacementWithoutReadingReplacementAndCleansSnapshots() async throws {
        let helper = try helperURL()
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImmutableTagInput-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("input.pdf"), original = Self.fixture(tagged: true)
            try original.write(to: url, options: .withoutOverwriting)
            let source = try PDFSourceFileAccess.loadDocument(at: url).document
            try PDFCatalogStructurePreserver.prepare(source, force: true)
            let owner = try XCTUnwrap(source.documentRef), raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
            _ = try XCTUnwrap(raw.signatureInputDigest(in: owner))
            let replacement = Self.fixture(first: "New URL must stay untouched", tagged: true)
            try replacement.write(to: url, options: .atomic)
            XCTAssertNil(try raw.tagReadFileInput(in: owner))
            let other = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: original)?.documentRef)
            XCTAssertNil(try raw.tagReadImmutableInput(in: other))
            XCTAssertNil(try raw.tagReadImmutableInput(in: owner, maximumBytes: 1))
            let before = try Self.tagTemporaryNames()
            let result = try XCTUnwrap(PDFNativeStagingWriter.dataIfEligible(source, helperURL: helper))
            let saved = try XCTUnwrap(PDFDocument(data: result))
            XCTAssertEqual(saved.findString("First current body", withOptions: []).count, 1)
            XCTAssertTrue(saved.findString("New URL must stay untouched", withOptions: []).isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), replacement)
            XCTAssertEqual(try Self.tagTemporaryNames(), before)
            XCTAssertNil(try PDFTagReadAuxiliary.create(immutableSource: raw, owner: owner, helperURL: helper,
                limits: .init(residentBytes: 1_024 * 1_024 * 1_024, seconds: 10, outputBytes: 128)))
            XCTAssertEqual(try Self.tagTemporaryNames(), before)
            let token = PDFSaveCancellation(); token.cancel()
            XCTAssertThrowsError(try PDFSaveCancellation.withCurrent(token) {
                try PDFTagReadAuxiliary.create(immutableSource: raw, owner: owner, helperURL: helper)
            }) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(try Self.tagTemporaryNames(), before)
            // Unmaterialized file input has no old-byte authority after a URL
            // replacement: it cannot initialize the new bytes as the old owner.
            try original.write(to: url, options: .atomic)
            let fresh = try PDFSourceFileAccess.loadDocument(at: url).document
            let freshOwner = try XCTUnwrap(fresh.documentRef), freshRaw = try XCTUnwrap(PDFRawStreamProvenance.source(for: fresh))
            XCTAssertEqual(freshRaw.widgetInputFootprint.storage, "versionGuardedFile")
            try replacement.write(to: url, options: .atomic)
            XCTAssertNil(try freshRaw.tagReadImmutableInput(in: freshOwner))
            XCTAssertNil(try freshRaw.tagReadFileInput(in: freshOwner))
            XCTAssertEqual(try Data(contentsOf: url), replacement)
        }.value
    }

    func testConcurrentTaggedSavesQueueAndQueuedCancellationLaunchesNoSecondHelper() async throws {
        let helper = try helperURL()
        for cancelQueued in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QueuedTagHelpers-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let log = folder.appendingPathComponent("launches.txt"), wrapper = folder.appendingPathComponent("worker-wrapper")
            func shell(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let script = "#!/bin/sh\nprintf '%s\\n' \"$$\" >> " + shell(log.path) + "\n/bin/sleep 0.35\nexec " + shell(helper.path) + " \"$@\"\n"
            try Data(script.utf8).write(to: wrapper, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            let first = Task.detached { try Self.runTagged(helper: wrapper, replaceURL: false, lowerLimit: nil) }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !FileManager.default.fileExists(atPath: log.path), ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
            let token = PDFSaveCancellation()
            let second = Task.detached { try PDFSaveCancellation.withCurrent(token) {
                try Self.runTagged(helper: wrapper, replaceURL: false, lowerLimit: nil)
            } }
            if cancelQueued { try await Task.sleep(for: .milliseconds(60)); token.cancel() }
            let firstBytes = try await first.value
            XCTAssertNotNil(firstBytes)
            if cancelQueued {
                do { _ = try await second.value; XCTFail("Queued cancellation must propagate") }
                catch { XCTAssertTrue(error is CancellationError) }
            } else { let secondBytes = try await second.value; XCTAssertNotNil(secondBytes) }
            let launches = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(launches.count, cancelQueued ? 1 : 2)
            XCTAssertEqual(Set(launches).count, launches.count)
        }
    }

    nonisolated private static func tagTemporaryNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("EmberPDF-tag-read-") || $0.hasPrefix("EmberPDF-tag-input-") })
    }

    func testTrustedSparseTagGraphAboveTwoMillionComparisonsIsAdmittedWithExactInput() async throws {
        let helper = try helperURL()
        try await Task.detached {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TagCapacityPositive-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("sparse.pdf")
            let original = Self.fixture(tagged: true, sparseNullBlocks: 11)
            try original.write(to: url, options: .withoutOverwriting)
            let document = try PDFSourceFileAccess.loadDocument(at: url).document
            let owner = try XCTUnwrap(document.documentRef)
            let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
            let input = try XCTUnwrap(raw.tagReadFileInput(in: owner))
            let auxiliary = try XCTUnwrap(PDFTagReadAuxiliary.create(input: input, helperURL: helper))
            XCTAssertTrue(auxiliary.matches(original: owner, raw: raw))
            XCTAssertEqual(auxiliary.document.numberOfPages, 2)
            let root = try XCTUnwrap(Self.dictionary(try XCTUnwrap(auxiliary.document.catalog), "StructTreeRoot"))
            let parents = try XCTUnwrap(Self.dictionary(root, "ParentTree"))
            var nums: CGPDFArrayRef?
            XCTAssertTrue(CGPDFDictionaryGetArray(parents, "Nums", &nums))
            XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(nums)), 26)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }.value
    }

    func testCapacityReceiptAboveSixteenMillionAndInvalidBindingsRemainRejected() async throws {
        let helper = try helperURL()
        let mutations: [[String: String]] = [
            [:], // Positive control: authentic helper receipt and output must remain admissible.
            ["tagNodes": "16000001"], ["tagNodes": "0"],
            ["tagNodes": "2200001", "inputSHA256": String(repeating: "0", count: 64)],
            ["tagNodes": "2200001", "outputSHA256": String(repeating: "0", count: 64)],
            ["tagNodes": "2200001", "protocolVersion": "2"],
            ["tagNodes": "2200001", "objectCount": "250001"],
            ["tagNodes": "2200001", "pageCount": "999"]
        ]
        for mutation in mutations {
            try await Task.detached {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TagCapacityReceipt-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: folder) }
                let url = folder.appendingPathComponent("source.pdf")
                let original = Self.fixture(tagged: true)
                try original.write(to: url, options: .withoutOverwriting)
                let document = try PDFSourceFileAccess.loadDocument(at: url).document
                let owner = try XCTUnwrap(document.documentRef)
                let raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: document))
                let input = try XCTUnwrap(raw.tagReadFileInput(in: owner))
                let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
                let workerLiteral = String(data: try encoder.encode(helper.path), encoding: .utf8)!
                let mutationLiteral = String(data: try JSONSerialization.data(withJSONObject: mutation, options: [.sortedKeys]), encoding: .utf8)!
                let script = "#!/usr/bin/python3\nimport json,subprocess,sys,time\ntime.sleep(0.1)\np=subprocess.Popen([" + workerLiteral + "]+sys.argv[1:],stderr=subprocess.PIPE)\n_,receipt=p.communicate()\nif p.returncode: sys.stderr.buffer.write(receipt);sys.exit(p.returncode)\nr=json.loads(receipt)\nm=json.loads('" + mutationLiteral + "')\nfor k,v in m.items(): r[k]=int(v) if k not in ('inputSHA256','outputSHA256') else v\nsys.stderr.write(json.dumps(r,separators=(',',':'))+chr(10));sys.stderr.flush()\n"
                let wrapper = folder.appendingPathComponent("receipt-worker")
                try Data(script.utf8).write(to: wrapper, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
                let auxiliary = try PDFTagReadAuxiliary.create(input: input, helperURL: wrapper)
                if mutation.isEmpty { XCTAssertNotNil(auxiliary, "Receipt wrapper positive control must be valid") }
                else { XCTAssertNil(auxiliary, "Invalid capacity/protocol/source receipt: \(mutation)") }
                XCTAssertEqual(try Data(contentsOf: url), original)
            }.value
        }
    }

    func testCarrierDoesNotInventLinkAppearancesAcrossReopenAndRepeatedSaves() async throws {
        let helper = try helperURL()
        try await Task.detached {
            var source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture(tagged: true)))
            try PDFCatalogStructurePreserver.prepare(source, force: true)
            let link = try XCTUnwrap(source.page(at: 0)?.annotations.first)
            let border = PDFBorder(); border.lineWidth = 2; border.style = .solid
            link.border = border; link.color = .red; link.contents = "Current styled link"
            link.destination = nil
            link.action = PDFActionGoTo(destination: PDFDestination(page: try XCTUnwrap(source.page(at: 1)), at: CGPoint(x: 45, y: 80)))
            for round in 0..<3 {
                let data = try XCTUnwrap(PDFNativeStagingWriter.dataIfEligible(source, helperURL: helper), "round \(round)")
                source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: data))
                let page = try XCTUnwrap(source.page(at: 0)), current = try XCTUnwrap(page.annotations.first)
                var annots: CGPDFArrayRef?, raw: CGPDFDictionaryRef?, ap: CGPDFObjectRef?, aa: CGPDFObjectRef?
                XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(page.pageRef?.dictionary), "Annots", &annots))
                XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(annots), 0, &raw))
                XCTAssertFalse(CGPDFDictionaryGetObject(try XCTUnwrap(raw), "AP", &ap), "Carrier AP must not become original authority")
                XCTAssertFalse(CGPDFDictionaryGetObject(try XCTUnwrap(raw), "AA", &aa))
                XCTAssertEqual(current.bounds, CGRect(x: 20, y: 20, width: 80, height: 30))
                XCTAssertEqual(current.contents, "Current styled link")
                XCTAssertEqual(current.border?.lineWidth, 2)
                XCTAssertEqual(current.border?.style, .solid)
                let destination = try XCTUnwrap((current.action as? PDFActionGoTo)?.destination ?? current.destination)
                XCTAssertTrue(destination.page === source.page(at: 1)); XCTAssertEqual(destination.point, CGPoint(x: 45, y: 80))
                var color: CGPDFArrayRef?
                XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(raw), "C", &color))
                XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(color)), 3)
                for (index, expected) in [1.0, 0, 0].enumerated() {
                    var value: CGPDFReal = 0; XCTAssertTrue(CGPDFArrayGetNumber(try XCTUnwrap(color), index, &value)); XCTAssertEqual(value, expected)
                }
                try PDFCatalogStructurePreserver.prepare(source, force: true)
            }
        }.value
    }

    func testOriginalAndCurrentLinkAppearancesAndAdditionalActionsStayIneligible() async throws {
        try await Task.detached {
            for original in [" /AP << /N 16 0 R >>", " /AA << /U << /S /URI /URI (https://example.invalid/original) >> >>"] {
                let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture(linkExtras: original)))
                try PDFCatalogStructurePreserver.prepare(source, force: true)
                XCTAssertNil(try PDFNativeStagingWriter.dataIfEligible(source), original)
            }
            for key in ["/AP", "/AA"] {
                let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture()))
                try PDFCatalogStructurePreserver.prepare(source, force: true)
                let link = try XCTUnwrap(source.page(at: 0)?.annotations.first)
                XCTAssertTrue(link.setValue(["N": "current appearance or action"], forAnnotationKey: .init(rawValue: key)))
                XCTAssertNotNil(link.value(forAnnotationKey: .init(rawValue: key)))
                XCTAssertNil(try PDFNativeStagingWriter.dataIfEligible(source), key)
            }
        }.value
    }

    func testUnprovenNewOrForeignLinkAndPostProofStyleMutationCannotBorrowAppearanceAbsence() async throws {
        try await Task.detached {
            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture()))
            try PDFCatalogStructurePreserver.prepare(source, force: true)
            let page = try XCTUnwrap(source.page(at: 0)), link = try XCTUnwrap(page.annotations.first)
            let proof = try XCTUnwrap(PDFCatalogStructurePreserver.nativeStagingSource(for: source))
            var plan = try PDFCatalogStructurePreserver.plan(for: source)
            let border = PDFBorder(); border.lineWidth = 3; link.border = border
            XCTAssertFalse(try PDFCatalogStructurePreserver.preserveNativeStagingAppearanceAbsence(in: &plan, document: source, proof: proof))
            let cancellation = PDFSaveCancellation(); cancellation.cancel()
            do {
                _ = try PDFSaveCancellation.withCurrent(cancellation) { try PDFCatalogStructurePreserver.preserveNativeStagingAppearanceAbsence(in: &plan, document: source, proof: proof) }
                XCTFail("Cancellation must propagate")
            } catch is CancellationError { }
            let added = PDFAnnotation(bounds: CGRect(x: 1, y: 2, width: 30, height: 40), forType: .link, withProperties: nil)
            added.modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
            page.removeAnnotation(link); page.addAnnotation(added)
            let newProof = try XCTUnwrap(PDFCatalogStructurePreserver.nativeStagingSource(for: source))
            var newPlan = PDFCatalogGraphPlan()
            XCTAssertFalse(try PDFCatalogStructurePreserver.preserveNativeStagingAppearanceAbsence(in: &newPlan, document: source, proof: newProof), "A new link has no exact native absence authority")
            XCTAssertTrue(newPlan.annotationDrops.isEmpty)
            let other = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture()))
            let otherPage = try XCTUnwrap(other.page(at: 0)), old = try XCTUnwrap(otherPage.annotations.first)
            let foreign = ForeignLink(bounds: old.bounds, forType: .link, withProperties: nil)
            foreign.contents = old.contents
            foreign.destination = PDFDestination(page: try XCTUnwrap(other.page(at: 1)), at: CGPoint(x: 30, y: 70))
            foreign.modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
            otherPage.removeAnnotation(old); otherPage.addAnnotation(foreign)
            try PDFCatalogStructurePreserver.prepare(other, force: true)
            let classProof = try XCTUnwrap(PDFCatalogStructurePreserver.nativeStagingSource(for: other))
            var classPlan = PDFCatalogGraphPlan()
            XCTAssertFalse(try PDFCatalogStructurePreserver.preserveNativeStagingAppearanceAbsence(in: &classPlan, document: other, proof: classProof), "An application drawing subclass cannot borrow native absence")
            XCTAssertTrue(classPlan.annotationDrops.isEmpty)
            let foreignSource = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture()))
            try PDFCatalogStructurePreserver.prepare(foreignSource, force: true)
            let foreignPage = try XCTUnwrap(foreignSource.page(at: 0)), foreignOwnerLink = try XCTUnwrap(foreignPage.annotations.first)
            foreignPage.removeAnnotation(foreignOwnerLink)
            let target = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture()))
            try PDFCatalogStructurePreserver.prepare(target, force: true)
            let targetPage = try XCTUnwrap(target.page(at: 0)), targetLink = try XCTUnwrap(targetPage.annotations.first)
            targetPage.removeAnnotation(targetLink); targetPage.addAnnotation(foreignOwnerLink)
            foreignOwnerLink.destination = nil
            foreignOwnerLink.action = PDFActionGoTo(destination: PDFDestination(page: try XCTUnwrap(target.page(at: 1)), at: CGPoint(x: 30, y: 70)))
            foreignOwnerLink.modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
            let ownerProof = try XCTUnwrap(PDFCatalogStructurePreserver.nativeStagingSource(for: target))
            var ownerPlan = PDFCatalogGraphPlan()
            XCTAssertFalse(try PDFCatalogStructurePreserver.preserveNativeStagingAppearanceAbsence(in: &ownerPlan, document: target, proof: ownerProof), "A standard SDK link from another factory owner cannot borrow target absence")
            XCTAssertTrue(ownerPlan.annotationDrops.isEmpty)
        }.value
    }
    private final class ForeignLink: PDFAnnotation { }

    private func helperURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["EMBER_NATIVE_STAGING_WORKER_PATH"],
              FileManager.default.isExecutableFile(atPath: path) else { throw XCTSkip("Explicit owned built worker required") }
        return URL(fileURLWithPath: path)
    }
    private enum Mutation: Sendable { case current, body, root(String?), metadata, note, appearance, unprovenBody }
    nonisolated private static func runFixture(_ mutation: Mutation) throws -> Data {
        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let page = try XCTUnwrap(source.page(at: 0))
        switch mutation {
        case .current:
            page.rotation = 90; page.setBounds(CGRect(x: 2, y: 3, width: 390, height: 280), for: .cropBox)
            let link = try XCTUnwrap(page.annotations.first); link.contents = "Current link text"
            link.destination = nil; link.action = PDFActionGoTo(destination: PDFDestination(page: page, at: CGPoint(x: 30, y: 70)))
            source.outlineRoot?.child(at: 0)?.label = "Current bookmark"
        case .body:
            let replacementSource = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture(first: "Changed replacement body", marker: true)))
            let replacement = try XCTUnwrap(replacementSource.page(at: 0))
            for annotation in replacement.annotations { replacement.removeAnnotation(annotation) }
            PDFCatalogStructurePreserver.inheritMetadata(from: page, to: replacement)
            for annotation in page.annotations { page.removeAnnotation(annotation); replacement.addAnnotation(annotation) }
            source.removePage(at: 0); source.insert(replacement, at: 0)
            PDFCatalogStructurePreserver.refreshMarker(source)
        case .root(let label):
            // On a native document PDFKit reloads original outlines after a
            // nil assignment. An actual extracted document has no old native
            // Catalog to resurrect, so it represents explicit removal.
            let current = try PDFPageOperations.extract(from: source, indexes: [0, 1])
            if let label { current.outlineRoot?.label = label }
            else { current.outlineRoot = nil }
            XCTAssertEqual(current.outlineRoot?.label, label, "Assembled fixture must expose requested current state")
            return try XCTUnwrap(PDFNativeStagingWriter.dataIfEligible(current))
        default: throw TestFailure.unexpected
        }
        return try XCTUnwrap(PDFNativeStagingWriter.dataIfEligible(source))
    }
    nonisolated private static func refuses(_ mutation: Mutation) throws -> Bool {
        let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture()))
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        let page = try XCTUnwrap(source.page(at: 0))
        switch mutation {
        case .metadata: source.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Current changed title"]
        case .note: page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 1, y: 2, width: 4, height: 5), forType: .text, withProperties: nil))
        case .appearance: _ = page.annotations.first?.setValue(["N": "unproven"], forAnnotationKey: .init(rawValue: "/AP"))
        case .unprovenBody:
            let replacement = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture(first: "Unmarked changed body"))?.page(at: 0))
            PDFCatalogStructurePreserver.inheritMetadata(from: page, to: replacement)
            source.removePage(at: 0); source.insert(replacement, at: 0)
        default: throw TestFailure.unexpected
        }
        return try PDFNativeStagingWriter.dataIfEligible(source) == nil
    }
    nonisolated private static func runTagged(helper: URL, replaceURL: Bool,
                 lowerLimit: PDFTagReadAuxiliary.Limits?, editBody: Bool = false) throws -> Data? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NativeStagingTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("original.pdf")
        try fixture(tagged: true).write(to: url, options: .withoutOverwriting)
        let source = try PDFSourceFileAccess.loadDocument(at: url).document
        try PDFCatalogStructurePreserver.prepare(source, force: true)
        if editBody {
            let original = try XCTUnwrap(source.page(at: 0))
            let replacementSource = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: fixture(first: "Tagged current replacement", marker: true)))
            let replacement = try XCTUnwrap(replacementSource.page(at: 0))
            for annotation in replacement.annotations { replacement.removeAnnotation(annotation) }
            PDFCatalogStructurePreserver.inheritMetadata(from: original, to: replacement)
            for annotation in original.annotations { original.removeAnnotation(annotation); replacement.addAnnotation(annotation) }
            source.removePage(at: 0); source.insert(replacement, at: 0)
            PDFCatalogStructurePreserver.refreshMarker(source)
        }
        if replaceURL {
            let owner = try XCTUnwrap(source.documentRef), raw = try XCTUnwrap(PDFRawStreamProvenance.source(for: source))
            XCTAssertNotNil(try raw.signatureInputDigest(in: owner))
            try fixture(first: "Replacement URL bytes", tagged: true).write(to: url, options: .atomic)
            // Keep the guarded-file contract explicit. A separate factory
            // immutable-context route is covered below, never a URL waiver.
            XCTAssertNil(try raw.tagReadFileInput(in: owner))
            return nil
        }
        return try PDFNativeStagingWriter.dataIfEligible(source, helperURL: helper, helperLimits: lowerLimit ?? .standard)
    }
    nonisolated private static func dictionary(_ owner: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?; return CGPDFDictionaryGetDictionary(owner, key, &value) ? value : nil
    }
    nonisolated private static func nativeString(_ owner: CGPDFDictionaryRef, _ key: String) throws -> Data {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(owner, key, &value), let value,
              let bytes = CGPDFStringGetBytePtr(value) else { throw TestFailure.unexpected }
        return Data(bytes: bytes, count: CGPDFStringGetLength(value))
    }
    nonisolated private static func decodeUTF16(_ raw: Data) -> String? {
        if raw.starts(with: [0xfe, 0xff]) { return String(data: raw.dropFirst(2), encoding: .utf16BigEndian) }
        return String(data: raw, encoding: .utf8)
    }
    nonisolated private static func fixture(first: String = "First current body", tagged: Bool = false, marker: Bool = false, rootTitle: String? = "Original root", sparseNullBlocks: Int = 0, linkExtras: String = "") -> Data {
        func stream(_ value: String) -> Data { Data("<< /Length \(value.utf8.count) >>\nstream\n\(value)\nendstream".utf8) }
        var objects = [
            Data(("<< /Type /Catalog /Pages 2 0 R /Outlines 13 0 R /AcroForm 15 0 R" + (tagged ? " /StructTreeRoot 7 0 R /MarkInfo << /Marked true >>" : "") + " >>").utf8),
            Data("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /ITXT (opaque-root) >>".utf8),
            Data(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 11 0 R >> >> /Contents 5 0 R /Annots [9 0 R]" + (tagged ? " /StructParents 0" : "") + (marker ? " /EmberPDFPreservePageContent true" : "") + " >>").utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Resources << /Font << /F1 11 0 R >> >> /Contents 6 0 R >>".utf8),
            stream((tagged ? "/P <</MCID 0>> BDC " : "") + "BT /F1 16 Tf 1 0 0 1 30 200 Tm (\(first)) Tj ET" + (tagged ? " EMC" : "")),
            stream("BT /F1 16 Tf 1 0 0 1 30 200 Tm (Second current body) Tj ET"),
            Data("<< /Type /StructTreeRoot /K [8 0 R] /ParentTree 10 0 R /ParentTreeNextKey 2 >>".utf8),
            Data("<< /Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K [0 << /Type /OBJR /Obj 9 0 R /Pg 3 0 R >>] >>".utf8),
            Data(("<< /Type /Annot /Subtype /Link /Rect [20 20 100 50] /Contents (Original link text) /Dest [4 0 R /Fit]" + (tagged ? " /StructParent 1" : "") + linkExtras + " >>").utf8),
            Data((sparseNullBlocks == 0 ? "<< /Nums [0 [8 0 R] 1 8 0 R] >>" : "<< /Nums [0 [8 0 R] 1 8 0 R " + (0..<sparseNullBlocks).map { "\($0 + 2) [" + String(repeating: "null ", count: 200_000) + "] " }.joined() + "] >>").utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
            Data("<< /Title (Staging fixture) /Author (QA) /Keywords () /Trapped /Unknown /PrivateUnknown <FEFF6F22> >>".utf8),
            Data(("<< /Type /Outlines " + (rootTitle.map { "/Title (\($0)) " } ?? "") + "/First 14 0 R /Last 14 0 R /Count 1 >>").utf8),
            Data("<< /Title (Original bookmark) /Parent 13 0 R /Dest [3 0 R /Fit] >>".utf8),
            Data("<< /Fields [] >>".utf8)
        ]
        if !linkExtras.isEmpty {
            let appearance = "0 0 m 80 30 l S\n"
            objects.append(Data("<< /Type /XObject /Subtype /Form /BBox [0 0 80 30] /Resources << >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)endstream".utf8))
        }
        var data = Data("%PDF-1.7\n".utf8), offsets: [Int] = []
        for (index, value) in objects.enumerated() { offsets.append(data.count); data.append(Data("\(index + 1) 0 obj\n".utf8)); data.append(value); data.append(Data("\nendobj\n".utf8)) }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 12 0 R /ID [<01020304> <05060708>] >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }
    private enum TestFailure: Error { case unexpected }

    func testFactoryBoundEmptyOutlinesSurviveBothWritersAcrossTwoColdSaves() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-Empty-Outlines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let variants = ["", "/Type /Outlines", "/Type /Outlines /Count 0",
                        "/Type /Outlines /Count 0 /Title <FEFF7A7A>"]
        for (index, entries) in variants.enumerated() {
            for atomic in [false, true] {
                var source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.emptyOutlineFixture(entries)))
                let expected = try Self.emptyOutlineControls(XCTUnwrap(source.documentRef?.catalog))
                XCTAssertNotNil(expected)
                XCTAssertEqual(source.outlineRoot?.numberOfChildren ?? 0, 0)
                let originalText = source.page(at: 0)?.string
                for cycle in 0..<2 {
                    let snapshot = try PDFRecoverySnapshot(capturing: source)
                    let url = folder.appendingPathComponent("\(index)-\(atomic)-\(cycle).pdf")
                    let data = try await Task.detached { () throws -> Data in
                        if atomic {
                            try AtomicPDFWriter.write(snapshot.takeDocument(), to: url)
                            return try Data(contentsOf: url)
                        }
                        return try snapshot.serializedData()
                    }.value
                    source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: data))
                    XCTAssertEqual(source.pageCount, 1)
                    XCTAssertEqual(source.page(at: 0)?.string, originalText)
                    XCTAssertEqual(try Self.emptyOutlineControls(XCTUnwrap(source.documentRef?.catalog)), expected,
                        "The original empty root's typed controls and key presence must survive cold save \(cycle).")
                }
            }
        }
    }

    func testEmptyOutlinesCannotBorrowAuthorityFromMalformedUnboundOrEditedRoots() async throws {
        try await Task.detached {
            for entries in ["/First null", "/Last null", "/Count 1", "/Count -1", "/Count null",
                            "/Type /NotOutlines", "/Title 42", "/PrivateUnknown true"] {
                let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.emptyOutlineFixture(entries)))
                try PDFCatalogStructurePreserver.prepare(source, force: true)
                XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: source).emptyOutlineSource, entries)
            }
            let absent = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.emptyOutlineFixture(nil)))
            try PDFCatalogStructurePreserver.prepare(absent, force: true)
            XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: absent).emptyOutlineSource)
            let unbound = try XCTUnwrap(PDFDocument(data: Self.emptyOutlineFixture("/Type /Outlines")))
            try PDFCatalogStructurePreserver.prepare(unbound, force: true)
            XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: unbound).emptyOutlineSource)

            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.emptyOutlineFixture("/Type /Outlines")))
            try PDFCatalogStructurePreserver.prepare(source, force: true)
            let proof = try XCTUnwrap(PDFCatalogStructurePreserver.plan(for: source).emptyOutlineSource)
            let provider = try XCTUnwrap(CGDataProvider(data: Self.emptyOutlineFixture(nil) as CFData))
            let staged = try XCTUnwrap(CGPDFDocument(provider))
            XCTAssertNotNil(try PDFCatalogStructurePreserver.originalEmptyOutline(proof, for: source, staged: staged))
            let root = PDFOutline(), child = PDFOutline()
            root.label = "Current root"; child.label = "Current child"
            child.destination = PDFDestination(page: try XCTUnwrap(source.page(at: 0)), at: CGPoint(x: 20, y: 80))
            root.insertChild(child, at: 0); source.outlineRoot = root
            XCTAssertNil(try PDFCatalogStructurePreserver.originalEmptyOutline(proof, for: source, staged: staged),
                "A plan captured before a current outline edit must not overwrite the new root.")
            XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: source).emptyOutlineSource)

            // An assembled document has no original native outline tree for
            // PDFKit to reload after a nil assignment. Keep the metadata owner
            // from the original, then change only its public current root.
            let owner = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data:
                Self.emptyOutlineFixture("/Type /Outlines /Title (Original)")))
            let ownerRoot = owner.outlineRoot ?? PDFOutline()
            ownerRoot.label = "Original"; owner.outlineRoot = ownerRoot
            try PDFCatalogStructurePreserver.prepare(owner, force: true)
            let assembled = try PDFPageOperations.extract(from: owner, indexes: [0])
            let currentRoot = PDFOutline(); currentRoot.label = "Original"
            currentRoot.isOpen = ownerRoot.isOpen; assembled.outlineRoot = currentRoot
            let emptyProof = try XCTUnwrap(PDFCatalogStructurePreserver.plan(for: assembled).emptyOutlineSource)
            XCTAssertNotNil(try PDFCatalogStructurePreserver.originalEmptyOutline(emptyProof, for: assembled, staged: staged))
            let initialOpen = currentRoot.isOpen
            currentRoot.isOpen = !initialOpen
            XCTAssertNotEqual(currentRoot.isOpen, initialOpen)
            XCTAssertNil(try PDFCatalogStructurePreserver.originalEmptyOutline(emptyProof, for: assembled, staged: staged))
            currentRoot.isOpen = initialOpen
            XCTAssertNotNil(try PDFCatalogStructurePreserver.originalEmptyOutline(emptyProof, for: assembled, staged: staged))
            assembled.outlineRoot = nil
            XCTAssertNil(assembled.outlineRoot, "The public removal must remain nil on this assembled control.")
            XCTAssertNil(try PDFCatalogStructurePreserver.originalEmptyOutline(emptyProof, for: assembled, staged: staged))

            // These controls have the same page count. A pre-existing staged
            // key must block recovery whether it is empty, null or nonempty.
            for data in [Self.emptyOutlineFixture("/Type /Outlines"),
                         Self.emptyOutlineFixture(nil, catalogOutlineOverride: "/Outlines null"),
                         Self.emptyOutlineFixture("/Type /Outlines /First 7 0 R /Last 7 0 R /Count 1", outlineChild: true)] {
                let stagedProvider = try XCTUnwrap(CGDataProvider(data: data as CFData))
                let stagedWithRoot = try XCTUnwrap(CGPDFDocument(stagedProvider))
                XCTAssertEqual(stagedWithRoot.numberOfPages, source.pageCount)
                let stagedCatalog = try XCTUnwrap(stagedWithRoot.catalog)
                XCTAssertNotNil(PDFCatalogStructurePreserver.object(stagedCatalog, "Outlines"))
                // Use the unchanged original owner rather than the already
                // edited source above, so this specifically tests staged state.
                let fresh = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.emptyOutlineFixture("/Type /Outlines")))
                try PDFCatalogStructurePreserver.prepare(fresh, force: true)
                let freshProof = try XCTUnwrap(PDFCatalogStructurePreserver.plan(for: fresh).emptyOutlineSource)
                XCTAssertNil(try PDFCatalogStructurePreserver.originalEmptyOutline(freshProof, for: fresh, staged: stagedWithRoot))
            }

            let nonempty = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.fixture()))
            try PDFCatalogStructurePreserver.prepare(nonempty, force: true)
            XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: nonempty).emptyOutlineSource,
                "An originally nonempty hierarchy never obtains empty-root recovery authority.")
            let preEdited = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.emptyOutlineFixture("/Type /Outlines /Title (Original)")))
            let editedRoot = PDFOutline(); editedRoot.label = "Edited before preparation"
            preEdited.outlineRoot = editedRoot
            try PDFCatalogStructurePreserver.prepare(preEdited, force: true)
            XCTAssertNil(try PDFCatalogStructurePreserver.plan(for: preEdited).emptyOutlineSource,
                "A captured current label cannot mint permission to restore a different literal original title.")
        }.value
    }

    func testCallerOutlineDropsAndOverridesWinOverEmptyRootRecovery() async throws {
        try await Task.detached {
            let source = try XCTUnwrap(PDFRawStreamProvenance.createdDocument(data: Self.emptyOutlineFixture("/Type /Outlines")))
            try PDFCatalogStructurePreserver.prepare(source, force: true)
            let staged = Self.emptyOutlineFixture(nil)
            var drop = try PDFCatalogStructurePreserver.plan(for: source)
            XCTAssertNotNil(drop.emptyOutlineSource)
            drop.catalogDrops.insert("Outlines")
            let dropped = try PDFBodyTextPageSnapshot.preservingCatalog(in: staged, from: source, plan: drop)
            let droppedOwner = try XCTUnwrap(PDFDocument(data: dropped)?.documentRef)
            XCTAssertNil(Self.dictionary(try XCTUnwrap(droppedOwner.catalog), "Outlines"))
            var override = try PDFCatalogStructurePreserver.plan(for: source)
            XCTAssertNotNil(override.emptyOutlineSource)
            override.catalogEntries["Outlines"] = .dictionary(["Type": .name("Outlines"), "Title": .string(Data("Caller root".utf8))])
            let changed = try PDFBodyTextPageSnapshot.preservingCatalog(in: staged, from: source, plan: override)
            let changedOwner = try XCTUnwrap(PDFDocument(data: changed)?.documentRef)
            let changedRoot = try XCTUnwrap(Self.dictionary(try XCTUnwrap(changedOwner.catalog), "Outlines"))
            XCTAssertEqual(try Self.nativeString(changedRoot, "Title"), Data("Caller root".utf8))
        }.value
    }

    nonisolated private static func emptyOutlineControls(_ catalog: CGPDFDictionaryRef) throws -> [String: String]? {
        guard let outlines = dictionary(catalog, "Outlines") else { return nil }
        var result: [String: String] = [:]
        CGPDFDictionaryApplyBlock(outlines, { key, value, _ in
            let name = String(cString: key)
            switch CGPDFObjectGetType(value) {
            case .name:
                var raw: UnsafePointer<CChar>?
                if CGPDFObjectGetValue(value, .name, &raw), let raw { result[name] = "name:" + String(cString: raw) }
            case .integer:
                var integer: CGPDFInteger = 0
                if CGPDFObjectGetValue(value, .integer, &integer) { result[name] = "integer:\(integer)" }
            case .string:
                var string: CGPDFStringRef?
                if CGPDFObjectGetValue(value, .string, &string), let string,
                   let raw = CGPDFStringGetBytePtr(string) {
                    let bytes = Data(bytes: raw, count: CGPDFStringGetLength(string))
                    result[name] = "string:" + bytes.map { String(format: "%02x", $0) }.joined()
                }
            default: result[name] = "unexpected-type:\(CGPDFObjectGetType(value).rawValue)"
            }
            return true
        }, nil)
        XCTAssertEqual(result.count, CGPDFDictionaryGetCount(outlines))
        return result
    }

    nonisolated private static func emptyOutlineFixture(_ outlineEntries: String?,
        catalogOutlineOverride: String? = nil, outlineChild: Bool = false) -> Data {
        let content = "BT /F1 12 Tf 20 80 Td (Owned empty outline body) Tj ET\n"
        let catalogOutline = catalogOutlineOverride ?? (outlineEntries == nil ? "" : "/Outlines 6 0 R")
        var objects = [Data("<< /Type /Catalog /Pages 2 0 R \(catalogOutline) >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 120] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
            Data("<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream".utf8)]
        if let outlineEntries { objects.append(Data("<< \(outlineEntries) >>".utf8)) }
        if outlineChild {
            precondition(outlineEntries != nil && objects.count == 6)
            objects.append(Data("<< /Title (Current staged item) /Parent 6 0 R /Dest [3 0 R /Fit] >>".utf8))
        }
        var data = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count); data.append(Data("\(index+1) 0 obj\n".utf8))
            data.append(object); data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

}
