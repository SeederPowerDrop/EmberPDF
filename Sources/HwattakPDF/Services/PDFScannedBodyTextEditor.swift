// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import CryptoKit
import CPDFium
import PDFKit

/// A bounded hint stored only on a generated normal-font scan donor. Neither
/// this marker nor its digest proves clearance: the resolver independently
/// verifies the current paper program, every other paint's erasure clip and
/// the uniquely invoked native text-only donor before using these rows.
struct PDFScannedErasureMetadata: Codable {
    static let maximumBytes = 16 * 1_024
    private let version: Int
    private let rectangles: [[Double]]
    private let paper: [Double]
    private let programSHA256: String

    var erasedRects: [CGRect] {
        rectangles.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
    }
    var paperColor: PDFTextColor {
        PDFTextColor(red: CGFloat(paper[0]), green: CGFloat(paper[1]),
                     blue: CGFloat(paper[2]), alpha: 1)
    }
    var bounds: CGRect { erasedRects.reduce(CGRect.null) { $0.union($1) } }

    init(erasedRects: [CGRect], paperColor: PDFTextColor, program: Data) throws {
        version = 1
        rectangles = erasedRects.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
        paper = [Double(paperColor.red), Double(paperColor.green), Double(paperColor.blue)]
        programSHA256 = SHA256.hash(data: program).map { String(format: "%02x", $0) }.joined()
        try validate()
    }
    private func validate() throws {
        guard version == 1, !rectangles.isEmpty, rectangles.count <= 64,
              rectangles.allSatisfy({ $0.count == 4
                  && $0.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 })
                  && $0[2] > 0 && $0[3] > 0 }),
              paper.count == 3, paper.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              programSHA256.utf8.count == 64,
              programSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw PDFBodyTextContentStream.ParseFailure.unsupported
        }
        for (index, rectangle) in erasedRects.enumerated() {
            guard erasedRects.prefix(index).allSatisfy({ !$0.intersects(rectangle) }) else {
                throw PDFBodyTextContentStream.ParseFailure.unsupported
            }
        }
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw PDFBodyTextContentStream.ParseFailure.limitExceeded }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw PDFBodyTextContentStream.ParseFailure.limitExceeded
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    func replacingProgram(_ program: Data) throws -> Self {
        try Self(erasedRects: erasedRects, paperColor: paperColor, program: program)
    }
    func provesCurrentProgram(_ program: Data, mediaBox: CGRect,
                              donorName: String, donorRange: Range<Int>,
                              requiringPositiveDonorClip: Bool = false) throws -> Bool {
        try Task.checkCancellation()
        guard !program.isEmpty, program.count <= 64 * 1_024 * 1_024,
              erasedRects.allSatisfy({ mediaBox.contains($0) }),
              SHA256.hash(data: program).map({ String(format: "%02x", $0) }).joined() == programSHA256 else { return false }
        return try PDFScannedReadOrderContent.provesGeneratedErasureProgram(program,
            erasedRects: erasedRects, mediaBox: mediaBox, paperColor: paperColor,
            donorName: donorName, donorRange: donorRange,
            requiringPositiveDonorClip: requiringPositiveDonorClip)
    }
}

/// A scan has an image and a separate, invisible recognition layer. Editing
/// only that layer would leave the printed words unchanged. This bounded route
/// replaces the selected ink in page content while retaining the image stream.
@MainActor
enum PDFScannedBodyTextEditor {
    struct Source {
        let snapshot: Data
        let rootIndices: [Int]
        let erasedRects: [CGRect]
        let paperColor: PDFTextColor
        var recoveredZeroWidthRoots: [Int:String] = [:]
        var firstRemovedShowOffset: Int? = nil
        var semanticFontName: String? = nil
        var semanticEncoding: PDFOCRTextEncoding? = nil
        var semanticDefaultWidth: CGFloat = 1_000
        var semanticLineMatrices: [CGAffineTransform] = []
        var semanticLineFontSizes: [CGFloat] = []
        var semanticLineWidths: [CGFloat] = []
        var preservedFormNames: Set<String> = []
    }
    struct Description {
        let text: String
        let bounds: CGRect
        let baseline: CGPoint
        let style: InlineTextStyle
        let lineHeight: CGFloat?
        let firstLineIndent: CGFloat
        let sourceRuns: [InlineTextSourceRun]
        let selectedRange: NSRange
        let source: Source
    }
    enum Failure: LocalizedError {
        case unsupported, doesNotFit
        var errorDescription: String? {
            switch self {
            case .unsupported:
                return L10n.string("body_text.error.scan_background", defaultValue:
                    "선택한 스캔 본문의 배치와 배경을 안전하게 유지하며 편집할 수 없습니다. 같은 문단의 줄을 선택하거나 한 줄씩 편집해 주세요.")
            case .doesNotFit:
                return L10n.string("body_text.error.scan_selection_fit", defaultValue:
                    "입력한 글자가 선택한 스캔 영역을 벗어납니다. 더 넓은 문장이나 문단을 선택하거나 글자 크기를 줄여 주세요.")
            }
        }
    }
    private struct Glyph {
        let text: String
        let bounds: CGRect
        let origin: CGPoint
        let size: CGFloat
        let selected: Bool
    }
    private struct Run {
        let root: Int
        let text: String
        let bounds: CGRect
        let baseline: CGPoint
        let size: CGFloat
        let selectedRange: NSRange?
        let glyphMasks: [CGRect]
        let semanticMatrix: CGAffineTransform
        let semanticFontSize: CGFloat
    }

    static func target(on page: PDFPage, selection: PDFSelection, nativePage: FPDF_PAGE,
                       textPage: FPDF_TEXTPAGE, characterCount: Int32,
                       snapshot: () throws -> Data,
                       protectedFormBounds: [Int: [CGRect]] = [:],
                       protectedFormNames: [Int: String] = [:]) throws -> Description? {
        let fragments = selection.selectionsByLine().map { $0.bounds(for: page) }
        guard !fragments.isEmpty, fragments.count <= 64,
              page.rotation == 0, page.bounds(for: .mediaBox).origin == .zero else { return nil }
        let roots = (0..<FPDFPage_CountObjects(nativePage)).compactMap { index -> (Int, FPDF_PAGEOBJECT)? in
            FPDFPage_GetObject(nativePage, index).map { (Int(index), $0) }
        }
        guard roots.contains(where: { FPDFPageObj_GetType($0.1) == FPDF_PAGEOBJ_TEXT
            && FPDFTextObj_GetTextRenderMode($0.1) == FPDF_TEXTRENDERMODE_INVISIBLE }) else { return nil }
        let rootMap = Dictionary(uniqueKeysWithValues: roots.map { ($0.1, $0.0) })
        var glyphs: [FPDF_PAGEOBJECT: [Glyph]] = [:]
        var touched = Set<FPDF_PAGEOBJECT>()
        var touchedVisible = false
        var protectedTextRects: [CGRect] = []
        var recognizedHyphens: [FPDF_PAGEOBJECT: [CGRect]] = [:]
        var recoveredZeroWidthRoots:[Int:String]=[:]
        for index in 0..<characterCount {
            guard let object = FPDFText_GetTextObject(textPage, index),
                  let rawScalar = UnicodeScalar(FPDFText_GetUnicode(textPage, index)),
                  rawScalar.value > 0, !CharacterSet.newlines.contains(rawScalar) else { continue }
            // PDFium uses U+0002 for a recognized line-end hyphen. It is not
            // the source's Unicode text; retain the printed '-' only when
            // PDFium independently identifies this character as a hyphen.
            let scalar = rawScalar.value == 2 && FPDFText_IsHyphen(textPage, index) == 1
                ? UnicodeScalar(45)! : rawScalar
            var x = 0.0, y = 0.0, left = 0.0, right = 0.0, bottom = 0.0, top = 0.0
            guard FPDFText_GetCharOrigin(textPage, index, &x, &y) != 0,
                  FPDFText_GetCharBox(textPage, index, &left, &right, &bottom, &top) != 0 else { continue }
            var matrix = FS_MATRIX()
            guard FPDFText_GetMatrix(textPage, index, &matrix) != 0 else { continue }
            let size = CGFloat(FPDFText_GetFontSize(textPage, index)) * CGFloat(matrix.d)
            var box = CGRect(x: left, y: bottom, width: right-left, height: top-bottom)
            if box.height < 0.1 {
                // Acrobat Paper Capture's Korean CID font has no outlines,
                // hence zero ink height. The OCR em cell still has geometry.
                box = CGRect(x: left, y: y-size*0.25, width: max(1,right-left), height: size*1.25)
            }
            let selected = FPDFText_IsGenerated(textPage, index) == 0
                && !CharacterSet.whitespaces.contains(scalar)
                && fragments.contains { $0.insetBy(dx: -0.2, dy: -0.2).contains(CGPoint(x: box.midX, y: box.midY)) }
            let invisible = FPDFTextObj_GetTextRenderMode(object) == FPDF_TEXTRENDERMODE_INVISIBLE
            if selected, !invisible { touchedVisible = true }
            if !invisible, !CharacterSet.whitespaces.contains(scalar) { protectedTextRects.append(box) }
            guard invisible else { continue }
            if rawScalar.value == 2, FPDFText_IsHyphen(textPage, index) == 1 {
                recognizedHyphens[object, default: []].append(box)
            }
            if selected {
                guard rootMap[object] != nil, size >= InlineTextStyle.minimumFontSize,
                      size <= InlineTextStyle.maximumFontSize,
                      matrix.a > 0, matrix.d > 0, abs(matrix.b) < 0.001, abs(matrix.c) < 0.001 else {
                    throw Failure.unsupported
                }
                touched.insert(object)
            }
            glyphs[object, default: []].append(Glyph(text: String(scalar), bounds: box,
                origin: CGPoint(x: x,y:y), size:size, selected:selected))
        }
        // PDFium occasionally suppresses an OCR character whose cell overlaps
        // the preceding word's oversized space. The native object still exists
        // and PDFKit can read its Unicode. Recover only a bounded object whose
        // independently selected text fits its exact native cell rectangle.
        for (rootIndex,object) in roots where glyphs[object]?.contains(where: {
            !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        }) != true {
            guard FPDFPageObj_GetType(object)==FPDF_PAGEOBJ_TEXT,
                  FPDFTextObj_GetTextRenderMode(object)==FPDF_TEXTRENDERMODE_INVISIBLE else{continue}
            var l:Float=0,b:Float=0,r:Float=0,t:Float=0,fontSize:Float=0,matrix=FS_MATRIX()
            guard FPDFPageObj_GetBounds(object,&l,&b,&r,&t) != 0,
                  FPDFPageObj_GetMatrix(object,&matrix) != 0,
                  FPDFTextObj_GetFontSize(object,&fontSize) != 0,
                  matrix.a>0,matrix.d>0,abs(matrix.b)<0.001,abs(matrix.c)<0.001 else{continue}
            let size=CGFloat(fontSize*matrix.d)
            guard size>=InlineTextStyle.minimumFontSize,size<=InlineTextStyle.maximumFontSize else{continue}
            let missingAdvance=r-l<0.1
            let cellWidth=missingAdvance ? CGFloat(fontSize*matrix.a) : CGFloat(r-l)
            let box=CGRect(x:CGFloat(l),y:CGFloat(matrix.f)-size*0.25,width:cellWidth,height:size*1.25)
            guard box.width>0,box.width<=size*8,
                  fragments.contains(where:{$0.insetBy(dx:-0.2,dy:-0.2).contains(CGPoint(x:box.midX,y:box.midY))}) else{continue}
            guard let recovered=page.selection(for:box.insetBy(dx:0.2,dy:0.2)),
                  let recoveredText=recovered.string,!recoveredText.isEmpty,recoveredText.utf16.count<=16,
                  box.insetBy(dx:-1,dy:-1).contains(recovered.bounds(for:page)) else{throw Failure.unsupported}
            if missingAdvance {
                // The raw stream planner must additionally prove that this
                // zero-advance object contains this one Unicode hex glyph.
                guard recoveredText.utf16.count==1,!recoveredText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw Failure.unsupported}
                recoveredZeroWidthRoots[rootIndex]=recoveredText
            }
            var recoveredGlyphs:[Glyph]=[],consumed=Set<NSRange>()
            for part in 0..<recovered.numberOfTextRanges(on:page) {
                let range=recovered.range(at:part,on:page)
                guard range.location != NSNotFound,range.length<=16 else{throw Failure.unsupported}
                for index in range.location..<NSMaxRange(range) {
                    guard let glyph=page.selection(for:NSRange(location:index,length:1)),
                          glyph.numberOfTextRanges(on:page)==1,let value=glyph.string else{throw Failure.unsupported}
                    let actual=glyph.range(at:0,on:page)
                    guard consumed.insert(actual).inserted else{continue}
                    let bounds=glyph.bounds(for:page)
                    guard !bounds.isEmpty,box.insetBy(dx:-1,dy:-1).contains(bounds) else{throw Failure.unsupported}
                    let selected=fragments.contains{$0.insetBy(dx:-0.2,dy:-0.2).contains(CGPoint(x:bounds.midX,y:bounds.midY))}
                    recoveredGlyphs.append(Glyph(text:value,bounds:bounds,
                        origin:CGPoint(x:bounds.minX,y:CGFloat(matrix.f)),size:size,selected:selected))
                }
            }
            guard !recoveredGlyphs.isEmpty,recoveredGlyphs.contains(where:{$0.selected}) else{throw Failure.unsupported}
            glyphs[object]=recoveredGlyphs;touched.insert(object)
        }
        guard !touched.isEmpty else { return nil }
        guard !touchedVisible, touched.count <= 256 else { throw Failure.unsupported }
        // Invisible text in an otherwise vector page is not assumed to be OCR.
        guard roots.contains(where: { _, object in
            guard FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_IMAGE else { return false }
            var l: Float=0,b:Float=0,r:Float=0,t:Float=0
            guard FPDFPageObj_GetBounds(object,&l,&b,&r,&t) != 0 else { return false }
            let box=CGRect(x:CGFloat(l),y:CGFloat(b),width:CGFloat(r-l),height:CGFloat(t-b))
            return fragments.allSatisfy { box.contains(CGPoint(x:$0.midX,y:$0.midY)) }
        }) else { return nil }
        var runs: [Run] = []
        for object in touched {
            guard let characters = glyphs[object], let first = characters.first,
                  let root = rootMap[object] else { throw Failure.unsupported }
            // Removing one PDF object must never silently span another row
            // or column: the complete object is the smallest removal unit.
            guard characters.allSatisfy({ abs($0.origin.y-first.origin.y)<2
                && (0.75...1.4).contains($0.size/first.size) }) else { throw Failure.unsupported }
            let painted = characters.filter { !$0.text.trimmingCharacters(in:.whitespaces).isEmpty }
            for pair in zip(painted,painted.dropFirst()) {
                guard pair.1.bounds.minX >= pair.0.bounds.minX-0.5,
                      pair.1.bounds.minX-pair.0.bounds.maxX <= max(24,first.size*2) else { throw Failure.unsupported }
            }
            let rawText = characters.map(\.text).joined()
            let text = rawText.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let trimStart = (rawText as NSString).range(of: text).location
            var offset = 0, selectedStart: Int?, selectedEnd = 0
            for character in characters {
                if character.selected {
                    if selectedStart == nil { selectedStart = offset }
                    selectedEnd = offset + character.text.utf16.count
                }
                offset += character.text.utf16.count
            }
            let selectedRange = selectedStart.map {
                NSRange(location: max(0, $0-trimStart), length: min(text.utf16.count, selectedEnd-trimStart)-max(0,$0-trimStart))
            }
            let box = characters.filter { !$0.text.trimmingCharacters(in:.whitespaces).isEmpty }
                .reduce(CGRect.null) { $0.union($1.bounds) }
            guard !box.isNull, !box.isEmpty else { throw Failure.unsupported }
            var nativeMatrix = FS_MATRIX(), nativeFontSize: Float = 0
            guard FPDFPageObj_GetMatrix(object, &nativeMatrix) != 0,
                  FPDFTextObj_GetFontSize(object, &nativeFontSize) != 0 else { throw Failure.unsupported }
            runs.append(Run(root:root,text:text,bounds:box,baseline:first.origin,size:first.size,
                selectedRange:selectedRange,glyphMasks:painted.map(\.bounds),
                semanticMatrix:CGAffineTransform(a:CGFloat(nativeMatrix.a),b:CGFloat(nativeMatrix.b),
                    c:CGFloat(nativeMatrix.c),d:CGFloat(nativeMatrix.d),tx:CGFloat(nativeMatrix.e),ty:CGFloat(nativeMatrix.f)),
                semanticFontSize:CGFloat(nativeFontSize)))
        }
        runs.sort { abs($0.baseline.y-$1.baseline.y)>2 ? $0.baseline.y>$1.baseline.y : $0.bounds.minX<$1.bounds.minX }
        guard !runs.isEmpty else { throw Failure.unsupported }
        var lines: [[Run]] = []
        for run in runs {
            if let last = lines.last, abs(last[0].baseline.y-run.baseline.y)<2 {
                guard run.bounds.minX-last.last!.bounds.maxX < max(24,run.size*2) else { throw Failure.unsupported }
                lines[lines.count-1].append(run)
            } else { lines.append([run]) }
        }
        guard lines.count<=64 else { throw Failure.unsupported }
        let sortedSizes = runs.map(\.size).sorted(), fontSize=sortedSizes[sortedSizes.count/2]
        guard runs.allSatisfy({ (0.75...1.4).contains($0.size/fontSize) }) else { throw Failure.unsupported }
        let lineRects=lines.map { $0.reduce(CGRect.null) { $0.union($1.bounds) } }
        let baselines=lines.map { $0[0].baseline.y }
        var lineHeight: CGFloat?
        if lines.count>1 {
            let distances=zip(baselines,baselines.dropFirst()).map(-)
            let mean=distances.reduce(0,+)/CGFloat(distances.count)
            guard (fontSize*1.1...fontSize*3).contains(mean),
                  distances.allSatisfy({abs($0-mean)<=max(2,mean*0.12)}),
                  lineRects.dropFirst().allSatisfy({abs($0.minX-lineRects[1].minX)<=fontSize*0.65}),
                  abs(lineRects[0].minX-lineRects[1].minX)<=fontSize*2 else { throw Failure.unsupported }
            lineHeight=mean
        }
        let inkBounds=lineRects.reduce(CGRect.null) { $0.union($1) }
        guard inkBounds.width>0,inkBounds.height>0 else { throw Failure.unsupported }
        // Reject any painted vector objects in the erased region. Only the
        // scanned image and its invisible recognition layer may be replaced.
        for (root,object) in roots where ![FPDF_PAGEOBJ_IMAGE,FPDF_PAGEOBJ_TEXT].contains(FPDFPageObj_GetType(object)) {
            let boxes: [CGRect]
            if FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_FORM,
               let verified = protectedFormBounds[root] {
                boxes = verified
            } else {
                boxes = conservativePaintBounds(of: object).map { [$0] } ?? []
            }
            for box in boxes {
                guard !lineRects.contains(where:{$0.intersects(box)}) else { throw Failure.unsupported }
                protectedTextRects.append(box)
            }
        }
        protectedTextRects += glyphs.filter { !touched.contains($0.key) }.flatMap {
            $0.value.filter { !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }.map(\.bounds)
        }
        let paper=try inspectPaper(on:page,rects:lineRects,glyphMasks:runs.flatMap(\.glyphMasks),
            hyphenMasks:touched.flatMap {recognizedHyphens[$0] ?? []},
            protectedRects:protectedTextRects,fontSize:fontSize)
        let nominalFont=NSFont(name:"AppleSDGothicNeo-Regular",size:fontSize) ?? .systemFont(ofSize:fontSize)
        func lineText(_ line:[Run])->String {
            var result=""
            for (index,word) in line.enumerated() {
                if index>0,word.bounds.minX-line[index-1].bounds.maxX>fontSize*0.12 { result+=" " }
                result+=word.text
            }
            return result
        }
        let sizeCorrections=zip(lines,paper.inkHeights).compactMap { line, inkHeight -> CGFloat? in
            let measured=CTLineCreateWithAttributedString(NSAttributedString(string:lineText(line),attributes:[.font:nominalFont]))
            let height=CTLineGetBoundsWithOptions(measured,.useGlyphPathBounds).height
            guard height>0,inkHeight>0 else{return nil}
            let ratio=inkHeight/height
            return (0.75...1.8).contains(ratio) ? ratio : nil
        }.sorted()
        guard sizeCorrections.count==lines.count else{throw Failure.unsupported}
        // OCR em sizes are synthetic recognition geometry, not the printed
        // font size. Match the measured scan ink height, then preserve each
        // row's original advance independently through its source run.
        let renderedSize=fontSize*sizeCorrections[sizeCorrections.count/2]
        guard renderedSize<=InlineTextStyle.maximumFontSize else{throw Failure.unsupported}
        let font=NSFont(name:nominalFont.fontName,size:renderedSize) ?? .systemFont(ofSize:renderedSize)
        let style=InlineTextStyle(fontName:font.fontName,fontSize:renderedSize,textColor:paper.ink,
            backgroundColor:.clear,alignment:.left)
        var text="",sourceRuns:[InlineTextSourceRun]=[]
        var selectedStart: Int?, selectedEnd = 0
        for (index,line) in lines.enumerated() {
            if index>0 {text+="\n"}
            let start=text.utf16.count
            var lineText=""
            for (wordIndex,word) in line.enumerated() {
                if wordIndex>0 {
                    let previous=line[wordIndex-1]
                    if word.bounds.minX-previous.bounds.maxX>fontSize*0.12 {lineText+=" "}
                }
                if let selected = word.selectedRange {
                    let start = text.utf16.count + lineText.utf16.count + selected.location
                    if selectedStart == nil { selectedStart = start }
                    selectedEnd = start + selected.length
                }
                lineText+=word.text
            }
            text+=lineText
            sourceRuns.append(InlineTextSourceRun(range:NSRange(location:start,length:lineText.utf16.count),
                style:style,horizontalAdvance:lineRects[index].width))
        }
        guard !InlineTextDraftLimiter.limit(text).wasTruncated, let selectedStart,
              selectedEnd > selectedStart,
              let selectedRange=matchingRange(selection.string ?? "",in:text,
                  within:NSRange(location:selectedStart,length:selectedEnd-selectedStart)) else { throw Failure.unsupported }
        let firstIndent=max(0,lineRects[0].minX-inkBounds.minX)
        let firstLine=CTLineCreateWithAttributedString(NSAttributedString(string:lineText(lines[0]),attributes:[.font:font]))
        let firstInk=CTLineGetBoundsWithOptions(firstLine,.useGlyphPathBounds)
        let fittedBaseline=paper.inkBounds[0].minY-firstInk.minY
        let bounds=CGRect(x:inkBounds.minX,y:inkBounds.minY,width:inkBounds.width,height:inkBounds.height)
        var source=Source(snapshot:try snapshot(),rootIndices:runs.map(\.root).sorted(),
            erasedRects:paper.rects,paperColor:paper.color)
        source.preservedFormNames = Set(protectedFormNames.compactMap { root, name in
            guard let bounds = protectedFormBounds[root], !bounds.isEmpty,
                  bounds.allSatisfy({ box in !paper.rects.contains(where: { $0.intersects(box) }) }) else { return nil }
            return name
        })
        source.recoveredZeroWidthRoots=recoveredZeroWidthRoots
        let raw = try PDFScannedContentStream.parse(PDFBodyTextPageSnapshot.contentData(for: page))
        let textRoots = roots.filter { FPDFPageObj_GetType($0.1) == FPDF_PAGEOBJ_TEXT }.map(\.0)
        guard raw.shows.count == textRoots.count,
              let first = source.rootIndices.compactMap({ textRoots.firstIndex(of: $0) }).min() else {
            throw Failure.unsupported
        }
        source.firstRemovedShowOffset = raw.shows[first].range.lowerBound
        let selectedShows = runs.compactMap { run -> (PDFScannedContentStream.Show, String)? in
            guard let ordinal = textRoots.firstIndex(of: run.root) else { return nil }
            return (raw.shows[ordinal], run.text)
        }
        if selectedShows.count == runs.count, let name = selectedShows.first?.0.fontName,
           selectedShows.allSatisfy({ $0.0.fontName == name }),
           let font = PDFBodyTextPageSnapshot.scannedOCRFont(named: name, on: page) {
            func equivalent(_ value: String?, _ expected: String) -> Bool {
                value?.filter { !$0.isWhitespace } == expected.filter { !$0.isWhitespace }
            }
            if selectedShows.allSatisfy({ equivalent($0.0.stringBytes.flatMap { String(bytes: $0, encoding: .utf16BigEndian) }, $0.1) }) {
                source.semanticEncoding = .utf16BE
            } else if selectedShows.allSatisfy({ equivalent($0.0.stringBytes.flatMap { String(bytes: $0, encoding: .ascii) }, $0.1) }) {
                source.semanticEncoding = .ascii
            }
            if source.semanticEncoding != nil {
                source.semanticFontName = name
                source.semanticDefaultWidth = font.defaultWidth
                source.semanticLineMatrices = lines.map { $0[0].semanticMatrix }
                source.semanticLineFontSizes = lines.map { $0[0].semanticFontSize }
                source.semanticLineWidths = lineRects.map(\.width)
            }
        }
        var baseline = CGPoint(x:lineRects[0].minX,y:fittedBaseline)
        if source.semanticFontName == nil || source.semanticEncoding == nil {
            let mediaBox = page.bounds(for:.mediaBox)
            let donor = try PDFBodyTextEditor.scannedSourceDonor(text,style:style,bounds:bounds,
                mediaBox:mediaBox,visibleBox:mediaBox.intersection(page.bounds(for:.cropBox)),
                baseline:baseline,lineHeight:lineHeight,firstLineIndent:firstIndent,sourceRuns:sourceRuns)
            guard let adjustment = try PDFScannedInkPlacement.baselineAdjustment(donor:donor,
                erasedRects:paper.rects,sourceInkRows:paper.inkBounds) else { throw Failure.doesNotFit }
            baseline.y += adjustment
        }
        return Description(text:text,bounds:bounds,baseline:baseline,
            style:style,lineHeight:lineHeight,firstLineIndent:firstIndent,sourceRuns:sourceRuns,
            selectedRange:selectedRange,source:source)
    }

    /// PDFium reports the un-clipped path rectangle. Our paper restoration is a
    /// page-sized fill clipped to the edited rows, so treating that raw bound as
    /// painted ink would incorrectly block an edit of every remaining row.
    /// Each clip's complete control-point box is a conservative paint bound;
    /// holes and curves can only reduce the actual painted region inside it.
    static func conservativePaintBounds(of object: FPDF_PAGEOBJECT) -> CGRect? {
        var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
        guard FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top) != 0,
              [left, bottom, right, top].allSatisfy(\.isFinite) else { return nil }
        let original = CGRect(x: CGFloat(left), y: CGFloat(bottom),
            width: CGFloat(right - left), height: CGFloat(top - bottom)).standardized
        var matrix = FS_MATRIX()
        // Clip points and path points are comparable without any coordinate
        // conversion only for an identity root path. Unknown transforms retain
        // the old, wider protection instead of guessing a coordinate space.
        guard FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_PATH,
              FPDFPageObj_GetMatrix(object, &matrix) != 0,
              matrix.a == 1, matrix.b == 0, matrix.c == 0, matrix.d == 1,
              matrix.e == 0, matrix.f == 0,
              let clip = FPDFPageObj_GetClipPath(object) else { return original }
        let count = FPDFClipPath_CountPaths(clip)
        guard count > 0, count <= 64 else { return original }
        var result = original, total = 0
        for path in 0..<count {
            let segments = FPDFClipPath_CountPathSegments(clip, path)
            guard segments > 0, segments <= 8_192,
                  total <= 65_536 - Int(segments) else { return original }
            total += Int(segments)
            var minX = CGFloat.infinity, minY = CGFloat.infinity
            var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
            for index in 0..<segments {
                var x: Float = 0, y: Float = 0
                guard let segment = FPDFClipPath_GetPathSegment(clip, path, index),
                      FPDFPathSegment_GetPoint(segment, &x, &y) != 0,
                      x.isFinite, y.isFinite else { return original }
                minX = min(minX, CGFloat(x)); maxX = max(maxX, CGFloat(x))
                minY = min(minY, CGFloat(y)); maxY = max(maxY, CGFloat(y))
            }
            result = result.intersection(CGRect(x: minX, y: minY,
                width: maxX - minX, height: maxY - minY))
        }
        return result
    }

    /// PDFium may normalize unrelated graphics while removing OCR objects.
    /// Accept that serialization only when the complete visible page renders
    /// identically; no source artwork has been changed at this stage.
    static func preservesAppearance(of original: PDFPage, in cleaned: PDFPage) throws -> Bool {
        let box=original.bounds(for:.mediaBox)
        guard box == cleaned.bounds(for:.mediaBox),box.width>0,box.height>0,
              box.width*box.height<=8_000_000 else { throw Failure.unsupported }
        let scale=min(CGFloat(2),sqrt(8_000_000/(box.width*box.height)))
        let width=Int(ceil(box.width*scale)),height=Int(ceil(box.height*scale))
        func pixels(_ page:PDFPage)throws->Data {
            var data=Data(repeating:255,count:width*height*4)
            try data.withUnsafeMutableBytes {raw in
                guard let reference=page.pageRef,
                      let context=CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,
                        bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                        bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw Failure.unsupported}
                context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))
                context.scaleBy(x:scale,y:scale);context.drawPDFPage(reference)
            }
            return data
        }
        return try pixels(original) == pixels(cleaned)
    }

    static func replacementFits(_ page: FPDF_PAGE, source: Source, tolerance: CGFloat = 0.1) -> Bool {
        let mediaBox = CGRect(x: 0, y: 0, width: FPDF_GetPageWidth(page), height: FPDF_GetPageHeight(page))
        let objectCount = FPDFPage_CountObjects(page)
        guard objectCount > 0, objectCount <= 50_000 else { return false }
        var hasOutline = false
        for index in 0..<objectCount {
            guard let object = FPDFPage_GetObject(page, index) else { return false }
            switch FPDFPageObj_GetType(object) {
            case FPDF_PAGEOBJ_TEXT: break
            case FPDF_PAGEOBJ_PATH:
                guard let bounds = PDFOutlinedOCRArtwork.paintBounds(of: object, mediaBox: mediaBox),
                      !bounds.isEmpty, bounds.allSatisfy({ covered($0, by: source.erasedRects, tolerance: tolerance) }) else { return false }
                hasOutline = true
            default: return false
            }
        }
        if source.semanticFontName != nil, !hasOutline { return false }
        guard let text = FPDFText_LoadPage(page) else { return false }
        defer { FPDFText_ClosePage(text) }
        for index in 0..<FPDFText_CountChars(text) {
            guard FPDFText_IsGenerated(text,index) == 0,
                  let scalar = UnicodeScalar(FPDFText_GetUnicode(text,index)),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
            var l=0.0,r=0.0,b=0.0,t=0.0
            guard FPDFText_GetCharBox(text,index,&l,&r,&b,&t) != 0 else { return false }
            guard [l,r,b,t].allSatisfy(\.isFinite) else { return false }
            let box=CGRect(x:l,y:b,width:r-l,height:t-b)
            if !box.isEmpty && !covered(box, by: source.erasedRects, tolerance: tolerance) { return false }
        }
        return true
    }

    /// The page program digest excludes Form payloads. Before replacing the
    /// whole current donor, independently bound every direct text child's ink
    /// in page coordinates; a moved or altered donor must not borrow old rows.
    static func currentTextFormFits(_ form: FPDF_PAGEOBJECT, on page: FPDF_PAGE,
                                    source: Source, independentlyUnclipped: Bool) throws -> Bool {
        try Task.checkCancellation()
        guard FPDFPageObj_GetType(form) == FPDF_PAGEOBJ_FORM else { return false }
        let count = Int(FPDFFormObj_CountObjects(form))
        var matrix = FS_MATRIX()
        guard count > 0, count <= 50_000,
              FPDFPageObj_GetMatrix(form, &matrix) != 0,
              [matrix.a, matrix.b, matrix.c, matrix.d, matrix.e, matrix.f].allSatisfy(\.isFinite),
              abs(matrix.a * matrix.d - matrix.b * matrix.c) > 0.000_000_001 else { return false }
        let transform = CGAffineTransform(a: CGFloat(matrix.a), b: CGFloat(matrix.b),
            c: CGFloat(matrix.c), d: CGFloat(matrix.d), tx: CGFloat(matrix.e), ty: CGFloat(matrix.f))
        var children = Set<FPDF_PAGEOBJECT>()
        for index in 0..<count {
            if index % 256 == 0 { try Task.checkCancellation() }
            guard let object = FPDFFormObj_GetObject(form, UInt(index)),
                  FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT,
                  FPDFTextObj_GetTextRenderMode(object) == FPDF_TEXTRENDERMODE_FILL,
                  FPDFPageObj_HasTransparency(object) == 0 else { return false }
            if let clip = FPDFPageObj_GetClipPath(object) {
                let paths = FPDFClipPath_CountPaths(clip)
                guard paths == 0 || (paths == -1 && independentlyUnclipped) else { return false }
            }
            var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
            guard FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top) != 0,
                  [left, bottom, right, top].allSatisfy(\.isFinite), right >= left, top >= bottom else { return false }
            let box = CGRect(x: CGFloat(left), y: CGFloat(bottom), width: CGFloat(right - left),
                             height: CGFloat(top - bottom)).applying(transform)
            guard [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite),
                  box.isEmpty || covered(box, by: source.erasedRects, tolerance: 0) else { return false }
            children.insert(object)
        }
        guard let text = FPDFText_LoadPage(page) else { return false }
        defer { FPDFText_ClosePage(text) }
        let characters = FPDFText_CountChars(text)
        guard characters > 0, characters <= 250_000 else { return false }
        var ink = false
        for index in 0..<characters {
            if index % 256 == 0 { try Task.checkCancellation() }
            guard let object = FPDFText_GetTextObject(text, index), children.contains(object),
                  FPDFText_IsGenerated(text, index) == 0,
                  let scalar = UnicodeScalar(FPDFText_GetUnicode(text, index)),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
            var left = 0.0, right = 0.0, bottom = 0.0, top = 0.0
            guard FPDFText_GetCharBox(text, index, &left, &right, &bottom, &top) != 0,
                  [left, right, bottom, top].allSatisfy(\.isFinite), right >= left, top >= bottom else { return false }
            let box = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
            guard box.isEmpty || covered(box, by: source.erasedRects, tolerance: 0) else { return false }
            ink = ink || !box.isEmpty
        }
        return ink
    }

    /// A descender can cross the boundary between two selected rows. Require
    /// its complete box to belong to the erasure union, including the short
    /// last row, rather than assigning it to one arbitrary row rectangle.
    private static func covered(_ bounds: CGRect, by rectangles: [CGRect], tolerance: CGFloat) -> Bool {
        var remaining = [bounds]
        let minimumPiece = tolerance == 0 ? CGFloat(0) : CGFloat(0.000001)
        for rectangle in rectangles {
            let cover = rectangle.insetBy(dx: -tolerance, dy: -tolerance)
            var next: [CGRect] = []
            for piece in remaining {
                let intersection = piece.intersection(cover)
                guard !intersection.isNull, !intersection.isEmpty else { next.append(piece); continue }
                for candidate in [
                    CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: intersection.minY-piece.minY),
                    CGRect(x: piece.minX, y: intersection.maxY, width: piece.width, height: piece.maxY-intersection.maxY),
                    CGRect(x: piece.minX, y: intersection.minY, width: intersection.minX-piece.minX, height: intersection.height),
                    CGRect(x: intersection.maxX, y: intersection.minY, width: piece.maxX-intersection.maxX, height: intersection.height)
                ] where candidate.width > minimumPiece && candidate.height > minimumPiece {
                    next.append(candidate)
                }
            }
            remaining = next
            if remaining.isEmpty { return true }
            guard remaining.count <= 256 else { return false }
        }
        return remaining.isEmpty
    }

    /// Preserve the original OCR content sequence. Painting is clipped at each
    /// image call so replacement text can occupy the removed show's position.
    static func clippedContent(_ content: Data, source: Source, mediaBox: CGRect,
                               donorName: String?) throws -> Data {
        try PDFScannedReadOrderContent.render(content, erasedRects: source.erasedRects,
            mediaBox: mediaBox, paperColor: source.paperColor,
            insertionOffset: source.firstRemovedShowOffset, donorName: donorName,
            preservedFormNames: source.preservedFormNames,
            clipDonorToErasure: source.semanticFontName == nil || source.semanticEncoding == nil)
    }
    private static func matchingRange(_ selected:String,in text:String,within range:NSRange)->NSRange? {
        let source=text as NSString
        let direct=source.range(of:selected,options:[],range:range)
        if direct.location != NSNotFound {return direct}
        var scalars:[UnicodeScalar]=[],ranges:[NSRange]=[],offset=0
        for character in text {
            let string=String(character),length=string.utf16.count
            if !string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                for scalar in string.unicodeScalars {scalars.append(scalar);ranges.append(NSRange(location:offset,length:length))}
            }
            offset+=length
        }
        let needle=Array(selected.unicodeScalars.filter {!CharacterSet.whitespacesAndNewlines.contains($0)})
        guard !needle.isEmpty,needle.count<=scalars.count else{return nil}
        for start in 0...(scalars.count-needle.count) where Array(scalars[start..<start+needle.count])==needle {
            let candidate = NSRange(location:ranges[start].location,length:NSMaxRange(ranges[start+needle.count-1])-ranges[start].location)
            if candidate.location >= range.location && NSMaxRange(candidate) <= NSMaxRange(range) { return candidate }
        }
        return nil
    }
    private struct Paper {let color:PDFTextColor;let ink:PDFTextColor;let rects:[CGRect];let inkHeights:[CGFloat];let inkBounds:[CGRect]}
    private static func inspectPaper(on page:PDFPage,rects:[CGRect],glyphMasks:[CGRect],hyphenMasks:[CGRect],protectedRects:[CGRect],fontSize:CGFloat)throws->Paper {
        let horizontalPadding=max(1.5,fontSize*0.55),verticalPadding=max(1.5,fontSize*0.18)
        let mediaBox=page.bounds(for:.mediaBox)
        let nominalRegion=rects.reduce(CGRect.null){$0.union($1)}.insetBy(dx:-horizontalPadding-0.5,dy:-verticalPadding-0.5)
            .intersection(mediaBox)
        // Inspect more vertical space only to finish ink connected to the
        // original OCR cells. This does not enlarge the default erasure.
        let verticalInspectionPadding=max(verticalPadding,fontSize*0.5)
        let extra=ceil(verticalInspectionPadding-verticalPadding)
        let below=max(0,min(extra,floor(nominalRegion.minY-mediaBox.minY)))
        let above=max(0,min(extra,floor(mediaBox.maxY-nominalRegion.maxY)))
        // Whole-point offsets preserve the existing 2x raster phase and the
        // every-other-pixel paper samples. New margin pixels do not estimate paper.
        let region=CGRect(x:nominalRegion.minX,y:nominalRegion.minY-below,
            width:nominalRegion.width,height:nominalRegion.height+below+above)
        let protectedRects=protectedRects.filter { $0.intersects(region) }
        let scale:CGFloat=2,width=Int(ceil(region.width*scale)),height=Int(ceil(region.height*scale))
        guard width>0,height>0,width*height<=12_000_000,let reference=page.pageRef else{throw Failure.unsupported}
        var pixels=[UInt8](repeating:255,count:width*height*4)
        try pixels.withUnsafeMutableBytes {raw in
            guard let context=CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{throw Failure.unsupported}
            context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:width,height:height))
            context.scaleBy(x:scale,y:scale);context.translateBy(x:-region.minX,y:-region.minY);context.drawPDFPage(reference)
        }
        // A value contains its channels inline; sampling a pixel does not
        // allocate a separate Swift Array. All thresholds remain integer-exact.
        struct RGB {
            let red: UInt8
            let green: UInt8
            let blue: UInt8
            var intensity: Int { Int(red) + Int(green) + Int(blue) }
        }
        func rgb(_ x:Int,_ y:Int)->RGB {
            let i=((height-y-1)*width+x)*4
            return RGB(red:pixels[i],green:pixels[i+1],blue:pixels[i+2])
        }
        // Include a raster pixel only when its center belongs to the PDF
        // rectangle. Inclusive rounded edges sampled neighboring text rows.
        func box(_ r:CGRect)->(Int,Int,Int,Int){(max(0,Int(ceil((r.minX-region.minX)*scale-0.5))),min(width-1,Int(ceil((r.maxX-region.minX)*scale-0.5))-1),max(0,Int(ceil((r.minY-region.minY)*scale-0.5))),min(height-1,Int(ceil((r.maxY-region.minY)*scale-0.5))-1))}
        // The modal color, not assumed white, identifies plain colored paper.
        let sampleBottom=Int(below*scale),sampleHeight=Int(ceil(nominalRegion.height*scale))
        var bins:[Int:Int]=[:]
        for y in stride(from:sampleBottom,to:sampleBottom+sampleHeight,by:2){for x in stride(from:0,to:width,by:2){let c=rgb(x,y);let key=(Int(c.red)/8)<<10 | (Int(c.green)/8)<<5 | Int(c.blue)/8;bins[key,default:0]+=1}}
        guard let key=bins.max(by:{$0.value<$1.value})?.key else{throw Failure.unsupported}
        let coarse=[((key>>10)&31)*8+4,((key>>5)&31)*8+4,(key&31)*8+4]
        var sums=[0,0,0],count=0,inkSamples:[RGB]=[]
        func near(_ c:RGB,_ reference:[Int],tolerance:Int)->Bool{abs(Int(c.red)-reference[0])<=tolerance && abs(Int(c.green)-reference[1])<=tolerance && abs(Int(c.blue)-reference[2])<=tolerance}
        for y in stride(from:sampleBottom,to:sampleBottom+sampleHeight,by:2){for x in stride(from:0,to:width,by:2){let c=rgb(x,y);if near(c,coarse,tolerance:12){sums[0]+=Int(c.red);sums[1]+=Int(c.green);sums[2]+=Int(c.blue);count+=1}else if c.intensity<coarse.reduce(0,+)-120{inkSamples.append(c)}}}
        guard count>max(1,width*sampleHeight/10),coarse.min()!>70 else{throw Failure.unsupported}
        let background=sums.map{$0/count}
        inkSamples.sort{$0.intensity<$1.intensity}
        let ink=inkSamples.isEmpty ? RGB(red:0,green:0,blue:0) : inkSamples[inkSamples.count/5]
        let inkThreshold=(background.reduce(0,+)+ink.intensity)/2
        // Rasterize the bounded glyph-cell mask once. Testing every dark
        // pixel against every glyph would be quadratic for long selections.
        var glyphMask=[UInt8](repeating:0,count:width*height)
        var expandedMask=glyphMask
        var connectedSearchMask=glyphMask
        for glyph in glyphMasks {
            // Synthetic OCR cells can end before the last printed glyph.
            // Allow at most half an em of horizontal recognition error;
            // unexplained artwork between cells still fails the ink check.
            let expanded=glyph.insetBy(dx:-max(1.25,fontSize*0.5),dy:-verticalPadding)
            let left=max(0,Int(ceil((expanded.minX-region.minX)*scale-0.5)))
            let right=min(width-1,Int(ceil((expanded.maxX-region.minX)*scale-0.5))-1)
            let bottom=max(0,Int(ceil((expanded.minY-region.minY)*scale-0.5)))
            let top=min(height-1,Int(ceil((expanded.maxY-region.minY)*scale-0.5))-1)
            guard right>=left,top>=bottom else{continue}
            for y in bottom...top { for x in left...right { expandedMask[y*width+x]=1 } }
            let connected=glyph.insetBy(dx:-max(1.25,fontSize*0.5),dy:-verticalInspectionPadding)
            let (connectedLeft,connectedRight,connectedBottom,connectedTop)=box(connected)
            if connectedRight>=connectedLeft,connectedTop>=connectedBottom {
                for y in connectedBottom...connectedTop {
                    for x in connectedLeft...connectedRight {connectedSearchMask[y*width+x]=1}
                }
            }
            let core=glyph.insetBy(dx:-max(1.5,fontSize*0.1),dy:-verticalPadding)
            let (coreLeft,coreRight,coreBottom,coreTop)=box(core)
            guard coreRight>=coreLeft,coreTop>=coreBottom else{continue}
            for y in coreBottom...coreTop {for x in coreLeft...coreRight {glyphMask[y*width+x]=1}}
        }
        // A printed hyphen is detached from its neighboring letter. PDFium's
        // independent hyphen flag proves that this narrow OCR cell expects a
        // separate mark, so it may seed the same bounded recognition margin.
        for hyphen in hyphenMasks {
            let expanded=hyphen.insetBy(dx:-max(1.25,fontSize*0.5),dy:-verticalPadding)
            let (left,right,bottom,top)=box(expanded)
            guard right>=left,top>=bottom else{continue}
            for y in bottom...top {for x in left...right {glyphMask[y*width+x]=1}}
        }
        // The extra tolerance may recover only ink connected to an original
        // glyph cell. A detached illustration or mark in the new margin is
        // still unexplained; widening a rectangle must not silently erase it.
        var frontier:[UInt32]=[]
        for y in 0..<height {for x in 0..<width {
            if glyphMask[y*width+x] != 0,!near(rgb(x,y),background,tolerance:18) {
                frontier.append(UInt32(y*width+x))
                connectedSearchMask[y*width+x] |= 2
            }
        }}
        var cursor=0
        while cursor<frontier.count {
            let index=Int(frontier[cursor]),x=index%width,y=index/width
            cursor+=1
            // One empty raster pixel can split an antialiased thin stroke.
            // Bridge only that half-point gap; the half-em outer limit and
            // the unexplained-artwork budget still apply.
            for nextY in max(0,y-2)...min(height-1,y+2) {
                for nextX in max(0,x-2)...min(width-1,x+2) {
                    guard abs(nextY-y)+abs(nextX-x)<=2 else{continue}
                    let next=nextY*width+nextX
                    // Outside the old recognition window require directly
                    // touching pixels; never bridge a paper gap to a neighbor.
                    let directlyConnected=abs(nextY-y)<=1 && abs(nextX-x)<=1
                    if glyphMask[next]==0,connectedSearchMask[next] & 1 != 0,
                       (expandedMask[next] != 0 || directlyConnected),
                       !near(rgb(nextX,nextY),background,tolerance:18) {
                        glyphMask[next]=1
                        connectedSearchMask[next] |= 2
                        frontier.append(UInt32(next))
                    }
                }
            }
        }
        // A final narrow stem (for example t or the right side of n) may be
        // completely outside a synthetic OCR cell. Admit only a thin, tall
        // stroke inside the bounded margin; a square mark or photograph must
        // not become explained merely because it is near recognized text.
        for index in expandedMask.indices where expandedMask[index]==1 && glyphMask[index]==0 {
            let x=index%width,y=index/width
            guard !near(rgb(x,y),background,tolerance:18) else{continue}
            var component=[UInt32(index)],head=0,minX=x,maxX=x,minY=y,maxY=y
            expandedMask[index]=2
            while head<component.count {
                let point=Int(component[head]),px=point%width,py=point/width
                head+=1
                minX=min(minX,px);maxX=max(maxX,px);minY=min(minY,py);maxY=max(maxY,py)
                for nextY in max(0,py-1)...min(height-1,py+1) {
                    for nextX in max(0,px-1)...min(width-1,px+1) {
                        let next=nextY*width+nextX
                        if expandedMask[next]==1,glyphMask[next]==0,
                           !near(rgb(nextX,nextY),background,tolerance:18) {
                            expandedMask[next]=2;component.append(UInt32(next))
                        }
                    }
                }
            }
            let strokeWidth=CGFloat(maxX-minX+1)/scale,strokeHeight=CGFloat(maxY-minY+1)/scale
            if strokeWidth<=fontSize*0.25,(fontSize*0.3...fontSize*1.25).contains(strokeHeight),
               strokeHeight>=strokeWidth*2.5 {
                for point in component {glyphMask[Int(point)]=1}
            }
        }
        var erased:[CGRect]=[],inkHeights:[CGFloat]=[],inkBounds:[CGRect]=[]
        for original in rects {
            var accepted:CGRect?
            // Keep horizontal OCR tolerance independent of row leading. A
            // tight paragraph's adjacent erasures must never overlap (the
            // save path uses an even-odd clipping rule).
            do {
                var minX=original.minX-horizontalPadding,maxX=original.maxX+horizontalPadding
                var minY=original.minY-verticalPadding,maxY=original.maxY+verticalPadding
                var inspectionMinY=original.minY-verticalInspectionPadding
                var inspectionMaxY=original.maxY+verticalInspectionPadding
                for other in rects.filter({$0 != original}) + protectedRects {
                    if other.maxX>original.minX && other.minX<original.maxX {
                        if other.minY>=original.maxY {
                            let boundary=(original.maxY+other.minY)/2
                            maxY=min(maxY,boundary);inspectionMaxY=min(inspectionMaxY,boundary)
                        } else if other.maxY<=original.minY {
                            let boundary=(original.minY+other.maxY)/2
                            minY=max(minY,boundary);inspectionMinY=max(inspectionMinY,boundary)
                        }
                    }
                    if other.maxY>original.minY && other.minY<original.maxY {
                        if other.minX>=original.maxX {maxX=min(maxX,(original.maxX+other.minX)/2)}
                        else if other.maxX<=original.minX {minX=max(minX,(original.minX+other.maxX)/2)}
                    }
                }
                let allowed=CGRect(x:minX,y:minY,width:maxX-minX,height:maxY-minY)
                    .intersection(page.bounds(for:.mediaBox))
                minY=allowed.minY;maxY=allowed.maxY
                let inspection=CGRect(x:allowed.minX,y:inspectionMinY,width:allowed.width,
                    height:inspectionMaxY-inspectionMinY).intersection(region).intersection(mediaBox)
                let (allowedLeft,allowedRight,allowedBottom,allowedTop)=box(inspection)
                guard allowedRight>=allowedLeft,allowedTop>=allowedBottom else{throw Failure.unsupported}
                var inkLeft=allowedRight,inkRight=allowedLeft,foundInk=false
                var connectedBottom=allowedTop,connectedTop=allowedBottom,foundConnected=false,unclosedConnected=false,crossesVerticalLimit=false
                for y in allowedBottom...allowedTop {for x in allowedLeft...allowedRight {
                    if glyphMask[y*width+x] != 0,!near(rgb(x,y),background,tolerance:18) {
                        inkLeft=min(inkLeft,x);inkRight=max(inkRight,x)
                        foundInk=true
                        if connectedSearchMask[y*width+x] & 2 != 0 {
                            connectedBottom=min(connectedBottom,y);connectedTop=max(connectedTop,y);foundConnected=true
                            if y-allowedBottom<2 || allowedTop-y<2 {
                                for ny in max(0,y-2)...min(height-1,y+2) where ny<allowedBottom || ny>allowedTop {
                                    for nx in max(0,x-2)...min(width-1,x+2) where abs(ny-y)+abs(nx-x)<=2 {
                                        if connectedSearchMask[ny*width+nx] & 2 != 0,
                                           !near(rgb(nx,ny),background,tolerance:18) {crossesVerticalLimit=true}
                                    }
                                }
                            }
                            if expandedMask[y*width+x]==0 {
                                // The per-glyph search mask can end before the
                                // row window. Check its actual raster boundary too.
                                for ny in (y-1)...(y+1) {for nx in (x-1)...(x+1) {
                                    if nx<0 || nx>=width || ny<0 || ny>=height {unclosedConnected=true;continue}
                                    if connectedSearchMask[ny*width+nx] & 1 == 0,
                                       !near(rgb(nx,ny),background,tolerance:18) {unclosedConnected=true}
                                }}
                            }
                        }
                    }
                }}
                guard !crossesVerticalLimit,!unclosedConnected else {throw Failure.unsupported}
                // The recognition margin is an inspection limit, not an
                // instruction to repaint half an em of accurate paper. Keep
                // the usual 1.5pt erasure unless observed ink needs more.
                if foundInk {
                    minX=max(allowed.minX,min(original.minX-1.5,region.minX+CGFloat(inkLeft)/scale-0.5))
                    maxX=min(allowed.maxX,max(original.maxX+1.5,region.minX+CGFloat(inkRight+1)/scale+0.5))
                    let observedBottom=region.minY+CGFloat(connectedBottom)/scale
                    let observedTop=region.minY+CGFloat(connectedTop+1)/scale
                    if foundConnected && (observedBottom<allowed.minY || observedTop>allowed.maxY) {
                        // The read halo above already rejects an open component
                        // or ink crossing the inspection/neighbor boundary. Its
                        // complete raster cells must also fit inside that bound;
                        // spare paper rows are not additional erasure authority.
                        guard !unclosedConnected,observedBottom>=inspection.minY,
                              observedTop<=inspection.maxY else {throw Failure.unsupported}
                        minY=max(inspection.minY,min(allowed.minY,observedBottom-0.5))
                        maxY=min(inspection.maxY,max(allowed.maxY,observedTop+0.5))
                    }
                }
                let candidate=CGRect(x:minX,y:minY,width:maxX-minX,height:maxY-minY)
                guard !candidate.isEmpty,!protectedRects.contains(where:{$0.intersects(candidate)}) else {throw Failure.unsupported}
                let (left,right,bottom,top)=box(candidate)
                guard right>=left,top>=bottom else {throw Failure.unsupported}
                var edge=0,plain=0,interior=0,interiorPlain=0,unexplainedInk=0
                var inkRows=[Int](repeating:0,count:top-bottom+1)
                for y in bottom...top {for x in left...right {
                    let c=rgb(x,y),isPlain=near(c,background,tolerance:18)
                    if x-left<2||right-x<2||y-bottom<2||top-y<2 {edge+=1;if isPlain{plain+=1}}
                    interior+=1;if isPlain{interiorPlain+=1}
                    if !isPlain {
                        if c.intensity<=inkThreshold && glyphMask[y*width+x] != 0 {inkRows[y-bottom]+=1}
                        if glyphMask[y*width+x]==0 { unexplainedInk+=1 }
                    }
                }}
                // Permit at most two square page points of scanner dust;
                // an illustration in a word gap is far larger than this.
                if unexplainedInk<=8,edge>0,Double(plain)/Double(edge)>0.94,Double(interiorPlain)/Double(max(1,interior))>0.55 {
                    let threshold=max(2,(right-left)/200)
                    guard let firstInk=inkRows.firstIndex(where:{$0>=threshold}),
                          let lastInk=inkRows.lastIndex(where:{$0>=threshold}) else{throw Failure.unsupported}
                    let inkHeight=CGFloat(lastInk-firstInk+1)/scale
                    inkHeights.append(inkHeight)
                    inkBounds.append(CGRect(x:original.minX,y:region.minY+CGFloat(bottom+firstInk)/scale,
                        width:original.width,height:inkHeight))
                    accepted=candidate
                }
            }
            guard let accepted,erased.allSatisfy({!$0.intersects(accepted)})else{throw Failure.unsupported}
            erased.append(accepted)
        }
        return Paper(color:PDFTextColor(red:CGFloat(background[0])/255,green:CGFloat(background[1])/255,blue:CGFloat(background[2])/255,alpha:1),
            ink:PDFTextColor(red:CGFloat(ink.red)/255,green:CGFloat(ink.green)/255,blue:CGFloat(ink.blue)/255,alpha:1),rects:erased,inkHeights:inkHeights,inkBounds:inkBounds)
    }
}
