// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// Non-authoritative evidence produced by the actual byte-patch boundary.
/// A matching program alone cannot authorize retaining a structure owner.
struct PDFBodyLosslessRewriteReceipt {
    enum Kind: Equatable { case blocks, records, forms, mixed, glyph }
    struct Patch { let range: Range<Int>; let bytes: Data }
    let source: Data
    let rewritten: Data
    let patches: [Patch]
    let kind: Kind
    fileprivate init(source: Data, rewritten: Data, changes: [(range: Range<Int>, bytes: Data)], kind: Kind) {
        self.source = source.withUnsafeBytes { Data($0) }
        self.rewritten = rewritten.withUnsafeBytes { Data($0) }
        patches = changes.map { Patch(range: $0.range, bytes: $0.bytes.withUnsafeBytes { Data($0) }) }
        self.kind = kind
    }
}

/// Bounded lexical inspection for the lossless edit path. Original bytes are
/// retained verbatim; only a validated, complete text-show command is removed.
/// Strings, comments, hex strings, arrays and dictionaries are single operands,
/// so text that happens to contain PDF operators can never become a command.
struct PDFBodyTextContentStream {
    struct TextRecord {
        let blockStart: Int
        let showRange: Range<Int>
        let insertionOffset: Int
        let transform: CGAffineTransform
        let graphicsStateNames: [String]
        let isSupported: Bool
        let glyphOperand: GlyphOperand?
    }

    struct GlyphOperand {
        let font: String
        let bytes: [UInt8]
    }

    struct FormRecord {
        let name: String
        let showRange: Range<Int>
        let insertionOffset: Int
        let transform: CGAffineTransform
        let graphicsStateNames: [String]
        let isSupported: Bool
    }

    /// A complete text object can contain many shows, including tagged space
    /// placeholders. Replacing the whole object preserves later text advances.
    struct TextBlock {
        let range: Range<Int>
        let showRanges: [Range<Int>]
        let transform: CGAffineTransform
        let graphicsStateNames: [String]
        let isSupported: Bool
        let whitespaceMarkupRanges: [Range<Int>]
    }

    enum ParseFailure: Error { case unsupported, malformed, limitExceeded }
    let data: Data
    let records: [TextRecord]
    let forms: [FormRecord]
    let blocks: [TextBlock]

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1_024 * 1_024 else { throw ParseFailure.limitExceeded }
        var lexer = Lexer(bytes: Array(data))
        struct State {
            var transform = CGAffineTransform.identity
            var renderMode = 0
            var font: String?
            var graphicsStateNames: [String] = []
        }
        struct Block {
            let start: Int
            let marked: Bool
            let startingMarkedDepth: Int
            var safe = true
            var wholeBlockSafe = true
            var shows: [Range<Int>] = []
            var allShows: [Range<Int>] = []
            var whitespaceMarkupRanges: [Range<Int>] = []
            var glyphOperands: [Int: GlyphOperand] = [:]
        }
        struct MarkedScope {
            let openingRange: Range<Int>
            let supported: Bool
            let hasActualText: Bool
            let textBlockStart: Int?
        }
        var state = State()
        var stack: [State] = []
        var markedScopes: [MarkedScope] = []
        var block: Block?
        var operands: [Lexer.Token] = []
        var records: [TextRecord] = []
        var forms: [FormRecord] = []
        var blocks: [TextBlock] = []
        var commands = 0
        let allowedInText: Set<String> = ["Tc", "Tw", "Tz", "TL", "Tf", "Tr", "Ts", "Tm", "Td", "TD", "T*", "Tj", "TJ", "'", "\"", "ET"]
        let allowedInWholeText = allowedInText.union([
            "g", "G", "rg", "RG", "k", "K", "cs", "CS", "sc", "SC", "scn", "SCN",
            "gs", "ri", "BMC", "BDC", "EMC"
        ])
        while let token = try lexer.next() {
            guard let command = token.command else {
                operands.append(token)
                guard operands.count <= 256 else { throw ParseFailure.limitExceeded }
                continue
            }
            commands += 1
            guard commands <= 250_000 else { throw ParseFailure.limitExceeded }
            if block != nil, !allowedInText.contains(command) { block?.safe = false }
            if block != nil, !allowedInWholeText.contains(command) { block?.wholeBlockSafe = false }
            switch command {
            case "BI":
                guard block == nil, operands.isEmpty else { throw ParseFailure.unsupported }
                try lexer.skipUnfilteredImageMask()
            case "ID", "EI": throw ParseFailure.malformed
            case "q":
                guard operands.isEmpty, stack.count < 64 else { throw ParseFailure.malformed }
                stack.append(state)
            case "Q":
                guard operands.isEmpty, let saved = stack.popLast() else { throw ParseFailure.malformed }
                state = saved
            case "cm":
                let numbers = operands.compactMap(\.number)
                guard numbers.count == 6, operands.count == 6 else { throw ParseFailure.malformed }
                let matrix = CGAffineTransform(a: numbers[0], b: numbers[1], c: numbers[2], d: numbers[3], tx: numbers[4], ty: numbers[5])
                state.transform = matrix.concatenating(state.transform)
                guard finite(state.transform) else { throw ParseFailure.malformed }
            case "gs":
                guard operands.count == 1, let name = operands[0].name else { throw ParseFailure.malformed }
                if !state.graphicsStateNames.contains(name) { state.graphicsStateNames.append(name) }
                guard state.graphicsStateNames.count <= 256 else { throw ParseFailure.limitExceeded }
            case "Tf":
                state.font = operands.count == 2 && operands[1].number.map { $0 > 0 } == true
                    ? operands[0].name : nil
            case "Do":
                guard operands.count == 1, let name = operands[0].name else { throw ParseFailure.malformed }
                let determinant = state.transform.a * state.transform.d - state.transform.b * state.transform.c
                forms.append(FormRecord(name: name, showRange: operands[0].range.lowerBound..<token.range.upperBound,
                    insertionOffset: token.range.upperBound, transform: state.transform,
                    graphicsStateNames: state.graphicsStateNames,
                    isSupported: block == nil
                        && markedScopes.allSatisfy { $0.supported && !$0.hasActualText }
                        && abs(determinant) > 0.000_000_1))
            case "BMC", "BDC":
                guard operands.count == (command == "BMC" ? 1 : 2),
                      let tag = operands[0].name else { throw ParseFailure.malformed }
                let properties = command == "BDC" ? operands[1].dictionary : [:]
                let hasActualText = properties?["ActualText"] != nil
                let supported = tag != "OC" && properties.map(markedPropertiesAreSupported) == true
                if !supported { block?.wholeBlockSafe = false }
                markedScopes.append(MarkedScope(
                    openingRange: operands[0].range.lowerBound..<token.range.upperBound,
                    supported: supported, hasActualText: hasActualText, textBlockStart: block?.start
                ))
                guard markedScopes.count <= 64 else { throw ParseFailure.limitExceeded }
            case "EMC":
                guard operands.isEmpty, let scope = markedScopes.popLast() else { throw ParseFailure.malformed }
                if scope.hasActualText, scope.supported,
                   let start = block?.start, scope.textBlockStart == start {
                    block?.whitespaceMarkupRanges.append(scope.openingRange)
                    block?.whitespaceMarkupRanges.append(token.range)
                }
            case "BT":
                guard block == nil, operands.isEmpty else { throw ParseFailure.malformed }
                block = Block(start: token.range.lowerBound, marked: !markedScopes.isEmpty,
                    startingMarkedDepth: markedScopes.count,
                    wholeBlockSafe: markedScopes.allSatisfy { $0.supported && !$0.hasActualText })
            case "Tr":
                guard operands.count == 1, let number = operands[0].number,
                      number.rounded() == number, (0...7).contains(number) else { throw ParseFailure.malformed }
                state.renderMode = Int(number)
            case "Tj", "TJ", "'", "\"":
                guard block != nil, !operands.isEmpty else { throw ParseFailure.malformed }
                let expected = command == "\"" ? 3 : 1
                guard operands.count == expected else { throw ParseFailure.malformed }
                block?.allShows.append(operands[0].range.lowerBound..<token.range.upperBound)
                if state.renderMode != 0 || command == "'" || command == "\"" { block?.wholeBlockSafe = false }
                if operands.contains(where: \.hasText) {
                    let start = operands[0].range.lowerBound
                    block?.shows.append(start..<token.range.upperBound)
                    if command == "Tj", state.renderMode == 0, let font = state.font,
                       let bytes = operands[0].stringBytes, !bytes.isEmpty, bytes.count <= 1024,
                       markedScopes.allSatisfy({ $0.supported && !$0.hasActualText }) {
                        block?.glyphOperands[start] = GlyphOperand(font: font, bytes: bytes)
                    }
                    if state.renderMode != 0 || command == "'" || command == "\"" { block?.safe = false }
                }
            case "ET":
                guard let completed = block, operands.isEmpty else { throw ParseFailure.malformed }
                // Keep the completed snapshot independent of the active
                // optional's lifetime for older Swift release optimizers.
                block = nil
                let determinant = state.transform.a * state.transform.d - state.transform.b * state.transform.c
                let safe = completed.safe && !completed.marked && completed.shows.count == 1
                    && abs(determinant) > 0.000_000_1 && finite(state.transform)
                for show in completed.shows {
                    records.append(TextRecord(blockStart: completed.start, showRange: show,
                        insertionOffset: token.range.upperBound, transform: state.transform,
                        graphicsStateNames: state.graphicsStateNames, isSupported: safe,
                        glyphOperand: completed.glyphOperands[show.lowerBound]))
                }
                blocks.append(TextBlock(range: completed.start..<token.range.upperBound,
                    showRanges: completed.allShows, transform: state.transform,
                    graphicsStateNames: state.graphicsStateNames,
                    isSupported: completed.wholeBlockSafe && !completed.allShows.isEmpty
                        && markedScopes.count == completed.startingMarkedDepth
                        && abs(determinant) > 0.000_000_1 && finite(state.transform),
                    whitespaceMarkupRanges: completed.whitespaceMarkupRanges))
            default:
                break
            }
            operands.removeAll(keepingCapacity: true)
        }
        guard operands.isEmpty, block == nil, stack.isEmpty, markedScopes.isEmpty else { throw ParseFailure.malformed }
        return Self(data: data, records: records, forms: forms, blocks: blocks)
    }

    func rewritingBlocks(blockIndices: [Int], donorInvocation: String?,
                         capture: ((PDFBodyLosslessRewriteReceipt) -> Void)? = nil) throws -> Data {
        let selected = Array(Set(blockIndices)).sorted()
        guard !selected.isEmpty, selected.count == blockIndices.count,
              selected.allSatisfy({ blocks.indices.contains($0) && blocks[$0].isSupported }) else {
            throw ParseFailure.unsupported
        }
        var patches: [(range: Range<Int>, bytes: Data)] = []
        for index in selected {
            patches += blocks[index].showRanges.map { ($0, Data("[] TJ".utf8)) }
            // An empty show under ActualText still contributes a semantic
            // space in some readers. Remove only these nested space wrappers.
            patches += blocks[index].whitespaceMarkupRanges.map { ($0, Data()) }
        }
        if let donorInvocation, let first = selected.first {
            let offset = blocks[first].range.upperBound
            patches.append((offset..<offset, Data(("\n" + donorInvocation + "\n").utf8)))
        }
        return try applying(patches, kind: .blocks, capture: capture)
    }

    func replacingGlyph(_ patch: PDFBodyTextGlyphSubstitution.Patch,
                        capture: ((PDFBodyLosslessRewriteReceipt) -> Void)?) throws -> Data {
        try applying([(patch.range, patch.command)], kind: .glyph, capture: capture)
    }

    func rewriting(recordIndices: [Int], donorInvocation: String?,
                   capture: ((PDFBodyLosslessRewriteReceipt) -> Void)? = nil) throws -> Data {
        let selected = Array(Set(recordIndices)).sorted()
        guard !selected.isEmpty, selected.count == recordIndices.count,
              selected.allSatisfy({ records.indices.contains($0) && records[$0].isSupported }) else {
            throw ParseFailure.unsupported
        }
        var patches: [(range: Range<Int>, bytes: Data)] = selected.map {
            (records[$0].showRange, Data("[] TJ".utf8))
        }
        if let donorInvocation, let first = selected.first {
            let offset = records[first].insertionOffset
            patches.append((offset..<offset, Data(("\n" + donorInvocation + "\n").utf8)))
        }
        return try applying(patches, kind: .records, capture: capture)
    }

    func rewritingForms(recordIndices: [Int], donorInvocation: String?,
                        capture: ((PDFBodyLosslessRewriteReceipt) -> Void)? = nil) throws -> Data {
        let selected = Array(Set(recordIndices)).sorted()
        guard !selected.isEmpty, selected.count == recordIndices.count,
              selected.allSatisfy({ forms.indices.contains($0) && forms[$0].isSupported }) else {
            throw ParseFailure.unsupported
        }
        var patches: [(range: Range<Int>, bytes: Data)] = selected.map { (forms[$0].showRange, Data()) }
        if let donorInvocation, let first = selected.first {
            patches[0].bytes = Data(("\n" + donorInvocation + "\n").utf8)
            assert(patches[0].range == forms[first].showRange)
        }
        return try applying(patches, kind: .forms, capture: capture)
    }

    /// A paragraph reselected after row preservation can contain original
    /// text blocks and an app-owned donor invocation. The caller independently
    /// verifies native ownership and the complete, consecutive root span.
    func rewritingMixed(blockIndices: [Int], formIndices: [Int], insertionOffset: Int,
                        donorInvocation: String?,
                        capture: ((PDFBodyLosslessRewriteReceipt) -> Void)? = nil) throws -> Data {
        guard blockIndices.count == Set(blockIndices).count,
              formIndices.count == Set(formIndices).count,
              !formIndices.isEmpty,
              blockIndices.allSatisfy({ blocks.indices.contains($0) && blocks[$0].isSupported }),
              formIndices.allSatisfy({ forms.indices.contains($0) && forms[$0].isSupported }),
              blockIndices.contains(where: { blocks[$0].range.upperBound == insertionOffset })
                || formIndices.contains(where: { forms[$0].insertionOffset == insertionOffset }) else {
            throw ParseFailure.unsupported
        }
        var patches: [(range: Range<Int>, bytes: Data)] = []
        for index in blockIndices {
            patches += blocks[index].showRanges.map { ($0, Data("[] TJ".utf8)) }
            patches += blocks[index].whitespaceMarkupRanges.map { ($0, Data()) }
        }
        patches += formIndices.map { (forms[$0].showRange, Data()) }
        if let donorInvocation {
            patches.append((insertionOffset..<insertionOffset, Data(("\n" + donorInvocation + "\n").utf8)))
        }
        return try applying(patches, kind: .mixed, capture: capture)
    }

    private func applying(_ changes: [(range: Range<Int>, bytes: Data)], kind: PDFBodyLosslessRewriteReceipt.Kind,
                          capture: ((PDFBodyLosslessRewriteReceipt) -> Void)?) throws -> Data {
        let patches = changes.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var result = Data()
        var cursor = 0
        for patch in patches {
            guard patch.range.lowerBound >= cursor else { throw ParseFailure.malformed }
            result.append(data[cursor..<patch.range.lowerBound])
            result.append(patch.bytes)
            cursor = patch.range.upperBound
        }
        result.append(data[cursor..<data.count])
        guard result.count <= 64 * 1_024 * 1_024 else { throw ParseFailure.limitExceeded }
        // This optional evidence never changes editing admission. Bound both
        // retained programs and selected patches independently of the editor.
        if let capture, data.count <= 2 * 1_024 * 1_024, result.count <= 2 * 1_024 * 1_024,
           patches.count <= 256, patches.allSatisfy({ $0.bytes.count <= 16 * 1_024 }) {
            capture(PDFBodyLosslessRewriteReceipt(source: data, rewritten: result, changes: patches, kind: kind))
        }
        return result
    }

    private static func finite(_ value: CGAffineTransform) -> Bool {
        [value.a, value.b, value.c, value.d, value.tx, value.ty].allSatisfy(\.isFinite)
    }

    private static func markedPropertiesAreSupported(_ properties: [String: Lexer.Token]) -> Bool {
        guard Set(properties.keys).isSubset(of: ["Lang", "MCID", "ActualText"]) else { return false }
        if let language = properties["Lang"], language.stringBytes == nil { return false }
        if let identifier = properties["MCID"] {
            guard let number = identifier.number, number >= 0, number.rounded() == number else { return false }
        }
        if let actual = properties["ActualText"] {
            guard let bytes = actual.stringBytes, !bytes.isEmpty else { return false }
            if bytes.starts(with: [0xFE, 0xFF]) {
                guard let text = String(data: Data(bytes.dropFirst(2)), encoding: .utf16BigEndian),
                      !text.isEmpty,
                      text.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else { return false }
            } else {
                // PDFDocEncoding is not Latin-1; only unambiguous ASCII white
                // space is accepted without an explicit Unicode byte order.
                guard bytes.allSatisfy({ [9, 10, 12, 13, 32].contains($0) }) else { return false }
            }
        }
        return true
    }

    struct Lexer {
        struct Token {
            let range: Range<Int>
            var command: String?
            var number: CGFloat?
            var name: String?
            var hasText = false
            var stringBytes: [UInt8]?
            var dictionary: [String: Token]?
        }
        let bytes: [UInt8]
        var offset = 0
        var visits = 0

        /// Only unfiltered one-bit masks have a bounded, exact byte length.
        /// Keep their original bytes; never search arbitrary image data for EI.
        mutating func skipUnfilteredImageMask() throws {
            // The scan fixture contains a one-bit uncompressed image mask.
            // Compute its exact byte count; never search binary data for EI.
            var properties: [String: Token] = [:]
            var foundData = false
            while let key = try next() {
                if key.command == "ID" { foundData = true; break }
                guard let name = key.name, properties[name] == nil,
                      let value = try next(), value.command == nil,
                      properties.count < 16 else { throw ParseFailure.unsupported }
                properties[name] = value
            }
            for aliases in [("W", "Width"), ("H", "Height"), ("IM", "ImageMask"),
                        ("BPC", "BitsPerComponent"), ("D", "Decode"), ("I", "Interpolate")] {
                guard properties[aliases.0] == nil || properties[aliases.1] == nil else { throw ParseFailure.unsupported }
            }
            let mask = properties["IM"] ?? properties["ImageMask"]
            let bits = properties["BPC"] ?? properties["BitsPerComponent"]
            guard foundData, let mask, String(decoding: bytes[mask.range], as: UTF8.self) == "true",
                  properties["F"] == nil, properties["Filter"] == nil,
                  properties.keys.allSatisfy({ ["W", "Width", "H", "Height", "IM", "ImageMask", "BPC", "BitsPerComponent", "D", "Decode", "I", "Interpolate"].contains($0) }),
                  let w = (properties["W"] ?? properties["Width"])?.number,
                  let h = (properties["H"] ?? properties["Height"])?.number,
                  w.rounded() == w, h.rounded() == h, (1...8192).contains(w), (1...8192).contains(h),
                  bits == nil || bits?.number == 1,
                  offset < bytes.count, whitespace(bytes[offset]) else { throw ParseFailure.unsupported }
            let first = bytes[offset]
            offset += 1
            if first == 13, offset < bytes.count, bytes[offset] == 10 { offset += 1 }
            let count = ((Int(w) + 7) / 8) * Int(h)
            guard count <= bytes.count - offset else { throw ParseFailure.malformed }
            offset += count
            guard offset < bytes.count, whitespace(bytes[offset]),
                  let end = try next(), end.command == "EI" else { throw ParseFailure.malformed }
        }

        mutating func next(depth: Int = 0) throws -> Token? {
            guard depth < 64 else { throw ParseFailure.limitExceeded }
            skipTrivia()
            guard offset < bytes.count else { return nil }
            visits += 1
            guard visits < 1_000_000 else { throw ParseFailure.limitExceeded }
            let start = offset
            let byte = bytes[offset]
            offset += 1
            if byte == 40 { // Literal string, including escaped parentheses.
                var nesting = 1
                var decoded: [UInt8] = []
                while offset < bytes.count {
                    let current = bytes[offset]
                    offset += 1
                    if current == 92 {
                        guard offset < bytes.count else { throw ParseFailure.malformed }
                        let escaped = bytes[offset]
                        offset += 1
                        if escaped == 13, offset < bytes.count, bytes[offset] == 10 { offset += 1 }
                        if (48...55).contains(escaped) {
                            var octal = Int(escaped - 48)
                            for _ in 0..<2 where offset < bytes.count && (48...55).contains(bytes[offset]) {
                                octal = octal * 8 + Int(bytes[offset] - 48)
                                offset += 1
                            }
                            decoded.append(UInt8(truncatingIfNeeded: octal))
                        } else if escaped != 10 && escaped != 13 {
                            let escapes: [UInt8: UInt8] = [110: 10, 114: 13, 116: 9, 98: 8, 102: 12]
                            decoded.append(escapes[escaped] ?? escaped)
                        }
                    } else if current == 40 {
                        nesting += 1
                        guard nesting < 64 else { throw ParseFailure.limitExceeded }
                        decoded.append(current)
                    } else if current == 41 {
                        nesting -= 1
                        if nesting == 0 { return Token(range: start..<offset, hasText: !decoded.isEmpty, stringBytes: decoded) }
                        decoded.append(current)
                    } else { decoded.append(current) }
                }
                throw ParseFailure.malformed
            }
            if byte == 60, offset >= bytes.count || bytes[offset] != 60 { // Hex string.
                var decoded: [UInt8] = []
                var highNibble: UInt8?
                while offset < bytes.count {
                    let current = bytes[offset]
                    offset += 1
                    if current == 62 {
                        if let highNibble { decoded.append(highNibble * 16) }
                        return Token(range: start..<offset, hasText: !decoded.isEmpty, stringBytes: decoded)
                    }
                    guard whitespace(current) || (48...57).contains(current)
                        || (65...70).contains(current) || (97...102).contains(current) else { throw ParseFailure.malformed }
                    if !whitespace(current) {
                        let nibble = current <= 57 ? current - 48 : (current & 0xDF) - 65 + 10
                        if let high = highNibble {
                            decoded.append(high * 16 + nibble)
                            highNibble = nil
                        } else { highNibble = nibble }
                    }
                }
                throw ParseFailure.malformed
            }
            if byte == 91 || byte == 60 { // Array or dictionary; never commands.
                let dictionary = byte == 60
                if dictionary { offset += 1 }
                var hasText = false
                var properties: [String: Token] = [:]
                var propertyName: String?
                while true {
                    skipTrivia()
                    guard offset < bytes.count else { throw ParseFailure.malformed }
                    if !dictionary, bytes[offset] == 93 {
                        offset += 1
                        return Token(range: start..<offset, hasText: hasText)
                    }
                    if dictionary, bytes[offset] == 62, offset + 1 < bytes.count, bytes[offset + 1] == 62 {
                        guard propertyName == nil else { throw ParseFailure.malformed }
                        offset += 2
                        return Token(range: start..<offset, hasText: hasText, dictionary: properties)
                    }
                    guard let child = try next(depth: depth + 1), child.command == nil else { throw ParseFailure.malformed }
                    hasText = hasText || child.hasText
                    if dictionary {
                        if let key = propertyName {
                            guard properties[key] == nil else { throw ParseFailure.malformed }
                            properties[key] = child
                            propertyName = nil
                        } else {
                            guard let key = child.name else { throw ParseFailure.malformed }
                            propertyName = key
                        }
                    }
                }
            }
            if [41, 62, 93, 123, 125].contains(byte) { throw ParseFailure.malformed }
            while offset < bytes.count, !whitespace(bytes[offset]), !delimiter(bytes[offset]) { offset += 1 }
            if byte == 47 {
                var decoded: [UInt8] = []
                var index = start + 1
                while index < offset {
                    if bytes[index] == 35 {
                        guard index + 2 < offset,
                              let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) else {
                            throw ParseFailure.malformed
                        }
                        decoded.append(value)
                        index += 3
                    } else {
                        decoded.append(bytes[index])
                        index += 1
                    }
                }
                guard let name = String(bytes: decoded, encoding: .utf8), !name.isEmpty else { throw ParseFailure.unsupported }
                return Token(range: start..<offset, name: name)
            }
            let word = String(decoding: bytes[start..<offset], as: UTF8.self)
            if let value = Double(word), value.isFinite { return Token(range: start..<offset, number: CGFloat(value)) }
            if ["true", "false", "null"].contains(word) { return Token(range: start..<offset) }
            guard depth == 0 else { throw ParseFailure.malformed }
            return Token(range: start..<offset, command: word)
        }

        mutating func skipTrivia() {
            while offset < bytes.count {
                if whitespace(bytes[offset]) { offset += 1 }
                else if bytes[offset] == 37 {
                    while offset < bytes.count, bytes[offset] != 10, bytes[offset] != 13 { offset += 1 }
                } else { break }
            }
        }

        func whitespace(_ byte: UInt8) -> Bool { [0, 9, 10, 12, 13, 32].contains(byte) }
        func delimiter(_ byte: UInt8) -> Bool { [40, 41, 60, 62, 91, 93, 123, 125, 47, 37].contains(byte) }
    }
}
