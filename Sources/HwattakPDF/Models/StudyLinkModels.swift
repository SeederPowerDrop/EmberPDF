// SPDX-License-Identifier: MPL-2.0

import CryptoKit
import Foundation
import PDFKit

/// PDFKit drops FreeText's standard /NM key when it rebuilds appearances.
/// This small custom entry survives its serializer and identifies a note;
/// it never grants permission to edit or follow an action from that note.
enum StudyLinkNoteIdentity {
    static let key = PDFAnnotationKey(rawValue: "/EmberPDFNoteID")

    static func identifier(in annotation: PDFAnnotation) -> String? {
        guard let value = annotation.value(forAnnotationKey: key) as? String,
              !value.isEmpty, value.utf8.count <= 512 else { return nil }
        return value
    }

    @discardableResult
    static func assignIfNeeded(to annotation: PDFAnnotation) -> String {
        if let existing = identifier(in: annotation) { return existing }
        let standard = annotation.value(forAnnotationKey: .name) as? String
        let identifier = standard.flatMap { !$0.isEmpty && $0.utf8.count <= 512 ? $0 : nil }
            ?? "EmberPDF-Note-\(UUID().uuidString)"
        annotation.setValue(identifier, forAnnotationKey: key)
        return identifier
    }

    static func preserve(from source: PDFAnnotation, to destination: PDFAnnotation) {
        if let identifier = identifier(in: source) {
            destination.setValue(identifier, forAnnotationKey: key)
        }
    }
}

/// The link graph lives in EmberPDF's local preferences, never in an imported
/// PDF action. An endpoint can name a page or a FreeText note on that page.
struct StudyLinkEndpoint: Codable, Equatable {
    let documentID: UUID
    let pageIndex: Int
    let note: StudyLinkNoteLocator?
    /// A PDF outline choice is a connection to its page; this label preserves
    /// the chosen chapter title without importing an executable PDF action.
    var bookmarkTitle: String? = nil
}

struct StudyLinkNoteLocator: Codable, Equatable {
    let name: String?
    let textDigest: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(annotation: PDFAnnotation) {
        let identifier = StudyLinkNoteIdentity.identifier(in: annotation)
            ?? annotation.value(forAnnotationKey: .name) as? String
        name = identifier.flatMap { !$0.isEmpty && $0.utf8.count <= 512 ? $0 : nil }
        textDigest = Self.digest(annotation.contents ?? "")
        let bounds = annotation.bounds
        x = bounds.minX; y = bounds.minY; width = bounds.width; height = bounds.height
    }

    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && width >= 0 && height >= 0 && textDigest.count == 64
            && name.map { !$0.isEmpty && $0.utf8.count <= 512 } != false
    }

    func identifies(_ other: Self) -> Bool {
        if let name, let otherName = other.name { return name == otherName }
        return textDigest == other.textDigest && hasSameBounds(as: other)
    }

    /// Named notes survive content and geometry edits. Older external notes
    /// have no stable ID; resolve only a unique match, never guess among copies.
    func resolve(on page: PDFPage) -> PDFAnnotation? {
        let notes = page.annotations.filter {
            $0.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText"
        }
        if let name {
            let matches = notes.filter {
                (StudyLinkNoteIdentity.identifier(in: $0) ?? $0.value(forAnnotationKey: .name) as? String) == name
            }
            return matches.count == 1 ? matches.first : nil
        }
        let matches = notes.filter { Self.digest($0.contents ?? "") == textDigest }
        if matches.count == 1 { return matches[0] }
        let positioned = matches.filter { hasSameBounds(as: Self(annotation: $0)) }
        return positioned.count == 1 ? positioned.first : nil
    }

    private func hasSameBounds(as other: Self) -> Bool {
        abs(x - other.x) < 0.5 && abs(y - other.y) < 0.5
            && abs(width - other.width) < 0.5 && abs(height - other.height) < 0.5
    }

    private static func digest(_ contents: String) -> String {
        // Notes are already bounded by the editor. Avoid retaining their full
        // private text a second time in the app-local relation database.
        let bounded = String(decoding: contents.utf16.prefix(65_536), as: UTF16.self)
        return SHA256.hash(data: Data(bounded.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct StudyLink: Codable, Identifiable, Equatable {
    let id: UUID
    let first: StudyLinkEndpoint
    let second: StudyLinkEndpoint
    let createdAt: Date

    func destination(from endpoint: StudyLinkEndpoint) -> StudyLinkEndpoint? {
        if Self.matches(first, endpoint) { return second }
        if Self.matches(second, endpoint) { return first }
        return nil
    }

    static func matches(_ lhs: StudyLinkEndpoint, _ rhs: StudyLinkEndpoint) -> Bool {
        guard lhs.documentID == rhs.documentID, lhs.pageIndex == rhs.pageIndex else { return false }
        switch (lhs.note, rhs.note) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return lhs.identifies(rhs)
        default: return false
        }
    }
}

struct StudyLinkDocument: Codable, Identifiable {
    let id: UUID
    var bookmark: Data
    var path: String
    var displayName: String
}

enum StudyLinkError: LocalizedError {
    case saveFirst, invalidDestination, duplicate, storageLimit, unavailable, corruptStorage, notePermission

    var errorDescription: String? {
        switch self {
        case .saveFirst: L10n.string("study.links.save_first", defaultValue: "연결할 PDF를 먼저 파일로 저장하세요.")
        case .invalidDestination: L10n.string("study.links.invalid_target", defaultValue: "연결할 페이지 또는 메모를 다시 선택하세요.")
        case .duplicate: L10n.string("study.links.duplicate", defaultValue: "이미 연결된 위치입니다.")
        case .storageLimit: L10n.string("study.links.limit", defaultValue: "연결 저장 공간이 가득 찼습니다. 사용하지 않는 연결을 삭제하세요.")
        case .unavailable: L10n.string("study.links.unavailable", defaultValue: "연결된 PDF를 열 수 없습니다. ‘파일 다시 연결’로 파일을 선택하세요.")
        case .corruptStorage: L10n.string("study.links.storage_error", defaultValue: "저장된 연결 목록을 읽을 수 없습니다. 원래 데이터는 보존되어 있습니다.")
        case .notePermission: L10n.string("study.links.note_permission", defaultValue: "메모 연결에는 식별자를 저장할 수정 권한이 필요합니다. 학습 모드에서 연결하거나 페이지를 연결하세요.")
        }
    }
}
