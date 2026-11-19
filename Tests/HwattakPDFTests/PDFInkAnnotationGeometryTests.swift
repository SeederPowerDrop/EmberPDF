// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFInkAnnotationGeometryTests: XCTestCase {
    private let mediaBounds = CGRect(x: 13, y: 29, width: 310, height: 360)
    private let cropBounds = CGRect(x: 43, y: 71, width: 240, height: 260)
    private let points = [
        CGPoint(x: 75, y: 150), CGPoint(x: 195, y: 150),
        CGPoint(x: 195, y: 230), CGPoint(x: 235, y: 230)
    ]
    private let probes = [
        CGPoint(x: 110, y: 150), // A black page-content bar lies under this point.
        CGPoint(x: 165, y: 150), CGPoint(x: 195, y: 190), CGPoint(x: 218, y: 230)
    ]

    func testMouseInkKeepsAsymmetricPathPositionOverPageContentAfterCommitAndSave() throws {
        try assertCommittedAppearance(style: .ink, pressure: false)
    }

    func testPressureInkKeepsAsymmetricPathPositionOverPageContentAfterCommitAndSave() throws {
        try assertCommittedAppearance(style: .ink, pressure: true)
    }

    func testPencilKeepsAsymmetricPathPositionOverPageContentAfterCommitAndSave() throws {
        try assertCommittedAppearance(style: .pencil, pressure: false)
    }

    func testFountainPenKeepsAsymmetricPathPositionOverPageContentAfterCommitAndSave() throws {
        try assertCommittedAppearance(style: .fountain, pressure: false)
    }

    func testHighlighterKeepsAsymmetricPathPositionOverPageContentAfterCommitAndSave() throws {
        try assertCommittedAppearance(style: .highlighter, pressure: false)
    }

    private func assertCommittedAppearance(style: PDFInkStyle, pressure: Bool) throws {
        for offsetBoxes in [false, true] {
            try assertCommittedAppearance(style: style, pressure: pressure, offsetBoxes: offsetBoxes)
        }
    }

    private func assertCommittedAppearance(style: PDFInkStyle, pressure: Bool, offsetBoxes: Bool) throws {
        let mediaBounds = offsetBoxes ? self.mediaBounds : CGRect(origin: .zero, size: self.mediaBounds.size)
        let cropBounds = offsetBoxes ? self.cropBounds : CGRect(origin: .zero, size: self.cropBounds.size)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberPDF-Ink-Geometry-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for rotation in [0, 90, 180, 270] {
            let sourceURL = directory.appendingPathComponent("source-\(rotation).pdf")
            let sourceData = fixtureData(rotation: rotation, markers: false, offsetBoxes: offsetBoxes)
            try sourceData.write(to: sourceURL)
            let diagnosticName = "\(style)-\(pressure ? "pressure" : "mouse")-\(offsetBoxes ? "offset" : "zero")-rotation-\(rotation)"
            try dump(sourceData, named: "\(diagnosticName)-source.pdf")
            let state = PDFWorkspaceState()
            XCTAssertTrue(state.open(url: sourceURL))
            state.setMode(.editing)
            state.activeTool = .pen
            state.inkSettings.selectStyle(style)
            state.inkSettings.color = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
            state.inkSettings.width = 12
            let view = InteractivePDFView(frame: .zero)
            view.viewportContext = .normal
            view.configure(with: state)
            defer { view.workspaceState = nil }
            let document = try XCTUnwrap(state.document)
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertEqual(page.bounds(for: .mediaBox), mediaBounds)
            XCTAssertEqual(page.bounds(for: .cropBox), cropBounds)
            XCTAssertTrue(view.commitInkStroke(points, on: page,
                pressures: pressure ? [1, 1, 1, 1] : nil))
            XCTAssertEqual(page.annotations.count, 1)

            // The oracle is ordinary PDF page content, not a second annotation
            // or the production coordinate-conversion code. Asymmetric probes
            // catch vertical mirroring and shifts that horizontal test strokes
            // on origin-zero pages can hide.
            let reference = try fixture(rotation: rotation, markers: true, offsetBoxes: offsetBoxes,
                includeBlackProbe: style != .highlighter)
            let referencePage = try XCTUnwrap(reference.page(at: 0))
            try dump(fixtureData(rotation: rotation, markers: true, offsetBoxes: offsetBoxes,
                includeBlackProbe: style != .highlighter), named: "\(diagnosticName)-reference.pdf")
            for box in [PDFDisplayBox.mediaBox, .cropBox] {
                let oracle = try bitmap(page: referencePage, box: box)
                let actual = try bitmap(page: page, box: box)
                try dump(oracle.representation(using: .png, properties: [:]), named: "\(diagnosticName)-box-\(box.rawValue)-reference.png")
                try dump(actual.representation(using: .png, properties: [:]), named: "\(diagnosticName)-box-\(box.rawValue)-live.png")
                let probePixels = try markerPixels(in: oracle)
                XCTAssertGreaterThanOrEqual(probePixels.count, style == .highlighter ? 12 : 16,
                    "The page-content oracle must be visible")
                try assertVisibleRedInk(actual, at: probePixels,
                    context: "live \(style), rotation \(rotation), box \(box), offset \(offsetBoxes)")
            }

            let savedData = try XCTUnwrap(document.dataRepresentation())
            try dump(savedData, named: "\(diagnosticName)-saved.pdf")
            let reopened = try XCTUnwrap(PDFDocument(data: savedData))
            let reopenedPage = try XCTUnwrap(reopened.page(at: 0))
            XCTAssertEqual(reopenedPage.rotation, rotation)
            // PDFKit may normalize MediaBox to origin zero when writing. Its
            // content and annotations must move together, preserving the crop
            // offset and the visible ink position.
            let savedMedia = reopenedPage.bounds(for: .mediaBox)
            let savedCrop = reopenedPage.bounds(for: .cropBox)
            XCTAssertEqual(savedMedia.size, mediaBounds.size)
            XCTAssertEqual(savedCrop.size, cropBounds.size)
            XCTAssertEqual(savedCrop.minX - savedMedia.minX, cropBounds.minX - mediaBounds.minX)
            XCTAssertEqual(savedCrop.minY - savedMedia.minY, cropBounds.minY - mediaBounds.minY)
            XCTAssertEqual(reopenedPage.annotations.count, 1)
            for box in [PDFDisplayBox.mediaBox, .cropBox] {
                let probePixels = try markerPixels(in: bitmap(page: referencePage, box: box))
                let actual = try bitmap(page: reopenedPage, box: box)
                try dump(actual.representation(using: .png, properties: [:]), named: "\(diagnosticName)-box-\(box.rawValue)-saved.png")
                try assertVisibleRedInk(actual, at: probePixels,
                    context: "saved \(style), rotation \(rotation), box \(box), offset \(offsetBoxes)")
            }
        }
    }

    private func fixture(rotation: Int, markers: Bool, offsetBoxes: Bool, includeBlackProbe: Bool = true) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: fixtureData(rotation: rotation, markers: markers,
            offsetBoxes: offsetBoxes, includeBlackProbe: includeBlackProbe)))
    }

    private func fixtureData(rotation: Int, markers: Bool, offsetBoxes: Bool, includeBlackProbe: Bool = true) -> Data {
        // Write the fixture directly. PDFKit.write normalizes a nonzero media
        // origin, which would otherwise change the intended input coordinates
        // before the test even calls the production commit method.
        let media = offsetBoxes ? mediaBounds : CGRect(origin: .zero, size: mediaBounds.size)
        let crop = offsetBoxes ? cropBounds : CGRect(origin: .zero, size: cropBounds.size)
        var content = "1 1 1 rg \(media.minX) \(media.minY) \(media.width) \(media.height) re f\n"
        if markers {
            content += "0 1 0 rg\n"
            for point in includeBlackProbe ? probes[...] : probes.dropFirst() {
                content += "\(point.x - 1.5) \(point.y - 1.5) 3 3 re f\n"
            }
        } else {
            // Opaque page content distinguishes correct annotation compositing
            // from a stroke rendered behind the original PDF text or graphics.
            content += "0 0 0 rg 85 137 50 26 re f\n"
        }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [\(media.minX) \(media.minY) \(media.maxX) \(media.maxY)] /CropBox [\(crop.minX) \(crop.minY) \(crop.maxX) \(crop.maxY)] /Rotate \(rotation) /Resources << >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream"
        ]
        var pdf = "%PDF-1.7\n"
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    private func dump(_ data: Data?, named name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["EMBER_INK_QA_DIRECTORY"],
              let data else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name))
    }

    private func bitmap(page: PDFPage, box: PDFDisplayBox) throws -> NSBitmapImageRep {
        // A generous square keeps all rotated crop/media extents visible. Both
        // PDFs are drawn through the same public PDFPage.draw API.
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 420, pixelsHigh: 420, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        graphics.cgContext.setFillColor(NSColor.white.cgColor)
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: 420, height: 420))
        page.draw(with: box, to: graphics.cgContext)
        graphics.flushGraphics()
        return bitmap
    }

    private func markerPixels(in bitmap: NSBitmapImageRep) throws -> [CGPoint] {
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        var points: [CGPoint] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * 4
                guard bytes[offset] < 32, bytes[offset + 1] > 230, bytes[offset + 2] < 32 else { continue }
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.greenComponent > 0.9 && color.redComponent < 0.1 && color.blueComponent < 0.1 {
                    points.append(CGPoint(x: x, y: y))
                }
            }
        }
        return points
    }

    private func assertVisibleRedInk(_ bitmap: NSBitmapImageRep, at probes: [CGPoint],
                                     context: String, file: StaticString = #filePath, line: UInt = #line) throws {
        for point in probes {
            let color = try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: Int(point.y))?
                .usingColorSpace(.deviceRGB), file: file, line: line)
            XCTAssertGreaterThan(color.redComponent - color.greenComponent, 0.1,
                "Ink must cover its original page-coordinate probe \(point): \(context)", file: file, line: line)
        }
    }
}
