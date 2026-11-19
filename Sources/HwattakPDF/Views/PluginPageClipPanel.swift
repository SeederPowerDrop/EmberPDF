// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// All interaction and raster export belong to the host. A manifest can request
/// this panel, but cannot select a rectangle, read its pixels, or trigger export.
struct PluginPageClipPanel: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let documentRevision: UUID
    let isAuthorized: () -> Bool

    @EmberTheme private var theme
    @State private var snapshot: PluginPageClipService.Snapshot?
    @State private var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var message: String?
    @State private var isVisible = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.string("plugins.clip.instructions", defaultValue: "페이지 위를 드래그해 필요한 부분을 오려보세요. 원본 PDF는 그대로 유지됩니다."))
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)

                if let snapshot, available {
                    selectionCanvas(snapshot)
                    HStack {
                        Text(String(format: L10n.string("plugins.clip.page", defaultValue: "%d페이지"),
                                    locale: L10n.currentLanguage.locale, snapshot.pageIndex + 1))
                            .font(.caption).foregroundStyle(theme.secondaryText)
                        Spacer()
                        Button(L10n.string("plugins.clip.full_page", defaultValue: "페이지 전체")) {
                            region = CGRect(x: 0, y: 0, width: 1, height: 1)
                            message = nil
                        }
                        .accessibilityIdentifier("plugin-clip-full-page")
                    }

                    DisclosureGroup(L10n.string("plugins.clip.adjust", defaultValue: "영역 미세 조정")) {
                        VStack(spacing: 8) {
                            regionStepper("plugins.clip.left", "왼쪽", component: .left)
                            regionStepper("plugins.clip.top", "위쪽", component: .top)
                            regionStepper("plugins.clip.width", "너비", component: .width)
                            regionStepper("plugins.clip.height", "높이", component: .height)
                        }.padding(.top, 8)
                    }.font(.caption)

                    ViewThatFits {
                        HStack { copyButton(snapshot); saveButton(snapshot) }
                        VStack(alignment: .leading) { copyButton(snapshot); saveButton(snapshot) }
                    }

                    Label(L10n.string("plugins.clip.drag", defaultValue: "이 이미지를 다른 앱으로 드래그"), systemImage: "arrow.up.right.square")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity).padding(12)
                        .background(theme.selectionFill, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.selectionBorder))
                        .contentShape(Rectangle())
                        .onDrag {
                            do {
                                return try PluginPageClipService.dragProvider(snapshot, normalizedRect: region,
                                    workspace: workspace, isAuthorized: authorizedForExport)
                            } catch { message = error.localizedDescription; return NSItemProvider() }
                        }
                        .accessibilityIdentifier("plugin-clip-drag")

                    Text(L10n.string("plugins.clip.export_note", defaultValue: "복사하거나 PNG로 저장한 이미지를 PDF·노트·Word 등에 붙여넣을 수 있습니다. 이미지는 원본 색상으로 내보냅니다."))
                        .font(.caption).foregroundStyle(theme.secondaryText)
                } else if message == nil {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
                if let message {
                    Text(message).font(.callout).foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("plugin-clip-status")
                }
            }.padding(14)
        }
        .background(theme.canvas)
        .accessibilityIdentifier("plugin-page-clip-panel")
        .onAppear { isVisible = true; capture() }
        .onDisappear { isVisible = false; snapshot = nil }
        .onChange(of: workspace.revision) { _, _ in invalidate() }
        .onChange(of: workspace.documentURL) { _, _ in invalidate() }
    }

    private var available: Bool {
        guard let snapshot else { return false }
        return (try? PluginPageClipService.validate(snapshot, workspace: workspace, isAuthorized: authorizedForExport)) != nil
    }

    private func authorizedForExport() -> Bool { isVisible && isAuthorized() }

    private func capture() {
        do {
            snapshot = try PluginPageClipService.capture(workspace: workspace,
                documentRevision: documentRevision, isAuthorized: authorizedForExport)
            message = nil
        } catch { snapshot = nil; message = error.localizedDescription }
    }

    private func invalidate() {
        snapshot = nil
        message = PluginPageClipService.ClipError.stale.localizedDescription
    }

    private func copyButton(_ snapshot: PluginPageClipService.Snapshot) -> some View {
        Button {
            do {
                try PluginPageClipService.copy(snapshot, normalizedRect: region,
                    workspace: workspace, isAuthorized: authorizedForExport)
                message = L10n.string("plugins.clip.copied", defaultValue: "이미지를 복사했습니다. 다른 앱에서 붙여넣으세요.")
            } catch { message = error.localizedDescription }
        } label: {
            Label(L10n.string("plugins.clip.copy", defaultValue: "이미지 복사"), systemImage: "doc.on.doc")
        }.buttonStyle(.borderedProminent).tint(theme.accent)
            .accessibilityIdentifier("plugin-clip-copy")
    }

    private func saveButton(_ snapshot: PluginPageClipService.Snapshot) -> some View {
        Button {
            do {
                try PluginPageClipService.validate(snapshot, workspace: workspace, isAuthorized: authorizedForExport)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.allowsOtherFileTypes = false
                panel.canCreateDirectories = true
                panel.nameFieldStringValue = snapshot.suggestedFilename
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try PluginPageClipService.save(snapshot, normalizedRect: region, to: url,
                    workspace: workspace, isAuthorized: authorizedForExport)
                message = L10n.string("plugins.clip.saved", defaultValue: "PNG 이미지를 저장했습니다.")
            } catch { message = error.localizedDescription }
        } label: {
            Label(L10n.string("plugins.clip.save", defaultValue: "PNG 저장"), systemImage: "square.and.arrow.down")
        }.accessibilityIdentifier("plugin-clip-save")
    }

    private func selectionCanvas(_ snapshot: PluginPageClipService.Snapshot) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let rect = CGRect(x: region.minX * size.width, y: region.minY * size.height,
                              width: region.width * size.width, height: region.height * size.height)
            ZStack(alignment: .topLeading) {
                Image(decorative: snapshot.image, scale: 1).resizable().interpolation(.high)
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }.fill(.black.opacity(0.42), style: FillStyle(eoFill: true))
                Rectangle().strokeBorder(theme.accent, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                let start = CGPoint(x: min(1, max(0, value.startLocation.x / size.width)),
                                    y: min(1, max(0, value.startLocation.y / size.height)))
                let end = CGPoint(x: min(1, max(0, value.location.x / size.width)),
                                  y: min(1, max(0, value.location.y / size.height)))
                let next = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                  width: abs(end.x - start.x), height: abs(end.y - start.y))
                guard next.width * CGFloat(snapshot.image.width) >= 1,
                      next.height * CGFloat(snapshot.image.height) >= 1 else { return }
                region = next
                message = nil
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.string("plugins.clip.selection", defaultValue: "페이지 클립 영역. 영역 미세 조정에서 키보드로 변경할 수 있습니다."))
            .accessibilityIdentifier("plugin-clip-selection")
        }
        .aspectRatio(snapshot.pixelSize, contentMode: .fit)
        .frame(maxHeight: 600)
        .clipped()
    }

    private enum RegionComponent { case left, top, width, height }

    private func regionStepper(_ key: String, _ fallback: String, component: RegionComponent) -> some View {
        let value = Binding<Int>(get: {
            let fraction: CGFloat
            switch component {
            case .left: fraction = region.minX
            case .top: fraction = region.minY
            case .width: fraction = region.width
            case .height: fraction = region.height
            }
            return Int((fraction * 100).rounded())
        }, set: { percent in
            let fraction = CGFloat(percent) / 100
            switch component {
            case .left:
                region.origin.x = fraction
                region.size.width = min(region.width, 1 - fraction)
            case .top:
                region.origin.y = fraction
                region.size.height = min(region.height, 1 - fraction)
            case .width: region.size.width = min(fraction, 1 - region.minX)
            case .height: region.size.height = min(fraction, 1 - region.minY)
            }
        })
        return Stepper(value: value, in: (component == .left || component == .top) ? 0...99 : 1...100) {
            Text("\(L10n.string(key, defaultValue: fallback))  \(value.wrappedValue)%")
        }
    }
}
