// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import CryptoKit
import Foundation
import PDFKit
import zlib

/// Optional page-MCID authority only. Neither a serialized marker nor the
/// general body-origin flag can construct Commit or its two private receipts.
enum PDFBodyEditedTagPreserver {
    enum Refusal: Error { case unsupported, limit }
    struct Budget {
        var remaining = 500_000
        mutating func visit(_ count: Int = 1) throws {
            guard count >= 0, count <= remaining else { throw Refusal.limit }
            remaining -= count
            if remaining & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
        }
    }
    final class Permission: @unchecked Sendable {
        let originalDocument: CGPDFDocument
        let tagDocument: CGPDFDocument
        let sourceIndex: Int
        let changedMCID: Int
        private let owners: [Int: CGPDFDictionaryRef]
        private let commit: PDFBodyLosslessCommit
        var requiresPreservation: Bool { commit.rewrite.kind == .glyph }
        fileprivate init(original: CGPDFDocument, tag: CGPDFDocument, sourceIndex: Int,
                         changed: Int, owners: [Int: CGPDFDictionaryRef], commit: PDFBodyLosslessCommit) {
            originalDocument = original; tagDocument = tag; self.sourceIndex = sourceIndex
            changedMCID = changed; self.owners = owners; self.commit = commit
        }
        func matchesCurrent(_ page: PDFPage) -> Bool {
            page.pageRef?.dictionary == commit.current.dictionary
                && PDFRawStreamProvenance.source(for: page) === commit.currentRaw
                && commit.currentRaw.provesExactFactoryOwner(commit.currentOwner)
        }
        func permits(mcid: Int, owner: CGPDFDictionaryRef, document: CGPDFDocument) -> Bool {
            tagDocument === document && owners[mcid] == owner
        }
        func rebound(to auxiliary: PDFTagReadAuxiliary) throws -> Permission? {
            do {
                guard auxiliary.matches(original: originalDocument, raw: commit.originalRaw) else { return nil }
                var budget = Budget()
                guard let mapped = try reboundOwners(in: auxiliary.document, pageIndex: sourceIndex,
                    mcids: Set(owners.keys), budget: &budget) else { return nil }
                var forward: [UInt: UInt] = [:], reverse: [UInt: UInt] = [:]
                for (mcid, original) in owners {
                    try budget.visit()
                    guard let other = mapped[mcid] else { return nil }
                    let a = pdfReferenceIdentity(original), b = pdfReferenceIdentity(other)
                    guard forward[a].map({ $0 == b }) ?? true,
                          reverse[b].map({ $0 == a }) ?? true else { return nil }
                    forward[a] = b; reverse[b] = a
                }
                // Auxiliary qualification remains mandatory outside this
                // optional owner lookup. No old painting is authorized here.
                return Permission(original: originalDocument, tag: auxiliary.document, sourceIndex: sourceIndex,
                    changed: changedMCID, owners: mapped, commit: commit)
            } catch is CancellationError { throw CancellationError() }
            catch { return nil }
        }
    }

    static func prove(_ commit: PDFBodyLosslessCommit, source: CGPDFDocument,
                      sourceIndex: Int, painting: CGPDFPage, livePage: PDFPage) throws -> Permission? {
        try PDFSaveCancellation.checkCurrent()
        guard !Thread.isMainThread, sourceIndex >= 0, sourceIndex < source.numberOfPages,
              source === commit.originalOwner,
              source.page(at: sourceIndex + 1)?.dictionary == painting.dictionary,
              painting.dictionary == commit.original.dictionary,
              painting.dictionary == commit.copy.source.dictionary,
              livePage.pageRef?.dictionary == commit.current.dictionary,
              PDFRawStreamProvenance.source(for: livePage) === commit.currentRaw,
              commit.originalRaw.provesExactFactoryOwner(source),
              commit.currentRaw.provesExactFactoryOwner(commit.currentOwner) else { return nil }
        do {
            let glyph = commit.rewrite.kind == .glyph
            let originalMatches = glyph
                ? try commit.originalRaw.provesGlyphPaintingRoots(painting, in: source)
                : try commit.originalRaw.provesBodyTagPaintingRoots(painting, in: source)
            let currentMatches = glyph
                ? try commit.currentRaw.provesGlyphPaintingRoots(commit.current, in: commit.currentOwner)
                : try commit.currentRaw.provesBodyTagPaintingRoots(commit.current, in: commit.currentOwner)
            guard originalMatches, currentMatches,
                  try commit.currentRaw.signatureInputDigest(in: commit.currentOwner) == commit.copy.outputSHA256,
                  Data(SHA256.hash(data: commit.rewrite.rewritten)) == commit.copy.contentSHA256 else { return nil }
            var budget = Budget()
            let delta = try validateRewrite(commit.rewrite, donorName: commit.copy.donorName, budget: &budget)
            if let donor = commit.copy.donorProgram { try validateDonor(donor, budget: &budget) }
            else if commit.copy.donorName != nil { return nil }
            guard commit.copy.droppedForms == delta.removedForms else { return nil }
            try validateRemovedForms(commit, names: delta.removedForms, budget: &budget)
            let owners = try ownerMap(in: source, pageIndex: sourceIndex,
                                      mcids: delta.mcids, budget: &budget)
            guard let changedOwner = owners[delta.changed], let root = structureRoot(source) else { return nil }
            let chain = try validateChangedAncestry(changedOwner, root: root, budget: &budget)
            guard try commit.originalRaw.provesBodyTagOwnerMetadata(in: source, pageIndex: sourceIndex,
                mcid: delta.changed, chain: chain, paragraphStyleCommit: commit) else { return nil }
            let permission = Permission(original: source, tag: source, sourceIndex: sourceIndex,
                changed: delta.changed, owners: owners, commit: commit)
            guard permission.matchesCurrent(livePage) else { return nil }
            try PDFSaveCancellation.checkCurrent()
            return permission
        } catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    /// Non-authoritative native owner lookup; only a factory-bound private
    /// Permission can use its result. Unsupported auxiliary reader shapes must
    /// not turn the optional preservation feature into a whole-save error.
    static func reboundOwners(in document: CGPDFDocument, pageIndex: Int, mcids: Set<Int>,
                              budget: inout Budget) throws -> [Int: CGPDFDictionaryRef]? {
        try PDFSaveCancellation.checkCurrent()
        do { return try ownerMap(in: document, pageIndex: pageIndex, mcids: mcids, budget: &budget) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    struct Delta { let changed: Int; let mcids: Set<Int>; let removedForms: Set<String> }
    struct Operation {
        let command: String
        let operands: [PDFBodyTextContentStream.Lexer.Token]
        let range: Range<Int>
        let mcid: Int?
        let block: Int?
        let renderingMode: Int
        let scopeSafe: Bool
    }
    struct Mark: Equatable { let tag: String; let property: Data; let mcid: Int?; let depth: Int }
    struct Trace {
        let operations: [Operation]
        let marks: [Mark]
        let mcids: Set<Int>
        let shows: [Int: Set<Range<Int>>]
    }

    /// Stateless validation is testable, but cannot mint a Permission. Only a
    /// private Editor commit plus construction receipt reaches prove().
    static func validateRewrite(_ receipt: PDFBodyLosslessRewriteReceipt, donorName: String?,
                                budget: inout Budget) throws -> Delta {
        guard receipt.source.count <= 2 * 1_024 * 1_024,
              receipt.rewritten.count <= 2 * 1_024 * 1_024,
              receipt.patches.count <= 256, receipt.kind != .mixed else { throw Refusal.unsupported }
        var bytes = Data(), cursor = 0
        for patch in receipt.patches {
            try budget.visit()
            guard patch.range.lowerBound >= cursor, patch.range.upperBound <= receipt.source.count else { throw Refusal.unsupported }
            bytes.append(receipt.source[cursor..<patch.range.lowerBound]); bytes.append(patch.bytes)
            cursor = patch.range.upperBound
        }
        bytes.append(receipt.source[cursor..<receipt.source.count])
        guard bytes == receipt.rewritten else { throw Refusal.unsupported }
        let original = try trace(receipt.source, budget: &budget)
        let current = try trace(receipt.rewritten, budget: &budget)
        guard original.marks == current.marks, original.mcids == current.mcids,
              !original.mcids.isEmpty, original.mcids.count <= 100_000 else { throw Refusal.unsupported }
        let byRange = Dictionary(uniqueKeysWithValues: original.operations.map { ($0.range, $0) })
        if receipt.kind == .glyph {
            guard donorName == nil, receipt.patches.count == 1, let patch = receipt.patches.first,
                  let operation = byRange[patch.range], operation.command == "Tj", operation.scopeSafe,
                  operation.renderingMode == 0, let mcid = operation.mcid,
                  let before = operation.operands.first?.stringBytes, before.count.isMultiple(of: 2),
                  before.count <= 1024 else { throw Refusal.unsupported }
            var lexer = PDFBodyTextContentStream.Lexer(bytes: Array(patch.bytes))
            guard let after = try lexer.next()?.stringBytes, after.count == before.count,
                  try lexer.next()?.command == "Tj", try lexer.next() == nil else { throw Refusal.unsupported }
            var differences = 0
            for offset in stride(from: 0, to: before.count, by: 2) {
                if before[offset] != after[offset] || before[offset + 1] != after[offset + 1] { differences += 1 }
            }
            guard differences == 1 else { throw Refusal.unsupported }
            return Delta(changed: mcid, mcids: original.mcids, removedForms: [])
        }
        var changed = Set<Int>(), removed: [Int: Set<Range<Int>>] = [:], forms = Set<String>(), insertions = 0
        for patch in receipt.patches {
            try budget.visit()
            if patch.range.isEmpty {
                guard let previous = original.operations.first(where: { $0.range.upperBound == patch.range.lowerBound }),
                      previous.command == "ET", previous.scopeSafe, let mcid = previous.mcid,
                      try invocation(patch.bytes, expected: donorName, budget: &budget) else { throw Refusal.unsupported }
                changed.insert(mcid); insertions += 1
            } else {
                guard let operation = byRange[patch.range], operation.scopeSafe, let mcid = operation.mcid else { throw Refusal.unsupported }
                changed.insert(mcid)
                if operation.command == "Tj" || operation.command == "TJ" {
                    guard patch.bytes == Data("[] TJ".utf8), operation.renderingMode == 0,
                          let block = operation.block else { throw Refusal.unsupported }
                    removed[block, default: []].insert(operation.range)
                } else if operation.command == "Do", let name = operation.operands.first?.name {
                    let valid = patch.bytes.isEmpty ? true : try invocation(patch.bytes, expected: donorName, budget: &budget)
                    guard receipt.kind == .forms, valid else { throw Refusal.unsupported }
                    forms.insert(name); if !patch.bytes.isEmpty { insertions += 1 }
                } else { throw Refusal.unsupported }
            }
        }
        guard changed.count == 1, let mcid = changed.first,
              insertions == (donorName == nil ? 0 : 1), forms.count <= 1,
              original.operations.filter({ $0.mcid == mcid && $0.command == "q" }).count <= 64 else { throw Refusal.unsupported }
        for (block, shows) in removed {
            guard original.shows[block] == shows else { throw Refusal.unsupported }
        }
        return Delta(changed: mcid, mcids: original.mcids, removedForms: forms)
    }

    static func trace(_ data: Data, budget: inout Budget) throws -> Trace {
        guard data.count <= 2 * 1_024 * 1_024 else { throw Refusal.limit }
        var lexer = PDFBodyTextContentStream.Lexer(bytes: Array(data))
        var operands: [PDFBodyTextContentStream.Lexer.Token] = [], operations: [Operation] = [], marks: [Mark] = []
        var stack: [(Int?, Bool)] = [], active: Int?, scopeSafe = true, mcids = Set<Int>(), mode = 0, graphics: [Int] = []
        var block: Int?, blockMarkDepth = 0, shows: [Int: Set<Range<Int>>] = [:]
        while let token = try lexer.next() {
            try budget.visit()
            guard let command = token.command else {
                operands.append(token); guard operands.count <= 256 else { throw Refusal.limit }; continue
            }
            guard operations.count < 50_000 else { throw Refusal.limit }
            let start = operands.first?.range.lowerBound ?? token.range.lowerBound
            let range = start..<token.range.upperBound
            if command == "BI" || command == "ID" || command == "EI" { throw Refusal.unsupported }
            switch command {
            case "q":
                guard operands.isEmpty, block == nil, graphics.count < 64 else { throw Refusal.unsupported }; graphics.append(mode)
            case "Q":
                guard operands.isEmpty, block == nil, let old = graphics.popLast() else { throw Refusal.unsupported }; mode = old
            case "cm":
                guard block == nil, operands.count == 6,
                      operands.allSatisfy({ $0.number?.isFinite == true }) else { throw Refusal.unsupported }
            case "Tr":
                guard operands.count == 1, let value = operands[0].number,
                      value.rounded() == value, (0...7).contains(value) else { throw Refusal.unsupported }; mode = Int(value)
            case "BT":
                guard operands.isEmpty, block == nil else { throw Refusal.unsupported }; block = operations.count; blockMarkDepth = stack.count
            case "ET": guard operands.isEmpty, block != nil, stack.count == blockMarkDepth else { throw Refusal.unsupported }
            case "BMC", "BDC":
                guard operands.count == (command == "BMC" ? 1 : 2), let tag = operands[0].name,
                      stack.count < 64 else { throw Refusal.unsupported }
                var id: Int?, propertySafe = tag != "OC"
                if command == "BDC" {
                    guard let properties = operands[1].dictionary else { throw Refusal.unsupported }
                    propertySafe = propertySafe && Set(properties.keys).isSubset(of: ["MCID", "Lang"])
                    if let language = properties["Lang"], language.stringBytes == nil { propertySafe = false }
                    if let property = properties["MCID"] {
                        guard let value = property.number, value >= 0, value < 100_000,
                              value.rounded() == value, active == nil,
                              mcids.insert(Int(value)).inserted else { throw Refusal.unsupported }; id = Int(value)
                    }
                }
                let property = command == "BDC" ? data[operands[1].range] : Data()
                marks.append(Mark(tag: tag, property: Data(property), mcid: id, depth: stack.count))
                stack.append((active, scopeSafe)); scopeSafe = scopeSafe && propertySafe
                if let id { active = id }
            case "EMC":
                guard operands.isEmpty, let prior = stack.popLast() else { throw Refusal.unsupported }
                active = prior.0; scopeSafe = prior.1
            case "Tj", "TJ":
                guard operands.count == 1, let block else { throw Refusal.unsupported }
                shows[block, default: []].insert(range)
            case "'", "\"": throw Refusal.unsupported
            default: break
            }
            operations.append(Operation(command: command, operands: operands, range: range,
                mcid: active, block: block, renderingMode: mode, scopeSafe: scopeSafe))
            if command == "ET" { block = nil }
            operands.removeAll(keepingCapacity: true)
        }
        guard operands.isEmpty, stack.isEmpty, graphics.isEmpty, block == nil else { throw Refusal.unsupported }
        return Trace(operations: operations, marks: marks, mcids: mcids, shows: shows)
    }

    private static func invocation(_ data: Data, expected: String?, budget: inout Budget) throws -> Bool {
        guard let expected, !expected.isEmpty, expected.utf8.count <= 128, data.count <= 16 * 1_024 else { return false }
        let parsed = try trace(data, budget: &budget)
        guard parsed.marks.isEmpty, parsed.operations.map(\.command) == ["q", "cm", "Do", "Q"] else { return false }
        let matrix = parsed.operations[1].operands.compactMap(\.number)
        return matrix.count == 6 && matrix.allSatisfy { $0.isFinite && abs($0) <= 1_000_000_000 }
            && abs(matrix[0] * matrix[3] - matrix[1] * matrix[2]) > 0.000001
            && parsed.operations[2].operands.count == 1 && parsed.operations[2].operands[0].name == expected
    }

    static func validateDonor(_ data: Data, budget: inout Budget) throws {
        guard data.count <= 1_024 * 1_024 else { throw Refusal.limit }
        let parsed = try trace(data, budget: &budget)
        let allowed: Set<String> = ["q", "Q", "cm", "gs", "BT", "ET", "Tf", "Tr", "Tm", "Td", "TD", "T*",
            "Tc", "Tw", "Tz", "TL", "Ts", "Tj", "TJ", "g", "G", "rg", "RG", "k", "K", "cs", "CS",
            "sc", "SC", "scn", "SCN", "ri", "w", "J", "j", "M", "d"]
        guard parsed.marks.isEmpty, parsed.operations.allSatisfy({ allowed.contains($0.command) }),
              parsed.operations.filter({ $0.command == "Tj" || $0.command == "TJ" }).allSatisfy({ $0.renderingMode == 0 })
        else { throw Refusal.unsupported }
    }

    private static func validateRemovedForms(_ commit: PDFBodyLosslessCommit, names: Set<String>,
                                             budget: inout Budget) throws {
        guard names.count <= 1 else { throw Refusal.unsupported }
        guard !names.isEmpty else { return }
        guard let object = commit.copy.resources else { throw Refusal.unsupported }
        var resources: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &resources), let resources,
              let objects = PDFCatalogStructurePreserver.dictionary(resources, "XObject"),
              CGPDFDictionaryGetCount(objects) <= 4_096 else { throw Refusal.unsupported }
        let page = try trace(commit.rewrite.source, budget: &budget)
        for name in names {
            try budget.visit()
            guard page.operations.filter({ $0.command == "Do" && $0.operands.first?.name == name }).count == 1,
                  let value = PDFCatalogStructurePreserver.object(objects, name) else { throw Refusal.unsupported }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { throw Refusal.unsupported }
            for key in ["StructParent", "StructParents", "ActualText", "Alt", "E", "T", "F", "FFilter", "FDecodeParms"] {
                guard PDFCatalogStructurePreserver.object(dictionary, key) == nil else { throw Refusal.unsupported }
            }
            var aliases = 0
            CGPDFDictionaryApplyBlock(objects, { _, value, _ in
                var other: CGPDFStreamRef?
                if CGPDFObjectGetValue(value, .stream, &other), let other,
                   pdfReferenceIdentity(other) == pdfReferenceIdentity(stream) { aliases += 1 }
                return true
            }, nil)
            guard aliases == 1,
                  let encoded = try commit.originalRaw.bodyTagEncodedProgram(for: stream, in: commit.originalOwner)
            else { throw Refusal.unsupported }
            let program: Data
            if let filter = PDFCatalogStructurePreserver.object(dictionary, "Filter") {
                var name: UnsafePointer<CChar>?
                guard CGPDFObjectGetValue(filter, .name, &name), let name, strcmp(name, "FlateDecode") == 0 else { throw Refusal.unsupported }
                if let parameters = PDFCatalogStructurePreserver.object(dictionary, "DecodeParms") {
                    guard CGPDFObjectGetType(parameters) == .null else { throw Refusal.unsupported }
                }
                program = try boundedInflate(encoded)
            } else {
                guard PDFCatalogStructurePreserver.object(dictionary, "DecodeParms") == nil else { throw Refusal.unsupported }
                program = encoded
            }
            try validateDonor(program, budget: &budget)
        }
    }

    /// Existing C pipeline bounds encoded bytes before allocation. This local
    /// decoder bounds every accepted output chunk, requires EOF/checksum and
    /// refuses trailing input. It decodes a selected text Form only.
    private static func boundedInflate(_ encoded: Data) throws -> Data {
        guard encoded.count <= 2 * 1_024 * 1_024 else { throw Refusal.limit }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Refusal.unsupported }
        defer { inflateEnd(&stream) }
        return try encoded.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(input.count)
            var result = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try PDFSaveCancellation.checkCurrent()
                let before = stream.avail_in
                let status = buffer.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let made = buffer.count - Int(stream.avail_out)
                guard made <= 1_024 * 1_024 - result.count else { throw Refusal.limit }
                result.append(contentsOf: buffer.prefix(made))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw Refusal.unsupported }
                    return result
                }
                guard status == Z_OK, made > 0 || stream.avail_in < before else { throw Refusal.unsupported }
            }
        }
    }

    private static func structureRoot(_ document: CGPDFDocument) -> CGPDFDictionaryRef? {
        document.catalog.flatMap { PDFCatalogStructurePreserver.dictionary($0, "StructTreeRoot") }
    }
    private static func ownerMap(in document: CGPDFDocument, pageIndex: Int, mcids: Set<Int>,
                                 budget: inout Budget) throws -> [Int: CGPDFDictionaryRef] {
        guard pageIndex >= 0, pageIndex < document.numberOfPages,
              let page = document.page(at: pageIndex + 1)?.dictionary, let root = structureRoot(document),
              let tree = PDFCatalogStructurePreserver.dictionary(root, "ParentTree") else { throw Refusal.unsupported }
        var parentKey: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(page, "StructParents", &parentKey), parentKey >= 0 else { throw Refusal.unsupported }
        var pending = [(tree, 0)], seen = Set<UInt>(), found: CGPDFArrayRef?
        while let (node, depth) = pending.popLast() {
            try budget.visit()
            guard depth < 64, seen.insert(pdfReferenceIdentity(node)).inserted else { throw Refusal.unsupported }
            if let nums = PDFCatalogStructurePreserver.array(node, "Nums") {
                let count = CGPDFArrayGetCount(nums)
                guard count <= 200_000, count % 2 == 0 else { throw Refusal.limit }
                for index in stride(from: 0, to: count, by: 2) {
                    try budget.visit()
                    var key: CGPDFInteger = 0
                    guard CGPDFArrayGetInteger(nums, index, &key) else { throw Refusal.unsupported }
                    if key == parentKey {
                        var values: CGPDFArrayRef?
                        guard found == nil, CGPDFArrayGetArray(nums, index + 1, &values), let values,
                              CGPDFArrayGetCount(values) <= 100_000 else { throw Refusal.unsupported }; found = values
                    }
                }
            }
            if let kids = PDFCatalogStructurePreserver.array(node, "Kids") {
                let count = CGPDFArrayGetCount(kids); guard count <= 4_096 else { throw Refusal.limit }
                for index in 0..<count {
                    var child: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(kids, index, &child), let child else { throw Refusal.unsupported }
                    pending.append((child, depth + 1))
                }
            }
        }
        guard let found else { throw Refusal.unsupported }
        var result: [Int: CGPDFDictionaryRef] = [:]
        for mcid in mcids {
            try budget.visit()
            var owner: CGPDFDictionaryRef?
            guard mcid >= 0, mcid < CGPDFArrayGetCount(found), CGPDFArrayGetDictionary(found, mcid, &owner), let owner else { throw Refusal.unsupported }
            result[mcid] = owner
        }
        return result
    }

    private static func validateChangedAncestry(_ owner: CGPDFDictionaryRef, root: CGPDFDictionaryRef,
                                               budget: inout Budget) throws -> [CGPDFDictionaryRef] {
        var node = owner, seen = Set<UInt>(), chain: [CGPDFDictionaryRef] = []
        for _ in 0..<128 {
            try budget.visit()
            guard seen.insert(pdfReferenceIdentity(node)).inserted else { throw Refusal.unsupported }
            chain.append(node)
            for key in ["ActualText", "Alt", "E", "T"] {
                guard PDFCatalogStructurePreserver.object(node, key) == nil else { throw Refusal.unsupported }
            }
            if let attributes = PDFCatalogStructurePreserver.object(node, "A") {
                guard inertAttributes(attributes) else { throw Refusal.unsupported }
            }
            if let value = PDFCatalogStructurePreserver.object(node, "C") {
                var name: UnsafePointer<CChar>?
                guard CGPDFObjectGetValue(value, .name, &name), let name, strnlen(name, 4_097) <= 4_096,
                      CGPDFObjectGetType(value) == .name else { throw Refusal.unsupported }
                // Actual byte-name/ClassMap resolution is independently done
                // inside the original RawSource lock, without CString lookup.
            }
            if node == root { return chain }
            guard let parent = PDFCatalogStructurePreserver.dictionary(node, "P"),
                  let children = PDFCatalogStructurePreserver.object(parent, "K"),
                  try containsChild(children, child: node, depth: 0, budget: &budget) else { throw Refusal.unsupported }
            node = parent
        }
        throw Refusal.limit
    }
    private static func inertAttributes(_ value: CGPDFObjectRef) -> Bool {
        switch CGPDFObjectGetType(value) {
        case .array:
            var array: CGPDFArrayRef?
            return CGPDFObjectGetValue(value, .array, &array) && array.map { CGPDFArrayGetCount($0) == 0 } == true
        case .dictionary:
            var dictionary: CGPDFDictionaryRef?
            return CGPDFObjectGetValue(value, .dictionary, &dictionary) && dictionary.map { CGPDFDictionaryGetCount($0) == 0 } == true
        default: return false
        }
    }
    private static func containsChild(_ value: CGPDFObjectRef, child: CGPDFDictionaryRef, depth: Int,
                                      budget: inout Budget) throws -> Bool {
        try budget.visit(); guard depth < 64 else { throw Refusal.limit }
        if CGPDFObjectGetType(value) == .dictionary {
            var dictionary: CGPDFDictionaryRef?
            return CGPDFObjectGetValue(value, .dictionary, &dictionary) && dictionary == child
        }
        guard CGPDFObjectGetType(value) == .array else { return false }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(value, .array, &array), let array else { throw Refusal.unsupported }
        let count = CGPDFArrayGetCount(array); guard count <= 100_000 else { throw Refusal.limit }
        for index in 0..<count {
            var member: CGPDFObjectRef?
            guard CGPDFArrayGetObject(array, index, &member), let member else { throw Refusal.unsupported }
            if try containsChild(member, child: child, depth: depth + 1, budget: &budget) { return true }
        }
        return false
    }
}
