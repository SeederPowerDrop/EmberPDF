// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class InkPresetStoreTests: XCTestCase {
    func testFavoritesPersistAllToolOptionsAndRemainIndependentOfCurrentSettings() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = InkPresetStore(defaults: defaults)
        var settings = InkSettings()
        settings.selectStyle(.highlighter)
        settings.width = 18; settings.opacity = 0.55; settings.pressureEnabled = false
        settings.color = NSColor(deviceRed: 0.1, green: 0.2, blue: 0.8, alpha: 0.4)
        settings.drawingOptions = PDFInkDrawingOptions(shape: .rectangle, pattern: .dashed, highlighterTip: .round)
        XCTAssertTrue(store.add(settings))
        let saved = try XCTUnwrap(store.presets.last)
        XCTAssertTrue(saved.snapshot.matches(settings))
        XCTAssertEqual(saved.snapshot.settings.pdfInkColor.alphaComponent, 0.55, accuracy: 0.001)
        settings.width = 3
        let restored = InkPresetStore(defaults: defaults)
        XCTAssertEqual(restored.presets.last?.id, saved.id)
        XCTAssertEqual(restored.presets.last?.snapshot.width, 18)
        XCTAssertEqual(restored.presets.last?.snapshot.drawingOptions, saved.snapshot.drawingOptions)
        restored.replace(saved.id, with: settings)
        XCTAssertEqual(InkPresetStore(defaults: defaults).presets.last?.snapshot.width, 3)
        restored.remove(saved.id)
        XCTAssertFalse(InkPresetStore(defaults: defaults).presets.contains { $0.id == saved.id })
    }

    func testLimitsInvalidValuesAndEmptyListSurviveReload() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = InkPresetStore(defaults: defaults)
        while store.presets.count < InkPresetStore.maximumPresets { XCTAssertTrue(store.add(InkSettings())) }
        XCTAssertFalse(store.add(InkSettings()))
        for id in store.presets.map(\.id) { store.remove(id) }
        XCTAssertTrue(InkPresetStore(defaults: defaults).presets.isEmpty)
        var invalid = InkSettings(); invalid.width = .infinity
        XCTAssertFalse(store.add(invalid))
        defaults.set(Data(repeating: 1, count: 40_000), forKey: InkPresetStore.defaultsKey)
        XCTAssertEqual(InkPresetStore(defaults: defaults).presets.count, 4)
    }

    func testPresetSelectionRespectsModeAndDoesNotEditThePDF() throws {
        let (defaults, name) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preset = try XCTUnwrap(InkPresetStore(defaults: defaults).presets.last)
        let state = PDFWorkspaceState()
        XCTAssertFalse(state.useInkPreset(preset))
        let data = NSMutableData()
        var rect = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &rect, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preset-\(UUID()).pdf")
        try (data as Data).write(to: url)
        defer { state.closeDiscardingChanges(); try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(state.open(url: url))
        XCTAssertFalse(state.useInkPreset(preset))
        state.setMode(.editing)
        XCTAssertTrue(state.useInkPreset(preset))
        XCTAssertEqual(state.activeTool, .pen)
        XCTAssertTrue(preset.snapshot.matches(state.inkSettings))
        XCTAssertFalse(state.isDirty)
        XCTAssertTrue(try XCTUnwrap(state.document?.page(at: 0)).annotations.isEmpty)
        state.pageColumns = 3
        XCTAssertFalse(state.useInkPreset(preset))
        state.pageColumns = 1
        state.setMode(.study)
        XCTAssertTrue(state.useInkPreset(preset))
        XCTAssertFalse(state.isDirty)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "InkPresetTests-\(UUID())"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }
}
