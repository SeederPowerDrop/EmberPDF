// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import PDFKit

/// PDF rendering isolates each Form XObject's graphics stack. PDFKit text
/// extraction does not always do so: an unmatched `q` in a form can consume a
/// parent's `Q` and shift all subsequent text by an otherwise-restored `cm`.
/// Inspect only invoked forms, using the PDF tokenizer so strings, comments,
/// and image bytes containing q/Q cannot be mistaken for graphics operators.
enum PDFFormGraphicsStateInspector {
    static func hasUnbalancedForm(on page: PDFPage) -> Bool {
        guard let reference = page.pageRef else { return false }
        let content = CGPDFContentStreamCreateWithPage(reference)
        defer { CGPDFContentStreamRelease(content) }
        let probe = Probe()
        probe.scan(content, isForm: false, depth: 0)
        return probe.damaged
    }

    private final class Probe {
        private var visited: Set<UInt> = []
        private var decodedBytes = 0
        private var streamCount = 0
        private var exhausted = false
        var damaged = false

        func scan(_ content: CGPDFContentStreamRef, isForm: Bool, depth: Int) {
            guard !damaged, !exhausted, depth <= 8, bounded(content) else { return }
            let state = ScanState(probe: self, depth: depth)
            let table = CGPDFOperatorTableCreate()!
            defer { CGPDFOperatorTableRelease(table) }
            CGPDFOperatorTableSetCallback(table, "q") { scanner, info in
                guard let info else { return }
                let state = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
                state.saves += 1
                if state.saves > 4_096 {
                    state.probe.exhausted = true
                    CGPDFScannerStop(scanner)
                }
            }
            CGPDFOperatorTableSetCallback(table, "Q") { _, info in
                guard let info else { return }
                let state = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
                if state.saves == 0 { state.underflow = true }
                else { state.saves -= 1 }
            }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
                guard let info else { return }
                let state = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopName(scanner, &name), let name,
                      let object = CGPDFContentStreamGetResource(
                        CGPDFScannerGetContentStream(scanner), "XObject", name
                      ), CGPDFObjectGetType(object) == .stream else { return }
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
                state.probe.scanForm(stream, parent: CGPDFScannerGetContentStream(scanner),
                                     depth: state.depth + 1)
                if state.probe.damaged || state.probe.exhausted { CGPDFScannerStop(scanner) }
            }
            let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
            defer { CGPDFScannerRelease(scanner) }
            let complete = CGPDFScannerScan(scanner)
            if complete, !exhausted, isForm, state.underflow || state.saves != 0 {
                damaged = true
            }
        }

        private func scanForm(_ stream: CGPDFStreamRef, parent: CGPDFContentStreamRef, depth: Int) {
            guard let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                  strcmp(subtype, "Form") == 0 else { return }
            guard visited.insert(pdfReferenceIdentity(stream)).inserted else { return }
            var resources: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            let content = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, parent)
            defer { CGPDFContentStreamRelease(content) }
            scan(content, isForm: true, depth: depth)
        }

        private func bounded(_ content: CGPDFContentStreamRef) -> Bool {
            guard let streams = CGPDFContentStreamGetStreams(content) else { return false }
            let count = CFArrayGetCount(streams)
            guard count <= 64 - streamCount else { exhausted = true; return false }
            streamCount += count
            for index in 0..<count {
                let stream = unsafeBitCast(CFArrayGetValueAtIndex(streams, index), to: CGPDFStreamRef.self)
                var format = CGPDFDataFormat.raw
                // Core Graphics decodes before reporting length; retained data,
                // total scan bytes, resource visits, and recursion stay bounded.
                guard let bytes = CGPDFStreamCopyData(stream, &format), format == .raw else { return false }
                let length = CFDataGetLength(bytes)
                guard length <= 4 * 1_024 * 1_024 - decodedBytes else {
                    exhausted = true
                    return false
                }
                decodedBytes += length
            }
            return true
        }
    }

    private final class ScanState {
        let probe: Probe
        let depth: Int
        var saves = 0
        var underflow = false

        init(probe: Probe, depth: Int) {
            self.probe = probe
            self.depth = depth
        }
    }
}
