// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import ImageIO

/// Keeps JPEG coefficients intact for an uncropped stamp. ImageIO's native
/// image provider lets Quartz write a DCT image instead of expanding a photo
/// into a losslessly compressed bitmap. This is never used for a partial crop.
struct PDFOriginalJPEG {
    let image: CGImage
    let orientation: Int

    init?(data: Data, orientation: Int) {
        guard (1...8).contains(orientation),
              let stripped = Self.removingMetadata(from: data),
              let source = CGImageSourceCreateWithData(stripped as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              image.bitsPerComponent == 8,
              let model = image.colorSpace?.model,
              model == .rgb || model == .monochrome else { return nil }
        self.image = image
        self.orientation = orientation
    }

    func draw(in context: CGContext, bounds: CGRect) {
        context.saveGState()
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.scaleBy(x: bounds.width, y: bounds.height)
        // EXIF orientation is applied to the PDF drawing matrix, preserving
        // the encoded pixels even for mirrored/portrait camera photos.
        let transform: CGAffineTransform
        switch orientation {
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0)
        case 3: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
        case 4: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
        case 5: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 1, ty: 1)
        case 6: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)
        case 7: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        default: transform = .identity
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        context.restoreGState()
    }

    /// Remove EXIF/GPS/XMP/IPTC, comments, embedded thumbnails and trailing
    /// data without decoding/re-encoding the image. Keep only rendering-related
    /// JFIF, ICC and Adobe metadata. Scan data, tables and progressive scans are
    /// copied verbatim; malformed/unsupported streams use the raster fallback.
    private static func removingMetadata(from data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { return nil }
        var result = Data([0xff, 0xd8])
        var position = 2
        while position < bytes.count {
            guard bytes[position] == 0xff else { return nil }
            while position < bytes.count, bytes[position] == 0xff { position += 1 }
            guard position < bytes.count else { return nil }
            let marker = bytes[position]
            position += 1
            if marker == 0xd9 {
                result.append(contentsOf: [0xff, marker])
                return result
            }
            guard marker != 0, marker != 0xd8, !(0xd0...0xd7).contains(marker) else { return nil }
            if marker == 1 { result.append(contentsOf: [0xff, marker]); continue }
            guard position + 2 <= bytes.count else { return nil }
            let length = Int(bytes[position]) * 256 + Int(bytes[position + 1])
            guard length >= 2, length <= bytes.count - position else { return nil }
            let payload = bytes[(position + 2)..<(position + length)]
            var retained: ArraySlice<UInt8>?
            switch marker {
            case 0xe0:
                if payload.count >= 14, payload.starts(with: Array("JFIF\0".utf8)) {
                    // JFIF's final two header bytes describe an optional RGB
                    // thumbnail. Emit no thumbnail or hidden secondary image.
                    var header = Array(payload.prefix(14))
                    header[12] = 0
                    header[13] = 0
                    retained = header[...]
                }
            case 0xe2:
                if payload.count >= 14, payload.starts(with: Array("ICC_PROFILE\0".utf8)) {
                    retained = payload
                }
            case 0xee:
                if payload.count >= 12, payload.starts(with: Array("Adobe".utf8)) {
                    retained = payload.prefix(12)
                }
            case 0xe1...0xef, 0xfe:
                break
            default:
                retained = payload
            }
            if let retained {
                let storedLength = retained.count + 2
                result.append(contentsOf: [0xff, marker, UInt8(storedLength >> 8), UInt8(storedLength & 255)])
                result.append(contentsOf: retained)
            }
            position += length
            if marker == 0xda {
                // Entropy-coded data contains stuffed FF00 and restart markers.
                // Stop at the next real marker; progressive scans can continue
                // after tables/metadata, so don't simply copy to end-of-file.
                let start = position
                while position < bytes.count {
                    if bytes[position] != 0xff { position += 1; continue }
                    let markerStart = position
                    while position < bytes.count, bytes[position] == 0xff { position += 1 }
                    guard position < bytes.count else { return nil }
                    let next = bytes[position]
                    if next == 0 || (0xd0...0xd7).contains(next) { position += 1; continue }
                    result.append(contentsOf: bytes[start..<markerStart])
                    position = markerStart
                    break
                }
            }
        }
        return nil
    }
}
