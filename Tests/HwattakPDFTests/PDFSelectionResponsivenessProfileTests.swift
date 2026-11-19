// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import Darwin
import PDFKit
import QuartzCore
import SwiftUI
import XCTest
@testable import HwattakPDF

/// Opt-in end-to-end host profiling; run alone in an unsandboxed macOS session.
/// EMBER_SELECTION_TEST_PDF: explicitly supplied Katz PDF, read only.
/// EMBER_SELECTION_PROFILE_REPORT: absolute JSON output path.
/// EMBER_SELECTION_PROFILE_LABEL: comparison label, e.g. before/after.
/// EMBER_SELECTION_PROFILE_HOST=viewer selects a minimal PDFKitViewer host;
/// the default hosts WorkspaceView with its real toolbar and page sidebar.
/// EMBER_SELECTION_PROFILE_HZ: requested event cadence, 30...240 Hz; default 120.
/// EMBER_SELECTION_PROFILE_THEME: reading theme (e.g. soft/original); default original.
/// Bitmap verification runs only before/after the timed drag. This measures
/// event dispatch and compositor submission, not physical display refresh.
final class PDFSelectionResponsivenessProfileTests: XCTestCase {
    private enum Failure: Error { case unexpectedWrite }

    @MainActor
    func testChangingCharacterDragThroughRenderedSwiftUIWorkspace() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["EMBER_SELECTION_TEST_PDF"], path.hasPrefix("/"),
              let output = environment["EMBER_SELECTION_PROFILE_REPORT"], output.hasPrefix("/") else {
            throw XCTSkip("Selection profiling requires EMBER_SELECTION_TEST_PDF and EMBER_SELECTION_PROFILE_REPORT.")
        }
        let requestedHertz = Double(environment["EMBER_SELECTION_PROFILE_HZ"] ?? "120") ?? 120
        let eventHertz = requestedHertz.isFinite ? min(240, max(30, requestedHertz)) : 120
        let frameInterval = 1 / eventHertz
        _ = NSApplication.shared
        var memorySamples = [memorySample(phase: "beforeOpen")]
        let sourceURL = URL(fileURLWithPath: path)
        let sourceVersion = try PDFSourceFileVersion.capture(at: sourceURL)
        let workspace = PDFWorkspaceState(pdfWriter: { _, _, _ in throw Failure.unexpectedWrite })
        XCTAssertTrue(workspace.open(url: sourceURL))
        workspace.pageColumns = 1
        workspace.setCurrentPage(966)
        workspace.setMode(.viewer)
        workspace.activeTool = .select
        workspace.sidebarVisible = true
        let document = try XCTUnwrap(workspace.document)
        let page = try XCTUnwrap(document.page(at: 966))
        let originalText = page.string
        let originalRevision = workspace.revision
        let originalAnnotations = page.annotations.count
        memorySamples.append(memorySample(phase: "documentLoaded"))
        let multi = MultiDocumentWorkspaceState(initialWorkspace: workspace)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let defaultsName = "EmberPDF-SelectionProfile-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let readingTheme = PDFReadingTheme(rawValue: environment["EMBER_SELECTION_PROFILE_THEME"] ?? "original")
            ?? .original
        defaults.set(readingTheme.rawValue, forKey: PDFReadingTheme.defaultsKey)
        defaults.set(PDFPageNavigationMode.verticalScroll.rawValue, forKey: PDFPageNavigationMode.defaultsKey)
        let ai = AIProviderSettingsStore(configurationStore: UserDefaultsAIProviderConfigurationStore(defaults: defaults),
                                        keyStore: InMemorySecureAIAPIKeyStore())
        let plugins = PluginManager(pluginsDirectory: temporary.appendingPathComponent("Plugins"),
                                    defaults: defaults, bundledPluginsDirectory: nil)
        let minimalHost = environment["EMBER_SELECTION_PROFILE_HOST"] == "viewer"
        let root: AnyView
        if minimalHost {
            root = AnyView(PDFKitViewer(workspace: workspace).defaultAppStorage(defaults))
        } else {
            root = AnyView(WorkspaceView(multiDocumentWorkspace: multi, openDocument: {}, recentDocuments: [],
                openRecentDocument: { _ in }, removeRecentDocument: { _ in }, clearRecentDocuments: {})
                .environmentObject(workspace).environmentObject(ai).environmentObject(plugins)
                .defaultAppStorage(defaults))
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 30, y: 30, width: 1_440, height: 1_050),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let previousKeyWindow = NSApp.keyWindow
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        var view: InteractivePDFView?
        defer {
            view?.regionSelection.cancel()
            view?.prepareInlineTextEditingOverlayForRemoval()
            view?.prepareAnnotationEditingOverlayForRemoval()
            view?.workspaceState = nil
            host.rootView = AnyView(EmptyView())
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            previousKeyWindow?.makeKey()
            multi.freezeSessionPersistenceAfterFlushing()
            workspace.closeDiscardingChanges()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: temporary)
        }
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            if let mounted = findPDFView(in: host), mounted.document === document,
               mounted.visiblePages.contains(where: { $0 === page }) {
                view = mounted
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let pdfView = try XCTUnwrap(view, "The real representable must mount the requested page.")
        // A width-fitted book page extends below this window. Keep the actual
        // paragraph visible so synthetic events exercise the on-screen canvas
        // and the PNG verifies highlight presentation, not just model updates.
        pdfView.go(to: CGRect(x: 196, y: 120, width: 350, height: 95), on: page)
        // Render and let thumbnail/layout work settle before measuring the
        // first gesture. Idle geometry preparation may have completed by then.
        try await Task.sleep(nanoseconds: 400_000_000)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        _ = try raster(host)
        try await Task.sleep(nanoseconds: 100_000_000)
        let visibleParagraph = pdfView.convert(CGRect(x: 260, y: 130, width: 280, height: 70), from: page)
        XCTAssertTrue(pdfView.visibleRect.contains(visibleParagraph),
                      "The whole selected paragraph must be visible during the real-host workload.")
        let beforeImage = try snapshot(host)

        let counters = Counters()
        let changeObserver = workspace.objectWillChange.sink { counters.workspaceChanges += 1 }
        let statusObserver = workspace.$statusMessage.dropFirst().sink { _ in counters.statusPublications += 1 }
        let parentObserver = multi.objectWillChange.sink { counters.parentChanges += 1 }
        defer { changeObserver.cancel(); statusObserver.cancel(); parentObserver.cancel() }
        let anchor = CGPoint(x: 272.5, y: 193)
        let rows: [(CGFloat, CGFloat, CGFloat)] = [
            (272.5, 539, 193), (260.5, 539, 181.5), (260.5, 539, 170),
            (260.5, 539, 158.5), (260.5, 539, 147), (260.5, 329, 135)
        ]
        let endpoints = rows.flatMap { left, right, y in
            (1...20).map { step in CGPoint(x: left + (right - left) * CGFloat(step) / 20, y: y) }
        }
        XCTAssertTrue(pdfView.visibleRect.contains(pdfView.convert(anchor, from: page)))
        XCTAssertTrue(endpoints.allSatisfy { pdfView.visibleRect.contains(pdfView.convert($0, from: page)) },
                      "All drag endpoints must be inside the actual on-screen PDF viewport.")
        // Resolve the overlay once: walking the entire view hierarchy on every
        // pointer event would itself distort measurements of complex PDF pages.
        let selectionOverlay = descendants(of: pdfView).first {
            String(describing: type(of: $0)).contains("PDFRegionSelectionOverlay")
        }
        memorySamples.append(memorySample(phase: "beforeDrag"))
        let down = try mouse(.leftMouseDown, point: anchor, view: pdfView, page: page)
        let coldStarted = ProcessInfo.processInfo.systemUptime
        pdfView.mouseDown(with: down)
        let coldMouseDownSeconds = ProcessInfo.processInfo.systemUptime - coldStarted
        var frames: [[String: Any]] = []
        var liveTextChanges = 0
        var localIdentityChanges = 0
        var workspaceIdentityChanges = 0
        var dirtyOverlayFrames = 0
        var previousText = ""
        var previousLocal: PDFSelection?
        var previousPublished: PDFSelection? = workspace.currentSelection
        let dragStarted = ProcessInfo.processInfo.systemUptime
        var priorFrameStart = dragStarted
        let publicationsAfterDown = counters.workspaceChanges
        let statusesAfterDown = counters.statusPublications

        for (index, endpoint) in endpoints.enumerated() {
            // Every endpoint crosses a character boundary and each event gets
            // its own display interval. This cannot be satisfied by queuing 500
            // identical points inside a single coalesced frame.
            let due = priorFrameStart + frameInterval
            let delay = due - ProcessInfo.processInfo.systemUptime
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let conversionStarted = ProcessInfo.processInfo.systemUptime
            let event = try mouse(.leftMouseDragged, point: endpoint, view: pdfView, page: page)
            let frameStart = ProcessInfo.processInfo.systemUptime
            let eventConversionSeconds = frameStart - conversionStarted
            let interval = frameStart - priorFrameStart
            priorFrameStart = frameStart
            let beforePublications = counters.workspaceChanges
            pdfView.mouseDragged(with: event)
            let dispatchSeconds = ProcessInfo.processInfo.systemUptime - frameStart
            let dirty = selectionOverlay?.needsDisplay ?? false
            if dirty { dirtyOverlayFrames += 1 }
            let queueStarted = ProcessInfo.processInfo.systemUptime
            await drainMainQueue()
            let layoutStarted = ProcessInfo.processInfo.systemUptime
            let queueSeconds = layoutStarted - queueStarted
            host.layoutSubtreeIfNeeded()
            let displayStarted = ProcessInfo.processInfo.systemUptime
            let layoutSeconds = displayStarted - layoutStarted
            host.displayIfNeeded()
            let flushStarted = ProcessInfo.processInfo.systemUptime
            let displaySeconds = flushStarted - displayStarted
            CATransaction.flush()
            let modelStarted = ProcessInfo.processInfo.systemUptime
            let flushSeconds = modelStarted - flushStarted
            let settleSeconds = modelStarted - frameStart
            let local = pdfView.regionSelection.selection
            let text = local?.string ?? ""
            if text != previousText { liveTextChanges += 1 }
            if local !== previousLocal { localIdentityChanges += 1 }
            if workspace.currentSelection !== previousPublished { workspaceIdentityChanges += 1 }
            previousText = text
            previousLocal = local
            previousPublished = workspace.currentSelection
            let modelInspectionSeconds = ProcessInfo.processInfo.systemUptime - modelStarted
            frames.append([
                "index": index,
                "intervalSeconds": interval,
                "scheduledLatenessSeconds": max(0, frameStart - due),
                "eventConversionSeconds": eventConversionSeconds,
                "dispatchSeconds": dispatchSeconds,
                "mainQueueDrainSeconds": queueSeconds,
                "layoutOnlySeconds": layoutSeconds,
                "displayOnlySeconds": displaySeconds,
                "transactionFlushSeconds": flushSeconds,
                "modelInspectionSeconds": modelInspectionSeconds,
                "mainQueueLayoutDisplaySeconds": settleSeconds,
                "layoutDisplayOnlySeconds": layoutSeconds + displaySeconds,
                "forcedRasterSeconds": 0,
                "workspacePublications": counters.workspaceChanges - beforePublications,
                "localSelectionCharacterCount": text.count,
                "overlayWasDirty": dirty
            ])
        }
        let dragWorkloadSeconds = ProcessInfo.processInfo.systemUptime - dragStarted
        memorySamples.append(memorySample(phase: "afterDragBeforeMouseUp"))
        let publicationsDuringDrag = counters.workspaceChanges - publicationsAfterDown
        let statusesDuringDrag = counters.statusPublications - statusesAfterDown
        let publicationsBeforeUp = counters.workspaceChanges
        let statusesBeforeUp = counters.statusPublications
        let up = try mouse(.leftMouseUp, point: try XCTUnwrap(endpoints.last), view: pdfView, page: page)
        let upStarted = ProcessInfo.processInfo.systemUptime
        pdfView.mouseUp(with: up)
        await drainMainQueue()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        let mouseUpSeconds = ProcessInfo.processInfo.systemUptime - upStarted
        memorySamples.append(memorySample(phase: "afterMouseUpBeforeBitmap"))
        let afterImage = try snapshot(host)
        let paragraphInHost = host.convert(pdfView.convert(
            CGRect(x: 260, y: 130, width: 280, height: 70), from: page), from: pdfView)
        let highlightedPixels = changedPixelCount(beforeImage, afterImage,
            in: paragraphInHost, view: host)
        let figureLabelInHost = host.convert(pdfView.convert(
            CGRect(x: 196, y: 146, width: 48, height: 23), from: page), from: pdfView)
        let changedFigureLabelPixels = changedPixelCount(beforeImage, afterImage,
            in: figureLabelInHost, view: host)
        let selectionCommitPublications = counters.workspaceChanges - publicationsBeforeUp
            - (counters.statusPublications - statusesBeforeUp)
        let committed = try XCTUnwrap(workspace.currentSelection)
        XCTAssertTrue(committed.string?.contains("The other complication") == true)
        XCTAssertTrue(committed.string?.contains("kilometers daily.") == true)
        XCTAssertFalse(committed.string?.contains("Geographic") ?? true)
        XCTAssertGreaterThan(liveTextChanges, 100, "At least 100 frames must select different visible text.")
        XCTAssertGreaterThan(localIdentityChanges, 100, "The workload must perform real changing-character selection.")
        XCTAssertEqual(publicationsDuringDrag, 0, "Live dragging must not trigger whole-workspace observation.")
        XCTAssertEqual(statusesDuringDrag, 0)
        XCTAssertEqual(selectionCommitPublications, 1)
        XCTAssertGreaterThan(highlightedPixels, 200,
                             "The rendered host must visibly highlight the paragraph, not only update its selection model.")
        XCTAssertLessThan(changedFigureLabelPixels, 10,
                          "The neighboring diagram label must remain visually unselected.")
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(workspace.revision, originalRevision)
        XCTAssertEqual(page.string, originalText)
        XCTAssertEqual(page.annotations.count, originalAnnotations)
        XCTAssertEqual(try PDFSourceFileVersion.capture(at: sourceURL), sourceVersion)

        let report: [String: Any] = [
            "schemaVersion": 2,
            "label": environment["EMBER_SELECTION_PROFILE_LABEL"] ?? "unspecified",
            "host": minimalHost ? "PDFKitViewer" : "WorkspaceView with toolbar and page sidebar",
            "pageIndex": 966,
            "readingTheme": readingTheme.rawValue,
            "paragraphWasScrolledIntoView": true,
            "frameCount": endpoints.count,
            "requestedFrameIntervalSeconds": frameInterval,
            "requestedEventsPerSecond": eventHertz,
            "dragWorkloadSeconds": dragWorkloadSeconds,
            "achievedEventsPerSecond": Double(endpoints.count) / dragWorkloadSeconds,
            "timedDragBitmapRasterCount": 0,
            "framesOverRequestedInterval": frames.filter {
                ($0["mainQueueLayoutDisplaySeconds"] as? Double ?? 0) > frameInterval
            }.count,
            "timingSummariesSeconds": timingSummaries(frames),
            "memorySamples": memorySamples,
            "coldMouseDownSeconds": coldMouseDownSeconds,
            "firstGestureMayUseIdleGeometryPreparation": true,
            "mouseUpCommitAndDisplaySeconds": mouseUpSeconds,
            "workspacePublicationsDuringDrag": publicationsDuringDrag,
            "workspaceSelectionPublicationsAtCommit": selectionCommitPublications,
            "statusPublicationsDuringDrag": statusesDuringDrag,
            "workspacePublicationsTotal": counters.workspaceChanges,
            "multiDocumentPublicationsTotal": counters.parentChanges,
            "workspaceSelectionIdentityChangesDuringDrag": workspaceIdentityChanges,
            "localSelectionIdentityChangesDuringDrag": localIdentityChanges,
            "liveTextChanges": liveTextChanges,
            "framesSamplingDirtySelectionOverlay": dirtyOverlayFrames,
            "changedParagraphPixelsAfterSelection": highlightedPixels,
            "changedNeighboringLabelPixelsAfterSelection": changedFigureLabelPixels,
            "frames": frames,
            "limitations": [
                "AppKit/SwiftUI test-owned visible host, not a PDF Expert comparison or physical input-to-photon measurement.",
                "The first gesture occurs after the host settles and may use idle-prepared geometry; coldMouseDownSeconds retains its historical field name.",
                "Dirty-overlay frames are sampled flags, not a count of every invalidation or draw call.",
                "No forced bitmap rasterization occurs during the timed drag; before/after images verify highlight pixels separately.",
                "CATransaction.flush measures compositor submission, not input-to-photon latency or physical display frame completion.",
                "Task.sleep and main-queue drains can add scheduling jitter; per-stage timings and achieved event cadence are reported.",
                "Memory samples cover this test process, including the document, UI, PDFKit caches and verification bitmaps; they do not prove a leak.",
                "No PDF save, rewrite, OCR application, network, user-keychain, or installed-plugin access."
            ]
        ]
        let reportURL = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let imagePrefix = reportURL.deletingPathExtension()
        try XCTUnwrap(beforeImage.representation(using: .png, properties: [:]))
            .write(to: imagePrefix.appendingPathExtension("before.png"), options: .atomic)
        try XCTUnwrap(afterImage.representation(using: .png, properties: [:]))
            .write(to: imagePrefix.appendingPathExtension("after.png"), options: .atomic)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: reportURL, options: .atomic)
        print("EMBER_SELECTION_RENDERED_PROFILE frames=\(endpoints.count) requested_hz=\(eventHertz) achieved_hz=\(Double(endpoints.count) / dragWorkloadSeconds) text_changes=\(liveTextChanges) workspace_publications=\(publicationsDuringDrag) status_publications=\(statusesDuringDrag) cold_mouse_down_seconds=\(coldMouseDownSeconds)")
        host.rootView = AnyView(EmptyView())
        await drainMainQueue()
    }

    private func timingSummaries(_ frames: [[String: Any]]) -> [String: [String: Double]] {
        let keys = ["intervalSeconds", "scheduledLatenessSeconds", "eventConversionSeconds",
                    "dispatchSeconds", "mainQueueDrainSeconds", "layoutOnlySeconds", "displayOnlySeconds",
                    "transactionFlushSeconds", "modelInspectionSeconds", "mainQueueLayoutDisplaySeconds"]
        return Dictionary(uniqueKeysWithValues: keys.map { key in
            let values = frames.compactMap { $0[key] as? Double }.sorted()
            guard !values.isEmpty else { return (key, [:]) }
            func percentile(_ fraction: Double) -> Double {
                values[min(values.count - 1, Int(Double(values.count - 1) * fraction))]
            }
            return (key, ["minimum": values[0], "median": percentile(0.5), "p95": percentile(0.95),
                          "p99": percentile(0.99), "maximum": values[values.count - 1],
                          "mean": values.reduce(0, +) / Double(values.count)])
        })
    }

    private func memorySample(phase: String) -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        var sample: [String: Any] = ["phase": phase, "uptimeSeconds": started]
        // Reuse the app's task_info RSS and process CPU counter reader.
        if let counters = try? SystemProcessResourceCountersReader().readCounters() {
            sample["residentMemoryBytes"] = counters.residentMemoryBytes
            sample["cumulativeCPUSeconds"] = counters.cumulativeCPUTime
        }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS { sample["physicalFootprintBytes"] = UInt64(info.phys_footprint) }
        else { sample["taskInfoError"] = result }
        sample["samplingSeconds"] = ProcessInfo.processInfo.systemUptime - started
        return sample
    }

    @MainActor private final class Counters {
        var workspaceChanges = 0
        var statusPublications = 0
        var parentChanges = 0
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, point: CGPoint,
                       view: InteractivePDFView, page: PDFPage) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type,
            location: view.convert(view.convert(point, from: page), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @MainActor
    private func drainMainQueue() async {
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @MainActor
    private func raster(_ view: NSView) throws -> TimeInterval {
        let started = ProcessInfo.processInfo.systemUptime
        try autoreleasepool {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        }
        return ProcessInfo.processInfo.systemUptime - started
    }

    @MainActor
    private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
        CATransaction.flush()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    @MainActor
    private func changedPixelCount(_ before: NSBitmapImageRep, _ after: NSBitmapImageRep,
                                   in region: CGRect, view: NSView) -> Int {
        guard before.pixelsWide == after.pixelsWide, before.pixelsHigh == after.pixelsHigh,
              view.bounds.width > 0, view.bounds.height > 0 else { return 0 }
        let scaleX = CGFloat(after.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(after.pixelsHigh) / view.bounds.height
        let clipped = region.intersection(view.bounds)
        guard !clipped.isNull else { return 0 }
        let minX = max(0, Int((clipped.minX - view.bounds.minX) * scaleX))
        let maxX = min(after.pixelsWide, Int((clipped.maxX - view.bounds.minX) * scaleX))
        let top = view.isFlipped ? clipped.minY - view.bounds.minY : view.bounds.maxY - clipped.maxY
        let minY = max(0, Int(top * scaleY))
        let maxY = min(after.pixelsHigh, Int((top + clipped.height) * scaleY))
        var changed = 0
        for y in stride(from: minY, to: maxY, by: 2) {
            for x in stride(from: minX, to: maxX, by: 2) {
                guard let first = before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let last = after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(first.redComponent - last.redComponent)
                    + abs(first.greenComponent - last.greenComponent)
                    + abs(first.blueComponent - last.blueComponent) > 0.08 {
                    changed += 1
                }
            }
        }
        return changed
    }

    @MainActor
    private func findPDFView(in view: NSView) -> InteractivePDFView? {
        if let pdfView = view as? InteractivePDFView { return pdfView }
        return view.subviews.lazy.compactMap { self.findPDFView(in: $0) }.first
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
