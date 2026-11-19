// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

enum AboutContent {
    static let sceneID = "about-hwattakpdf"
    static let imageResourceName = "AboutAuthor-SeederPowerDrop-UserProvided"
    static let imageResourceExtension = "jpg"

    static let windowSize = CGSize(width: 960, height: 740)

    static let introductionParagraphs = [
        "기존에 큰돈을 주고 구입한 PDF 뷰어·편집 앱이 구독제로 바뀌면서, 기존에 쓰던 기능을 더 이상 사용할 수 없게 되었습니다. 화가 나서 바이브 코딩으로 EmberPDF를 만들었습니다.",
        "그렇게 화가 나서 만들기 시작했지만, 어느새 그 마음은 잉걸불처럼 잔잔해졌습니다. 저와 같은 일을 겪은 사람이 많을 것 같았습니다. 그런 분들을 위해 오랫동안 유지될 앱이 되기를 기원하며 만들었습니다.",
        "PDF계의 Obsidian 같은 앱을 꿈꾸며 플러그인 기능도 넣었습니다. 각자에게 필요한 기능을 더하고, 함께 가능성을 넓혀 가면 좋겠습니다.",
        "누구나 유용하게, 잉걸불처럼 오래도록 EmberPDF를 사용했으면 합니다. 제가 할 수 있는 한 무료로 오랫동안 배포하고 가꾸어 가겠습니다.",
        "감사합니다.\n그리고 ERW FWS WRG"
    ]
    static let introductionLocalizationKeys = (1...5).map { "about.introduction.\($0)" }

    static var localizedIntroductionParagraphs: [String] {
        zip(introductionLocalizationKeys, introductionParagraphs).map { key, fallback in
            L10n.string(key, defaultValue: fallback)
        }
    }

    static var supportTitle: String { L10n.string("about.support.title", defaultValue: "후원하기") }
    static var supportDetail: String {
        L10n.string("about.support.detail", defaultValue: "제가 받은 도움을 다시 나누는 마음으로, 누구나 무료로 쓸 수 있는 도구를 만듭니다. 유용하게 쓰셨다면 작은 후원으로 개발과 유지보수를 응원해 주세요.")
    }
    static var rightsDetail: String {
        L10n.string("about.rights.detail", defaultValue: "컴퓨터를 사용하는 데 필요한 기본 도구는 누구나 무료로, 자유롭게 쓸 수 있어야 한다고 생각합니다. 우리가 나누는 지식이 누군가의 시작이 되고, 사람과 AI가 함께 배우고 만들며 가능성을 넓혀 가길 바랍니다.")
    }

    static let githubURL = validatedExternalURL(
        "https://github.com/SeederPowerDrop/HwattakPDF"
    )
    static let supportURL = validatedExternalURL("https://buymeacoffee.com/master_chief")

    /// About links must always leave the app through an ordinary web origin.
    /// User-info is rejected so a displayed host cannot conceal credentials or
    /// a misleading destination.
    static func validatedExternalURL(_ rawValue: String) -> URL? {
        guard
            rawValue.count <= 2_048,
            let components = URLComponents(string: rawValue),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            let url = components.url
        else {
            return nil
        }
        return url
    }

    static func authorImage(bundle: Bundle = .main) -> NSImage? {
        if let bundledURL = bundle.url(
            forResource: imageResourceName,
            withExtension: imageResourceExtension
        ), let image = NSImage(contentsOf: bundledURL) {
            return image
        }

        #if DEBUG
        let sourceURL = sourceResourcesDirectory
            .appendingPathComponent(imageResourceName)
            .appendingPathExtension(imageResourceExtension)
        return NSImage(contentsOf: sourceURL)
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static var sourceResourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
    }
    #endif
}

/// A self-contained classic dialog palette; reading paper colors should not
/// tint its blue title bar, high-contrast copy, or the donation QR code.
struct AboutClassicPalette {
    let isDark: Bool
    var canvas: Color { isDark ? Color(red: 0.15, green: 0.16, blue: 0.17) : Color(red: 0.93, green: 0.92, blue: 0.86) }
    var text: Color { isDark ? Color(white: 0.94) : Color(white: 0.06) }
    var secondary: Color { isDark ? Color(white: 0.72) : Color(white: 0.34) }
    var card: Color { isDark ? Color(red: 0.19, green: 0.20, blue: 0.21) : Color(red: 0.98, green: 0.98, blue: 0.96) }
    var border: Color { isDark ? Color(white: 0.38) : Color(red: 0.76, green: 0.75, blue: 0.70) }
    var highlight: Color { isDark ? Color(white: 0.49) : .white }
    var shadow: Color { isDark ? Color(white: 0.06) : Color(white: 0.50) }
    var link: Color { isDark ? Color(red: 0.47, green: 0.70, blue: 1) : Color(red: 0, green: 0.28, blue: 0.94) }
    var titleStart: Color { isDark ? Color(red: 0.03, green: 0.16, blue: 0.39) : Color(red: 0.01, green: 0.27, blue: 0.89) }
    var titleEnd: Color { isDark ? Color(red: 0.10, green: 0.29, blue: 0.57) : Color(red: 0.20, green: 0.56, blue: 1) }
}

struct AboutView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsBitcoin = false
    @State private var showsLicenses = false
    private let authorImage: NSImage?
    private let version: String
    private var palette: AboutClassicPalette { AboutClassicPalette(isDark: colorScheme == .dark) }

    init(authorImage: NSImage? = AboutContent.authorImage(), version: String = HwattakPDFRelease.version) {
        self.authorImage = authorImage
        self.version = version
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    introductionHeader
                    ForEach(Array(AboutContent.localizedIntroductionParagraphs.dropFirst().dropLast().enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.string("about.rights.title", defaultValue: "소프트웨어 기본권"))
                            .font(.system(size: 16, weight: .bold))
                        Text(AboutContent.rightsDetail).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(AboutContent.localizedIntroductionParagraphs.last ?? "")
                        .fixedSize(horizontal: false, vertical: true)
                    supportSection
                }
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            bottomBar
        }
        .frame(width: AboutContent.windowSize.width, height: AboutContent.windowSize.height)
        .background(palette.canvas)
        .background(AboutWindowChrome(title: L10n.string("about.title"), color: NSColor(palette.canvas)))
        .overlay { Rectangle().stroke(palette.titleStart, lineWidth: 1).allowsHitTesting(false) }
        // Extend the border with the content; applying this before the overlay
        // places its top edge at the native title bar's safe-area boundary.
        .ignoresSafeArea()
        .tint(palette.link)
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showsLicenses) {
            AboutLicensesView()
        }
    }

    private var titleBar: some View {
        HStack {
            Text(L10n.string("about.title", defaultValue: "EmberPDF 정보"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 0, x: 1, y: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(AboutTitlebarDragArea().accessibilityHidden(true))
            Button { dismissWindow(id: AboutContent.sceneID) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 33, height: 33)
                    .background(LinearGradient(colors: [Color(red: 1, green: 0.52, blue: 0.38), Color(red: 0.81, green: 0.14, blue: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay { RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.94), lineWidth: 1.5) }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(L10n.string("about.close", defaultValue: "닫기"))
            .accessibilityLabel(L10n.string("about.close", defaultValue: "닫기"))
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(LinearGradient(colors: [palette.titleStart, palette.titleEnd], startPoint: .leading, endPoint: .trailing))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.25)).frame(height: 1) }
    }

    private var introductionHeader: some View {
        HStack(alignment: .top, spacing: 24) {
            authorPortrait
            VStack(alignment: .leading, spacing: 9) {
                Text("EmberPDF \(version)")
                    .font(.system(size: 29, weight: .bold))
                    .environment(\.layoutDirection, .leftToRight)
                Text(L10n.string("about.tagline", defaultValue: "누구나 자유롭게 쓰는 macOS PDF 도구."))
                    .font(.system(size: 16))
                    .foregroundStyle(palette.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { guideLink; githubLink }
                    VStack(alignment: .leading, spacing: 6) { guideLink; githubLink }
                }
                .font(.system(size: 15, weight: .medium))
                .padding(.vertical, 2)
                Text(AboutContent.localizedIntroductionParagraphs.first ?? "")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var guideLink: some View {
        Button { openWindow(id: HelpTutorialContent.sceneID) } label: {
            Text(L10n.string("about.guide", defaultValue: "사용 가이드")).underline()
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.link)
    }

    @ViewBuilder private var githubLink: some View {
        if let url = AboutContent.githubURL {
            Link(destination: url) { Text(L10n.string("about.github", defaultValue: "GitHub · SeederPowerDrop")).underline() }
                .foregroundStyle(palette.link)
                .environment(\.layoutDirection, .leftToRight)
                .help(url.absoluteString)
        }
    }

    private var authorPortrait: some View {
        Group {
            if let authorImage {
                Image(nsImage: authorImage).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "person.crop.square").resizable().scaledToFit().padding(30).foregroundStyle(.gray)
            }
        }
        .frame(width: 150, height: 150)
        .background(.white)
        .overlay { Rectangle().stroke(palette.border, lineWidth: 2) }
        .accessibilityLabel(L10n.string("about.image_accessibility", defaultValue: "제작자가 제공한 흑백 캐릭터 그림"))
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Rectangle().fill(palette.border).frame(height: 1).padding(.bottom, 5)
            Text(AboutContent.supportTitle).font(.system(size: 18, weight: .bold))
            Text(AboutContent.supportDetail).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if let url = AboutContent.supportURL {
                    Link(destination: url) { supportCard("Buy Me a Coffee", symbol: "cup.and.saucer", color: Color(red: 1, green: 0.84, blue: 0.27)) }
                        .help(url.absoluteString)
                }
                Link(destination: AboutSupport.koFiURL) { supportCard("Ko-fi", symbol: "heart.fill", color: Color(red: 1, green: 0.83, blue: 0.87)) }
                    .help(AboutSupport.koFiURL.absoluteString)
                Button { showsBitcoin.toggle() } label: {
                    supportCard("BlueWallet", symbol: "wallet.bifold", color: Color(red: 0.82, green: 0.89, blue: 1), subtitle: L10n.string("about.bitcoin", defaultValue: "Bitcoin (BTC)"), disclosure: true)
                }
                .accessibilityIdentifier("about-bitcoin-support")
                .popover(isPresented: $showsBitcoin) { AboutBitcoinSupportView() }
            }
            .buttonStyle(.plain)
            Text(L10n.string("about.support.optional", defaultValue: "후원은 자유롭게 선택할 수 있으며, 후원 여부에 따라 앱 기능이 달라지지 않습니다."))
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func supportCard(_ name: String, symbol: String, color: Color, subtitle: String? = nil, disclosure: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 23, weight: .medium)).foregroundStyle(Color(white: 0.16))
                .frame(width: 48, height: 48).background(color, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 17, weight: .bold)).lineLimit(1).minimumScaleFactor(0.85)
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(palette.secondary) }
            }
            Spacer(minLength: 0)
            if disclosure { Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)) }
        }
        .foregroundStyle(palette.text)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 78)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(palette.border, lineWidth: 1) }
        .contentShape(Rectangle())
        .environment(\.layoutDirection, .leftToRight)
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 10)
            Button(L10n.string("about.licenses", defaultValue: "오픈소스 라이선스")) { showsLicenses = true }
                .buttonStyle(AboutClassicButtonStyle(palette: palette))
            Button(L10n.string("about.confirm", defaultValue: "확인")) { dismissWindow(id: AboutContent.sceneID) }
                .buttonStyle(AboutClassicButtonStyle(palette: palette))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 20)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct AboutClassicButtonStyle: ButtonStyle {
    let palette: AboutClassicPalette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 20)
            .frame(minWidth: 84, minHeight: 36)
            .background(palette.canvas)
            .overlay(alignment: .top) { Rectangle().fill(configuration.isPressed ? palette.shadow : palette.highlight).frame(height: 2) }
            .overlay(alignment: .leading) { Rectangle().fill(configuration.isPressed ? palette.shadow : palette.highlight).frame(width: 2) }
            .overlay(alignment: .bottom) { Rectangle().fill(configuration.isPressed ? palette.highlight : palette.shadow).frame(height: 2) }
            .overlay(alignment: .trailing) { Rectangle().fill(configuration.isPressed ? palette.highlight : palette.shadow).frame(width: 2) }
            .offset(x: configuration.isPressed ? 1 : 0, y: configuration.isPressed ? 1 : 0)
    }
}

/// Apply only to the dedicated About window, keeping native window lifetime,
/// keyboard handling and accessibility while using the custom title controls.
private struct AboutWindowChrome: NSViewRepresentable {
    let title: String
    let color: NSColor
    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.dialogTitle = title
        view.dialogColor = color
        return view
    }
    func updateNSView(_ view: ChromeView, context: Context) {
        view.dialogTitle = title
        view.dialogColor = color
        view.applyChrome()
    }
    final class ChromeView: NSView {
        var dialogTitle = ""
        var dialogColor = NSColor.windowBackgroundColor
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyChrome() }
        func applyChrome() {
            guard let window else { return }
            window.title = dialogTitle
            window.backgroundColor = dialogColor
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            // A transparent native title bar can still draw its separator over
            // our custom title bar when content fills the window frame.
            window.titlebarSeparatorStyle = .none
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
        }
    }
}

private struct AboutTitlebarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
    final class DragView: NSView {
        override var acceptsFirstResponder: Bool { false }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
