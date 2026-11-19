// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

/// Explicitly opted-in integration coverage for private, local PDF collections.
/// The manifest contains [{"id":"pdf-001","path":"...","bytes":123,...}].
/// Accepts 4...30 explicitly selected files; it never discovers additional PDFs.
/// Workspaces contain at most 10 tabs and groups contain at most 5 tabs.
/// No fixture name, path, extracted text, or bookmark is included in the report.
/// Run with EMBER_STRESS_MANIFEST and EMBER_STRESS_REPORT set to absolute paths.
/// A subprocess timeout is still needed: synchronous PDFKit parsing/rendering
/// cannot be safely interrupted by a cooperative Swift task deadline.
final class RealPDFStressTests: XCTestCase {
    @MainActor
    func testLargeLocalPDFsAcrossWorkspaces() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifestPath = environment["EMBER_STRESS_MANIFEST"], !manifestPath.isEmpty else {
            throw XCTSkip("Real local PDFs are opt-in via EMBER_STRESS_MANIFEST.")
        }
        guard manifestPath.hasPrefix("/"),
              let reportPath = environment["EMBER_STRESS_REPORT"], reportPath.hasPrefix("/") else {
            XCTFail("Stress manifest and report must have absolute paths.")
            return
        }

        let reportURL = URL(fileURLWithPath: reportPath)
        let recorder = RealPDFStressRecorder(reportURL: reportURL)
        do {
            let fixtures: [RealPDFStressFixture]
            do {
                fixtures = try JSONDecoder().decode(
                    [RealPDFStressFixture].self,
                    from: Data(contentsOf: URL(fileURLWithPath: manifestPath))
                )
            } catch {
                throw RealPDFStressFailure("manifest_read_or_decode_failed")
            }
            try recorder.require((4...30).contains(fixtures.count), "manifest_requires_4_to_30_files")
            try recorder.require(Set(fixtures.map(\.path)).count == fixtures.count, "manifest_paths_not_unique")
            let workspaceStarts = Array(stride(from: 0, to: fixtures.count, by: 10))
            recorder.report.inputBytes = fixtures.reduce(0) { $0 + $1.bytes }
            recorder.report.fileCount = fixtures.count
            try recorder.sample("baseline")

            // Check the same lightweight descriptor the app uses before any
            // activation, so an unattended run never presents a password modal.
            for (index, fixture) in fixtures.enumerated() {
                try recorder.checkDeadline()
                let valid = autoreleasepool { () -> Bool in
                    guard let descriptor = try? CoreGraphicsPDFLazyDocumentInspector().inspect(fixture.url) else {
                        return false
                    }
                    return !descriptor.isEncrypted && descriptor.pageCount > 0
                }
                try recorder.require(valid, "fixture_\(index + 1)_invalid_or_locked")
            }

            let persistence = RealPDFStressSessionPersistence()
            let recentPersistence = RealPDFStressRecentPersistence()
            let bookmarkCoder = RealPDFStressBookmarkCoder()
            let sessionStore = WorkspaceSessionStore(persistence: persistence, bookmarkCoder: bookmarkCoder)
            let recentStore = RecentDocumentsStore(persistence: recentPersistence, bookmarkCoder: bookmarkCoder)
            let state = MultiDocumentWorkspaceState(recentDocumentsStore: recentStore, sessionStore: sessionStore)
            let manager = PDFTabMemoryManager(
                workspace: state,
                loadedTabBudget: 3,
                pressureMonitor: RealPDFStressPressureMonitor()
            )
            defer {
                state.freezeSessionPersistenceAfterFlushing()
                for session in state.allTabs { session.workspace.close() }
            }

            var workspaceIDs: [UUID] = []
            var tabIDs: [UUID] = []
            var memberships: [UUID: UUID] = [:]
            var expectedPages: [UUID: Int] = [:]
            var expectedSelections: [UUID: Set<Int>] = [:]
            var pageCounts: [UUID: Int] = [:]
            var groupMembers: [UUID: Set<UUID>] = [:]

            for (workspaceIndex, start) in workspaceStarts.enumerated() {
                try recorder.checkDeadline()
                let workspaceID = workspaceIndex == 0
                    ? state.activeWorkspaceID
                    : state.createWorkspace(title: "Stress \(workspaceIndex + 1)")
                workspaceIDs.append(workspaceID)
                let batch = Array(fixtures[start..<min(start + 10, fixtures.count)])
                let began = recorder.uptime
                let opened = await state.openPDFsInTabsAsync(
                    urls: batch.map(\.url),
                    maximumInspectionConcurrency: 3
                )
                manager.workspaceContentsDidChange()
                try recorder.require(opened.count == batch.count, "batch_\(workspaceIndex + 1)_open_count")
                try recorder.require(state.tabs.count == batch.count, "batch_\(workspaceIndex + 1)_tab_count")
                try recorder.require(state.activeTabID == opened.last, "batch_active_tab")
                // Compare internally without putting a private URL in XCTest output.
                try recorder.require(
                    state.tabs.compactMap { $0.workspace.documentURL } == batch.map(\.url),
                    "batch_order_or_identity"
                )
                recorder.recordDuration("batch_import", seconds: recorder.uptime - began)
                tabIDs.append(contentsOf: opened)
                for id in opened { memberships[id] = workspaceID }
                for (groupIndex, groupStart) in stride(from: 0, to: opened.count, by: 5).enumerated() {
                    let members = Array(opened[groupStart..<min(groupStart + 5, opened.count)])
                    guard let groupID = state.createTabGroup(
                        title: "Collection \(groupIndex + 1)", tabIDs: members
                    ) else { throw RealPDFStressFailure("group_creation_failed") }
                    groupMembers[groupID] = Set(members)
                }
                try recorder.checkState(state, manager: manager)
                try recorder.sample("batch_\(workspaceIndex + 1)", state: state, manager: manager)
                await Task.yield()
            }
            recorder.report.workspaceCount = state.workspaces.count
            try recorder.require(state.allTabs.count == fixtures.count, "total_tab_count")
            try recorder.require(state.workspaces.count == workspaceStarts.count, "workspace_count")
            try checkOrganization(state, memberships: memberships, groups: groupMembers, recorder: recorder)

            // Visit every actual PDF and exercise representative pages. PDFKit
            // thumbnails are rasterized to force decoding, then promptly released.
            for (index, id) in tabIDs.enumerated() {
                try recorder.checkDeadline()
                try activate(id, in: state, manager: manager, memberships: memberships, recorder: recorder)
                guard let workspace = state.activeWorkspace else {
                    throw RealPDFStressFailure("active_workspace_missing")
                }
                let count = workspace.pageCount
                let pages = Array(Set([0, count / 2, count - 1])).sorted()
                let renderBegan = recorder.uptime
                for pageIndex in pages {
                    try autoreleasepool {
                        workspace.setCurrentPage(pageIndex)
                        guard let page = workspace.document?.page(at: pageIndex) else {
                            throw RealPDFStressFailure("page_access_failed")
                        }
                        let thumbnail = page.thumbnail(of: NSSize(width: 160, height: 220), for: .cropBox)
                        var rect = CGRect(origin: .zero, size: thumbnail.size)
                        guard let bitmap = thumbnail.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                              bitmap.width > 0, bitmap.height > 0 else {
                            throw RealPDFStressFailure("thumbnail_rasterization_failed")
                        }
                        recorder.report.renderedPageCount += 1
                    }
                }
                recorder.recordDuration("three_page_render", seconds: recorder.uptime - renderBegan)
                pageCounts[id] = count
                expectedSelections[id] = Set(pages)
                workspace.selectedPages = Set(pages)
                workspace.setCurrentPage(count - 1)
                expectedPages[id] = count - 1
                workspace.recordPDFViewport(
                    autoScales: false,
                    scaleFactor: 1.25,
                    scrollProgress: PDFScrollProgress(horizontal: 0.2, vertical: 0.7)
                )
                recorder.report.documents.append(.init(ordinal: index + 1, bytes: fixtures[index].bytes, pages: count))
                try recorder.checkState(state, manager: manager)
                try recorder.sample("render_\(index + 1)", state: state, manager: manager)
                await Task.yield()
            }

            // Search one document per workspace: either finish or cancel at
            // a cooperative 3-second deadline. No OCR or whole-document export.
            for (searchIndex, index) in workspaceStarts.enumerated() {
                let id = tabIDs[index]
                try activate(id, in: state, manager: manager, memberships: memberships, recorder: recorder)
                guard let workspace = state.activeWorkspace else { throw RealPDFStressFailure("search_tab_missing") }
                let began = recorder.uptime
                workspace.searchText = "PDF"
                workspace.performSearch()
                while workspace.isSearching && recorder.uptime - began < 3 {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                let completed = !workspace.isSearching && workspace.searchProgress.phase == .completed
                if workspace.isSearching { workspace.cancelSearch() }
                recorder.report.searches.append(.init(
                    ordinal: index + 1,
                    seconds: recorder.uptime - began,
                    completed: completed,
                    scannedPages: workspace.searchProgress.completedPages,
                    resultCount: workspace.searchNavigatorResults.count
                ))
                try recorder.require(!workspace.isSearching, "search_cancel_failed")

                // Also exercise the actual deactivation path while a search
                // is scheduled; stale progress must not arrive in a hidden tab.
                workspace.performSearch()
                // A final workspace may contain just one tab. In that case,
                // wrap to the first workspace to still deactivate this tab.
                try activate(
                    tabIDs[(index + 1) % tabIDs.count],
                    in: state, manager: manager,
                    memberships: memberships, recorder: recorder
                )
                try recorder.require(!workspace.isSearching, "tab_deactivation_did_not_cancel_search")
                let oldResultCount = workspace.searchNavigatorResults.count
                await Task.yield()
                try recorder.require(workspace.searchNavigatorResults.count == oldResultCount, "stale_search_results")
                try recorder.checkState(state, manager: manager)
                // Search navigation legitimately changes the current page.
                // Re-establish the expected view before hibernation checks.
                try activate(id, in: state, manager: manager, memberships: memberships, recorder: recorder)
                workspace.setCurrentPage(expectedPages[id]!)
                workspace.selectedPages = expectedSelections[id]!
                workspace.recordPDFViewport(
                    autoScales: false, scaleFactor: 1.25,
                    scrollProgress: PDFScrollProgress(horizontal: 0.2, vertical: 0.7)
                )
                workspace.cancelSearch()
                try recorder.sample("search_\(searchIndex + 1)", state: state, manager: manager)
            }

            // Two complete return passes make every tab cross repeated
            // eviction boundaries while workspace and group membership survive.
            for pass in 0..<2 {
                for id in tabIDs {
                    try recorder.checkDeadline()
                    try activate(id, in: state, manager: manager, memberships: memberships, recorder: recorder)
                    guard let workspace = state.activeWorkspace else { throw RealPDFStressFailure("revisit_tab_missing") }
                    try recorder.require(workspace.pageCount == pageCounts[id], "page_count_not_preserved")
                    try recorder.require(workspace.currentPageIndex == expectedPages[id], "page_position_not_preserved")
                    try recorder.require(workspace.selectedPages == expectedSelections[id], "selection_not_preserved")
                    try recorder.require(workspace.pdfViewportState.scaleFactor == 1.25, "zoom_not_preserved")
                    try recorder.require(workspace.pdfViewportState.scrollProgress?.vertical == 0.7, "scroll_not_preserved")
                    if pass == 0 {
                        let nextPage = workspace.pageCount / 2
                        workspace.setCurrentPage(nextPage)
                        expectedPages[id] = nextPage
                        workspace.recordPDFViewport(
                            autoScales: false, scaleFactor: 1.25,
                            scrollProgress: PDFScrollProgress(horizontal: 0.2, vertical: 0.7)
                        )
                    }
                    recorder.report.revisitCount += 1
                    try recorder.sample("revisit_\(pass + 1)", state: state, manager: manager)
                    await Task.yield()
                }
            }

            // Multiple comparison-visible tabs may intentionally exceed the
            // normal budget. Critical pressure must preserve exactly that set
            // plus the active tab, then return to the ordinary cap on release.
            let protected = Set(tabIDs.prefix(4))
            manager.setProtectedTabIDs(protected)
            manager.handleMemoryPressure(.critical)
            let expectedLoaded = protected.union(state.activeTabID.map { [$0] } ?? [])
            let actualLoaded = Set(state.allTabs.filter { $0.workspace.document != nil }.map(\.id))
            try recorder.require(actualLoaded == expectedLoaded, "protected_comparison_tabs_not_preserved")
            try recorder.sample("protected_critical_pressure", state: state, manager: manager)
            manager.setProtectedTabIDs([])
            manager.handleMemoryPressure(.critical)
            try recorder.require(manager.metrics.loadedDocumentCount == 1, "critical_pressure_did_not_release_inactive")
            try recorder.checkState(state, manager: manager)
            recorder.report.cumulativeHibernations = manager.metrics.cumulativeHibernations
            try recorder.require(recorder.report.observedResumes >= fixtures.count, "revisit_did_not_exercise_hibernation")

            // Persist only lightweight state into a memory-backed store. Close
            // the first model before restoring so RSS does not count two live
            // copies of the entire workspace's model graph.
            let activeID = state.activeTabID
            state.freezeSessionPersistenceAfterFlushing()
            try recorder.require(sessionStore.lastError == nil && persistence.data != nil, "snapshot_failed")
            let savedSession = persistence.data
            let savedRecent = recentPersistence.data
            for session in state.allTabs { session.workspace.close() }
            await Task.yield()
            try recorder.require(persistence.data == savedSession, "frozen_session_changed_during_close")
            try recorder.sample("original_models_closed")

            let restoreStore = WorkspaceSessionStore(persistence: persistence, bookmarkCoder: bookmarkCoder)
            let restored = MultiDocumentWorkspaceState(recentDocumentsStore: recentStore, sessionStore: restoreStore)
            let restoredManager = PDFTabMemoryManager(
                workspace: restored, loadedTabBudget: 3,
                pressureMonitor: RealPDFStressPressureMonitor()
            )
            defer {
                restored.freezeSessionPersistenceAfterFlushing()
                for session in restored.allTabs { session.workspace.close() }
            }
            try recorder.require(restoreStore.lastError == nil, "restore_store_error")
            try recorder.require(restored.activeTabID == activeID, "restored_active_tab")
            try recorder.require(restored.allTabs.count == fixtures.count, "restored_tab_count")
            try recorder.require(restored.workspaces.map(\.id) == workspaceIDs, "restored_workspace_order")
            try checkOrganization(restored, memberships: memberships, groups: groupMembers, recorder: recorder)
            try recorder.require(recentPersistence.data == savedRecent, "restore_changed_recent_documents")
            try recorder.sample("restored_initial", state: restored, manager: restoredManager)
            for id in tabIDs {
                try recorder.checkDeadline()
                try activate(id, in: restored, manager: restoredManager, memberships: memberships, recorder: recorder)
                guard let workspace = restored.activeWorkspace else { throw RealPDFStressFailure("restored_tab_missing") }
                try recorder.require(workspace.currentPageIndex == expectedPages[id], "restored_page_position")
                try recorder.require(workspace.pageCount == pageCounts[id], "restored_page_count")
                try recorder.require(workspace.selectedPages == expectedSelections[id], "restored_selection")
                try recorder.require(workspace.pdfViewportState.scaleFactor == 1.25, "restored_zoom")
                try recorder.require(workspace.pdfViewportState.scrollProgress?.vertical == 0.7, "restored_scroll")
                recorder.report.restoredAndActivatedCount += 1
                try recorder.sample("restored_revisit", state: restored, manager: restoredManager)
                await Task.yield()
            }
            recorder.report.sessionRoundTripPassed = true
            recorder.report.cumulativeHibernations += restoredManager.metrics.cumulativeHibernations
            recorder.report.status = "passed"
        } catch let error as RealPDFStressFailure {
            recorder.report.status = "failed"
            recorder.report.failures.append(error.code)
            XCTFail("Real PDF stress failure: \(error.code)")
        } catch {
            // Never interpolate arbitrary Foundation/PDFKit errors: they may
            // contain a user's path or document title.
            recorder.report.status = "failed"
            recorder.report.failures.append("unexpected_runtime_error")
            XCTFail("Real PDF stress failure: unexpected_runtime_error")
        }
        recorder.report.elapsedSeconds = recorder.uptime - recorder.startedAt
        do {
            try recorder.write()
        } catch {
            XCTFail("Could not write anonymized stress report.")
        }
        print("EMBER_STRESS_RESULT status=\(recorder.report.status) files=\(recorder.report.fileCount) rendered=\(recorder.report.renderedPageCount) restored=\(recorder.report.restoredAndActivatedCount)")
    }

    @MainActor
    private func activate(
        _ id: UUID,
        in state: MultiDocumentWorkspaceState,
        manager: PDFTabMemoryManager,
        memberships: [UUID: UUID],
        recorder: RealPDFStressRecorder
    ) throws {
        let began = recorder.uptime
        guard let workspaceID = memberships[id],
              let original = state.allTabs.first(where: { $0.id == id }) else {
            throw RealPDFStressFailure("activation_identity_missing")
        }
        let wasHibernated = original.workspace.isHibernated
        try autoreleasepool {
            try recorder.require(state.selectWorkspace(workspaceID), "workspace_selection_failed")
            manager.activeTabDidChange()
            state.selectTab(id)
            manager.activeTabDidChange()
            try recorder.require(state.activeTabID == id, "tab_selection_failed")
            try recorder.require(state.activeWorkspace?.document != nil, "active_document_resume_failed")
            try recorder.checkState(state, manager: manager)
        }
        if wasHibernated { recorder.report.observedResumes += 1 }
        recorder.recordDuration("activate_workspace_and_tab", seconds: recorder.uptime - began)
    }

    @MainActor
    private func checkOrganization(
        _ state: MultiDocumentWorkspaceState,
        memberships: [UUID: UUID],
        groups: [UUID: Set<UUID>],
        recorder: RealPDFStressRecorder
    ) throws {
        for workspace in state.workspaces {
            let expectedTabs = Set(memberships.compactMap { tabID, workspaceID in
                workspaceID == workspace.id ? tabID : nil
            })
            let expectedGroups = Set(groups.compactMap { groupID, members in
                !members.isEmpty && members.isSubset(of: expectedTabs) ? groupID : nil
            })
            try recorder.require((1...10).contains(expectedTabs.count), "workspace_batch_size")
            try recorder.require(Set(workspace.tabs.map(\.id)) == expectedTabs, "workspace_containment_count")
            try recorder.require(workspace.tabs.count == expectedTabs.count, "workspace_duplicate_tabs")
            try recorder.require(Set(workspace.tabGroups.map(\.id)) == expectedGroups, "workspace_group_count")
            try recorder.require(workspace.tabGroups.count == expectedGroups.count, "workspace_duplicate_groups")
            for tab in workspace.tabs {
                try recorder.require(memberships[tab.id] == workspace.id, "workspace_containment_identity")
            }
            for group in workspace.tabGroups {
                try recorder.require((1...5).contains(group.tabIDs.count), "group_batch_size")
                try recorder.require(Set(group.tabIDs) == groups[group.id], "group_membership_changed")
            }
        }
    }
}

private struct RealPDFStressFixture: Decodable {
    let path: String
    let bytes: UInt64
    var url: URL { URL(fileURLWithPath: path) }
}

private struct RealPDFStressFailure: Error {
    let code: String
    init(_ code: String) { self.code = code }
}

private struct RealPDFStressReport: Encodable {
    struct Document: Encodable { let ordinal: Int; let bytes: UInt64; let pages: Int }
    struct Search: Encodable {
        let ordinal: Int
        let seconds: Double
        let completed: Bool
        let scannedPages: Int
        let resultCount: Int
    }
    struct Sample: Encodable {
        let phase: String
        let elapsedSeconds: Double
        let residentBytes: UInt64
        let cumulativeCPUSeconds: Double
        let loadedDocuments: Int?
        let hibernatedDocuments: Int?
    }
    var schemaVersion = 1
    var status = "running"
    var fileCount = 0
    var inputBytes: UInt64 = 0
    var workspaceCount = 0
    var renderedPageCount = 0
    var revisitCount = 0
    var restoredAndActivatedCount = 0
    var observedResumes = 0
    var cumulativeHibernations = 0
    var sessionRoundTripPassed = false
    var elapsedSeconds: Double = 0
    var documents: [Document] = []
    var searches: [Search] = []
    var durationsSeconds: [String: [Double]] = [:]
    var samples: [Sample] = []
    var failures: [String] = []
    let limitations = [
        "Model integration and bounded PDFKit rendering, not a UI event latency measurement.",
        "RSS is sampled after operations; transient allocation peaks may be higher.",
        "Search cancellation and overall deadline are cooperative between synchronous PDFKit calls.",
        "No PDF edit/save/export/OCR/network operation is invoked. Input content is never logged.",
        "Original SHA-256 and mtime verification is performed by the external test runner."
    ]
}

@MainActor
private final class RealPDFStressRecorder {
    let reportURL: URL
    let startedAt = ProcessInfo.processInfo.systemUptime
    let reader = SystemProcessResourceCountersReader()
    var report = RealPDFStressReport()
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(reportURL: URL) { self.reportURL = reportURL }

    func require(_ condition: Bool, _ code: String) throws {
        if !condition { throw RealPDFStressFailure(code) }
    }

    func checkDeadline() throws {
        try require(uptime - startedAt < 480, "overall_480_second_cooperative_deadline")
    }

    func checkState(_ state: MultiDocumentWorkspaceState, manager: PDFTabMemoryManager) throws {
        try require(state.allTabs.allSatisfy { $0.workspace.presentedError == nil }, "presented_document_error")
        try require(state.allTabs.allSatisfy { !$0.workspace.isDirty }, "read_only_document_became_dirty")
        try require(state.allTabs.filter { $0.workspace.hasOpenDocument }.allSatisfy { $0.workspace.pageCount > 0 }, "empty_document")
        try require(state.activeWorkspace?.document != nil, "active_document_missing")
        try require(manager.metrics.loadedDocumentCount <= 3, "loaded_document_budget_exceeded")
        try require(manager.metrics.loadedDocumentCount == state.allTabs.filter { $0.workspace.document != nil }.count, "memory_metrics_mismatch")
    }

    func recordDuration(_ name: String, seconds: TimeInterval) {
        report.durationsSeconds[name, default: []].append(seconds)
    }

    func sample(
        _ phase: String,
        state: MultiDocumentWorkspaceState? = nil,
        manager: PDFTabMemoryManager? = nil
    ) throws {
        let counters = try reader.readCounters()
        report.samples.append(.init(
            phase: phase,
            elapsedSeconds: uptime - startedAt,
            residentBytes: counters.residentMemoryBytes,
            cumulativeCPUSeconds: counters.cumulativeCPUTime,
            loadedDocuments: state.map { $0.allTabs.filter { $0.workspace.document != nil }.count },
            hibernatedDocuments: manager?.metrics.hibernatedDocumentCount
        ))
        report.elapsedSeconds = uptime - startedAt
        try write()
    }

    func write() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
    }
}

private final class RealPDFStressSessionPersistence: WorkspaceSessionDataPersisting {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

private final class RealPDFStressRecentPersistence: RecentDocumentsPersisting {
    var data: Data?
}

private struct RealPDFStressBookmarkCoder: WorkspaceSessionBookmarkCoding, RecentDocumentBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        guard let path = String(data: data, encoding: .utf8) else { throw RealPDFStressFailure("invalid_memory_bookmark") }
        return (URL(fileURLWithPath: path), false)
    }
}

private final class RealPDFStressPressureMonitor: PDFMemoryPressureMonitoring {
    func start(handler: @escaping (PDFMemoryPressureLevel) -> Void) {}
    func stop() {}
}
