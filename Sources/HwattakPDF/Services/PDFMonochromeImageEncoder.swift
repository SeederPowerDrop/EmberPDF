// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Optional lossless compression for already decoded, one-bit DeviceGray
/// samples. ImageIO owns Group 4 encoding; unsupported layouts keep the
/// existing Flate path. This never quantizes an eight-bit image.
enum PDFMonochromeImageEncoder {
    private static let maximumInputBytes = 16 * 1_024 * 1_024
    private static let maximumTIFFBytes = 64 * 1_024 * 1_024

    /// The returned payload uses PDF /CCITTFaxDecode with /K -1,
    /// /Columns width, /Rows height, and /BlackIs1 true. Keep the source
    /// image dictionary's /Decode array, if any, unchanged.
    static func encode(data: Data, width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, width <= 65_535, height <= 65_535 else { return nil }
        let row = (width + 7) / 8
        guard height <= maximumInputBytes / row, data.count == row * height,
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 1,
                bitsPerPixel: 1, bytesPerRow: row, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.tiff.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image,
            [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 4]] as CFDictionary)
        guard CGImageDestinationFinalize(destination), encoded.length <= maximumTIFFBytes else { return nil }
        return group4Payload(fromGeneratedTIFF: encoded as Data, width: width, height: height)
    }

    /// Read only the bounded scalar directory emitted by our native encoder.
    /// Multi-strip/tiled/multi-image TIFF, alternate polarity or bit order, and
    /// ambiguous directories fall back rather than inventing PDF semantics.
    static func group4Payload(fromGeneratedTIFF data: Data, width: Int, height: Int) -> Data? {
        guard data.count >= 14, data.count <= maximumTIFFBytes else { return nil }
        let little: Bool
        if data[0] == 0x49, data[1] == 0x49 { little = true }
        else if data[0] == 0x4D, data[1] == 0x4D { little = false }
        else { return nil }
        func u16(_ offset: Int) -> Int {
            little ? Int(data[offset]) | Int(data[offset+1]) << 8
                : Int(data[offset]) << 8 | Int(data[offset+1])
        }
        func u32(_ offset: Int) -> Int {
            if little {
                return Int(data[offset]) | Int(data[offset+1]) << 8
                    | Int(data[offset+2]) << 16 | Int(data[offset+3]) << 24
            }
            return Int(data[offset]) << 24 | Int(data[offset+1]) << 16
                | Int(data[offset+2]) << 8 | Int(data[offset+3])
        }
        guard u16(2) == 42 else { return nil }
        let directory = u32(4)
        guard directory >= 8, directory <= data.count-2 else { return nil }
        let count = u16(directory)
        guard count > 0, count <= 128, count <= (data.count-directory-6)/12 else { return nil }
        let directoryEnd = directory+2+count*12+4
        guard directoryEnd <= data.count, u32(directoryEnd-4) == 0 else { return nil }
        var scalars: [Int: Int] = [:], seen = Set<Int>()
        let required: Set<Int> = [256,257,258,259,262,266,273,274,277,278,279,284]
        for index in 0..<count {
            let offset = directory+2+index*12, tag = u16(offset), type = u16(offset+2)
            guard seen.insert(tag).inserted, ![322,323,324,325].contains(tag) else { return nil }
            guard required.contains(tag) else { continue }
            guard u32(offset+4) == 1, type == 3 || type == 4 else { return nil }
            scalars[tag] = type == 3 ? u16(offset+8) : u32(offset+8)
        }
        guard scalars[256] == width, scalars[257] == height,
              scalars[258] == 1, scalars[259] == 4, scalars[262] == 1,
              scalars[266] == 1, scalars[274] == 1, scalars[277] == 1,
              scalars[278] == height, scalars[284] == 1,
              let start = scalars[273], let length = scalars[279],
              start >= 8, length > 0, start <= data.count, length <= data.count-start else { return nil }
        let end = start+length
        guard end <= directory || start >= directoryEnd else { return nil }
        return data.subdata(in: start..<end)
    }
}
