// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// Prunes only the name table of a verified image-only XObject namespace.
/// The complete final painting-page set must be supplied in one call: names
/// used by pages sharing a namespace are unioned before any plan change.
/// Parser objects and original stream bytes are never changed or regenerated.
enum PDFCatalogImageResourcePruner {
    enum Failure: Error { case tooComplex }

    struct Limits {
        var maximumPages = 250_000
        var maximumVisits = 250_000
        var maximumStreams = 25_000
        var maximumDecodedBytes = 64 * 1_024 * 1_024
        var maximumTokens = 1_000_000
        var maximumInheritanceDepth = 64
    }

    private final class Budget {
        let limits: Limits
        var visits = 0, streams = 0, decodedBytes = 0, tokens = 0
        init(_ limits: Limits) { self.limits = limits }
        private var callbackError: Error?
        func visit() throws {
            if visits & 255 == 0 { try PDFSaveCancellation.checkCurrent() }
            guard visits < limits.maximumVisits else { throw Failure.tooComplex }
            visits += 1
        }
        // CoreGraphics callbacks cannot throw. Preserve the exact error and
        // rethrow it immediately after their bounded scan/apply returns.
        func pollCancellationInCallback() -> Bool {
            guard callbackError == nil else { return false }
            guard visits & 255 == 0 else { return true }
            do { try PDFSaveCancellation.checkCurrent(); return true }
            catch { callbackError = error; return false }
        }
        func rethrowCallbackError() throws {
            if let callbackError { throw callbackError }
        }
    }
    private final class Candidate {
        var names: Set<String> = []
        var used: Set<String> = []
        var safe = true
    }
    private final class ScanState {
        let candidate: Candidate
        let budget: Budget
        var invalid = false, exhausted = false
        init(_ candidate: Candidate, _ budget: Budget) { self.candidate = candidate; self.budget = budget }
    }

    static func addPrunedImageResources(
        pages: [CGPDFPage], to plan: inout PDFCatalogGraphPlan, limits: Limits = Limits(),
        onContentDecoded: ((CGPDFStreamRef, Data) -> Void)? = nil, requireImageOnlyPainting: Bool = false
    ) throws {
        guard pages.count <= limits.maximumPages, limits.maximumVisits > 0,
              limits.maximumStreams > 0, limits.maximumDecodedBytes > 0,
              limits.maximumTokens > 0, limits.maximumInheritanceDepth > 0 else { throw Failure.tooComplex }
        try PDFSaveCancellation.checkCurrent()
        let budget = Budget(limits)
        var candidates: [UInt: Candidate] = [:]
        for page in pages {
            try PDFSaveCancellation.checkCurrent()
            guard let pageDictionary = page.dictionary else { return }
            let resolved = try resources(for: pageDictionary, budget: budget)
            guard resolved.known else { return } // Unresolved namespace: keep every original resource.
            guard let resources = resolved.dictionary else { continue }
            guard object(resources, "XObject") != nil else { continue }
            guard let xobjects = dictionary(resources, "XObject") else { return }
            let key = pdfReferenceIdentity(xobjects)
            let candidate: Candidate
            if let existing = candidates[key] { candidate = existing }
            else {
                candidate = Candidate()
                candidate.safe = try imageNames(in: xobjects, into: candidate, budget: budget)
                candidates[key] = candidate
            }
            guard candidate.safe else { continue }
            // An appearance can use the same dictionary outside the page's Do
            // program. One complex selected page vetoes this shared namespace.
            guard object(pageDictionary, "Annots") == nil,
                  try simpleResources(resources, budget: budget) else {
                candidate.safe = false
                continue
            }
            let content = CGPDFContentStreamCreateWithPage(page)
            defer { CGPDFContentStreamRelease(content) }
            guard try boundedContent(content, budget: budget, onContentDecoded: onContentDecoded,
                                     requireImageOnlyPainting: requireImageOnlyPainting) else {
                candidate.safe = false
                continue
            }
            let state = ScanState(candidate, budget)
            guard let table = CGPDFOperatorTableCreate() else { candidate.safe = false; continue }
            defer { CGPDFOperatorTableRelease(table) }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
                guard let info else { return }
                let state = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
                guard state.budget.pollCancellationInCallback() else { CGPDFScannerStop(scanner); return }
                guard state.budget.visits < state.budget.limits.maximumVisits else {
                    state.exhausted = true; CGPDFScannerStop(scanner); return
                }
                state.budget.visits += 1
                var rawName: UnsafePointer<CChar>?
                guard CGPDFScannerPopName(scanner, &rawName), let rawName,
                      let name = PDFCatalogImageResourcePruner.boundedName(rawName), state.candidate.names.contains(name),
                      CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", rawName) != nil else {
                    state.invalid = true; CGPDFScannerStop(scanner); return
                }
                state.candidate.used.insert(name)
            }
            let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
            defer { CGPDFScannerRelease(scanner) }
            let complete = withExtendedLifetime(state) { CGPDFScannerScan(scanner) }
            try budget.rethrowCallbackError()
            if state.exhausted { throw Failure.tooComplex }
            if !complete || state.invalid { candidate.safe = false }
        }
        // Compute every change before committing, including cancellation.
        var additions: [UInt: Set<String>] = [:]
        for (key, candidate) in candidates where candidate.safe {
            try PDFSaveCancellation.checkCurrent()
            let unused = candidate.names.subtracting(candidate.used)
            if !unused.isEmpty { additions[key] = unused }
        }
        try PDFSaveCancellation.checkCurrent()
        for (key, unused) in additions { plan.dictionaryDrops[key, default: []].formUnion(unused) }
    }

    private static func resources(for page: CGPDFDictionaryRef, budget: Budget) throws
        -> (known: Bool, dictionary: CGPDFDictionaryRef?) {
        var current: CGPDFDictionaryRef? = page, seen = Set<UInt>()
        for _ in 0..<budget.limits.maximumInheritanceDepth {
            guard let node = current else { return (true, nil) }
            try budget.visit()
            guard seen.insert(pdfReferenceIdentity(node)).inserted else { throw Failure.tooComplex }
            if object(node, "Resources") != nil {
                guard let resources = dictionary(node, "Resources") else { return (false, nil) }
                return (true, resources)
            }
            if object(node, "Parent") != nil, dictionary(node, "Parent") == nil { return (false, nil) }
            current = dictionary(node, "Parent")
        }
        guard current == nil else { throw Failure.tooComplex }
        return (true, nil)
    }

    private static func imageNames(in dictionary: CGPDFDictionaryRef, into candidate: Candidate,
                                   budget: Budget) throws -> Bool {
        var safe = true, exhausted = false
        CGPDFDictionaryApplyBlock(dictionary, { rawName, value, _ in
            guard budget.pollCancellationInCallback() else { return false }
            guard budget.visits < budget.limits.maximumVisits else { exhausted = true; return false }
            budget.visits += 1
            var stream: CGPDFStreamRef?
            guard let name = boundedName(rawName), CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let image = CGPDFStreamGetDictionary(stream), nameValue(image, "Subtype") == "Image",
                  object(image, "SMask") == nil, object(image, "Mask") == nil,
                  object(image, "Alternates") == nil else { safe = false; return false }
            candidate.names.insert(name)
            return true
        }, nil)
        try budget.rethrowCallbackError()
        if exhausted { throw Failure.tooComplex }
        return safe
    }

    private static func simpleResources(_ resources: CGPDFDictionaryRef, budget: Budget) throws -> Bool {
        var safe = true, exhausted = false
        CGPDFDictionaryApplyBlock(resources, { rawName, _, _ in
            guard budget.pollCancellationInCallback() else { return false }
            guard budget.visits < budget.limits.maximumVisits else { exhausted = true; return false }
            budget.visits += 1
            guard let name = boundedName(rawName), ["XObject", "Font", "ColorSpace", "ProcSet", "ExtGState"].contains(name) else {
                safe = false; return false
            }
            return true
        }, nil)
        try budget.rethrowCallbackError()
        if exhausted { throw Failure.tooComplex }
        guard safe else { return false }
        if object(resources, "Font") != nil {
            guard let fonts = dictionary(resources, "Font") else { return false }
            CGPDFDictionaryApplyBlock(fonts, { _, value, _ in
                guard budget.pollCancellationInCallback() else { return false }
                guard budget.visits < budget.limits.maximumVisits else { exhausted = true; return false }
                budget.visits += 1
                var font: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(value, .dictionary, &font), let font,
                      let subtype = nameValue(font, "Subtype"),
                      ["Type1", "MMType1", "TrueType", "Type0", "CIDFontType0", "CIDFontType2"].contains(subtype),
                      object(font, "Resources") == nil else { safe = false; return false }
                return true
            }, nil)
        }
        try budget.rethrowCallbackError()
        if exhausted { throw Failure.tooComplex }
        guard safe else { return false }
        if object(resources, "ExtGState") != nil {
            guard let states = dictionary(resources, "ExtGState") else { return false }
            var caught: Error?
            CGPDFDictionaryApplyBlock(states, { _, value, _ in
                guard budget.pollCancellationInCallback() else { return false }
                guard budget.visits < budget.limits.maximumVisits else { caught = Failure.tooComplex; return false }
                budget.visits += 1
                var state: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(value, .dictionary, &state), let state else { safe = false; return false }
                do { safe = try simpleGraphicsState(state, budget: budget) }
                catch { caught = error; return false }
                return safe
            }, nil)
            try budget.rethrowCallbackError()
            if let caught { throw caught }
        }
        return safe
    }

    /// Numeric/boolean/name-only graphics settings cannot execute a hidden
    /// image program. Soft-mask forms, transfer functions and font programs do
    /// not qualify, even when the page never invokes that particular state.
    private static func simpleGraphicsState(_ state: CGPDFDictionaryRef, budget: Budget) throws -> Bool {
        var safe = true, exhausted = false
        CGPDFDictionaryApplyBlock(state, { rawName, value, _ in
            guard budget.pollCancellationInCallback() else { return false }
            guard budget.visits < budget.limits.maximumVisits else { exhausted = true; return false }
            budget.visits += 1
            guard let key = boundedName(rawName) else { safe = false; return false }
            switch key {
            case "Type": safe = nameValue(state, key) == "ExtGState"
            case "SMask": safe = nameValue(state, key) == "None"
            case "CA", "ca", "LW", "LC", "LJ", "ML", "OPM", "FL", "SM":
                safe = [.integer, .real].contains(CGPDFObjectGetType(value))
            case "OP", "op", "SA", "AIS", "TK": safe = CGPDFObjectGetType(value) == .boolean
            case "RI": safe = CGPDFObjectGetType(value) == .name
            case "BM": safe = simpleNameArrayOrName(value, budget: budget)
            default: safe = false
            }
            return safe
        }, nil)
        try budget.rethrowCallbackError()
        if exhausted { throw Failure.tooComplex }
        return safe
    }

    private static func simpleNameArrayOrName(_ value: CGPDFObjectRef, budget: Budget) -> Bool {
        if CGPDFObjectGetType(value) == .name { return true }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(value, .array, &array), let array else { return false }
        let count = CGPDFArrayGetCount(array)
        guard count <= 64, count <= budget.limits.maximumVisits - budget.visits else { return false }
        budget.visits += count
        for index in 0..<count {
            var name: UnsafePointer<CChar>?
            guard CGPDFArrayGetName(array, index, &name), let name, boundedName(name) != nil else { return false }
        }
        return true
    }

    private static let operators: Set<String> = Set((
        "q Q cm w J j M d ri i gs m l c v y h re S s f F f* B B* b b* n W W* " +
        "BT ET Tc Tw Tz TL Tf Tr Ts Td TD Tm T* Tj TJ ' \" d0 d1 CS cs SC SCN sc scn G g RG rg K k sh Do " +
        "MP DP BMC BDC EMC BX EX"
    ).split(separator: " ").map(String.init))
    private static let textOperators: Set<String> = Set("BT ET Tc Tw Tz TL Tf Tr Ts Td TD Tm T* Tj TJ ' \"".split(separator: " ").map(String.init))
    // Inline ActualText can give an image text semantics without any BT/Tj.
    // Keep all marked painting on the established SDK assembly path as well.
    private static let markedContentOperators: Set<String> = ["BMC", "BDC", "EMC", "MP", "DP"]

    private static func boundedContent(_ content: CGPDFContentStreamRef, budget: Budget,
                                       onContentDecoded: ((CGPDFStreamRef, Data) -> Void)?,
                                       requireImageOnlyPainting: Bool) throws -> Bool {
        guard let streams = CGPDFContentStreamGetStreams(content) else { return false }
        let count = CFArrayGetCount(streams)
        guard count <= budget.limits.maximumStreams - budget.streams else { throw Failure.tooComplex }
        budget.streams += count
        for index in 0..<count {
            try PDFSaveCancellation.checkCurrent()
            let stream = unsafeBitCast(CFArrayGetValueAtIndex(streams, index), to: CGPDFStreamRef.self)
            guard let dictionary = CGPDFStreamGetDictionary(stream), object(dictionary, "F") == nil else { return false }
            var format = CGPDFDataFormat.raw
            // CGPDF's decoder allocates before exposing length; the decoded
            // buffer and subsequent lexical/scanner work are checked here.
            guard let bytes = CGPDFStreamCopyData(stream, &format), format == .raw else { return false }
            let length = CFDataGetLength(bytes)
            guard length <= budget.limits.maximumDecodedBytes - budget.decodedBytes else { throw Failure.tooComplex }
            budget.decodedBytes += length
            try PDFSaveCancellation.checkCurrent()
            var lexer = PDFBodyTextContentStream.Lexer(bytes: Array(bytes as Data))
            do {
                var nextCancellationVisit = 0
                while let token = try lexer.next() {
                    if lexer.visits >= nextCancellationVisit {
                        try PDFSaveCancellation.checkCurrent()
                        nextCancellationVisit = lexer.visits + 1_024
                    }
                    guard lexer.visits <= budget.limits.maximumTokens - budget.tokens else { throw Failure.tooComplex }
                    if let command = token.command {
                        if !operators.contains(command) { return false }
                        if requireImageOnlyPainting &&
                            (textOperators.contains(command) || markedContentOperators.contains(command)) { return false }
                    }
                }
            } catch is CancellationError { throw CancellationError() }
              catch PDFBodyTextContentStream.ParseFailure.limitExceeded { throw Failure.tooComplex }
              catch is Failure { throw Failure.tooComplex }
              catch { return false }
            budget.tokens += lexer.visits
            onContentDecoded?(stream, bytes as Data)
        }
        return true
    }

    private static func boundedName(_ value: UnsafePointer<CChar>) -> String? {
        guard strnlen(value, 4_097) <= 4_096 else { return nil }
        return String(validatingUTF8: value)
    }
    private static func object(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var value: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &value) ? value : nil
    }
    private static func dictionary(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(dictionary, key, &value) ? value : nil
    }
    private static func nameValue(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return boundedName(value)
    }
}
