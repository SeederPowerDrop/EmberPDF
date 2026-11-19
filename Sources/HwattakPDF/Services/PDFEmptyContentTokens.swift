// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A deliberately closed grammar for bounded, unfiltered original contents.
/// It proves no marks only; comments, operands and every other operator refuse.
enum PDFEmptyContentTokens {
    static func provesEmpty(_ data: Data,
                            checkCancellation: () throws -> Void = PDFSaveCancellation.checkCurrent) throws -> Bool {
        try checkCancellation()
        guard data.count <= 4_096 else { return false }
        var depth = 0, tokens = 0, token: UInt8?
        func whitespace(_ byte: UInt8) -> Bool { [0, 9, 10, 12, 13, 32].contains(byte) }
        func finish() -> Bool {
            guard let operatorByte = token else { return true }
            tokens += 1
            guard tokens <= 512 else { return false }
            if operatorByte == 113 {
                depth += 1
                guard depth <= 64 else { return false }
            } else {
                guard depth > 0 else { return false }
                depth -= 1
            }
            token = nil
            return true
        }
        for (index, byte) in data.enumerated() {
            if index & 63 == 0 { try checkCancellation() }
            if whitespace(byte) {
                guard finish() else { return false }
            } else {
                guard token == nil, byte == 113 || byte == 81 else { return false }
                token = byte
            }
        }
        guard finish(), depth == 0 else { return false }
        try checkCancellation()
        return true
    }
}
