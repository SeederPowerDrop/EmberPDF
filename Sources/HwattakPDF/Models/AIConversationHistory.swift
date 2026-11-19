// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation

/// A conversation is scoped to both the PDF and the configured destination.
/// API keys, tool approval IDs and extracted request context are never archived.
struct AIConversationProviderScope: Codable, Equatable {
    let configurationID: UUID
    let provider: AIProviderKind
    let normalizedEndpoint: String

    init(configuration: AIProviderConfiguration) {
        configurationID = configuration.id
        provider = configuration.kind
        normalizedEndpoint = AIEndpointPolicy.normalizedEndpoint(configuration.baseURL)
    }
}

struct AIConversationSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    let modifiedAt: Date
    let messageCount: Int
    let providerName: String?
}

struct AIConversationRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var hasCustomTitle: Bool
    var modifiedAt: Date
    var providerScope: AIConversationProviderScope?
    var messages: [ArchivedMessage]

    struct ArchivedMessage: Codable, Equatable {
        let id: UUID
        let role: String
        let text: String
        let images: [AIResponseImage]
        let citations: [AISourceCitation]
        let providerName: String?

        init(_ message: AIAssistantMessage) {
            id = message.id
            role = message.role.rawValue
            text = message.text
            images = message.images
            citations = message.citations
            providerName = message.providerName
        }

        var restored: AIAssistantMessage? {
            guard let role = AIAssistantRole(rawValue: role) else { return nil }
            // Saved page indices can become stale after the PDF is edited by
            // another application. History remains readable, but old page links
            // and fill-draft targets intentionally have no authority on reopen.
            return AIAssistantMessage(
                id: id, role: role, text: text, images: images,
                citations: citations, providerName: providerName
            )
        }
    }
}

struct AIConversationArchive: Codable, Equatable {
    static let schemaVersion = 1
    var version = Self.schemaVersion
    var activeConversationID: UUID?
    var conversations: [AIConversationRecord]
    var deletedConversationIDs: Set<UUID> = []
}

protocol AIConversationHistoryPersisting: AnyObject {
    func load(documentURL: URL) throws -> AIConversationArchive?
    func save(_ archive: AIConversationArchive, documentURL: URL) throws
}

enum AIConversationHistoryError: LocalizedError {
    case invalidArchive
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            L10n.string("ai.history.error.invalid", defaultValue: "저장된 대화 기록을 읽을 수 없습니다. 기존 기록은 유지했습니다.")
        case .archiveTooLarge:
            L10n.string("ai.history.error.large", defaultValue: "대화 기록이 저장 한도에 도달했습니다. 필요 없는 대화를 정리해 주세요.")
        }
    }
}

/// The filename contains a hash, never the PDF's path. Atomic replacements and
/// owner-only permissions keep partially written or shared-readable archives
/// out of the application's local support directory.
final class AIConversationHistoryStore: AIConversationHistoryPersisting {
    static let maximumArchiveBytes = 32 * 1_024 * 1_024
    let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? (
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
        ).appendingPathComponent("EmberPDF/AI Conversations", isDirectory: true)
    }

    func archiveURL(for documentURL: URL) -> URL {
        let identity = documentURL.standardizedFileURL.resolvingSymlinksInPath().absoluteString
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(digest + ".json")
    }

    func load(documentURL: URL) throws -> AIConversationArchive? {
        let url = archiveURL(for: documentURL)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maximumArchiveBytes else {
            throw AIConversationHistoryError.archiveTooLarge
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let archive = try JSONDecoder().decode(AIConversationArchive.self, from: data)
        guard archive.version == AIConversationArchive.schemaVersion else {
            throw AIConversationHistoryError.invalidArchive
        }
        return archive
    }

    func save(_ archive: AIConversationArchive, documentURL: URL) throws {
        // Multiple windows may show the same PDF. Merge independent chats and
        // retain deletion tombstones instead of replacing another window's work.
        var merged = archive
        if let previous = try load(documentURL: documentURL) {
            merged.deletedConversationIDs.formUnion(previous.deletedConversationIDs)
            var records: [UUID: AIConversationRecord] = [:]
            for record in previous.conversations + archive.conversations
                where !merged.deletedConversationIDs.contains(record.id) {
                if let existing = records[record.id], existing.modifiedAt > record.modifiedAt { continue }
                records[record.id] = record
            }
            merged.conversations = Array(records.values)
        }
        guard merged.conversations.count <= 100 else {
            throw AIConversationHistoryError.archiveTooLarge
        }
        let data = try JSONEncoder().encode(merged)
        guard data.count <= Self.maximumArchiveBytes else {
            throw AIConversationHistoryError.archiveTooLarge
        }
        try fileManager.createDirectory(
            at: directoryURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let target = archiveURL(for: documentURL)
        // The staging file starts private; the atomic replacement retains its
        // mode, so there is no temporary interval with broader permissions.
        let temporary = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fileManager.removeItem(at: temporary) }
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: target)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
