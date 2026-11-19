// SPDX-License-Identifier: MPL-2.0

import Foundation

/// OCR-only byte edits. In particular, never regenerate a scan's other OCR
/// objects: outline-less CID fonts can lose their Unicode during regeneration.
struct PDFScannedContentStream {
    struct Show {
        let range: Range<Int>
        let invisible: Bool
        let marked: Bool
        let resetsPosition: Bool
        let stringBytes: [UInt8]?
        let fontName: String?
    }
    let data: Data
    let shows: [Show]
    typealias Failure = PDFBodyTextContentStream.ParseFailure

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1_024 * 1_024 else { throw Failure.limitExceeded }
        var lexer = PDFBodyTextContentStream.Lexer(bytes: Array(data))
        var operands: [PDFBodyTextContentStream.Lexer.Token] = []
        var shows: [Show] = []
        var renderMode = 0, stack: [Int] = [], markedDepth = 0
        var fontName: String?, fontStack: [String?] = []
        var inText = false, reset = false, commands = 0
        while let token = try lexer.next() {
            guard let command = token.command else {
                operands.append(token)
                guard operands.count <= 256 else { throw Failure.limitExceeded }
                continue
            }
            commands += 1
            guard commands <= 250_000 else { throw Failure.limitExceeded }
            switch command {
            case "BI":
                guard !inText, operands.isEmpty else { throw Failure.unsupported }
                try lexer.skipUnfilteredImageMask()
            case "ID", "EI": throw Failure.malformed
            case "q":
                guard operands.isEmpty, !inText, stack.count < 64 else { throw Failure.unsupported }
                stack.append(renderMode)
                fontStack.append(fontName)
            case "Q":
                guard operands.isEmpty, !inText, let old = stack.popLast() else { throw Failure.malformed }
                renderMode = old
                fontName = fontStack.removeLast()
            case "BT":
                guard !inText, operands.isEmpty else { throw Failure.malformed }
                inText = true; reset = true
            case "ET":
                guard inText, operands.isEmpty else { throw Failure.malformed }
                inText = false; reset = true
            case "Tr":
                guard operands.count == 1, let value = operands[0].number,
                      value.rounded() == value, (0...7).contains(value) else { throw Failure.malformed }
                renderMode = Int(value)
            case "Tf":
                guard operands.count == 2, let name = operands[0].name,
                      operands[1].number != nil else { throw Failure.malformed }
                fontName = name
            case "Tm", "Td", "TD", "T*":
                let count = command == "Tm" ? 6 : command == "T*" ? 0 : 2
                guard inText, operands.count == count, operands.allSatisfy({ $0.number != nil }) else { throw Failure.malformed }
                reset = true
            case "BMC", "BDC":
                guard operands.count == (command == "BMC" ? 1 : 2), operands[0].name != nil,
                      command == "BMC" || operands[1].name != nil || operands[1].dictionary != nil else { throw Failure.malformed }
                markedDepth += 1
                guard markedDepth <= 64 else { throw Failure.limitExceeded }
            case "EMC":
                guard operands.isEmpty, markedDepth > 0 else { throw Failure.malformed }
                markedDepth -= 1
            case "Tj", "TJ", "'", "\"":
                guard inText, operands.count == (command == "\"" ? 3 : 1),
                      let first = operands.first else { throw Failure.malformed }
                var stringBytes = command == "Tj" ? first.stringBytes : nil
                if command == "TJ" {
                    guard lexer.bytes[first.range.lowerBound] == 91 else { throw Failure.malformed }
                    // Our earlier edit leaves [] TJ in place. It has no glyphs
                    // or advance, so retain its bytes without adding an ordinal.
                    var elements = PDFBodyTextContentStream.Lexer(bytes: Array(lexer.bytes[first.range].dropFirst().dropLast()))
                    var bytes: [UInt8] = [], found = false
                    while let element = try elements.next() {
                        found = true
                        if let value = element.stringBytes { bytes.append(contentsOf: value) }
                    }
                    if !found { break }
                    stringBytes = bytes
                } else if command == "\"" {
                    guard operands[0].number != nil, operands[1].number != nil,
                          operands[2].stringBytes != nil else { throw Failure.malformed }
                } else {
                    guard let bytes = first.stringBytes else { throw Failure.malformed }
                    if command == "Tj", bytes.isEmpty { break }
                }
                // Numeric-only TJ arrays can still advance the text matrix;
                // unlike an empty no-op, they cannot be silently skipped.
                guard operands.contains(where: \.hasText) else { throw Failure.unsupported }
                shows.append(Show(range: first.range.lowerBound..<token.range.upperBound,
                    invisible: renderMode == 3 && ["Tj", "TJ"].contains(command),
                    marked: markedDepth > 0, resetsPosition: reset || ["'", "\""].contains(command),
                    stringBytes: stringBytes, fontName: fontName))
                reset = false
            default:
                break
            }
            operands.removeAll(keepingCapacity: true)
        }
        guard operands.isEmpty, !inText, stack.isEmpty, markedDepth == 0 else { throw Failure.malformed }
        return Self(data: data, shows: shows)
    }

    func removing(_ indices: [Int]) throws -> Data {
        let selected = Set(indices)
        guard !selected.isEmpty, selected.count == indices.count,
              selected.allSatisfy({ shows.indices.contains($0) && shows[$0].invisible && !shows[$0].marked }) else { throw Failure.unsupported }
        for index in selected where index + 1 < shows.count && !selected.contains(index + 1) {
            guard shows[index + 1].resetsPosition else { throw Failure.unsupported }
        }
        var result = data
        for index in indices.sorted().reversed() { result.replaceSubrange(shows[index].range, with: Data("[] TJ".utf8)) }
        return result
    }
}
