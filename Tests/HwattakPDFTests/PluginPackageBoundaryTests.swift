// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation
import XCTest
@testable import HwattakPDF

final class PluginPackageBoundaryTests: XCTestCase {
    private var root: URL!
    private var directory: Int32 = -1

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EmberPDF-PackageBoundary-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(directory, 0)
    }

    override func tearDownWithError() throws {
        if directory >= 0 { close(directory) }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: root.appendingPathExtension("moved"))
    }

    func testPinnedDirectoryKeepsReviewedBytesAfterPathReplacement() throws {
        let reviewed = Data("reviewed bytes".utf8)
        try reviewed.write(to: root.appendingPathComponent("manifest.json"))
        let moved = root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("replacement bytes".utf8).write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try read("manifest.json", limit: 100), reviewed)
    }

    func testLeafSymlinkDirectoryAndFIFOAreRejectedAtOpenedObjectBoundary() throws {
        try Data("outside".utf8).write(to: root.appendingPathComponent("target"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "target")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertThrowsError(try read("link", limit: 100))
        XCTAssertThrowsError(try read("folder", limit: 100))
        // O_NONBLOCK prevents waiting for a writer before fstat rejects FIFO.
        XCTAssertThrowsError(try read("pipe", limit: 100))
    }

    func testBoundedReadRejectsOversizeAndPathTraversal() throws {
        let bytes = Data(repeating: 65, count: 33)
        try bytes.write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try read("manifest.json", limit: 32))
        XCTAssertEqual(try read("manifest.json", limit: 33), bytes)
        XCTAssertThrowsError(try read("../manifest.json", limit: 100))
        XCTAssertThrowsError(try read("manifest.json\0suffix", limit: 100))
        XCTAssertThrowsError(try read(".", limit: 100))
    }

    func testInstallationRecordUsesSameCapturedPackageSnapshot() throws {
        let package = root.appendingPathComponent("org.example.snapshot.hwattakplugin")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest = PluginManifest(
            schemaVersion: 1, identifier: "org.example.snapshot", displayName: "Snapshot", version: "1.0.0",
            author: "Tests", description: "Snapshot fixture", minimumHostVersion: nil, capabilities: [],
            actions: [PluginActionManifest(id: "hello", title: "Hello", description: nil, output: .showText, template: "Hello")]
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: package.appendingPathComponent("manifest.json"))
        let record = PluginInstallationRecord(schemaVersion: 1, manifestSHA256: PluginPackageValidator.sha256Hex(data), installedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let recordData = try encoder.encode(record)
        try recordData.write(to: package.appendingPathComponent("installation.json"))
        let inspected = try PluginPackageValidator(hostVersion: "1.0.0").inspectInstalledPackage(at: package)
        XCTAssertEqual(inspected.package.filePayloads["installation.json"], recordData)
        XCTAssertEqual(inspected.package.filePayloads["manifest.json"], data)
        XCTAssertEqual(inspected.package.totalBytes, data.count)
    }

    private func read(_ name: String, limit: Int) throws -> Data {
        try PluginPackageValidator.boundedRegularFileData(directoryDescriptor: directory, filename: name, maximumBytes: limit, label: name)
    }
}
