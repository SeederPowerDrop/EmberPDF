// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The destination is a gap in the original document (0...pageCount), matching
/// `movePage(from:before:)`. Selected pages keep their original relative order.
struct PDFPageGalleryMovePlan: Equatable {
    let sourceIndexes: [Int]
    let insertionIndex: Int

    var destinationIndexes: [Int] {
        Array(insertionIndex..<(insertionIndex + sourceIndexes.count))
    }

    var changesOrder: Bool { sourceIndexes != destinationIndexes }

    init?(selectedPages: Set<Int>, before target: Int, pageCount: Int) {
        guard
            pageCount > 0,
            !selectedPages.isEmpty,
            target >= 0,
            target <= pageCount,
            selectedPages.allSatisfy({ $0 >= 0 && $0 < pageCount })
        else { return nil }

        sourceIndexes = selectedPages.sorted()
        insertionIndex = target - sourceIndexes.filter { $0 < target }.count
    }
}
