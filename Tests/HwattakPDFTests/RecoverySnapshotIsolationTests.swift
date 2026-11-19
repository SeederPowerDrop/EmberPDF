// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class RecoverySnapshotIsolationTests: XCTestCase {
    private var root: URL!
    private var previousRecoverySetting: Any?

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RecoverySnapshotIsolation-\(UUID())")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        previousRecoverySetting = UserDefaults.standard.object(forKey: PDFRecoveryStore.enabledKey)
        UserDefaults.standard.set(true, forKey: PDFRecoveryStore.enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(previousRecoverySetting, forKey: PDFRecoveryStore.enabledKey)
        try? FileManager.default.removeItem(at: root)
    }

    func testDetachedSnapshotPreservesNotesLinksAndOutlineAfterSourceMutation() async throws {
        let source = try makeDocument()
        let first = try XCTUnwrap(source.page(at: 0)), target = try XCTUnwrap(source.page(at: 1))
        let note = PDFStudyNoteAnnotation(bounds: CGRect(x: 10, y: 40, width: 90, height: 50),
            contents: "At capture", font: .systemFont(ofSize: 12),
            background: NSColor.yellow.withAlphaComponent(0.35), foreground: .black)
        first.addAnnotation(note)
        let link = PDFAnnotation(bounds: CGRect(x: 10, y: 100, width: 50, height: 20), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: target, at: CGPoint(x: 20, y: 30)))
        first.addAnnotation(link)
        let outline = PDFOutline(), child = PDFOutline()
        child.label = "Destination"
        child.destination = PDFDestination(page: target, at: CGPoint(x: 20, y: 30))
        outline.insertChild(child, at: 0)
        source.outlineRoot = outline
        let snapshot = try PDFRecoverySnapshot(capturing: source)
        note.contents = "Later source text"
        first.removeAnnotation(link)
        source.removePage(at: 1)
        let store = PDFRecoveryStore(directory: root.appendingPathComponent("Snapshot"))
        let prepared = try await PDFRecoveryBackgroundWriter.stage(snapshot, store: store, id: UUID(), displayName: "Snapshot.pdf")
        defer { store.discard(prepared) }
        XCTAssertTrue(store.records().isEmpty, "Staging must not publish a recoverable generation.")
        let saved = try XCTUnwrap(PDFDocument(url: prepared.url))
        XCTAssertEqual(saved.pageCount, 2)
        let annotations = try XCTUnwrap(saved.page(at: 0)).annotations
        let savedNote = try XCTUnwrap(annotations.first(where: { $0.type == "FreeText" }))
        XCTAssertEqual(savedNote.contents, "At capture")
        XCTAssertEqual(PDFStudyNoteStyle(annotation: savedNote).backgroundOpacity, 0.35, accuracy: 0.001)
        let savedLink = try XCTUnwrap(annotations.first(where: { $0.type == "Link" }))
        let action = try XCTUnwrap(savedLink.action as? PDFActionGoTo)
        XCTAssertTrue(action.destination.page === saved.page(at: 1))
        XCTAssertTrue(saved.outlineRoot?.child(at: 0)?.destination?.page === saved.page(at: 1))
        try store.publish(prepared)
        XCTAssertEqual(store.records().count, 1)
    }

    func testMarkedOrphanFormKeepsCanonicalFieldsInDetachedRecovery() async throws {
        let source = try makeDocument()
        let page = try XCTUnwrap(source.page(at: 0))
        let field = PDFAnnotation(bounds: CGRect(x: 10, y: 30, width: 95, height: 25), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "recovery-student"
        field.widgetStringValue = "At capture"
        field.font = NSFont(name: "Helvetica", size: 12)
        page.addAnnotation(field)
        PDFCanonicalFormMaterializer.mark(source)
        let snapshot = try PDFRecoverySnapshot(capturing: source)
        field.widgetStringValue = "Later source value"
        let store = PDFRecoveryStore(directory: root.appendingPathComponent("CanonicalForm"))
        let prepared = try await PDFRecoveryBackgroundWriter.stage(snapshot, store: store, id: UUID(), displayName: "Form.pdf")
        defer { store.discard(prepared) }
        let native = try XCTUnwrap(CGPDFDocument(prepared.url as CFURL))
        let catalog = try XCTUnwrap(native.catalog)
        var form: CGPDFDictionaryRef?, fields: CGPDFArrayRef?, savedField: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form))
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(form), "Fields", &fields))
        XCTAssertEqual(CGPDFArrayGetCount(try XCTUnwrap(fields)), 1)
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(fields), 0, &savedField))
        var name: CGPDFStringRef?, value: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(savedField), "T", &name))
        XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(savedField), "V", &value))
        XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(try XCTUnwrap(name))) as String, "recovery-student")
        XCTAssertEqual(try XCTUnwrap(CGPDFStringCopyTextString(try XCTUnwrap(value))) as String, "At capture")
        XCTAssertEqual(field.widgetStringValue, "Later source value")
    }

    func testCustomStampCopiesRetainAppearanceAfterSourceRemoval() async throws {
        var source: PDFDocument? = try makeDocument()
        let page = try XCTUnwrap(source?.page(at: 0))
        let image = NSImage(size: CGSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let stamp = ImageStampAnnotation(image: image, bounds: CGRect(x: 10, y: 20, width: 20, height: 20))
        stamp.contents = "Image"
        let mark = StudyMarkupAnnotation(bounds: CGRect(x: 50, y: 20, width: 30, height: 20),
            style: StudyMarkupStyle(kind: .highlight, color: .green, opacity: 0.4))
        mark.contents = "Mark"
        page.addAnnotation(stamp); page.addAnnotation(mark)
        let snapshot = try PDFRecoverySnapshot(capturing: XCTUnwrap(source))
        stamp.updateCropRect(CGRect(x: 0, y: 0, width: 0.5, height: 1))
        page.removeAnnotation(stamp); page.removeAnnotation(mark)
        source = nil
        let store = PDFRecoveryStore(directory: root.appendingPathComponent("Appearance"))
        let prepared = try await PDFRecoveryBackgroundWriter.stage(snapshot, store: store, id: UUID(), displayName: "Appearance.pdf")
        defer { store.discard(prepared) }
        let saved = try XCTUnwrap(PDFDocument(url: prepared.url))
        let savedPage = try XCTUnwrap(saved.page(at: 0))
        XCTAssertEqual(savedPage.annotations.count, 2)
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 180, bitsPerComponent: 8,
            bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        savedPage.draw(with: .cropBox, to: context)
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let red = 150 * 480 + 20 * 4, green = 150 * 480 + 60 * 4
        XCTAssertGreaterThan(pixels[red], 220)
        XCTAssertLessThan(pixels[red + 1], 30)
        XCTAssertGreaterThan(Int(pixels[green + 1]), Int(pixels[green]) + 30)
    }

    func testCancelledWorkerCannotPublishAndDeletesItsUnpublishedPDF() async throws {
        let gate = RecoveryWriterGate()
        let store = PDFRecoveryStore(directory: root.appendingPathComponent("Cancelled"), beforeStaging: { gate.wait() })
        let snapshot = try PDFRecoverySnapshot(capturing: makeDocument())
        let task = Task { try await PDFRecoveryBackgroundWriter.stage(snapshot, store: store, id: UUID(), displayName: "Cancelled.pdf") }
        defer { gate.release() }
        try await waitUntil { gate.isWaiting }
        task.cancel()
        gate.release()
        do { _ = try await task.value; XCTFail("Cancelled staging should throw.") }
        catch is CancellationError { }
        XCTAssertTrue(store.records().isEmpty)
        XCTAssertTrue(pdfFiles(in: store.directory).isEmpty)
    }

    func testLateWorkerAfterCloseCannotResurrectRecovery() async throws {
        try await checkLateWorker(.close)
    }

    func testLateWorkerAfterSaveCannotResurrectRecovery() async throws {
        try await checkLateWorker(.save)
    }

    func testLateWorkerAfterDisablingRecoveryCannotPublish() async throws {
        try await checkLateWorker(.disable)
    }

    func testSnapshotIsSingleUseAndRejectsEncryptedOrEmptyDocuments() async throws {
        XCTAssertThrowsError(try PDFRecoverySnapshot(capturing: PDFDocument()))
        let source = try makeDocument()
        let protectedURL = root.appendingPathComponent("Protected.pdf")
        XCTAssertTrue(source.write(to: protectedURL, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "reader"]))
        let encrypted = try XCTUnwrap(PDFDocument(url: protectedURL))
        XCTAssertTrue(encrypted.unlock(withPassword: "owner"))
        XCTAssertThrowsError(try PDFRecoverySnapshot(capturing: encrypted))
        let snapshot = try PDFRecoverySnapshot(capturing: source)
        let store = PDFRecoveryStore(directory: root.appendingPathComponent("SingleUse"))
        let first = try await PDFRecoveryBackgroundWriter.stage(snapshot, store: store, id: UUID(), displayName: "First.pdf")
        defer { store.discard(first) }
        do {
            _ = try await PDFRecoveryBackgroundWriter.stage(snapshot, store: store, id: UUID(), displayName: "Second.pdf")
            XCTFail("A snapshot must transfer its PDF graph only once.")
        } catch { }
    }

    private enum LateAction { case close, save, disable }

    private func checkLateWorker(_ action: LateAction) async throws {
        let gate = RecoveryWriterGate()
        let store = PDFRecoveryStore(directory: root.appendingPathComponent("Late"), beforeStaging: { gate.wait() })
        let sourceURL = root.appendingPathComponent("Source.pdf")
        XCTAssertTrue(try makeDocument().write(to: sourceURL))
        let workspace = PDFWorkspaceState()
        defer { gate.release(); workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: sourceURL))
        workspace.configureRecovery(store: store)
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        try await waitUntil(timeout: 8) { gate.isWaiting }
        // Waiting for this background semaphore leaves MainActor available;
        // a synchronous recovery writer would deadlock this operation.
        XCTAssertTrue(store.records().isEmpty)
        switch action {
        case .close: workspace.closeDiscardingChanges()
        case .save: XCTAssertTrue(workspace.saveSynchronously())
        case .disable: UserDefaults.standard.set(false, forKey: PDFRecoveryStore.enabledKey)
        }
        gate.release()
        try await waitUntil { gate.hasReturned }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(store.records().isEmpty)
        XCTAssertTrue(pdfFiles(in: store.directory).isEmpty)
    }

    private func makeDocument() throws -> PDFDocument {
        let url = root.appendingPathComponent("\(UUID()).pdf")
        var bounds = CGRect(x: 0, y: 0, width: 120, height: 180)
        let writer = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for _ in 0..<2 {
            writer.beginPDFPage(nil)
            writer.setFillColor(NSColor.white.cgColor)
            writer.fill(bounds)
            writer.endPDFPage()
        }
        writer.closePDF()
        return try XCTUnwrap(PDFDocument(url: url))
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "Timed out waiting for recovery staging.")
    }

    private func pdfFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "pdf" }
    }
}

private final class RecoveryWriterGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var waiting = false
    private var returned = false
    var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    var hasReturned: Bool { lock.lock(); defer { lock.unlock() }; return returned }
    func wait() {
        lock.lock(); waiting = true; lock.unlock()
        _ = semaphore.wait(timeout: .now() + 15)
        lock.lock(); returned = true; lock.unlock()
    }
    func release() { semaphore.signal() }
}
