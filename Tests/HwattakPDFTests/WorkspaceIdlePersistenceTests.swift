// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

/// Real debounce timing with an entirely memory-backed session store. No PDF,
/// user preference, bookmark, or Application Support file is read or written.
final class WorkspaceIdlePersistenceTests: XCTestCase {
    @MainActor
    func testExplicitFlushDoesNotScheduleAnotherSaveWhileIdle() async throws {
        let (workspace, persistence) = makeWorkspace(title: "Idle workspace")
        defer { workspace.freezeSessionPersistenceAfterFlushing() }

        XCTAssertFalse(try XCTUnwrap(workspace.activeWorkspace).isDirty)
        XCTAssertTrue(workspace.flushSessionPersistence())
        let writesAfterFlush = persistence.writeCount
        XCTAssertEqual(writesAfterFlush, 1)

        // More than three 650 ms debounce periods: a flush that re-arms itself
        // must be detected even though the user made no further changes.
        try await Task.sleep(for: .milliseconds(2_200))

        XCTAssertEqual(persistence.writeCount, writesAfterFlush,
                       "Saving the workspace projection must not schedule itself again.")
    }

    @MainActor
    func testRealWorkspaceChangeSavesAfterDebounceThenStopsWriting() async throws {
        let (workspace, persistence) = makeWorkspace(title: "Before")
        defer { workspace.freezeSessionPersistenceAfterFlushing() }
        XCTAssertTrue(workspace.flushSessionPersistence())
        let baseline = persistence.writeCount

        XCTAssertTrue(workspace.renameWorkspace(workspace.activeWorkspaceID, to: "After"))
        XCTAssertEqual(persistence.writeCount, baseline, "Changes should remain debounced.")
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while persistence.writeCount == baseline, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(persistence.writeCount, baseline + 1,
                       "A real change must still reach the session store.")
        let archive = try JSONDecoder().decode(WorkspaceSessionArchive.self,
                                              from: XCTUnwrap(persistence.data))
        XCTAssertEqual(archive.workspaces.first?.title, "After")
        let writesAfterChange = persistence.writeCount

        try await Task.sleep(for: .milliseconds(2_200))

        XCTAssertEqual(persistence.writeCount, writesAfterChange,
                       "The debounced save must stop after recording the change.")
    }

    @MainActor
    func testIncludingAnotherWindowDoesNotRearmEitherWindowPersistence() async throws {
        let (main, mainPersistence) = makeWorkspace(title: "Main")
        let (detached, detachedPersistence) = makeWorkspace(title: "Detached")
        defer {
            main.freezeSessionPersistenceAfterFlushing()
            detached.freezeSessionPersistenceAfterFlushing()
        }
        XCTAssertTrue(detached.flushSessionPersistence())
        XCTAssertTrue(main.flushSessionPersistence(including: [detached]))
        let mainWrites = mainPersistence.writeCount
        let detachedWrites = detachedPersistence.writeCount
        let archive = try JSONDecoder().decode(WorkspaceSessionArchive.self,
                                              from: XCTUnwrap(mainPersistence.data))
        XCTAssertEqual(Set(archive.workspaces.map(\.title)), ["Main", "Detached"])

        try await Task.sleep(for: .milliseconds(2_200))

        XCTAssertEqual(mainPersistence.writeCount, mainWrites,
                       "Capturing a second window must not keep the main archive writing.")
        XCTAssertEqual(detachedPersistence.writeCount, detachedWrites,
                       "Projection synchronization must not start a background save in that window.")
    }

    @MainActor
    private func makeWorkspace(title: String) -> (MultiDocumentWorkspaceState, IdleSessionPersistence) {
        let persistence = IdleSessionPersistence()
        let store = WorkspaceSessionStore(persistence: persistence,
                                          bookmarkCoder: UnusedIdleBookmarkCoder())
        let workspace = MultiDocumentWorkspaceState(initialWorkspace: PDFWorkspaceState(),
                                                    initialWorkspaceTitle: title,
                                                    sessionStore: store)
        return (workspace, persistence)
    }
}

private final class IdleSessionPersistence: WorkspaceSessionDataPersisting {
    private(set) var data: Data?
    private(set) var writeCount = 0

    func read() throws -> Data? { data }

    func write(_ data: Data) throws {
        self.data = data
        writeCount += 1
    }
}

private struct UnusedIdleBookmarkCoder: WorkspaceSessionBookmarkCoding {
    private struct UnexpectedBookmark: Error {}

    func makeBookmark(for url: URL) throws -> Data { throw UnexpectedBookmark() }
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        throw UnexpectedBookmark()
    }
}
