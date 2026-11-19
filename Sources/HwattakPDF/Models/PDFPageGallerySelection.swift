// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Gallery selection is independent of the reading cursor. In particular,
/// Command-clicking the last selected page may leave no pages selected.
enum PDFPageGallerySelection {
    struct Result: Equatable {
        let selectedPages: Set<Int>
        let anchor: Int?
    }

    static func normalized(_ selectedPages: Set<Int>, pageCount: Int) -> Set<Int> {
        Set(selectedPages.filter { $0 >= 0 && $0 < pageCount })
    }

    static func selectAll(pageCount: Int) -> Set<Int> {
        Set(0..<max(0, pageCount))
    }

    static func select(
        page: Int,
        selectedPages: Set<Int>,
        anchor: Int?,
        pageCount: Int,
        extending: Bool = false,
        toggling: Bool = false
    ) -> Result {
        let selection = normalized(selectedPages, pageCount: pageCount)
        let validAnchor = anchor.flatMap { $0 >= 0 && $0 < pageCount ? $0 : nil }
        guard page >= 0, page < pageCount else {
            return Result(selectedPages: selection, anchor: validAnchor)
        }

        if extending {
            let rangeAnchor = validAnchor ?? selection.min() ?? page
            let range = Set(min(rangeAnchor, page)...max(rangeAnchor, page))
            return Result(
                selectedPages: toggling ? selection.union(range) : range,
                anchor: rangeAnchor
            )
        }

        if toggling {
            var updated = selection
            if !updated.insert(page).inserted {
                updated.remove(page)
            }
            return Result(selectedPages: updated, anchor: page)
        }
        return Result(selectedPages: [page], anchor: page)
    }
}
