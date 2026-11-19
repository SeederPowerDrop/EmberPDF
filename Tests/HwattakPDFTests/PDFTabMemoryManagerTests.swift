// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFTabMemoryManagerTests: XCTestCase {
    func testNormalBudgetHibernatesOldestEligibleTabsOnly() {
        let ids = (0..<6).map { _ in UUID() }
        let inputs = ids.enumerated().map { index, id in
            PDFTabMemoryPolicyInput(
                id: id,
                isLoaded: true,
                isActive: index == 5,
                isProtected: index == 1,
                canHibernate: index != 2
            )
        }
        let recency = Dictionary(
            uniqueKeysWithValues: ids.enumerated().map { ($0.element, UInt64($0.offset + 1)) }
        )

        let selected = PDFTabMemoryPolicy().hibernationCandidates(
            inputs: inputs,
            lastAccessSequence: recency,
            loadedTabBudget: 3
        )

        XCTAssertEqual(selected, [ids[0], ids[3], ids[4]])
        XCTAssertFalse(selected.contains(ids[1]), "comparison-visible tabs stay resident")
        XCTAssertFalse(selected.contains(ids[2]), "dirty/OCR-pinned tabs stay resident")
        XCTAssertFalse(selected.contains(ids[5]), "the active tab stays resident")
    }

    func testWarningAndCriticalPressureReleaseRecreatableLRUWorkingSet() {
        let ids = (0..<7).map { _ in UUID() }
        let inputs = ids.enumerated().map { index, id in
            PDFTabMemoryPolicyInput(
                id: id,
                isLoaded: true,
                isActive: index == 6,
                isProtected: false,
                canHibernate: index != 1
            )
        }
        let recency = Dictionary(
            uniqueKeysWithValues: ids.enumerated().map { ($0.element, UInt64($0.offset)) }
        )
        let policy = PDFTabMemoryPolicy()

        XCTAssertEqual(
            policy.hibernationCandidates(
                inputs: inputs,
                lastAccessSequence: recency,
                loadedTabBudget: 12,
                pressure: .warning
            ),
            [ids[0], ids[2], ids[3]]
        )
        XCTAssertEqual(
            policy.hibernationCandidates(
                inputs: inputs,
                lastAccessSequence: recency,
                loadedTabBudget: 12,
                pressure: .critical
            ),
            [ids[0], ids[2], ids[3], ids[4], ids[5]]
        )
    }

    func testLoadedTabBudgetNormalizationIsBounded() {
        XCTAssertEqual(PDFTabMemorySettings.normalizedBudget(-100), 1)
        XCTAssertEqual(PDFTabMemorySettings.normalizedBudget(4), 4)
        XCTAssertEqual(PDFTabMemorySettings.normalizedBudget(10_000), 12)
    }

    @MainActor
    func testViewportRestoreClampsFiniteValuesAndIgnoresNonFinitePayloads() {
        let workspace = PDFWorkspaceState()
        workspace.restorePDFViewport(
            autoScales: false,
            scaleFactor: 500,
            horizontalScrollProgress: -2,
            verticalScrollProgress: 7
        )
        XCTAssertFalse(workspace.pdfViewportState.autoScales)
        XCTAssertEqual(workspace.pdfViewportState.scaleFactor, 20)
        XCTAssertEqual(workspace.pdfViewportState.scrollProgress?.horizontal, 0)
        XCTAssertEqual(workspace.pdfViewportState.scrollProgress?.vertical, 1)

        workspace.restorePDFViewport(
            autoScales: false,
            scaleFactor: .infinity,
            horizontalScrollProgress: .nan,
            verticalScrollProgress: 0.5
        )
        XCTAssertTrue(workspace.pdfViewportState.autoScales)
        XCTAssertNil(workspace.pdfViewportState.scaleFactor)
        XCTAssertNil(workspace.pdfViewportState.scrollProgress)
    }

    @MainActor
    func testComparisonViewportDoesNotOverwriteNormalTabViewport() {
        let workspace = PDFWorkspaceState()
        workspace.currentPageIndex = 4
        workspace.recordPDFViewport(
            autoScales: false,
            scaleFactor: 1.6,
            scrollProgress: PDFScrollProgress(horizontal: 0.1, vertical: 0.65),
            context: .normal
        )
        workspace.currentPageIndex = 9
        workspace.recordPDFViewport(
            autoScales: true,
            scaleFactor: 0.8,
            scrollProgress: PDFScrollProgress(horizontal: 0.8, vertical: 0.2),
            context: .comparison
        )

        XCTAssertEqual(workspace.pdfViewportState.capturedPageIndex, 4)
        XCTAssertEqual(workspace.pdfViewportState.scrollProgress?.vertical, 0.65)
        XCTAssertNil(workspace.pdfViewportState.scrollProgress(forPageIndex: 9))
        XCTAssertEqual(
            workspace.pdfViewportState.scrollProgress(forPageIndex: 4)?.vertical,
            0.65
        )
        XCTAssertEqual(
            workspace.pdfViewportState(for: .comparison).capturedPageIndex,
            9
        )
        XCTAssertEqual(
            workspace.pdfViewportState(for: .comparison).scrollProgress?.vertical,
            0.2
        )
    }

    @MainActor
    func testCleanWorkspaceHibernatesAndResumesAtPreservedPage() throws {
        let fixture = try makePDF(pageCount: 4)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.setCurrentPage(3)
        workspace.selectedPages = [2, 3]
        workspace.sidebarVisible = false
        workspace.gridLayoutMode = .singleRow
        workspace.recordPDFViewport(
            autoScales: false,
            scaleFactor: 1.75,
            scrollProgress: PDFScrollProgress(horizontal: 0.2, vertical: 0.73)
        )

        XCTAssertTrue(workspace.hibernateIfPossible())
        XCTAssertNil(workspace.document)
        XCTAssertTrue(workspace.hasOpenDocument)
        XCTAssertTrue(workspace.isHibernated)
        XCTAssertEqual(workspace.pageCount, 4)
        XCTAssertEqual(workspace.currentPageIndex, 3)
        XCTAssertEqual(workspace.selectedPages, [2, 3])
        XCTAssertFalse(workspace.sidebarVisible)
        XCTAssertEqual(workspace.gridLayoutMode, .singleRow)
        XCTAssertEqual(workspace.pdfViewportState.scaleFactor, 1.75)
        XCTAssertEqual(workspace.pdfViewportState.scrollProgress?.horizontal, 0.2)
        XCTAssertEqual(workspace.pdfViewportState.scrollProgress?.vertical, 0.73)

        XCTAssertTrue(workspace.resumeIfNeeded())
        XCTAssertNotNil(workspace.document)
        XCTAssertFalse(workspace.isHibernated)
        XCTAssertEqual(workspace.documentURL, fixture.url)
        XCTAssertEqual(workspace.currentPageIndex, 3)
        XCTAssertEqual(workspace.selectedPages, [2, 3])
        XCTAssertFalse(workspace.pdfViewportState.autoScales)
        XCTAssertEqual(workspace.pdfViewportState.scaleFactor, 1.75)
        XCTAssertEqual(workspace.pdfViewportState.scrollProgress?.vertical, 0.73)
    }

    @MainActor
    func testDirtyWorkspaceIsNeverHibernated() throws {
        let fixture = try makePDF(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)

        XCTAssertTrue(workspace.isDirty)
        XCTAssertFalse(workspace.canHibernate)
        XCTAssertFalse(workspace.hibernateIfPossible())
        XCTAssertNotNil(workspace.document)
    }

    @MainActor
    func testFailedLazyResumeKeepsTabMetadataForRetry() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).pdf")
        let workspace = PDFWorkspaceState()
        workspace.restoreHibernated(
            url: missingURL,
            pageCount: 321,
            currentPageIndex: 120,
            selectedPages: [120]
        )

        XCTAssertTrue(workspace.hasOpenDocument)
        XCTAssertTrue(workspace.isHibernated)
        XCTAssertFalse(workspace.resumeIfNeeded())
        XCTAssertEqual(workspace.documentURL, missingURL)
        XCTAssertEqual(workspace.pageCount, 321)
        XCTAssertEqual(workspace.currentPageIndex, 120)
        XCTAssertNotNil(workspace.presentedError)
    }

    func testLightweightInspectorValidatesContainerAndReadsPageCount() throws {
        let fixture = try makePDF(pageCount: 4)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }

        let descriptor = try CoreGraphicsPDFLazyDocumentInspector().inspect(fixture.url)

        XCTAssertEqual(descriptor.url, fixture.url)
        XCTAssertEqual(descriptor.pageCount, 4)
    }

    func testLightweightInspectorRejectsInvalidPDFWithoutPDFKitWorkspace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Lazy-Invalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: url)

        XCTAssertThrowsError(try CoreGraphicsPDFLazyDocumentInspector().inspect(url))
    }

    func testAsyncBatchInspectorLimitsIOConcurrencyAndPreservesRequestOrder() async {
        let urls = (0..<8).map {
            URL(fileURLWithPath: "/tmp/async-inspection-\($0).pdf")
        }
        let invalidURL = urls[3]
        let inspector = TrackingLazyDocumentInspector(
            invalidURLs: [invalidURL],
            delay: { url in
                let index = Int(url.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "0") ?? 0
                return TimeInterval(8 - index) * 0.004
            }
        )

        let outcomes = await PDFLazyDocumentBatchInspector(
            inspector: inspector,
            maximumConcurrency: 3
        ).inspect(urls)

        XCTAssertEqual(outcomes.map(\.url), urls)
        XCTAssertEqual(outcomes[3].descriptor, nil)
        XCTAssertEqual(
            outcomes.compactMap(\.descriptor).map(\.url),
            urls.filter { $0 != invalidURL }
        )
        XCTAssertEqual(inspector.maximumObservedConcurrency, 3)
    }

    @MainActor
    func testAsyncWorkspaceBatchKeepsOrderDeduplicatesInvalidAndLoadsOnlyFinalTab() async throws {
        let fixture = try makePDF(pageCount: 2, fileCount: 4)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let invalidURL = fixture.directory.appendingPathComponent("damaged.pdf")
        try Data("not a PDF".utf8).write(to: invalidURL)
        let workspace = MultiDocumentWorkspaceState()
        let requested = [
            fixture.urls[0],
            fixture.urls[1],
            fixture.urls[1],
            invalidURL,
            fixture.urls[2],
        ]

        let opened = await workspace.openPDFsInTabsAsync(
            urls: requested,
            maximumInspectionConcurrency: 2
        )

        XCTAssertEqual(opened.count, 3)
        XCTAssertEqual(
            workspace.tabs.compactMap { $0.workspace.documentURL },
            [fixture.urls[0], fixture.urls[1], fixture.urls[2]]
        )
        XCTAssertEqual(workspace.activeTabID, opened.last)
        XCTAssertEqual(workspace.tabs.count { $0.workspace.document != nil }, 1)
        XCTAssertEqual(workspace.tabs.count { $0.workspace.isHibernated }, 2)
        XCTAssertTrue(workspace.activeWorkspace?.presentedError?.contains("damaged.pdf") == true)
    }

    @MainActor
    func testCancellingPendingUIBatchPreventsLateTabRecentAndSelectionMutation() async {
        let started = expectation(description: "background metadata inspection started")
        let inspector = TrackingLazyDocumentInspector(
            delay: { _ in 0.08 },
            onFirstStart: { started.fulfill() }
        )
        let workspace = MultiDocumentWorkspaceState(lazyDocumentInspector: inspector)
        let initialTabID = workspace.activeTabID
        let urls = (0..<5).map {
            URL(fileURLWithPath: "/tmp/cancelled-batch-\($0).pdf")
        }
        var completionCalled = false

        let task = workspace.beginOpeningPDFsInTabs(urls: urls) { _ in
            completionCalled = true
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(workspace.hasPendingBatchOpen)

        // This is the same lifecycle hook TabbedWorkspaceView invokes from
        // onDisappear. The main actor remains responsive while inspection is
        // running because Core Graphics work is in bounded child tasks.
        workspace.cancelPendingBatchOpen()
        let opened = await task.value

        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(workspace.hasPendingBatchOpen)
        XCTAssertFalse(completionCalled)
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.activeTabID, initialTabID)
        XCTAssertFalse(workspace.tabs[0].workspace.hasOpenDocument)
        XCTAssertTrue(workspace.recentDocuments.isEmpty)
    }

    @MainActor
    func testWorkspaceSwitchCancelsBatchInsteadOfInstallingIntoWrongWorkspace() async {
        let started = expectation(description: "workspace batch inspection started")
        let inspector = TrackingLazyDocumentInspector(
            delay: { _ in 0.08 },
            onFirstStart: { started.fulfill() }
        )
        let workspace = MultiDocumentWorkspaceState(lazyDocumentInspector: inspector)
        let sourceWorkspaceID = workspace.activeWorkspaceID
        let destinationWorkspaceID = workspace.createWorkspace(activate: false)
        let urls = (0..<4).map {
            URL(fileURLWithPath: "/tmp/switched-workspace-batch-\($0).pdf")
        }

        let task = workspace.beginOpeningPDFsInTabs(urls: urls)
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(workspace.selectWorkspace(destinationWorkspaceID))
        let opened = await task.value

        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(workspace.hasPendingBatchOpen)
        XCTAssertTrue(
            workspace.sessions(inWorkspace: sourceWorkspaceID).allSatisfy {
                !$0.workspace.hasOpenDocument
            }
        )
        XCTAssertTrue(
            workspace.sessions(inWorkspace: destinationWorkspaceID).allSatisfy {
                !$0.workspace.hasOpenDocument
            }
        )
        XCTAssertTrue(workspace.recentDocuments.isEmpty)
    }

    @MainActor
    func testManagerAppliesBudgetAndCriticalPressureWithoutTouchingDirtyTab() async throws {
        let fixture = try makePDF(pageCount: 1, fileCount: 5)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = MultiDocumentWorkspaceState()
        let ids = workspace.openPDFsInTabs(urls: fixture.urls)
        XCTAssertEqual(ids.count, 5)
        workspace.selectTab(ids[0])
        workspace.activeWorkspace?.setMode(.editing)
        workspace.activeWorkspace?.rotateSelectedPages(clockwise: true)
        // Batch open leaves these inactive tabs lazy. Resume several before
        // constructing the manager so its normal/critical policies have a
        // realistic resident working set to trim.
        workspace.selectTab(ids[1])
        workspace.selectTab(ids[2])
        workspace.selectTab(ids[4])
        let pressure = StubPDFMemoryPressureMonitor()
        var clock: TimeInterval = 10
        let manager = PDFTabMemoryManager(
            workspace: workspace,
            loadedTabBudget: 2,
            pressureMonitor: pressure,
            uptime: {
                defer { clock += 0.001 }
                return clock
            }
        )

        XCTAssertLessThanOrEqual(manager.metrics.loadedDocumentCount, 2)
        XCTAssertTrue(
            workspace.tabs.first(where: { $0.id == ids[0] })?.workspace.document != nil,
            "dirty documents are pinned even when the loaded budget is exceeded"
        )
        XCTAssertTrue(workspace.activeWorkspace?.document != nil)

        pressure.send(.critical)
        await Task.yield()

        XCTAssertEqual(manager.metrics.loadedDocumentCount, 2)
        XCTAssertEqual(manager.metrics.lastPressureLevel, .critical)
        XCTAssertGreaterThanOrEqual(manager.metrics.cumulativeHibernations, 2)
    }

    @MainActor
    func testBatchOpenConstructsOnlyFinalPDFDocumentAndKeepsOtherTabsLazy() throws {
        let defaults = UserDefaults.standard
        let key = PDFTabMemorySettings.loadedTabBudgetKey
        let previousValue = defaults.object(forKey: key)
        defaults.set(2, forKey: key)
        addTeardownBlock {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let fixture = try makePDF(pageCount: 1, fileCount: 8)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = MultiDocumentWorkspaceState()

        let opened = workspace.openPDFsInTabs(urls: fixture.urls)

        XCTAssertEqual(opened.count, 8)
        XCTAssertEqual(workspace.documentSessions.count, 8)
        XCTAssertEqual(workspace.tabs.count { $0.workspace.document != nil }, 1)
        XCTAssertEqual(workspace.tabs.count { $0.workspace.isHibernated }, 7)
        XCTAssertNotNil(workspace.activeWorkspace?.document)
        XCTAssertEqual(workspace.activeTabID, opened.last)
        XCTAssertEqual(
            workspace.tabs.first(where: { $0.id == opened[0] })?.workspace.pageCount,
            1
        )

        // The inspector's temporary access object has already been released.
        // A lazy tab still resumes because PDFWorkspaceState retained its own
        // security-scoped lifetime when the descriptor was installed.
        let previousActive = try XCTUnwrap(workspace.activeWorkspace)
        XCTAssertTrue(previousActive.hibernateIfPossible())
        workspace.selectTab(opened[0])
        XCTAssertNotNil(workspace.activeWorkspace?.document)
        XCTAssertEqual(workspace.activeWorkspace?.documentURL, fixture.urls[0])
    }

    @MainActor
    func testComparisonExitDefersAndCoalescesCleanupOneDocumentPerSlice() throws {
        let setup = try makeComparisonMemorySetup()
        let manager = setup.manager
        let scheduler = setup.scheduler

        manager.releaseComparisonProtectionAfterTransition()
        manager.enforceBudget()
        manager.workspaceContentsDidChange()
        manager.updateLoadedTabBudget(1)
        manager.releaseComparisonProtectionAfterTransition()

        XCTAssertEqual(manager.metrics.loadedDocumentCount, 4, "exit must not release PDF graphs inline")
        XCTAssertEqual(scheduler.pendingJobs.count, 1, "eligibility callbacks join the existing cleanup")
        XCTAssertEqual(scheduler.pendingJobs.first?.delay, 0.2)
        for remaining in [3, 2, 1] {
            scheduler.fireNext()
            XCTAssertEqual(manager.metrics.loadedDocumentCount, remaining)
            XCTAssertNotNil(setup.workspace.activeWorkspace?.document)
            if remaining > 1 {
                XCTAssertEqual(scheduler.pendingJobs.count, 1)
                XCTAssertEqual(scheduler.pendingJobs.first?.delay, 0.05)
            }
        }
        XCTAssertTrue(scheduler.pendingJobs.isEmpty)
        XCTAssertEqual(manager.metrics.cumulativeHibernations, 3)
    }

    @MainActor
    func testRemovingAComparisonPaneDefersItsReleaseAndKeepsSurvivorsResident() throws {
        let setup = try makeComparisonMemorySetup()
        let removedID = setup.ids[0]
        let removed = try XCTUnwrap(setup.workspace.tabs.first { $0.id == removedID })
        let survivingIDs = Set(setup.ids.dropFirst())

        setup.manager.setProtectedTabIDs(survivingIDs, deferCleanup: true)
        setup.manager.workspaceContentsDidChange()
        setup.manager.enforceBudget()

        XCTAssertNotNil(removed.workspace.document, "The outgoing PDFView must detach before document release.")
        XCTAssertEqual(setup.manager.metrics.loadedDocumentCount, 4)
        XCTAssertEqual(setup.scheduler.pendingJobs.count, 1)
        XCTAssertEqual(setup.scheduler.pendingJobs.first?.delay, 0.2)

        setup.scheduler.fireNext()

        XCTAssertTrue(removed.workspace.isHibernated)
        XCTAssertTrue(removed.workspace.hasOpenDocument, "Removing a comparison pane must keep its tab available.")
        XCTAssertEqual(setup.workspace.tabs.count, 4)
        XCTAssertTrue(setup.workspace.tabs.filter { survivingIDs.contains($0.id) }
            .allSatisfy { $0.workspace.document != nil })
        XCTAssertEqual(setup.manager.metrics.loadedDocumentCount, 3)
        XCTAssertTrue(setup.scheduler.pendingJobs.isEmpty)
    }

    @MainActor
    func testReplacingAComparisonPaneResumesNewPDFBeforeDeferringOldPDFRelease() throws {
        let setup = try makeComparisonMemorySetup()
        let old = try XCTUnwrap(setup.workspace.tabs.first { $0.id == setup.ids[0] })
        let survivor = try XCTUnwrap(setup.workspace.tabs.first { $0.id == setup.ids[1] })
        let replacement = try XCTUnwrap(setup.workspace.tabs.first { $0.id == setup.ids[2] })
        setup.manager.setProtectedTabIDs([old.id, survivor.id])
        XCTAssertTrue(replacement.workspace.isHibernated)

        setup.manager.setProtectedTabIDs([survivor.id, replacement.id], deferCleanup: true)
        setup.manager.enforceBudget()

        XCTAssertNotNil(old.workspace.document, "The old pane must survive the replacement transition.")
        XCTAssertNotNil(survivor.workspace.document)
        XCTAssertNotNil(replacement.workspace.document, "The replacement is resident before presentation changes.")
        XCTAssertFalse(replacement.workspace.isHibernated)
        XCTAssertEqual(setup.scheduler.pendingJobs.count, 1)

        setup.scheduler.fireNext()

        XCTAssertTrue(old.workspace.isHibernated)
        XCTAssertNotNil(survivor.workspace.document)
        XCTAssertNotNil(replacement.workspace.document)
        XCTAssertNotNil(setup.workspace.activeWorkspace?.document)
        XCTAssertEqual(setup.workspace.tabs.count, 4)
        XCTAssertEqual(setup.manager.metrics.loadedDocumentCount, 3)
        XCTAssertTrue(setup.scheduler.pendingJobs.isEmpty)
    }

    @MainActor
    func testDeferredCleanupReevaluatesResumedActiveDirtyAndClosedTabs() throws {
        let setup = try makeComparisonMemorySetup()
        setup.manager.releaseComparisonProtectionAfterTransition()
        setup.scheduler.fireNext()
        XCTAssertEqual(setup.manager.metrics.loadedDocumentCount, 3)
        let hibernated = try XCTUnwrap(setup.workspace.tabs.first { $0.workspace.isHibernated })
        let dirty = try XCTUnwrap(setup.workspace.tabs.first {
            $0.workspace.document != nil && $0.id != setup.workspace.activeTabID
        })
        dirty.workspace.setMode(.editing)
        dirty.workspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(dirty.workspace.isDirty)
        let toClose = try XCTUnwrap(setup.workspace.tabs.first {
            $0.id != hibernated.id && $0.id != dirty.id && $0.id != setup.workspace.activeTabID
        })
        XCTAssertTrue(setup.workspace.closeTab(toClose.id))
        setup.workspace.selectTab(hibernated.id)
        setup.manager.activeTabDidChange()
        setup.manager.workspaceContentsDidChange()

        setup.scheduler.fireNext()

        XCTAssertEqual(setup.manager.metrics.loadedDocumentCount, 2)
        XCTAssertNotNil(dirty.workspace.document, "new edits remain resident even above the budget")
        XCTAssertNotNil(hibernated.workspace.document, "a newly resumed active tab must survive old work")
        XCTAssertTrue(setup.scheduler.pendingJobs.isEmpty)
    }

    @MainActor
    func testReenteringComparisonCancelsPendingAndLateCleanupCallbacks() throws {
        let setup = try makeComparisonMemorySetup()
        setup.manager.releaseComparisonProtectionAfterTransition()
        let cancelledJob = try XCTUnwrap(setup.scheduler.pendingJobs.first)

        setup.manager.setProtectedTabIDs(Set(setup.ids))
        XCTAssertTrue(cancelledJob.isCancelled)
        cancelledJob.fireIgnoringCancellation()

        XCTAssertEqual(setup.manager.metrics.loadedDocumentCount, 4)
        XCTAssertTrue(setup.scheduler.pendingJobs.isEmpty)
        setup.manager.releaseComparisonProtectionAfterTransition()
        cancelledJob.fireIgnoringCancellation()
        XCTAssertEqual(setup.scheduler.pendingJobs.count, 1, "an old callback cannot consume the new cleanup")
        setup.scheduler.fireNext()
        XCTAssertEqual(setup.manager.metrics.loadedDocumentCount, 3)
    }

    @MainActor
    func testMemoryPressureBypassesExitDelayAndCancelsItsScheduledWork() throws {
        let setup = try makeComparisonMemorySetup()
        setup.manager.releaseComparisonProtectionAfterTransition()
        let cancelledJob = try XCTUnwrap(setup.scheduler.pendingJobs.first)

        setup.manager.handleMemoryPressure(.critical)

        XCTAssertEqual(setup.manager.metrics.loadedDocumentCount, 1)
        XCTAssertEqual(setup.manager.metrics.lastPressureLevel, .critical)
        XCTAssertNotNil(setup.workspace.activeWorkspace?.document)
        XCTAssertTrue(cancelledJob.isCancelled)
        cancelledJob.fireIgnoringCancellation()
        XCTAssertTrue(setup.scheduler.pendingJobs.isEmpty)
        XCTAssertEqual(setup.manager.metrics.cumulativeHibernations, 3)
    }

    @MainActor
    func testDeferredCleanupDoesNotRetainManagerOrWorkspaceAfterWindowCloses() throws {
        let fixture = try makePDF(pageCount: 1, fileCount: 4)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let scheduler = ManualPDFTabMemoryCleanupScheduler()
        let pressure = StubPDFMemoryPressureMonitor()
        weak var weakManager: PDFTabMemoryManager?
        weak var weakWorkspace: MultiDocumentWorkspaceState?
        var pendingJob: ManualPDFTabMemoryCleanupScheduler.Job?
        do {
            let workspace = MultiDocumentWorkspaceState()
            let ids = workspace.openPDFsInTabs(urls: fixture.urls)
            let manager = PDFTabMemoryManager(
                workspace: workspace,
                loadedTabBudget: 1,
                pressureMonitor: pressure,
                cleanupScheduler: scheduler
            )
            weakManager = manager
            weakWorkspace = workspace
            manager.setProtectedTabIDs(Set(ids))
            manager.releaseComparisonProtectionAfterTransition()
            pendingJob = scheduler.pendingJobs.first
        }

        XCTAssertNil(weakManager)
        XCTAssertNil(weakWorkspace)
        XCTAssertTrue(try XCTUnwrap(pendingJob).isCancelled)
        pendingJob?.fireIgnoringCancellation()
        XCTAssertTrue(scheduler.pendingJobs.isEmpty)
    }

    @MainActor
    private func makeComparisonMemorySetup() throws -> (
        workspace: MultiDocumentWorkspaceState,
        ids: [UUID],
        manager: PDFTabMemoryManager,
        scheduler: ManualPDFTabMemoryCleanupScheduler
    ) {
        let fixture = try makePDF(pageCount: 1, fileCount: 4)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = MultiDocumentWorkspaceState()
        let ids = workspace.openPDFsInTabs(urls: fixture.urls)
        let scheduler = ManualPDFTabMemoryCleanupScheduler()
        let manager = PDFTabMemoryManager(
            workspace: workspace,
            loadedTabBudget: 1,
            pressureMonitor: StubPDFMemoryPressureMonitor(),
            cleanupScheduler: scheduler
        )
        manager.setProtectedTabIDs(Set(ids))
        XCTAssertEqual(manager.metrics.loadedDocumentCount, 4)
        return (workspace, ids, manager, scheduler)
    }

    func testHundredTabPolicyPlanningBenchmark() {
        let ids = (0..<100).map { _ in UUID() }
        let inputs = ids.enumerated().map { index, id in
            PDFTabMemoryPolicyInput(
                id: id,
                isLoaded: true,
                isActive: index == 99,
                isProtected: false,
                canHibernate: true
            )
        }
        let recency = Dictionary(
            uniqueKeysWithValues: ids.enumerated().map { ($0.element, UInt64($0.offset)) }
        )
        let policy = PDFTabMemoryPolicy()

        measure {
            for _ in 0..<1_000 {
                _ = policy.hibernationCandidates(
                    inputs: inputs,
                    lastAccessSequence: recency,
                    loadedTabBudget: 3
                )
            }
        }
    }

    private func makePDF(
        pageCount: Int,
        fileCount: Int = 1
    ) throws -> (directory: URL, url: URL, urls: [URL]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for fileIndex in 0..<fileCount {
            let document = PDFDocument()
            for pageIndex in 0..<pageCount {
                let image = NSImage(size: CGSize(width: 140, height: 190), flipped: false) { rect in
                    NSColor.white.setFill()
                    rect.fill()
                    NSColor.black.setFill()
                    NSRect(x: 12, y: 12 + CGFloat(pageIndex), width: 30, height: 4).fill()
                    return true
                }
                document.insert(try XCTUnwrap(PDFPage(image: image)), at: pageIndex)
            }
            let url = directory.appendingPathComponent("fixture-\(fileIndex).pdf")
            XCTAssertTrue(document.write(to: url))
            urls.append(url)
        }
        return (directory, try XCTUnwrap(urls.first), urls)
    }
}

private final class ManualPDFTabMemoryCleanupScheduler: PDFTabMemoryCleanupScheduling {
    final class Job: PDFTabMemoryCleanupToken {
        let delay: TimeInterval
        private let action: @MainActor () -> Void
        private(set) var isCancelled = false
        private(set) var hasFired = false

        init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.action = action
        }

        func cancel() { isCancelled = true }

        @MainActor
        func fireIgnoringCancellation() {
            hasFired = true
            action()
        }
    }

    private var jobs: [Job] = []
    var pendingJobs: [Job] { jobs.filter { !$0.isCancelled && !$0.hasFired } }

    @MainActor
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any PDFTabMemoryCleanupToken {
        let job = Job(delay: delay, action: action)
        jobs.append(job)
        return job
    }

    @MainActor
    func fireNext() { pendingJobs.first?.fireIgnoringCancellation() }
}

private final class TrackingLazyDocumentInspector: PDFLazyDocumentInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private let invalidURLs: Set<URL>
    private let delay: (URL) -> TimeInterval
    private let onFirstStart: (() -> Void)?
    private var activeCount = 0
    private var maximumCount = 0
    private var hasStarted = false

    init(
        invalidURLs: Set<URL> = [],
        delay: @escaping (URL) -> TimeInterval,
        onFirstStart: (() -> Void)? = nil
    ) {
        self.invalidURLs = invalidURLs
        self.delay = delay
        self.onFirstStart = onFirstStart
    }

    var maximumObservedConcurrency: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumCount
    }

    func inspect(_ url: URL) throws -> PDFLazyDocumentDescriptor {
        lock.lock()
        activeCount += 1
        maximumCount = max(maximumCount, activeCount)
        let isFirst = !hasStarted
        hasStarted = true
        lock.unlock()

        if isFirst {
            onFirstStart?()
        }
        Thread.sleep(forTimeInterval: delay(url))

        lock.lock()
        activeCount -= 1
        lock.unlock()
        if invalidURLs.contains(url) {
            throw WorkspaceError.invalidPDF(url)
        }
        return PDFLazyDocumentDescriptor(url: url, pageCount: 1)
    }
}

private final class StubPDFMemoryPressureMonitor: PDFMemoryPressureMonitoring {
    private var handler: ((PDFMemoryPressureLevel) -> Void)?

    func start(handler: @escaping (PDFMemoryPressureLevel) -> Void) {
        self.handler = handler
    }

    func stop() {
        handler = nil
    }

    func send(_ level: PDFMemoryPressureLevel) {
        handler?(level)
    }
}
