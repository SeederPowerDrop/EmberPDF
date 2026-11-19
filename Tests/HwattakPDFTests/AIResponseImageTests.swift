// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import HwattakPDF

final class AIResponseImageTests: XCTestCase {
    func testStaticRasterIsValidatedAndRoundTripsThroughHistory() throws {
        let data = try rasterData()
        let image = try XCTUnwrap(AIResponseImage(data: data, mimeType: "image/png"))
        XCTAssertEqual(image.pixelWidth, 2)
        XCTAssertEqual(image.pixelHeight, 2)
        XCTAssertEqual(image.mimeType, "image/png")
        XCTAssertNil(image.remoteURL)
        XCTAssertEqual(try JSONDecoder().decode(
            AIResponseImage.self, from: JSONEncoder().encode(image)
        ), image)
        XCTAssertEqual(AIResponseImage(dataURL: "data:image/png;base64," + data.base64EncodedString())?.data, data)
    }

    func testInvalidMIMENonRasterAndOversizedDataAreRejected() throws {
        let png = try rasterData()
        XCTAssertNil(AIResponseImage(data: png, mimeType: "image/jpeg"))
        XCTAssertNil(AIResponseImage(data: Data("<svg><script>1</script></svg>".utf8), mimeType: "image/svg+xml"))
        XCTAssertNil(AIResponseImage(data: Data("<html>image</html>".utf8)))
        XCTAssertNil(AIResponseImage(data: Data(repeating: 0, count: AIResponseImageLimits.maximumImageByteCount + 1)))
        XCTAssertNil(AIResponseImage(base64: String(repeating: "A", count: AIResponseImageLimits.maximumBase64ByteCount + 1)))
        XCTAssertNil(AIResponseImage(dataURL: "data:text/html;base64," + png.base64EncodedString()))
        XCTAssertNil(AIResponseImage(dataURL: "data:image/png," + png.base64EncodedString()))
        XCTAssertNil(AIResponseImage(data: try rasterData(width: 8_193, height: 1)))
    }

    func testRemoteImagesAreOnlyPublicHTTPSMetadataAndRevalidatedWhenDecoded() throws {
        for address in ["file:///etc/passwd", "http://example.org/a.png", "https://localhost/a.png",
                        "https://127.1/a.png", "https://2130706433/a.png", "https://printer.local/a.png",
                        "https://user:secret@example.org/a.png", "javascript:alert(1)"] {
            XCTAssertNil(AIResponseImage(remoteURL: URL(string: address)!), address)
        }
        let image = try XCTUnwrap(AIResponseImage(remoteURL: URL(string: "https://example.org/a.png?q=1")!))
        XCTAssertNil(image.data)
        XCTAssertNil(image.mimeType)
        XCTAssertEqual(try JSONDecoder().decode(AIResponseImage.self, from: JSONEncoder().encode(image)), image)
        let invalidArchive = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "remoteURL": "file:///etc/passwd"
        ])
        XCTAssertThrowsError(try JSONDecoder().decode(AIResponseImage.self, from: invalidArchive))
    }

    func testResponseImageCountAndTotalBytesRemainBounded() throws {
        let remote = try XCTUnwrap(AIResponseImage(remoteURL: URL(string: "https://example.org/a.png")!))
        XCTAssertEqual(AIResponseImage.bounded(Array(repeating: remote, count: 12)).count, 8)

        var padded = try rasterData()
        padded.append(Data(repeating: 0, count: AIResponseImageLimits.maximumImageByteCount - padded.count))
        let raster = try XCTUnwrap(AIResponseImage(data: padded))
        let response = AICompletionResponse(text: "", provider: .gemini, images: [raster, raster, raster])
        XCTAssertEqual(response.images.count, 2)
        XCTAssertEqual(response.images.compactMap(\.data).reduce(0) { $0 + $1.count }, AIResponseImageLimits.maximumTotalByteCount)
    }

    func testOpenAIImageOnlyResponseIsPreservedWithoutEnablingImageTools() async throws {
        let imageData = try rasterData()
        let (response, transport) = try await complete(.openAI, object: [
            "output": [["type": "image_generation_call", "result": imageData.base64EncodedString()]]
        ])
        XCTAssertEqual(response.text, "")
        XCTAssertEqual(response.images.first?.data, imageData)
        let sent = try XCTUnwrap(transport.requests.first?.httpBody)
        XCTAssertFalse(String(decoding: sent, as: UTF8.self).contains("image_generation"))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testGeminiPreservesTextAndImageButOmitsThoughtParts() async throws {
        let imageData = try rasterData()
        let inline: [String: Any] = ["data": imageData.base64EncodedString(), "mimeType": "image/png"]
        let (response, _) = try await complete(.gemini, object: [
            "candidates": [["content": ["parts": [
                ["thought": true, "text": "draft answer"],
                ["thought": true, "inlineData": inline],
                ["text": "The final explanation."],
                ["inlineData": inline]
            ]]]]
        ])
        XCTAssertEqual(response.text, "The final explanation.")
        XCTAssertEqual(response.images.count, 1)
        XCTAssertEqual(response.images.first?.data, imageData)
    }

    func testGeminiSnakeCaseImageOnlyResponseIsValid() async throws {
        let data = try rasterData()
        let (response, _) = try await complete(.gemini, object: [
            "candidates": [["content": ["parts": [["inline_data": [
                "mime_type": "image/png", "data": data.base64EncodedString()
            ]]]]]]
        ])
        XCTAssertEqual(response.text, "")
        XCTAssertEqual(response.images.first?.data, data)
    }

    func testCompatibleContentPreservesRasterAndSafeRemoteLinkWithoutFetching() async throws {
        let data = try rasterData()
        let (response, transport) = try await complete(.customOpenAICompatible, object: [
            "choices": [["message": ["content": [
                ["type": "text", "text": "An illustration"],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64," + data.base64EncodedString()]],
                ["type": "image_url", "image_url": ["url": "https://example.org/a.png"]],
                ["type": "image_url", "image_url": ["url": "file:///tmp/private.png"]],
                ["type": "image_url", "image_url": ["url": "https://127.1/private.png"]]
            ]]]]
        ])
        XCTAssertEqual(response.text, "An illustration")
        XCTAssertEqual(response.images.count, 2)
        XCTAssertEqual(response.images[0].data, data)
        XCTAssertEqual(response.images[1].remoteURL?.absoluteString, "https://example.org/a.png")
        XCTAssertEqual(transport.requests.count, 1, "Images must not trigger automatic network requests")
    }

    func testMalformedImageDoesNotDiscardUsableAnswerAndTooManyImagesAreCapped() async throws {
        let imageData = try rasterData()
        var output: [[String: Any]] = [["type": "message", "content": [["type": "output_text", "text": "Still useful"]]]]
        output.append(["type": "image_generation_call", "result": "invalid base64!"])
        output += Array(repeating: ["type": "image_generation_call", "result": imageData.base64EncodedString()], count: 12)
        let (response, _) = try await complete(.openAI, object: ["output": output])
        XCTAssertEqual(response.text, "Still useful")
        XCTAssertEqual(response.images.count, AIResponseImageLimits.maximumImageCount)
    }

    private func complete(
        _ provider: AIProviderKind,
        object: [String: Any]
    ) async throws -> (AICompletionResponse, ResponseImageTransport) {
        let transport = ResponseImageTransport(body: try JSONSerialization.data(withJSONObject: object))
        let service = AIService(transport: transport, keyStore: ResponseImageKeyStore())
        var configuration = provider.defaultConfiguration
        configuration.requiresAPIKey = false
        let result = try await service.complete(AICompletionRequest(prompt: "Explain", context: ""), using: configuration)
        return (result, transport)
    }

    private func rasterData(width: Int = 2, height: Int = 2) throws -> Data {
        let pixels = Data(repeating: 255, count: width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private final class ResponseImageTransport: AIHTTPTransporting {
    let body: Data
    private(set) var requests: [URLRequest] = []
    init(body: Data) { self.body = body }
    func send(_ request: URLRequest) async throws -> AIHTTPResponse {
        requests.append(request)
        return AIHTTPResponse(data: body, response: HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )!)
    }
}

private struct ResponseImageKeyStore: SecureAIAPIKeyStoring {
    func loadAPIKey(for scope: AIAPIKeyScope) throws -> String? { "fixture-only-key" }
    func saveAPIKey(_ apiKey: String, for scope: AIAPIKeyScope) throws {}
    func deleteAPIKey(for scope: AIAPIKeyScope) throws {}
    func containsAPIKey(for scope: AIAPIKeyScope) throws -> Bool { true }
}
