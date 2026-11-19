// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import XCTest
@testable import HwattakPDF

final class PDFReferenceIdentityTests: XCTestCase {
    func testOpaqueReferencesKeepTheirAddressIdentity() throws {
        let first = try XCTUnwrap(OpaquePointer(bitPattern: 0x1000))
        let sameAddress = try XCTUnwrap(OpaquePointer(bitPattern: 0x1000))
        let second = try XCTUnwrap(OpaquePointer(bitPattern: 0x2000))

        XCTAssertEqual(pdfReferenceIdentity(first), 0x1000)
        XCTAssertEqual(pdfReferenceIdentity(first), pdfReferenceIdentity(sameAddress))
        XCTAssertNotEqual(pdfReferenceIdentity(first), pdfReferenceIdentity(second))
    }

    func testSDKStyleWrappersUseTheUnderlyingPointerIdentity() throws {
        let first = try XCTUnwrap(OpaquePointer(bitPattern: 0x1000))
        let second = try XCTUnwrap(OpaquePointer(bitPattern: 0x2000))
        let wrapper = WrappedReference(rawValue: first)
        let recreatedWrapper = WrappedReference(rawValue: first)

        XCTAssertEqual(pdfReferenceIdentity(wrapper), pdfReferenceIdentity(first))
        XCTAssertEqual(pdfReferenceIdentity(wrapper), pdfReferenceIdentity(recreatedWrapper))
        XCTAssertNotEqual(pdfReferenceIdentity(wrapper),
                          pdfReferenceIdentity(WrappedReference(rawValue: second)))
    }

    func testCoreGraphicsSharedReferencesRetainIdentityAcrossLookups() throws {
        let document = try fixture()
        let catalog = try XCTUnwrap(document.catalog)

        var dictionary: CGPDFDictionaryRef?, sharedDictionary: CGPDFDictionaryRef?, otherDictionary: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "Shared", &dictionary))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "SharedAgain", &sharedDictionary))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "OtherDictionary", &otherDictionary))
        XCTAssertEqual(pdfReferenceIdentity(try XCTUnwrap(dictionary)),
                       pdfReferenceIdentity(try XCTUnwrap(sharedDictionary)))
        XCTAssertNotEqual(pdfReferenceIdentity(try XCTUnwrap(dictionary)),
                          pdfReferenceIdentity(try XCTUnwrap(otherDictionary)))

        var array: CGPDFArrayRef?, sharedArray: CGPDFArrayRef?, otherArray: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(catalog, "Array", &array))
        XCTAssertTrue(CGPDFDictionaryGetArray(catalog, "ArrayAgain", &sharedArray))
        XCTAssertTrue(CGPDFDictionaryGetArray(catalog, "OtherArray", &otherArray))
        XCTAssertEqual(pdfReferenceIdentity(try XCTUnwrap(array)),
                       pdfReferenceIdentity(try XCTUnwrap(sharedArray)))
        XCTAssertNotEqual(pdfReferenceIdentity(try XCTUnwrap(array)),
                          pdfReferenceIdentity(try XCTUnwrap(otherArray)))

        var stream: CGPDFStreamRef?, sharedStream: CGPDFStreamRef?, otherStream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFDictionaryGetStream(catalog, "Stream", &stream))
        XCTAssertTrue(CGPDFDictionaryGetStream(catalog, "StreamAgain", &sharedStream))
        XCTAssertTrue(CGPDFDictionaryGetStream(catalog, "OtherStream", &otherStream))
        XCTAssertEqual(pdfReferenceIdentity(try XCTUnwrap(stream)),
                       pdfReferenceIdentity(try XCTUnwrap(sharedStream)))
        XCTAssertNotEqual(pdfReferenceIdentity(try XCTUnwrap(stream)),
                          pdfReferenceIdentity(try XCTUnwrap(otherStream)))

        var object: CGPDFObjectRef?, repeatedObject: CGPDFObjectRef?, otherObject: CGPDFObjectRef?
        XCTAssertTrue(CGPDFDictionaryGetObject(catalog, "Shared", &object))
        XCTAssertTrue(CGPDFDictionaryGetObject(catalog, "Shared", &repeatedObject))
        XCTAssertTrue(CGPDFDictionaryGetObject(catalog, "OtherDictionary", &otherObject))
        XCTAssertEqual(pdfReferenceIdentity(try XCTUnwrap(object)),
                       pdfReferenceIdentity(try XCTUnwrap(repeatedObject)))
        XCTAssertNotEqual(pdfReferenceIdentity(try XCTUnwrap(object)),
                          pdfReferenceIdentity(try XCTUnwrap(otherObject)))
    }

    private struct WrappedReference: RawRepresentable {
        let rawValue: OpaquePointer

        init(rawValue: OpaquePointer) {
            self.rawValue = rawValue
        }
    }

    private func fixture() throws -> CGPDFDocument {
        let content = "q Q"
        let stream = "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Shared 5 0 R /SharedAgain 5 0 R /OtherDictionary 7 0 R /Array 6 0 R /ArrayAgain 6 0 R /OtherArray 8 0 R /Stream 4 0 R /StreamAgain 4 0 R /OtherStream 9 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources 5 0 R /Contents 4 0 R >>",
            stream,
            "<< /Marker 42 >>",
            "[5 0 R 4 0 R 42]",
            "<< /Marker 42 >>",
            "[5 0 R 4 0 R 42]",
            stream
        ]
        var bytes = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        bytes.append(Data("trailer\n<< /Root 1 0 R /Size \(objects.count + 1) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        return try XCTUnwrap(CGPDFDocument(provider))
    }
}
