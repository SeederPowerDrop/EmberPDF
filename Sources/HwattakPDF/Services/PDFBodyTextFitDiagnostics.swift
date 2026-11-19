// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import Foundation
import OSLog

/// Opt-in, bounded refusal telemetry. Never supplies editing authority, changes
/// a fit decision, or serializes document text, paths, font names, or glyph IDs.
@MainActor
enum PDFBodyTextFitDiagnostics {
    enum Branch: String, CaseIterable {
        case scannedInitialEnvelope
        case scannedReeditEnvelope
        case outlinedNoLines
        case outlinedLineCapacity
        case outlinedEnvelope
        case outlinedTextPageUnavailable
        case rendererWidth
        case rendererVisibleBounds
        case rendererPaintExtent
        case rendererTextObstacle
        case rendererBackgroundObstacle
    }

    enum PaintPlan: String { case missing, shows, wholeBlock, ownForm, mixed }
    enum PaintAudit: String { case notRequested, unavailable, available }
    enum PaintCount: String, CaseIterable {
        case selectedObjects, precedingPaint, selectedFormsOmitted
        case underlayEligible, underlayRectangleAccepted, underlayAccepted, laterOpaqueAccepted
        case otherPaths, otherImages, otherForms, otherShadings, otherUnknown
        case overlappingOtherPaint, overlappingOtherText
    }

    /// Ephemeral observations of already-executed decisions, never authority.
    /// No object indices, resource/font names, PDF strings, or per-object arrays.
    struct PaintObservation {
        static let maximumCount = 250_000
        let plan: PaintPlan
        private(set) var audit: PaintAudit = .notRequested
        private(set) var auditFlags = 0
        private(set) var clampedEdges = 0
        private(set) var sourceEdges = 0
        private(set) var usesSavedExtent = false
        private var counts: [PaintCount: Int] = [:]

        init(plan: PaintPlan, selectedObjects: Int) {
            self.plan = plan
            counts[.selectedObjects] = min(Self.maximumCount, max(0, selectedObjects))
        }
        mutating func increment(_ key: PaintCount) {
            let old = counts[key, default: 0]
            counts[key] = old < Self.maximumCount ? old + 1 : Self.maximumCount
        }
        mutating func unavailableAudit() { audit = .unavailable }
        // Bits: nested compositing=1, unsupported paint=2, unsafe occlusion=4,
        // explicit clip=8, text clip=16, page-covering clips only=32.
        mutating func observedAudit(nestedUnsafe: Bool, unsupportedPaint: Bool,
            occlusionUnsafe: Bool, explicitClip: Bool, textClip: Bool, pageClipsOnly: Bool) {
            audit = .available
            auditFlags = (nestedUnsafe ? 1 : 0) | (unsupportedPaint ? 2 : 0)
                | (occlusionUnsafe ? 4 : 0) | (explicitClip ? 8 : 0)
                | (textClip ? 16 : 0) | (pageClipsOnly ? 32 : 0)
        }
        /// Edge bits: left=1, bottom=2, right=4, top=8.
        mutating func clamped(left: Bool, bottom: Bool, right: Bool, top: Bool) {
            clampedEdges |= (left ? 1 : 0) | (bottom ? 2 : 0) | (right ? 4 : 0) | (top ? 8 : 0)
        }
        mutating func finish(source: CGRect, declared: CGRect, savedExtent: Bool) {
            sourceEdges = (source.minX == declared.minX ? 1 : 0)
                | (source.minY == declared.minY ? 2 : 0)
                | (source.maxX == declared.maxX ? 4 : 0)
                | (source.maxY == declared.maxY ? 8 : 0)
            usesSavedExtent = savedExtent
        }
        var payload: [String: Any] {
            var value: [String: Any] = ["paintPlan": plan.rawValue, "paintAudit": audit.rawValue,
                "paintAuditFlags": auditFlags, "paintClampedEdges": clampedEdges,
                "paintSourceEdges": sourceEdges, "paintUsesSavedExtent": usesSavedExtent]
            for key in PaintCount.allCases { value["paintCount_" + key.rawValue] = counts[key, default: 0] }
            return value
        }
    }

    /// Default-off creation avoids even counter allocation in normal builds.
    static func beginPaintObservation(plan: PaintPlan, selectedObjects: Int) -> PaintObservation? {
        enabled && hasBudget(emittedCount: emitted)
            ? PaintObservation(plan: plan, selectedObjects: selectedObjects) : nil
    }

    static let maximumEvents = 16
    static let maximumFontRuns = 8
    static let maximumEventBytes = 16 * 1024
    static let maximumLogMessageBytes = 900
    static let maximumLogParts = 64
    private static let enabled = isEligible(
        environmentValue: ProcessInfo.processInfo.environment["EMBER_QA_BODY_FIT_DIAGNOSTICS"],
        bundleIdentifier: Bundle.main.bundleIdentifier,
        qaInfoValue: Bundle.main.object(forInfoDictionaryKey: "EmberQABodyFitDiagnostics"))
    private static let logger = Logger(subsystem: "com.vibepdf.mac", category: "body-fit-diagnostics")
    private static var emitted = 0

    /// QA Info activation requires both a QA bundle identity and a real plist
    /// Boolean. Explicit per-process environment activation remains independent.
    static func isEligible(environmentValue: String?, bundleIdentifier: String?, qaInfoValue: Any?) -> Bool {
        if environmentValue == "1" { return true }
        guard bundleIdentifier?.hasPrefix("com.vibepdf.mac.releaseqa") == true,
              let value = qaInfoValue as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }

    static func hasBudget(emittedCount: Int) -> Bool { (0..<maximumEvents).contains(emittedCount) }

    static func encodedEvent(_ payload: [String: Any]) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              data.count <= maximumEventBytes else { return nil }
        return data
    }

    /// Unified logging can truncate an interpolated string at about 1 KiB.
    /// Frame only the already-sanitized event, measuring serialized UTF-8 bytes.
    /// Every message is standalone JSON; geometry values are never rounded.
    /// The whole frame set is prepared before output, so an oversized field or
    /// transport budget failure cannot leave a partially emitted event.
    static func logFrames(_ payload: [String: Any], eventID: Int) -> [Data]? {
        guard (1...maximumEvents).contains(eventID),
              let event = encodedEvent(payload),
              let branch = payload["branch"] as? String, Branch(rawValue: branch) != nil else { return nil }
        var core = payload
        let fontValue = core.removeValue(forKey: "fontProbes")
        let fonts: [[String: Any]]?
        if let fontValue {
            guard let values = fontValue as? [[String: Any]], values.count <= maximumFontRuns else { return nil }
            fonts = values
        } else { fonts = nil }
        let sectionCount = fonts == nil ? 1 : 2
        func frame(section: String, part: Int, parts: Int, value: [String: Any]) -> Data? {
            let envelope: [String: Any] = ["frameSchema": 1, "eventID": eventID,
                "branch": branch, "section": section, "part": part, "parts": parts,
                "sectionCount": sectionCount, "eventBytes": event.count, "payload": value]
            guard let bytes = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]),
                  bytes.count <= maximumLogMessageBytes else { return nil }
            return bytes
        }
        // Reserve the maximum two-digit part indices while grouping. Actual
        // indices can only make the final envelope smaller.
        func fits(_ value: [String: Any], section: String) -> Bool {
            frame(section: section, part: maximumLogParts, parts: maximumLogParts, value: value) != nil
        }
        var coreGroups: [[String: Any]] = []
        var group: [String: Any] = [:]
        for key in core.keys.sorted() {
            var next = group
            next[key] = core[key]
            if fits(next, section: "core") { group = next; continue }
            guard !group.isEmpty else { return nil }
            coreGroups.append(group)
            group = [key: core[key]!]
            guard fits(group, section: "core") else { return nil }
        }
        if !group.isEmpty { coreGroups.append(group) }
        var sections: [(String, [[String: Any]])] = [("core", coreGroups)]
        if let fonts {
            var groups: [[String: Any]] = []
            var selected: [[String: Any]] = []
            for probe in fonts {
                let next = selected + [probe]
                if fits(["fontProbes": next], section: "fonts") { selected = next; continue }
                guard !selected.isEmpty else { return nil }
                groups.append(["fontProbes": selected])
                selected = [probe]
                guard fits(["fontProbes": selected], section: "fonts") else { return nil }
            }
            // Keep an explicitly empty probes array distinct from no field.
            groups.append(["fontProbes": selected])
            sections.append(("fonts", groups))
        }
        let count = sections.reduce(0) { $0 + $1.1.count }
        guard count > 0, count <= maximumLogParts else { return nil }
        var result: [Data] = []
        var totalBytes = 0
        for (section, groups) in sections {
            for (index, value) in groups.enumerated() {
                guard let bytes = frame(section: section, part: index + 1, parts: groups.count, value: value),
                      bytes.count <= maximumEventBytes - totalBytes else { return nil }
                totalBytes += bytes.count
                result.append(bytes)
            }
        }
        return result
    }

    enum ApplyPhase: String {
        case replacementPage, pageTransactionPreparation, pageTransactionApply
    }

    /// Pure, fixed-vocabulary failure provenance. Does not inspect PDF objects
    /// or call LocalizedError/NSError descriptions supplied by arbitrary errors.
    enum ReplacementPhase: String {
        case sourceSnapshot, declaration, nativeResolve, nativeGraphics
        case donorGeneration, losslessRewrite, losslessSnapshotWrite
        case restoredFontNames, outputFactory, finalPDFKitTextSequence
        case copyPage, copyAnnotation, scannedAppearance, nativeFontFallback
        case nativeFontAttributes, approvedFontProgramRestore
    }

    private static func classifiedFailureCode(_ error: Error) -> String {
        let code: String
        if let failure = error as? PDFPageStructurePreserver.Failure {
            switch failure {
            case .unsupportedStructure: code = "pageStructure.unsupportedStructure"
            case .unsupportedPageLabels: code = "pageStructure.unsupportedPageLabels"
            case .invalidDestination: code = "pageStructure.invalidDestination"
            case .conflictingFormFields: code = "pageStructure.conflictingFormFields"
            case .tooComplex: code = "pageStructure.tooComplex"
            case .invalidCopy: code = "pageStructure.invalidCopy"
            }
        } else if let failure = error as? PDFPageGeometryPreserver.Failure {
            switch failure {
            case .invalidGeometry: code = "pageGeometry.invalidGeometry"
            case .tooComplex: code = "pageGeometry.tooComplex"
            }
        } else if let failure = PDFBodyTextEditor.diagnosticFailureCode(for: error) {
            code = failure
        } else if error is CancellationError {
            code = "cancelled"
        } else {
            code = "unclassified"
        }
        return code
    }

    static func applyFailurePayload(_ phase: ApplyPhase, error: Error) -> [String: Any] {
        ["schema": 1, "kind": "bodyCommitFailure", "phase": phase.rawValue,
         "failureCode": classifiedFailureCode(error)]
    }

    static func replacementFailurePayload(_ phase: ReplacementPhase, error: Error) -> [String: Any] {
        ["schema": 1, "kind": "bodyReplacementFailure", "replacementPhase": phase.rawValue,
         "failureCode": classifiedFailureCode(error)]
    }

    /// Synchronous invocation-local scope; it owns no PDF handle or mutable
    /// global phase. The exact original Error is rethrown without fallback.
    static func withReplacementPhase<T>(_ phase: ReplacementPhase,
                                        _ body: () throws -> T) rethrows -> T {
        do { return try body() }
        catch {
            recordReplacementFailure(phase, error: error)
            throw error
        }
    }

    static func recordApplyFailure(_ phase: ApplyPhase, error: Error) {
        guard enabled, hasBudget(emittedCount: emitted) else { return }
        recordFailurePayload(applyFailurePayload(phase, error: error))
    }

    static func recordReplacementFailure(_ phase: ReplacementPhase, error: Error) {
        guard enabled, hasBudget(emittedCount: emitted) else { return }
        recordFailurePayload(replacementFailurePayload(phase, error: error))
    }

    private static func recordFailurePayload(_ payload: [String: Any]) {
        guard enabled, hasBudget(emittedCount: emitted) else { return }
        emitted += 1 // At most16 diagnostic events, not16 distinct user attempts.
        var value = payload
        value["eventID"] = emitted
        guard let data = encodedEvent(value), data.count <= maximumLogMessageBytes,
              let json = String(data: data, encoding: .utf8) else { return }
        logger.notice("\(json, privacy: .public)")
        var output = Data("EMBER_BODY_APPLY_REFUSAL ".utf8)
        output.append(data); output.append(0x0A)
        try? FileHandle.standardError.write(contentsOf: output)
    }

    static func record(_ branch: Branch, bounds: CGRect, visible: CGRect? = nil,
                       paintExtent: CGRect? = nil, ink: CGRect? = nil, layout: CGRect? = nil,
                       width: CGFloat? = nil, lineHeight: CGFloat? = nil,
                       lineIndex: Int? = nil, lineCount: Int? = nil, expectedLineCount: Int? = nil,
                       retainedCount: Int? = nil, lineRetained: Bool? = nil,
                       obstacleIndex: Int? = nil, obstacleCount: Int? = nil, obstacle: CGRect? = nil,
                       line: CTLine? = nil, attributed: NSAttributedString? = nil, preferred: NSFont? = nil,
                       paintObservation: PaintObservation? = nil) {
        guard enabled, hasBudget(emittedCount: emitted) else { return }
        emitted += 1
        let value = payload(branch, bounds: bounds, visible: visible, paintExtent: paintExtent,
            ink: ink, layout: layout, width: width, lineHeight: lineHeight,
            lineIndex: lineIndex, lineCount: lineCount, expectedLineCount: expectedLineCount,
            retainedCount: retainedCount, lineRetained: lineRetained,
            obstacleIndex: obstacleIndex, obstacleCount: obstacleCount, obstacle: obstacle,
            line: line, attributed: attributed, preferred: preferred, paintObservation: paintObservation)
        guard let data = encodedEvent(value) else { return }
        // Keep geometry and font probes independently recoverable. Log frame
        // IDs are process-local refusal counters, not document identifiers.
        if let frames = logFrames(value, eventID: emitted) {
            for frame in frames {
                if let json = String(data: frame, encoding: .utf8) {
                    logger.notice("\(json, privacy: .public)")
                }
            }
        }
        var output = Data("EMBER_BODY_FIT_REFUSAL ".utf8)
        output.append(data); output.append(0x0A)
        // Diagnostic I/O must not replace the original failure or throw into Apply.
        try? FileHandle.standardError.write(contentsOf: output)
    }

    /// Pure geometry/schema entry point for deterministic owned fixture tests.
    /// Font probes read only existing CoreText runs; no PDF/font parsing is added.
    static func payload(_ branch: Branch, bounds: CGRect, visible: CGRect? = nil,
                        paintExtent: CGRect? = nil, ink: CGRect? = nil, layout: CGRect? = nil,
                        width: CGFloat? = nil, lineHeight: CGFloat? = nil,
                        lineIndex: Int? = nil, lineCount: Int? = nil, expectedLineCount: Int? = nil,
                        retainedCount: Int? = nil, lineRetained: Bool? = nil,
                        obstacleIndex: Int? = nil, obstacleCount: Int? = nil, obstacle: CGRect? = nil,
                        line: CTLine? = nil, attributed: NSAttributedString? = nil, preferred: NSFont? = nil,
                        paintObservation: PaintObservation? = nil) -> [String: Any] {
        func number(_ value: CGFloat) -> Any { value.isFinite ? NSNumber(value: Double(value)) : NSNull() }
        func finite(_ rectangle: CGRect) -> Bool {
            !rectangle.isNull && [rectangle.minX, rectangle.minY, rectangle.maxX, rectangle.maxY].allSatisfy(\.isFinite)
        }
        func rectangle(_ value: CGRect) -> Any {
            guard finite(value) else { return NSNull() }
            return [value.minX, value.minY, value.maxX, value.maxY].map(number)
        }
        func excess(_ limit: CGRect, _ actual: CGRect) -> [String: Any]? {
            guard finite(limit), finite(actual) else { return nil }
            return ["left": number(max(0, limit.minX - actual.minX)),
                    "bottom": number(max(0, limit.minY - actual.minY)),
                    "right": number(max(0, actual.maxX - limit.maxX)),
                    "top": number(max(0, actual.maxY - limit.maxY))]
        }
        var result: [String: Any] = ["schema": 1, "branch": branch.rawValue,
            "boundsXYXY": rectangle(bounds), "originalFontIdentityVerified": NSNull(),
            "originalFontIdentityStatus": "notMeasured"]
        if let paintObservation {
            result.merge(paintObservation.payload) { current, _ in current }
        }
        for (key, value) in [("visibleXYXY", visible), ("paintExtentXYXY", paintExtent),
                             ("inkXYXY", ink), ("layoutXYXY", layout), ("obstacleXYXY", obstacle)] {
            if let value { result[key] = rectangle(value) }
        }
        if let ink, let visible, let value = excess(visible, ink) { result["visibleExcess"] = value }
        if let ink, let paintExtent, let value = excess(paintExtent, ink) { result["paintExcess"] = value }
        if let ink, let obstacle { result["obstacleIntersectionXYXY"] = rectangle(ink.intersection(obstacle)) }
        for (key, value) in [("lineIndex", lineIndex), ("lineCount", lineCount),
                             ("expectedLineCount", expectedLineCount), ("retainedCount", retainedCount),
                             ("obstacleIndex", obstacleIndex), ("obstacleCount", obstacleCount)] {
            if let value { result[key] = value }
        }
        if let width { result["layoutWidth"] = number(width) }
        if let lineHeight { result["lineHeight"] = number(lineHeight) }
        if let lineRetained { result["lineRetainedRaw"] = lineRetained }
        if let line {
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            result["fontRunCount"] = runs.count
            result["fontProbesTruncated"] = runs.count > maximumFontRuns
            result["fontProbes"] = runs.prefix(maximumFontRuns).map { run -> [String: Any] in
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let value = attributes[kCTFontAttributeName],
                      CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else {
                    return ["actualFontPresent": false]
                }
                let actual = value as! CTFont
                let actualGraphics = CTFontCopyGraphicsFont(actual, nil)
                let matrix = CTFontGetMatrix(actual)
                let range = CTRunGetStringRange(run)
                var probe: [String: Any] = ["actualFontPresent": true,
                    "pointSize": number(CTFontGetSize(actual)),
                    "fontMatrix": [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].map(number)]
                if let preferred {
                    // A different primary face can also be an intentional mixed-font run.
                    probe["differentBackingFromPrimaryPreferred"] =
                        !CFEqual(actualGraphics, CTFontCopyGraphicsFont(preferred as CTFont, nil))
                }
                if let attributed, range.location >= 0, range.location < attributed.length,
                   let declared = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                    // This specifically observes CoreText fallback after attributed layout.
                    // An earlier explicit replacementFont substitution is not proved here.
                    probe["coreTextFallbackFromDeclaredFace"] =
                        !CFEqual(actualGraphics, CTFontCopyGraphicsFont(declared as CTFont, nil))
                }
                return probe
            }
        }
        return result
    }
}
