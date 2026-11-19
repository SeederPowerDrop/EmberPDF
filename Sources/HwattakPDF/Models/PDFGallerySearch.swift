// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A gallery entry keeps the original tab identity across workspace filters.
/// Merely enumerating/searching one never selects or resumes that tab.
@MainActor
struct PDFGalleryDocument: Identifiable {
    let workspaceID: UUID
    let workspaceTitle: String
    let session: PDFTabSession
    let groupTitle: String?

    init(workspaceID: UUID, workspaceTitle: String, session: PDFTabSession, groupTitle: String? = nil) {
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.session = session
        self.groupTitle = groupTitle
    }

    var id: UUID { session.id }
}

enum PDFGalleryDocumentSearchStatus: Equatable, Sendable {
    case searching, completed, locked, copyRestricted, unavailable, noText, changed, notSearched

    var isSkipped: Bool {
        switch self {
        case .locked, .copyRestricted, .unavailable, .noText, .changed, .notSearched: return true
        case .searching, .completed: return false
        }
    }
}

@MainActor
struct PDFGalleryDocumentSearchResult: Identifiable {
    let document: PDFGalleryDocument
    let filenameMatched: Bool
    let documentRevision: UUID
    var sourceVersion: PDFSourceFileVersion?
    var matches: [PDFSearchResult] = []
    var status: PDFGalleryDocumentSearchStatus = .searching
    var isTruncated = false
    var scannedPages = 0
    var totalPages = 0

    var id: UUID { document.id }
    var isMatch: Bool { filenameMatched || !matches.isEmpty }
}

struct PDFGallerySearchProgress: Equatable {
    enum Phase: Equatable { case idle, searching, completed, cancelled }

    var phase: Phase = .idle
    var scannedDocuments = 0
    var totalDocuments = 0
    var scannedPages = 0
    var resultCount = 0
    var isTruncated = false
    var skippedDocumentCount = 0

    var fraction: Double {
        guard totalDocuments > 0 else { return phase == .completed ? 1 : 0 }
        return min(1, Double(scannedDocuments) / Double(totalDocuments))
    }

    static let idle = Self()
}

struct PDFGallerySearchConfiguration: Sendable {
    var maximumTotalResults = 200
    var maximumResultsPerDocument = 12
    var maximumResultsPerPage = 4
    var publicationPageBatch = 6
    var debounceNanoseconds: UInt64 = 220_000_000

    static let standard = Self()
}
