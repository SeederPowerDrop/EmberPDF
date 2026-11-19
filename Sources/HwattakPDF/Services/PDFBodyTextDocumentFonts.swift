// SPDX-License-Identifier: MPL-2.0
import AppKit
import CoreText
import CryptoKit
import Foundation
import PDFKit

fileprivate enum PDFDocumentFontBufferBudget {
    private static let budgetLock = NSLock()
    private static var liveBytes = 0
    private static var livePrograms = 0
    final class Charge: NSObject {
        let bytes: Int
        init(bytes: Int) { self.bytes = bytes }
        deinit {
            budgetLock.lock(); defer { budgetLock.unlock() }
            liveBytes -= bytes; livePrograms -= 1
        }
    }
    static func reserve(_ bytes: Int) -> Charge? {
        budgetLock.lock(); defer { budgetLock.unlock() }
        guard bytes > 0, bytes <= PDFBodyTextDocumentFonts.maximumLiveProgramBytes - liveBytes,
              livePrograms < PDFBodyTextDocumentFonts.maximumLivePrograms else { return nil }
        liveBytes += bytes; livePrograms += 1
        return Charge(bytes: bytes)
    }

}

/// The finite budget accounts owned program backing buffers, not all memory
/// allocated internally by CoreText/CoreGraphics.
/// In-memory, document-owned editable fonts. Nothing is registered by name.
/// Leases retain only a weak store; closing/replacing a document invalidates
/// them even if a stale target/draft remains reachable through undo or a view.
@MainActor
enum PDFBodyTextDocumentFonts {
    nonisolated static let maximumProgramBytes = 16 * 1_024 * 1_024
    nonisolated static let maximumLiveProgramBytes = 32 * 1_024 * 1_024
    nonisolated static let maximumLivePrograms = 64
    private static let associationKey = NSObject()
    private static let backingKey = NSObject()
    private static var association: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(associationKey).toOpaque())
    }
    private static var backingAssociation: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(backingKey).toOpaque())
    }

    @MainActor fileprivate final class Store: NSObject {
        weak var owner: PDFDocument?
        var active = true
        var entries: [Data: Entry] = [:]
        init(owner: PDFDocument) { self.owner = owner }
    }
    @MainActor fileprivate final class Entry {
        let graphics: CGFont
        let lease: Lease
        let charge: PDFDocumentFontBufferBudget.Charge
        let backing: NSData
        init(graphics: CGFont, lease: Lease, charge: PDFDocumentFontBufferBudget.Charge, backing: NSData) {
            self.graphics = graphics; self.lease = lease; self.charge = charge; self.backing = backing
        }
    }
    @MainActor final class Lease: Equatable {
        nonisolated let identity = UUID()
        nonisolated let postScriptName: String
        fileprivate weak var store: Store?
        fileprivate let key: Data
        fileprivate init(store: Store, key: Data, name: String) {
            self.store = store; self.key = key; postScriptName = name
        }
        nonisolated static func == (left: Lease, right: Lease) -> Bool { left.identity == right.identity }
        func isValid(for document: PDFDocument?) -> Bool {
            guard let store, store.active, let owner = store.owner else { return false }
            return owner === document && store.entries[key] != nil
        }
        func approvedProgramToken(for font: CTFont) -> ApprovedProgramToken? {
            guard let store, let owner = store.owner, isValid(for: owner), let entry = store.entries[key],
                  CTFontCopyGraphicsFont(font, nil) === entry.graphics else { return nil }
            return ApprovedProgramToken(lease: self, owner: owner, entry: entry)
        }
        func font(ofSize size: CGFloat) -> NSFont? {
            guard size.isFinite, size > 0, let store, store.active, store.owner != nil,
                  let entry = store.entries[key] else { return nil }
            let font = CTFontCreateWithGraphicsFont(entry.graphics, size, nil, nil)
            // A same-name process/installed face cannot replace this program.
            guard CTFontCopyGraphicsFont(font, nil) === entry.graphics else { return nil }
            let result = font as NSFont
            objc_setAssociatedObject(result, backingAssociation, entry.charge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return result
        }
    }

    /// Issued only for the actual rendered run and its live document lease.
    /// The immutable backing is the existing charged buffer, not a second copy.
    @MainActor final class ApprovedProgramToken {
        fileprivate let lease: Lease
        fileprivate weak var owner: PDFDocument?
        fileprivate let entry: Entry
        fileprivate init(lease: Lease, owner: PDFDocument, entry: Entry) {
            self.lease = lease; self.owner = owner; self.entry = entry
        }
        var isValid: Bool { guard let owner else { return false }; return lease.isValid(for: owner) }
    }

    /// Newly generated Simple TrueType/MacRoman fonts only. Reuse the whole
    /// subset proof and independently bind the FULL program's actual MacRoman
    /// code path, not just its preferred Unicode cmap or PostScript name.
    static func approvedProgram(forGeneratedSubset subset: CGFont,
                                tokens: [ApprovedProgramToken]) -> (bytes: Data, digest: Data)? {
        guard !tokens.isEmpty, tokens.count <= maximumLivePrograms,
              let owner = tokens.first?.owner,
              tokens.allSatisfy({ $0.isValid && $0.owner === owner }),
              let subsetMac = macRomanGlyphs(in: subset), !subsetMac.isEmpty else { return nil }
        var text = ""
        for code in subsetMac.keys.sorted() where subsetMac[code] != 0 {
            let scalar = code < 128 ? UInt32(code) : macRomanHighScalars[code - 128]
            guard let unicode = UnicodeScalar(scalar) else { return nil }
            text.unicodeScalars.append(unicode)
        }
        guard let lease = matchingSubset(subset, document: owner, covering: text, requiringMissingOS2: false),
              let token = tokens.first(where: { $0.lease == lease }),
              let fullMac = macRomanGlyphs(in: token.entry.graphics) else { return nil }
        let full = CTFontCreateWithGraphicsFont(token.entry.graphics, CGFloat(subset.unitsPerEm), nil, nil)
        for (code, glyph) in subsetMac where glyph != 0 {
            guard let expected = fullMac[code], expected != 0 else { return nil }
            let scalar = code < 128 ? UInt32(code) : macRomanHighScalars[code - 128]
            guard let unicode = UnicodeScalar(scalar) else { return nil }
            let chars = Array(String(unicode).utf16)
            var mapped = [CGGlyph](repeating: 0, count: chars.count)
            guard CTFontGetGlyphsForCharacters(full, chars, &mapped, chars.count),
                  mapped.filter({ $0 != 0 }) == [expected] else { return nil }
        }
        let program = Data(referencing: token.entry.backing)
        guard token.isValid, [[UInt8]([0, 1, 0, 0]), Array("true".utf8)].contains(Array(program.prefix(4))) else { return nil }
        return (program, token.lease.key)
    }

    /// Geometry-only reader reuse. No lease/permission or registration is issued.
    static func sourceMacRomanGlyphs(in graphics: CGFont) -> [Int: CGGlyph]? {
        macRomanGlyphs(in: graphics)
    }

    private static func macRomanGlyphs(in graphics: CGFont) -> [Int: CGGlyph]? {
        let font = CTFontCreateWithGraphicsFont(graphics, 12, nil, nil)
        guard let data = CTFontCopyTable(font, CTFontTableTag(kCTFontTableCmap), []) as Data?,
              data.count >= 4, data.count <= 1_024 * 1_024 else { return nil }
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at <= data.count - 2 else { return nil }
            return Int(data[data.startIndex + at]) << 8 | Int(data[data.startIndex + at + 1])
        }
        guard u16(0) == 0, let count = u16(2), (1...16).contains(count), data.count >= 4 + count * 8 else { return nil }
        var result: [Int: CGGlyph] = [:], seen = Set<Int>()
        for index in 0..<count {
            let record = 4 + index * 8
            guard let platform = u16(record), let encoding = u16(record + 2),
                  let high = u16(record + 4), let low = u16(record + 6) else { return nil }
            guard platform == 1, encoding == 0 else { continue }
            let start = high << 16 | low
            guard seen.insert(start).inserted else { continue }
            guard start >= 4 + count * 8, let format = u16(start), let length = u16(start + 2),
                  length <= data.count - start, u16(start + 4) == 0 else { return nil }
            let first: Int, entries: Int, glyphStart: Int
            if format == 0 {
                guard length == 262 else { return nil }; first = 0; entries = 256; glyphStart = start + 6
            } else if format == 6 {
                guard length >= 10, let f = u16(start + 6), let n = u16(start + 8),
                      f <= 255, n > 0, n <= 256 - f, length == 10 + n * 2 else { return nil }
                first = f; entries = n; glyphStart = start + 10
            } else { return nil }
            for offset in 0..<entries {
                let value: Int
                if format == 0 { value = Int(data[data.startIndex + glyphStart + offset]) }
                else { guard let v = u16(glyphStart + offset * 2) else { return nil }; value = v }
                let key = first + offset
                if let old = result[key], old != CGGlyph(value) { return nil }
                result[key] = CGGlyph(value)
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Font copies can outlive a draft/store. Carry the same backing charge
    /// with each copy without retaining the PDFDocument or granting a lease.
    static func retainingBacking(from source: NSFont, on copy: NSFont) -> NSFont {
        if let charge = objc_getAssociatedObject(source, backingAssociation) as? PDFDocumentFontBufferBudget.Charge {
            objc_setAssociatedObject(copy, backingAssociation, charge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        return copy
    }

    static func invalidate(_ document: PDFDocument?) {
        guard let document,
              let store = objc_getAssociatedObject(document, association) as? Store else { return }
        store.active = false
        store.entries.removeAll(keepingCapacity: false)
        objc_setAssociatedObject(document, association, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Called only after the editor has read a bounded embedded sfnt program.
    /// Exact fsType8 only: no missing-table, restricted, preview-only,
    /// no-subsetting, bitmap-only or unknown-bit admission is added.
    static func lease(program: Data, document: PDFDocument, covering text: String) -> Lease? {
        guard program.count > 12, program.count <= maximumProgramBytes,
              [[UInt8]([0, 1, 0, 0]), Array("OTTO".utf8), Array("true".utf8)]
                .contains(Array(program.prefix(4))) else { return nil }
        let key = Data(SHA256.hash(data: program))
        let store: Store
        if let existing = objc_getAssociatedObject(document, association) as? Store, existing.active {
            store = existing
        } else {
            store = Store(owner: document)
            objc_setAssociatedObject(document, association, store, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if let previous = store.entries[key]?.lease {
            guard let font = previous.font(ofSize: 12), covers(text, font: font as CTFont) else { return nil }
            return previous
        }
        guard let charge = PDFDocumentFontBufferBudget.reserve(program.count) else { return nil }
        // The provider owns this explicit NSData. Its budget charge therefore
        // outlives derived CTFont copies still retained by TextKit/CoreText.
        let backing = NSData(data: program)
        objc_setAssociatedObject(backing, backingAssociation, charge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        guard let provider = CGDataProvider(data: backing as CFData), let graphics = CGFont(provider) else { return nil }
        let font = CTFontCreateWithGraphicsFont(graphics, 12, nil, nil)
        guard CTFontCopyGraphicsFont(font, nil) === graphics,
              let os2 = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, os2.count >= 10,
              (UInt16(os2[8]) << 8 | UInt16(os2[9])) == 0x0008,
              covers(text, font: font), let name = graphics.postScriptName as String?,
              !name.isEmpty, name.utf8.count <= 1_024 else { return nil }
        let lease = Lease(store: store, key: key, name: name)
        store.entries[key] = Entry(graphics: graphics, lease: lease, charge: charge, backing: backing)
        return lease
    }

    /// A licensing-less subset is never a source of permission. Resolve it
    /// only against an exact fsType8 program already admitted in this document.
    /// Every Unicode mapping and every nonzero subset glyph must be covered;
    /// matching the selected text or a PostScript name alone is insufficient.
    static func lease(matchingSubsetWithoutOS2 subset: CGFont, document: PDFDocument,
                      covering text: String) -> Lease? {
        return matchingSubset(subset, document: document, covering: text, requiringMissingOS2: true)
    }

    private static func matchingSubset(_ subset: CGFont, document: PDFDocument,
                                       covering text: String, requiringMissingOS2: Bool) -> Lease? {
        guard let store = objc_getAssociatedObject(document, association) as? Store,
              store.active, store.owner === document, !store.entries.isEmpty else { return nil }
        let units = subset.unitsPerEm
        guard units > 0, units <= 16_384 else { return nil }
        let subsetFont = CTFontCreateWithGraphicsFont(subset, CGFloat(units), nil, nil)
        guard CTFontCopyGraphicsFont(subsetFont, nil) === subset,
              let cmap = CTFontCopyTable(subsetFont, CTFontTableTag(kCTFontTableCmap), []) as Data?,
              let maxp = CTFontCopyTable(subsetFont, CTFontTableTag(kCTFontTableMaxp), []) as Data?,
              let mapping = completeSubsetUnicodeMapping(cmap: cmap, maxp: maxp) else { return nil }
        if let os2 = CTFontCopyTable(subsetFont, CTFontTableTag(kCTFontTableOS2), []) as Data? {
            guard !requiringMissingOS2, os2.count >= 10,
                  (UInt16(os2[8]) << 8 | UInt16(os2[9])) == 0x0008 else { return nil }
        }
        let textScalars = Array(text.unicodeScalars.prefix(InlineTextDraftLimiter.maximumUTF16CodeUnitCount + 1))
        guard !textScalars.isEmpty,
              textScalars.count <= InlineTextDraftLimiter.maximumUTF16CodeUnitCount,
              textScalars.allSatisfy({ [9, 10, 13].contains($0.value) || mapping[$0.value] != nil }) else { return nil }
        var selected: Lease?
        // At most64 admitted programs ×512 mapped scalars. A second match to
        // a different program digest is ambiguous, even if its name is equal.
        for entry in store.entries.values {
            guard entry.graphics.unitsPerEm == units else { continue }
            let full = CTFontCreateWithGraphicsFont(entry.graphics, CGFloat(units), nil, nil)
            guard CTFontCopyGraphicsFont(full, nil) === entry.graphics else { return nil }
            var matches = true
            for (scalar, expectedGlyph) in mapping {
                guard let value = UnicodeScalar(scalar) else { return nil }
                let characters = Array(String(value).utf16)
                var a = [CGGlyph](repeating: 0, count: characters.count), b = a
                guard CTFontGetGlyphsForCharacters(subsetFont, characters, &a, characters.count),
                      CTFontGetGlyphsForCharacters(full, characters, &b, characters.count),
                      a.filter({ $0 != 0 }) == [expectedGlyph],
                      b.filter({ $0 != 0 }).count == 1,
                      let fullGlyph = b.first(where: { $0 != 0 }) else { matches = false; break }
                var leftGlyph = expectedGlyph, rightGlyph = fullGlyph
                var left = CGSize.zero, right = CGSize.zero
                CTFontGetAdvancesForGlyphs(subsetFont, .horizontal, &leftGlyph, &left, 1)
                CTFontGetAdvancesForGlyphs(full, .horizontal, &rightGlyph, &right, 1)
                guard left.width.isFinite, left.height.isFinite,
                      right.width.isFinite, right.height.isFinite,
                      left == right else { matches = false; break }
                switch (CTFontCreatePathForGlyph(subsetFont, expectedGlyph, nil),
                        CTFontCreatePathForGlyph(full, fullGlyph, nil)) {
                case let (a?, b?): if a != b { matches = false }
                case (nil, nil): if !CharacterSet.whitespaces.contains(value) { matches = false }
                default: matches = false
                }
                if !matches { break }
            }
            guard matches else { continue }
            if selected != nil { return nil }
            selected = entry.lease
        }
        return selected
    }

    // Exact post-Mac OS8.5 Roman mapping, encodingID0, language0 only.
    // Apple ROMAN.TXT (Unicode vendor map): ASCII/control0...127 are identity;
    // 0xDB is EURO and0xBD is OMEGA. No locale/name/font heuristic is used.
    private static let macRomanHighScalars: [UInt32] = [
        0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1,
        0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8,
        0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3,
        0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC,
        0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF,
        0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8,
        0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211,
        0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8,
        0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB,
        0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153,
        0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA,
        0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
        0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1,
        0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4,
        0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC,
        0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7,
    ]

    /// Conservative complete Unicode cmap reader for the new subset join.
    /// Supports Unicode formats4/12 and MacRoman format6; malformed,
    /// conflicting/variation mappings,
    /// unreferenced glyphs and all over-budget inputs refuse the optional join.
    /// The existing installable/registered-font resolver is unchanged.
    static func completeSubsetUnicodeMapping(cmap: Data, maxp: Data) -> [UInt32: CGGlyph]? {
        guard cmap.count >= 4, cmap.count <= 1_024 * 1_024,
              maxp.count >= 6, maxp.count <= 1_024 * 1_024 else { return nil }
        func u16(_ data: Data, _ offset: Int) -> Int? {
            guard offset >= 0, offset <= data.count - 2 else { return nil }
            return Int(data[data.startIndex + offset]) << 8 | Int(data[data.startIndex + offset + 1])
        }
        func u32(_ data: Data, _ offset: Int) -> Int? {
            guard let a = u16(data, offset), let b = u16(data, offset + 2) else { return nil }
            return a << 16 | b
        }
        guard let version = u16(cmap, 0), version == 0,
              let count = u16(cmap, 2), (1...16).contains(count), cmap.count >= 4 + count * 8,
              let maxpVersion = u32(maxp, 0), [0x00010000, 0x00005000].contains(maxpVersion),
              let glyphCount = u16(maxp, 4), (2...513).contains(glyphCount) else { return nil }
        var mapping: [UInt32: CGGlyph] = [:], parsed = Set<Int>(), work = 0
        func insert(_ scalar: Int, _ glyph: Int) -> Bool {
            guard glyph >= 0, glyph < glyphCount else { return false }
            if glyph == 0 { return true }
            guard (0...0x10FFFF).contains(scalar), !(0xD800...0xDFFF).contains(scalar) else { return false }
            if let old = mapping[UInt32(scalar)] { return old == CGGlyph(glyph) }
            guard mapping.count < 512 else { return false }
            mapping[UInt32(scalar)] = CGGlyph(glyph); return true
        }
        for record in 0..<count {
            let offset = 4 + record * 8
            guard let platform = u16(cmap, offset), let encoding = u16(cmap, offset + 2),
                  let start = u32(cmap, offset + 4), start >= 4 + count * 8,
                  let format = u16(cmap, start) else { return nil }
            if platform == 1, encoding == 0, format == 6 {
                guard parsed.insert(start).inserted else { continue }
                guard let length = u16(cmap, start + 2), length >= 10,
                      length <= cmap.count - start, u16(cmap, start + 4) == 0,
                      let first = u16(cmap, start + 6), first <= 255,
                      let entries = u16(cmap, start + 8), entries > 0,
                      entries <= 256 - first, length == 10 + entries * 2,
                      entries <= 65_536 - work else { return nil }
                work += entries
                for index in 0..<entries {
                    guard let glyph = u16(cmap, start + 10 + index * 2) else { return nil }
                    let code = first + index
                    let scalar = code < 128 ? UInt32(code) : macRomanHighScalars[code - 128]
                    guard insert(Int(scalar), glyph) else { return nil }
                }
                continue
            }
            let unicode = platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10))
            guard unicode else { continue }
            guard platform != 0 || (0...4).contains(encoding),
                  platform != 3 || (encoding == 1 ? format == 4 : format == 12) else { return nil }
            guard parsed.insert(start).inserted else { continue }
            if format == 4 {
                guard let length = u16(cmap, start + 2), length >= 24, length <= cmap.count - start,
                      u16(cmap, start + 4) == 0, let twice = u16(cmap, start + 6),
                      twice > 0, twice % 2 == 0, twice <= 1_024 else { return nil }
                let segments = twice / 2, endBase = start + 14
                let startBase = endBase + twice + 2, deltaBase = startBase + twice
                let rangeBase = deltaBase + twice, glyphBase = rangeBase + twice, end = start + length
                guard glyphBase <= end, u16(cmap, endBase + twice) == 0 else { return nil }
                var previous = -1
                for index in 0..<segments {
                    guard let lower = u16(cmap, startBase + index * 2),
                          let upper = u16(cmap, endBase + index * 2), lower <= upper, lower > previous,
                          let delta = u16(cmap, deltaBase + index * 2),
                          let range = u16(cmap, rangeBase + index * 2), range % 2 == 0,
                          upper - lower + 1 <= 65_536 - work else { return nil }
                    work += upper - lower + 1; previous = upper
                    for scalar in lower...upper {
                        let glyph: Int
                        if range == 0 { glyph = (scalar + delta) & 0xFFFF }
                        else {
                            let address = rangeBase + index * 2 + range + (scalar - lower) * 2
                            guard address >= glyphBase, address <= end - 2,
                                  let raw = u16(cmap, address) else { return nil }
                            glyph = raw == 0 ? 0 : (raw + delta) & 0xFFFF
                        }
                        guard insert(scalar, glyph) else { return nil }
                    }
                }
                guard previous == 0xFFFF else { return nil }
            } else if format == 12 {
                guard u16(cmap, start + 2) == 0, let length = u32(cmap, start + 4),
                      length >= 16, length <= cmap.count - start, u32(cmap, start + 8) == 0,
                      let groups = u32(cmap, start + 12), groups > 0, groups <= 512,
                      length == 16 + groups * 12 else { return nil }
                var previous = -1
                for index in 0..<groups {
                    let group = start + 16 + index * 12
                    guard let lower = u32(cmap, group), let upper = u32(cmap, group + 4),
                          let firstGlyph = u32(cmap, group + 8), lower <= upper, lower > previous,
                          upper <= 0x10FFFF, upper - lower + 1 <= 65_536 - work else { return nil }
                    work += upper - lower + 1; previous = upper
                    for scalar in lower...upper {
                        guard insert(scalar, firstGlyph + scalar - lower) else { return nil }
                    }
                }
            } else { return nil }
        }
        guard !parsed.isEmpty, !mapping.isEmpty,
              Set(mapping.values) == Set((1..<glyphCount).map { CGGlyph($0) }) else { return nil }
        return mapping
    }

    private static func covers(_ text: String, font: CTFont) -> Bool {
        let bounded = Array(text.utf16.prefix(InlineTextDraftLimiter.maximumUTF16CodeUnitCount + 1))
        guard bounded.count <= InlineTextDraftLimiter.maximumUTF16CodeUnitCount else { return false }
        let units = bounded.filter { ![9, 10, 13].contains($0) }
        guard !units.isEmpty else { return false }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
    }
}
