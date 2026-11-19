// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class AIConversationHistoryTests: XCTestCase {
    private let documentURL = URL(fileURLWithPath: "/private/Study.pdf")

    func testNewRenameRestoreAndDeleteConversationPersistWithoutPendingAuthority() async throws {
        let store = MemoryHistoryStore()
        let configuration = AIProviderKind.openAI.defaultConfiguration
        let model = makeModel()
        model.bindConversationHistory(documentURL: documentURL, isEncrypted: false, store: store)
        await send("First question", model: model, configuration: configuration)
        let firstID = model.activeConversationID
        XCTAssertEqual(model.conversations.first?.title, "First question")
        XCTAssertTrue(model.renameConversation(id: firstID, title: "  Physics study  "))
        XCTAssertTrue(model.startNewConversation())
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.conversations.count, 1)
        await send("Second question", model: model, configuration: configuration)
        let secondID = model.activeConversationID
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertTrue(model.openConversation(id: firstID))
        XCTAssertEqual(model.activeConversationTitle, "Physics study")
        XCTAssertEqual(model.messages.first?.text, "First question")
        XCTAssertEqual(model.messages.last?.localCitations.first?.pageNumber, 1)

        let restored = makeModel()
        restored.bindConversationHistory(documentURL: documentURL, isEncrypted: false, store: store)
        XCTAssertEqual(restored.activeConversationID, firstID)
        XCTAssertEqual(restored.activeConversationTitle, "Physics study")
        XCTAssertEqual(restored.messages.count, 2)
        XCTAssertNil(restored.pendingConsent)
        XCTAssertNil(restored.mcpApprovalSession)
        XCTAssertTrue(restored.messages.allSatisfy { $0.draftApplicationTarget == nil && $0.localCitations.isEmpty })
        XCTAssertTrue(restored.deleteConversation(id: firstID))
        XCTAssertEqual(restored.conversations.map(\.id), [secondID])
        XCTAssertTrue(restored.messages.isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.archives[documentURL]).deletedConversationIDs.contains(firstID))
    }

    func testDeleteMessageCancelsConsentAndOmitsOrphanAnswerFromNextRequest() async throws {
        let model = makeModel()
        let configuration = AIProviderKind.openAI.defaultConfiguration
        await send("Question to remove", model: model, configuration: configuration)
        let userID = try XCTUnwrap(model.messages.first?.id)
        model.prompt = "Waiting question"
        model.beginRequest(action: nil, workspace: PDFWorkspaceState(), documentCollection: nil,
                           configuration: configuration, hasAPIKey: true)
        await waitUntil { model.pendingConsent != nil }
        XCTAssertTrue(model.deleteMessage(id: userID))
        XCTAssertNil(model.pendingConsent)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.messages.map(\.role), [.assistant])
        model.prompt = "Next question"
        model.beginRequest(action: nil, workspace: PDFWorkspaceState(), documentCollection: nil,
                           configuration: configuration, hasAPIKey: true)
        await waitUntil { model.pendingConsent != nil }
        XCTAssertTrue(model.pendingConsent?.conversation.isEmpty == true)
        model.cancel()
    }

    func testRestoredHistoryNeverForwardsAcrossProviderOrEndpoint() async {
        for destinationChange in ["provider", "endpoint", "missingScope"] {
            let store = MemoryHistoryStore()
            var configuration = AIProviderKind.openAI.defaultConfiguration
            let original = makeModel()
            original.bindConversationHistory(documentURL: documentURL, isEncrypted: false, store: store)
            await send("Private old conversation", model: original, configuration: configuration)
            let originalID = original.activeConversationID
            if destinationChange == "missingScope" {
                store.archives[documentURL]?.conversations[0].providerScope = nil
            }
            let restored = makeModel()
            restored.bindConversationHistory(documentURL: documentURL, isEncrypted: false, store: store)
            if destinationChange == "endpoint" {
                configuration.baseURL = URL(string: "https://other.example.com/v1")!
            } else if destinationChange == "provider" {
                configuration = AIProviderKind.anthropic.defaultConfiguration
            }
            restored.prompt = "New destination question"
            restored.beginRequest(action: nil, workspace: PDFWorkspaceState(), documentCollection: nil,
                                  configuration: configuration, hasAPIKey: true)
            await waitUntil { restored.pendingConsent != nil }
            XCTAssertNotEqual(restored.activeConversationID, originalID)
            XCTAssertTrue(restored.pendingConsent?.conversation.isEmpty == true)
            XCTAssertEqual(restored.pendingConsent?.prompt, "New destination question")
            XCTAssertTrue(restored.conversations.contains { $0.id == originalID })
            restored.cancel()
        }
    }

    func testNewConversationRejectsLateNetworkResponse() async {
        var continuation: CheckedContinuation<AICompletionResponse, Never>?
        let model = makeModel { _, configuration in
            await withCheckedContinuation { continuation = $0 }
        }
        let configuration = AIProviderKind.openAI.defaultConfiguration
        model.prompt = "Slow question"
        model.beginRequest(action: nil, workspace: PDFWorkspaceState(), documentCollection: nil,
                           configuration: configuration, hasAPIKey: true, requiresTransmissionConfirmation: false)
        await waitUntil { continuation != nil }
        XCTAssertTrue(model.startNewConversation())
        continuation?.resume(returning: AICompletionResponse(text: "Late answer", provider: .openAI))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.conversations.first?.messageCount, 1)
        XCTAssertNil(model.pendingConsent)
        XCTAssertNil(model.mcpApprovalSession)
    }

    func testEncryptedDocumentKeepsHistoryMemoryOnlyAcrossNewConversations() async {
        let store = MemoryHistoryStore()
        let model = makeModel()
        model.bindConversationHistory(documentURL: documentURL, isEncrypted: true, store: store)
        await send("Protected text", model: model, configuration: AIProviderKind.openAI.defaultConfiguration)
        XCTAssertFalse(model.isConversationHistoryPersistent)
        XCTAssertTrue(model.startNewConversation())
        XCTAssertEqual(model.conversations.count, 1)
        XCTAssertEqual(store.readCount, 0)
        XCTAssertEqual(store.writeCount, 0)
        model.documentDidChange()
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testDocumentSwitchSeparatesRecordsAndCorruptReadNeverOverwritesArchive() async {
        let store = MemoryHistoryStore()
        let model = makeModel()
        model.bindConversationHistory(documentURL: documentURL, isEncrypted: false, store: store)
        await send("Document A", model: model, configuration: AIProviderKind.openAI.defaultConfiguration)
        model.documentDidChange()
        let other = URL(fileURLWithPath: "/private/Other.pdf")
        model.bindConversationHistory(documentURL: other, isEncrypted: false, store: store)
        XCTAssertTrue(model.messages.isEmpty)
        await send("Document B", model: model, configuration: AIProviderKind.openAI.defaultConfiguration)
        XCTAssertEqual(store.archives[documentURL]?.conversations.first?.messages.first?.text, "Document A")
        XCTAssertEqual(store.archives[other]?.conversations.first?.messages.first?.text, "Document B")
        store.readError = AIConversationHistoryError.invalidArchive
        let failed = makeModel()
        failed.bindConversationHistory(documentURL: documentURL, isEncrypted: false, store: store)
        let writesBefore = store.writeCount
        await send("Must remain memory-only", model: failed, configuration: AIProviderKind.openAI.defaultConfiguration)
        XCTAssertNotNil(failed.historyErrorMessage)
        XCTAssertEqual(store.writeCount, writesBefore)
        XCTAssertEqual(store.archives[documentURL]?.conversations.first?.messages.first?.text, "Document A")
    }

    func testFileStoreUsesHashedNamesPrivatePermissionsAndMergesWindowConversations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIConversationHistoryStore(directoryURL: directory)
        let first = record(title: "One")
        let second = record(title: "Two")
        try store.save(.init(activeConversationID: first.id, conversations: [first]), documentURL: documentURL)
        try store.save(.init(activeConversationID: second.id, conversations: [second]), documentURL: documentURL)
        XCTAssertEqual(Set(try XCTUnwrap(store.load(documentURL: documentURL)).conversations.map(\.id)), [first.id, second.id])
        try store.save(.init(activeConversationID: second.id, conversations: [second], deletedConversationIDs: [first.id]), documentURL: documentURL)
        // A stale window cannot resurrect a conversation deleted in another.
        try store.save(.init(activeConversationID: first.id, conversations: [first]), documentURL: documentURL)
        XCTAssertEqual(try store.load(documentURL: documentURL)?.conversations.map(\.id), [second.id])
        let fileURL = store.archiveURL(for: documentURL)
        XCTAssertFalse(fileURL.lastPathComponent.contains("Study"))
        XCTAssertEqual(fileURL.deletingPathExtension().lastPathComponent.count, 64)
        let filePermissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePermissions?.intValue, 0o600)
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)
        let rawArchive = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(rawArchive.contains(documentURL.path))
        XCTAssertFalse(rawArchive.contains("draftApplicationTarget"))
        XCTAssertFalse(rawArchive.contains("pendingConsent"))
    }

    func testConversationCountLimitDoesNotDiscardExistingRecords() throws {
        let store = MemoryHistoryStore()
        let records = (0..<100).map { record(title: "Conversation \($0)") }
        store.archives[documentURL] = .init(activeConversationID: records[0].id, conversations: records)
        let model = makeModel()
        model.bindConversationHistory(documentURL: documentURL, isEncrypted: false, store: store)
        XCTAssertFalse(model.startNewConversation())
        XCTAssertEqual(model.conversations.count, 100)
        XCTAssertNotNil(model.historyErrorMessage)
        XCTAssertTrue(model.deleteConversation(id: records[1].id))
        XCTAssertTrue(model.startNewConversation())
        XCTAssertEqual(model.conversations.count, 99)
    }

    func testFullConversationRetainsAllMessagesAndStopsBeforeSendingAgain() async {
        let store = MemoryHistoryStore()
        let configuration = AIProviderKind.openAI.defaultConfiguration
        let messages = (0..<100).map {
            AIConversationRecord.ArchivedMessage(AIAssistantMessage(
                role: $0.isMultiple(of: 2) ? .user : .assistant, text: "Turn \($0)"))
        }
        let full = AIConversationRecord(id: UUID(), title: "Long conversation", hasCustomTitle: false,
            modifiedAt: Date(), providerScope: AIConversationProviderScope(configuration: configuration),
            messages: messages)
        store.archives[documentURL] = .init(activeConversationID: full.id, conversations: [full])
        let model = makeModel()
        model.bindConversationHistory(documentURL: documentURL, isEncrypted: false, store: store)
        model.prompt = "One more"
        model.beginRequest(action: nil, workspace: PDFWorkspaceState(), documentCollection: nil,
                           configuration: configuration, hasAPIKey: true, requiresTransmissionConfirmation: false)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.messages.count, 100)
        XCTAssertEqual(model.messages.first?.text, "Turn 0")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.startNewConversation())
        await send("Fresh question", model: model, configuration: configuration)
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.conversations.first(where: { $0.id == full.id })?.messageCount, 100)
    }

    func testFullHistoryWithNoActiveRecordBlocksNewRequestWithoutDroppingIt() {
        let store = MemoryHistoryStore()
        store.archives[documentURL] = .init(activeConversationID: UUID(),
            conversations: (0..<100).map { record(title: "Record \($0)") })
        let model = makeModel()
        model.bindConversationHistory(documentURL: documentURL, isEncrypted: false, store: store)
        XCTAssertFalse(model.startNewConversation())
        model.prompt = "Must not vanish"
        model.beginRequest(action: nil, workspace: PDFWorkspaceState(), documentCollection: nil,
                           configuration: AIProviderKind.openAI.defaultConfiguration,
                           hasAPIKey: true, requiresTransmissionConfirmation: false)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.prompt, "Must not vanish")
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.conversations.count, 100)
        XCTAssertNotNil(model.historyErrorMessage)
    }

    func testImageOnlyAnswerPersistsButNeverAddsEmptyOrBinaryConversationTurn() async throws {
        let store = MemoryHistoryStore()
        let image = try XCTUnwrap(AIResponseImage(remoteURL: URL(string: "https://example.org/diagram.png")!))
        let configuration = AIProviderKind.openAI.defaultConfiguration
        let model = makeModel { _, _ in AICompletionResponse(text: "", provider: .openAI, images: [image]) }
        model.bindConversationHistory(documentURL: documentURL, isEncrypted: false, store: store)
        await send("Draw a diagram", model: model, configuration: configuration)
        XCTAssertEqual(model.messages.last?.images, [image])
        let restored = makeModel()
        restored.bindConversationHistory(documentURL: documentURL, isEncrypted: false, store: store)
        XCTAssertEqual(restored.messages.last?.images, [image])
        restored.prompt = "Explain it"
        restored.beginRequest(action: nil, workspace: PDFWorkspaceState(), documentCollection: nil,
                              configuration: configuration, hasAPIKey: true)
        await waitUntil { restored.pendingConsent != nil }
        XCTAssertEqual(restored.pendingConsent?.conversation.map(\.role), [.user])
        XCTAssertEqual(restored.pendingConsent?.conversation.first?.content, "Draw a diagram")
        restored.cancel()
    }

    func testSaveAsAndHibernationCancelPendingAuthorityWithoutLosingSavedHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        let destination = directory.appendingPathComponent("copy.pdf")
        let pdf = PDFDocument()
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(pdf.write(to: source))
        let store = MemoryHistoryStore()
        let model = makeModel()
        let workspace = PDFWorkspaceState(aiAssistantSession: model)
        XCTAssertTrue(workspace.open(url: source))
        workspace.enableAIConversationHistoryPersistence(store: store)
        let configuration = AIProviderKind.openAI.defaultConfiguration
        await send("Original conversation", model: model, configuration: configuration)
        model.prompt = "Pending original request"
        model.beginRequest(action: nil, workspace: workspace, documentCollection: nil,
                           configuration: configuration, hasAPIKey: true)
        await waitUntil { model.pendingConsent != nil }
        XCTAssertTrue(workspace.saveSynchronously(as: destination))
        XCTAssertNil(model.pendingConsent)
        XCTAssertNil(model.mcpApprovalSession)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertTrue(store.archives[source.standardizedFileURL.resolvingSymlinksInPath()]?.conversations.isEmpty == false)
        await send("Copy conversation", model: model, configuration: configuration)
        model.prompt = "Pending before hibernation"
        model.beginRequest(action: nil, workspace: workspace, documentCollection: nil,
                           configuration: configuration, hasAPIKey: true)
        await waitUntil { model.pendingConsent != nil }
        XCTAssertTrue(workspace.hibernateIfPossible())
        XCTAssertNil(model.pendingConsent)
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertTrue(workspace.resumeIfNeeded())
        XCTAssertEqual(model.messages.first?.text, "Copy conversation")
        XCTAssertTrue(model.isConversationHistoryPersistent)
    }

    private func record(title: String) -> AIConversationRecord {
        AIConversationRecord(id: UUID(), title: title, hasCustomTitle: false, modifiedAt: Date(),
                             providerScope: nil, messages: [.init(AIAssistantMessage(role: .user, text: title))])
    }

    private func makeModel(complete: AIAssistantSessionModel.CompleteHandler? = nil) -> AIAssistantSessionModel {
        AIAssistantSessionModel(
            complete: complete ?? { _, configuration in AICompletionResponse(text: "Answer", provider: configuration.kind) },
            extractContext: { _, scope in
                PDFAIContextBundle(scope: scope, documentTitle: "Study.pdf", documentURL: self.documentURL,
                                   documentPageCount: 3, sources: [
                                    PDFAIContextSource(citationID: "S1", documentURL: self.documentURL,
                                        documentTitle: "Study.pdf", pageIndex: 0, pageNumber: 1,
                                        text: "Local evidence", kind: .pageText, wasTruncated: false)
                                   ], omittedPageCount: 0, wasTruncated: false)
            },
            searchRelatedPDFs: { _, _, _ in [] }
        )
    }

    private func send(_ question: String, model: AIAssistantSessionModel, configuration: AIProviderConfiguration) async {
        model.prompt = question
        model.beginRequest(action: nil, workspace: PDFWorkspaceState(), documentCollection: nil,
                           configuration: configuration, hasAPIKey: true, requiresTransmissionConfirmation: false)
        await waitUntil { model.phase == .idle && model.messages.last?.role == .assistant }
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for model transition")
    }
}

private final class MemoryHistoryStore: AIConversationHistoryPersisting {
    var archives: [URL: AIConversationArchive] = [:]
    var readCount = 0
    var writeCount = 0
    var readError: Error?
    func load(documentURL: URL) throws -> AIConversationArchive? {
        readCount += 1
        if let readError { throw readError }
        return archives[documentURL]
    }
    func save(_ archive: AIConversationArchive, documentURL: URL) throws {
        writeCount += 1
        archives[documentURL] = archive
    }
}
