// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFDecimalNumberTests: XCTestCase {
    func testFiniteNumbersRoundTripWithoutExponentSyntaxOrRoundingTinyTransformsToZero() throws {
        let values: [CGFloat] = [0, -0.0, 0.1, .pi, -9.094947017e-13, 1e-30, -1e30,
            .leastNonzeroMagnitude, .greatestFiniteMagnitude]
        for value in values {
            let encoded = try PDFDecimalNumber.string(value)
            XCTAssertFalse(encoded.contains("e") || encoded.contains("E"))
            XCTAssertEqual(Double(encoded), Double(value))
            var lexer = PDFBodyTextContentStream.Lexer(bytes: Array(encoded.utf8))
            XCTAssertEqual(try lexer.next()?.number, value)
            XCTAssertNil(try lexer.next())
        }
        XCTAssertNotEqual(try PDFDecimalNumber.string(-9.094947017e-13), "0")
        XCTAssertEqual(try XCTUnwrap(Double(PDFDecimalNumber.string(-0.0))).sign, .minus)
    }

    func testNonfiniteNumbersAreRejectedRatherThanWrittenAsZeroOrInvalidPDF() {
        for value in [CGFloat.nan, CGFloat.infinity, -CGFloat.infinity] {
            XCTAssertThrowsError(try PDFDecimalNumber.string(value))
        }
    }

    @MainActor
    func testScanClipSerializationRetainsTinyTransformComponentsAsPDFDecimals() throws {
        let source = "q 1 0 0 1 0 -0.0000000000009094947017 cm /Scan Do Q\nBT 3 Tr [] TJ ET"
        let offset = try XCTUnwrap(source.range(of: "[] TJ")).lowerBound.utf16Offset(in: source)
        let output = try PDFScannedReadOrderContent.render(Data(source.utf8),
            erasedRects: [CGRect(x: 10, y: 10, width: 20, height: 10)],
            mediaBox: CGRect(x: 0, y: 0, width: 100, height: 100), paperColor: .white,
            insertionOffset: offset, donorName: "NewText")
        var lexer = PDFBodyTextContentStream.Lexer(bytes: Array(output))
        while let token = try lexer.next() {
            if let command = token.command {
                XCTAssertNil(command.range(of: "^[eE][+-]?[0-9]+$", options: .regularExpression))
            }
        }
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("0.000000000000909"))
    }

    @MainActor
    func testOptInRealEnglishSecondEditKeepsPopplerTextAndOutsidePixels() throws {
        guard let directory = ProcessInfo.processInfo.environment["EMBER_BODY_SOURCE_PDF_DIRECTORY"] else {
            throw XCTSkip("Set EMBER_BODY_SOURCE_PDF_DIRECTORY for the private English book regression.")
        }
        let textTool = "/opt/homebrew/bin/pdftotext", renderTool = "/opt/homebrew/bin/pdftoppm"
        guard FileManager.default.isExecutableFile(atPath: textTool),
              FileManager.default.isExecutableFile(atPath: renderTool) else { throw XCTSkip("Poppler is required.") }
        let source = URL(fileURLWithPath: directory).appendingPathComponent("Educated (Tara Westover) (Z-Library).pdf")
        let original = try XCTUnwrap(PDFDocument(url: source)), originalPage = try XCTUnwrap(original.page(at: 19))
        let selected = "making machine. It was bulky and bolted to an iron workstation in"
        let firstSelection = try XCTUnwrap(original.findString(selected, withOptions: []).first {
            $0.pages.contains { $0 === originalPage }
        })
        let firstTarget = try XCTUnwrap(PDFBodyTextEditor.target(on: originalPage, selection: firstSelection))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let before = temporary.appendingPathComponent("before.pdf"), after = temporary.appendingPathComponent("after.pdf")
        try PDFBodyTextPageSnapshot.originalPageData(for: originalPage).write(to: before)
        var current = original, page = originalPage, target = firstTarget
        var expectedTargetText = firstTarget.text
        var editedBounds: [CGRect] = []
        for (old, new) in [("and", "the"), ("the", "one")] {
            if current !== original {
                // A common word occurs elsewhere on the page. Re-edit only
                // the exact line changed by the previous transaction.
                let selection = try XCTUnwrap(current.findString(expectedTargetText, withOptions: []).first)
                target = try XCTUnwrap(PDFBodyTextEditor.target(on: page, selection: selection))
            }
            editedBounds.append(target.bounds)
            let revised = target.text.replacingOccurrences(of: old, with: new)
            expectedTargetText = revised
            let edited = try PDFBodyTextEditor.replacementPage(for: page, target: target,
                text: revised, style: target.style, bounds: target.bounds)
            let bytes = try PDFBodyTextPageSnapshot.originalPageData(for: edited)
            try bytes.write(to: after)
            current = try XCTUnwrap(PDFDocument(data: bytes)); page = try XCTUnwrap(current.page(at: 0))
        }
        let oldText = try externalText(before, executable: textTool, directory: temporary)
        let newText = try externalText(after, executable: textTool, directory: temporary)
        let normalized = oldText.filter { !$0.isWhitespace }, key = firstTarget.text.filter { !$0.isWhitespace }
        XCTAssertEqual(normalized.components(separatedBy: key).count, 2)
        XCTAssertEqual(newText.filter { !$0.isWhitespace }, normalized.replacingOccurrences(of: key,
            with: firstTarget.text.replacingOccurrences(of: "and", with: "one").filter { !$0.isWhitespace }))
        let firstImage = try render(before, executable: renderTool, directory: temporary, name: "before")
        let lastImage = try render(after, executable: renderTool, directory: temporary, name: "after")
        XCTAssertEqual(firstImage.pixelsWide, lastImage.pixelsWide)
        XCTAssertEqual(firstImage.pixelsHigh, lastImage.pixelsHigh)
        let a = try rgba(firstImage), b = try rgba(lastImage)
        let media = originalPage.bounds(for: .mediaBox)
        let scaleX = CGFloat(firstImage.pixelsWide) / media.width
        let scaleY = CGFloat(firstImage.pixelsHigh) / media.height
        var outside = 0, changed = 0
        for y in 0..<firstImage.pixelsHigh { for x in 0..<firstImage.pixelsWide {
            let index = (y * firstImage.pixelsWide + x) * 4
            if (0..<4).contains(where: { a[index + $0] != b[index + $0] }) {
                changed += 1
                // Antialiasing can affect a boundary pixel whose center lies
                // outside a text rectangle. Compare every pixel whose entire
                // area misses both actual transaction bounds; no extra margin.
                let pixel = CGRect(x: media.minX + CGFloat(x) / scaleX,
                    y: media.maxY - CGFloat(y + 1) / scaleY, width: 1 / scaleX, height: 1 / scaleY)
                if editedBounds.allSatisfy({ !$0.intersects(pixel) }) { outside += 1 }
            }
        } }
        XCTAssertGreaterThan(changed, 100)
        XCTAssertEqual(outside, 0, "A tiny inverse CTM component must not blank unrelated page text.")
        XCTAssertEqual(original.pageCount, 366)
        XCTAssertEqual(current.pageCount, 1)
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardError = error; process.standardOutput = Pipe()
        try process.run()
        let diagnostics = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostics, as: UTF8.self))
        XCTAssertFalse(String(decoding: diagnostics, as: UTF8.self).contains("Syntax Error"))
    }

    private func externalText(_ pdf: URL, executable: String, directory: URL) throws -> String {
        let text = directory.appendingPathComponent(pdf.deletingPathExtension().lastPathComponent + ".txt")
        try run(executable, ["-f", "1", "-l", "1", "-enc", "UTF-8", pdf.path, text.path])
        return try String(contentsOf: text, encoding: .utf8)
    }

    private func render(_ pdf: URL, executable: String, directory: URL, name: String) throws -> NSBitmapImageRep {
        let prefix = directory.appendingPathComponent(name)
        try run(executable, ["-f", "1", "-l", "1", "-singlefile", "-scale-to", "1600", "-png", pdf.path, prefix.path])
        return try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: prefix.appendingPathExtension("png"))))
    }

    private func rgba(_ image: NSBitmapImageRep) throws -> Data {
        let width = image.pixelsWide, height = image.pixelsHigh
        var data = Data(repeating: 255, count: width * height * 4)
        try data.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }
}
