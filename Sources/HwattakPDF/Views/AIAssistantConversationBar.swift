// SPDX-License-Identifier: MPL-2.0

import SwiftUI

@MainActor
struct AIAssistantConversationBar: View {
    @ObservedObject var viewModel: AIAssistantSessionModel
    let theme: HwattakPDFTheme

    @State private var showingHistory = false
    @State private var search = ""
    @State private var renameID: UUID?
    @State private var renameDraft = ""
    @State private var showingRename = false
    @State private var deletionID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    search = ""
                    showingHistory.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .foregroundStyle(theme.accent)
                        Text(viewModel.activeConversationTitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("ai.history.open", defaultValue: "대화 목록"))
                .accessibilityValue(viewModel.activeConversationTitle)
                .accessibilityIdentifier("ai-conversation-history")
                .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                    historyPopover
                }

                Button {
                    viewModel.startNewConversation()
                } label: {
                    Label(L10n.string("ai.history.new", defaultValue: "새 대화"), systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.accent)
                .accessibilityIdentifier("ai-new-conversation")
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .frame(height: 34)

            if let error = viewModel.historyErrorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: viewModel.clearHistoryError) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("action.close", defaultValue: "닫기"))
                }
                .foregroundStyle(theme.warning)
                .padding(9)
                .background(theme.warning.opacity(0.08))
            }
        }
        .background(theme.panel)
        .alert(L10n.string("ai.history.rename", defaultValue: "대화 이름 변경"), isPresented: $showingRename) {
            TextField(L10n.string("ai.history.title", defaultValue: "대화 이름"), text: $renameDraft)
            Button(L10n.string("action.cancel", defaultValue: "취소"), role: .cancel) { renameID = nil }
            Button(L10n.string("action.save", defaultValue: "저장")) {
                if let renameID { viewModel.renameConversation(id: renameID, title: renameDraft) }
                renameID = nil
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            L10n.string("ai.history.delete_title", defaultValue: "이 대화를 삭제할까요?"),
            isPresented: Binding(get: { deletionID != nil }, set: { if !$0 { deletionID = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.string("action.delete", defaultValue: "삭제"), role: .destructive) {
                if let deletionID { viewModel.deleteConversation(id: deletionID) }
                deletionID = nil
            }
            Button(L10n.string("action.cancel", defaultValue: "취소"), role: .cancel) { deletionID = nil }
        } message: {
            Text(L10n.string("ai.history.delete_message", defaultValue: "이 Mac에 저장된 대화 기록도 함께 삭제됩니다."))
        }
    }

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.string("ai.history.heading", defaultValue: "이 PDF의 대화"))
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.startNewConversation()
                    showingHistory = false
                } label: {
                    Label(L10n.string("ai.history.new", defaultValue: "새 대화"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            TextField(L10n.string("ai.history.search", defaultValue: "대화 이름 검색"), text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("ai-history-search")

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if filteredConversations.isEmpty {
                        Text(L10n.string("ai.history.empty", defaultValue: "표시할 대화가 없습니다."))
                            .foregroundStyle(theme.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: 100)
                    }
                    ForEach(filteredConversations) { conversation in
                        historyRow(conversation)
                    }
                }
            }
            .frame(height: 280)

            Text(viewModel.isConversationHistoryPersistent
                 ? L10n.string("ai.history.saved_locally", defaultValue: "대화 기록은 이 Mac에 저장됩니다.")
                 : L10n.string("ai.history.memory_only", defaultValue: "이 PDF의 대화는 앱을 사용하는 동안만 유지됩니다."))
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 360)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
    }

    private var filteredConversations: [AIConversationSummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.conversations.filter {
            query.isEmpty || $0.title.localizedStandardContains(query)
                || ($0.providerName?.localizedStandardContains(query) ?? false)
        }
    }

    private func historyRow(_ conversation: AIConversationSummary) -> some View {
        HStack(spacing: 6) {
            Button {
                viewModel.openConversation(id: conversation.id)
                showingHistory = false
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        if conversation.id == viewModel.activeConversationID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.accent)
                        }
                        Text(conversation.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        Text(conversation.modifiedAt, style: .date)
                        Text(L10n.format("ai.history.message_count", conversation.messageCount))
                        if let provider = conversation.providerName { Text(provider).lineLimit(1) }
                    }
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ai-history-item-\(conversation.id.uuidString)")

            Menu {
                Button(L10n.string("ai.history.rename", defaultValue: "대화 이름 변경")) {
                    renameID = conversation.id
                    renameDraft = conversation.title
                    showingHistory = false
                    showingRename = true
                }
                Button(L10n.string("ai.history.delete", defaultValue: "대화 삭제"), role: .destructive) {
                    deletionID = conversation.id
                    showingHistory = false
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.string("ai.history.options", defaultValue: "대화 관리"))
        }
        .padding(.horizontal, 8)
        .background(conversation.id == viewModel.activeConversationID ? theme.dropHighlight : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }
}
