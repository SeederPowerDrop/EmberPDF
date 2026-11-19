// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import CPDFium

/// Measures only a fresh, text-only donor made by textPDFRendering. This does
/// not admit an input Form, grant erasure authority, or change an erasure row.
/// One translation preserves the entire source baseline grid. It is selected
/// before presenting the draft, so preview and committed text share an anchor.
@MainActor
enum PDFScannedInkPlacement {
    static let scale: CGFloat = 2
    private static let maximumShapes = 65_536
    private static let maximumWork = 8_000_000

    struct Measurement {
        let geometry: [CGRect]
        /// Complete nonzero-alpha cell footprints, one enclosing span per row.
        let paintedRows: [CGRect]
    }

    static func baselineAdjustment(donor: Data, erasedRects: [CGRect], sourceInkRows: [CGRect]) throws -> CGFloat? {
        let value = try measure(donor)
        guard !sourceInkRows.isEmpty, sourceInkRows.count <= 64,
              sourceInkRows.allSatisfy(valid), let available = try corridor(value, erasedRects: erasedRects) else { return nil }
        // A row must remain beside its measured original ink. This prevents a
        // feasible interval on a different line from becoming a new baseline.
        // The constraint is derived from the source bands, not a point margin.
        var groups = [CGRect](repeating: .null, count: sourceInkRows.count)
        var work = 0
        for row in value.paintedRows {
            work += sourceInkRows.count
            guard work <= maximumWork else { return nil }
            let distances = sourceInkRows.map { abs($0.midY-row.midY) }
            guard let distance = distances.min(),
                  let index = distances.firstIndex(of: distance),
                  distances.filter({ $0 == distance }).count == 1 else { return nil }
            groups[index] = groups[index].union(row)
        }
        var near = -CGFloat.infinity...CGFloat.infinity
        for (ink, group) in zip(sourceInkRows, groups) {
            guard !group.isNull else { return nil }
            let lower = max(near.lowerBound, ink.minY-group.midY)
            let upper = min(near.upperBound, ink.maxY-group.midY)
            guard lower <= upper else { return nil }
            near = lower...upper
        }
        var chosen: CGFloat?
        for interval in available {
            let lower = ceil(max(interval.lowerBound, near.lowerBound)*scale)
            let upper = floor(min(interval.upperBound, near.upperBound)*scale)
            guard lower <= upper else { continue }
            // Whole raster-cell translations preserve the measurement phase.
            // There is no fixed shift: an already contained donor chooses 0.
            let candidate = min(max(CGFloat(0), lower), upper)/scale
            if chosen == nil || abs(candidate) < abs(chosen!) ||
                (abs(candidate) == abs(chosen!) && candidate < chosen!) { chosen = candidate }
        }
        return chosen
    }

    static func fits(_ donor: Data, erasedRects: [CGRect]) throws -> Bool {
        guard let intervals = try corridor(measure(donor), erasedRects: erasedRects) else { return false }
        return intervals.contains { $0.contains(0) }
    }

    /// Exact interval intersection; no tolerance, enlarged mask, or font-size
    /// change. Partition X at rectangle edges so touching erasures may cover
    /// one complete glyph, while a real hole or short row remains protected.
    static func corridor(_ value: Measurement, erasedRects: [CGRect]) throws -> [ClosedRange<CGFloat>]? {
        guard !erasedRects.isEmpty, erasedRects.count <= 64,
              erasedRects.allSatisfy(valid), !value.geometry.isEmpty, !value.paintedRows.isEmpty,
              value.geometry.count <= maximumShapes, value.paintedRows.count <= maximumShapes else { return nil }
        var result = [-CGFloat.infinity...CGFloat.infinity]
        var work = 0
        for (index, shape) in (value.geometry + value.paintedRows).enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            guard valid(shape) else { return nil }
            let edges = Array(Set([shape.minX,shape.maxX] + erasedRects.flatMap {
                [$0.minX,$0.maxX].filter { $0 > shape.minX && $0 < shape.maxX }
            })).sorted()
            var allowed = [-CGFloat.infinity...CGFloat.infinity]
            for (left,right) in zip(edges,edges.dropFirst()) {
                work += erasedRects.count+allowed.count
                guard work <= maximumWork else { return nil }
                let bands = merge(erasedRects.compactMap { rectangle -> ClosedRange<CGFloat>? in
                    guard rectangle.minX <= left,rectangle.maxX >= right else { return nil }
                    return rectangle.minY...rectangle.maxY
                })
                let offsets = bands.compactMap { band -> ClosedRange<CGFloat>? in
                    let lower = band.lowerBound-shape.minY,upper = band.upperBound-shape.maxY
                    return lower <= upper ? lower...upper : nil
                }
                allowed = intersect(allowed,offsets)
                if allowed.isEmpty { return nil }
            }
            guard !allowed.isEmpty else { return nil }
            let next = intersect(result,allowed)
            guard !next.isEmpty else { return nil }
            result = next
        }
        return result
    }

    private static func intersect(_ lhs: [ClosedRange<CGFloat>], _ rhs: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        var result: [ClosedRange<CGFloat>] = [],left = 0,right = 0
        while left < lhs.count && right < rhs.count {
            let lower = max(lhs[left].lowerBound,rhs[right].lowerBound)
            let upper = min(lhs[left].upperBound,rhs[right].upperBound)
            if lower <= upper { result.append(lower...upper) }
            if lhs[left].upperBound < rhs[right].upperBound { left += 1 } else { right += 1 }
        }
        return result
    }

    private static func merge(_ values: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        var result: [ClosedRange<CGFloat>] = []
        for value in values.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, value.lowerBound <= last.upperBound {
                result[result.count-1] = last.lowerBound...max(last.upperBound, value.upperBound)
            } else { result.append(value) }
        }
        return result
    }

    private static func valid(_ box: CGRect) -> Bool {
        !box.isNull && !box.isEmpty && [box.minX,box.minY,box.maxX,box.maxY].allSatisfy {
            $0.isFinite && abs($0) <= 1_000_000
        }
    }

    /// Both readers borrow the same immutable donor buffer. Nothing escapes a
    /// native document lifetime; only bounded rectangles and raster cells do.
    static func measure(_ data: Data) throws -> Measurement {
        guard !data.isEmpty, data.count <= 64*1_024*1_024 else {
            throw PDFScannedBodyTextEditor.Failure.doesNotFit
        }
        let geometry: [CGRect] = try data.withUnsafeBytes { bytes in
            guard let document = FPDF_LoadMemDocument64(bytes.baseAddress, data.count, nil) else {
                throw PDFScannedBodyTextEditor.Failure.doesNotFit
            }
            defer { FPDF_CloseDocument(document) }
            guard FPDF_GetPageCount(document) == 1, let page = FPDF_LoadPage(document, 0) else {
                throw PDFScannedBodyTextEditor.Failure.doesNotFit
            }
            defer { FPDF_ClosePage(page) }
            let count = FPDFPage_CountObjects(page)
            guard count > 0, count <= 50_000 else { throw PDFScannedBodyTextEditor.Failure.doesNotFit }
            var boxes: [CGRect] = []
            for index in 0..<count {
                if index % 256 == 0 { try Task.checkCancellation() }
                guard let object = FPDFPage_GetObject(page,index),
                      FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT,
                      FPDFTextObj_GetTextRenderMode(object) == FPDF_TEXTRENDERMODE_FILL,
                      FPDFPageObj_HasTransparency(object) == 0 else { throw PDFScannedBodyTextEditor.Failure.doesNotFit }
                var l: Float=0,b: Float=0,r: Float=0,t: Float=0
                guard FPDFPageObj_GetBounds(object,&l,&b,&r,&t) != 0,
                      [l,b,r,t].allSatisfy(\.isFinite),r >= l,t >= b else { throw PDFScannedBodyTextEditor.Failure.doesNotFit }
                let box = CGRect(x:CGFloat(l),y:CGFloat(b),width:CGFloat(r-l),height:CGFloat(t-b))
                if !box.isEmpty { boxes.append(box) }
            }
            guard let text = FPDFText_LoadPage(page) else { throw PDFScannedBodyTextEditor.Failure.doesNotFit }
            defer { FPDFText_ClosePage(text) }
            let characters = FPDFText_CountChars(text)
            guard characters > 0,characters <= 250_000 else { throw PDFScannedBodyTextEditor.Failure.doesNotFit }
            for index in 0..<characters {
                if index % 256 == 0 { try Task.checkCancellation() }
                guard FPDFText_IsGenerated(text,index) == 0,
                      let scalar = UnicodeScalar(FPDFText_GetUnicode(text,index)),
                      !CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
                var l=0.0,r=0.0,b=0.0,t=0.0
                guard FPDFText_GetCharBox(text,index,&l,&r,&b,&t) != 0,
                      [l,r,b,t].allSatisfy(\.isFinite),r >= l,t >= b else { throw PDFScannedBodyTextEditor.Failure.doesNotFit }
                let box = CGRect(x:l,y:b,width:r-l,height:t-b)
                if !box.isEmpty { boxes.append(box) }
                guard boxes.count <= maximumShapes else { throw PDFScannedBodyTextEditor.Failure.doesNotFit }
            }
            guard !boxes.isEmpty,boxes.allSatisfy(valid) else { throw PDFScannedBodyTextEditor.Failure.doesNotFit }
            return boxes
        }
        let bounds = geometry.reduce(CGRect.null) { $0.union($1) }
        // Two 2x cells are a read halo, never permission to paint. An occupied
        // outer edge refuses this measurement instead of cropping its support.
        let region = CGRect(x:floor(bounds.minX*scale)/scale-1,y:floor(bounds.minY*scale)/scale-1,
            width:(ceil(bounds.maxX*scale)-floor(bounds.minX*scale))/scale+2,
            height:(ceil(bounds.maxY*scale)-floor(bounds.minY*scale))/scale+2)
        guard valid(region) else { throw PDFScannedBodyTextEditor.Failure.doesNotFit }
        let width = Int((region.width*scale).rounded()),height = Int((region.height*scale).rounded())
        guard width > 2,height > 2,width <= 32_768,height <= 32_768,
              width <= 12_000_000/height else { throw PDFScannedBodyTextEditor.Failure.doesNotFit }
        guard let provider = CGDataProvider(data:data as CFData),let document = CGPDFDocument(provider),
              document.numberOfPages == 1,let page = document.page(at:1) else {
            throw PDFScannedBodyTextEditor.Failure.doesNotFit
        }
        var pixels = Data(repeating:0,count:width*height*4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data:bytes.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PDFScannedBodyTextEditor.Failure.doesNotFit }
            context.scaleBy(x:scale,y:scale);context.translateBy(x:-region.minX,y:-region.minY)
            context.drawPDFPage(page)
        }
        var rows: [CGRect] = []
        for y in 0..<height {
            if y % 64 == 0 { try Task.checkCancellation() }
            var left = width,right = -1
            for x in 0..<width where pixels[((height-y-1)*width+x)*4+3] != 0 {
                guard x > 0,x+1 < width,y > 0,y+1 < height else { throw PDFScannedBodyTextEditor.Failure.doesNotFit }
                left = min(left,x);right = max(right,x)
            }
            if right >= left {
                rows.append(CGRect(x:region.minX+CGFloat(left)/scale,y:region.minY+CGFloat(y)/scale,
                    width:CGFloat(right-left+1)/scale,height:1/scale))
            }
        }
        guard !rows.isEmpty,rows.count <= maximumShapes else { throw PDFScannedBodyTextEditor.Failure.doesNotFit }
        return Measurement(geometry:geometry,paintedRows:rows)
    }
}
