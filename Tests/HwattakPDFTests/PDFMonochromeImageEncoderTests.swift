// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFMonochromeImageEncoderTests: XCTestCase {
    func testNativeGroup4RetainsEveryDecodedByteAndRenderedPixelWithEitherDecodePolarity() throws {
        let width=128,height=96,raw=samples(width:width,height:height)
        let encoded=try XCTUnwrap(PDFMonochromeImageEncoder.encode(data:raw,width:width,height:height))
        XCTAssertLessThan(encoded.count,raw.count)
        for inverted in [false,true] {
            let original=try imagePDF(payload:raw,width:width,height:height,inverted:inverted,group4:false)
            let compressed=try imagePDF(payload:encoded,width:width,height:height,inverted:inverted,group4:true)
            XCTAssertEqual(try decoded(compressed),raw,
                           "BlackIs1 must describe the native codec, independently of the image's Decode array.")
            XCTAssertEqual(try pixels(original,width:width,height:height),try pixels(compressed,width:width,height:height))
        }
    }

    func testNonByteAlignedRowsPreserveEveryVisibleBitAndRGBAValue() throws {
        let width=13,height=45,raw=samples(width:width,height:height)
        let encoded=try XCTUnwrap(PDFMonochromeImageEncoder.encode(data:raw,width:width,height:height))
        let original=try imagePDF(payload:raw,width:width,height:height,inverted:false,group4:false)
        let compressed=try imagePDF(payload:encoded,width:width,height:height,inverted:false,group4:true)
        let recovered=try decoded(compressed),row=(width+7)/8
        XCTAssertEqual(recovered.count,raw.count)
        for y in 0..<height {for x in 0..<width {
            let shift=UInt8(7-x%8)
            XCTAssertEqual((raw[y*row+x/8]>>shift)&1,(recovered[y*row+x/8]>>shift)&1)
        }}
        XCTAssertEqual(try pixels(original,width:width,height:height),try pixels(compressed,width:width,height:height))
    }

    func testUnsupportedDimensionsAndNonOneBitDataFallBack() {
        for (width,height,data) in [(0,10,Data()),(-1,10,Data()),(65_536,1,Data()),
            (65_535,65_535,Data()),(8,8,Data(repeating:0,count:64)),(8,8,Data())] {
            XCTAssertNil(PDFMonochromeImageEncoder.encode(data:data,width:width,height:height))
        }
    }

    func testTIFFReaderRejectsAmbiguousPolarityPackingAndStripMetadata() throws {
        let valid=tiff()
        XCTAssertEqual(PDFMonochromeImageEncoder.group4Payload(fromGeneratedTIFF:valid,width:8,height:8),Data([1,2,3,4]))
        for (tag,value) in [(258,8),(259,1),(262,0),(266,2),(274,2),(277,4),(278,7),(284,2),
                            (273,12),(279,65_535),(256,9),(257,9)] {
            XCTAssertNil(PDFMonochromeImageEncoder.group4Payload(fromGeneratedTIFF:tiff(overrides:[tag:value]),width:8,height:8),"Tag \(tag)")
        }
        for invalid in [Data(),Data(valid.prefix(13)),tiff(multiStrip:true),tiff(duplicate:true),
                        tiff(nextDirectory:8),tiff(tile:true)] {
            XCTAssertNil(PDFMonochromeImageEncoder.group4Payload(fromGeneratedTIFF:invalid,width:8,height:8))
        }
    }

    private func samples(width:Int,height:Int)->Data {
        let row=(width+7)/8
        var data=Data(repeating:0,count:row*height)
        for y in 0..<height {for x in 0..<width {
            if (x/9+y/7)%3 != 0 {data[y*row+x/8] |= 1<<UInt8(7-x%8)}
        }}
        return data
    }

    private func decoded(_ data:Data)throws->Data {
        let document=try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data:data as CFData))))
        let dictionary=try XCTUnwrap(document.page(at:1)?.dictionary)
        var resources:CGPDFDictionaryRef?,images:CGPDFDictionaryRef?,image:CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(dictionary,"Resources",&resources))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(resources),"XObject",&images))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(images),"Image",&image))
        var format=CGPDFDataFormat.raw
        let result=try XCTUnwrap(CGPDFStreamCopyData(XCTUnwrap(image),&format)) as Data
        XCTAssertEqual(format,.raw)
        return result
    }

    private func pixels(_ data:Data,width:Int,height:Int)throws->Data {
        let document=try XCTUnwrap(CGPDFDocument(XCTUnwrap(CGDataProvider(data:data as CFData))))
        var pixels=Data(repeating:255,count:width*height*4)
        try pixels.withUnsafeMutableBytes {raw in
            let context=try XCTUnwrap(CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.drawPDFPage(try XCTUnwrap(document.page(at:1)))
        }
        return pixels
    }

    private func imagePDF(payload:Data,width:Int,height:Int,inverted:Bool,group4:Bool)throws->Data {
        let filter=group4 ? "/Filter /CCITTFaxDecode /DecodeParms << /K -1 /Columns \(width) /Rows \(height) /BlackIs1 true >>" : ""
        var image=Data("<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /BitsPerComponent 1 /ColorSpace /DeviceGray /Decode \(inverted ? "[1 0]" : "[0 1]") \(filter) /Length \(payload.count) >>\nstream\n".utf8)
        image.append(payload);image.append(Data("\nendstream".utf8))
        let commands="q \(width) 0 0 \(height) 0 0 cm /Image Do Q\n"
        let objects=[Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),Data("<< /Type /Pages /Count 1 /Kids [3 0 R] >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] /Resources << /XObject << /Image 4 0 R >> >> /Contents 5 0 R >>".utf8),
            image,Data("<< /Length \(commands.utf8.count) >>\nstream\n\(commands)endstream".utf8)]
        var data=Data("%PDF-1.7\n".utf8),offsets=[0]
        for (index,object) in objects.enumerated() {
            offsets.append(data.count);data.append(Data("\(index+1) 0 obj\n".utf8));data.append(object);data.append(Data("\nendobj\n".utf8))
        }
        let xref=data.count
        data.append(Data("xref\n0 \(objects.count+1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {data.append(Data(String(format:"%010d 00000 n \n",offset).utf8))}
        data.append(Data("trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    private func tiff(overrides:[Int:Int]=[:],multiStrip:Bool=false,duplicate:Bool=false,
                      nextDirectory:Int=0,tile:Bool=false)->Data {
        var values=[(256,8),(257,8),(258,1),(259,4),(262,1),(266,1),(273,8),(274,1),
                    (277,1),(278,8),(279,4),(284,1)]
        if duplicate {values.append((256,8))}
        if tile {values.append((322,8))}
        var data=Data([0x49,0x49,42,0,12,0,0,0,1,2,3,4])
        func append(_ value:Int,bytes:Int) {for shift in 0..<bytes {data.append(UInt8((value>>(8*shift))&255))}}
        append(values.count,bytes:2)
        for (tag,value) in values {
            append(tag,bytes:2);append(4,bytes:2)
            append(multiStrip && tag==273 ? 2 : 1,bytes:4);append(overrides[tag] ?? value,bytes:4)
        }
        append(nextDirectory,bytes:4)
        return data
    }
}
