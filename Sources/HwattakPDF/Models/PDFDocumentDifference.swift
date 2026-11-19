// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Immutable values are the only boundary between PDFKit and the diff worker.
struct PDFDocumentDifferenceSnapshot: Sendable {
    let pages: [String]
}

struct PDFDocumentDifferenceLocation: Equatable, Sendable {
    let pageIndex: Int
    /// UTF-16 coordinates in the original page text, before normalization.
    let range: NSRange
    let excerpt: String
}

struct PDFDocumentDifferenceChange: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case added, removed, modified }
    let id: Int
    let kind: Kind
    let before: PDFDocumentDifferenceLocation?
    let after: PDFDocumentDifferenceLocation?
    /// A complex page can still be compared exactly at page granularity.
    let isWholePage: Bool
}

struct PDFDocumentDifferenceReport: Sendable {
    let changes: [PDFDocumentDifferenceChange]
    let beforePageCount: Int
    let afterPageCount: Int
    let textlessPageCount: Int
    let isTruncated: Bool

    /// This concerns extracted text only, never visual/annotation equality.
    var hasNoTextChanges: Bool { changes.isEmpty && !isTruncated && textlessPageCount == 0 }
}

struct PDFDocumentDifferenceLimits: Sendable {
    var maximumPagesPerDocument = 2_000
    var maximumPageUTF16Count = 200_000
    var maximumTotalUTF16Count = 8_000_000
    var maximumChanges = 1_000
    var maximumPageAlignmentCells = 4_100_000
    var maximumTokenAlignmentCells = 1_000_000
    var maximumDuration: TimeInterval = 60
}

enum PDFDocumentDifferenceFailure: Error, Equatable {
    case unavailable, restricted, tooLarge, noText, changed, timedOut
}

/// Page anchors prevent one inserted page from shifting every later result.
/// Within changed page pairs a bounded token LCS retains original UTF-16 ranges.
/// No PDF object, file URL, renderer or document mutation is involved here.
enum PDFDocumentDifferenceEngine {
    private struct Token {
        let value: String
        let range: NSRange
    }

    static func compare(_ before: PDFDocumentDifferenceSnapshot,
                        _ after: PDFDocumentDifferenceSnapshot,
                        limits: PDFDocumentDifferenceLimits = .init()) throws -> PDFDocumentDifferenceReport {
        let deadline = ProcessInfo.processInfo.systemUptime + limits.maximumDuration
        func check() throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime <= deadline else { throw PDFDocumentDifferenceFailure.timedOut }
        }
        try check()
        guard before.pages.count <= limits.maximumPagesPerDocument,
              after.pages.count <= limits.maximumPagesPerDocument else { throw PDFDocumentDifferenceFailure.tooLarge }
        var total = 0
        for page in before.pages + after.pages {
            try check()
            let count = page.utf16.count
            guard count <= limits.maximumPageUTF16Count,
                  count <= limits.maximumTotalUTF16Count - total else { throw PDFDocumentDifferenceFailure.tooLarge }
            total += count
        }
        let oldKeys = try before.pages.map { try tokens($0).map(\.value).joined() }
        let newKeys = try after.pages.map { try tokens($0).map(\.value).joined() }
        let textless = oldKeys.filter(\.isEmpty).count + newKeys.filter(\.isEmpty).count
        guard oldKeys.contains(where: { !$0.isEmpty }) || newKeys.contains(where: { !$0.isEmpty }) else {
            throw PDFDocumentDifferenceFailure.noText
        }
        // Intern each full page once: the matrix compares small integers, not
        // multi-kilobyte page strings at each cell. Dictionary collisions still
        // use exact equality, so fingerprints cannot hide real differences.
        var identifiers: [String: Int] = [:]
        func identifier(_ value: String) -> Int {
            if let existing = identifiers[value] { return existing }
            let next = identifiers.count
            identifiers[value] = next
            return next
        }
        let oldIDs = oldKeys.map(identifier), newIDs = newKeys.map(identifier)
        let anchors = try matchingPairs(oldIDs, newIDs, maximumCells: limits.maximumPageAlignmentCells, check: check)
        var changes: [PDFDocumentDifferenceChange] = []
        var truncated = false
        func append(before old: PDFDocumentDifferenceLocation?, after new: PDFDocumentDifferenceLocation?, wholePage: Bool) {
            guard changes.count < max(1, limits.maximumChanges) else { truncated = true; return }
            let oldHasText = (old?.range.length ?? 0) > 0
            let newHasText = (new?.range.length ?? 0) > 0
            let kind: PDFDocumentDifferenceChange.Kind = old == nil ? .added : (new == nil ? .removed
                : (!oldHasText ? .added : (!newHasText ? .removed : .modified)))
            changes.append(.init(id: changes.count, kind: kind, before: old, after: new, isWholePage: wholePage))
        }
        func location(_ text: String, page: Int, range: NSRange? = nil) -> PDFDocumentDifferenceLocation {
            let source = text as NSString
            let range = range ?? NSRange(location: 0, length: source.length)
            let excerpt = String(source.substring(with: range).prefix(240))
            return .init(pageIndex: page, range: range, excerpt: excerpt)
        }
        func comparePage(_ oldIndex: Int, _ newIndex: Int) throws {
            try check()
            guard oldKeys[oldIndex] != newKeys[newIndex] else { return }
            let oldText = before.pages[oldIndex], newText = after.pages[newIndex]
            let old = try tokens(oldText), new = try tokens(newText)
            // Trim shared edges before allocating a matrix. A one-word edit on
            // a long page therefore uses a tiny matrix rather than N squared.
            var prefix = 0
            while prefix < min(old.count, new.count), old[prefix].value == new[prefix].value { prefix += 1 }
            var oldEnd = old.count, newEnd = new.count
            while oldEnd > prefix, newEnd > prefix, old[oldEnd - 1].value == new[newEnd - 1].value {
                oldEnd -= 1; newEnd -= 1
            }
            let oldSlice = Array(old[prefix..<oldEnd]), newSlice = Array(new[prefix..<newEnd])
            let cellCount = (oldSlice.count + 1).multipliedReportingOverflow(by: newSlice.count + 1)
            guard !cellCount.overflow, cellCount.partialValue <= limits.maximumTokenAlignmentCells else {
                append(before: location(oldText, page: oldIndex), after: location(newText, page: newIndex), wholePage: true)
                return
            }
            let matches = try matchingPairs(oldSlice.map(\.value), newSlice.map(\.value),
                                             maximumCells: limits.maximumTokenAlignmentCells, check: check)
            var oldStart = 0, newStart = 0
            for (oldStop, newStop) in matches + [(oldSlice.count, newSlice.count)] {
                try check()
                if oldStart != oldStop || newStart != newStop {
                    let oldRange = sourceRange(old, start: prefix + oldStart, end: prefix + oldStop, text: oldText)
                    let newRange = sourceRange(new, start: prefix + newStart, end: prefix + newStop, text: newText)
                    append(before: location(oldText, page: oldIndex, range: oldRange),
                           after: location(newText, page: newIndex, range: newRange), wholePage: false)
                    if truncated { return }
                }
                oldStart = oldStop + 1; newStart = newStop + 1
            }
        }
        var oldStart = 0, newStart = 0
        for (oldStop, newStop) in anchors + [(oldKeys.count, newKeys.count)] {
            try check()
            let paired = min(oldStop - oldStart, newStop - newStart)
            for offset in 0..<paired { try comparePage(oldStart + offset, newStart + offset); if truncated { break } }
            if !truncated {
                for index in (oldStart + paired)..<oldStop {
                    append(before: location(before.pages[index], page: index), after: nil, wholePage: true)
                    if truncated { break }
                }
            }
            if !truncated {
                for index in (newStart + paired)..<newStop {
                    append(before: nil, after: location(after.pages[index], page: index), wholePage: true)
                    if truncated { break }
                }
            }
            if truncated { break }
            oldStart = oldStop + 1; newStart = newStop + 1
        }
        try check()
        return .init(changes: changes, beforePageCount: before.pages.count, afterPageCount: after.pages.count,
                     textlessPageCount: textless, isTruncated: truncated)
    }

    private static func sourceRange(_ tokens: [Token], start: Int, end: Int, text: String) -> NSRange {
        guard start < end else {
            return .init(location: start < tokens.count ? tokens[start].range.location : text.utf16.count, length: 0)
        }
        let first = tokens[start].range.location, last = NSMaxRange(tokens[end - 1].range)
        return .init(location: first, length: last - first)
    }

    private static func tokens(_ text: String) throws -> [Token] {
        var result: [Token] = [], value = "", start = 0, offset = 0, category = 0, iteration = 0
        func flush() {
            if !value.isEmpty { result.append(.init(value: value.precomposedStringWithCanonicalMapping,
                                                   range: .init(location: start, length: offset - start))) }
            value = ""
        }
        for character in text {
            if iteration.isMultiple(of: 1_024) { try Task.checkCancellation() }
            iteration += 1
            let scalars = character.unicodeScalars
            let isSpace = scalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
            // Han and Kana must remain independently editable even without
            // spaces. Hangul/Latin words preserve meaningful word boundaries.
            let isCJK = scalars.contains { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
                || (0x3040...0x30FF).contains($0.value) }
            let nextCategory = isSpace ? 1 : (!isCJK && scalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
            } ? 2 : 3)
            if nextCategory != category || nextCategory == 3 { flush(); start = offset }
            if nextCategory == 1 { value = " " } else { value.append(character) }
            category = nextCategory
            offset += String(character).utf16.count
        }
        flush()
        if result.first?.value == " " { result.removeFirst() }
        if result.last?.value == " " { result.removeLast() }
        return result
    }

    /// Matrix allocation and cancellation are explicit rather than delegated to
    /// an unbounded generic collection-difference implementation.
    private static func matchingPairs<Value: Equatable>(_ old: [Value], _ new: [Value], maximumCells: Int,
                                      check: () throws -> Void) throws -> [(Int, Int)] {
        guard !old.isEmpty, !new.isEmpty else { return [] }
        let width = new.count + 1
        let cells = (old.count + 1).multipliedReportingOverflow(by: width)
        guard !cells.overflow, cells.partialValue <= maximumCells else { throw PDFDocumentDifferenceFailure.tooLarge }
        var lengths = [UInt32](repeating: 0, count: cells.partialValue)
        for i in old.indices.reversed() {
            try check()
            for j in new.indices.reversed() {
                let index = i * width + j
                lengths[index] = old[i] == new[j] ? 1 + lengths[index + width + 1]
                    : max(lengths[index + width], lengths[index + 1])
            }
        }
        var pairs: [(Int, Int)] = [], i = 0, j = 0
        while i < old.count, j < new.count {
            if (i + j).isMultiple(of: 128) { try check() }
            if old[i] == new[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] { i += 1 }
            else { j += 1 }
        }
        return pairs
    }
}
