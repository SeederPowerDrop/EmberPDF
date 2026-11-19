// SPDX-License-Identifier: MPL-2.0

import CEmberPDFRawStreams
import CoreGraphics
import CoreText
import CPDFium
import Foundation
import zlib

/// Geometry only. Does not issue a font lease, tag/raw-copy
/// permission, registration or marker. The private Editor caller must supply
/// its existing independently prefix-bound LosslessPlan show, and the exact
/// snapshot used by the still-open native owner. It is not a general PDF API.
enum PDFBodyTextOriginalGlyphInk {
    static let maximumSnapshotBytes = 2 * 1_024 * 1_024
    private static let maximumProgramBytes = 1 * 1_024 * 1_024
    private static let maximumContentBytes = 256 * 1_024
    private enum Refusal: Error { case unsupported(Int) }

    /// The caller's immutable LosslessPlan supplies either one root showRange
    /// or its uniquely invoked own-Form name. No caller-provided proof Bool.
    @MainActor
    static func envelope(snapshot: Data, sourceContent: Data, showRange: Range<Int>?,
                         sourceFormName: String?, expectedText: String,
                         nativeObject: FPDF_PAGEOBJECT, nativeTextPage: FPDF_TEXTPAGE,
                         invocation: CGAffineTransform = .identity) throws -> CGRect? {
        do {
            try Task.checkCancellation()
            let units = Array(expectedText.utf16)
            try require(!units.isEmpty && units.count <= 512 && units.allSatisfy { (32...126).contains($0) })
            try require(FPDFPageObj_GetType(nativeObject) == FPDF_PAGEOBJ_TEXT
                && FPDFTextObj_GetTextRenderMode(nativeObject) == FPDF_TEXTRENDERMODE_FILL
                && FPDFPageObj_HasTransparency(nativeObject) == 0)
            guard let nativeFont = FPDFTextObj_GetFont(nativeObject) else { return nil }
            try require(FPDFFont_GetIsEmbedded(nativeFont) == 1)
            var size = 0
            try require(FPDFFont_GetFontData(nativeFont, nil, 0, &size) != 0
                && size > 12 && size <= maximumProgramBytes)
            var program = Data(count: size), copied = size
            try require(program.withUnsafeMutableBytes {
                FPDFFont_GetFontData(nativeFont, $0.bindMemory(to: UInt8.self).baseAddress, size, &copied)
            } != 0 && copied == size)
            let reader = try Reader(snapshot)
            let binding = try reader.binding(sourceContent: sourceContent, showRange: showRange,
                sourceFormName: sourceFormName, expected: units, nativeProgram: program)
            let count = FPDFText_CountChars(nativeTextPage)
            try require(count >= 0 && count <= 200_000)
            let indices = (0..<count).filter { FPDFText_GetTextObject(nativeTextPage, $0) == nativeObject }
            try require(indices.count == binding.glyphs.count)
            var ink = CGRect.null
            var glyphBounds: [CGGlyph: CGRect] = [:], empty = Set<CGGlyph>()
            let pointFont = CTFontCreateWithGraphicsFont(binding.graphics, 1, nil, nil)
            try require(CTFontCopyGraphicsFont(pointFont, nil) === binding.graphics)
            for (offset, index) in indices.enumerated() {
                if offset % 32 == 0 { try Task.checkCancellation() }
                try require(FPDFText_IsGenerated(nativeTextPage, index) == 0
                    && FPDFText_HasUnicodeMapError(nativeTextPage, index) == 0
                    && FPDFText_GetUnicode(nativeTextPage, index) == UInt32(units[offset]))
                var matrix = FS_MATRIX(), x = 0.0, y = 0.0
                let fontSize = FPDFText_GetFontSize(nativeTextPage, index)
                try require(FPDFText_GetMatrix(nativeTextPage, index, &matrix) != 0
                    && FPDFText_GetCharOrigin(nativeTextPage, index, &x, &y) != 0
                    && [matrix.a, matrix.b, matrix.c, matrix.d, matrix.e, matrix.f].allSatisfy(\.isFinite)
                    && matrix.b == 0 && matrix.c == 0 && matrix.a > 0 && matrix.d > 0
                    && x.isFinite && y.isFinite && fontSize.isFinite && fontSize > 0 && fontSize <= 1_000)
                let glyph = binding.glyphs[offset]
                if empty.contains(glyph) { continue }
                let localBounds: CGRect
                if let cached = glyphBounds[glyph] { localBounds = cached }
                else {
                    guard let path = CTFontCreatePathForGlyph(pointFont, glyph, nil) else {
                        // nil is never a blank-glyph proof. The original mapped
                        // space may be skipped only with independently empty glyf.
                        try require(units[offset] == 32 && emptyGlyph(glyph, in: binding.graphics))
                        empty.insert(glyph); continue
                    }
                    guard let bounds = PDFGlyphOutlineIdentity.closedPaintBounds(path) else { throw Refusal.unsupported(#line) }
                    try require(valid(bounds)); glyphBounds[glyph] = bounds; localBounds = bounds
                }
                // Origin is already page-space; do not add matrix.e/f again.
                let pointSize = CGFloat(fontSize)
                let transform = CGAffineTransform(a: CGFloat(matrix.a) * pointSize,
                    b: CGFloat(matrix.b) * pointSize, c: CGFloat(matrix.c) * pointSize,
                    d: CGFloat(matrix.d) * pointSize, tx: CGFloat(x), ty: CGFloat(y))
                let bounds = localBounds.applying(transform)
                try require(valid(bounds))
                ink = ink.union(bounds)
                // Raw Tj state/Widths also provide original mathematical
                // placement. Preserve both independently traced envelopes;
                // never pad by an epsilon to hide native Float conversion.
                var rawTransform = binding.rawTransforms[offset]
                if binding.formBox != nil { rawTransform = rawTransform.concatenating(invocation) }
                try require(rawTransform.b == 0 && rawTransform.c == 0 && rawTransform.a > 0 && rawTransform.d > 0)
                let rawBounds = localBounds.applying(rawTransform)
                try require(valid(rawBounds)); ink = ink.union(rawBounds)
            }
            try require(valid(ink))
            if let box = binding.formBox {
                try require([invocation.a,invocation.b,invocation.c,invocation.d,invocation.tx,invocation.ty].allSatisfy(\.isFinite)
                    && invocation.b == 0 && invocation.c == 0 && invocation.a > 0 && invocation.d > 0
                    && box.applying(invocation).contains(ink))
            }
            return ink
        } catch is CancellationError { throw CancellationError() }
        catch {
            #if DEBUG
            if ProcessInfo.processInfo.environment["EMBER_BODY_SOURCE_QA_DIRECTORY"] != nil {
                print("ORIGINAL_GLYPH_INK_REFUSAL \(error)")
            }
            #endif
            return nil
        }
    }

    private struct Binding {
        let graphics: CGFont
        let glyphs: [CGGlyph]
        let rawTransforms: [CGAffineTransform]
        let formBox: CGRect?
    }
    private struct Show {
        let range: Range<Int>
        let font: String
        let bytes: [UInt8]
        let graphicsStates: [String]
        let matrix: CGAffineTransform
        let fontSize: CGFloat
        let characterSpace: CGFloat
        let wordSpace: CGFloat
        let horizontalScale: CGFloat
        let rise: CGFloat
        let explicit: Set<String>
    }
    /// Only the exact selected Tj is decoded. Other shows cannot select an
    /// authority; q/Q restore Tf and GS. Font-changing GS and all raw clipping/
    /// ActualText in the selected scope are conservatively outside this lane.
    private static func shows(_ data: Data, rejectGraphicsStates: Bool = false) throws -> [Show] {
        try require(data.count <= maximumContentBytes)
        var lexer = PDFBodyTextContentStream.Lexer(bytes: Array(data))
        var operands: [PDFBodyTextContentStream.Lexer.Token] = []
        struct State {
            var font: String?, states: [String] = [], ctm = CGAffineTransform.identity
            var size: CGFloat = 0, characterSpace: CGFloat = 0, wordSpace: CGFloat = 0
            var scale: CGFloat = 1, rise: CGFloat = 0
            var explicit = Set<String>()
        }
        var state = State(), stack: [State] = [], textMatrix: CGAffineTransform?
        var result: [Show] = [], commands = 0, inText = false, showed = false
        while let token = try lexer.next() {
            guard let command = token.command else {
                operands.append(token); try require(operands.count <= 256); continue
            }
            commands += 1; try require(commands <= 100_000)
            switch command {
            case "q": try require(!inText && operands.isEmpty && stack.count < 64); stack.append(state)
            case "Q":
                try require(!inText && operands.isEmpty)
                guard let old = stack.popLast() else { throw Refusal.unsupported(#line) }; state = old
            case "cm", "Tm":
                try require(command == "cm" ? !inText : inText)
                let values = operands.compactMap(\.number)
                try require(operands.count == 6 && values.count == 6 && values.allSatisfy { $0.isFinite && abs($0) <= 1_000_000 })
                let matrix = CGAffineTransform(a:values[0],b:values[1],c:values[2],d:values[3],tx:values[4],ty:values[5])
                if command == "cm" { state.ctm = matrix.concatenating(state.ctm) }
                else { textMatrix = matrix }
            case "BT":
                try require(!inText && operands.isEmpty); inText = true; showed = false; textMatrix = nil
            case "ET":
                try require(inText && operands.isEmpty); inText = false; textMatrix = nil
            case "Td", "TD":
                try require(inText && operands.count == 2 && operands.allSatisfy { $0.number?.isFinite == true }); textMatrix = nil
            case "T*": try require(inText && operands.isEmpty); textMatrix = nil
            case "TL":
                try require(inText && operands.count == 1 && operands[0].number?.isFinite == true)
            case "Tf":
                try require(operands.count == 2 && operands[1].number.map { $0.isFinite && $0 > 0 } == true)
                guard let name = operands[0].name, let size = operands[1].number, size <= 1_000 else { throw Refusal.unsupported(#line) }
                state.font = name; state.size = size; state.explicit.insert("Tf")
            case "Tc", "Tw", "Tz", "Ts":
                try require(operands.count == 1); state.explicit.insert(command)
                guard let value = operands[0].number, value.isFinite, abs(value) <= 1_000_000 else { throw Refusal.unsupported(#line) }
                if command == "Tc" { state.characterSpace = value }
                else if command == "Tw" { state.wordSpace = value }
                else if command == "Ts" { state.rise = value }
                else { try require(value > 0 && value <= 1_000); state.scale = value / 100 }
            case "gs":
                try require(!rejectGraphicsStates && operands.count == 1)
                guard let name = operands[0].name else { throw Refusal.unsupported(#line) }
                state.states.append(name); try require(state.states.count <= 64)
            case "Tr": try require(operands.count == 1 && operands[0].number == 0); state.explicit.insert("Tr")
            case "TJ":
                try require(inText && operands.count == 1)
                let inert = data[operands[0].range].filter { ![0,9,10,12,13,32].contains($0) }
                try require(inert.elementsEqual([91,93]))
            case "W", "W*", "BMC", "BDC", "EMC", "BI", "ID", "EI", "'", "\"": throw Refusal.unsupported(#line)
            case "Tj":
                try require(inText && !showed && operands.count == 1); showed = true
                guard let bytes = operands[0].stringBytes, let font = state.font,
                      let textMatrix else { throw Refusal.unsupported(#line) }
                result.append(Show(range: operands[0].range.lowerBound..<token.range.upperBound,
                    font: font, bytes: bytes, graphicsStates: state.states,
                    matrix: textMatrix.concatenating(state.ctm), fontSize: state.size,
                    characterSpace: state.characterSpace, wordSpace: state.wordSpace,
                    horizontalScale: state.scale, rise: state.rise, explicit: state.explicit))
                try require(result.count <= 4_096)
            case "m", "l", "c", "v", "y", "h", "re", "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n", "Do", "sh":
                try require(!inText)
            case "w", "J", "j", "M", "d", "ri", "i", "CS", "cs", "SC", "SCN", "sc", "scn", "G", "g", "RG", "rg", "K", "k": break
            default: throw Refusal.unsupported(#line)
            }
            operands.removeAll(keepingCapacity: true)
        }
        try require(!inText && stack.isEmpty && operands.isEmpty)
        return result
    }

    private final class Reader {
        let raw: EmberRawPDFRef
        private var decodedRemaining = 2 * 1_024 * 1_024
        init(_ snapshot: Data) throws {
            try PDFBodyTextOriginalGlyphInk.require(!snapshot.isEmpty && snapshot.count <= PDFBodyTextOriginalGlyphInk.maximumSnapshotBytes)
            var status: Int32 = 0
            guard let raw = snapshot.withUnsafeBytes({
                ember_raw_pdf_create($0.bindMemory(to: UInt8.self).baseAddress, snapshot.count,
                    PDFBodyTextOriginalGlyphInk.maximumSnapshotBytes, 16_384, &status)
            }) else { throw Refusal.unsupported(#line) }
            guard status == Int32(EMBER_RAW_PDF_OK.rawValue) else { ember_raw_pdf_destroy(raw); throw Refusal.unsupported(#line) }
            self.raw = raw
        }
        deinit { ember_raw_pdf_destroy(raw) }
        @MainActor
        func binding(sourceContent: Data, showRange: Range<Int>?, sourceFormName: String?,
                     expected: [UInt16], nativeProgram: Data) throws -> Binding {
            var pages: UInt32 = 0; try PDFBodyTextOriginalGlyphInk.checked(ember_raw_pdf_page_count(raw, &pages)); try PDFBodyTextOriginalGlyphInk.require(pages == 1)
            let page = try object { ember_raw_pdf_page(raw, 0, &$0) }, pageEntries = try entries(page)
            guard let contents = pageEntries["/Contents"], let rootResources = pageEntries["/Resources"] else { throw Refusal.unsupported(#line) }
            try PDFBodyTextOriginalGlyphInk.require(try stream(contents, maximum: PDFBodyTextOriginalGlyphInk.maximumContentBytes) == sourceContent)
            var resources = rootResources, content = sourceContent, formBox: CGRect?
            if let name = sourceFormName {
                // Parent GS may affect a Form without appearing on its native
                // leaf. This initial lane refuses every root gs invocation.
                _ = try PDFBodyTextOriginalGlyphInk.shows(sourceContent, rejectGraphicsStates: true)
                try PDFBodyTextOriginalGlyphInk.require(showRange == nil && !name.isEmpty && name.utf8.count <= 128)
                let root = try entries(rootResources)
                guard let xobjects = root["/XObject"], let form = try entries(xobjects)["/"+name] else { throw Refusal.unsupported(#line) }
                let dictionary = try object { ember_raw_pdf_stream_dictionary(raw, form, &$0) }, values = try entries(dictionary)
                try PDFBodyTextOriginalGlyphInk.require(try named(values["/Subtype"]) == "/Form")
                guard let marker = values["/EmberPDFBodyText"], let scoped = values["/Resources"], let box = values["/BBox"] else { throw Refusal.unsupported(#line) }
                var enabled: Int32 = 0; try PDFBodyTextOriginalGlyphInk.checked(ember_raw_pdf_boolean(raw, marker, &enabled)); try PDFBodyTextOriginalGlyphInk.require(enabled == 1)
                for key in ["/Group","/Ref","/Metadata","/StructParent","/StructParents","/EmberPDFOutlinedOCR","/EmberPDFScannedErasure"] { try PDFBodyTextOriginalGlyphInk.require(values[key] == nil) }
                if let matrix = values["/Matrix"] { try PDFBodyTextOriginalGlyphInk.require(try numbers(matrix) == [1,0,0,1,0,0]) }
                let coordinates = try numbers(box); try PDFBodyTextOriginalGlyphInk.require(coordinates.count == 4)
                let rect = CGRect(x: coordinates[0], y: coordinates[1], width: coordinates[2]-coordinates[0], height: coordinates[3]-coordinates[1])
                try PDFBodyTextOriginalGlyphInk.require(PDFBodyTextOriginalGlyphInk.valid(rect)); formBox = rect
                resources = scoped; content = try stream(form, maximum: PDFBodyTextOriginalGlyphInk.maximumContentBytes)
            } else { try PDFBodyTextOriginalGlyphInk.require(showRange != nil) }
            let records = try PDFBodyTextOriginalGlyphInk.shows(content)
            let selected: Show
            if sourceFormName != nil {
                try PDFBodyTextOriginalGlyphInk.require(records.count == 1); selected = records[0]
                // A Form inherits caller text state. Only the explicit reset
                // emitted by the existing owned donor is admitted here.
                try PDFBodyTextOriginalGlyphInk.require(Set(["Tf","Tc","Tw","Tz","Ts","Tr"]).isSubset(of: selected.explicit))
            } else {
                let matching = records.filter { $0.range == showRange }
                try PDFBodyTextOriginalGlyphInk.require(matching.count == 1); selected = matching[0]
            }
            try PDFBodyTextOriginalGlyphInk.require(selected.bytes.count == expected.count
                && zip(selected.bytes,expected).allSatisfy { UInt16($0.0) == $0.1 })
            let scope = try entries(resources)
            if !selected.graphicsStates.isEmpty {
                guard let states = scope["/ExtGState"] else { throw Refusal.unsupported(#line) }
                let dictionary = try entries(states)
                for name in selected.graphicsStates {
                    guard let state = dictionary["/"+name] else { throw Refusal.unsupported(#line) }
                    try PDFBodyTextOriginalGlyphInk.require(try entries(state)["/Font"] == nil)
                }
            }
            guard let fonts = scope["/Font"], let font = try entries(fonts)["/"+selected.font] else { throw Refusal.unsupported(#line) }
            let values = try entries(font)
            let subtype = try named(values["/Subtype"]), encoding = try named(values["/Encoding"])
            try PDFBodyTextOriginalGlyphInk.require(subtype == "/TrueType" && encoding == "/MacRomanEncoding" && values["/ToUnicode"] == nil)
            guard let descriptor = values["/FontDescriptor"], let first = values["/FirstChar"], let last = values["/LastChar"], let widths = values["/Widths"] else { throw Refusal.unsupported(#line) }
            let start = try integer(first), end = try integer(last), widthValues = try numbers(widths)
            try PDFBodyTextOriginalGlyphInk.require(start >= 0 && end >= start && end <= 255 && widthValues.count == Int(end-start+1)
                && selected.bytes.allSatisfy { Int64($0) >= start && Int64($0) <= end })
            let fields = try entries(descriptor)
            guard let flags = fields["/Flags"], let program = fields["/FontFile2"] else { throw Refusal.unsupported(#line) }
            try PDFBodyTextOriginalGlyphInk.require(try integer(flags) == 32 && fields["/FontFile"] == nil && fields["/FontFile3"] == nil)
            let bytes = try stream(program, maximum: PDFBodyTextOriginalGlyphInk.maximumProgramBytes)
            // Both standard SFNT and Apple's legacy TrueType signatures are
            // used by the existing original-program font path. Neither a CFF
            // signature nor a differing native program acquires this proof.
            let trueTypeSignatures = [[UInt8]([0, 1, 0, 0]), Array("true".utf8)]
            try PDFBodyTextOriginalGlyphInk.require(bytes == nativeProgram
                && trueTypeSignatures.contains(Array(bytes.prefix(4))))
            guard let provider = CGDataProvider(data: bytes as CFData), let graphics = CGFont(provider),
                  PDFBodyTextOriginalGlyphInk.hasOnlyMacRomanCmap(graphics),
                  let mapping = PDFBodyTextDocumentFonts.sourceMacRomanGlyphs(in: graphics) else { throw Refusal.unsupported(#line) }
            var glyphs: [CGGlyph] = [], transforms: [CGAffineTransform] = [], advance: CGFloat = 0
            for code in selected.bytes {
                guard let glyph = mapping[Int(code)], glyph != 0, Int(glyph) < graphics.numberOfGlyphs else { throw Refusal.unsupported(#line) }
                let name = try PDFBodyTextOriginalGlyphInk.glyphName(code)
                try PDFBodyTextOriginalGlyphInk.require(graphics.getGlyphWithGlyphName(name: name as CFString) == glyph)
                glyphs.append(glyph)
                transforms.append(CGAffineTransform(a:selected.fontSize * selected.horizontalScale,b:0,
                    c:0,d:selected.fontSize,tx:advance,ty:selected.rise).concatenating(selected.matrix))
                let width = widthValues[Int(Int64(code)-start)]
                try PDFBodyTextOriginalGlyphInk.require(width >= 0)
                advance += (width / 1_000 * selected.fontSize + selected.characterSpace
                    + (code == 32 ? selected.wordSpace : 0)) * selected.horizontalScale
                try PDFBodyTextOriginalGlyphInk.require(advance.isFinite && abs(advance) <= 1_000_000)
            }
            return Binding(graphics: graphics, glyphs: glyphs, rawTransforms: transforms, formBox: formBox)
        }
        private func integer(_ value: EmberRawPDFObject) throws -> Int64 {
            var n: Int64 = 0; try PDFBodyTextOriginalGlyphInk.checked(ember_raw_pdf_integer(raw,value,&n)); return n
        }
        private func numbers(_ value: EmberRawPDFObject) throws -> [CGFloat] {
            var count: UInt32 = 0; try PDFBodyTextOriginalGlyphInk.checked(ember_raw_pdf_array_count(raw,value,&count)); try PDFBodyTextOriginalGlyphInk.require(count <= 256)
            return try (0..<count).map { index in
                let member = try object { ember_raw_pdf_array_item(raw,value,index,&$0) }
                var kind: Int32 = 0; try PDFBodyTextOriginalGlyphInk.checked(ember_raw_pdf_kind(raw,member,&kind))
                let number: Double
                if kind == 2 { number = Double(try integer(member)) }
                else { var real = 0.0; try PDFBodyTextOriginalGlyphInk.checked(ember_raw_pdf_real(raw,member,&real)); number = real }
                try PDFBodyTextOriginalGlyphInk.require(number.isFinite && abs(number) <= 1_000_000); return CGFloat(number)
            }
        }
        private func entries(_ value: EmberRawPDFObject) throws -> [String: EmberRawPDFObject] {
            var count: UInt32 = 0; try PDFBodyTextOriginalGlyphInk.checked(ember_raw_pdf_dictionary_count(raw,value,&count)); try PDFBodyTextOriginalGlyphInk.require(count <= 256)
            var result: [String: EmberRawPDFObject] = [:]
            for index in 0..<count {
                let key = try copy(maximum: 256) { ember_raw_pdf_bounded_key_copy(raw,value,index,256,&$0,&$1) }
                guard let name = String(data:key,encoding:.utf8), !name.utf8.contains(0), result[name] == nil else { throw Refusal.unsupported(#line) }
                result[name] = try key.withUnsafeBytes { bytes in
                    try object { ember_raw_pdf_dictionary_get(raw,value,bytes.bindMemory(to:UInt8.self).baseAddress,key.count,&$0) }
                }
            }
            return result
        }
        private func named(_ value: EmberRawPDFObject?) throws -> String {
            guard let value else { throw Refusal.unsupported(#line) }
            var kind: Int32 = 0; try PDFBodyTextOriginalGlyphInk.checked(ember_raw_pdf_kind(raw,value,&kind)); try PDFBodyTextOriginalGlyphInk.require(kind == 4)
            guard let name = String(data:try copy(maximum:256) { ember_raw_pdf_bounded_scalar_copy(raw,value,256,&$0,&$1) },encoding:.utf8) else { throw Refusal.unsupported(#line) }; return name
        }
        private func stream(_ value: EmberRawPDFObject, maximum: Int) throws -> Data {
            let dictionary = try object { ember_raw_pdf_stream_dictionary(raw,value,&$0) }, fields = try entries(dictionary)
            for key in ["/DecodeParms","/F","/FFilter","/FDecodeParms"] { try PDFBodyTextOriginalGlyphInk.require(fields[key] == nil) }
            let filter = fields["/Filter"]
            if filter != nil { try PDFBodyTextOriginalGlyphInk.require(try named(filter) == "/FlateDecode") }
            guard let length = fields["/Length"] else { throw Refusal.unsupported(#line) }
            let expected = try integer(length); try PDFBodyTextOriginalGlyphInk.require(expected >= 0 && expected <= maximum)
            let encoded = try copy(maximum:maximum) { ember_raw_pdf_stream_copy(raw,value,maximum,{_ in
                do { try Task.checkCancellation(); return 0 } catch { return 1 }
            },nil,&$0,&$1) }
            try PDFBodyTextOriginalGlyphInk.require(encoded.count == expected)
            let decoded: Data
            if filter == nil { decoded = encoded }
            else { decoded = try PDFBodyTextOriginalGlyphInk.inflateData(encoded, maximum:min(maximum,decodedRemaining)) }
            try PDFBodyTextOriginalGlyphInk.require(decoded.count <= decodedRemaining); decodedRemaining -= decoded.count
            return decoded
        }
        private func object(_ action: (inout EmberRawPDFObject) -> Int32) throws -> EmberRawPDFObject {
            var value: EmberRawPDFObject = 0; try PDFBodyTextOriginalGlyphInk.checked(action(&value)); return value
        }
        private func copy(maximum: Int, _ action: (inout UnsafeMutablePointer<UInt8>?,inout Int) -> Int32) throws -> Data {
            var pointer: UnsafeMutablePointer<UInt8>?, count = 0
            let status = action(&pointer,&count); defer { if let pointer { ember_raw_pdf_free(pointer) } }
            try PDFBodyTextOriginalGlyphInk.checked(status); try PDFBodyTextOriginalGlyphInk.require(count >= 0 && count <= maximum && (count == 0 || pointer != nil))
            return pointer.map { Data(bytes:$0,count:count) } ?? Data()
        }
    }
    private static func glyphName(_ code: UInt8) throws -> String {
        try require((32...126).contains(code))
        var names: [String] = ["space","exclam","quotedbl","numbersign","dollar","percent","ampersand","quotesingle","parenleft","parenright","asterisk","plus","comma","hyphen","period","slash"]
        names.append(contentsOf: ["zero","one","two","three","four","five","six","seven","eight","nine"])
        names.append(contentsOf: ["colon","semicolon","less","equal","greater","question","at"])
        names.append(contentsOf: (65...90).map { String(UnicodeScalar($0)!) })
        names.append(contentsOf: ["bracketleft","backslash","bracketright","asciicircum","underscore","grave"])
        names.append(contentsOf: (97...122).map { String(UnicodeScalar($0)!) })
        names.append(contentsOf: ["braceleft","bar","braceright","asciitilde"])
        return names[Int(code)-32]
    }
    /// Prevent an alternate Unicode/symbol cmap from selecting a different
    /// native glyph for the same byte. Existing bounded format0/6 reader then
    /// validates every MacRoman record and rejects conflicting entries.
    private static func hasOnlyMacRomanCmap(_ font: CGFont) -> Bool {
        let ct = CTFontCreateWithGraphicsFont(font, 1, nil, nil)
        guard CTFontCopyGraphicsFont(ct, nil) === font,
              let data = CTFontCopyTable(ct, 0x636d6170, []) as Data?,
              data.count >= 4, data.count <= 1_024 * 1_024 else { return false }
        func u16(_ i: Int) -> Int { Int(data[data.startIndex+i]) << 8 | Int(data[data.startIndex+i+1]) }
        let count = u16(2)
        guard u16(0) == 0, (1...16).contains(count), data.count >= 4 + count * 8 else { return false }
        return (0..<count).allSatisfy { u16(4+$0*8) == 1 && u16(6+$0*8) == 0 }
    }
    private static func emptyGlyph(_ glyph: CGGlyph, in font: CGFont) -> Bool {
        let pointFont = CTFontCreateWithGraphicsFont(font, 1, nil, nil)
        guard CTFontCopyGraphicsFont(pointFont,nil) === font,
              let head = CTFontCopyTable(pointFont,0x68656164,[]) as Data?, let maxp = CTFontCopyTable(pointFont,0x6d617870,[]) as Data?,
              let loca = CTFontCopyTable(pointFont,0x6c6f6361,[]) as Data?, let glyf = CTFontCopyTable(pointFont,0x676c7966,[]) as Data?,
              head.count >= 54, maxp.count >= 6 else { return false }
        func u16(_ d:Data,_ i:Int)->Int { Int(d[d.startIndex+i])<<8|Int(d[d.startIndex+i+1]) }
        let count=u16(maxp,4), format=u16(head,50), index=Int(glyph)
        guard index<count, format==0 || format==1 else{return false}
        let width=format==0 ? 2:4; guard loca.count>=(count+1)*width else{return false}
        func offset(_ i:Int)->Int { let p=i*width; return format==0 ? u16(loca,p)*2 : (u16(loca,p)<<16|u16(loca,p+2)) }
        let start=offset(index),end=offset(index+1)
        return start==end && start>=0 && end<=glyf.count
    }
    private static func inflateData(_ encoded:Data,maximum:Int)throws->Data {
        try require(!encoded.isEmpty && maximum>0)
        var state=z_stream();try require(inflateInit_(&state,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))==Z_OK)
        defer{inflateEnd(&state)}
        return try encoded.withUnsafeBytes{input in
            state.next_in=UnsafeMutablePointer(mutating:input.bindMemory(to:Bytef.self).baseAddress);state.avail_in=uInt(input.count)
            var result=Data(),buffer=[UInt8](repeating:0,count:4096)
            while true{
                try Task.checkCancellation();let before=state.avail_in
                let status=buffer.withUnsafeMutableBytes{out->Int32 in state.next_out=out.bindMemory(to:Bytef.self).baseAddress;state.avail_out=uInt(out.count);return inflate(&state,Z_NO_FLUSH)}
                let made=buffer.count-Int(state.avail_out);try require(made<=maximum-result.count)
                result.append(contentsOf:buffer.prefix(made))
                if status==Z_STREAM_END{try require(state.avail_in==0);return result}
                try require(status==Z_OK && (made>0 || state.avail_in<before))
            }
        }
    }
    private static func valid(_ r:CGRect)->Bool { !r.isNull && [r.minX,r.minY,r.maxX,r.maxY].allSatisfy(\.isFinite) && r.width>0 && r.height>0 }
    private static func require(_ value: Bool, line: Int = #line) throws { if !value { throw Refusal.unsupported(line) } }
    private static func checked(_ status: Int32, line: Int = #line) throws { if status == Int32(EMBER_RAW_PDF_CANCELLED.rawValue) { throw CancellationError() }; try require(status == Int32(EMBER_RAW_PDF_OK.rawValue), line: line) }
}
