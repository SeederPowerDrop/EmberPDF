// SPDX-License-Identifier: MPL-2.0

import Foundation
import CoreGraphics

/// Repairs one PDFKit serialization defect: an absent object recorded as an
/// in-use classic-xref entry at byte zero. Only that entry's `n` byte changes.
/// Unsupported or ambiguous files are returned untouched; this is not a PDF
/// recovery reader. The caller owns the staged output and commits it afterward.
enum PDFSerializationCrossReferenceRepair {
    private static let tailLimit = 4 * 1_024
    private static let tableLimit = 8 * 1_024 * 1_024

    static func repair(_ data: Data) -> Data {
        guard data.startIndex == 0, let patches = patches(length: data.count, read: { offset, count in
            data.subdata(in: offset..<(offset + count))
        }), !patches.isEmpty,
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), safeToRepair(document) else { return data }
        var repaired = data
        for offset in patches { repaired[offset] = 102 } // f
        return repaired
    }

    /// Ordinary files read their tail and bounded xref only, without creating a
    /// whole-file Data. CoreGraphics protection checks run only for candidates.
    @discardableResult
    static func repair(at url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length64 = try handle.seekToEnd()
        guard length64 <= UInt64(Int.max) else { return false }
        let length = Int(length64)
        let edits = try patches(length: length, read: { offset, count in
            try handle.seek(toOffset: UInt64(offset))
            let bytes = try handle.read(upToCount: count) ?? Data()
            guard bytes.count == count else { throw CocoaError(.fileReadCorruptFile) }
            return bytes
        })
        guard let edits, !edits.isEmpty,
              let document = CGPDFDocument(url as CFURL), safeToRepair(document) else { return false }
        // Validate everything before the first write. Byte positions, object
        // contents, stream contents, and the total file length stay unchanged.
        for offset in edits {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: Data([102]))
        }
        try handle.synchronize()
        return true
    }

    private static func patches(length: Int, read: (Int, Int) throws -> Data) rethrows -> [Int]? {
        guard length >= 24 else { return nil }
        let tailStart = max(0, length - tailLimit)
        let tail = try read(tailStart, length - tailStart)
        guard let marker = tail.range(of: Data("startxref".utf8), options: .backwards),
              marker.lowerBound > 0, white(tail[marker.lowerBound - 1]) else { return nil }
        var suffix = Cursor(Array(tail[marker.lowerBound...]))
        guard suffix.word("startxref"), suffix.whitespace(), let start = suffix.unsigned(),
              suffix.whitespace(), suffix.literal("%%EOF"), suffix.onlyWhitespaceRemains(),
              start >= 8, start < length, length - start <= tableLimit else { return nil }
        let header = try read(0, min(8, length))
        guard header.starts(with: Data("%PDF-".utf8)) else { return nil }
        let table = try read(start, length - start)
        var cursor = Cursor(Array(table))
        guard cursor.line() == Array("xref".utf8) else { return nil }
        struct Entry { var offset: Int; var generation: Int; var flag: UInt8 }
        var entries: [Int: Entry] = [:], edits: [Int] = []
        while true {
            guard let line = cursor.line() else { return nil }
            if line == Array("trailer".utf8) { break }
            var subsection = Cursor(line)
            guard let first = subsection.unsigned(), subsection.whitespace(), let count = subsection.unsigned(),
                  subsection.onlyWhitespaceRemains(), count > 0, count <= tableLimit / 20,
                  first <= Int.max - count, entries.count <= tableLimit / 20 - count else { return nil }
            for object in first..<(first + count) {
                let entryStart = cursor.position
                guard let record = cursor.line(), cursor.position - entryStart == 20,
                      record.count == 18 || record.count == 19,
                      record[10] == 32, record[16] == 32,
                      record.count == 18 || record[18] == 32,
                      let offset = decimal(record[0..<10]), let generation = decimal(record[11..<16]),
                      generation <= 65_535, record[17] == 102 || record[17] == 110,
                      entries[object] == nil else { return nil }
                if record[17] == 110 {
                    guard object != 0, offset < start else { return nil }
                    if offset == 0 {
                        guard generation == 0 else { return nil }
                        edits.append(start + entryStart + 17)
                    } else if offset < 8 { return nil }
                }
                entries[object] = Entry(offset: offset, generation: generation, flag: record[17])
            }
        }
        guard let trailer = cursor.value(), case .dictionary(let dictionary) = trailer,
              case .integer(let size)? = dictionary["Size"], size > 0, size == entries.count,
              entries.keys.allSatisfy({ $0 >= 0 && $0 < size }),
              let zero = entries[0], zero.offset == 0, zero.generation == 65_535, zero.flag == 102,
              ["Prev", "XRefStm", "Encrypt"].allSatisfy({ dictionary[$0] == nil }),
              case .reference(let root, let generation)? = dictionary["Root"],
              let rootEntry = entries[root], rootEntry.flag == 110, rootEntry.offset > 0,
              rootEntry.generation == generation else { return nil }
        cursor.skipSpaceAndComments()
        guard start + cursor.position == tailStart + marker.lowerBound else { return nil }
        if !edits.isEmpty {
            for (object, entry) in entries where entry.flag == 110 && entry.offset > 0 {
                let header = try read(entry.offset, min(64, length - entry.offset))
                var objectHeader = Cursor(Array(header))
                guard objectHeader.unsigned() == object, objectHeader.whitespace(),
                      objectHeader.unsigned() == entry.generation, objectHeader.whitespace(),
                      objectHeader.word("obj") else { return nil }
            }
        }
        return edits
    }

    private static func safeToRepair(_ document: CGPDFDocument) -> Bool {
        guard !document.isEncrypted, document.isUnlocked, let catalog = document.catalog else { return false }
        func contains(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
            var object: CGPDFObjectRef?
            return CGPDFDictionaryGetObject(dictionary, key, &object)
        }
        guard !contains(catalog, "Perms"), !contains(catalog, "DSS") else { return false }
        guard contains(catalog, "AcroForm") else { return true }
        var form: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form,
              !contains(form, "XFA") else { return false }
        if contains(form, "SigFlags") {
            var flags: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(form, "SigFlags", &flags), flags == 0 else { return false }
        }
        guard contains(form, "Fields") else { return false }
        var fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(form, "Fields", &fields), let fields else { return false }
        var pending = [fields], visited = Set<UInt>(), count = 0
        while let array = pending.popLast() {
            let children = CGPDFArrayGetCount(array)
            guard children <= 10_000 - count else { return false }
            count += children
            for index in 0..<children {
                var field: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(array, index, &field), let field,
                      visited.insert(pdfReferenceIdentity(field)).inserted else { return false }
                for key in ["FT", "Type"] where contains(field, key) {
                    var name: UnsafePointer<CChar>?
                    guard CGPDFDictionaryGetName(field, key, &name), let name,
                          String(cString: name) != "Sig" else { return false }
                }
                if contains(field, "ByteRange") { return false }
                var value: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(field, "V", &value), let value {
                    var type: UnsafePointer<CChar>?
                    if contains(value, "ByteRange") { return false }
                    if contains(value, "Type") {
                        guard CGPDFDictionaryGetName(value, "Type", &type), let type,
                              String(cString: type) != "Sig" else { return false }
                    }
                }
                if contains(field, "Kids") {
                    var kids: CGPDFArrayRef?
                    guard CGPDFDictionaryGetArray(field, "Kids", &kids), let kids else { return false }
                    pending.append(kids)
                }
            }
        }
        return true
    }

    private static func white(_ byte: UInt8) -> Bool { [0, 9, 10, 12, 13, 32].contains(byte) }
    private static func decimal(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard !bytes.isEmpty else { return nil }
        var result = 0
        for byte in bytes {
            guard (48...57).contains(byte), result <= (Int.max - Int(byte - 48)) / 10 else { return nil }
            result = result * 10 + Int(byte - 48)
        }
        return result
    }

    private indirect enum Value {
        case integer(Int), reference(Int, Int), dictionary([String: Value]), other
    }

    private struct Cursor {
        var bytes: [UInt8]
        var position = 0
        var tokens = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        mutating func line() -> [UInt8]? {
            let start = position
            while position < bytes.count, bytes[position] != 10, bytes[position] != 13 { position += 1 }
            guard position < bytes.count else { return nil }
            let end = position
            if bytes[position] == 13 { position += 1; if position < bytes.count, bytes[position] == 10 { position += 1 } }
            else { position += 1 }
            return Array(bytes[start..<end])
        }
        mutating func whitespace() -> Bool {
            let start = position
            while position < bytes.count, white(bytes[position]) { position += 1 }
            return position > start
        }
        mutating func onlyWhitespaceRemains() -> Bool { _ = whitespace(); return position == bytes.count }
        mutating func literal(_ text: String) -> Bool {
            let text = Array(text.utf8)
            guard bytes.count - position >= text.count, bytes[position..<(position + text.count)].elementsEqual(text) else { return false }
            position += text.count
            return true
        }
        mutating func word(_ text: String) -> Bool {
            guard literal(text) else { return false }
            return position == bytes.count || delimiter(bytes[position])
        }
        mutating func unsigned() -> Int? {
            let start = position
            while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
            return decimal(bytes[start..<position])
        }
        mutating func skipSpaceAndComments() {
            while position < bytes.count {
                if white(bytes[position]) { position += 1 }
                else if bytes[position] == 37 {
                    while position < bytes.count, bytes[position] != 10, bytes[position] != 13 { position += 1 }
                } else { break }
            }
        }
        private func delimiter(_ byte: UInt8) -> Bool { white(byte) || [40, 41, 60, 62, 91, 93, 123, 125, 47, 37].contains(byte) }
        private func hex(_ byte: UInt8) -> UInt8? {
            if (48...57).contains(byte) { return byte - 48 }
            if (65...70).contains(byte) { return byte - 55 }
            if (97...102).contains(byte) { return byte - 87 }
            return nil
        }
        mutating func name() -> String? {
            guard literal("/") else { return nil }
            var decoded: [UInt8] = []
            while position < bytes.count, !delimiter(bytes[position]) {
                let byte = bytes[position]; position += 1
                if byte == 35 {
                    guard position + 1 < bytes.count, let high = hex(bytes[position]), let low = hex(bytes[position + 1]) else { return nil }
                    decoded.append(high * 16 + low); position += 2
                } else { decoded.append(byte) }
            }
            return String(bytes: decoded, encoding: .utf8)
        }
        mutating func value(depth: Int = 0) -> Value? {
            tokens += 1
            guard depth < 32, tokens < 20_000 else { return nil }
            skipSpaceAndComments()
            guard position < bytes.count else { return nil }
            if literal("<<") {
                var dictionary: [String: Value] = [:]
                while true {
                    skipSpaceAndComments()
                    if literal(">>") { return .dictionary(dictionary) }
                    guard let key = name(), dictionary[key] == nil,
                          let child = value(depth: depth + 1) else { return nil }
                    dictionary[key] = child
                }
            }
            if literal("[") {
                while true {
                    skipSpaceAndComments()
                    if literal("]") { return .other }
                    guard value(depth: depth + 1) != nil else { return nil }
                }
            }
            if literal("(") {
                var nesting = 1
                while position < bytes.count {
                    let byte = bytes[position]; position += 1
                    if byte == 92 {
                        guard position < bytes.count else { return nil }
                        position += 1
                    } else if byte == 40 { nesting += 1; guard nesting < 32 else { return nil } }
                    else if byte == 41 { nesting -= 1; if nesting == 0 { return .other } }
                }
                return nil
            }
            if literal("<") {
                while position < bytes.count {
                    let byte = bytes[position]; position += 1
                    if byte == 62 { return .other }
                    guard white(byte) || hex(byte) != nil else { return nil }
                }
                return nil
            }
            if bytes[position] == 47 { return name().map { _ in .other } }
            let start = position
            if let first = unsigned(), position == bytes.count || delimiter(bytes[position]) {
                let afterFirst = position
                skipSpaceAndComments()
                if let second = unsigned(), second <= 65_535, position < bytes.count, delimiter(bytes[position]) {
                    skipSpaceAndComments()
                    if word("R") { return .reference(first, second) }
                }
                position = afterFirst
                return .integer(first)
            }
            position = start
            for keyword in ["true", "false", "null"] { if word(keyword) { return .other }; position = start }
            return nil
        }
    }
}
