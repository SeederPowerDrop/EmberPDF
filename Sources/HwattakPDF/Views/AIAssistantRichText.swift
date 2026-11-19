// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI
import WebKit

/// Selectable, accessible Markdown and TeX with a completely offline renderer.
/// Only an explicit image-button click can start an external image request.
struct AIAssistantRichText: View {
    let source: String
    var images: [AIResponseImage] = []
    let theme: HwattakPDFTheme
    @State private var contentHeight = 24.0

    var body: some View {
        Group {
            if let resourceRoot = AIAssistantRichTextDocument.resourceRoot,
               source.count <= AIAssistantRichTextDocument.maximumMarkdownCharacters {
                AIAssistantRichWebView(source: source, images: images, theme: theme,
                                       resourceRoot: resourceRoot, contentHeight: $contentHeight)
                    .frame(height: contentHeight)
            } else {
                // Missing assets or unusually large output never makes the
                // response disappear. Preserve all original text and spacing.
                Text(verbatim: source).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private final class AIAssistantResponseWebView: WKWebView {
    var usesInnerVerticalScrolling = false

    override func scrollWheel(with event: NSEvent) {
        if !usesInnerVerticalScrolling, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

private struct AIAssistantRichWebView: NSViewRepresentable {
    let source: String
    let images: [AIResponseImage]
    let theme: HwattakPDFTheme
    let resourceRoot: URL
    @Binding var contentHeight: Double

    func makeCoordinator() -> Coordinator { Coordinator(contentHeight: $contentHeight) }

    func makeNSView(context: Context) -> AIAssistantResponseWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(AIAssistantRichResourceHandler(root: resourceRoot), forURLScheme: "ember-ai-resource")
        configuration.userContentController.add(context.coordinator, name: "richText")
        let view = AIAssistantResponseWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.allowsLinkPreview = false
        context.coordinator.webView = view
        context.coordinator.update(source: source, images: images, theme: theme)
        view.load(URLRequest(url: URL(string: "ember-ai-resource://bundle/index.html")!))
        return view
    }

    func updateNSView(_ view: AIAssistantResponseWebView, context: Context) {
        context.coordinator.contentHeight = $contentHeight
        context.coordinator.update(source: source, images: images, theme: theme)
    }

    static func dismantleNSView(_ view: AIAssistantResponseWebView, coordinator: Coordinator) {
        coordinator.cancelImages()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "richText")
        view.navigationDelegate = nil
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: AIAssistantResponseWebView?
        var contentHeight: Binding<Double>
        private var ready = false
        private var currentSource: String?
        private var currentImages: [AIResponseImage] = []
        private var currentTheme: [String: String] = [:]
        private var pendingPayload: [String: Any]?
        private var imageTasks: [String: Task<Void, Never>] = [:]
        private var acceptedImages: [AIResponseImage] = []

        init(contentHeight: Binding<Double>) { self.contentHeight = contentHeight }

        func update(source: String, images: [AIResponseImage], theme: HwattakPDFTheme) {
            if source != currentSource || images != currentImages {
                cancelImages()
                currentSource = source; currentImages = images
                pendingPayload = AIAssistantRichTextDocument.payload(source: source, images: images)
            }
            let colors = ["text": css(theme.primaryText), "secondary": css(theme.secondaryText),
                          "accent": css(theme.accent), "surface": css(theme.hoverFill), "border": css(theme.border)]
            let changed = colors != currentTheme
            currentTheme = colors
            guard ready else { return }
            if changed { applyTheme() }
            renderPendingPayload()
        }

        private func css(_ color: Color) -> String {
            let color = NSColor(color).usingColorSpace(.sRGB) ?? .labelColor
            return "rgba(\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255)),\(color.alphaComponent))"
        }

        private func applyTheme() {
            webView?.callAsyncJavaScript("window.EmberRichText.setTheme(theme)", arguments: ["theme": currentTheme], in: nil, in: .page, completionHandler: nil)
        }

        private func renderPendingPayload() {
            guard let payload = pendingPayload else { return }
            pendingPayload = nil
            webView?.callAsyncJavaScript("window.EmberRichText.render(payload)", arguments: ["payload": payload], in: nil, in: .page) { [weak self] result in
                if case .failure = result {
                    // An unexpected renderer failure remains selectable and
                    // lossless, with pre-wrap line breaks instead of blank UI.
                    guard let self else { return }
                    self.webView?.callAsyncJavaScript("const r=document.getElementById('response'); r.style.whiteSpace='pre-wrap'; r.textContent=source;", arguments: ["source": self.currentSource ?? ""], in: nil, in: .page, completionHandler: nil)
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            switch kind {
            case "ready":
                ready = true; applyTheme(); renderPendingPayload()
            case "height":
                guard let value = body["height"] as? Double,
                      let height = AIAssistantRichTextDocument.boundedHeight(value) else { return }
                webView?.usesInnerVerticalScrolling = value > AIAssistantRichTextDocument.maximumHeight
                if abs(contentHeight.wrappedValue - height) > 0.5 {
                    contentHeight.wrappedValue = height
                }
            case "link":
                guard let source = body["url"] as? String, let url = URL(string: source),
                      AIEndpointPolicy.isValidExternalWebURL(url) else { return }
                NSWorkspace.shared.open(url)
            case "image": loadImage(body)
            default: break
            }
        }

        private func loadImage(_ body: [String: Any]) {
            guard let index = body["index"] as? Int, (0 ..< AIResponseImageLimits.maximumImageCount).contains(index),
                  let generation = body["generation"] as? Int,
                  let source = body["source"] as? String,
                  let embedded = body["embedded"] as? Bool else { return }
            let key = "\(generation)-\(index)"
            guard imageTasks[key] == nil else { return }
            imageTasks[key] = Task { @MainActor [weak self] in
                let image: AIResponseImage?
                if embedded {
                    image = AIResponseImage(dataURL: source)
                } else if let url = AIAssistantRichTextDocument.validRemoteImageURL(source) {
                    image = await AIAssistantRichImageLoader.load(url)
                } else { image = nil }
                guard !Task.isCancelled, let self else { return }
                var acceptedImage: AIResponseImage?
                if let image {
                    let bounded = AIResponseImage.bounded(self.acceptedImages + [image])
                    if bounded.contains(where: { $0.id == image.id }) {
                        self.acceptedImages = bounded
                        acceptedImage = image
                    }
                }
                let dataURL = acceptedImage.flatMap(AIAssistantRichTextDocument.imagePayload)?["source"]
                self.webView?.callAsyncJavaScript("window.EmberRichText.acceptImage(index, generation, dataURL)",
                    arguments: ["index": index, "generation": generation, "dataURL": dataURL as Any? ?? NSNull()],
                    in: nil, in: .page, completionHandler: nil)
                self.imageTasks.removeValue(forKey: key)
            }
        }

        func cancelImages() {
            imageTasks.values.forEach { $0.cancel() }; imageTasks.removeAll()
            acceptedImages.removeAll()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Native link handling above requires a user click. No provider
            // content may navigate this renderer or open another WebKit view.
            let isInitialPage = navigationAction.request.url?.absoluteString == "ember-ai-resource://bundle/index.html"
            decisionHandler(isInitialPage && !ready ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // Old image completions refer to the terminated page's generation
            // and must not populate the freshly bootstrapped renderer.
            cancelImages()
            ready = false
            if let currentSource { pendingPayload = AIAssistantRichTextDocument.payload(source: currentSource, images: currentImages) }
            webView.reload()
        }
    }
}

final class AIAssistantRichResourceHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let url = AIAssistantRichTextDocument.resourceURL(for: requestURL, root: root),
              let data = try? Data(contentsOf: url) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mimeType: String
        switch url.pathExtension {
        case "html": mimeType = "text/html"
        case "js": mimeType = "application/javascript"
        case "css": mimeType = "text/css"
        case "woff2": mimeType = "font/woff2"
        default: urlSchemeTask.didFailWithError(URLError(.unsupportedURL)); return
        }
        urlSchemeTask.didReceive(URLResponse(url: requestURL, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: mimeType.hasPrefix("text/") || mimeType.contains("javascript") ? "utf-8" : nil))
        urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/// Images use a separate, cookie-free session and never share provider keys.
/// Redirects and authentication challenges cannot broaden the clicked target.
private final class AIAssistantRichImageLoader: NSObject, URLSessionTaskDelegate {
    static func load(_ url: URL) async -> AIResponseImage? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 25
        let delegate = AIAssistantRichImageLoader()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: url)
            request.setValue("image/png,image/jpeg,image/webp,image/gif", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.expectedContentLength <= AIResponseImageLimits.maximumImageByteCount else { return nil }
            var data = Data(); data.reserveCapacity(min(262_144, AIResponseImageLimits.maximumImageByteCount))
            for try await byte in bytes {
                if Task.isCancelled || data.count >= AIResponseImageLimits.maximumImageByteCount { return nil }
                data.append(byte)
            }
            return AIResponseImage(data: data, mimeType: response.mimeType)
        } catch { return nil }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
