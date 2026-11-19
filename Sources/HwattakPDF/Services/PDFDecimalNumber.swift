// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// PDF real numbers have no exponent syntax. Preserve Double's round-trip
/// precision, including tiny transform components, without emitting `e`/`E`.
enum PDFDecimalNumber {
    enum Failure: Error { case nonFinite }

    static func string(_ value: CGFloat) throws -> String {
        guard value.isFinite else { throw Failure.nonFinite }
        let raw = String(Double(value))
        guard let marker = raw.firstIndex(of: "e"),
              let exponent = Int(raw[raw.index(after: marker)...]) else { return raw }
        let mantissa = String(raw[..<marker])
        let negative = mantissa.hasPrefix("-")
        let unsigned = negative ? String(mantissa.dropFirst()) : mantissa
        let point = unsigned.firstIndex(of: ".").map { unsigned.distance(from: unsigned.startIndex, to: $0) } ?? unsigned.count
        let digits = unsigned.replacingOccurrences(of: ".", with: "")
        let position = point + exponent, sign = negative ? "-" : ""
        if position <= 0 { return sign + "0." + String(repeating: "0", count: -position) + digits }
        if position >= digits.count { return sign + digits + String(repeating: "0", count: position - digits.count) }
        let split = digits.index(digits.startIndex, offsetBy: position)
        return sign + digits[..<split] + "." + digits[split...]
    }
}
