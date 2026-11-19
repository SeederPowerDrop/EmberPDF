// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit

/// A document-independent scroll position that can be mapped between PDF views
/// with different page sizes, zoom factors, and viewport dimensions.
struct PDFScrollProgress: Equatable {
    var horizontal: CGFloat
    var vertical: CGFloat

    init(horizontal: CGFloat, vertical: CGFloat) {
        self.horizontal = Self.clamped(horizontal)
        self.vertical = Self.clamped(vertical)
    }

    static func progress(
        boundsOrigin: CGPoint,
        documentFrame: CGRect,
        viewportSize: CGSize
    ) -> PDFScrollProgress {
        let minimumX = documentFrame.minX
        let minimumY = documentFrame.minY
        let horizontalRange = max(0, documentFrame.width - viewportSize.width)
        let verticalRange = max(0, documentFrame.height - viewportSize.height)

        return PDFScrollProgress(
            horizontal: normalized(
                value: boundsOrigin.x,
                minimum: minimumX,
                range: horizontalRange
            ),
            vertical: normalized(
                value: boundsOrigin.y,
                minimum: minimumY,
                range: verticalRange
            )
        )
    }

    func boundsOrigin(
        documentFrame: CGRect,
        viewportSize: CGSize
    ) -> CGPoint {
        let horizontalRange = max(0, documentFrame.width - viewportSize.width)
        let verticalRange = max(0, documentFrame.height - viewportSize.height)
        return CGPoint(
            x: documentFrame.minX + horizontal * horizontalRange,
            y: documentFrame.minY + vertical * verticalRange
        )
    }

    private static func normalized(
        value: CGFloat,
        minimum: CGFloat,
        range: CGFloat
    ) -> CGFloat {
        guard range > 0 else { return 0 }
        return clamped((value - minimum) / range)
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

/// A relative pan measured in rendered page widths/heights. Keeping deltas
/// independent of total document length preserves the pages the reader aligned.
struct PDFComparisonScrollDelta: Equatable {
    var horizontal: CGFloat
    var vertical: CGFloat

    init(originChange: CGPoint, pageSize: CGSize, isFlipped: Bool) {
        horizontal = Self.normalized(originChange.x, by: pageSize.width)
        vertical = Self.normalized(originChange.y, by: pageSize.height) * (isFlipped ? 1 : -1)
    }

    func applying(to origin: CGPoint, pageSize: CGSize, isFlipped: Bool) -> CGPoint {
        CGPoint(
            x: origin.x + horizontal * max(0, pageSize.width),
            y: origin.y + vertical * max(0, pageSize.height) * (isFlipped ? 1 : -1)
        )
    }

    private static func normalized(_ value: CGFloat, by extent: CGFloat) -> CGFloat {
        guard value.isFinite, extent.isFinite, extent > 0 else { return 0 }
        return value / extent
    }
}

/// Keeps each document's starting page/position while sharing subsequent pans.
/// Fixed panels neither drive nor follow the group and keep their reading position.
@MainActor
final class PDFScrollSyncCoordinator: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            refreshAllBaselines()
        }
    }

    private struct Snapshot {
        var origin: CGPoint
        var viewportSize: CGSize
        var documentFrame: CGRect
        var pageSize: CGSize
        var scale: CGFloat
        var documentID: ObjectIdentifier
        var pageCount: Int
        var isFlipped: Bool

        func hasSameGeometry(as other: Snapshot) -> Bool {
            documentID == other.documentID && pageCount == other.pageCount
                && Self.nearlyEqual(viewportSize.width, other.viewportSize.width)
                && Self.nearlyEqual(viewportSize.height, other.viewportSize.height)
                && Self.nearlyEqual(documentFrame.width, other.documentFrame.width)
                && Self.nearlyEqual(documentFrame.height, other.documentFrame.height)
                && Self.nearlyEqual(scale, other.scale, tolerance: 0.000001)
                && isFlipped == other.isFlipped
        }

        private static func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.01) -> Bool {
            abs(lhs - rhs) <= tolerance
        }
    }

    private struct Participant {
        weak var pdfView: PDFView?
        weak var clipView: NSClipView?
        var isLocked: Bool
        var snapshot: Snapshot?
        var boundsObserver: NSObjectProtocol?
    }

    private var participants: [UUID: Participant] = [:]
    private var applyingParticipantIDs: Set<UUID> = []
    private var programmaticUpdateDepths: [UUID: Int] = [:]
    private var programmaticUpdateStarts: [UUID: Snapshot] = [:]
    private var geometrySettlingGenerations: [UUID: UUID] = [:]

    init(enabled: Bool = true) {
        self.enabled = enabled
    }

    deinit {
        for participant in participants.values {
            if let observer = participant.boundsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    func register(pdfView: PDFView, id: UUID, locked: Bool = false) {
        let clipView = scrollView(for: pdfView)?.contentView
        if let current = participants[id], current.pdfView === pdfView, current.clipView === clipView {
            var updated = current
            updated.isLocked = locked
            // Native scroll notifications can arrive after a SwiftUI refresh.
            // Re-registering the same view must not consume its pending delta.
            if current.isLocked != locked || current.snapshot == nil {
                updated.snapshot = snapshot(for: updated)
            }
            participants[id] = updated
            clipView?.postsBoundsChangedNotifications = true
            return
        }

        unregister(id: id)
        guard let clipView else { return }
        clipView.postsBoundsChangedNotifications = true
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
        ) { [weak self, weak clipView] _ in
            guard let self, let clipView else { return }
            MainActor.assumeIsolated {
                self.clipViewBoundsChanged(id: id, clipView: clipView)
            }
        }
        var participant = Participant(
            pdfView: pdfView, clipView: clipView, isLocked: locked,
            snapshot: nil, boundsObserver: observer
        )
        participant.snapshot = snapshot(for: participant)
        participants[id] = participant
        removeReleasedParticipants()
    }

    func updateRegistration(pdfView: PDFView, id: UUID, locked: Bool) {
        register(pdfView: pdfView, id: id, locked: locked)
    }

    func unregister(id: UUID, pdfView expectedPDFView: PDFView? = nil) {
        guard let participant = participants[id] else { return }
        // A replacement can register before SwiftUI dismantles its predecessor.
        if let expectedPDFView, participant.pdfView !== expectedPDFView { return }
        participants.removeValue(forKey: id)
        if let observer = participant.boundsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        applyingParticipantIDs.remove(id)
        geometrySettlingGenerations.removeValue(forKey: id)
    }

    /// Model application, viewport restoration, and layout are not user pans.
    /// Nesting is supported because PDFKit may synchronously trigger SwiftUI work.
    func beginProgrammaticUpdate(id: UUID) {
        if programmaticUpdateDepths[id] == nil, let participant = participants[id] {
            programmaticUpdateStarts[id] = snapshot(for: participant)
        }
        programmaticUpdateDepths[id, default: 0] += 1
    }

    func endProgrammaticUpdate(id: UUID) {
        let depth = programmaticUpdateDepths[id, default: 0]
        if depth > 1 {
            programmaticUpdateDepths[id] = depth - 1
            return
        }
        programmaticUpdateDepths.removeValue(forKey: id)
        let before = programmaticUpdateStarts.removeValue(forKey: id)
        guard let participant = participants[id], let after = snapshot(for: participant) else { return }
        // Most SwiftUI updates only refresh labels after a native scroll. They
        // must leave an as-yet-undelivered clip delta intact.
        if let before, before.hasSameGeometry(as: after),
           approximatelyEqual(before.origin, after.origin) { return }
        refreshBaseline(id: id)
    }

    /// PDFKit sometimes replaces its clip or switches off bounds notifications
    /// after scaling. Its native live-scroll channel remains authoritative.
    func receiveLiveScroll(pdfView: PDFView, id: UUID, locked: Bool) {
        updateRegistration(pdfView: pdfView, id: id, locked: locked)
        guard let clip = participants[id]?.clipView else { return }
        clipViewBoundsChanged(id: id, clipView: clip)
    }

    func refreshAfterLayout(pdfView: PDFView, id: UUID, locked: Bool) {
        updateRegistration(pdfView: pdfView, id: id, locked: locked)
        refreshBaseline(id: id)
    }

    /// With a source, follows the sync switch; a fixed source cannot move.
    /// Without a source, the explicit group buttons move every non-fixed pane,
    /// including when automatic scroll synchronization is switched off.
    @discardableResult
    func stepPages(by delta: Int, sourceID: UUID? = nil) -> Bool {
        guard delta != 0 else { return false }
        removeReleasedParticipants()
        if let sourceID {
            guard let source = participants[sourceID], !source.isLocked else { return false }
        }
        let targetIDs = navigationParticipantIDs(sourceID: sourceID)
        return navigate(targetIDs: targetIDs, delta: delta)
    }

    /// A page jump applies the source's page difference to the other unlocked
    /// panes. Each PDF clamps independently at its first or last page.
    @discardableResult
    func goToPage(index: Int, sourceID: UUID) -> Bool {
        guard let source = participants[sourceID],
              let pdfView = source.pdfView, let document = pdfView.document,
              let page = Self.readingPage(in: pdfView), document.pageCount > 0 else { return false }
        let current = document.index(for: page)
        guard current != NSNotFound else { return false }
        let requested = min(max(0, index), document.pageCount - 1)
        return stepPages(by: requested - current, sourceID: sourceID)
    }

    /// A diff pairs independent page positions (an insertion can shift only
    /// one side). Suppress automatic synchronization for this explicit jump,
    /// preserve pinned panes, and leave every unrelated comparison pane alone.
    @discardableResult
    func revealComparisonDifferences(_ locations: [UUID: PDFDocumentDifferenceLocation]) -> Bool {
        removeReleasedParticipants()
        let targets: [(UUID, PDFView, PDFPage, NSRange)] = locations.compactMap { id, location in
            guard let participant = participants[id], !participant.isLocked,
                  let view = participant.pdfView, let document = view.document,
                  location.pageIndex >= 0, location.pageIndex < document.pageCount,
                  let page = document.page(at: location.pageIndex) else { return nil }
            return (id, view, page, location.range)
        }
        guard !targets.isEmpty else { return false }
        for (id, _, _, _) in targets { beginProgrammaticUpdate(id: id) }
        defer { for (id, _, _, _) in targets { endProgrammaticUpdate(id: id) } }
        for (_, view, page, range) in targets {
            if let interactive = view as? InteractivePDFView, interactive.viewportContext == .comparison {
                interactive.revealComparisonPage(page)
                interactive.onComparisonSynchronizedScroll?()
            } else { view.go(to: page) }
            // The report was revision-checked by its owner. Still validate the
            // Objective-C range boundary: malformed PDFs can disagree about
            // page.string and numberOfCharacters just as in text search.
            if range.location >= 0, range.length > 0, range.length <= 4_000, range.location <= page.numberOfCharacters,
               range.length <= page.numberOfCharacters - range.location,
               let selection = page.selection(for: range) {
                view.setCurrentSelection(selection, animate: false)
            } else { view.clearSelection() }
        }
        return true
    }

    private func navigationParticipantIDs(sourceID: UUID?) -> [UUID] {
        guard let sourceID, let source = participants[sourceID] else {
            return participants.compactMap { $0.value.isLocked ? nil : $0.key }
        }
        guard !source.isLocked else { return [] }
        guard enabled else { return [sourceID] }
        return participants.compactMap { $0.value.isLocked ? nil : $0.key }
    }

    private func navigate(targetIDs: [UUID], delta: Int) -> Bool {
        let destinations: [(UUID, PDFView, PDFPage)] = targetIDs.compactMap { id in
            guard let view = participants[id]?.pdfView, let document = view.document,
                  let currentPage = Self.readingPage(in: view), document.pageCount > 0 else { return nil }
            let current = document.index(for: currentPage)
            guard current != NSNotFound else { return nil }
            // Avoid overflow from an externally supplied page-step amount.
            let available = delta > 0 ? document.pageCount - 1 - current : current
            let change = delta > 0 ? min(delta, available) : max(delta, -available)
            guard change != 0, let page = document.page(at: current + change) else { return nil }
            return (id, view, page)
        }
        guard !destinations.isEmpty else { return false }
        for (id, _, _) in destinations { beginProgrammaticUpdate(id: id) }
        defer { for (id, _, _) in destinations { endProgrammaticUpdate(id: id) } }
        for (_, view, page) in destinations {
            if let interactive = view as? InteractivePDFView,
               interactive.viewportContext == .comparison {
                interactive.revealComparisonPage(page)
                interactive.onComparisonSynchronizedScroll?()
            } else {
                view.go(to: page)
            }
        }
        return true
    }

    private func clipViewBoundsChanged(id: UUID, clipView: NSClipView) {
        guard var source = participants[id], source.clipView === clipView else { return }
        let previous = source.snapshot
        let next = snapshot(for: source)
        // Restoring notification delivery inside a no-op SwiftUI update can
        // emit the native scroll delta that preceded that update.
        if programmaticUpdateDepths[id] != nil,
           let start = programmaticUpdateStarts[id], let next,
           start.hasSameGeometry(as: next), approximatelyEqual(start.origin, next.origin) {
            return
        }
        source.snapshot = next
        participants[id] = source
        guard !applyingParticipantIDs.contains(id), programmaticUpdateDepths[id] == nil,
              !isReflowing(source.pdfView),
              let previous, let current = source.snapshot else { return }
        guard current.hasSameGeometry(as: previous) else {
            settleGeometryChange(id: id)
            return
        }
        guard geometrySettlingGenerations[id] == nil else { return }
        if source.isLocked {
            // Also catches native scrollbar drags and selection auto-scroll,
            // whose events are handled inside PDFKit's private document view.
            if !approximatelyEqual(clipView.bounds.origin, previous.origin) {
                applyingParticipantIDs.insert(id)
                clipView.setBoundsOrigin(previous.origin)
                clipView.enclosingScrollView?.reflectScrolledClipView(clipView)
                (source.pdfView as? InteractivePDFView)?.onComparisonSynchronizedScroll?()
                refreshBaseline(id: id)
                applyingParticipantIDs.remove(id)
            }
            return
        }
        guard enabled else { return }

        let change = CGPoint(x: current.origin.x - previous.origin.x, y: current.origin.y - previous.origin.y)
        guard abs(change.x) > 0.01 || abs(change.y) > 0.01 else { return }
        let delta = PDFComparisonScrollDelta(
            originChange: change, pageSize: previous.pageSize, isFlipped: previous.isFlipped
        )
        (source.pdfView as? InteractivePDFView)?.onComparisonSynchronizedScroll?()
        removeReleasedParticipants()
        for (targetID, participant) in participants where targetID != id && !participant.isLocked {
            guard programmaticUpdateDepths[targetID] == nil,
                  geometrySettlingGenerations[targetID] == nil,
                  !isReflowing(participant.pdfView),
                  let targetClip = participant.clipView,
                  let target = snapshot(for: participant) else { continue }
            let proposed = delta.applying(to: target.origin, pageSize: target.pageSize, isFlipped: target.isFlipped)
            let constrained = targetClip.constrainBoundsRect(
                CGRect(origin: proposed, size: targetClip.bounds.size)
            ).origin
            guard !approximatelyEqual(targetClip.bounds.origin, constrained) else { continue }
            applyingParticipantIDs.insert(targetID)
            targetClip.setBoundsOrigin(constrained)
            targetClip.enclosingScrollView?.reflectScrolledClipView(targetClip)
            (participant.pdfView as? InteractivePDFView)?.onComparisonSynchronizedScroll?()
            refreshBaseline(id: targetID)
            applyingParticipantIDs.remove(targetID)
        }
    }

    /// Native currentPage may remain cached when another pane moves this
    /// clip view directly. Resolve the page from its actual displayed geometry.
    static func readingPage(in view: PDFView) -> PDFPage? {
        if let page = (view as? InteractivePDFView)?.anchoredComparisonReadingPage() { return page }
        guard view.bounds.width > 0, view.bounds.height > 0 else { return view.currentPage }
        return view.page(for: CGPoint(x: view.bounds.midX, y: view.bounds.midY), nearest: true)
            ?? view.currentPage
    }

    private func settleGeometryChange(id: UUID) {
        let generation = UUID()
        geometrySettlingGenerations[id] = generation
        // PDFKit changes scale first, then re-centres its clip in a later
        // bounds notification. Treat both as one local zoom/layout operation.
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.geometrySettlingGenerations[id] == generation else { return }
                self.geometrySettlingGenerations.removeValue(forKey: id)
                self.refreshBaseline(id: id)
            }
        }
    }

    private func isReflowing(_ view: PDFView?) -> Bool {
        guard let view = view as? InteractivePDFView else { return false }
        return view.isApplyingPageFitScale || view.pageFitUpdateScheduled
    }

    private func snapshot(for participant: Participant) -> Snapshot? {
        guard let view = participant.pdfView, let document = view.document,
              let clip = participant.clipView, let documentView = clip.documentView,
              let page = Self.readingPage(in: view), document.pageCount > 0 else { return nil }
        // Clip origins are unscaled document coordinates, whereas PDFView's
        // page conversion is in screen coordinates. Compare like units so a
        // 50% pane and a 200% pane move by the same fraction of their pages.
        let pageRectInView = view.convert(page.bounds(for: view.displayBox), from: page)
        let pageSize = documentView.convert(pageRectInView, from: view).size
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        return Snapshot(
            origin: clip.constrainBoundsRect(clip.bounds).origin,
            viewportSize: clip.bounds.size, documentFrame: documentView.frame,
            pageSize: pageSize, scale: view.scaleFactor,
            documentID: ObjectIdentifier(document), pageCount: document.pageCount,
            isFlipped: documentView.isFlipped
        )
    }

    private func refreshBaseline(id: UUID) {
        guard var participant = participants[id] else { return }
        participant.snapshot = snapshot(for: participant)
        participants[id] = participant
    }

    private func refreshAllBaselines() {
        for id in participants.keys { refreshBaseline(id: id) }
    }

    private func scrollView(for pdfView: PDFView) -> NSScrollView? {
        firstScrollView(in: pdfView) ?? pdfView.enclosingScrollView
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) { return scrollView }
        }
        return nil
    }

    private func removeReleasedParticipants() {
        let releasedIDs = participants.compactMap { id, participant in
            participant.pdfView == nil || participant.clipView == nil ? id : nil
        }
        for id in releasedIDs { unregister(id: id) }
    }

    private func approximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) < 0.25 && abs(lhs.y - rhs.y) < 0.25
    }
}
