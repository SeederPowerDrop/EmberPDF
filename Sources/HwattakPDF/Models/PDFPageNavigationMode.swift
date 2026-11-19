// SPDX-License-Identifier: MPL-2.0

import Foundation

enum PDFPageNavigationMode: String, CaseIterable, Identifiable {
    case verticalScroll = "vertical"
    case horizontalPaging = "horizontal"
    case allDirectionsPaging = "allDirections"

    // Keep the existing four-page preference so every main-canvas layout
    // shares one direction, including previously saved grid preferences.
    static let defaultsKey = "fourPagePagingDirection"
    static let defaultValue: Self = .verticalScroll

    var id: String { rawValue }
    var title: String {
        switch self {
        case .verticalScroll: L10n.string("pdf.navigation.vertical", defaultValue: "상하 스크롤")
        case .horizontalPaging: L10n.string("pdf.navigation.horizontal", defaultValue: "좌우 넘김")
        case .allDirectionsPaging: L10n.string("pdf.navigation.all_directions", defaultValue: "상하좌우 다 사용하기")
        }
    }

    /// Unmodified canvas arrows only; responder/selection guards live at the
    /// event boundary. This option does not change wheel or trackpad geometry.
    func pageTurnStep(forArrowKeyCode code: UInt16) -> Int? {
        switch (self, code) {
        case (.horizontalPaging, 123), (.allDirectionsPaging, 123), (.allDirectionsPaging, 126): -1
        case (.horizontalPaging, 124), (.allDirectionsPaging, 124), (.allDirectionsPaging, 125): 1
        default: nil
        }
    }

    static func targetPage(from pageIndex: Int, pageCount: Int, pagesPerTurn: Int, step: Int) -> Int? {
        guard pageIndex >= 0, pageIndex < pageCount, step != 0 else { return nil }
        let stride = max(1, min(12, pagesPerTurn))
        let start = (pageIndex / stride) * stride
        if step > 0 {
            return stride < pageCount - start ? start + stride : nil
        }
        return start >= stride ? start - stride : nil
    }
}
