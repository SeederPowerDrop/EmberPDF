// SPDX-License-Identifier: MPL-2.0

import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import HwattakPDF

final class ImageInsertionOptionsTests: XCTestCase {
    @MainActor
    func testOriginalKeepsJPEGCompressionAndPreparedPixelsSurviveSourceReplacement() throws {
        try inTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("photo.jpg")
            let data = try jpeg(width: 640, height: 480, quality: 0.55)
            try data.write(to: url)
            let prepared = try XCTUnwrap(ImageInsertionPreparation.prepare(urls: [url], option: .original).first)
            XCTAssertNotNil(prepared.originalJPEG)
            XCTAssertFalse(prepared.isRecompressed)
            XCTAssertFalse(prepared.isResized)
            XCTAssertEqual(prepared.sourceBytes, data.count)
            XCTAssertEqual(prepared.pixelSize, CGSize(width: 640, height: 480))
            XCTAssertLessThan(prepared.estimatedAddedBytes, data.count + 10_000)
            let before = try rasterPixels(prepared.image)
            try Data("replaced after the preview was prepared".utf8).write(to: url)
            XCTAssertEqual(try rasterPixels(prepared.image), before)
            XCTAssertEqual(prepared.originalJPEG?.image.width, 640)
        }
    }

    @MainActor
    func testBalancedAndSmallProduceBoundedRastersAndSmallerPhotoAppearances() throws {
        try inTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("large.jpg")
            try jpeg(width: 2_800, height: 1_400, quality: 0.98).write(to: url)
            let original = try XCTUnwrap(ImageInsertionPreparation.prepare(urls: [url], option: .original).first)
            let balanced = try XCTUnwrap(ImageInsertionPreparation.prepare(urls: [url], option: .balanced).first)
            let small = try XCTUnwrap(ImageInsertionPreparation.prepare(urls: [url], option: .small).first)
            XCTAssertEqual(original.pixelSize.width, 2_800)
            XCTAssertEqual(balanced.pixelSize, CGSize(width: 2_400, height: 1_200))
            XCTAssertEqual(small.pixelSize, CGSize(width: 1_600, height: 800))
            XCTAssertTrue(balanced.isResized)
            XCTAssertTrue(small.isResized)
            XCTAssertTrue(balanced.isRecompressed)
            XCTAssertTrue(small.isRecompressed)
            XCTAssertNotNil(balanced.originalJPEG)
            XCTAssertNotNil(small.originalJPEG)
            XCTAssertLessThan(balanced.estimatedAddedBytes, original.estimatedAddedBytes)
            XCTAssertLessThan(small.estimatedAddedBytes, balanced.estimatedAddedBytes)
            print("IMAGE_QUALITY original=\(original.estimatedAddedBytes) balanced=\(balanced.estimatedAddedBytes) small=\(small.estimatedAddedBytes)")
        }
    }

    @MainActor
    func testTransparentPNGRemainsTransparentAndIsNeverJPEGFlattened() throws {
        try inTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("transparent.png")
            let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8,
                bytesPerRow: 320 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.clear(CGRect(x: 0, y: 0, width: 320, height: 200))
            context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 0.5))
            context.fill(CGRect(x: 60, y: 40, width: 200, height: 120))
            let png = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            try (png as Data).write(to: url)
            let original = try XCTUnwrap(ImageInsertionPreparation.prepare(urls: [url], option: .original).first)
            for quality in [ImageInsertionQuality.balanced, .small] {
                let result = try XCTUnwrap(ImageInsertionPreparation.prepare(urls: [url], option: quality).first)
                XCTAssertNil(result.originalJPEG)
                XCTAssertTrue(result.preservesTransparency)
                XCTAssertFalse(result.isRecompressed)
                XCTAssertEqual(try rasterPixels(result.image), try rasterPixels(original.image))
                let bytes = try rasterPixels(result.image)
                XCTAssertEqual(bytes[3], 0, "The transparent margin must not be flattened to a solid color.")
                XCTAssertTrue((120...135).contains(Int(bytes[(100 * 320 + 160) * 4 + 3])))
            }
        }
    }

    @MainActor
    func testSmallerChoiceDoesNotEnlargeAnAlreadyCompactJPEG() throws {
        try inTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("compact.jpg")
            try jpeg(width: 640, height: 480, quality: 0.15).write(to: url)
            let original = try XCTUnwrap(ImageInsertionPreparation.prepare(urls: [url], option: .original).first)
            for option in [ImageInsertionQuality.balanced, .small] {
                let result = try XCTUnwrap(ImageInsertionPreparation.prepare(urls: [url], option: option).first)
                XCTAssertLessThanOrEqual(result.estimatedAddedBytes, original.estimatedAddedBytes)
                XCTAssertEqual(result.pixelSize, original.pixelSize)
            }
        }
    }

    @MainActor
    func testOriginalPreservesCameraOrientationWithoutCountingItAsResizing() throws {
        try inTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("portrait.jpg")
            try jpeg(width: 640, height: 480, quality: 0.8, orientation: 6).write(to: url)
            let result = try XCTUnwrap(ImageInsertionPreparation.prepare(urls: [url], option: .original).first)
            XCTAssertEqual(result.pixelSize, CGSize(width: 480, height: 640))
            XCTAssertEqual(result.originalJPEG?.orientation, 6)
            XCTAssertFalse(result.isResized)
        }
    }

    @MainActor
    func testInvalidBatchThrowsWithoutReturningPartialPreparationOrChangingFiles() throws {
        try inTemporaryDirectory { directory in
            let valid = directory.appendingPathComponent("valid.jpg")
            let invalid = directory.appendingPathComponent("invalid.jpg")
            let validData = try jpeg(width: 120, height: 80, quality: 0.8)
            try validData.write(to: valid)
            try Data("not an image".utf8).write(to: invalid)
            XCTAssertThrowsError(try ImageInsertionPreparation.prepare(urls: [valid, invalid], option: .balanced))
            XCTAssertEqual(try Data(contentsOf: valid), validData)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
        }
    }

    func testPreparationCanRunOnBackgroundWorker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("background.jpg")
        try jpeg(width: 320, height: 240, quality: 0.85).write(to: url)
        let result = try await Task.detached {
            try ImageInsertionPreparation.prepare(urls: [url], option: .small)
        }.value
        XCTAssertEqual(result.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(result.first).estimatedAddedBytes, 0)
    }

    private func inTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func jpeg(width: Int, height: Int, quality: CGFloat, orientation: Int = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var random: UInt64 = 0x6fab_1234_45dc_a667
        for y in 0..<height {
            for x in 0..<width {
                random = random &* 6_364_136_223_846_793_005 &+ 1
                let noise = Int((random >> 32) & 127) - 63
                let index = (y * width + x) * 4
                pixels[index] = UInt8(clamping: 50 + x * 150 / width + noise)
                pixels[index + 1] = UInt8(clamping: 45 + y * 150 / height + noise)
                pixels[index + 2] = UInt8(clamping: 80 + (x + y) * 100 / (width + height) - noise)
                pixels[index + 3] = 255
            }
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
            [kCGImageDestinationLossyCompressionQuality: quality, kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func rasterPixels(_ image: NSImage) throws -> Data {
        let width = Int(image.size.width), height = Int(image.size.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(try XCTUnwrap(image.cgImage(forProposedRect: &bounds, context: nil, hints: nil)), in: bounds)
        return Data(bytes: try XCTUnwrap(context.data), count: width * height * 4)
    }
}
