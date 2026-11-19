// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import HwattakPDF

@MainActor
final class PluginScriptStorageTests: XCTestCase {
    func testCompareAndSetCreatesValueAndRejectsStaleWriterWithoutOverwriting() throws {
        try withStorage { store in
            XCTAssertTrue(try store.compareAndSet(expected: NSNull(), value: ["visits": 1], identifier: "org.example.trail"))
            XCTAssertFalse(try store.compareAndSet(expected: NSNull(), value: ["visits": 99], identifier: "org.example.trail"))
            XCTAssertEqual((try store.get(identifier: "org.example.trail") as? [String: Int])?["visits"], 1)
            XCTAssertTrue(try store.compareAndSet(expected: ["visits": 1], value: ["visits": 2], identifier: "org.example.trail"))
            XCTAssertFalse(try store.compareAndSet(expected: ["visits": 1], value: ["visits": 100], identifier: "org.example.trail"))
            XCTAssertEqual((try store.get(identifier: "org.example.trail") as? [String: Int])?["visits"], 2)
        }
    }

    func testComparisonUsesJSONValuesAndNamespacesRemainIndependent() throws {
        try withStorage { store in
            try store.set(["a": 1, "b": [true, false]] as [String: Any], identifier: "org.example.one")
            XCTAssertTrue(try store.compareAndSet(expected: ["b": [true, false], "a": 1] as [String: Any],
                value: "updated", identifier: "org.example.one"))
            XCTAssertTrue(try store.compareAndSet(expected: NSNull(), value: ["a": 1], identifier: "org.example.two"))
            XCTAssertEqual(try store.get(identifier: "org.example.one") as? String, "updated")
            XCTAssertEqual((try store.get(identifier: "org.example.two") as? [String: Int])?["a"], 1)
            try store.set(true, identifier: "org.example.bool")
            XCTAssertFalse(try store.compareAndSet(expected: 1, value: false, identifier: "org.example.bool"))
            XCTAssertEqual(try store.get(identifier: "org.example.bool") as? Bool, true)
        }
    }

    func testOversizedOrNonJSONReplacementPreservesExistingValue() throws {
        try withStorage { store in
            try store.set("keep", identifier: "org.example.limit")
            XCTAssertThrowsError(try store.compareAndSet(expected: "keep", value: String(repeating: "x", count: 65 * 1_024), identifier: "org.example.limit"))
            XCTAssertThrowsError(try store.compareAndSet(expected: String(repeating: "x", count: 65 * 1_024), value: "small", identifier: "org.example.limit"))
            XCTAssertThrowsError(try store.compareAndSet(expected: "keep", value: Double.infinity, identifier: "org.example.limit"))
            XCTAssertEqual(try store.get(identifier: "org.example.limit") as? String, "keep")
        }
    }

    func testIndependentMainActorWindowsRetryConflictsWithoutLosingVisits() async throws {
        let suite = "EmberPDF.StorageCAS.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PluginScriptStorage(defaults: defaults)
        try store.set([Int](), identifier: "org.example.shared")
        let tasks = (0..<8).map { window in
            Task { @MainActor in
                for _ in 0..<8 {
                    let before = try store.get(identifier: "org.example.shared")
                    let visits = try XCTUnwrap(before as? [Int])
                    // Separate workers can read the same old value before either
                    // arrives at the native conditional-write boundary.
                    await Task.yield()
                    if try store.compareAndSet(expected: before, value: visits + [window], identifier: "org.example.shared") {
                        return true
                    }
                }
                return false
            }
        }
        for task in tasks {
            let saved = try await task.value
            XCTAssertTrue(saved)
        }
        let visits = try XCTUnwrap(store.get(identifier: "org.example.shared") as? [Int])
        XCTAssertEqual(visits.count, 8)
        XCTAssertEqual(Set(visits), Set(0..<8))
    }

    private func withStorage(_ body: (PluginScriptStorage) throws -> Void) throws {
        let suite = "EmberPDF.StorageCAS.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(PluginScriptStorage(defaults: defaults))
    }
}
