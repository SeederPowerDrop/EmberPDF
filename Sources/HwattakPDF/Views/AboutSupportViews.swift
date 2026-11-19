// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum AboutSupport {
    // Public support destinations shared by the author's AlmaengRe and ZipLens.
    static let koFiURL = URL(string: "https://ko-fi.com/seederpower")!
    static let bitcoinAddress = "BC1QUEUAX3FJP77NZUKF732AEWVFE0YVS9ZPKUMLTV"
    static let bitcoinURI = "bitcoin:\(bitcoinAddress)"

    /// QR and clipboard derive from the same displayed public receiving address.
    static func makeBitcoinQRCode() -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(bitcoinURI.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        return CIContext(options: [.useSoftwareRenderer: true])
            .createCGImage(scaled, from: scaled.extent)
    }
}

struct AboutBitcoinSupportView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false
    private static let qrCode = AboutSupport.makeBitcoinQRCode()
    private var palette: AboutClassicPalette { AboutClassicPalette(isDark: colorScheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "wallet.bifold")
                    .foregroundStyle(palette.link)
                Text(verbatim: "BlueWallet")
                    .font(.system(size: 20, weight: .bold))
                Spacer(minLength: 0)
                Text(L10n.string("about.bitcoin", defaultValue: "Bitcoin (BTC)"))
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondary)
            }

            Text(L10n.string("about.bitcoin.detail", defaultValue: "아래 주소로 Bitcoin(BTC)을 후원할 수 있습니다."))
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)

            if let qrCode = Self.qrCode {
                HStack {
                    Spacer(minLength: 0)
                    Image(qrCode, scale: 1, label: Text(L10n.string("about.bitcoin.qr", defaultValue: "Bitcoin 후원 주소 QR 코드")))
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 180, height: 180)
                        // Keep a white quiet zone in every app/reading appearance.
                        .padding(20)
                        .background(.white)
                        .accessibilityLabel(L10n.string("about.bitcoin.qr", defaultValue: "Bitcoin 후원 주소 QR 코드"))
                    Spacer(minLength: 0)
                }
            }

            Text(verbatim: AboutSupport.bitcoinAddress)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(palette.card)
                .overlay { Rectangle().stroke(palette.border, lineWidth: 1) }
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityIdentifier("about-bitcoin-address")

            HStack {
                Spacer(minLength: 0)
                Button(L10n.string(
                    copied ? "about.bitcoin.copied" : "about.bitcoin.copy",
                    defaultValue: copied ? "주소를 복사했습니다" : "주소 복사"
                )) {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(AboutSupport.bitcoinAddress, forType: .string)
                }
                .buttonStyle(AboutClassicButtonStyle(palette: palette))
                .accessibilityIdentifier("about-bitcoin-copy")
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(palette.text)
        .padding(24)
        .frame(width: 400)
        .background(palette.canvas)
    }
}

/// Only bundled, local notices are read. Source paths are a debug-only fallback
/// for SwiftPM development; a distributed app never depends on its checkout.
enum AboutLicenseContent {
    struct Document {
        let title: String
        let text: String
    }

    static func projectDocuments(bundle: Bundle = .main) -> [Document] {
        [
            document(title: "EmberPDF · Mozilla Public License 2.0", bundledPath: "Legal/LICENSE", sourcePath: "LICENSE", bundle: bundle),
            document(title: "EmberPDF · NOTICE", bundledPath: "Legal/NOTICE", sourcePath: "NOTICE", bundle: bundle),
            document(title: "About artwork · NOTICE", bundledPath: "Legal/AboutAuthor-UserProvided-NOTICE.txt", sourcePath: "Resources/AboutAuthor-UserProvided-NOTICE.txt", bundle: bundle)
        ].compactMap { $0 }
    }

    static func componentDocuments(bundle: Bundle = .main) -> [Document] {
        var documents = [
            document(title: "AI response renderer · THIRD-PARTY-NOTICES", bundledPath: "AIRichText/THIRD-PARTY-NOTICES.txt", sourcePath: "Resources/AIRichText/THIRD-PARTY-NOTICES.txt", bundle: bundle),
            document(title: "KaTeX · LICENSE", bundledPath: "AIRichText/katex/LICENSE", sourcePath: "Resources/AIRichText/katex/LICENSE", bundle: bundle),
            document(title: "Marked · LICENSE", bundledPath: "AIRichText/marked/LICENSE", sourcePath: "Resources/AIRichText/marked/LICENSE", bundle: bundle),
            document(title: "DOMPurify · LICENSE", bundledPath: "AIRichText/dompurify/LICENSE", sourcePath: "Resources/AIRichText/dompurify/LICENSE", bundle: bundle),
            document(title: "PDFium binary distribution · LICENSE", bundledPath: "Legal/PDFium/LICENSE", sourcePath: "Vendor/PDFium/LICENSE", bundle: bundle)
        ].compactMap { $0 }

        if let directory = resourceURL(bundledPath: "Legal/PDFium/licenses", sourcePath: "Vendor/PDFium/licenses", bundle: bundle),
           let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                documents.append(Document(title: "PDFium · \(url.lastPathComponent)", text: text))
            }
        }
        return documents
    }

    static func combinedText(_ documents: [Document]) -> String {
        documents.map { "\($0.title)\n\n\($0.text)" }.joined(separator: "\n\n────────────────────────────────────────\n\n")
    }

    private static func document(title: String, bundledPath: String, sourcePath: String, bundle: Bundle) -> Document? {
        guard let url = resourceURL(bundledPath: bundledPath, sourcePath: sourcePath, bundle: bundle),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Document(title: title, text: text)
    }

    private static func resourceURL(bundledPath: String, sourcePath: String, bundle: Bundle) -> URL? {
        if let resources = bundle.resourceURL {
            let url = resources.appendingPathComponent(bundledPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        #if DEBUG
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = sourceRoot.appendingPathComponent(sourcePath)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        #endif
        return nil
    }
}

struct AboutLicensesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsComponents = false
    private let projectText: String
    private let componentsText: String
    private var palette: AboutClassicPalette { AboutClassicPalette(isDark: colorScheme == .dark) }

    init(bundle: Bundle = .main) {
        projectText = AboutLicenseContent.combinedText(AboutLicenseContent.projectDocuments(bundle: bundle))
        componentsText = AboutLicenseContent.combinedText(AboutLicenseContent.componentDocuments(bundle: bundle))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("about.licenses", defaultValue: "오픈소스 라이선스"))
                .font(.system(size: 22, weight: .bold))
            Text(L10n.string("about.licenses.detail", defaultValue: "EmberPDF는 Mozilla Public License 2.0으로 배포됩니다. 함께 사용하는 오픈소스 구성 요소의 라이선스와 저작권 고지도 확인할 수 있습니다."))
                .font(.system(size: 14))
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(L10n.string("about.licenses", defaultValue: "오픈소스 라이선스"), selection: $showsComponents) {
                Text(L10n.string("about.licenses.project", defaultValue: "EmberPDF 라이선스")).tag(false)
                Text(L10n.string("about.licenses.components", defaultValue: "구성 요소와 저작권 고지")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                Text(verbatim: showsComponents ? componentsText : projectText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .id(showsComponents)
            .environment(\.layoutDirection, .leftToRight)
            .background(palette.card)
            .overlay { Rectangle().stroke(palette.border, lineWidth: 1) }
            HStack {
                Spacer(minLength: 0)
                Button(L10n.string("about.confirm", defaultValue: "확인")) { dismiss() }
                    .buttonStyle(AboutClassicButtonStyle(palette: palette))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(palette.text)
        .padding(24)
        .frame(width: 740, height: 560)
        .background(palette.canvas)
        .onExitCommand { dismiss() }
    }
}
