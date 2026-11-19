// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

/// Preexisting CG-exact fractional success. NOT a ULP-mismatch reproducer.
@MainActor
final class PDFInkCGMatchingFractionalTests: XCTestCase {
    func testCGMatchingFractionalNamedInkSaveKeepsChosenProgramAndName() async throws {
        let fixture = try InkNameRoundingTestFixture.make()
        try PDFCatalogStructurePreserver.prepare(fixture.document, force: true)
        let page = try XCTUnwrap(fixture.document.page(at: 0)), ink = try XCTUnwrap(page.annotations.first)
        let current = try PDFPageGeometryPreserver.liveAnnotation(ink)
        let originalStage = try InkNameRoundingTestFixture.stage(fixture.data)
        defer { withExtendedLifetime(originalStage.owner) {} }
        let original = try PDFPageGeometryPreserver.rawAnnotation(originalStage.first)
        let plan = try PDFCatalogStructurePreserver.plan(for: fixture.document)
        let chosen = try XCTUnwrap(plan.annotationGeometry[0]?[0])
        XCTAssertEqual(chosen, original, "The preexisting unchanged-annotation resolver already selects original geometry.")
        XCTAssertEqual(current, chosen,
                       "Preexisting ordinary CG success: current and selected programs match exactly.")
        let liveValues = InkNameRoundingTestFixture.values(try XCTUnwrap(current.coordinates["InkList"]))
        let chosenValues = InkNameRoundingTestFixture.values(try XCTUnwrap(chosen.coordinates["InkList"]))
        XCTAssertEqual(InkNameRoundingTestFixture.bits(liveValues), InkNameRoundingTestFixture.bits(chosenValues))
        XCTAssertEqual(try PDFPageGeometryPreserver.annotation(ink, original: original, baseline: current), original)
        let expected = InkNameRoundingTestFixture.values(try XCTUnwrap(chosen.coordinates["InkList"]))
        XCTAssertEqual(expected.count, 6, "Exactly three synthetic points.")
        let snapshot = try PDFRecoverySnapshot(capturing: fixture.document)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ink-ULP-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("saved.pdf")
        let saved = try await Task.detached {
            try AtomicPDFWriter.write(snapshot.takeDocument(), to: output)
            return try Data(contentsOf: output)
        }.value
        let observed = try InkNameRoundingTestFixture.stored(saved)
        XCTAssertEqual(observed.name, InkNameRoundingTestFixture.name)
        XCTAssertEqual(InkNameRoundingTestFixture.bits(observed.ink), InkNameRoundingTestFixture.bits(expected),
                       "Compare writer's chosen program exactly through a second reader; no epsilon.")
        XCTAssertEqual(try PDFPageGeometryPreserver.liveAnnotation(ink), current)
        XCTAssertEqual(ink.value(forAnnotationKey: .init(rawValue: "/NM")) as? String, "synthetic-three-point-ink")
    }

}
