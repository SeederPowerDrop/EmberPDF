// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HwattakPDF

/// Checks the bytes that Quartz actually embeds, rather than only the decoded
/// preview. Metadata removal must not requantize JPEG coefficients or leave an
/// EXIF thumbnail/secondary image in a saved PDF.
final class PDFOriginalJPEGTests: XCTestCase {
    func testProgressiveJPEGPreservesEveryScanAndCodingTable() throws {
        let source = try fixture(progressive: true)
        let sourceParts = try parts(source)
        XCTAssertTrue(sourceParts.contains { $0.marker == 0xc2 }, "Fixture must use progressive SOF2.")
        XCTAssertGreaterThan(sourceParts.filter { $0.marker == 0xda }.count, 1)

        let saved = try embeddedJPEG(source)
        XCTAssertEqual(try codingParts(saved), try codingParts(source),
            "Every quantization/Huffman table, scan header, and entropy-coded byte must survive unchanged.")
        XCTAssertEqual(try embeddedJPEG(saved), saved, "A second save must not transcode or accumulate metadata.")
        XCTAssertEqual(try pixels(saved), try pixels(source))
    }

    func testPrivateMetadataThumbnailsAndTrailingImagesAreRemovedWhileICCSurvives() throws {
        // Start with an already normalized JPEG so the exact expected output
        // can be assembled without reproducing the production metadata parser.
        let baseline = try embeddedJPEG(fixture(progressive: false))
        let profileParts = try parts(baseline).filter {
            $0.marker == 0xe2 && $0.payload.starts(with: Data("ICC_PROFILE\0".utf8))
        }
        XCTAssertFalse(profileParts.isEmpty, "Fixture must contain a real ICC profile.")

        let jfifHeader: [UInt8] = Array("JFIF\0".utf8) + [1, 2, 0, 0, 1, 0, 1]
        let thumbnail = segment(0xe0, Data(jfifHeader + [1, 1, 231, 49, 82]))
        let strippedJFIF = segment(0xe0, Data(jfifHeader + [0, 0]))
        let metadata = [
            thumbnail,
            segment(0xe0, Data("JFXX\0private-embedded-thumbnail".utf8)),
            segment(0xe1, Data("Exif\0\0private-GPS-and-camera-thumbnail".utf8)),
            segment(0xe1, Data("http://ns.adobe.com/xap/1.0/\0private-XMP".utf8)),
            segment(0xe2, Data("MPF\0private-secondary-image-index".utf8)),
            segment(0xed, Data("Photoshop 3.0\0private-IPTC-caption".utf8)),
            segment(0xfe, Data("private-JPEG-comment".utf8))
        ].reduce(into: Data()) { $0.append($1) }
        var decorated = Data(baseline.prefix(2))
        decorated.append(metadata)
        decorated.append(baseline.dropFirst(2))
        decorated.append(Data("private-trailing-payload".utf8))
        decorated.append(try fixture(progressive: false))

        var expected = Data(baseline.prefix(2))
        expected.append(strippedJFIF)
        expected.append(baseline.dropFirst(2))
        let saved = try embeddedJPEG(decorated)
        XCTAssertEqual(saved, expected,
            "Only the thumbnail-free JFIF header and original image/profile should be embedded.")
        XCTAssertEqual(try parts(saved).filter { $0.marker == 0xe2 }, profileParts)
        XCTAssertEqual(try codingParts(saved), try codingParts(baseline))
        XCTAssertEqual(try pixels(saved), try pixels(baseline))
    }

    func testMetadataBetweenProgressiveScansIsRemovedWithoutLosingLaterScans() throws {
        let baseline = try embeddedJPEG(fixture(progressive: true))
        let scans = try parts(baseline).filter { $0.marker == 0xda }
        XCTAssertGreaterThan(scans.count, 1)
        let insertion = try XCTUnwrap(scans.first).endOffset
        var decorated = Data(baseline.prefix(insertion))
        decorated.append(segment(0xe1, Data("Exif\0\0private-between-scans".utf8)))
        decorated.append(segment(0xfe, Data("private-between-scan-comment".utf8)))
        decorated.append(baseline.dropFirst(insertion))
        XCTAssertEqual(try embeddedJPEG(decorated), baseline)
    }

    func testMalformedMarkersAndUnsupportedOrientationUseFallback() throws {
        let valid = try fixture(progressive: false)
        var invalidLength = Data(valid.prefix(2))
        invalidLength.append(contentsOf: [0xff, 0xe1, 0, 1])
        invalidLength.append(valid.dropFirst(2))
        var oversizedLength = Data(valid.prefix(2))
        oversizedLength.append(contentsOf: [0xff, 0xe1, 0xff, 0xff, 1, 2])
        let malformed: [Data] = [
            Data(), Data([0xff]), Data([0xff, 0xd8, 0xff]),
            Data([0xff, 0xd8, 0xff, 0xe1, 0]),
            Data([0xff, 0xd8, 0xff, 0xd9]),
            Data([0xff, 0xd8, 0xff, 0x00, 0, 2]),
            Data([0xff, 0xd8, 0xff, 0xd0, 0xff, 0xd9]),
            invalidLength, oversizedLength, Data(valid.dropLast()), Data(valid.dropLast(2))
        ]
        for (index, data) in malformed.enumerated() {
            XCTAssertNil(PDFOriginalJPEG(data: data, orientation: 1), "Malformed fixture \(index) must fall back.")
        }
        XCTAssertNil(PDFOriginalJPEG(data: valid, orientation: 0))
        XCTAssertNil(PDFOriginalJPEG(data: valid, orientation: 9))
    }

    private struct Part: Equatable {
        let marker: UInt8
        let payload: Data
        let coding: Data
        let endOffset: Int

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.marker == rhs.marker && lhs.payload == rhs.payload && lhs.coding == rhs.coding
        }
    }

    /// Test fixture inspection: each SOS part includes all entropy bytes up to
    /// its next structural marker. APP contents are inspected independently.
    private func parts(_ data: Data) throws -> [Part] {
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes.prefix(2)), [0xff, 0xd8])
        var result: [Part] = [], offset = 2
        while offset < bytes.count {
            let start = offset
            guard bytes[offset] == 0xff else { throw FixtureError.invalidJPEG }
            while offset < bytes.count && bytes[offset] == 0xff { offset += 1 }
            guard offset < bytes.count else { throw FixtureError.invalidJPEG }
            let marker = bytes[offset]
            offset += 1
            if marker == 0xd9 { return result }
            guard offset + 2 <= bytes.count else { throw FixtureError.invalidJPEG }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            guard length >= 2, offset + length <= bytes.count else { throw FixtureError.invalidJPEG }
            let payload = Data(bytes[(offset + 2)..<(offset + length)])
            offset += length
            if marker == 0xda {
                while offset < bytes.count {
                    if bytes[offset] != 0xff { offset += 1; continue }
                    let boundary = offset
                    repeat { offset += 1 } while offset < bytes.count && bytes[offset] == 0xff
                    guard offset < bytes.count else { throw FixtureError.invalidJPEG }
                    if bytes[offset] == 0 || (0xd0...0xd7).contains(bytes[offset]) { offset += 1 }
                    else { offset = boundary; break }
                }
            }
            result.append(Part(marker: marker, payload: payload, coding: Data(bytes[start..<offset]), endOffset: offset))
        }
        throw FixtureError.invalidJPEG
    }

    private func codingParts(_ data: Data) throws -> [Data] {
        try parts(data).filter { !(0xe0...0xef).contains($0.marker) && $0.marker != 0xfe }.map(\.coding)
    }

    private func segment(_ marker: UInt8, _ payload: Data) -> Data {
        let length = payload.count + 2
        var result = Data([0xff, marker, UInt8(length >> 8), UInt8(length & 255)])
        result.append(payload)
        return result
    }

    private func fixture(progressive: Bool) throws -> Data {
        let width = 96, height = 64
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for y in 0..<height {
            for x in 0..<width {
                let r = CGFloat((x * 13 + y * 7) % 256) / 255
                let g = CGFloat((x * 3 + y * 17) % 256) / 255
                context.setFillColor(CGColor(colorSpace: context.colorSpace!, components: [r, g, 1 - r, 1])!)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
            kCGImageDestinationLossyCompressionQuality: 0.71,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: progressive]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func embeddedJPEG(_ source: Data) throws -> Data {
        let jpeg = try XCTUnwrap(PDFOriginalJPEG(data: source, orientation: 1))
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: jpeg.image.width, height: jpeg.image.height)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        jpeg.draw(in: context, bounds: bounds)
        context.endPDFPage()
        context.closePDF()
        let document = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data))))
        let page = try XCTUnwrap(document.page(at: 1))
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(page.dictionary), "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &objects))
        let collector = ImageCollector()
        CGPDFDictionaryApplyFunction(try XCTUnwrap(objects), { _, object, info in
            guard let info else { return }
            let collector = Unmanaged<ImageCollector>.fromOpaque(info).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
            var format: CGPDFDataFormat = .raw
            if let bytes = CGPDFStreamCopyData(stream, &format), format == .jpegEncoded {
                collector.images.append(bytes as Data)
            }
        }, Unmanaged.passUnretained(collector).toOpaque())
        XCTAssertEqual(collector.images.count, 1, "Quartz must retain one DCT image.")
        return try XCTUnwrap(collector.images.first)
    }

    private func pixels(_ data: Data) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    private final class ImageCollector { var images: [Data] = [] }
    private enum FixtureError: Error { case invalidJPEG }
}
