// SPDX-License-Identifier: MPL-2.0

import Foundation
import AppKit
import ImageIO
import WebKit
import XCTest
@testable import HwattakPDF

final class AIAssistantRichTextDocumentTests: XCTestCase {
    func testEquationsAreDataAndMarkdownRetainsParagraphsListsAndCode() {
        let source = #"""
        ## 핵심

        첫 문단입니다.

        1. 첫 항목 $x^2$
        2. 둘째 항목

        \[\frac{a}{b}\]

        ```tex
        $not_math$
        ```
        """#
        let payload = AIAssistantRichTextDocument.payload(source: source)
        let markdown = payload["markdown"] as! String
        let equations = payload["equations"] as! [[String: Any]]
        XCTAssertTrue(markdown.contains("## 핵심\n\n첫 문단입니다.\n\n1. 첫 항목"))
        XCTAssertTrue(markdown.contains("2. 둘째 항목\n\n"))
        XCTAssertTrue(markdown.contains("```tex\n$not_math$\n```"))
        XCTAssertEqual(equations.count, 2)
        XCTAssertEqual(equations[0]["expression"] as? String, "x^2")
        XCTAssertEqual(equations[1]["expression"] as? String, #"\frac{a}{b}"#)
        XCTAssertEqual(equations[1]["display"] as? Bool, true)
    }

    func testImageURLPolicyRejectsLocalTargetsCredentialsAndNonStandardPorts() {
        XCTAssertNotNil(AIAssistantRichTextDocument.validRemoteImageURL("https://images.example.org/a.png?width=400"))
        for value in ["http://example.org/a.png", "file:///etc/passwd", "https://localhost/a", "https://127.1/a", "https://2130706433/a", "https://[::1]/a", "https://machine.local/a", "https://printer/a", "https://user:secret@example.org/a", "https://example.org:8443/a", "javascript:alert(1)"] {
            XCTAssertNil(AIAssistantRichTextDocument.validRemoteImageURL(value), value)
        }
    }

    func testResourceSchemeCannotReadArbitraryFiles() throws {
        let root = try XCTUnwrap(AIAssistantRichTextDocument.resourceRoot)
        XCTAssertNotNil(AIAssistantRichTextDocument.resourceURL(for: URL(string: "ember-ai-resource://bundle/renderer.js")!, root: root))
        XCTAssertNotNil(AIAssistantRichTextDocument.resourceURL(for: URL(string: "ember-ai-resource://bundle/katex/fonts/KaTeX_Main-Regular.woff2")!, root: root))
        for path in ["ember-ai-resource://other/renderer.js", "file:///etc/passwd", "ember-ai-resource://bundle/vendor-manifest.json", "ember-ai-resource://bundle/%2e%2e/Info.plist", "ember-ai-resource://bundle/katex/fonts/../../Info.plist", "ember-ai-resource://bundle/renderer.js?other=1", "ember-ai-resource://bundle/renderer.js#x", "ember-ai-resource://bundle/katex/fonts/no.woff2"] {
            XCTAssertNil(AIAssistantRichTextDocument.resourceURL(for: URL(string: path)!, root: root), path)
        }
    }

    func testHeightClampsEnormousLayoutAndRejectsInvalidMeasurements() {
        XCTAssertNil(AIAssistantRichTextDocument.boundedHeight(.infinity))
        XCTAssertNil(AIAssistantRichTextDocument.boundedHeight(.nan))
        XCTAssertNil(AIAssistantRichTextDocument.boundedHeight(-1))
        XCTAssertEqual(AIAssistantRichTextDocument.boundedHeight(0), 24)
        XCTAssertEqual(AIAssistantRichTextDocument.boundedHeight(132.2), 133)
        XCTAssertEqual(AIAssistantRichTextDocument.boundedHeight(1_000_000), 24_000)
    }
}

@MainActor
final class AIAssistantRichTextWebTests: XCTestCase {
    private final class Recorder: NSObject, WKScriptMessageHandler {
        let ready: XCTestExpectation
        var images: [[String: Any]] = []
        var nextImage: XCTestExpectation?
        init(ready: XCTestExpectation) { self.ready = ready }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if body["kind"] as? String == "ready" { ready.fulfill() }
            if body["kind"] as? String == "image" {
                images.append(body); nextImage?.fulfill(); nextImage = nil
            }
        }
    }

    func testOfflineRendererPreservesStructureMathAndBlocksActiveContent() async throws {
        let root = try XCTUnwrap(AIAssistantRichTextDocument.resourceRoot)
        let ready = expectation(description: "Offline renderer ready")
        let recorder = Recorder(ready: ready)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(AIAssistantRichResourceHandler(root: root), forURLScheme: "ember-ai-resource")
        configuration.userContentController.add(recorder, name: "richText")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 340, height: 300), configuration: configuration)
        defer { webView.stopLoading(); configuration.userContentController.removeScriptMessageHandler(forName: "richText") }
        webView.load(URLRequest(url: URL(string: "ember-ai-resource://bundle/index.html")!))
        await fulfillment(of: [ready], timeout: 15)

        let source = #"""
        ## 전자 구름

        첫 문단입니다.
        같은 문단의 다음 줄입니다.

        1. **정의** $\alpha^2 + \beta^2$
        2. 관찰

        \[\frac{1}{2} = \int_0^1 x\,dx\]

        | 기호 | 의미 |
        | --- | --- |
        | x | 위치 |

        ```html
        <script>window.injected = 1</script>
        ```

        <script>window.injected = 2</script>
        <img src="https://example.org/leak" onerror="window.injected = 3">

        [unsafe](javascript:alert(1))

        ![전자 구름 $x^2$ 예시](https://images.example.org/cloud.png)
        """#
        let payload = AIAssistantRichTextDocument.payload(source: source)
        try await runJavaScript("window.EmberRichText.render(payload)", arguments: ["payload": payload], in: webView)
        let result = try await webView.evaluateJavaScript("""
            ({headings: document.querySelectorAll('#response h2').length,
              listItems: document.querySelectorAll('#response ol > li').length,
              paragraphs: document.querySelectorAll('#response p').length,
              breaks: document.querySelectorAll('#response br').length,
              math: document.querySelectorAll('#response .katex').length,
              accessibleMath: document.querySelectorAll('#response math').length,
              tables: document.querySelectorAll('#response .table-scroll table').length,
              code: document.querySelector('#response pre code').textContent,
              activeScripts: document.querySelectorAll('#response script').length,
              remoteImages: document.querySelectorAll('#response img').length,
              imageButtons: document.querySelectorAll('#response .image-card button').length,
              unsafeLinks: document.querySelectorAll('#response a[href^="javascript:"]').length,
              injected: window.injected || 0,
              width: document.getElementById('response').getBoundingClientRect().width,
              height: document.getElementById('response').getBoundingClientRect().height})
            """) as! [String: Any]
        if result["math"] as? Int != 2 || result["imageButtons"] as? Int != 1 {
            let debugHTML = try await webView.evaluateJavaScript("document.getElementById('response').innerHTML")
            print("Rich renderer diagnostic DOM: \(String(describing: debugHTML))")
        }
        XCTAssertEqual(result["headings"] as? Int, 1)
        XCTAssertEqual(result["listItems"] as? Int, 2)
        XCTAssertGreaterThanOrEqual(result["paragraphs"] as? Int ?? 0, 3)
        XCTAssertGreaterThanOrEqual(result["breaks"] as? Int ?? 0, 1)
        XCTAssertEqual(result["math"] as? Int, 2)
        XCTAssertEqual(result["accessibleMath"] as? Int, 2)
        XCTAssertEqual(result["tables"] as? Int, 1)
        XCTAssertTrue((result["code"] as? String)?.contains("<script>window.injected = 1</script>") == true)
        XCTAssertEqual(result["activeScripts"] as? Int, 0)
        XCTAssertEqual(result["remoteImages"] as? Int, 0)
        XCTAssertEqual(result["imageButtons"] as? Int, 1)
        XCTAssertEqual(result["unsafeLinks"] as? Int, 0)
        XCTAssertEqual(result["injected"] as? Int, 0)
        XCTAssertLessThanOrEqual(result["width"] as? Double ?? 1000, 340)
        XCTAssertGreaterThan(result["height"] as? Double ?? 0, 200)
        XCTAssertTrue(recorder.images.isEmpty, "Remote image must wait for the user's click")
        let imageCaption = try await webView.evaluateJavaScript("document.querySelector('.image-card .image-info').textContent") as? String
        XCTAssertTrue(imageCaption?.contains("x^2") == true)
        XCTAssertFalse(imageCaption?.contains("EMBERMATH") == true)
        let clicked = expectation(description: "Explicit image click reaches native loader")
        recorder.nextImage = clicked
        _ = try await webView.evaluateJavaScript("document.querySelector('.image-card button').click()")
        await fulfillment(of: [clicked], timeout: 5)
        XCTAssertEqual(recorder.images.last?["embedded"] as? Bool, false)
        XCTAssertEqual(recorder.images.last?["source"] as? String, "https://images.example.org/cloud.png")

        // Invalid TeX falls back to readable source; code remains code, and
        // trusted=false prevents TeX from creating image/link requests.
        let hostile = AIAssistantRichTextDocument.payload(source: #"$\includegraphics{https://example.org/leak}$ and $\badcommand{x}$"#)
        try await runJavaScript("window.EmberRichText.render(payload)", arguments: ["payload": hostile], in: webView)
        let hostileResult = try await webView.evaluateJavaScript("({images:document.querySelectorAll('#response img').length, fallback:document.querySelectorAll('.math-error').length, text:document.getElementById('response').textContent})") as! [String: Any]
        XCTAssertEqual(hostileResult["images"] as? Int, 0)
        XCTAssertGreaterThanOrEqual(hostileResult["fallback"] as? Int ?? 0, 1)
        XCTAssertTrue((hostileResult["text"] as? String)?.contains("badcommand") == true)

        let image = try XCTUnwrap(AIResponseImage(data: syntheticGraph()))
        let visualSource = #"""
        ## 전자 구름과 확률 밀도

        전자 구름은 **전자가 발견될 가능성**을 나타냅니다.
        짙은 영역일수록 발견할 확률이 높습니다.

        1. **관찰** — 전자의 위치를 측정합니다.
        2. **계산** — $P(x)=|\psi(x)|^2$로 확률 밀도를 구합니다.

        ### 수식과 행렬

        \[\frac{1}{2}=\int_0^1 x\,dx\]
        \[A=\begin{bmatrix}1 & 2\\3 & 4\end{bmatrix}\]

        | 기호 | 의미 |
        | --- | --- |
        | $\psi$ | 파동 함수 |
        | P | 확률 밀도 |

        ```python
        probability = abs(psi(x)) ** 2
        ```

        아래는 표시를 검증하기 위한 예시 그림입니다.
        """#
        let embeddedReady = expectation(description: "Embedded raster reaches native validation without a click")
        recorder.nextImage = embeddedReady
        try await runJavaScript("window.EmberRichText.render(payload)", arguments: ["payload": AIAssistantRichTextDocument.payload(source: visualSource, images: [image])], in: webView)
        await fulfillment(of: [embeddedReady], timeout: 5)
        let imageRequest = try XCTUnwrap(recorder.images.last)
        XCTAssertEqual(imageRequest["embedded"] as? Bool, true)
        let validated = try XCTUnwrap(AIResponseImage(dataURL: imageRequest["source"] as! String))
        let dataURL = try XCTUnwrap(AIAssistantRichTextDocument.imagePayload(validated)?["source"])
        try await runJavaScript("window.EmberRichText.acceptImage(index, generation, dataURL); await document.fonts.ready; await Promise.all(Array.from(document.images).map(image => image.decode()));", arguments: ["index": imageRequest["index"]!, "generation": imageRequest["generation"]!, "dataURL": dataURL], in: webView)
        let embeddedResult = try await webView.evaluateJavaScript("({images:document.querySelectorAll('#response img').length, width:document.querySelector('#response img').naturalWidth, height:document.querySelector('#response img').naturalHeight, matrix:document.querySelectorAll('.mtable').length})") as! [String: Any]
        XCTAssertEqual(embeddedResult["images"] as? Int, 1)
        XCTAssertEqual(embeddedResult["width"] as? Int, 320)
        XCTAssertEqual(embeddedResult["height"] as? Int, 140)
        XCTAssertGreaterThanOrEqual(embeddedResult["matrix"] as? Int ?? 0, 1)

        if let outputDirectory = ProcessInfo.processInfo.environment["EMBER_RICH_TEXT_SNAPSHOT_DIRECTORY"] {
            try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
            for (name, theme, background) in [
                ("light", ["text":"#302b25", "secondary":"#6b6258", "accent":"#905523", "surface":"#62544312", "border":"#62544328"], "#fffdfa"),
                ("dark", ["text":"#e7e1d8", "secondary":"#aca49a", "accent":"#d6a56f", "surface":"#e7e1d80e", "border":"#bdb09d29"], "#302e29")
            ] {
                webView.setFrameSize(NSSize(width: 350, height: 1_200))
                try await runJavaScript("window.EmberRichText.setTheme(theme); document.body.style.background=background; await document.fonts.ready;", arguments: ["theme": theme, "background": background], in: webView)
                let height = try await webView.evaluateJavaScript("Math.ceil(document.getElementById('response').getBoundingClientRect().height)") as! Double
                webView.setFrameSize(NSSize(width: 350, height: height))
                let snapshot: NSImage = try await withCheckedThrowingContinuation { continuation in
                    webView.takeSnapshot(with: nil) { image, error in
                        if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
                    }
                }
                let tiff = try XCTUnwrap(snapshot.tiffRepresentation)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("ai-rich-response-\(name).png"))
            }
        }
    }

    private func syntheticGraph() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 140, bitsPerComponent: 8, bytesPerRow: 1_280, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 140))
        context.setStrokeColor(CGColor(gray: 0.72, alpha: 1)); context.setLineWidth(1)
        context.move(to: CGPoint(x: 20, y: 20)); context.addLine(to: CGPoint(x: 300, y: 20))
        context.move(to: CGPoint(x: 20, y: 20)); context.addLine(to: CGPoint(x: 20, y: 125)); context.strokePath()
        context.setStrokeColor(CGColor(red: 0.23, green: 0.47, blue: 0.67, alpha: 1)); context.setLineWidth(3)
        for index in 0 ... 280 {
            let x = Double(index) / 280 * 6 - 3
            let point = CGPoint(x: 20 + Double(index), y: 20 + 100 * exp(-x * x))
            if index == 0 { context.move(to: point) } else { context.addLine(to: point) }
        }
        context.strokePath()
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func runJavaScript(_ source: String, arguments: [String: Any], in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webView.callAsyncJavaScript(source, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success: continuation.resume()
                case let .failure(error): continuation.resume(throwing: error)
                }
            }
        }
    }
}
