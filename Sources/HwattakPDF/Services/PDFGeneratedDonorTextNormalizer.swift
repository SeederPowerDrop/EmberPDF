// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Quartz sometimes maps an ideograph to its visually identical radical and
/// corrects it with a one-glyph ActualText span. Readers can then sort the
/// narrow span as a separate line. For a newly generated donor only, move that
/// exact semantic correction into its private ToUnicode map. Every use of the
/// code must agree; ambiguous, shared or unfamiliar programs stay untouched.
enum PDFGeneratedDonorTextNormalizer {
    static let maximumCombinedCMapBytes = 8 * 1_024 * 1_024
    struct Output {
        let content: Data
        let fontCMaps: [String: Data]
    }

    private struct Key: Hashable { let font: String; let code: UInt8 }
    private struct Use { let key: Key; let scope: Int? }
    private struct Scope {
        let opening: Range<Int>
        let unicode: [UInt8]?
        var closing: Range<Int>?
        var shows = 0
        var valid = true
    }

    static func normalize(content: Data, fontCMaps: [String: Data],
                          nonFontGraphicsStates: Set<String> = []) -> Output? {
        // This optional normalization never relaxes the editor's native,
        // geometry, painting, source-provenance or resource-copy checks.
        guard content.count <= 1_024 * 1_024, fontCMaps.count <= 256 else { return nil }
        var mapBytes = 0
        for map in fontCMaps.values {
            guard map.count <= maximumCombinedCMapBytes - mapBytes else { return nil }
            mapBytes += map.count
        }
        do {
            var lexer = PDFBodyTextContentStream.Lexer(bytes: Array(content))
            var operands: [PDFBodyTextContentStream.Lexer.Token] = []
            var font: String?, stack: [String?] = [], active: Int?
            var scopes: [Scope] = [], uses: [Use] = [], blocked = Set<String>()
            var commands = 0
            let semantic: Set<String> = ["q", "Q", "cm", "BT", "ET", "Tf", "Tr", "Tm", "Td", "TD",
                "T*", "Tj", "Tc", "Tw", "Tz", "TL", "Ts", "g", "G", "rg", "RG", "k", "K",
                "cs", "CS", "sc", "SC", "scn", "SCN", "ri"]
            while let token = try lexer.next() {
                guard let command = token.command else {
                    operands.append(token)
                    guard operands.count <= 256 else { return nil }
                    continue
                }
                commands += 1
                guard commands <= 100_000 else { return nil }
                if let active, !semantic.contains(command), command != "EMC" {
                    scopes[active].valid = false
                }
                switch command {
                case "q":
                    guard operands.isEmpty, stack.count < 64 else { return nil }
                    stack.append(font)
                case "Q":
                    guard operands.isEmpty, !stack.isEmpty else { return nil }
                    font = stack.removeLast()
                case "Tf":
                    guard operands.count == 2, let name = operands[0].name,
                          operands[1].number != nil else { return nil }
                    font = name
                case "gs":
                    guard operands.count == 1, let name = operands[0].name,
                          nonFontGraphicsStates.contains(name) else { return nil }
                case "BDC":
                    guard active == nil, scopes.count < 16_384, operands.count == 2,
                          operands[0].name == "Span", let properties = operands[1].dictionary,
                          properties.count == 1, let actual = properties["ActualText"]?.stringBytes else { return nil }
                    let unicode: [UInt8]?
                    if actual.starts(with: [0xfe, 0xff]), actual.count == 4 || actual.count == 6,
                       let string = String(data: Data(actual.dropFirst(2)), encoding: .utf16BigEndian),
                       string.unicodeScalars.count == 1 {
                        unicode = Array(actual.dropFirst(2))
                    } else { unicode = nil }
                    active = scopes.count
                    scopes.append(Scope(opening: operands[0].range.lowerBound..<token.range.upperBound,
                                        unicode: unicode))
                case "EMC":
                    guard operands.isEmpty, let index = active else { return nil }
                    scopes[index].closing = token.range
                    active = nil
                case "Tj":
                    guard operands.count == 1, let bytes = operands[0].stringBytes, let font else { return nil }
                    if let active {
                        scopes[active].shows += 1
                        if bytes.count != 1 { scopes[active].valid = false }
                    }
                    for code in bytes {
                        guard uses.count < 250_000 else { return nil }
                        uses.append(Use(key: Key(font: font, code: code), scope: active))
                    }
                case "TJ", "'", "\"":
                    // Array operands are deliberately opaque to the lexer.
                    // Do not rewrite any code in a font with uncounted uses.
                    if let font { blocked.insert(font) } else { return nil }
                    if let active { scopes[active].valid = false }
                case "Do", "BI", "BMC": return nil
                default: break
                }
                operands.removeAll(keepingCapacity: true)
            }
            guard operands.isEmpty, stack.isEmpty, active == nil else { return nil }
            var corrections: [Key: [UInt8]] = [:], excluded = Set<Key>()
            for use in uses {
                guard !blocked.contains(use.key.font), fontCMaps[use.key.font] != nil,
                      let index = use.scope, scopes[index].valid, scopes[index].shows == 1,
                      scopes[index].closing != nil, let unicode = scopes[index].unicode else {
                    excluded.insert(use.key); continue
                }
                if let previous = corrections[use.key], previous != unicode { excluded.insert(use.key) }
                corrections[use.key] = unicode
            }
            for key in excluded { corrections.removeValue(forKey: key) }
            var maps: [String: Data] = [:], accepted = Set<Key>()
            for (font, cmap) in fontCMaps {
                let changes = corrections.filter { $0.key.font == font }
                guard !changes.isEmpty,
                      let rewritten = rewriteCMap(cmap, changes: Dictionary(uniqueKeysWithValues:
                        changes.map { ($0.key.code, $0.value) })) else { continue }
                maps[font] = rewritten
                accepted.formUnion(changes.keys)
            }
            guard !accepted.isEmpty else { return nil }
            var ranges: [Range<Int>] = []
            for use in uses where accepted.contains(use.key) {
                guard let index = use.scope, let closing = scopes[index].closing else { return nil }
                ranges.append(scopes[index].opening); ranges.append(closing)
            }
            var rewritten = content
            for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
                rewritten.removeSubrange(range)
            }
            return Output(content: rewritten, fontCMaps: maps)
        } catch { return nil }
    }

    private static func rewriteCMap(_ data: Data, changes: [UInt8: [UInt8]]) -> Data? {
        guard data.count <= 1_024 * 1_024 else { return nil }
        do {
            var lexer = PDFBodyTextContentStream.Lexer(bytes: Array(data))
            var previous: PDFBodyTextContentStream.Lexer.Token?
            var destinations: [UInt8: Range<Int>] = [:], coveredCodes = Set<UInt8>(), visits = 0
            while let token = try lexer.next() {
                visits += 1
                guard visits <= 100_000 else { return nil }
                if token.command == "usecmap" || token.name == "UseCMap" { return nil }
                if token.command == "beginbfchar" || token.command == "beginbfrange" {
                    let range = token.command == "beginbfrange"
                    guard let number = previous?.number, number.rounded() == number,
                          number > 0, number <= 4096 else { return nil }
                    for _ in 0..<Int(number) {
                        guard let source = try lexer.next(), let code = source.stringBytes, code.count == 1 else { return nil }
                        var lastCode = code[0]
                        if range {
                            guard let end = try lexer.next()?.stringBytes, end.count == 1,
                                  end[0] >= code[0] else { return nil }
                            lastCode = end[0]
                        }
                        guard let destination = try lexer.next(), let unicode = destination.stringBytes,
                              !unicode.isEmpty, unicode.count <= 32 else { return nil }
                        if lastCode != code[0] {
                            // Preserve an unrelated, bounded BMP range verbatim.
                            // Corrected codes must still have an independent
                            // destination token; ranges are never split or rewritten.
                            guard unicode.count == 2 else { return nil }
                            let firstScalar = Int(unicode[0]) * 256 + Int(unicode[1])
                            let finalScalar = firstScalar + Int(lastCode) - Int(code[0])
                            guard finalScalar <= 0xffff,
                                  !(firstScalar...finalScalar).overlaps(0xd800...0xdfff) else { return nil }
                        }
                        // A mapping hidden in an unrelated range must not alias
                        // a singleton correction (or any other mapping).
                        for mappedCode in Int(code[0])...Int(lastCode) {
                            let value = UInt8(mappedCode)
                            guard coveredCodes.insert(value).inserted else { return nil }
                            if lastCode != code[0], changes[value] != nil { return nil }
                        }
                        if lastCode == code[0] { destinations[code[0]] = destination.range }
                    }
                    guard try lexer.next()?.command == (range ? "endbfrange" : "endbfchar") else { return nil }
                }
                previous = token
            }
            guard changes.keys.allSatisfy({ destinations[$0] != nil }) else { return nil }
            var rewritten = data
            let patches = changes.map { (destinations[$0.key]!, $0.value) }
                .sorted { $0.0.lowerBound > $1.0.lowerBound }
            for (range, unicode) in patches {
                let hex = unicode.map { String(format: "%02X", $0) }.joined()
                rewritten.replaceSubrange(range, with: Data("<\(hex)>".utf8))
            }
            return rewritten
        } catch { return nil }
    }
}
