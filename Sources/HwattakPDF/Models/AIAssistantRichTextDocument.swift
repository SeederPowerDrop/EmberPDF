// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Transfers response text as data, never as an HTML or JavaScript fragment.
/// The existing lossless parser keeps code opaque and recognizes all four
/// supported TeX delimiters before Markdown consumes their backslashes.
enum AIAssistantRichTextDocument {
    static let maximumHeight: Double = 24_000
    static let maximumMarkdownCharacters = 1_000_000

    static func payload(source: String, images: [AIResponseImage] = []) -> [String: Any] {
        let prefix = "EMBERMATH" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "X"
        var markdown = ""
        var equations: [[String: Any]] = []
        for segment in AIAssistantMarkupParser.parse(source).segments {
            switch segment {
            case let .markdown(value): markdown += value
            case let .inlineMath(expression, original), let .blockMath(expression, original):
                let token = prefix + String(equations.count) + "X"
                equations.append(["token": token, "expression": expression, "display": segment.isBlockMath, "source": original])
                markdown += token
            }
        }
        return [
            "markdown": markdown,
            "equations": equations,
            "images": images.compactMap(imagePayload),
            "labels": [
                "load": L10n.string("ai.rich.load_image", defaultValue: "이미지 불러오기"),
                "loading": L10n.string("ai.rich.loading_image", defaultValue: "불러오는 중…"),
                "failed": L10n.string("ai.rich.image_failed", defaultValue: "이미지를 불러올 수 없습니다."),
                "unavailable": L10n.string("ai.rich.image_unavailable", defaultValue: "지원하지 않는 이미지입니다.")
            ]
        ]
    }

    static func imagePayload(_ image: AIResponseImage) -> [String: String]? {
        let alt = L10n.string("ai.rich.image_alt", defaultValue: "AI 응답 이미지")
        if let data = image.data, let mimeType = image.mimeType {
            return ["source": "data:\(mimeType);base64,\(data.base64EncodedString())", "alt": alt]
        }
        if let url = image.remoteURL {
            return ["source": url.absoluteString, "alt": alt]
        }
        return nil
    }

    static func validRemoteImageURL(_ source: String) -> URL? {
        guard source.utf8.count <= 8_192,
              let url = URL(string: source),
              url.scheme?.lowercased() == "https",
              (url.port == nil || url.port == 443),
              AIEndpointPolicy.isValidExternalWebURL(url) else { return nil }
        return url
    }

    static func boundedHeight(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0 else { return nil }
        return max(24, min(ceil(value), maximumHeight))
    }

    /// A dedicated custom scheme serves this finite bundle only. There is no
    /// file:// read-access grant, URL decoding traversal, or network fallback.
    static func resourceURL(for request: URL, root: URL) -> URL? {
        guard request.scheme == "ember-ai-resource", request.host == "bundle",
              request.query == nil, request.fragment == nil,
              request.user == nil, request.password == nil,
              let path = request.path.removingPercentEncoding,
              !path.contains("\\"), !path.contains("\0") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(".."), !parts.contains(".") else { return nil }
        let allowed = ["index.html", "renderer.js", "renderer.css", "katex/katex.min.js", "katex/katex.min.css", "marked/marked.umd.js", "dompurify/purify.min.js"]
        let relative = String(path.drop(while: { $0 == "/" }))
        let isFont = relative.hasPrefix("katex/fonts/KaTeX_") && relative.hasSuffix(".woff2")
            && relative.split(separator: "/").count == 3
        guard allowed.contains(relative) || isFont else { return nil }
        let candidate = root.appendingPathComponent(relative).resolvingSymlinksInPath()
        let resolvedRoot = root.resolvingSymlinksInPath().path + "/"
        return candidate.path.hasPrefix(resolvedRoot) ? candidate : nil
    }

    static var resourceRoot: URL? {
        var candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("AIRichText", isDirectory: true)
        ]
        #if DEBUG
        // SwiftPM's command-line/debug product does not have an app bundle.
        // Do not embed the developer's checkout path in a release executable.
        candidates.append(
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/AIRichText", isDirectory: true)
        )
        #endif
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path)
        }
    }
}
