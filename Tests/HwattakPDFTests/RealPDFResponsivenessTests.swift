// SPDX-License-Identifier: MPL-2.0

import AppKit
import Darwin
import PDFKit
import SwiftUI
import XCTest
@testable import HwattakPDF

/// Opt-in native rendering/teardown measurements. Uses only the first three
/// explicitly supplied files, never discovers files or persists document edits.
/// EMBER_PERF_MANIFEST: [{"path":"/…", "bytes":123}], at most 30 entries.
/// EMBER_PERF_REPORT: absolute output JSON path (private paths/text are omitted).
/// Native drawing in a nonactivating test window is the default. The legacy
/// hidden-window cacheDisplay diagnostic is opt-in via
/// EMBER_PERF_RENDER_MODE=offscreen-raster and is not a native frame-rate test.
/// Each phase/operation is also flushed to <report>.events.jsonl so a trap
/// cannot erase the last completed boundary.
/// Always use an external process timeout: synchronous PDFKit cannot be cancelled.
final class RealPDFResponsivenessTests: XCTestCase {
    private struct Fixture: Decodable {
        let path: String
        let bytes: UInt64
        var url: URL { URL(fileURLWithPath: path) }
    }
    private struct Stamp: Equatable { let bytes: UInt64; let modified: Date }
    private enum Failure: Error {
        case unexpectedWrite, unreadable, deadline, renderFailed, sourceChanged
        case invalidRenderMode, nativeViewNotVisible
    }

    @MainActor
    func testNativeLargePDFResponsivenessAndRelease() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifest = environment["EMBER_PERF_MANIFEST"], manifest.hasPrefix("/") else {
            throw XCTSkip("Local native performance coverage is opt-in via EMBER_PERF_MANIFEST.")
        }
        guard let reportPath = environment["EMBER_PERF_REPORT"], reportPath.hasPrefix("/") else {
            XCTFail("EMBER_PERF_REPORT must be an absolute path.")
            return
        }
        if let pidPath = environment["EMBER_PERF_PID_FILE"], pidPath.hasPrefix("/") {
            try String(ProcessInfo.processInfo.processIdentifier)
                .write(to: URL(fileURLWithPath: pidPath), atomically: true, encoding: .utf8)
        }
        let supplied = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        guard (3...30).contains(supplied.count), Set(supplied.map(\.path)).count == supplied.count else {
            XCTFail("Supply 3...30 distinct, explicitly selected PDFs.")
            return
        }
        let fixtures = Array(supplied.prefix(3))
        let sourceStamps = try fixtures.map { try stamp($0.url) }
        for (index, fixture) in fixtures.enumerated() {
            XCTAssertEqual(sourceStamps[index].bytes, fixture.bytes, "Manifest size must match its source.")
            let descriptor = try CoreGraphicsPDFLazyDocumentInspector().inspect(fixture.url)
            guard !descriptor.isEncrypted, descriptor.pageCount > 2 else { throw Failure.unreadable }
        }

        guard let renderMode = NativePerformanceRenderMode(
            rawValue: environment["EMBER_PERF_RENDER_MODE"] ?? "native-display"
        ) else { throw Failure.invalidRenderMode }
        let recorder = try NativePerformanceRecorder(reportURL: URL(fileURLWithPath: reportPath),
                                                     renderMode: renderMode)
        defer { recorder.stopAndWrite() }
        guard PDFNativeRenderingAvailability.current.isAvailable else {
            recorder.failure = "native_rendering_unavailable"
            recorder.phase("native_rendering_preflight_failed")
            XCTFail("Native PDFKit rendering requires IOSurface creation and locking. Run this opt-in test in a normal-permission macOS graphical session.")
            return
        }
        let application = NSApplication.shared
        let previousActivationPolicy = application.activationPolicy()
        if renderMode == .nativeDisplay { application.setActivationPolicy(.accessory) }
        defer { application.setActivationPolicy(previousActivationPolicy) }
        recorder.inputBytes = fixtures.reduce(0) { $0 + $1.bytes }
        recorder.start()
        let window = NativePerformanceWindow(contentRect: CGRect(x: 0, y: 0, width: 1_560, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if renderMode == .nativeDisplay {
            window.title = "EmberPDF Native Performance"
            window.animationBehavior = .none
            window.center()
            // Display this test's window without activating this process or
            // taking keyboard focus from the user's current application.
            window.orderFrontRegardless()
        }
        let content = try XCTUnwrap(window.contentView)
        var states: [PDFWorkspaceState] = []
        var allWeakViews: [NativeWeakObject] = []
        var weakStates: [NativeWeakObject] = []
        var weakDocuments: [NativeWeakObject] = []
        defer {
            content.subviews.forEach { $0.removeFromSuperview() }
            window.contentView = nil
            window.close()
            states.forEach { $0.closeDiscardingChanges() }
        }

        do {
            recorder.phase("idle_empty_baseline")
            try await idle(seconds: 10, recorder: recorder)
            recorder.phase("open_documents")
            for fixture in fixtures {
                try checkDeadline(recorder)
                let began = recorder.uptime
                let state = autoreleasepool {
                    PDFWorkspaceState(pdfWriter: { _, _, _ in throw Failure.unexpectedWrite },
                                      passwordProvider: { _, _ in nil })
                }
                guard state.open(url: fixture.url) else { throw Failure.unreadable }
                // The normal-view workload is one-page reading. Multi-column
                // overview is a different product view and is tested separately.
                state.pageColumns = 1
                state.setCurrentPage(min(state.pageCount / 2, state.pageCount - 2))
                states.append(state)
                weakStates.append(NativeWeakObject(state))
                if let document = state.document { weakDocuments.append(NativeWeakObject(document)) }
                recorder.duration("document_open", began: began)
                recorder.documentPages.append(state.pageCount)
                await settle([])
            }

            recorder.phase("normal_tab_switches_before")
            allWeakViews += try await normalSwitches(states, content: content, recorder: recorder)
            recorder.phase("idle_documents_loaded")
            try await idle(seconds: 5, recorder: recorder)

            for cycle in 0..<8 {
                try checkDeadline(recorder)
                let cycleWeak = try await comparisonCycle(states, cycle: cycle, content: content, recorder: recorder)
                allWeakViews += cycleWeak
                recorder.phase("comparison_\(cycle + 1)_released")
                try await idle(seconds: 0.5, recorder: recorder)
                recorder.releaseCounts.append(.init(cycle: cycle + 1,
                    objectsCreated: cycleWeak.count, objectsStillAlive: cycleWeak.filter { $0.value != nil }.count,
                    totalObjectsCreated: allWeakViews.count,
                    totalObjectsStillAlive: allWeakViews.filter { $0.value != nil }.count))
                states.forEach { XCTAssertFalse($0.isDirty, "Rendering and panning must never modify the PDF.") }
            }

            recorder.phase("normal_tab_switches_after")
            allWeakViews += try await normalSwitches(states, content: content, recorder: recorder)
            recorder.phase("close_documents")
            let closeBegan = recorder.uptime
            autoreleasepool {
                states.forEach { $0.closeDiscardingChanges() }
                states.removeAll()
            }
            recorder.duration("close_all_documents", began: closeBegan)
            await settle([])
            recorder.phase("idle_after_close")
            try await idle(seconds: 10, recorder: recorder)
            recorder.finalLiveViews = allWeakViews.filter { $0.value != nil }.count
            recorder.finalLiveStates = weakStates.filter { $0.value != nil }.count
            recorder.finalLiveDocuments = weakDocuments.filter { $0.value != nil }.count
            recorder.createdViewObjects = allWeakViews.count
            XCTAssertEqual(recorder.finalLiveViews, 0, "Native/hosting views should be released after removal and idle.")
            XCTAssertEqual(recorder.finalLiveStates, 0, "Document workspace states should be released after closing.")
            XCTAssertEqual(recorder.finalLiveDocuments, 0, "PDFDocument objects should be released after closing.")
            for (index, fixture) in fixtures.enumerated() {
                guard try stamp(fixture.url) == sourceStamps[index] else { throw Failure.sourceChanged }
            }
            recorder.sourceMetadataUnchanged = true
            recorder.completed = true
            recorder.phase("finished")
        } catch {
            // Error types only: Foundation error descriptions may contain paths.
            recorder.failure = String(describing: type(of: error))
            throw error
        }
    }

    @MainActor
    private func normalSwitches(_ states: [PDFWorkspaceState], content: NSView,
                                recorder: NativePerformanceRecorder) async throws -> [NativeWeakObject] {
        var weakObjects: [NativeWeakObject] = []
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        host.frame = content.bounds
        content.addSubview(host)
        weakObjects.append(NativeWeakObject(host))
        for index in 0..<6 {
            try checkDeadline(recorder)
            let began = recorder.uptime
            let state = states[index % states.count]
            recorder.event("view_replacement_begin", name: "normal_tab_\(index)")
            host.rootView = AnyView(PDFKitViewer(workspace: state).id(index))
            await settle([host])
            recorder.duration("normal_tab_switch_layout", began: began)
            if let view = findPDFView(in: host) { weakObjects.append(NativeWeakObject(view)) }
            else { XCTFail("A normal PDF view must be mounted.") }
            try await render(content, recorder: recorder, name: "normal_tab_raster")
            try await idle(seconds: 0.1, recorder: recorder)
        }
        let began = recorder.uptime
        recorder.event("view_teardown_begin", name: "normal_view_teardown")
        host.rootView = AnyView(EmptyView())
        await settle([host])
        host.removeFromSuperview()
        recorder.duration("normal_view_teardown", began: began)
        return weakObjects
    }

    @MainActor
    private func comparisonCycle(_ states: [PDFWorkspaceState], cycle: Int, content: NSView,
                                 recorder: NativePerformanceRecorder) async throws -> [NativeWeakObject] {
        recorder.phase("comparison_\(cycle + 1)_enter")
        let enterBegan = recorder.uptime
        let sync = PDFScrollSyncCoordinator()
        sync.enabled = true
        let ids = states.map { _ in UUID() }
        let hosts = states.enumerated().map { index, state in
            NSHostingView(rootView: AnyView(PDFKitViewer(workspace: state,
                scrollSyncCoordinator: sync, scrollSyncID: ids[index], viewportContext: .comparison)))
        }
        for (index, host) in hosts.enumerated() {
            host.sizingOptions = []
            host.frame = CGRect(x: index * 520, y: 0, width: 520, height: 720)
            content.addSubview(host)
        }
        defer { hosts.forEach { $0.removeFromSuperview() } }
        await settle(hosts)
        recorder.duration("comparison_enter_layout", began: enterBegan)
        let views = try hosts.map { try XCTUnwrap(findPDFView(in: $0)) }
        let weakObjects = (hosts.map { NativeWeakObject($0) } + views.map { NativeWeakObject($0) })
        for view in views { XCTAssertEqual(view.displayMode, .singlePageContinuous) }
        try await render(content, recorder: recorder, name: "comparison_enter_raster")

        recorder.phase("comparison_\(cycle + 1)_resize_pan")
        for step in 0..<20 {
            try checkDeadline(recorder)
            let began = recorder.uptime
            if step.isMultiple(of: 2) {
                let width = CGFloat(340 + ((step + cycle) % 8) * 35)
                let secondWidth = (1_560 - width) / 2
                hosts[0].frame = CGRect(x: 0, y: 0, width: width, height: 720)
                hosts[1].frame = CGRect(x: width, y: 0, width: secondWidth, height: 720)
                hosts[2].frame = CGRect(x: width + secondWidth, y: 0, width: secondWidth, height: 720)
                await settle(hosts)
                recorder.duration("comparison_resize_layout", began: began)
            } else {
                if let scroll = views[0].firstDocumentScrollView() {
                    let clip = scroll.contentView
                    let direction: CGFloat = (step + cycle) % 4 == 1 ? 1 : -1
                    let proposed = clip.bounds.offsetBy(dx: 0, dy: direction * 32)
                    clip.setBoundsOrigin(clip.constrainBoundsRect(proposed).origin)
                    scroll.reflectScrolledClipView(clip)
                } else { XCTFail("A comparison pane must have a native scroll view.") }
                await settle(hosts)
                recorder.duration("comparison_pan_layout", began: began)
            }
            if step % 5 == 4 { try await render(content, recorder: recorder, name: "comparison_update_raster") }
            try await idle(seconds: 0.035, recorder: recorder)
        }
        XCTAssertTrue(sync.stepPages(by: 1, sourceID: ids[0]))
        await settle(hosts)
        recorder.phase("comparison_\(cycle + 1)_idle_visible")
        try await idle(seconds: 1, recorder: recorder)
        recorder.phase("comparison_\(cycle + 1)_exit")
        let exitBegan = recorder.uptime
        // Explicit empty roots exercise NSViewRepresentable.dismantleNSView;
        // removing an NSHostingView alone can defer retirement in SwiftUI.
        hosts.forEach { $0.rootView = AnyView(EmptyView()) }
        await settle(hosts)
        hosts.forEach { $0.removeFromSuperview() }
        recorder.duration("comparison_exit_layout", began: exitBegan)
        return weakObjects
    }

    @MainActor
    private func render(_ content: NSView, recorder: NativePerformanceRecorder, name: String) async throws {
        let began = recorder.uptime
        if recorder.renderMode == .nativeDisplay {
            let operation = name.replacingOccurrences(of: "_raster", with: "_native_display")
            recorder.event("operation_begin", name: operation)
            // Readiness is a condition, not a fixed lifetime extension. The
            // window server/PDFKit may publish visiblePages after a later
            // display cycle. Fail visibly if no real viewport becomes ready.
            let deadline = began + 5
            while true {
                try checkDeadline(recorder)
                autoreleasepool {
                    content.layoutSubtreeIfNeeded()
                    content.displayIfNeeded()
                }
                let views = findPDFViews(in: content)
                if content.window?.isVisible == true,
                   !views.isEmpty, views.allSatisfy({ !$0.visiblePages.isEmpty }) {
                    recorder.duration(operation, began: began)
                    recorder.nativeDisplayCount += 1
                    return
                }
                guard recorder.uptime < deadline else { throw Failure.nativeViewNotVisible }
                try await Task.sleep(nanoseconds: 16_000_000)
            }
        }
        recorder.event("operation_begin", name: name)
        try autoreleasepool {
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw Failure.renderFailed
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { throw Failure.renderFailed }
        }
        // Forced rasterization is recorded separately from input/layout latency.
        recorder.duration(name, began: began)
        recorder.rasterCount += 1
    }

    @MainActor
    private func settle(_ hosts: [NSView]) async {
        for _ in 0..<4 {
            autoreleasepool { hosts.forEach { $0.layoutSubtreeIfNeeded() } }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @MainActor
    private func idle(seconds: Double, recorder: NativePerformanceRecorder) async throws {
        try checkDeadline(recorder)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try checkDeadline(recorder)
    }

    private func checkDeadline(_ recorder: NativePerformanceRecorder) throws {
        guard recorder.uptime - recorder.started < 180 else { throw Failure.deadline }
    }

    @MainActor
    private func findPDFView(in view: NSView) -> InteractivePDFView? {
        if let pdf = view as? InteractivePDFView { return pdf }
        return view.subviews.lazy.compactMap { self.findPDFView(in: $0) }.first
    }

    @MainActor
    private func findPDFViews(in view: NSView) -> [InteractivePDFView] {
        if let pdf = view as? InteractivePDFView { return [pdf] }
        return view.subviews.flatMap { findPDFViews(in: $0) }
    }

    private func stamp(_ url: URL) throws -> Stamp {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let bytes = values.fileSize, let date = values.contentModificationDate else { throw Failure.unreadable }
        return Stamp(bytes: UInt64(bytes), modified: date)
    }
}

private enum NativePerformanceRenderMode: String {
    case nativeDisplay = "native-display"
    case offscreenRaster = "offscreen-raster"
}

@MainActor
private final class NativePerformanceWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class NativeWeakObject {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}

/// Only sampler internals cross queues; NSLock protects every such field.
/// There is at most one queued main-thread ping, even during a long PDF render.
private final class NativePerformanceRecorder: @unchecked Sendable {
    struct Sample: Encodable {
        let seconds: Double
        let phase: String
        let residentBytes: UInt64
        let physicalFootprintBytes: UInt64?
        let cumulativeCPUSeconds: Double
        let cpuPercent: Double?
    }
    struct Lag: Encodable { let seconds: Double; let phase: String; let milliseconds: Double }
    struct Phase: Encodable { let seconds: Double; let name: String }
    struct Duration: Encodable { let phase: String; let name: String; let seconds: Double }
    struct Release: Encodable {
        let cycle: Int
        let objectsCreated: Int
        let objectsStillAlive: Int
        let totalObjectsCreated: Int
        let totalObjectsStillAlive: Int
    }
    private struct Report: Encodable {
        let schemaVersion: Int
        let scope: String
        let buildConfiguration: String
        let logicalCPUCount: Int
        let systemMemoryBytes: UInt64
        let elapsedSeconds: Double
        let inputBytes: UInt64
        let documentPages: [Int]
        let completed: Bool
        let failure: String?
        let sourceMetadataUnchanged: Bool
        let rasterCount: Int
        let nativeDisplayCount: Int
        let renderMode: String
        let createdViewObjects: Int
        let finalLiveViews: Int
        let finalLiveStates: Int
        let finalLiveDocuments: Int
        let releaseCounts: [Release]
        let phases: [Phase]
        let operationDurations: [Duration]
        let resources: [Sample]
        let mainQueueDelay: [Lag]
    }

    let started = ProcessInfo.processInfo.systemUptime
    var uptime: Double { ProcessInfo.processInfo.systemUptime }
    var inputBytes: UInt64 = 0
    var documentPages: [Int] = []
    var releaseCounts: [Release] = []
    var rasterCount = 0
    var nativeDisplayCount = 0
    var createdViewObjects = 0
    var finalLiveViews = -1
    var finalLiveStates = -1
    var finalLiveDocuments = -1
    var sourceMetadataUnchanged = false
    var completed = false
    var failure: String?

    private let reportURL: URL
    let renderMode: NativePerformanceRenderMode
    private let eventHandle: FileHandle
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "EmberPDF.NativePerformance.Sample", qos: .utility)
    private var sampler: DispatchSourceTimer?
    private var probe: DispatchSourceTimer?
    private var active = false
    private var pingPending = false
    private var currentPhase = "starting"
    private var samples: [Sample] = []
    private var lags: [Lag] = []
    private var phases: [Phase] = []
    private var durations: [Duration] = []
    private var previousCounter: (time: Double, cpu: Double)?

    init(reportURL: URL, renderMode: NativePerformanceRenderMode) throws {
        self.reportURL = reportURL
        self.renderMode = renderMode
        let eventURL = reportURL.appendingPathExtension("events.jsonl")
        try Data().write(to: eventURL, options: .atomic)
        eventHandle = try FileHandle(forWritingTo: eventURL)
    }

    deinit { try? eventHandle.close() }

    /// Flush only anonymous boundaries; PDF text and original paths never enter
    /// the event stream. This survives an uncatchable framework trap.
    func event(_ kind: String, name: String) {
        lock.lock()
        defer { lock.unlock() }
        writeEventLocked(kind, name: name)
    }

    private func writeEventLocked(_ kind: String, name: String) {
        let record: [String: Any] = ["kind": kind, "name": name,
                                    "phase": currentPhase, "seconds": uptime - started]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        eventHandle.write(data)
        eventHandle.write(Data([10]))
        eventHandle.synchronizeFile()
    }

    func start() {
        lock.lock(); active = true; lock.unlock()
        let sampler = DispatchSource.makeTimerSource(queue: queue)
        sampler.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(10))
        sampler.setEventHandler { [weak self] in self?.sample() }
        self.sampler = sampler
        sampler.resume()
        let probe = DispatchSource.makeTimerSource(queue: queue)
        probe.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        probe.setEventHandler { [weak self] in self?.enqueueProbe() }
        self.probe = probe
        probe.resume()
    }

    func phase(_ name: String) {
        lock.lock()
        currentPhase = name
        phases.append(.init(seconds: uptime - started, name: name))
        writeEventLocked("phase", name: name)
        lock.unlock()
    }

    func duration(_ name: String, began: Double) {
        lock.lock()
        durations.append(.init(phase: currentPhase, name: name, seconds: uptime - began))
        writeEventLocked("operation_complete", name: name)
        lock.unlock()
    }

    private func enqueueProbe() {
        lock.lock()
        guard active, !pingPending else { lock.unlock(); return }
        pingPending = true
        let phase = currentPhase
        let sent = uptime
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let received = self.uptime
            self.lock.lock()
            if self.active {
                self.lags.append(.init(seconds: sent - self.started, phase: phase,
                                       milliseconds: max(0, received - sent) * 1_000))
            }
            self.pingPending = false
            self.lock.unlock()
        }
    }

    private func sample() {
        guard let counter = try? SystemProcessResourceCountersReader().readCounters() else { return }
        let time = uptime
        let footprint = physicalFootprint()
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        let cpu = previousCounter.flatMap { previous -> Double? in
            let elapsed = time - previous.time
            guard elapsed > 0 else { return nil }
            return max(0, (counter.cumulativeCPUTime - previous.cpu) / elapsed * 100)
        }
        samples.append(.init(seconds: time - started, phase: currentPhase,
                             residentBytes: counter.residentMemoryBytes, physicalFootprintBytes: footprint,
                             cumulativeCPUSeconds: counter.cumulativeCPUTime, cpuPercent: cpu))
        previousCounter = (time, counter.cumulativeCPUTime)
    }

    private func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
    }

    func stopAndWrite() {
        sample()
        lock.lock()
        active = false
        let samples = self.samples
        let lags = self.lags
        let phases = self.phases
        let durations = self.durations
        lock.unlock()
        sampler?.cancel(); probe?.cancel()
        sampler = nil; probe = nil
        let report = Report(schemaVersion: 2,
            scope: renderMode == .nativeDisplay
                ? "Three local PDFs in a visible, nonactivating test-owned NSHostingView/PDFKit window; native display submissions with visible-page readiness; not tile-completion, frame rate, or full-app input latency."
                : "Explicit diagnostic: three local PDFs in a hidden test-owned window, forced offscreen cacheDisplay; not the app's normal drawing path or frame rate.",
            buildConfiguration: _isDebugAssertConfiguration() ? "debug" : "release",
            logicalCPUCount: ProcessInfo.processInfo.activeProcessorCount,
            systemMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            elapsedSeconds: uptime - started, inputBytes: inputBytes, documentPages: documentPages,
            completed: completed, failure: failure, sourceMetadataUnchanged: sourceMetadataUnchanged,
            rasterCount: rasterCount, nativeDisplayCount: nativeDisplayCount, renderMode: renderMode.rawValue,
            createdViewObjects: createdViewObjects,
            finalLiveViews: finalLiveViews, finalLiveStates: finalLiveStates, finalLiveDocuments: finalLiveDocuments,
            releaseCounts: releaseCounts, phases: phases, operationDurations: durations,
            resources: samples, mainQueueDelay: lags)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        } catch {
            XCTFail("Could not write anonymous native performance report.")
        }
    }
}
