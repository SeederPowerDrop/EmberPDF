// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// Two page outlines share one visual baseline: the Together View entry keeps
/// the same small vector mark in the toolbar and its document chooser.
struct TogetherViewIcon: View {
    var size: CGFloat = 18
    var color: Color? = nil
    @EmberTheme private var theme

    private var inkColor: Color { color ?? theme.accent }

    var body: some View {
        HStack(spacing: size * 0.12) {
            pageMark.offset(y: -size * 0.06)
            pageMark.offset(y: size * 0.06)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var pageMark: some View {
        RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
            .fill(inkColor.opacity(0.15))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
                    .strokeBorder(inkColor, lineWidth: max(1, size * 0.065))
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(inkColor.opacity(0.65))
                    .frame(width: size * 0.22, height: max(1, size * 0.045))
                    .padding(.top, size * 0.19)
            }
            .frame(width: size * 0.44, height: size * 0.76)
    }
}
