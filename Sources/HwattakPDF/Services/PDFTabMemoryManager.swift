// SPDX-License-Identifier: MPL-2.0

import Combine
import Dispatch
import Foundation

enum PDFTabMemorySettings {
    static let loadedTabBudgetKey = "performance.loadedPDFTabBudget"
    static let defaultLoadedTabBudget = 3
    static let allowedLoadedTabBudget = 1...12

    static func normalizedBudget(_ value: Int) -> Int {
        min(allowedLoadedTabBudget.upperBound, max(allowedLoadedTabBudget.lowerBound, value))
    }
}

enum PDFMemoryPressureLevel: Int, Equatable {
    case normal
    case warning
    case critical
}

struct PDFTabMemoryPolicyInput: Equatable {
    let id: UUID
    let isLoaded: Bool
    let isActive: Bool
    let isProtected: Bool
    let canHibernate: Bool
}

/// A deterministic, allocation-light policy kept separate from PDFKit so a
/// 100+ tab workload can be tested without loading fixture documents.
struct PDFTabMemoryPolicy {
    func hibernationCandidates(
        inputs: [PDFTabMemoryPolicyInput],
        lastAccessSequence: [UUID: UInt64],
        loadedTabBudget requestedBudget: Int,
        pressure: PDFMemoryPressureLevel = .normal
    ) -> [UUID] {
        let loaded = inputs.filter(\.isLoaded)
        let candidates = loaded.filter {
            !$0.isActive && !$0.isProtected && $0.canHibernate
        }
        guard !candidates.isEmpty else { return [] }

        let releaseCount: Int
        switch pressure {
        case .normal:
            let budget = PDFTabMemorySettings.normalizedBudget(requestedBudget)
            releaseCount = max(0, loaded.count - budget)
        case .warning:
            // A warning asks us to shed at least half of the recreatable
            // inactive working set, while retaining the active document.
            releaseCount = max(1, (candidates.count + 1) / 2)
        case .critical:
            // Dirty/OCR/visible tabs were filtered above. Everything else is
            // recreatable and should be released immediately.
            releaseCount = candidates.count
        }

        guard releaseCount > 0 else { return [] }
        return candidates.sorted { lhs, rhs in
            let lhsSequence = lastAccessSequence[lhs.id] ?? 0
            let rhsSequence = lastAccessSequence[rhs.id] ?? 0
            if lhsSequence == rhsSequence {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhsSequence < rhsSequence
        }
        .prefix(releaseCount)
        .map(\.id)
    }
}

struct PDFTabMemoryMetrics: Equatable {
    var loadedDocumentCount = 0
    var hibernatedDocumentCount = 0
    var pinnedDocumentCount = 0
    var cumulativeHibernations = 0
    var cumulativeResumes = 0
    var lastHibernationDuration: TimeInterval = 0
    var lastResumeDuration: TimeInterval = 0
    var lastPressureLevel: PDFMemoryPressureLevel = .normal
}

protocol PDFMemoryPressureMonitoring: AnyObject {
    func start(handler: @escaping (PDFMemoryPressureLevel) -> Void)
    func stop()
}

protocol PDFTabMemoryCleanupToken: AnyObject {
    func cancel()
}

protocol PDFTabMemoryCleanupScheduling {
    @MainActor
    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any PDFTabMemoryCleanupToken
}

struct RunLoopPDFTabMemoryCleanupScheduler: PDFTabMemoryCleanupScheduling {
    @MainActor
    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any PDFTabMemoryCleanupToken {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        // Releasing a PDFKit graph can be expensive. Default mode lets active
        // scroll/resize tracking finish before this discretionary cleanup.
        RunLoop.main.add(timer, forMode: .default)
        return RunLoopPDFTabMemoryCleanupToken(timer: timer)
    }
}

private final class RunLoopPDFTabMemoryCleanupToken: PDFTabMemoryCleanupToken {
    private var timer: Timer?

    init(timer: Timer) { self.timer = timer }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }
}

/// Darwin's dispatch memory-pressure source is the platform signal Apple
/// provides for releasing recreatable cache/data at warning and critical
/// pressure. Delivery happens on the main queue because PDFKit is main-thread
/// confined in this app.
final class DispatchPDFMemoryPressureMonitor: PDFMemoryPressureMonitoring {
    private var source: DispatchSourceMemoryPressure?
    private var handler: ((PDFMemoryPressureLevel) -> Void)?

    func start(handler: @escaping (PDFMemoryPressureLevel) -> Void) {
        guard source == nil else { return }
        self.handler = handler
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let event = self.source?.data else { return }
            if event.contains(.critical) {
                self.handler?(.critical)
            } else if event.contains(.warning) {
                self.handler?(.warning)
            }
        }
        source.setCancelHandler { [weak self] in
            self?.handler = nil
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        handler = nil
    }

    deinit {
        source?.cancel()
    }
}

@MainActor
final class PDFTabMemoryManager: ObservableObject {
    @Published private(set) var metrics = PDFTabMemoryMetrics()
    @Published private(set) var loadedTabBudget: Int

    private weak var workspace: MultiDocumentWorkspaceState?
    private let policy: PDFTabMemoryPolicy
    private let pressureMonitor: any PDFMemoryPressureMonitoring
    private let cleanupScheduler: any PDFTabMemoryCleanupScheduling
    private let uptime: () -> TimeInterval
    private var accessSequence: UInt64 = 0
    private var lastAccessSequence: [UUID: UInt64] = [:]
    private var protectedTabIDs: Set<UUID> = []
    private var cleanupToken: (any PDFTabMemoryCleanupToken)?
    private var cleanupGeneration: UUID?

    init(
        workspace: MultiDocumentWorkspaceState,
        loadedTabBudget: Int = UserDefaults.standard.integer(
            forKey: PDFTabMemorySettings.loadedTabBudgetKey
        ),
        policy: PDFTabMemoryPolicy = PDFTabMemoryPolicy(),
        pressureMonitor: any PDFMemoryPressureMonitoring = DispatchPDFMemoryPressureMonitor(),
        cleanupScheduler: any PDFTabMemoryCleanupScheduling = RunLoopPDFTabMemoryCleanupScheduler(),
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.workspace = workspace
        self.loadedTabBudget = PDFTabMemorySettings.normalizedBudget(
            loadedTabBudget == 0 ? PDFTabMemorySettings.defaultLoadedTabBudget : loadedTabBudget
        )
        self.policy = policy
        self.pressureMonitor = pressureMonitor
        self.cleanupScheduler = cleanupScheduler
        self.uptime = uptime

        recordAccess(to: workspace.activeTabID)
        resumeActiveTabIfNeeded()
        refreshMetrics()
        pressureMonitor.start { [weak self] level in
            Task { @MainActor [weak self] in
                self?.handleMemoryPressure(level)
            }
        }
        enforceBudget()
    }

    deinit {
        cleanupToken?.cancel()
        pressureMonitor.stop()
    }

    func updateLoadedTabBudget(_ budget: Int) {
        loadedTabBudget = PDFTabMemorySettings.normalizedBudget(budget)
        enforceBudget()
    }

    func activeTabDidChange() {
        recordAccess(to: workspace?.activeTabID)
        resumeActiveTabIfNeeded()
        enforceBudget()
    }

    func workspaceContentsDidChange() {
        guard let workspace else { return }
        let validIDs = Set(workspace.allTabs.map(\.id))
        lastAccessSequence = lastAccessSequence.filter { validIDs.contains($0.key) }
        protectedTabIDs.formIntersection(validIDs)
        recordAccess(to: workspace.activeTabID)
        resumeActiveTabIfNeeded()
        enforceBudget()
    }

    /// Comparison panes are simultaneously visible, so they are treated as
    /// active until comparison mode exits.
    func setProtectedTabIDs(_ ids: Set<UUID>, deferCleanup: Bool = false) {
        cancelDeferredCleanup()
        protectedTabIDs = ids
        guard let workspace else { return }
        for session in workspace.allTabs where ids.contains(session.id) {
            resume(session)
            recordAccess(to: session.id)
        }
        if deferCleanup {
            // A removed/replaced pane must detach its PDFView before its
            // document becomes eligible for hibernation.
            let generation = UUID()
            cleanupGeneration = generation
            scheduleCleanupSlice(after: 0.2, generation: generation)
            refreshMetrics()
        } else {
            enforceBudget()
        }
    }

    /// Let comparison PDFViews dismantle and the normal reader restore its
    /// viewport before releasing their documents. Subsequent budget/eligibility
    /// notifications join this pass instead of doing the same work inline.
    func releaseComparisonProtectionAfterTransition() {
        protectedTabIDs.removeAll()
        guard cleanupGeneration == nil else { return }
        let generation = UUID()
        cleanupGeneration = generation
        scheduleCleanupSlice(after: 0.2, generation: generation)
    }

    func handleMemoryPressure(_ level: PDFMemoryPressureLevel) {
        guard level != .normal else {
            enforceBudget()
            return
        }
        // Real memory pressure takes precedence over transition smoothness.
        cancelDeferredCleanup()
        enforce(pressure: level)
    }

    func enforceBudget() {
        guard cleanupGeneration == nil else {
            refreshMetrics()
            return
        }
        enforce(pressure: .normal)
    }

    private func scheduleCleanupSlice(after delay: TimeInterval, generation: UUID) {
        cleanupToken = cleanupScheduler.schedule(after: delay) { [weak self] in
            guard let self, self.cleanupGeneration == generation else { return }
            self.cleanupToken = nil
            // Recompute candidates every time: a tab may have become active,
            // dirty, protected, or closed since the previous slice.
            let hasMoreCandidates = self.enforce(pressure: .normal, maximumAttempts: 1)
            guard self.cleanupGeneration == generation else { return }
            if hasMoreCandidates {
                self.scheduleCleanupSlice(after: 0.05, generation: generation)
            } else {
                self.cleanupGeneration = nil
            }
        }
    }

    private func cancelDeferredCleanup() {
        cleanupGeneration = nil
        cleanupToken?.cancel()
        cleanupToken = nil
    }

    @discardableResult
    private func enforce(pressure: PDFMemoryPressureLevel, maximumAttempts: Int = .max) -> Bool {
        guard let workspace else { return false }
        let sessions = workspace.allTabs
        let activeID = workspace.activeTabID
        let inputs = sessions.map { session in
            PDFTabMemoryPolicyInput(
                id: session.id,
                isLoaded: session.workspace.document != nil,
                isActive: session.id == activeID,
                isProtected: protectedTabIDs.contains(session.id),
                canHibernate: session.workspace.canHibernate
            )
        }
        let candidateIDs = policy.hibernationCandidates(
            inputs: inputs,
            lastAccessSequence: lastAccessSequence,
            loadedTabBudget: loadedTabBudget,
            pressure: pressure
        )
        let sessionByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let startedAt = uptime()
        var releasedCount = 0
        for id in candidateIDs.prefix(maximumAttempts) {
            if sessionByID[id]?.workspace.hibernateIfPossible() == true {
                releasedCount += 1
            }
        }
        if releasedCount > 0 {
            metrics.cumulativeHibernations += releasedCount
            metrics.lastHibernationDuration = max(0, uptime() - startedAt)
        }
        metrics.lastPressureLevel = pressure
        refreshMetrics()
        return candidateIDs.count > maximumAttempts
    }

    private func resumeActiveTabIfNeeded() {
        guard let session = workspace?.activeSession else { return }
        resume(session)
    }

    private func resume(_ session: PDFTabSession) {
        guard session.workspace.isHibernated else { return }
        let startedAt = uptime()
        if session.workspace.resumeIfNeeded() {
            metrics.cumulativeResumes += 1
            metrics.lastResumeDuration = max(0, uptime() - startedAt)
        }
        refreshMetrics()
    }

    private func recordAccess(to id: UUID?) {
        guard let id else { return }
        accessSequence &+= 1
        lastAccessSequence[id] = accessSequence
    }

    private func refreshMetrics() {
        guard let workspace else { return }
        let states = workspace.allTabs.map(\.workspace)
        metrics.loadedDocumentCount = states.count { $0.document != nil }
        metrics.hibernatedDocumentCount = states.count { $0.isHibernated }
        metrics.pinnedDocumentCount = states.count {
            $0.document != nil && !$0.canHibernate
        }
    }
}
