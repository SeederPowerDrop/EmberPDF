// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import CPDFium
import Foundation

/// PDFKit uses painted path bounds while clustering hidden OCR text. Our
/// outlines therefore clip glyphs and fill a media-sized rectangle. Accept
/// only that exact paint shape; report the bounded clip rather than its large
/// nominal rectangle. This never relaxes ordinary PDF editing's clip guards.
@MainActor
enum PDFOutlinedOCRArtwork {
    struct Inspection {
        let bounds: [CGRect]
        let textObjects: Set<FPDF_PAGEOBJECT>
        let transform: CGAffineTransform
    }

    static func paintBounds(of object: FPDF_PAGEOBJECT, mediaBox: CGRect) -> [CGRect]? {
        var segmentBudget = 2_000_000, comparisonBudget = 2_000_000
        return paintBounds(of: object, mediaBox: mediaBox,
                           segmentBudget: &segmentBudget, comparisonBudget: &comparisonBudget)
    }

    private static func paintBounds(of object: FPDF_PAGEOBJECT, mediaBox: CGRect,
                                    segmentBudget: inout Int, comparisonBudget: inout Int) -> [CGRect]? {
        guard FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_PATH,
              FPDFPageObj_HasTransparency(object) == 0, let transform = matrix(object),
              let clip = FPDFPageObj_GetClipPath(object) else { return nil }
        var fill: Int32 = 0, stroke: Int32 = 0
        var red: UInt32 = 0, green: UInt32 = 0, blue: UInt32 = 0, alpha: UInt32 = 0
        guard FPDFPath_GetDrawMode(object, &fill, &stroke) != 0,
              [FPDF_FILLMODE_ALTERNATE, FPDF_FILLMODE_WINDING].contains(fill), stroke == 0,
              FPDFPageObj_GetFillColor(object, &red, &green, &blue, &alpha) != 0, alpha == 255,
              isMediaRectangle(object, transform: transform, media: mediaBox) else { return nil }
        let paths = Int(FPDFClipPath_CountPaths(clip))
        guard paths > 0, paths <= 8 else { return nil }
        var result = [mediaBox]
        for path in 0..<paths {
            let count = Int(FPDFClipPath_CountPathSegments(clip, Int32(path)))
            guard count > 0, count <= segmentBudget else { return nil }
            segmentBudget -= count
            var contours: [CGRect] = [], current = CGRect.null
            func finish() {
                if !current.isNull, current.width > 0, current.height > 0 { contours.append(current) }
                current = .null
            }
            for index in 0..<count {
                guard let segment = FPDFClipPath_GetPathSegment(clip, Int32(path), Int32(index)) else { return nil }
                let kind = FPDFPathSegment_GetType(segment)
                guard [FPDF_SEGMENT_MOVETO, FPDF_SEGMENT_LINETO, FPDF_SEGMENT_BEZIERTO].contains(kind) else { return nil }
                if kind == FPDF_SEGMENT_MOVETO { finish() }
                else if current.isNull { return nil }
                var x: Float = 0, y: Float = 0
                guard FPDFPathSegment_GetPoint(segment, &x, &y) != 0,
                      x.isFinite, y.isFinite, abs(x) <= 1_000_000, abs(y) <= 1_000_000 else { return nil }
                current = current.union(CGRect(x: CGFloat(x), y: CGFloat(y), width: 0.000001, height: 0.000001))
                if FPDFPathSegment_GetClose(segment) != 0 { finish() }
                guard contours.count <= 32_768 else { return nil }
            }
            finish()
            guard !contours.isEmpty, contours.count <= 32_768 else { return nil }
            var intersections: [CGRect] = []
            for previous in result {
                for contour in contours {
                    guard comparisonBudget > 0 else { return nil }
                    comparisonBudget -= 1
                    let cut = previous.intersection(contour)
                    if !cut.isNull, !cut.isEmpty { intersections.append(cut) }
                    guard intersections.count <= 32_768 else { return nil }
                }
            }
            result = intersections
            if result.isEmpty { return [] }
        }
        return result
    }

    static func effectiveBounds(of form: FPDF_PAGEOBJECT, metadata: PDFOutlinedOCRMetadata,
                                mediaBox: CGRect) -> [CGRect]? {
        inspect(form, metadata: metadata, mediaBox: mediaBox)?.bounds
    }

    static func inspect(_ form: FPDF_PAGEOBJECT, metadata: PDFOutlinedOCRMetadata,
                        mediaBox: CGRect) -> Inspection? {
        guard FPDFPageObj_GetType(form) == FPDF_PAGEOBJ_FORM, FPDFPageObj_HasTransparency(form) == 0,
              !hasClip(form), let transform = matrix(form) else { return nil }
        let count = Int(FPDFFormObj_CountObjects(form))
        guard count > 0, count <= 50_000 else { return nil }
        let localMedia = mediaBox.applying(transform.inverted())
        let colors = [metadata.style.textColor] + metadata.sourceRuns.map { $0.style.textColor }
        var bounds: [CGRect] = [], texts = Set<FPDF_PAGEOBJECT>(), pathCount = 0
        var segmentBudget = 2_000_000, comparisonBudget = 2_000_000
        for index in 0..<count {
            guard let child = FPDFFormObj_GetObject(form, UInt(index)), FPDFPageObj_HasTransparency(child) == 0 else { return nil }
            switch FPDFPageObj_GetType(child) {
            case FPDF_PAGEOBJ_TEXT:
                guard !hasClip(child), FPDFTextObj_GetTextRenderMode(child) == FPDF_TEXTRENDERMODE_INVISIBLE else { return nil }
                texts.insert(child)
            case FPDF_PAGEOBJ_PATH:
                guard let effective = paintBounds(of: child, mediaBox: localMedia,
                    segmentBudget: &segmentBudget, comparisonBudget: &comparisonBudget) else { return nil }
                var red: UInt32 = 0, green: UInt32 = 0, blue: UInt32 = 0, alpha: UInt32 = 0
                guard FPDFPageObj_GetFillColor(child, &red, &green, &blue, &alpha) != 0,
                      colors.contains(where: { abs(CGFloat(red) / 255 - $0.red) <= 1.0 / 255
                          && abs(CGFloat(green) / 255 - $0.green) <= 1.0 / 255
                          && abs(CGFloat(blue) / 255 - $0.blue) <= 1.0 / 255 }) else { return nil }
                for box in effective.map({ $0.applying(transform) }) {
                    guard covered(box, by: metadata.erasedRects) else { return nil }
                    bounds.append(box)
                }
                pathCount += 1
            default: return nil
            }
        }
        guard !texts.isEmpty, pathCount > 0, bounds.count <= 100_000 else { return nil }
        return Inspection(bounds: bounds, textObjects: texts, transform: transform)
    }

    private static func matrix(_ object: FPDF_PAGEOBJECT) -> CGAffineTransform? {
        var value = FS_MATRIX()
        guard FPDFPageObj_GetMatrix(object, &value) != 0,
              [value.a, value.b, value.c, value.d, value.e, value.f].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
              value.a > 0, value.d > 0, abs(value.b) < 0.001, abs(value.c) < 0.001 else { return nil }
        return CGAffineTransform(a: CGFloat(value.a), b: CGFloat(value.b), c: CGFloat(value.c),
                                 d: CGFloat(value.d), tx: CGFloat(value.e), ty: CGFloat(value.f))
    }

    private static func hasClip(_ object: FPDF_PAGEOBJECT) -> Bool {
        FPDFPageObj_GetClipPath(object).map { FPDFClipPath_CountPaths($0) > 0 } ?? false
    }

    private static func isMediaRectangle(_ object: FPDF_PAGEOBJECT, transform: CGAffineTransform, media: CGRect) -> Bool {
        let count = Int(FPDFPath_CountSegments(object))
        guard count == 4 || count == 5 else { return false }
        var points: [CGPoint] = []
        for index in 0..<count {
            guard let segment = FPDFPath_GetPathSegment(object, Int32(index)),
                  FPDFPathSegment_GetType(segment) == (index == 0 ? FPDF_SEGMENT_MOVETO : FPDF_SEGMENT_LINETO) else { return false }
            var x: Float = 0, y: Float = 0
            guard FPDFPathSegment_GetPoint(segment, &x, &y) != 0, x.isFinite, y.isFinite else { return false }
            points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)).applying(transform))
        }
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.05 && abs(a.y - b.y) < 0.05 }
        if points.count == 5 { guard near(points[0], points[4]) else { return false }; points.removeLast() }
        let corners = [CGPoint(x: media.minX, y: media.minY), CGPoint(x: media.maxX, y: media.minY),
                       CGPoint(x: media.maxX, y: media.maxY), CGPoint(x: media.minX, y: media.maxY)]
        guard corners.allSatisfy({ corner in points.filter { near($0, corner) }.count == 1 }) else { return false }
        return points.indices.allSatisfy { index in
            let a = points[index], b = points[(index + 1) % points.count]
            return abs(a.x - b.x) < 0.05 || abs(a.y - b.y) < 0.05
        }
    }

    private static func covered(_ bounds: CGRect, by rectangles: [CGRect]) -> Bool {
        var remaining = [bounds]
        for rectangle in rectangles {
            let cover = rectangle.insetBy(dx: -0.1, dy: -0.1)
            remaining = remaining.flatMap { piece -> [CGRect] in
                let cut = piece.intersection(cover)
                guard !cut.isNull, !cut.isEmpty else { return [piece] }
                return [CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY-piece.minY),
                        CGRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY-cut.maxY),
                        CGRect(x: piece.minX, y: cut.minY, width: cut.minX-piece.minX, height: cut.height),
                        CGRect(x: cut.maxX, y: cut.minY, width: piece.maxX-cut.maxX, height: cut.height)]
                    .filter { $0.width > 0.000001 && $0.height > 0.000001 }
            }
            if remaining.isEmpty { return true }
            if remaining.count > 256 { return false }
        }
        return remaining.isEmpty
    }
}
