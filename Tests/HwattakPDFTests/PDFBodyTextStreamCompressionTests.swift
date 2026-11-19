// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit
import XCTest
import zlib
@testable import HwattakPDF

@MainActor
final class PDFBodyTextStreamCompressionTests: XCTestCase {
    func testDecodedImageAndPredictorSoftMaskStayLosslessWithoutSizeExpansion() throws {
        let width = 1024, height = 512
        let image = Data(repeating: 92, count: width * height * 3)
        let mask = Data((0..<(width * height)).map { (($0 % width) / 8 + ($0 / width) / 8) % 2 == 0 ? UInt8(255) : 96 })
        var predicted = Data()
        for row in 0..<height { predicted.append(0); predicted.append(mask[(row * width)..<((row + 1) * width)]) }
        let sourceData = fixture(width: width, height: height, image: image,
                                 mask: try flate(predicted), predictedMask: true)
        let source = try XCTUnwrap(PDFDocument(data: sourceData)), page = try XCTUnwrap(source.page(at: 0))
        let output = try PDFBodyTextPageSnapshot.data(for: page)
        XCTAssertLessThan(output.count, sourceData.count / 8,
                          "Decoded scan image/mask bytes must not be saved as an expanded uncompressed stream.")
        let saved = try XCTUnwrap(PDFDocument(data: output)), savedPage = try XCTUnwrap(saved.page(at: 0))
        XCTAssertEqual(try pixels(page), try pixels(savedPage))
        let savedImage = try imageStream(savedPage)
        XCTAssertEqual(try decoded(savedImage), image)
        var savedMask: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(CGPDFStreamGetDictionary(savedImage)), "SMask", &savedMask))
        XCTAssertEqual(try decoded(XCTUnwrap(savedMask)), mask)
        let dictionary = try XCTUnwrap(CGPDFStreamGetDictionary(XCTUnwrap(savedMask)))
        var filter: UnsafePointer<CChar>?, parameters: CGPDFObjectRef?
        XCTAssertTrue(CGPDFDictionaryGetName(dictionary, "Filter", &filter))
        XCTAssertEqual(filter.map(String.init(cString:)), "FlateDecode")
        XCTAssertFalse(CGPDFDictionaryGetObject(dictionary, "DecodeParms", &parameters),
                       "The source's already-decoded PNG predictor must not be applied a second time.")
    }

    func testIncompressibleImageDoesNotGrowOrChangePixels() throws {
        var state: UInt32 = 0xDA7A2026
        let image = Data((0..<(256 * 128 * 3)).map { _ -> UInt8 in
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        })
        let sourceData = fixture(width: 256, height: 128, image: image)
        let source = try XCTUnwrap(PDFDocument(data: sourceData)), page = try XCTUnwrap(source.page(at: 0))
        let output = try PDFBodyTextPageSnapshot.data(for: page)
        XCTAssertLessThanOrEqual(output.count, sourceData.count + 1024)
        let saved = try XCTUnwrap(PDFDocument(data: output)), savedPage = try XCTUnwrap(saved.page(at: 0))
        XCTAssertEqual(try pixels(page), try pixels(savedPage))
        XCTAssertEqual(try decoded(imageStream(savedPage)), image)
    }

    func testOneBitSoftMaskUsesSmallerGroup4WithoutChangingBitsOrVisiblePixels() throws {
        let width = 2048, height = 512, rowBytes = width / 8
        var mask = Data(repeating: 255, count: rowBytes * height)
        for row in 0..<height {
            let start = row * 3 % 1024
            for column in start..<(start + 200) {
                mask[row * rowBytes + column / 8] &= ~(UInt8(1) << (7 - column % 8))
            }
        }
        let group4 = try XCTUnwrap(PDFMonochromeImageEncoder.encode(data: mask, width: width, height: height))
        XCTAssertLessThan(group4.count + 128, try flate(mask).count,
                          "This diagonal bitmap exercises the production choice of Group 4 over Flate.")
        let sourceData = fixture(width: width, height: height,
            image: Data(repeating: 92, count: width * height * 3), mask: mask, maskBits: 1)
        let source = try XCTUnwrap(PDFDocument(data: sourceData)), page = try XCTUnwrap(source.page(at: 0))
        let output = try PDFBodyTextPageSnapshot.data(for: page)
        let saved = try XCTUnwrap(PDFDocument(data: output)), savedPage = try XCTUnwrap(saved.page(at: 0))
        XCTAssertEqual(try pixels(page), try pixels(savedPage))
        let savedImage = try imageStream(savedPage)
        var savedMask: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(CGPDFStreamGetDictionary(savedImage)), "SMask", &savedMask))
        XCTAssertEqual(try decoded(XCTUnwrap(savedMask)), mask)
        let dictionary = try XCTUnwrap(CGPDFStreamGetDictionary(XCTUnwrap(savedMask)))
        var filter: UnsafePointer<CChar>?, parameters: CGPDFDictionaryRef?, blackIs1: CGPDFBoolean = 0
        XCTAssertTrue(CGPDFDictionaryGetName(dictionary, "Filter", &filter))
        XCTAssertEqual(filter.map { String(cString: $0) }, "CCITTFaxDecode")
        XCTAssertTrue(CGPDFDictionaryGetDictionary(dictionary, "DecodeParms", &parameters))
        XCTAssertTrue(CGPDFDictionaryGetBoolean(try XCTUnwrap(parameters), "BlackIs1", &blackIs1))
        XCTAssertEqual(blackIs1, 1)
    }

    private func fixture(width: Int, height: Int, image: Data, mask: Data? = nil,
                         predictedMask: Bool = false, maskBits: Int = 8) -> Data {
        var objects = [Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 256 128] /Resources << /XObject << /Im1 5 0 R >> >> /Contents 4 0 R >>".utf8),
            stream(Data("q 256 0 0 128 0 0 cm /Im1 Do Q".utf8)),
            stream(image, entries: "/Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceRGB /BitsPerComponent 8"
                   + (mask == nil ? "" : " /SMask 6 0 R"))]
        if let mask {
            objects.append(stream(mask, entries: "/Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceGray /BitsPerComponent \(maskBits)"
                + (predictedMask ? " /Filter /FlateDecode /DecodeParms << /Predictor 15 /Columns \(width) /Colors 1 /BitsPerComponent 8 >>" : "")))
        }
        var result = Data("%PDF-1.7\n".utf8), offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(result.count); result.append(Data("\(index + 1) 0 obj\n".utf8))
            result.append(object); result.append(Data("\nendobj\n".utf8))
        }
        let xref = result.count
        result.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { result.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        result.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return result
    }

    private func stream(_ data: Data, entries: String = "") -> Data {
        var result = Data("<< /Length \(data.count) \(entries) >>\nstream\n".utf8)
        result.append(data); result.append(Data("\nendstream".utf8)); return result
    }

    private func flate(_ data: Data) throws -> Data {
        var length = compressBound(uLong(data.count)), output = Data(count: Int(compressBound(uLong(data.count))))
        let status = output.withUnsafeMutableBytes { target in data.withUnsafeBytes { source in
            compress2(target.baseAddress?.assumingMemoryBound(to: Bytef.self), &length,
                      source.baseAddress?.assumingMemoryBound(to: Bytef.self), uLong(data.count), Z_BEST_SPEED)
        } }
        XCTAssertEqual(status, Z_OK); output.count = Int(length); return output
    }

    private func imageStream(_ page: PDFPage) throws -> CGPDFStreamRef {
        var resources: CGPDFDictionaryRef?, images: CGPDFDictionaryRef?, image: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(page.pageRef?.dictionary), "Resources", &resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources), "XObject", &images))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(images), "Im1", &image))
        return try XCTUnwrap(image)
    }

    private func decoded(_ stream: CGPDFStreamRef) throws -> Data {
        var format = CGPDFDataFormat.raw
        let data = try XCTUnwrap(CGPDFStreamCopyData(stream, &format)) as Data
        XCTAssertEqual(format, .raw); return data
    }

    private func pixels(_ page: PDFPage) throws -> Data {
        var result = Data(repeating: 255, count: 256 * 128 * 4)
        try result.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 256, height: 128,
                bitsPerComponent: 8, bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
            context.drawPDFPage(try XCTUnwrap(page.pageRef))
        }
        return result
    }
}
