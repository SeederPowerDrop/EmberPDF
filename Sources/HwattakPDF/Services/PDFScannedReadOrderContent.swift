// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// Keep replacement text at the original OCR show in the content sequence.
/// Original image/Form paints receive exclusion clips. A freshly generated
/// plain-text donor can separately receive the exact positive erasure union;
/// the complete page and retained OCR text are never clipped together.
enum PDFScannedReadOrderContent {
    typealias Failure = PDFBodyTextContentStream.ParseFailure

    /// Recognize only the writer's current paper prefix and per-paint exclusion
    /// wrappers. A normal-font donor may be replaced within these rows only
    /// after a separate native proof accounts for that whole unique text Form.
    /// Unknown visible paths, unwrapped images/Forms, text clipping and marked
    /// content do not gain an image-background exemption.
    static func provesGeneratedErasureProgram(_ data: Data, erasedRects: [CGRect],
                                              mediaBox: CGRect, paperColor: PDFTextColor,
                                              donorName: String, donorRange: Range<Int>,
                                              requiringPositiveDonorClip: Bool = false) throws -> Bool {
        guard data.count <= 64 * 1_024 * 1_024, !erasedRects.isEmpty, erasedRects.count <= 64,
              donorRange.lowerBound >= 0, donorRange.upperBound <= data.count else { return false }
        var paper = Data("q\n".utf8)
        for rectangle in erasedRects {
            paper.append(Data((try [rectangle.minX, rectangle.minY, rectangle.width, rectangle.height]
                .map(number).joined(separator: " ") + " re\n").utf8))
        }
        paper.append(Data((try "W n\n" + [paperColor.red, paperColor.green, paperColor.blue]
            .map(number).joined(separator: " ") + " rg\n").utf8))
        let background = mediaBox.insetBy(dx: -1, dy: -1)
        paper.append(Data((try [background.minX, background.minY, background.width, background.height]
            .map(number).joined(separator: " ") + " re f\nQ\n").utf8))
        guard data.starts(with: paper) else { return false }
        var lexer = PDFBodyTextContentStream.Lexer(bytes: Array(data))
        lexer.offset = paper.count
        struct ProofState {
            var transform = CGAffineTransform.identity
            var renderMode = 0
        }
        var state = ProofState(), stack: [ProofState] = []
        var operands: [PDFBodyTextContentStream.Lexer.Token] = []
        var inText = false, commands = erasedRects.count + 7, donorCount = 0, excludedPaints = 0
        var positiveClip: (depth: Int, initialDonorCount: Int)?
        var positiveClipCount = 0
        func clipPrefix(_ transform: CGAffineTransform) throws -> Data? {
            let values = [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
            guard values.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000_000 }),
                  abs(transform.a * transform.d - transform.b * transform.c) > 0.000_000_001 else { return nil }
            let inverse = transform.inverted()
            var bytes = Data("q\n".utf8)
            for rectangle in [mediaBox.insetBy(dx: -1, dy: -1)] + erasedRects {
                let points = [CGPoint(x: rectangle.minX, y: rectangle.minY),
                              CGPoint(x: rectangle.maxX, y: rectangle.minY),
                              CGPoint(x: rectangle.maxX, y: rectangle.maxY),
                              CGPoint(x: rectangle.minX, y: rectangle.maxY)].map { $0.applying(inverse) }
                for (index, point) in points.enumerated() {
                    bytes.append(Data("\(try number(point.x)) \(try number(point.y)) \(index == 0 ? "m" : "l")\n".utf8))
                }
                bytes.append(Data("h\n".utf8))
            }
            bytes.append(Data("W* n\n".utf8))
            return bytes
        }
        while let token = try lexer.next() {
            guard let command = token.command else {
                operands.append(token)
                guard operands.count <= 256 else { throw Failure.limitExceeded }
                continue
            }
            commands += 1
            guard commands <= 250_000 else { throw Failure.limitExceeded }
            if commands % 256 == 0 { try Task.checkCancellation() }
            let numbers = operands.compactMap(\.number)
            // A positive clip owns only the generated donor. It must never
            // hide an original image, invisible OCR, or another clip wrapper.
            if positiveClip != nil, !["q","Q","cm","Do"].contains(command) { return false }
            switch command {
            case "q":
                guard !inText, operands.isEmpty, stack.count < 64 else { return false }
                if let prefix = try clipPrefix(state.transform),
                   data[token.range.lowerBound...].starts(with: prefix) {
                    guard positiveClip == nil else { return false }
                    // The complete literal wrapper is independently rebuilt
                    // from page-space rows and the current incoming CTM.
                    lexer.offset = token.range.lowerBound + prefix.count
                    guard let paint = try lexer.next() else { return false }
                    if paint.command == "BI" {
                        try lexer.skipUnfilteredImageMask()
                    } else {
                        guard paint.name != nil, paint.name != donorName,
                              let operation = try lexer.next(), operation.command == "Do" else { return false }
                    }
                    guard let closing = try lexer.next(), closing.command == "Q" else { return false }
                    commands += 5 * (erasedRects.count + 1) + 4
                    guard commands <= 250_000 else { throw Failure.limitExceeded }
                    excludedPaints += 1
                    guard excludedPaints <= 50_000 else { throw Failure.limitExceeded }
                } else if let prefix = try donorClipPrefix(erasedRects, transform: state.transform),
                          data[token.range.lowerBound...].starts(with: prefix) {
                    guard positiveClip == nil else { return false }
                    // Admit only the complete literal positive union owned by
                    // this declaration. The donor remains independently bound
                    // by its unique invocation and full unclipped native ink.
                    // Keep normal stack parsing so later whole-Form rewrites
                    // may put their checked q/cm/Do/Q inside this same clip.
                    lexer.offset = token.range.lowerBound + prefix.count
                    commands += 5 * erasedRects.count + 2
                    guard commands <= 250_000 else { throw Failure.limitExceeded }
                    stack.append(state)
                    positiveClip = (stack.count,donorCount)
                    positiveClipCount += 1
                } else { stack.append(state) }
            case "Q":
                if let scope = positiveClip,stack.count == scope.depth {
                    guard donorCount == scope.initialDonorCount+1 else { return false }
                    positiveClip = nil
                }
                guard !inText, operands.isEmpty, let previous = stack.popLast() else { return false }
                state = previous
            case "cm":
                guard !inText, operands.count == 6, numbers.count == 6,
                      numbers.allSatisfy(\.isFinite) else { return false }
                state.transform = CGAffineTransform(a: numbers[0], b: numbers[1], c: numbers[2],
                    d: numbers[3], tx: numbers[4], ty: numbers[5]).concatenating(state.transform)
                guard [state.transform.a, state.transform.b, state.transform.c, state.transform.d,
                       state.transform.tx, state.transform.ty].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000_000 }) else { return false }
            case "Do":
                guard !inText, operands.count == 1, operands[0].name == donorName,
                      (operands[0].range.lowerBound..<token.range.upperBound) == donorRange else { return false }
                donorCount += 1
                guard donorCount == 1 else { return false }
            case "BT":
                guard !inText, operands.isEmpty else { return false }; inText = true
            case "ET":
                guard inText, operands.isEmpty else { return false }; inText = false
            case "Tr":
                guard operands.count == 1, numbers.count == 1, numbers[0].isFinite,
                      numbers[0].rounded() == numbers[0], (0...3).contains(numbers[0]) else { return false }
                state.renderMode = Int(numbers[0])
            case "Tj", "TJ", "'":
                guard inText, state.renderMode == 3, operands.count == 1 else { return false }
            case "\"":
                guard inText, state.renderMode == 3, operands.count == 3, numbers.count == 2 else { return false }
            case "Tf":
                guard inText, operands.count == 2, operands[0].name != nil,
                      numbers.count == 1, numbers[0].isFinite else { return false }
            case "Tm":
                guard inText, operands.count == 6, numbers.count == 6, numbers.allSatisfy(\.isFinite) else { return false }
            case "Td", "TD":
                guard inText, operands.count == 2, numbers.count == 2, numbers.allSatisfy(\.isFinite) else { return false }
            case "TL", "Tc", "Tw", "Tz", "Ts":
                guard operands.count == 1, numbers.count == 1, numbers[0].isFinite else { return false }
            case "T*":
                guard inText, operands.isEmpty else { return false }
            case "gs", "ri", "cs", "CS":
                guard operands.count == 1, operands[0].name != nil else { return false }
            case "g", "G", "w", "J", "j", "M", "i":
                guard operands.count == 1, numbers.count == 1, numbers[0].isFinite else { return false }
            case "rg", "RG":
                guard operands.count == 3, numbers.count == 3, numbers.allSatisfy(\.isFinite) else { return false }
            case "k", "K":
                guard operands.count == 4, numbers.count == 4, numbers.allSatisfy(\.isFinite) else { return false }
            case "d":
                guard operands.count == 2, operands[0].range.count >= 2,
                      data[operands[0].range.lowerBound] == 91,
                      data[operands[0].range.upperBound - 1] == 93,
                      numbers.count == 1, numbers[0].isFinite else { return false }
            case "n":
                guard operands.isEmpty else { return false }
            default:
                return false
            }
            operands.removeAll(keepingCapacity: true)
        }
        try Task.checkCancellation()
        return !inText && stack.isEmpty && operands.isEmpty && positiveClip == nil
            && donorCount == 1 && excludedPaints > 0
            && (!requiringPositiveDonorClip || positiveClipCount == 1)
    }

    /// A finite page-space erasure union, transformed without changing the
    /// caller's CTM. Only generated normal donors use this wrapper; it is not
    /// a general input-clipping exemption and never substitutes for ink fit.
    private static func donorClipPrefix(_ rectangles: [CGRect], transform: CGAffineTransform) throws -> Data? {
        guard !rectangles.isEmpty,rectangles.count <= 64,
              [transform.a,transform.b,transform.c,transform.d,transform.tx,transform.ty]
                .allSatisfy({ $0.isFinite && abs($0) <= 1_000_000_000 }),
              abs(transform.a*transform.d-transform.b*transform.c) > 0.000_000_001 else { return nil }
        let inverse = transform.inverted()
        var result = Data("q\n".utf8)
        for rectangle in rectangles {
            let points = [CGPoint(x:rectangle.minX,y:rectangle.minY),CGPoint(x:rectangle.maxX,y:rectangle.minY),
                CGPoint(x:rectangle.maxX,y:rectangle.maxY),CGPoint(x:rectangle.minX,y:rectangle.maxY)]
                .map { $0.applying(inverse) }
            for (index,point) in points.enumerated() {
                result.append(Data("\(try number(point.x)) \(try number(point.y)) \(index == 0 ? "m" : "l")\n".utf8))
            }
            result.append(Data("h\n".utf8))
        }
        result.append(Data("W n\n".utf8))
        return result
    }

    private struct State {
        var transform = CGAffineTransform.identity
        var leading: CGFloat = 0
        var renderMode = 0
        var clipPolygons: [[CGPoint]] = []
        var unknownClip = false
    }
    private struct Patch {
        let range: Range<Int>
        let bytes: Data
    }

    static func render(_ content: Data, erasedRects: [CGRect], mediaBox: CGRect,
                       paperColor: PDFTextColor, insertionOffset: Int?, donorName: String?,
                       preservedFormNames: Set<String> = [], clipDonorToErasure: Bool = false) throws -> Data {
        guard content.count <= 64 * 1_024 * 1_024, erasedRects.count <= 64,
              !erasedRects.isEmpty else { throw Failure.limitExceeded }
        guard ([mediaBox] + erasedRects).allSatisfy({ rectangle in
            [rectangle.minX, rectangle.minY, rectangle.width, rectangle.height].allSatisfy(\.isFinite)
                && rectangle.width > 0 && rectangle.height > 0
        }) else { throw Failure.unsupported }
        var lexer = PDFBodyTextContentStream.Lexer(bytes: Array(content))
        var operands: [PDFBodyTextContentStream.Lexer.Token] = []
        var state = State(), stack: [State] = []
        var lineMatrix = CGAffineTransform.identity
        var inText = false, markedDepth = 0, activePath = false, commands = 0
        var pathPolygon: [CGPoint]?, complexPath = false, pendingClip = false
        var patches: [Patch] = [], inserted = donorName == nil

        func matrix(_ numbers: [CGFloat]) -> CGAffineTransform {
            CGAffineTransform(a: numbers[0], b: numbers[1], c: numbers[2], d: numbers[3],
                              tx: numbers[4], ty: numbers[5])
        }
        func valid(_ transform: CGAffineTransform) -> Bool {
            [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
                .allSatisfy { $0.isFinite && abs($0) <= 1_000_000_000 }
                && abs(transform.a * transform.d - transform.b * transform.c) > 0.000_000_001
        }
        func clippedPaint(_ range: Range<Int>) throws -> Patch {
            guard !inText, !activePath, valid(state.transform) else { throw Failure.unsupported }
            let inverse = state.transform.inverted()
            let regions = [mediaBox.insetBy(dx: -1, dy: -1)] + erasedRects
            // Transform the path, not the CTM: a concatenate/invert round trip
            // can perturb untouched scan pixels at fractional image edges.
            var bytes = Data("q\n".utf8)
            for rectangle in regions {
                let points = [CGPoint(x: rectangle.minX, y: rectangle.minY),
                              CGPoint(x: rectangle.maxX, y: rectangle.minY),
                              CGPoint(x: rectangle.maxX, y: rectangle.maxY),
                              CGPoint(x: rectangle.minX, y: rectangle.maxY)].map { $0.applying(inverse) }
                for (index, point) in points.enumerated() {
                    bytes.append(Data("\(try number(point.x)) \(try number(point.y)) \(index == 0 ? "m" : "l")\n".utf8))
                }
                bytes.append(Data("h\n".utf8))
            }
            bytes.append(Data("W* n\n".utf8))
            bytes.append(content.subdata(in: range))
            bytes.append(Data("\nQ\n".utf8))
            return Patch(range: range, bytes: bytes)
        }
        func contains(_ rectangle: CGRect, in polygon: [CGPoint]) -> Bool {
            let area = polygon.indices.reduce(CGFloat(0)) { result, index in
                let first = polygon[index], next = polygon[(index + 1) % polygon.count]
                return result + first.x * next.y - next.x * first.y
            }
            guard abs(area) > 0.000_000_001 else { return false }
            let corners = [CGPoint(x: rectangle.minX, y: rectangle.minY), CGPoint(x: rectangle.maxX, y: rectangle.minY),
                           CGPoint(x: rectangle.maxX, y: rectangle.maxY), CGPoint(x: rectangle.minX, y: rectangle.maxY)]
            return corners.allSatisfy { point in
                var positive = false, negative = false
                for index in polygon.indices {
                    let first = polygon[index], second = polygon[(index + 1) % polygon.count]
                    let cross = (second.x - first.x) * (point.y - first.y) - (second.y - first.y) * (point.x - first.x)
                    if cross > 0.000_001 { positive = true }
                    if cross < -0.000_001 { negative = true }
                }
                return !(positive && negative)
            }
        }

        while let token = try lexer.next() {
            guard let command = token.command else {
                operands.append(token)
                guard operands.count <= 256 else { throw Failure.limitExceeded }
                continue
            }
            commands += 1
            guard commands <= 250_000 else { throw Failure.limitExceeded }
            let numbers = operands.compactMap(\.number)
            switch command {
            case "q":
                guard !inText, operands.isEmpty, stack.count < 64 else { throw Failure.unsupported }
                stack.append(state)
            case "Q":
                guard !inText, operands.isEmpty, let previous = stack.popLast() else { throw Failure.malformed }
                state = previous
            case "cm":
                guard !inText, numbers.count == 6, operands.count == 6 else { throw Failure.malformed }
                state.transform = matrix(numbers).concatenating(state.transform)
                guard valid(state.transform) else { throw Failure.unsupported }
            case "gs":
                guard operands.count == 1, operands[0].name != nil else { throw Failure.malformed }
            case "BT":
                guard !inText, operands.isEmpty else { throw Failure.malformed }
                inText = true
                lineMatrix = .identity
            case "ET":
                guard inText, operands.isEmpty else { throw Failure.malformed }
                inText = false
            case "Tm":
                guard inText, numbers.count == 6, operands.count == 6 else { throw Failure.malformed }
                lineMatrix = matrix(numbers)
            case "Td", "TD":
                guard inText, numbers.count == 2, operands.count == 2 else { throw Failure.malformed }
                if command == "TD" { state.leading = -numbers[1] }
                lineMatrix = CGAffineTransform(translationX: numbers[0], y: numbers[1]).concatenating(lineMatrix)
            case "TL":
                guard numbers.count == 1, operands.count == 1 else { throw Failure.malformed }
                state.leading = numbers[0]
            case "Tr":
                guard numbers.count == 1, operands.count == 1 else { throw Failure.malformed }
                state.renderMode = Int(numbers[0])
            case "T*", "'", "\"":
                guard inText else { throw Failure.malformed }
                lineMatrix = CGAffineTransform(translationX: 0, y: -state.leading).concatenating(lineMatrix)
            case "Tj", "TJ":
                guard inText, operands.count == 1 else { throw Failure.malformed }
                if let donorName, let offset = insertionOffset, operands[0].range.lowerBound == offset {
                    // The removal planner already proved this exact empty
                    // show and that the next retained show resets its matrix.
                    var array = PDFBodyTextContentStream.Lexer(bytes: Array(lexer.bytes[operands[0].range].dropFirst().dropLast()))
                    guard command == "TJ", lexer.bytes[offset] == 91, try array.next() == nil,
                          !inserted, markedDepth == 0, !activePath, state.renderMode == 3,
                          valid(state.transform), valid(lineMatrix),
                          !state.unknownClip,
                          state.clipPolygons.allSatisfy({ polygon in erasedRects.allSatisfy { contains($0, in: polygon) } }),
                          donorName.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
                        throw Failure.unsupported
                    }
                    let inverse = state.transform.inverted()
                    let inverseValues = try [inverse.a,inverse.b,inverse.c,inverse.d,inverse.tx,inverse.ty].map(number)
                    guard let a = Double(inverseValues[0]),let b = Double(inverseValues[1]),
                          let c = Double(inverseValues[2]),let d = Double(inverseValues[3]),
                          let tx = Double(inverseValues[4]),let ty = Double(inverseValues[5]) else { throw Failure.unsupported }
                    // Reconstruct the CTM from the actual serialized numbers,
                    // exactly as the independent parent-program proof does.
                    let reset = CGAffineTransform(a:a,b:b,c:c,d:d,tx:tx,ty:ty).concatenating(state.transform)
                    let clip: String
                    if clipDonorToErasure {
                        guard let prefix = try donorClipPrefix(erasedRects,transform:reset) else { throw Failure.unsupported }
                        clip = String(decoding:prefix,as:UTF8.self)
                    } else { clip = "" }
                    let call = try "\nET\nq\n\(matrixCommand(inverse, command: "cm"))"
                        + "BT 0 Tc 0 Tw 100 Tz 0 TL 0 Tr 0 Ts ET\n" + clip
                        + "/\(donorName) Do\n" + (clipDonorToErasure ? "Q\n" : "") + "Q\nBT\n"
                        + matrixCommand(lineMatrix, command: "Tm")
                    patches.append(Patch(range: offset..<offset, bytes: Data(call.utf8)))
                    inserted = true
                }
            case "Do":
                guard operands.count == 1, let name = operands[0].name else { throw Failure.malformed }
                // Only previously validated owned text Forms whose painted
                // bounds miss this erasure may retain their existing clip.
                // Their exact invocation remains editable on a later pass.
                if !preservedFormNames.contains(name) {
                    patches.append(try clippedPaint(operands[0].range.lowerBound..<token.range.upperBound))
                }
            case "BI":
                guard operands.isEmpty else { throw Failure.malformed }
                try lexer.skipUnfilteredImageMask()
                patches.append(try clippedPaint(token.range.lowerBound..<lexer.offset))
            case "ID", "EI": throw Failure.malformed
            case "BMC", "BDC": markedDepth += 1
            case "EMC":
                guard markedDepth > 0 else { throw Failure.malformed }
                markedDepth -= 1
            case "re":
                guard numbers.count == 4, operands.count == 4 else { throw Failure.malformed }
                if activePath { complexPath = true }
                let rectangle = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]).standardized
                pathPolygon = [CGPoint(x: rectangle.minX, y: rectangle.minY), CGPoint(x: rectangle.maxX, y: rectangle.minY),
                               CGPoint(x: rectangle.maxX, y: rectangle.maxY), CGPoint(x: rectangle.minX, y: rectangle.maxY)]
                    .map { $0.applying(state.transform) }
                activePath = true
            case "m", "l", "c", "v", "y", "h": activePath = true; complexPath = true
            case "W", "W*": pendingClip = true
            case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n":
                if pendingClip {
                    if !complexPath, let pathPolygon, pathPolygon.count == 4 {
                        state.clipPolygons.append(pathPolygon)
                        guard state.clipPolygons.count <= 64 else { throw Failure.limitExceeded }
                    } else { state.unknownClip = true }
                }
                activePath = false; pathPolygon = nil; complexPath = false; pendingClip = false
            default: break
            }
            operands.removeAll(keepingCapacity: true)
        }
        guard !inText, stack.isEmpty, operands.isEmpty, markedDepth == 0, inserted else { throw Failure.unsupported }
        var result = content
        for patch in patches.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(patch.range, with: patch.bytes)
            guard result.count <= 64 * 1_024 * 1_024 else { throw Failure.limitExceeded }
        }
        var paper = Data("q\n".utf8)
        for rectangle in erasedRects {
            paper.append(Data((try [rectangle.minX, rectangle.minY, rectangle.width, rectangle.height]
                .map(number).joined(separator: " ") + " re\n").utf8))
        }
        paper.append(Data((try "W n\n" + [paperColor.red, paperColor.green, paperColor.blue].map(number).joined(separator: " ") + " rg\n").utf8))
        // PDFKit considers a small filled rectangle an obstacle when deriving
        // OCR reading order, even if the fill precedes the text. The full-page
        // path is a background; its clip still paints only the erased ink.
        let background = mediaBox.insetBy(dx: -1, dy: -1)
        paper.append(Data((try [background.minX, background.minY, background.width, background.height]
            .map(number).joined(separator: " ") + " re f\n").utf8))
        paper.append(Data("Q\n".utf8))
        paper.append(result)
        return paper
    }

    private static func matrixCommand(_ matrix: CGAffineTransform, command: String) throws -> String {
        try [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].map(number).joined(separator: " ") + " \(command)\n"
    }
    private static func number(_ value: CGFloat) throws -> String {
        try PDFDecimalNumber.string(value)
    }
}
