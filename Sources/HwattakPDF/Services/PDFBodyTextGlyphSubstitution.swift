// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import CoreText
import CPDFium
import Foundation

/// A limited in-place correction in a root text show. The editor binds the
/// show to the selected PDFium object and validates the rewritten page.
enum PDFBodyTextGlyphSubstitution {
    struct Patch {
        let range: Range<Int>
        let command: Data
        let characterIndex: Int32
    }

    static func patch(record: PDFBodyTextContentStream.TextRecord, page: CGPDFPage,
                      textPage: FPDF_TEXTPAGE, object: FPDF_PAGEOBJECT,
                      from: UInt16, to: UInt16, envelope: CGRect, obstacles: [CGRect]) throws -> Patch? {
        guard let operand = record.glyphOperand, operand.bytes.count.isMultiple(of: 2),
              let font = FPDFTextObj_GetFont(object),
              FPDFTextObj_GetTextRenderMode(object) == FPDF_TEXTRENDERMODE_FILL,
              FPDFPageObj_HasTransparency(object) == 0, FPDFFont_GetIsEmbedded(font) == 1 else { return nil }
        let resources = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(resources) }
        for name in record.graphicsStateNames {
            guard let object = name.withCString({ CGPDFContentStreamGetResource(resources, "ExtGState", $0) }) else { return nil }
            var state: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &state), let state,
                  PDFCatalogStructurePreserver.object(state, "Font") == nil else { return nil }
        }
        guard let resource = operand.font.withCString({ CGPDFContentStreamGetResource(resources, "Font", $0) }) else { return nil }
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(resource, .dictionary, &dictionary), let dictionary,
              name(dictionary, "Subtype") == "Type0", name(dictionary, "Encoding") == "Identity-H",
              let descendants = PDFCatalogStructurePreserver.array(dictionary, "DescendantFonts"),
              CGPDFArrayGetCount(descendants) == 1 else { return nil }
        var descendant: CGPDFDictionaryRef?
        guard CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant,
              name(descendant, "Subtype") == "CIDFontType2",
              name(descendant, "CIDToGIDMap") == "Identity",
              let descriptor = PDFCatalogStructurePreserver.dictionary(descendant, "FontDescriptor"),
              let bytes = stream(descriptor, "FontFile2", maximum: 1_048_576),
              let cmap = stream(dictionary, "ToUnicode", maximum: 131_072),
              let mapping = try unicodeMap(cmap),
              let oldCode = uniqueCode(for: from, in: mapping),
              let newCode = uniqueCode(for: to, in: mapping), oldCode != newCode,
              let oldWidth = width(of: oldCode, in: descendant),
              let newWidth = width(of: newCode, in: descendant), oldWidth > 0, oldWidth == newWidth else { return nil }
        var length = 0
        guard FPDFFont_GetFontData(font, nil, 0, &length) != 0, length == bytes.count else { return nil }
        var native = Data(count: length), received = 0
        guard native.withUnsafeMutableBytes({
            FPDFFont_GetFontData(font, $0.bindMemory(to: UInt8.self).baseAddress, length, &received) != 0
        }), received == length, native == bytes,
              let provider = CGDataProvider(data: bytes as CFData), let graphics = CGFont(provider),
              oldCode > 0, newCode > 0, Int(oldCode) < graphics.numberOfGlyphs,
              Int(newCode) < graphics.numberOfGlyphs else { return nil }

        let codes = stride(from: 0, to: operand.bytes.count, by: 2).map {
            UInt16(operand.bytes[$0]) << 8 | UInt16(operand.bytes[$0 + 1])
        }
        let offsets = codes.indices.filter { codes[$0] == oldCode }
        guard offsets.count == 1, let offset = offsets.first else { return nil }
        let count = FPDFText_CountChars(textPage)
        guard (1...100_000).contains(count) else { return nil }
        var owned: [Int32] = []
        for index in 0..<count {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if FPDFText_GetTextObject(textPage, index) == object && FPDFText_IsGenerated(textPage, index) == 0 {
                owned.append(index)
            }
        }
        guard owned.count == codes.count, zip(owned, codes).allSatisfy({ index, code in
            FPDFText_HasUnicodeMapError(textPage, index) == 0
                && mapping[code].map { UInt32($0) == FPDFText_GetUnicode(textPage, index) } == true
        }) else { return nil }
        let index = owned[offset]
        let pointFont = CTFontCreateWithGraphicsFont(graphics, 1, nil, nil)
        guard let oldPath = CTFontCreatePathForGlyph(pointFont, oldCode, nil),
              let newPath = CTFontCreatePathForGlyph(pointFont, newCode, nil),
              let oldInk = PDFGlyphOutlineIdentity.closedPaintBounds(oldPath),
              let newInk = PDFGlyphOutlineIdentity.closedPaintBounds(newPath),
              !oldInk.isEmpty, !newInk.isEmpty else { return nil }
        var matrix = FS_MATRIX(), x = 0.0, y = 0.0
        let size = FPDFText_GetFontSize(textPage, index)
        guard FPDFText_GetMatrix(textPage, index, &matrix) != 0,
              FPDFText_GetCharOrigin(textPage, index, &x, &y) != 0,
              matrix.b == 0, matrix.c == 0, matrix.a > 0, matrix.d > 0,
              [x, y, size, Double(matrix.a), Double(matrix.d)].allSatisfy(\.isFinite), size > 0 else { return nil }
        // Use the original text cell and vertical font extents to bound ink,
        // then confirm the rendered candidate in the editor's paint envelope.
        // Equal PDF widths keep following shows and characters stationary.
        let pointWidth = oldWidth / 1000
        let fontBox = CTFontGetBoundingBox(pointFont)
        guard newInk.minX >= min(0, oldInk.minX), newInk.maxX <= max(pointWidth, oldInk.maxX),
              newInk.minY >= fontBox.minY, newInk.maxY <= fontBox.maxY else { return nil }
        let transform = CGAffineTransform(a: CGFloat(matrix.a) * size, b: 0, c: 0,
                                          d: CGFloat(matrix.d) * size, tx: x, ty: y)
        let placed = newInk.applying(transform)
        guard envelope.contains(placed), !obstacles.contains(where: { $0.intersects(placed) }) else { return nil }
        var patched = codes
        patched[offset] = newCode
        let command = Data(("<" + patched.map { String(format: "%04X", $0) }.joined() + "> Tj").utf8)
        return Patch(range: record.showRange, command: command, characterIndex: index)
    }

    static func hasSameLayout(_ source: FPDF_TEXTPAGE, _ edited: FPDF_TEXTPAGE,
                              index: Int32, to: UInt16, envelope: CGRect,
                              obstacles: [CGRect]) throws -> Bool {
        let count = FPDFText_CountChars(source)
        guard (1...100_000).contains(count), FPDFText_CountChars(edited) == count else { return false }
        for i in 0..<count {
            if i.isMultiple(of: 256) { try Task.checkCancellation() }
            let expected = i == index ? UInt32(to) : FPDFText_GetUnicode(source, i)
            guard FPDFText_GetUnicode(edited, i) == expected,
                  FPDFText_IsGenerated(source, i) == FPDFText_IsGenerated(edited, i) else { return false }
            if FPDFText_IsGenerated(source, i) != 0 { continue }
            var ax = 0.0, ay = 0.0, bx = 0.0, by = 0.0
            var am = FS_MATRIX(), bm = FS_MATRIX()
            guard FPDFText_GetCharOrigin(source, i, &ax, &ay) != 0,
                  FPDFText_GetCharOrigin(edited, i, &bx, &by) != 0, ax == bx, ay == by,
                  FPDFText_GetMatrix(source, i, &am) != 0, FPDFText_GetMatrix(edited, i, &bm) != 0,
                  am.a == bm.a, am.b == bm.b, am.c == bm.c, am.d == bm.d,
                  am.e == bm.e, am.f == bm.f,
                  FPDFText_GetFontSize(source, i) == FPDFText_GetFontSize(edited, i),
                  let actual = box(edited, i) else { return false }
            if i == index {
                guard !actual.isEmpty, envelope.contains(actual),
                      !obstacles.contains(where: { $0.intersects(actual) }) else { return false }
            } else if box(source, i) != actual { return false }
        }
        return true
    }

    private static func box(_ page: FPDF_TEXTPAGE, _ index: Int32) -> CGRect? {
        var l = 0.0, r = 0.0, b = 0.0, t = 0.0
        guard FPDFText_GetCharBox(page, index, &l, &r, &b, &t) != 0,
              [l, r, b, t].allSatisfy(\.isFinite), r >= l, t >= b else { return nil }
        return CGRect(x: l, y: b, width: r - l, height: t - b)
    }

    private static func uniqueCode(for value: UInt16, in mapping: [UInt16: UInt16]) -> UInt16? {
        let matches = mapping.filter { $0.value == value }
        return matches.count == 1 ? matches.first?.key : nil
    }

    private static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var result: UnsafePointer<CChar>?
        return CGPDFDictionaryGetName(dictionary, key, &result) ? result.map { String(cString: $0) } : nil
    }

    private static func stream(_ dictionary: CGPDFDictionaryRef, _ key: String, maximum: Int) -> Data? {
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(dictionary, key, &stream), let stream,
              let fields = CGPDFStreamGetDictionary(stream),
              ["F", "FFilter", "FDecodeParms", "UseCMap"].allSatisfy({
                  PDFCatalogStructurePreserver.object(fields, $0) == nil
              }) else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format), format == .raw,
              CFDataGetLength(data) <= maximum else { return nil }
        return data as Data
    }

    private static func width(of code: UInt16, in descendant: CGPDFDictionaryRef) -> CGFloat? {
        var fallback: CGPDFReal = 1000
        if PDFCatalogStructurePreserver.object(descendant, "DW") != nil,
           !CGPDFDictionaryGetNumber(descendant, "DW", &fallback) { return nil }
        guard let widths = PDFCatalogStructurePreserver.array(descendant, "W") else { return fallback }
        let count = CGPDFArrayGetCount(widths)
        guard count <= 16_384 else { return nil }
        var at = 0, last = -1
        var found: CGFloat?
        while at < count {
            var first: CGPDFInteger = 0, end: CGPDFInteger = 0, value: CGPDFReal = 0
            var values: CGPDFArrayRef?
            guard CGPDFArrayGetInteger(widths, at, &first), first > last, first <= 65_535, at + 1 < count else { return nil }
            if CGPDFArrayGetArray(widths, at + 1, &values), let values {
                let size = CGPDFArrayGetCount(values)
                guard size > 0, size <= 65_536 - first else { return nil }
                last = first + size - 1
                if (first...last).contains(Int(code)) {
                    guard CGPDFArrayGetNumber(values, Int(code) - first, &value) else { return nil }
                    found = value
                }
                at += 2
            } else {
                guard at + 2 < count, CGPDFArrayGetInteger(widths, at + 1, &end), end >= first, end <= 65_535,
                      CGPDFArrayGetNumber(widths, at + 2, &value) else { return nil }
                last = end
                if (first...last).contains(Int(code)) { found = value }
                at += 3
            }
        }
        let result = found ?? fallback
        return result.isFinite && (0...100_000).contains(result) ? result : nil
    }

    private static func unicodeMap(_ data: Data) throws -> [UInt16: UInt16]? {
        var lexer = PDFBodyTextContentStream.Lexer(bytes: Array(data))
        var mapping: [UInt16: UInt16] = [:], previous: CGFloat?
        var codeSpace = false
        func code(_ token: PDFBodyTextContentStream.Lexer.Token?) -> UInt16? {
            guard let bytes = token?.stringBytes, bytes.count == 2 else { return nil }
            return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        }
        while let token = try lexer.next() {
            switch token.command {
            case "usecmap", "begincidchar", "begincidrange", "beginnotdefchar", "beginnotdefrange": return nil
            case "begincodespacerange":
                guard !codeSpace, previous == 1, code(try lexer.next()) == 0, code(try lexer.next()) == .max,
                      try lexer.next()?.command == "endcodespacerange" else { return nil }
                codeSpace = true
            case "beginbfchar", "beginbfrange":
                let range = token.command == "beginbfrange"
                guard codeSpace, let count = previous, count.rounded() == count, (1...4096).contains(count) else { return nil }
                for _ in 0..<Int(count) {
                    guard let start = code(try lexer.next()) else { return nil }
                    let end = range ? code(try lexer.next()) : start
                    guard let end, end >= start, let first = code(try lexer.next()),
                          Int(first) + Int(end - start) <= 65_535 else { return nil }
                    for n in start...end {
                        let value = first + (n - start)
                        guard !(0xd800...0xdfff).contains(value), mapping[n] == nil else { return nil }
                        mapping[n] = value
                    }
                }
                guard try lexer.next()?.command == (range ? "endbfrange" : "endbfchar") else { return nil }
            default: break
            }
            previous = token.number
        }
        return codeSpace ? mapping : nil
    }
}
