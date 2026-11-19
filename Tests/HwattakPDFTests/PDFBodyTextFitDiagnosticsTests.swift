// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFBodyTextFitDiagnosticsTests: XCTestCase {
    private typealias D = PDFBodyTextFitDiagnostics
    private enum InvalidFrames: Error { case invalid }

    func testSmallEventIsStandaloneJSONAndRoundTripsExactly() throws {
        let value = D.payload(.rendererWidth, bounds: CGRect(x: 1, y: 2, width: 3, height: 4), width: 0)
        let frames = try XCTUnwrap(D.logFrames(value, eventID: 1))
        XCTAssertEqual(frames.count, 1)
        try assertRoundTrip(value, frames)
    }

    func testCoreLargerThanOneMessageSplitsWithoutRoundingGeometry() throws {
        let value = largeGeometry()
        XCTAssertGreaterThan(try XCTUnwrap(D.encodedEvent(value)).count, D.maximumLogMessageBytes)
        let frames = try XCTUnwrap(D.logFrames(value, eventID: 16))
        XCTAssertGreaterThan(frames.count, 1)
        XCTAssertTrue(try objects(frames).allSatisfy { $0["section"] as? String == "core" })
        try assertRoundTrip(value, frames)
        let rebuilt = try reassemble(Array(frames.reversed()))
        XCTAssertEqual(D.encodedEvent(rebuilt), D.encodedEvent(value), "Part indices recover a reordered log export.")
    }

    func testEightFontProbesRemainSeparateFromCoreAndRecoverExactly() throws {
        var value = largeGeometry()
        value["fontRunCount"] = 12
        value["fontProbesTruncated"] = true
        value["fontProbes"] = probes(8)
        let frames = try XCTUnwrap(D.logFrames(value, eventID: 9))
        let envelopes = try objects(frames)
        XCTAssertEqual(Set(envelopes.compactMap { $0["section"] as? String }), ["core", "fonts"])
        XCTAssertGreaterThan(envelopes.filter { $0["section"] as? String == "fonts" }.count, 1)
        for envelope in envelopes where envelope["section"] as? String == "core" {
            XCTAssertNil((envelope["payload"] as? [String: Any])?["fontProbes"])
        }
        try assertRoundTrip(value, frames)
    }

    func testEmptyProbeArrayIsDistinctFromAbsentProbeField() throws {
        var value = D.payload(.rendererWidth, bounds: .zero)
        let absent = try XCTUnwrap(D.logFrames(value, eventID: 1))
        XCTAssertNil(try reassemble(absent)["fontProbes"])
        value["fontProbes"] = [[String: Any]]()
        let empty = try XCTUnwrap(D.logFrames(value, eventID: 2))
        XCTAssertEqual((try reassemble(empty)["fontProbes"] as? [[String: Any]])?.count, 0)
        try assertRoundTrip(value, empty)
    }

    func testUTF8ByteBudgetCountsEncodedBytesRatherThanCharacters() throws {
        // Pure transport adversary; production payload() never accepts user text.
        var value = D.payload(.rendererWidth, bounds: .zero)
        value["syntheticA"] = String(repeating: "界", count: 160)
        value["syntheticB"] = String(repeating: "🙂", count: 120)
        let frames = try XCTUnwrap(D.logFrames(value, eventID: 1))
        XCTAssertGreaterThan(frames.count, 1)
        try assertRoundTrip(value, frames)
        value["oversizedAtomicValue"] = String(repeating: "界", count: 400)
        XCTAssertNil(D.logFrames(value, eventID: 1), "An indivisible oversized field must emit no partial frame set.")
    }

    func testOriginalAndTransportByteCapsBothRemainBounded() throws {
        var oversized = D.payload(.rendererWidth, bounds: .zero)
        oversized["synthetic"] = String(repeating: "x", count: D.maximumEventBytes)
        XCTAssertNil(D.encodedEvent(oversized))
        XCTAssertNil(D.logFrames(oversized, eventID: 1))
        var transportHeavy = D.payload(.rendererWidth, bounds: .zero)
        for index in 0..<45 { transportHeavy["synthetic\(index)"] = String(repeating: "x", count: 300) }
        XCTAssertNotNil(D.encodedEvent(transportHeavy), "The unframed event must fit to exercise transport overhead.")
        XCTAssertNil(D.logFrames(transportHeavy, eventID: 1), "All logger frames together retain the 16 KiB cap.")
    }

    func testEventIDsAndSixteenRefusalBudgetRemainBounded() throws {
        let value = D.payload(.rendererWidth, bounds: .zero)
        for id in [Int.min, -1, 0, 17, Int.max] { XCTAssertNil(D.logFrames(value, eventID: id)) }
        for id in 1...16 { XCTAssertNotNil(D.logFrames(value, eventID: id)) }
        XCTAssertFalse(D.hasBudget(emittedCount: -1))
        XCTAssertTrue(D.hasBudget(emittedCount: 0))
        XCTAssertTrue(D.hasBudget(emittedCount: 15))
        XCTAssertFalse(D.hasBudget(emittedCount: 16))
        XCTAssertEqual(D.maximumEventBytes, 16_384)
        XCTAssertEqual(D.maximumLogMessageBytes, 900)
    }

    func testNullAndNonfiniteGeometryRoundTripsWithoutJSONFailure() throws {
        let value = D.payload(.rendererWidth,
            bounds: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1), visible: .null,
            paintExtent: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1), width: CGFloat.nan)
        let frames = try XCTUnwrap(D.logFrames(value, eventID: 1))
        let rebuilt = try reassemble(frames)
        for key in ["boundsXYXY", "visibleXYXY", "paintExtentXYXY", "layoutWidth"] {
            XCTAssertTrue(rebuilt[key] is NSNull)
        }
        try assertRoundTrip(value, frames)
    }

    func testReassemblyRejectsMissingDuplicateAndCrossEventParts() throws {
        var value = largeGeometry()
        value["fontProbes"] = probes(8)
        let frames = try XCTUnwrap(D.logFrames(value, eventID: 1))
        XCTAssertGreaterThan(frames.count, 2)
        XCTAssertThrowsError(try reassemble(Array(frames.dropLast())))
        XCTAssertThrowsError(try reassemble(frames + [frames[0]]))
        let other = try XCTUnwrap(D.logFrames(value, eventID: 2))
        XCTAssertThrowsError(try reassemble([other[0]] + Array(frames.dropFirst())))
        let coreOnly = try zip(frames, objects(frames)).filter { $0.1["section"] as? String == "core" }.map(\.0)
        XCTAssertThrowsError(try reassemble(coreOnly), "The section count detects a wholly missing font section.")
    }

    func testInvalidFontShapeOrCountAndUnknownBranchAreRefused() throws {
        var value = D.payload(.rendererWidth, bounds: .zero)
        value["fontProbes"] = probes(9)
        XCTAssertNil(D.logFrames(value, eventID: 1))
        value["fontProbes"] = "not a probe array"
        XCTAssertNil(D.logFrames(value, eventID: 1))
        value.removeValue(forKey: "fontProbes")
        value["branch"] = "unknown"
        XCTAssertNil(D.logFrames(value, eventID: 1))
    }

    func testFramingKeepsDefaultOffAndExistingOptInGate() {
        XCTAssertFalse(D.isEligible(environmentValue: nil, bundleIdentifier: "com.vibepdf.mac", qaInfoValue: nil))
        XCTAssertFalse(D.isEligible(environmentValue: nil, bundleIdentifier: "com.vibepdf.mac", qaInfoValue: true))
        XCTAssertFalse(D.isEligible(environmentValue: nil, bundleIdentifier: "com.vibepdf.mac.releaseqa.x", qaInfoValue: "true"))
        XCTAssertTrue(D.isEligible(environmentValue: nil, bundleIdentifier: "com.vibepdf.mac.releaseqa.x", qaInfoValue: true))
        XCTAssertTrue(D.isEligible(environmentValue: "1", bundleIdentifier: "com.vibepdf.mac", qaInfoValue: nil))
    }

    func testGeneratedSchemaAddsNoDocumentTextPathsOrFontNames() throws {
        var value = largeGeometry()
        value["fontProbes"] = probes(8)
        let frames = try XCTUnwrap(D.logFrames(value, eventID: 1))
        let rebuilt = try reassemble(frames)
        XCTAssertEqual(Set(rebuilt.keys), Set(value.keys))
        for frame in frames {
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
            XCTAssertEqual(Set(envelope.keys), ["frameSchema", "eventID", "branch", "section", "part", "parts", "sectionCount", "eventBytes", "payload"])
            let string = try XCTUnwrap(String(data: frame, encoding: .utf8))
            for forbidden in ["text", "fontName", "filePath", "glyphID", "Helvetica", "/Users/"] {
                XCTAssertFalse(string.contains(forbidden))
            }
        }
        XCTAssertTrue(rebuilt["originalFontIdentityVerified"] is NSNull)
        XCTAssertEqual(rebuilt["originalFontIdentityStatus"] as? String, "notMeasured")
    }

    func testPaintObservationDistinguishesMissingProofAndRejectedUnderlay() throws {
        let missing = D.PaintObservation(plan: .missing, selectedObjects: 3)
        XCTAssertEqual(missing.payload["paintPlan"] as? String, "missing")
        XCTAssertEqual(missing.payload["paintAudit"] as? String, "notRequested")
        var available = D.PaintObservation(plan: .wholeBlock, selectedObjects: 3)
        available.observedAudit(nestedUnsafe: false, unsupportedPaint: false,
            occlusionUnsafe: false, explicitClip: true, textClip: false, pageClipsOnly: false)
        available.increment(.precedingPaint)
        available.increment(.underlayEligible)
        available.increment(.otherPaths)
        available.increment(.overlappingOtherPaint)
        available.clamped(left: true, bottom: true, right: true, top: true)
        let source = CGRect(x: 20, y: 30, width: 40, height: 10)
        available.finish(source: source, declared: source, savedExtent: false)
        let value = D.payload(.rendererPaintExtent, bounds: source, paintObservation: available)
        XCTAssertEqual(value["paintAuditFlags"] as? Int, 8)
        XCTAssertEqual(value["paintCount_underlayEligible"] as? Int, 1)
        XCTAssertEqual(value["paintCount_underlayRectangleAccepted"] as? Int, 0)
        XCTAssertEqual(value["paintClampedEdges"] as? Int, 15)
        XCTAssertEqual(value["paintSourceEdges"] as? Int, 15)
        try assertRoundTrip(value, XCTUnwrap(D.logFrames(value, eventID: 1)))
    }

    func testPaintObservationReportsAcceptedCoverageAndClampingSeparately() throws {
        var observation = D.PaintObservation(plan: .shows, selectedObjects: 1)
        observation.unavailableAudit()
        XCTAssertEqual(observation.payload["paintAudit"] as? String, "unavailable")
        observation.observedAudit(nestedUnsafe: true, unsupportedPaint: true,
            occlusionUnsafe: true, explicitClip: true, textClip: true, pageClipsOnly: true)
        XCTAssertEqual(observation.payload["paintAuditFlags"] as? Int, 63)
        observation.increment(.underlayEligible)
        observation.increment(.underlayRectangleAccepted)
        observation.increment(.underlayAccepted)
        observation.clamped(left: false, bottom: false, right: true, top: false)
        observation.clamped(left: false, bottom: false, right: false, top: true)
        observation.finish(source: CGRect(x: 10, y: 10, width: 10, height: 10),
            declared: CGRect(x: 0, y: 0, width: 20, height: 20), savedExtent: true)
        XCTAssertEqual(observation.payload["paintClampedEdges"] as? Int, 12)
        XCTAssertEqual(observation.payload["paintSourceEdges"] as? Int, 12)
        XCTAssertEqual(observation.payload["paintUsesSavedExtent"] as? Bool, true)
        XCTAssertEqual(observation.payload["paintCount_underlayAccepted"] as? Int, 1)
    }

    func testPaintObservationCountersSaturateAndFitExistingTransportBudget() throws {
        var observation = D.PaintObservation(plan: .mixed, selectedObjects: Int.max)
        for _ in 0...D.PaintObservation.maximumCount { observation.increment(.otherPaths) }
        XCTAssertEqual(observation.payload["paintCount_selectedObjects"] as? Int, 250_000)
        XCTAssertEqual(observation.payload["paintCount_otherPaths"] as? Int, 250_000)
        XCTAssertEqual(D.PaintObservation(plan: .missing, selectedObjects: Int.min)
            .payload["paintCount_selectedObjects"] as? Int, 0)
        var value = largeGeometry()
        value.merge(observation.payload) { _, new in new }
        value["fontProbes"] = probes(8)
        let frames = try XCTUnwrap(D.logFrames(value, eventID: 16))
        try assertRoundTrip(value, frames)
        XCTAssertEqual(Set(observation.payload.keys), Set(D.PaintCount.allCases.map { "paintCount_" + $0.rawValue })
            .union(["paintPlan", "paintAudit", "paintAuditFlags", "paintClampedEdges", "paintSourceEdges", "paintUsesSavedExtent"]))
        for key in observation.payload.keys {
            XCTAssertFalse(["fontName", "filePath", "glyphID", "text"].contains { key.contains($0) })
        }
    }

    private final class PrivateDiagnosticFailure: Error, LocalizedError, CustomStringConvertible, @unchecked Sendable {
        private(set) var descriptionReads = 0
        var errorDescription: String? {
            descriptionReads += 1
            return "PRIVATE-DIAGNOSTIC-TEXT /private/owned-fixture.pdf"
        }
        var description: String {
            descriptionReads += 1
            return "PRIVATE-DIAGNOSTIC-TEXT /private/owned-fixture.pdf"
        }
    }

    func testReplacementPhaseSuccessExecutesBodyExactlyOnce() {
        var calls = 0
        let expected = NSObject()
        let result = D.withReplacementPhase(.donorGeneration) {
            calls += 1
            return expected
        }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(result === expected)
    }

    func testReplacementPhaseFailureRethrowsIdenticalErrorOnce() {
        var calls = 0
        let expected = PrivateDiagnosticFailure()
        do {
            let _: Int = try D.withReplacementPhase(.losslessRewrite) {
                calls += 1
                throw expected
            }
            XCTFail("The original throwing body must remain a failure.")
        } catch {
            XCTAssertTrue((error as? PrivateDiagnosticFailure) === expected)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(expected.descriptionReads, 0)
    }

    func testFailureClassifierNeverReadsPrivateDescriptionsOrAddsPayload() throws {
        let error = PrivateDiagnosticFailure()
        let replacement = D.replacementFailurePayload(.sourceSnapshot, error: error)
        XCTAssertEqual(Set(replacement.keys), ["schema", "kind", "replacementPhase", "failureCode"])
        XCTAssertEqual(replacement["failureCode"] as? String, "unclassified")
        let commit = D.applyFailurePayload(.pageTransactionApply, error: error)
        XCTAssertEqual(Set(commit.keys), ["schema", "kind", "phase", "failureCode"])
        XCTAssertEqual(commit["failureCode"] as? String, "unclassified")
        XCTAssertEqual(D.applyFailurePayload(.pageTransactionPreparation,
            error: PDFPageStructurePreserver.Failure.invalidCopy)["failureCode"] as? String,
            "pageStructure.invalidCopy")
        XCTAssertEqual(D.replacementFailurePayload(.nativeResolve,
            error: CancellationError())["failureCode"] as? String, "cancelled")
        for payload in [replacement, commit] {
            let data = try XCTUnwrap(D.encodedEvent(payload))
            XCTAssertLessThanOrEqual(data.count, D.maximumLogMessageBytes)
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(json.contains("PRIVATE-DIAGNOSTIC-TEXT"))
            XCTAssertFalse(json.contains("/private/owned-fixture.pdf"))
        }
        XCTAssertEqual(error.descriptionReads, 0)
    }

    private func largeGeometry() -> [String: Any] {
        let area = CGRect(x: -1.234567890123456e100, y: -2.345678901234567e100,
                          width: 4.567890123456789e100, height: 6.789012345678901e100)
        return D.payload(.rendererTextObstacle, bounds: area, visible: area, paintExtent: area,
            ink: area.insetBy(dx: -1.23456789012345e90, dy: -2.34567890123456e90), layout: area,
            width: 391.281982421875, lineHeight: 15.000001192092896, lineIndex: 1, lineCount: 3,
            expectedLineCount: 3, retainedCount: 2, lineRetained: false,
            obstacleIndex: 4, obstacleCount: 5, obstacle: area)
    }

    private func probes(_ count: Int) -> [[String: Any]] {
        var result: [[String: Any]] = []
        let matrix: [Double] = [1.23456789012345, 0, 0, 1.34567890123456, 0, 0]
        for index in 0..<count {
            var probe: [String: Any] = [:]
            probe["actualFontPresent"] = true
            probe["pointSize"] = 15.000001192092896 + Double(index)
            probe["fontMatrix"] = matrix
            probe["coreTextFallbackFromDeclaredFace"] = index % 2 == 0
            probe["differentBackingFromPrimaryPreferred"] = index % 2 != 0
            result.append(probe)
        }
        return result
    }

    private func objects(_ frames: [Data]) throws -> [[String: Any]] {
        try frames.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
    }

    private func assertRoundTrip(_ value: [String: Any], _ frames: [Data]) throws {
        XCTAssertLessThanOrEqual(frames.count, D.maximumLogParts)
        XCTAssertLessThanOrEqual(frames.reduce(0) { $0 + $1.count }, D.maximumEventBytes)
        for frame in frames { XCTAssertLessThanOrEqual(frame.count, D.maximumLogMessageBytes) }
        XCTAssertEqual(D.encodedEvent(try reassemble(frames)), D.encodedEvent(value), "No coordinate rounding or field loss.")
    }

    /// Independent test decoder rejects incomplete or mixed logger exports.
    private func reassemble(_ frames: [Data]) throws -> [String: Any] {
        guard !frames.isEmpty, frames.count <= D.maximumLogParts,
              frames.reduce(0, { $0 + $1.count }) <= D.maximumEventBytes,
              frames.allSatisfy({ $0.count <= D.maximumLogMessageBytes }) else { throw InvalidFrames.invalid }
        let envelopes = try objects(frames)
        let first = envelopes[0]
        guard let eventID = first["eventID"] as? Int, (1...16).contains(eventID),
              let branch = first["branch"] as? String, D.Branch(rawValue: branch) != nil,
              let sectionCount = first["sectionCount"] as? Int, (1...2).contains(sectionCount),
              let eventBytes = first["eventBytes"] as? Int, (1...16_384).contains(eventBytes) else { throw InvalidFrames.invalid }
        var sections: [String: [Int: [String: Any]]] = [:]
        var totals: [String: Int] = [:]
        for envelope in envelopes {
            guard envelope["frameSchema"] as? Int == 1, envelope["eventID"] as? Int == eventID,
                  envelope["branch"] as? String == branch, envelope["sectionCount"] as? Int == sectionCount,
                  envelope["eventBytes"] as? Int == eventBytes,
                  let section = envelope["section"] as? String, ["core", "fonts"].contains(section),
                  let part = envelope["part"] as? Int, let parts = envelope["parts"] as? Int,
                  (1...D.maximumLogParts).contains(parts), (1...parts).contains(part),
                  let payload = envelope["payload"] as? [String: Any],
                  sections[section]?[part] == nil, totals[section].map({ $0 == parts }) ?? true else { throw InvalidFrames.invalid }
            totals[section] = parts
            sections[section, default: [:]][part] = payload
        }
        guard sections.count == sectionCount, let core = sections["core"] else { throw InvalidFrames.invalid }
        for (section, chunks) in sections {
            guard let total = totals[section], Set(chunks.keys) == Set(1...total) else { throw InvalidFrames.invalid }
        }
        var result: [String: Any] = [:]
        for index in 1...totals["core"]! {
            for (key, value) in core[index]! {
                guard result[key] == nil, key != "fontProbes" else { throw InvalidFrames.invalid }
                result[key] = value
            }
        }
        if let chunks = sections["fonts"] {
            var fonts: [[String: Any]] = []
            for index in 1...totals["fonts"]! {
                guard Set(chunks[index]!.keys) == ["fontProbes"],
                      let values = chunks[index]!["fontProbes"] as? [[String: Any]] else { throw InvalidFrames.invalid }
                fonts.append(contentsOf: values)
            }
            guard fonts.count <= D.maximumFontRuns else { throw InvalidFrames.invalid }
            result["fontProbes"] = fonts
        }
        guard result["branch"] as? String == branch, D.encodedEvent(result)?.count == eventBytes else { throw InvalidFrames.invalid }
        return result
    }
}
