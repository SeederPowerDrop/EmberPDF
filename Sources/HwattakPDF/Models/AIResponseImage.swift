// SPDX-License-Identifier: MPL-2.0

import Foundation
import ImageIO

enum AIResponseImageLimits {
    static let maximumImageCount = 8
    static let maximumImageByteCount = 4 * 1_024 * 1_024
    static let maximumTotalByteCount = 8 * 1_024 * 1_024
    static let maximumPixelCount = 16_000_000
    static let maximumTotalPixelCount = 32_000_000
    static let maximumDimension = 8_192
    static let maximumURLByteCount = 8_192
    static let maximumBase64ByteCount = ((maximumImageByteCount + 2) / 3) * 4
}

/// Response attachments are display-only: these bytes and remote addresses are
/// never part of the text conversation sent back to an AI provider.
struct AIResponseImage: Codable, Equatable, Identifiable {
    let id: UUID
    let data: Data?
    let mimeType: String?
    let remoteURL: URL?
    let pixelWidth: Int?
    let pixelHeight: Int?

    init?(data: Data, mimeType: String? = nil) {
        self.init(id: UUID(), data: data, mimeType: mimeType)
    }

    private init?(id: UUID, data: Data, mimeType: String?) {
        guard !data.isEmpty,
              mimeType == nil || mimeType!.utf8.count <= 64,
              data.count <= AIResponseImageLimits.maximumImageByteCount,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              // Animated images can multiply the decoded-memory budget. Only
              // static raster images enter the native/web response renderer.
              CGImageSourceGetCount(source) == 1,
              let rawType = CGImageSourceGetType(source) as String?,
              let actualMIME = Self.mimeType(for: rawType),
              mimeType == nil || Self.normalizedMIME(mimeType!) == actualMIME,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= AIResponseImageLimits.maximumDimension,
              height <= AIResponseImageLimits.maximumDimension,
              width <= AIResponseImageLimits.maximumPixelCount / height,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
              ) != nil else { return nil }
        self.id = id
        self.data = data
        self.mimeType = actualMIME
        self.remoteURL = nil
        self.pixelWidth = width
        self.pixelHeight = height
    }

    init?(remoteURL: URL) {
        self.init(id: UUID(), remoteURL: remoteURL)
    }

    private init?(id: UUID, remoteURL: URL) {
        guard remoteURL.absoluteString.utf8.count <= AIResponseImageLimits.maximumURLByteCount,
              remoteURL.scheme?.lowercased() == "https",
              AIEndpointPolicy.isValidExternalWebURL(remoteURL) else { return nil }
        self.id = id
        self.data = nil
        self.mimeType = nil
        self.remoteURL = remoteURL
        self.pixelWidth = nil
        self.pixelHeight = nil
    }

    init?(dataURL: String) {
        guard dataURL.utf8.count <= AIResponseImageLimits.maximumBase64ByteCount + 64,
              dataURL.hasPrefix("data:"),
              let separator = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5) ..< separator]
        guard header.hasSuffix(";base64") else { return nil }
        let mimeType = String(header.dropLast(7))
        self.init(
            base64: String(dataURL[dataURL.index(after: separator)...]),
            mimeType: mimeType
        )
    }

    init?(base64: String, mimeType: String? = nil) {
        guard base64.utf8.count <= AIResponseImageLimits.maximumBase64ByteCount,
              let data = Data(base64Encoded: base64) else { return nil }
        self.init(data: data, mimeType: mimeType)
    }

    static func bounded(_ images: [AIResponseImage]) -> [AIResponseImage] {
        var result: [AIResponseImage] = []
        var totalBytes = 0
        var totalPixels = 0
        for image in images.prefix(AIResponseImageLimits.maximumImageCount) {
            let bytes = image.data?.count ?? 0
            let pixels = (image.pixelWidth ?? 0) * (image.pixelHeight ?? 0)
            guard bytes <= AIResponseImageLimits.maximumTotalByteCount - totalBytes,
                  pixels <= AIResponseImageLimits.maximumTotalPixelCount - totalPixels else { continue }
            totalBytes += bytes
            totalPixels += pixels
            result.append(image)
        }
        return result
    }

    private static func mimeType(for imageType: String) -> String? {
        switch imageType {
        case "public.png": return "image/png"
        case "public.jpeg": return "image/jpeg"
        case "org.webmproject.webp": return "image/webp"
        case "com.compuserve.gif": return "image/gif"
        default: return nil
        }
    }

    private static func normalizedMIME(_ mimeType: String) -> String {
        let normalized = mimeType.lowercased()
        return normalized == "image/jpg" ? "image/jpeg" : normalized
    }

    private enum CodingKeys: String, CodingKey {
        case id, data, mimeType, remoteURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let data = try container.decodeIfPresent(Data.self, forKey: .data)
        let mime = try container.decodeIfPresent(String.self, forKey: .mimeType)
        let remote = try container.decodeIfPresent(URL.self, forKey: .remoteURL)
        let image: AIResponseImage?
        if let data, remote == nil {
            image = Self(id: id, data: data, mimeType: mime)
        } else if data == nil, let remote, mime == nil {
            image = Self(id: id, remoteURL: remote)
        } else {
            image = nil
        }
        guard let image else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "The response image is invalid or exceeds display limits."
            ))
        }
        self = image
    }
}

/// Bounds the aggregate while parsing, so repeated valid images do not build
/// an oversized temporary array before AICompletionResponse is initialized.
struct AIResponseImageAccumulator {
    private(set) var images: [AIResponseImage] = []

    var hasCapacity: Bool {
        images.count < AIResponseImageLimits.maximumImageCount
            && images.reduce(0, { $0 + ($1.data?.count ?? 0) }) < AIResponseImageLimits.maximumTotalByteCount
            && images.reduce(0, { $0 + ($1.pixelWidth ?? 0) * ($1.pixelHeight ?? 0) }) < AIResponseImageLimits.maximumTotalPixelCount
    }

    mutating func append(_ image: AIResponseImage?) {
        guard hasCapacity, let image else { return }
        images = AIResponseImage.bounded(images + [image])
    }
}
