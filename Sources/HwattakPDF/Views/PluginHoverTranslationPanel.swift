// SPDX-License-Identifier: MPL-2.0
import AppKit
import PDFKit
import SwiftUI

/// Local-window events only. No accessibility permission, global input monitor,
/// clipboard access or background observation is used by this host feature.
@MainActor
final class PluginHoverCapture: ObservableObject {
    struct Word: Equatable { let text: String; let pageNumber: Int }
    @Published private(set) var word: Word?
    private var monitor: Any?
    private var pending: Task<Void, Never>?
    private weak var window: NSWindow?
    private var previousMouseEvents = false
    private var generation = UUID()

    func start(window: NSWindow, workspace: PDFWorkspaceState, isAuthorized: @escaping () -> Bool) {
        stop()
        self.window = window
        previousMouseEvents = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .scrollWheel]) { [weak self, weak workspace] event in
            guard let self, let workspace else { return event }
            self.pending?.cancel()
            if event.type != .mouseMoved { return event }
            guard event.window === self.window, self.window?.isKeyWindow == true,
                  NSApp.isActive, NSApp.modalWindow == nil, self.window?.attachedSheet == nil,
                  isAuthorized(), workspace.allows(.copyAndPaste) else { return event }
            guard let content = event.window?.contentView,
                  let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return event }
            var ancestor: NSView? = hit
            while ancestor != nil && !(ancestor is InteractivePDFView) { ancestor = ancestor?.superview }
            guard let view = ancestor as? InteractivePDFView,
                  view.workspaceState === workspace, view.viewportContext == .normal,
                  view.document === workspace.document else { return event }
            let point = view.convert(event.locationInWindow, from: nil)
            let revision = workspace.revision
            let id = self.generation
            self.pending = Task { @MainActor [weak self, weak view, weak workspace] in
                do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
                guard let self, let view, let workspace, !Task.isCancelled,
                      self.generation == id, workspace.revision == revision, isAuthorized(),
                      self.window?.isKeyWindow == true, NSApp.isActive,
                      workspace.allows(.copyAndPaste), view.document === workspace.document,
                      let page = view.page(for: point, nearest: false),
                      let document = workspace.document else { return }
                let pagePoint = view.convert(point, to: page)
                guard let selection = page.selectionForWord(at: pagePoint),
                      selection.bounds(for: page).contains(pagePoint),
                      let text = Self.boundedWord(selection.string ?? "") else { return }
                let pageIndex = document.index(for: page)
                guard pageIndex != NSNotFound else { return }
                let word = Word(text: text, pageNumber: pageIndex + 1)
                if self.word != word { self.word = word }
            }
            return event
        }
    }
    static func boundedWord(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 120, text.utf8.count <= 512,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
    func stop() {
        generation = UUID(); pending?.cancel(); pending = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let window { window.acceptsMouseMovedEvents = previousMouseEvents }
        window = nil; word = nil
    }
}

@MainActor
struct PluginHoverTranslationPanel: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let isAuthorized: () -> Bool
    @StateObject private var capture = PluginHoverCapture()
    @State private var enabled = false
    @State private var target = L10n.currentLanguage.locale.language.languageCode?.identifier ?? "ko"
    @State private var job: ApplePageTranslationJob?
    @State private var translated = ""
    @State private var error: String?
    @EmberTheme private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.string("plugins.hover.title", defaultValue: "커서를 올려 번역"), systemImage: "character.cursor.ibeam").font(.headline)
            Text(L10n.string("plugins.hover.detail", defaultValue: "켜기를 누른 뒤 PDF의 단어 위에 잠시 커서를 멈추세요. 이 패널이 열려 있을 때만 macOS 기기 내 번역을 사용합니다."))
                .font(.callout).foregroundStyle(theme.secondaryText)
            if #available(macOS 15.0, *) {
                Picker(L10n.string("plugins.hover.language", defaultValue: "번역 언어"), selection: $target) {
                    ForEach(["ko", "en", "fr", "de", "es", "ja", "zh", "pt", "ru", "ar", "vi"], id: \.self) { code in
                        Text(L10n.currentLanguage.locale.localizedString(forLanguageCode: code) ?? code).tag(code)
                    }
                }
                Toggle(L10n.string("plugins.hover.enable", defaultValue: "커서 번역 켜기"), isOn: Binding(
                    get: { enabled }, set: { enabled = $0 && isAuthorized() }
                )).toggleStyle(.switch).accessibilityIdentifier("plugin-hover-enable")
                Text(L10n.string("plugins.hover.download", defaultValue: "처음 사용하는 언어는 macOS에서 언어팩 다운로드를 안내할 수 있습니다."))
                    .font(.caption).foregroundStyle(theme.secondaryText)
            } else {
                Text(L10n.string("plugins.hover.requires_system", defaultValue: "자동 커서 번역은 macOS 15 이상에서 사용할 수 있습니다."))
            }
            if let word = capture.word {
                VStack(alignment: .leading, spacing: 12) {
                    Text(word.text).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text(L10n.format("ai.related.page", word.pageNumber)).font(.caption).foregroundStyle(theme.accent)
                    if job != nil { ProgressView().controlSize(.small) }
                    if !translated.isEmpty { Text(translated).font(.title3).textSelection(.enabled) }
                    if let error { Text(error).font(.caption).foregroundStyle(theme.secondaryText) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
            }
            Spacer()
        }.padding(18)
            .background {
                if enabled {
                    PluginHoverWindowBridge(capture: capture, workspace: workspace, isAuthorized: isAuthorized)
                        .frame(width: 0, height: 0)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if #available(macOS 15.0, *), let job {
                    ApplePageTranslationBridge(job: job) { id, result in
                        guard self.job?.id == id, enabled, isAuthorized() else { return }
                        self.job = nil
                        switch result {
                        case let .success(value): translated = value.blocks.map(\.translated).joined(separator: "\n")
                        case let .failure(failure): error = failure.localizedDescription
                        }
                    }.id(job.id)
                }
            }
            .onChange(of: capture.word) { _, _ in translate() }
            .onChange(of: target) { _, _ in translate() }
            .onChange(of: enabled) { _, value in if !value { capture.stop(); job = nil; translated = "" } }
            .onDisappear { capture.stop(); job = nil }
            .accessibilityIdentifier("plugin-hover-panel")
    }
    private func translate() {
        job = nil; translated = ""; error = nil
        guard #available(macOS 15.0, *), enabled, isAuthorized(), let word = capture.word else { return }
        let input = PageTranslationInput(sourceText: word.text, targetLanguageCode: target)
        job = ApplePageTranslationJob(id: UUID(), input: input, blocks: [TranslationBlock(id: "hover", source: word.text)])
    }
}

private struct PluginHoverWindowBridge: NSViewRepresentable {
    let capture: PluginHoverCapture
    let workspace: PDFWorkspaceState
    let isAuthorized: () -> Bool
    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.attach = { [weak capture, weak workspace] window in
            guard let capture, let workspace, isAuthorized() else { return }
            capture.start(window: window, workspace: workspace, isAuthorized: isAuthorized)
        }
        view.detach = { [weak capture] in capture?.stop() }
        return view
    }
    func updateNSView(_ view: WindowProbe, context: Context) {}
    static func dismantleNSView(_ view: WindowProbe, coordinator: ()) { view.detach?() }
    final class WindowProbe: NSView {
        var attach: ((NSWindow) -> Void)?
        var detach: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attach?(window) } else { detach?() }
        }
    }
}
