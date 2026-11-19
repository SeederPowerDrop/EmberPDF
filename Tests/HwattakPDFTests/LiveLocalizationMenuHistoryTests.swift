// SPDX-License-Identifier: MPL-2.0
import AppKit
import Foundation
import PDFKit
import XCTest
@testable import HwattakPDF

final class LiveLocalizationMenuHistoryTests: XCTestCase {
    @MainActor
    func testOwnedHistoryLabelsRelocalizeWithCountsAndLiteralNamesStayLiteral() throws {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }
        setLanguage(.korean)
        let history = PDFEditHistory(), navigation = PDFEditNavigationSnapshot(currentPageIndex: 0, selectedPages: [0])
        var value = 1
        let label = PDFEditActionLocalization(key: "status.deleted_pages", integerArguments: [23])
        history.register(actionName: label.resolve(), actionLocalization: label,
            beforeNavigation: navigation, afterNavigation: navigation, undo: { value = 0 }, redo: { value = 1 })
        history.markSaved(); let checkpoint = history.checkpoint
        let korean = history.undoActionName
        setLanguage(.english)
        XCTAssertEqual(history.undoActionName, L10n.format("status.deleted_pages", 23))
        XCTAssertNotEqual(history.undoActionName, korean)
        XCTAssertTrue(history.isAtSavedState); XCTAssertEqual(history.checkpoint, checkpoint)
        _ = try history.undo(); XCTAssertEqual(value, 0)
        XCTAssertEqual(history.redoActionName, L10n.format("status.deleted_pages", 23))
        _ = try history.redo(); XCTAssertEqual(value, 1); XCTAssertEqual(history.checkpoint, checkpoint)
        let literal = "김민수의 챕터 — user supplied"
        history.register(actionName: literal, beforeNavigation: navigation, afterNavigation: navigation, undo: {}, redo: {})
        setLanguage(.japanese); XCTAssertEqual(history.undoActionName, literal)
        _ = try history.undo()
        XCTAssertEqual(history.undoActionName, L10n.format("status.deleted_pages", 23))
        for key in ["status.body_text_updated", "status.body_text_added", "status.body_text_deleted"] {
            let body = PDFEditActionLocalization(key: key)
            XCTAssertEqual(body.resolve(), L10n.string(key))
            XCTAssertNotEqual(body.resolve(), key)
        }
    }

    @MainActor
    func testWorkspaceRefreshUpdatesHistoryPresentationWithoutChangingPagesOrCheckpointBehavior() throws {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }; setLanguage(.korean)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-localization-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = PDFDocument()
        for _ in 0..<3 { let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 100, height: 100), for: .mediaBox); document.insert(page, at: document.pageCount) }
        let url = directory.appendingPathComponent("pages.pdf"); XCTAssertTrue(document.write(to: url))
        let workspace = PDFWorkspaceState(); defer { workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: url)); workspace.setMode(.editing)
        let first = try XCTUnwrap(workspace.document?.page(at: 0))
        workspace.movePage(from: 0, before: 2)
        XCTAssertTrue(workspace.canUndo); XCTAssertTrue(workspace.isDirty)
        let korean = workspace.undoActionName, page = workspace.currentPageIndex, selected = workspace.selectedPages
        setLanguage(.english); workspace.refreshLocalization()
        XCTAssertEqual(workspace.undoActionName, L10n.string("status.pages_reordered"))
        XCTAssertNotEqual(workspace.undoActionName, korean)
        XCTAssertEqual(workspace.documentURL, url); XCTAssertEqual(workspace.pageCount, 3)
        XCTAssertEqual(workspace.currentPageIndex, page); XCTAssertEqual(workspace.selectedPages, selected)
        workspace.undo(); XCTAssertFalse(workspace.isDirty)
        XCTAssertTrue(workspace.document?.page(at: 0) === first)
        XCTAssertEqual(workspace.redoActionName, L10n.string("status.pages_reordered"))
        workspace.redo(); XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(workspace.undoActionName, L10n.string("status.pages_reordered"))
    }

    @MainActor
    func testOwnedAnnotationAdditionAndEraserLabelsRelocalizeWhileLiteralIntegrationNamesStayLiteral() throws {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }; setLanguage(.korean)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-annotation-label-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = PDFDocument(), originalPage = PDFPage()
        originalPage.setBounds(CGRect(x: 0, y: 0, width: 400, height: 500), for: .mediaBox); document.insert(originalPage, at: 0)
        let url = directory.appendingPathComponent("fixture.pdf"); XCTAssertTrue(document.write(to: url))
        let workspace = PDFWorkspaceState(); defer { workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: url)); workspace.setMode(.editing)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        workspace.requestTextEdit(pageIndex: 0, point: CGPoint(x: 40, y: 160), annotation: nil)
        workspace.commitPendingText("my own note — 漢字")
        let note = try XCTUnwrap(page.annotations.first)
        setLanguage(.english); workspace.refreshLocalization()
        XCTAssertEqual(workspace.undoActionName, L10n.string("status.text_added"))
        XCTAssertEqual(note.contents, "my own note — 漢字")
        setLanguage(.korean); page.removeAnnotation(note)
        workspace.registerEraserGesture(on: page, from: [note], to: [])
        setLanguage(.english); workspace.refreshLocalization()
        XCTAssertEqual(workspace.undoActionName, L10n.string("eraser.changed"))
        workspace.undo(); XCTAssertTrue(page.annotations.first === note)
        XCTAssertEqual(workspace.redoActionName, L10n.string("eraser.changed"))
        let literal = "status.text_added" // An integration's literal that resembles an owned key.
        let external = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .ink, withProperties: nil)
        page.addAnnotation(external); workspace.registerAddedAnnotation(external, on: page, message: literal)
        setLanguage(.japanese); workspace.refreshLocalization()
        XCTAssertEqual(workspace.undoActionName, literal)
    }

    @MainActor
    func testOwnedStudyNoteVisibilityLabelsRelocalizeWithoutChangingFlagsOrUndoSemantics() throws {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }; setLanguage(.korean)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ember-visibility-label-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = PDFDocument(), initial = PDFPage()
        initial.setBounds(CGRect(x: 0, y: 0, width: 400, height: 500), for: .mediaBox); document.insert(initial, at: 0)
        let url = directory.appendingPathComponent("fixture.pdf"); XCTAssertTrue(document.write(to: url))
        let workspace = PDFWorkspaceState(); defer { workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: url)); workspace.setMode(.study)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 120, height: 40), forType: .freeText, withProperties: nil)
        annotation.contents = "Keep this note"; annotation.shouldPrint = true; page.addAnnotation(annotation)
        let note = try XCTUnwrap(workspace.studyNotes(on: 0).first)
        XCTAssertTrue(workspace.setStudyNoteHidden(true, note: note)); XCTAssertFalse(annotation.shouldDisplay)
        setLanguage(.english); workspace.refreshLocalization()
        XCTAssertEqual(workspace.undoActionName, L10n.string("study.notes.visibility.hide"))
        XCTAssertTrue(annotation.shouldPrint); XCTAssertEqual(annotation.contents, "Keep this note")
        workspace.undo(); XCTAssertTrue(annotation.shouldDisplay)
        XCTAssertEqual(workspace.redoActionName, L10n.string("study.notes.visibility.hide"))
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    func testNativeTextUndoLabelsUseSelectedAppLanguageWithoutChangingNativeHistory() {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }
        let manager = UndoManager(), target = NSObject()
        var value = 1
        manager.registerUndo(withTarget: target) { _ in value = 0 }
        manager.setActionName("사용자 입력")
        for language in [AppLanguage.korean, .english, .arabic] {
            setLanguage(language)
            XCTAssertEqual(AppEditCommandRouter.nativeTextHistoryTitle(backwards: true), L10n.string("menu.undo"))
            XCTAssertEqual(AppEditCommandRouter.nativeTextHistoryTitle(backwards: false), L10n.string("menu.redo"))
            XCTAssertTrue(manager.canUndo); XCTAssertEqual(manager.undoActionName, "사용자 입력")
        }
        manager.undo(); XCTAssertEqual(value, 0)
    }

    @MainActor
    func testMenuRolesChangeTitlesOnlyAndKeepCustomMenusAndCommandsUnchanged() {
        let fixture = menus(), ids = fixture.main.items.map(ObjectIdentifier.init)
        let originalCommands = fixture.file.items.map { ($0.title, $0.keyEquivalent, $0.action) }
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help,
            title: { "English:" + $0 })
        XCTAssertEqual(fixture.main.items.map(ObjectIdentifier.init), ids)
        XCTAssertEqual(fixture.file.title, "English:native_menu.file")
        XCTAssertEqual(fixture.edit.title, "English:native_menu.edit")
        XCTAssertEqual(fixture.view.title, "English:native_menu.view")
        XCTAssertEqual(fixture.window.title, "English:native_menu.window")
        XCTAssertEqual(fixture.help.title, "English:native_menu.help")
        XCTAssertEqual(fixture.custom.title, "김민수 작업공간")
        for (index, item) in fixture.file.items.enumerated() {
            XCTAssertEqual(item.title, originalCommands[index].0)
            XCTAssertEqual(item.keyEquivalent, originalCommands[index].1)
            XCTAssertEqual(item.action, originalCommands[index].2)
        }
        // An ambiguous command fingerprint must never pick a custom menu.
        let duplicate = NSMenu(title: "User commands")
        for key in ["t", "o", "w", "s"] { let item = NSMenuItem(title: key, action: nil, keyEquivalent: key); item.keyEquivalentModifierMask = .command; duplicate.addItem(item) }
        let extra = NSMenuItem(title: "User commands", action: nil, keyEquivalent: ""); extra.submenu = duplicate; fixture.main.addItem(extra)
        let before = fixture.file.title
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help, title: { "New:" + $0 })
        XCTAssertEqual(fixture.file.title, before); XCTAssertEqual(duplicate.title, "User commands")
    }

    @MainActor
    func testWrappedSwiftUICommandsUsePublicKeyboardFingerprintWithoutTitleMatching() {
        let fixture = menus()
        fixture.edit.removeAllItems(); fixture.view.removeAllItems()
        for key in ["x", "c", "v", "z", "f"] {
            let item = NSMenuItem(title: "動作", action: NSSelectorFromString("wrappedCommand:"), keyEquivalent: key)
            item.keyEquivalentModifierMask = .command; fixture.edit.addItem(item)
        }
        let fullScreen = NSMenuItem(title: "動作", action: NSSelectorFromString("wrappedCommand:"), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]; fixture.view.addItem(fullScreen)
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help,
            title: { "English:" + $0 })
        XCTAssertEqual(fixture.edit.title, "English:native_menu.edit")
        XCTAssertEqual(fixture.view.title, "English:native_menu.view")
        XCTAssertEqual(fixture.edit.items.count, 5); XCTAssertEqual(fixture.custom.title, "김민수 작업공간")
        XCTAssertEqual(fullScreen.action, NSSelectorFromString("wrappedCommand:"))
    }

    @MainActor
    func testLanguageAndMenuTrackingNotificationsRefreshExistingMenuWithoutRebuildingIt() async {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }; setLanguage(.korean)
        let fixture = menus(), center = NotificationCenter()
        let controller = AppMenuLanguageController(notificationCenter: center,
            menuProvider: { (fixture.main, fixture.window, fixture.help) })
        controller.start(); XCTAssertEqual(fixture.file.title, L10n.string("native_menu.file"))
        let items = fixture.main.items.map(ObjectIdentifier.init)
        setLanguage(.english); center.post(name: .appLanguageDidChange, object: AppLanguage.english)
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(fixture.file.title, "File"); XCTAssertEqual(fixture.edit.title, "Edit")
        fixture.file.title = "파일"
        center.post(name: NSMenu.didBeginTrackingNotification, object: fixture.file)
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(fixture.file.title, "File")
        XCTAssertEqual(fixture.main.items.map(ObjectIdentifier.init), items)
        XCTAssertEqual(fixture.custom.title, "김민수 작업공간")
    }

    @MainActor
    func testAllSupportedLanguagesHaveEveryNativeRoleAndBodyActionTranslation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for language in AppLanguage.allCases {
            let url = root.appendingPathComponent("Resources/Localization/\(language.rawValue).lproj/Localizable.strings")
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            for key in ["file", "edit", "view", "window", "help", "close_all", "cut", "copy", "paste", "select_all", "show_tab_bar", "hide_tab_bar", "show_all_tabs", "exit_tab_overview", "enter_full_screen", "exit_full_screen"].map({ "native_menu." + $0 })
                + ["status.body_text_updated", "status.body_text_added", "status.body_text_deleted"] {
                XCTAssertFalse(try XCTUnwrap(table[key]).isEmpty, "\(language.rawValue):\(key)")
            }
        }
    }

    @MainActor
    func testViewerFileMenuWithoutSaveAndNativeCommandsRelocalizeWithoutChangingBehavior() {
        let fixture = menus()
        fixture.file.items.filter { $0.keyEquivalent == "s" }.forEach(fixture.file.removeItem)
        let target = NSObject()
        let close = NSMenuItem(title: "닫기", action: NSSelectorFromString("performClose:"), keyEquivalent: "w")
        close.target = target; close.keyEquivalentModifierMask = [.command, .shift]; close.isEnabled = false
        let closeAll = NSMenuItem(title: "모두 닫기", action: NSSelectorFromString("closeAll:"), keyEquivalent: "")
        fixture.file.addItem(close); fixture.file.addItem(closeAll)
        let selectAll = NSMenuItem(title: "전체 선택", action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")
        fixture.edit.addItem(selectAll)
        let customCopy = NSMenuItem(title: "My copy command", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        fixture.custom.addItem(customCopy)
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help, title: { "EN:" + $0 })
        XCTAssertEqual(fixture.file.title, "EN:native_menu.file")
        XCTAssertEqual(close.title, "EN:menu.close"); XCTAssertEqual(closeAll.title, "EN:native_menu.close_all")
        XCTAssertEqual(selectAll.title, "EN:native_menu.select_all")
        XCTAssertTrue(close.target === target); XCTAssertEqual(close.action, NSSelectorFromString("performClose:"))
        XCTAssertEqual(close.keyEquivalent, "w"); XCTAssertEqual(close.keyEquivalentModifierMask, [.command, .shift]); XCTAssertFalse(close.isEnabled)
        XCTAssertEqual(customCopy.title, "My copy command"); XCTAssertEqual(fixture.custom.title, "김민수 작업공간")
    }

    @MainActor
    func testTrackingRefreshIsSynchronousAndLateMenuRebuildIsObserved() async {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }; setLanguage(.korean)
        let fixture = menus(), center = NotificationCenter()
        let controller = AppMenuLanguageController(notificationCenter: center, menuProvider: { (fixture.main, fixture.window, fixture.help) })
        controller.start(); setLanguage(.english)
        fixture.file.title = "파일"
        center.post(name: NSMenu.didBeginTrackingNotification, object: fixture.file)
        // No yield: the title must be correct before tracking displays it.
        XCTAssertEqual(fixture.file.title, "File")
        for _ in 0..<12 { await Task.yield() }
        fixture.edit.title = "편집"
        center.post(name: NSMenu.didChangeItemNotification, object: fixture.main)
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(fixture.edit.title, "Edit")
        XCTAssertEqual(fixture.custom.title, "김민수 작업공간")
    }

    @MainActor
    func testNativeViewTabCommandsUseWindowStateAndPreserveCustomCommands() {
        let fixture = menus(), target = NSObject()
        let bar = NSMenuItem(title: "탭 막대 보기", action: NSSelectorFromString("toggleTabBar:"), keyEquivalent: "t")
        let overview = NSMenuItem(title: "모든 탭 보기", action: NSSelectorFromString("toggleTabOverview:"), keyEquivalent: "")
        bar.target = target; bar.keyEquivalentModifierMask = [.command, .shift]; bar.isEnabled = false
        fixture.view.addItem(bar); fixture.view.addItem(overview)
        let custom = NSMenuItem(title: "User tab label", action: bar.action, keyEquivalent: "")
        fixture.custom.addItem(custom)
        let ids = fixture.view.items.map(ObjectIdentifier.init)
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help,
            tabState: { _ in (false, false) }, title: { "JP:" + $0 })
        XCTAssertEqual(bar.title, "JP:native_menu.show_tab_bar")
        XCTAssertEqual(overview.title, "JP:native_menu.show_all_tabs")
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help,
            tabState: { _ in (true, true) }, title: { "EN:" + $0 })
        XCTAssertEqual(bar.title, "EN:native_menu.hide_tab_bar")
        XCTAssertEqual(overview.title, "EN:native_menu.exit_tab_overview")
        XCTAssertEqual(fixture.view.items.map(ObjectIdentifier.init), ids)
        XCTAssertTrue(bar.target === target); XCTAssertEqual(bar.action, NSSelectorFromString("toggleTabBar:"))
        XCTAssertEqual(bar.keyEquivalent, "t"); XCTAssertEqual(bar.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertFalse(bar.isEnabled); XCTAssertEqual(custom.title, "User tab label")
        let titles = fixture.view.items.map(\.title)
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help,
            tabState: { _ in nil }, title: { "EN:" + $0 })
        XCTAssertEqual(fixture.view.items.map(\.title), titles,
                       "An unresolved native responder must not guess another window's tab state.")
    }

    @MainActor
    func testRealDefaultCenterTitleSettersStayInFrenchWithoutPostedMenuNotifications() throws {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }; setLanguage(.french)
        let fixture = menus()
        let controller = AppMenuLanguageController(notificationCenter: .default,
            applicationProvider: { nil }, menuProvider: { (fixture.main, fixture.window, fixture.help) })
        controller.start(); controller.start()
        let item = try XCTUnwrap(fixture.main.items.first { $0.submenu === fixture.view })
        let commands = fixture.view.items.map { ($0.action, $0.keyEquivalent, $0.keyEquivalentModifierMask) }
        for _ in 0..<3 {
            fixture.view.title = "보기"
            XCTAssertEqual(fixture.view.title, "Présentation")
            XCTAssertEqual(item.title, "Présentation")
            item.title = "보기"
            XCTAssertEqual(item.title, "Présentation")
            XCTAssertEqual(fixture.view.title, "Présentation")
        }
        fixture.custom.title = "User-supplied title"
        XCTAssertEqual(fixture.custom.title, "User-supplied title")
        for (index, command) in fixture.view.items.enumerated() {
            XCTAssertEqual(command.action, commands[index].0)
            XCTAssertEqual(command.keyEquivalent, commands[index].1)
            XCTAssertEqual(command.keyEquivalentModifierMask, commands[index].2)
        }
    }

    @MainActor
    func testRealMainMenuSetterRebindsNativeTitleObserversAndRetiresOldMenus() throws {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        let application = NSApplication.shared
        let previousMain = application.mainMenu, previousWindows = application.windowsMenu, previousHelp = application.helpMenu
        var controller: AppMenuLanguageController?
        defer {
            controller = nil
            application.mainMenu = previousMain
            application.windowsMenu = previousWindows
            application.helpMenu = previousHelp
            restoreLanguage(previous)
        }
        setLanguage(.french)
        let first = menus(), replacement = menus()
        application.windowsMenu = first.window; application.helpMenu = first.help; application.mainMenu = first.main
        controller = AppMenuLanguageController(notificationCenter: .default, applicationProvider: { application })
        controller?.start()
        XCTAssertEqual(first.view.title, "Présentation")
        application.windowsMenu = replacement.window; application.helpMenu = replacement.help
        application.mainMenu = replacement.main
        XCTAssertEqual(replacement.view.title, "Présentation")
        let item = try XCTUnwrap(replacement.main.items.first { $0.submenu === replacement.view })
        replacement.view.title = "보기"
        XCTAssertEqual(replacement.view.title, "Présentation"); XCTAssertEqual(item.title, "Présentation")
        let nextView = NSMenu(title: "보기")
        nextView.addItem(NSMenuItem(title: "전체화면", action: NSSelectorFromString("toggleFullScreen:"), keyEquivalent: ""))
        item.submenu = nextView
        XCTAssertEqual(nextView.title, "Présentation"); XCTAssertEqual(item.title, "Présentation")
        replacement.view.title = "Retired private submenu"
        XCTAssertEqual(replacement.view.title, "Retired private submenu")
        nextView.title = "보기"
        XCTAssertEqual(nextView.title, "Présentation")
        first.view.title = "Retired private menu"
        XCTAssertEqual(first.view.title, "Retired private menu")
        XCTAssertEqual(replacement.custom.title, "김민수 작업공간")
    }

    @MainActor
    func testTitleObservationsDoNotRetainControllerOrRefreshAfterTeardown() async {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }; setLanguage(.french)
        let fixture = menus()
        var controller: AppMenuLanguageController? = AppMenuLanguageController(notificationCenter: .default,
            applicationProvider: { nil }, menuProvider: { (fixture.main, fixture.window, fixture.help) })
        weak var weakController = controller
        controller?.start()
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(fixture.view.title, "Présentation")
        controller = nil
        XCTAssertNil(weakController)
        fixture.view.title = "After controller teardown"
        XCTAssertEqual(fixture.view.title, "After controller teardown")
    }

    @MainActor
    func testOfficialWindowAndHelpFullscreenCommandsDoNotHideTheNativeViewRole() throws {
        let fixture = menus()
        for menu in [fixture.window, fixture.help] {
            menu.addItem(NSMenuItem(title: "Native command", action: NSSelectorFromString("toggleFullScreen:"), keyEquivalent: ""))
        }
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help,
                                       title: { "FR:" + $0 })
        XCTAssertEqual(fixture.view.title, "FR:native_menu.view")
        XCTAssertEqual(fixture.window.title, "FR:native_menu.window")
        XCTAssertEqual(fixture.help.title, "FR:native_menu.help")
        let payload = AppMenuLanguageController.diagnosticPayload(in: fixture.main, windows: fixture.window,
                                                                help: fixture.help, event: .itemAdded)
        XCTAssertEqual(payload["c"] as? [Int], [1, 1, 3, 1])
        let rows = try XCTUnwrap(payload["i"] as? [[Int]])
        XCTAssertEqual(rows.first(where: { $0[0] == 2 })?[3], 3)

        // An unknown second candidate remains ambiguous; official identities
        // are the only candidates removed from the View match count.
        fixture.custom.addItem(NSMenuItem(title: "User command", action: NSSelectorFromString("toggleFullScreen:"), keyEquivalent: ""))
        fixture.view.title = "Original view"; fixture.custom.title = "User title"
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help,
                                       title: { "NEXT:" + $0 })
        XCTAssertEqual(fixture.view.title, "Original view")
        XCTAssertEqual(fixture.custom.title, "User title")
        let ambiguous = AppMenuLanguageController.diagnosticPayload(in: fixture.main, windows: fixture.window,
                                                                  help: fixture.help, event: .itemChanged)
        XCTAssertEqual(ambiguous["c"] as? [Int], [1, 1, 4, 2])
        XCTAssertEqual((ambiguous["i"] as? [[Int]])?.first(where: { $0[0] == 2 })?[3], 0)
    }

    @MainActor
    func testRealMenuStructureSettersRepairViewSynchronouslyWithoutTaskYield() throws {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }; setLanguage(.french)
        let fixture = menus()
        fixture.view.removeAllItems()
        let controller = AppMenuLanguageController(notificationCenter: .default,
            applicationProvider: { nil }, menuProvider: { (fixture.main, fixture.window, fixture.help) })
        controller.start()
        XCTAssertEqual(fixture.view.title, "보기", "A missing role must not guess from its title.")
        let command = NSMenuItem(title: "Native command", action: NSSelectorFromString("wrappedCommand:"), keyEquivalent: "f")
        command.keyEquivalentModifierMask = .command
        fixture.view.addItem(command)
        XCTAssertEqual(fixture.view.title, "보기")
        // A real property setter must repair a newly complete fingerprint.
        command.keyEquivalentModifierMask = [.command, .control]
        // Real change/add/remove notifications only; no synthesized notification,
        // Task.yield or run-loop drain may make these assertions pass later.
        XCTAssertEqual(fixture.view.title, "Présentation")
        fixture.view.removeItem(command)
        fixture.view.title = "보기"
        XCTAssertEqual(fixture.view.title, "보기", "Retired role observers must not remain authoritative.")
        fixture.view.addItem(command)
        XCTAssertEqual(fixture.view.title, "Présentation")

        let duplicate = NSMenu(title: "User supplied duplicate")
        duplicate.addItem(NSMenuItem(title: "Custom", action: NSSelectorFromString("toggleFullScreen:"), keyEquivalent: ""))
        let extra = NSMenuItem(title: "User supplied duplicate", action: nil, keyEquivalent: "")
        extra.submenu = duplicate; fixture.main.addItem(extra)
        fixture.view.title = "보기"
        XCTAssertEqual(fixture.view.title, "보기")
        fixture.main.removeItem(extra)
        XCTAssertEqual(fixture.view.title, "Présentation", "Removal must repair the newly unique role immediately.")
        XCTAssertEqual(duplicate.title, "User supplied duplicate")
        XCTAssertEqual(fixture.custom.title, "김민수 작업공간")
        XCTAssertEqual(command.action, NSSelectorFromString("wrappedCommand:"))
    }

    @MainActor
    func testMenuDiagnosticsRequireTheExistingOptInAndAQAIdentity() {
        typealias Diagnostics = AppMenuLanguageController.Diagnostics
        XCTAssertFalse(Diagnostics.isEligible(environmentValue: nil, bundleIdentifier: "com.vibepdf.mac.releaseqa90r61", qaInfoValue: nil))
        XCTAssertFalse(Diagnostics.isEligible(environmentValue: "1", bundleIdentifier: "com.vibepdf.mac", qaInfoValue: true))
        XCTAssertFalse(Diagnostics.isEligible(environmentValue: "1", bundleIdentifier: nil, qaInfoValue: nil))
        XCTAssertFalse(Diagnostics.isEligible(environmentValue: nil, bundleIdentifier: "com.vibepdf.mac.releaseqa90r61", qaInfoValue: NSNumber(value: 1)))
        XCTAssertFalse(Diagnostics.isEligible(environmentValue: nil, bundleIdentifier: "com.vibepdf.mac.releaseqa90r61", qaInfoValue: "true"))
        XCTAssertFalse(Diagnostics.isEligible(environmentValue: nil, bundleIdentifier: "com.vibepdf.mac.releaseqa90r61", qaInfoValue: false))
        XCTAssertTrue(Diagnostics.isEligible(environmentValue: nil, bundleIdentifier: "com.vibepdf.mac.releaseqa90r61", qaInfoValue: true))
        XCTAssertTrue(Diagnostics.isEligible(environmentValue: "1", bundleIdentifier: "com.vibepdf.mac.releaseqa90r61", qaInfoValue: nil))
        XCTAssertFalse(Diagnostics.hasBudget(emittedCount: -1))
        XCTAssertTrue(Diagnostics.hasBudget(emittedCount: 0))
        XCTAssertTrue(Diagnostics.hasBudget(emittedCount: 31))
        XCTAssertFalse(Diagnostics.hasBudget(emittedCount: 32))
        XCTAssertEqual(Diagnostics.eventLimits.reduce(0, +), Diagnostics.maximumEvents)
        XCTAssertFalse(Diagnostics.hasBudget(for: .itemAdded, counts: [8, 6, 0, 0, 0]))
        XCTAssertFalse(Diagnostics.hasBudget(for: .title, counts: [8, 6, 0, 0, 0]))
        XCTAssertTrue(Diagnostics.hasBudget(for: .language, counts: [8, 6, 0, 0, 0]))
        XCTAssertTrue(Diagnostics.hasBudget(for: .trackingBegin, counts: [8, 6, 4, 0, 0]))
        XCTAssertTrue(Diagnostics.hasBudget(for: .trackingEnd, counts: [8, 6, 4, 7, 0]))
        XCTAssertFalse(Diagnostics.hasBudget(for: .trackingBegin, counts: [8, 6, 4, 7, 0]))
        XCTAssertTrue(Diagnostics.hasBudget(for: .trackingEnd, counts: [8, 6, 4, 7, 6]))
        XCTAssertFalse(Diagnostics.hasBudget(for: .trackingEnd, counts: [8, 6, 4, 7, 7]))
        for index in 0..<Diagnostics.eventLimits.count {
            var excessive = [0, 0, 0, 0, 0]; excessive[index] = Diagnostics.eventLimits[index] + 1
            XCTAssertFalse(Diagnostics.hasBudget(for: .language, counts: excessive))
            excessive[index] = -1
            XCTAssertFalse(Diagnostics.hasBudget(for: .language, counts: excessive))
        }
        XCTAssertFalse(Diagnostics.hasBudget(for: .language, counts: [Int.max, 0, 0, 0, 0]))
        XCTAssertFalse(Diagnostics.hasBudget(for: .language, counts: []))
    }

    @MainActor
    func testMenuDiagnosticSchemaHasBoundedNumericStructureAndBeforeAfterStateOnly() throws {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }; setLanguage(.french)
        let fixture = menus()
        let secret = "Private document title / 사용자 문자열"
        fixture.custom.title = secret
        fixture.custom.addItem(NSMenuItem(title: secret, action: NSSelectorFromString("privateUserAction:"), keyEquivalent: secret))
        let viewItem = try XCTUnwrap(fixture.main.items.first { $0.submenu === fixture.view })
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help)
        let payload = AppMenuLanguageController.diagnosticPayload(in: fixture.main, windows: fixture.window,
            help: fixture.help, event: .itemChanged, beforeTitleMatches: [ObjectIdentifier(viewItem): 0])
        XCTAssertEqual(Set(payload.keys), Set(["schema", "e", "c", "n", "x", "i"]))
        XCTAssertEqual(payload["e"] as? String, "itemChanged")
        let row = try XCTUnwrap((payload["i"] as? [[Int]])?.first { $0[0] == 2 })
        XCTAssertEqual(row.count, 6)
        XCTAssertEqual(row[4], 0); XCTAssertEqual(row[5], 3)
        XCTAssertNotEqual(row[1] & (1 << 5), 0, "Only a known-command bit records fullscreen presence.")
        let data = try XCTUnwrap(AppMenuLanguageController.Diagnostics.encodedEvent(payload))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in [secret, "privateUserAction", "Présentation", "보기", "toggleFullScreen"] {
            XCTAssertFalse(json.contains(forbidden))
        }
        XCTAssertLessThanOrEqual(data.count, 900)
        for _ in 0..<40 {
            let item = NSMenuItem(title: secret, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: secret); fixture.main.addItem(item)
        }
        let wide = AppMenuLanguageController.diagnosticPayload(in: fixture.main, windows: fixture.window,
                                                              help: fixture.help, event: .trackingBegin)
        XCTAssertEqual(wide["x"] as? Bool, true)
        XCTAssertLessThanOrEqual(try XCTUnwrap(wide["i"] as? [[Int]]).count, 12)
        XCTAssertLessThanOrEqual(try XCTUnwrap(AppMenuLanguageController.Diagnostics.encodedEvent(wide)).count, 900)
        XCTAssertNil(AppMenuLanguageController.Diagnostics.encodedEvent(["oversized": String(repeating: "x", count: 901)]))
    }

    @MainActor
    func testThousandRealMenuMutationsConvergeWithoutChangingRolesOrGrowingItems() {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }; setLanguage(.french)
        let plain = menus()
        AppMenuLanguageController.apply(to: plain.main, windows: plain.window, help: plain.help,
                                       fullScreenState: { _ in nil })
        let clock = ContinuousClock()
        let plainStart = clock.now
        for _ in 0..<1_000 {
            let item = NSMenuItem(title: "Transient custom title", action: nil, keyEquivalent: "")
            plain.view.addItem(item)
            item.title = "Changed custom title"
            plain.view.removeItem(item)
        }
        let plainElapsed = plainStart.duration(to: clock.now)
        let fixture = menus()
        var translationReads = 0
        let controller = AppMenuLanguageController(notificationCenter: .default,
            applicationProvider: { nil }, menuProvider: { (fixture.main, fixture.window, fixture.help) },
            translationProvider: { key in translationReads += 1; return L10n.string(key) })
        controller.start()
        let initialTranslationReads = translationReads
        let topIdentities = fixture.main.items.map(ObjectIdentifier.init)
        let commandIdentities = fixture.view.items.map(ObjectIdentifier.init)
        let controllerStart = clock.now
        for _ in 0..<1_000 {
            let item = NSMenuItem(title: "Transient custom title", action: nil, keyEquivalent: "")
            fixture.view.addItem(item)
            item.title = "Changed custom title"
            fixture.view.removeItem(item)
        }
        let controllerElapsed = controllerStart.duration(to: clock.now)
        // Completion and final state exercise reentrancy/coalescing without
        // imposing a machine-dependent performance threshold on this UI test.
        XCTAssertEqual(fixture.view.title, "Présentation")
        XCTAssertEqual(fixture.main.items.map(ObjectIdentifier.init), topIdentities)
        XCTAssertEqual(fixture.view.items.map(ObjectIdentifier.init), commandIdentities)
        XCTAssertEqual(fixture.custom.title, "김민수 작업공간")
        XCTAssertEqual(translationReads, initialTranslationReads)
        XCTAssertLessThanOrEqual(translationReads, 18)
        func seconds(_ duration: Duration) -> Double {
            let value = duration.components
            return Double(value.seconds) + Double(value.attoseconds) / 1e18
        }
        // Retained in the normal owned test log. Diagnostic Debug comparison,
        // never a Release latency claim or a machine-dependent pass threshold.
        print("EMBER_MENU_MUTATION_BENCHMARK plainSeconds=\(seconds(plainElapsed)) controllerSeconds=\(seconds(controllerElapsed)) iterations=1000 translationReads=\(translationReads)")
    }

    @MainActor
    func testControllerReusesBoundedNativeTranslationsAndInvalidatesOnRealLanguageChange() {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }; setLanguage(.french)
        let fixture = menus()
        var reads: [String: Int] = [:]
        let controller = AppMenuLanguageController(notificationCenter: .default,
            applicationProvider: { nil }, menuProvider: { (fixture.main, fixture.window, fixture.help) },
            translationProvider: { key in reads[key, default: 0] += 1; return L10n.string(key) })
        controller.start()
        XCTAssertEqual(fixture.view.title, "Présentation")
        let initial = reads
        for _ in 0..<20 {
            let item = NSMenuItem(title: "User command", action: nil, keyEquivalent: "")
            fixture.view.addItem(item); item.title = "Changed user command"; fixture.view.removeItem(item)
        }
        fixture.view.title = "보기"
        XCTAssertEqual(fixture.view.title, "Présentation")
        XCTAssertEqual(reads, initial)
        XCTAssertLessThanOrEqual(reads.count, 18)
        XCTAssertTrue(reads.values.allSatisfy { $0 == 1 })
        let preferences = AppPreferences(defaults: .standard, appearanceDidChange: { _ in })
        preferences.language = .english
        XCTAssertEqual(fixture.view.title, "View")
        for key in initial.keys { XCTAssertEqual(reads[key], 2) }
        preferences.language = .french
        XCTAssertEqual(fixture.view.title, "Présentation")
        for key in initial.keys { XCTAssertEqual(reads[key], 3) }
        XCTAssertEqual(fixture.custom.title, "김민수 작업공간")
    }

    @MainActor
    func testControllerNoticesDirectSavedLanguageChangesAndUsesEffectiveFallbackEnum() {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }; setLanguage(.french)
        let fixture = menus()
        var reads: [String: Int] = [:]
        let controller = AppMenuLanguageController(notificationCenter: .default,
            applicationProvider: { nil }, menuProvider: { (fixture.main, fixture.window, fixture.help) },
            translationProvider: { key in reads[key, default: 0] += 1; return L10n.string(key) })
        controller.start()
        XCTAssertEqual(fixture.view.title, "Présentation")
        UserDefaults.standard.set("en", forKey: AppPreferences.languageDefaultsKey)
        fixture.view.title = "보기" // Real KVO repair, without a language notification.
        XCTAssertEqual(fixture.view.title, "View")
        XCTAssertTrue(reads.values.allSatisfy { $0 == 2 })
        let englishReads = reads
        UserDefaults.standard.set("pt", forKey: AppPreferences.languageDefaultsKey)
        fixture.view.title = "보기"
        XCTAssertEqual(fixture.view.title, "View", "The existing pt preference maps to effective English.")
        XCTAssertEqual(reads, englishReads, "A raw preference alias must not invalidate the same effective language.")
        UserDefaults.standard.set("not-a-language", forKey: AppPreferences.languageDefaultsKey)
        fixture.view.title = "Stale title"
        XCTAssertEqual(fixture.view.title, "보기")
        XCTAssertTrue(reads.values.allSatisfy { $0 == 3 })
        XCTAssertLessThanOrEqual(reads.count, 18)
    }

    @MainActor
    func testNativeFullscreenTitleUsesResolvedStateAndLeavesUnknownStateUnchanged() throws {
        let fixture = menus(), target = NSObject()
        let command = try XCTUnwrap(fixture.view.items.first { $0.action == NSSelectorFromString("toggleFullScreen:") })
        command.target = target; command.keyEquivalent = "f"
        command.keyEquivalentModifierMask = [.command, .control]; command.isEnabled = false
        let action = command.action, key = command.keyEquivalent, modifiers = command.keyEquivalentModifierMask
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help,
            fullScreenState: { _ in false }, title: { "FR:" + $0 })
        XCTAssertEqual(command.title, "FR:native_menu.enter_full_screen")
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help,
            fullScreenState: { _ in true }, title: { "FR:" + $0 })
        XCTAssertEqual(command.title, "FR:native_menu.exit_full_screen")
        command.title = "Unresolved native title"
        command.target = nil
        var sawNilTarget = false
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help,
            fullScreenState: { item in sawNilTarget = item.target == nil; return nil }, title: { "FR:" + $0 })
        XCTAssertEqual(command.title, "Unresolved native title")
        XCTAssertTrue(sawNilTarget); XCTAssertNil(command.target)
        command.target = target
        XCTAssertTrue(command.target === target)
        XCTAssertEqual(command.action, action); XCTAssertEqual(command.keyEquivalent, key)
        XCTAssertEqual(command.keyEquivalentModifierMask, modifiers); XCTAssertFalse(command.isEnabled)
        let custom = NSMenuItem(title: "Custom fullscreen", action: action, keyEquivalent: "")
        fixture.custom.addItem(custom)
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help,
            fullScreenState: { _ in false }, title: { "FR:" + $0 })
        XCTAssertEqual(custom.title, "Custom fullscreen", "Unknown duplicate View roles must remain unowned.")
    }


    @MainActor
    func testGalleryShortcutIdentifiesViewBeforeNativeFullscreenAndKeepsCacheBounded() throws {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }; setLanguage(.french)
        let fixture = menus()
        fixture.view.removeAllItems(); fixture.view.title = "Unrecognized original title"
        let gallery = NSMenuItem(title: "Owned gallery action", action: NSSelectorFromString("menuAction:"), keyEquivalent: "G")
        gallery.keyEquivalentModifierMask = [.command, .shift]; gallery.isEnabled = false
        fixture.view.addItem(gallery)
        var reads = 0
        let controller = AppMenuLanguageController(notificationCenter: .default,
            applicationProvider: { nil }, menuProvider: { (fixture.main, fixture.window, fixture.help) },
            translationProvider: { reads += 1; return L10n.string($0) })
        controller.start()
        XCTAssertEqual(fixture.view.title, "Présentation")
        let initialReads = reads
        for _ in 0..<20 { fixture.view.title = "Native reset" }
        XCTAssertEqual(fixture.view.title, "Présentation"); XCTAssertEqual(reads, initialReads)
        XCTAssertLessThanOrEqual(reads, 18)
        XCTAssertEqual(gallery.title, "Owned gallery action"); XCTAssertEqual(gallery.action, NSSelectorFromString("menuAction:"))
        XCTAssertEqual(gallery.keyEquivalent, "G"); XCTAssertEqual(gallery.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertFalse(gallery.isEnabled); XCTAssertEqual(fixture.custom.title, "김민수 작업공간")
    }

    @MainActor
    func testGalleryFallbackRejectsWrongModifiersAndCompetingViewCandidates() {
        let fixture = menus()
        fixture.view.removeAllItems()
        let gallery = NSMenuItem(title: "Gallery", action: nil, keyEquivalent: "g")
        fixture.view.addItem(gallery)
        let wrongModifiers: [NSEvent.ModifierFlags] = [.command, [.command, .shift, .option], [.command, .control]]
        for modifiers in wrongModifiers {
            gallery.keyEquivalentModifierMask = modifiers; fixture.view.title = "Keep original"
            AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help, title: { "FR:" + $0 })
            XCTAssertEqual(fixture.view.title, "Keep original")
        }
        gallery.keyEquivalentModifierMask = [.command, .shift]
        let duplicate = NSMenuItem(title: "User gallery", action: nil, keyEquivalent: "g")
        duplicate.keyEquivalentModifierMask = [.command, .shift]; fixture.custom.addItem(duplicate)
        fixture.custom.title = "User supplied title"
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help, title: { "FR:" + $0 })
        XCTAssertEqual(fixture.view.title, "Keep original"); XCTAssertEqual(fixture.custom.title, "User supplied title")
        fixture.custom.removeItem(duplicate)
        fixture.custom.addItem(NSMenuItem(title: "User fullscreen", action: NSSelectorFromString("toggleFullScreen:"), keyEquivalent: ""))
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help, title: { "FR:" + $0 })
        XCTAssertEqual(fixture.view.title, "Keep original"); XCTAssertEqual(fixture.custom.title, "User supplied title")
        fixture.custom.removeAllItems(); fixture.window.addItem(duplicate)
        AppMenuLanguageController.apply(to: fixture.main, windows: fixture.window, help: fixture.help, title: { "FR:" + $0 })
        XCTAssertEqual(fixture.view.title, "FR:native_menu.view")
        XCTAssertEqual(fixture.window.title, "FR:native_menu.window")
    }

    @MainActor
    func testUnknownTopLevelSubmenuReplacementIsDiscoveredWithoutYieldOrTitleMatching() throws {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }; setLanguage(.french)
        let fixture = menus(), top = try XCTUnwrap(fixture.main.items.first { $0.submenu === fixture.view })
        top.submenu = nil; top.title = "User text stays unowned"
        let controller = AppMenuLanguageController(notificationCenter: .default,
            applicationProvider: { nil }, menuProvider: { (fixture.main, fixture.window, fixture.help) })
        controller.start()
        XCTAssertEqual(top.title, "User text stays unowned")
        let first = NSMenu(title: "Replacement one")
        let gallery = NSMenuItem(title: "Gallery", action: NSSelectorFromString("menuAction:"), keyEquivalent: "g")
        gallery.keyEquivalentModifierMask = [.command, .shift]; first.addItem(gallery)
        top.submenu = first
        XCTAssertEqual(top.title, "Présentation"); XCTAssertEqual(first.title, "Présentation")
        top.title = "Native item reset"; first.title = "Native menu reset"
        XCTAssertEqual(top.title, "Présentation"); XCTAssertEqual(first.title, "Présentation")
        let unknown = NSMenu(title: "Unowned replacement")
        top.submenu = unknown; top.title = "Keep this custom title"
        first.title = "Retired menu title"
        XCTAssertEqual(top.title, "Keep this custom title"); XCTAssertEqual(unknown.title, "Unowned replacement")
        XCTAssertEqual(first.title, "Retired menu title")
        let second = NSMenu(title: "Replacement two")
        second.addItem(NSMenuItem(title: "Native fullscreen", action: NSSelectorFromString("toggleFullScreen:"), keyEquivalent: ""))
        top.submenu = second
        XCTAssertEqual(top.title, "Présentation"); XCTAssertEqual(second.title, "Présentation")
        XCTAssertEqual(fixture.custom.title, "김민수 작업공간")
    }

    @MainActor
    func testNewMainMenuUnknownSubmenusAreObservedAndRetiredMainHasNoAuthority() throws {
        let previous = UserDefaults.standard.string(forKey: AppPreferences.languageDefaultsKey)
        defer { restoreLanguage(previous) }; setLanguage(.french)
        let application = NSApplication.shared, prior = application.mainMenu
        defer { application.mainMenu = prior }
        let first = menus(), second = menus()
        let top = try XCTUnwrap(second.main.items.first { $0.submenu === second.view })
        top.submenu = nil
        var current = first
        application.mainMenu = first.main
        let controller = AppMenuLanguageController(notificationCenter: .default,
            applicationProvider: { application }, menuProvider: { (application.mainMenu, current.window, current.help) })
        controller.start()
        current = second; application.mainMenu = second.main
        let owned = NSMenu(title: "Fresh native title")
        owned.addItem(NSMenuItem(title: "Native fullscreen", action: NSSelectorFromString("toggleFullScreen:"), keyEquivalent: ""))
        top.submenu = owned
        XCTAssertEqual(top.title, "Présentation"); XCTAssertEqual(owned.title, "Présentation")
        first.view.title = "Retired main title"
        XCTAssertEqual(first.view.title, "Retired main title")
        XCTAssertEqual(second.custom.title, "김민수 작업공간")
    }


    @MainActor
    func testTrackingDiagnosticsDistinguishCurrentNativeMenuFromDetachedCopyWithoutTitles() throws {
        let fixture = menus()
        fixture.view.addItem(NSMenuItem(title: "Secret tab title", action: NSSelectorFromString("toggleTabBar:"), keyEquivalent: ""))
        let direct = AppMenuLanguageController.diagnosticPayload(in: fixture.main, windows: fixture.window,
            help: fixture.help, event: .trackingBegin, observedMenu: fixture.view)
        XCTAssertEqual(direct["schema"] as? Int, 2)
        XCTAssertEqual(direct["t"] as? [Int], [1, 3])
        let detached = NSMenu(title: "Private detached title")
        detached.addItem(NSMenuItem(title: "Secret fullscreen", action: NSSelectorFromString("toggleFullScreen:"), keyEquivalent: ""))
        let other = AppMenuLanguageController.diagnosticPayload(in: fixture.main, windows: fixture.window,
            help: fixture.help, event: .trackingBegin, observedMenu: detached)
        XCTAssertEqual(other["t"] as? [Int], [2, 1])
        let data = try XCTUnwrap(AppMenuLanguageController.Diagnostics.encodedEvent(other))
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertLessThanOrEqual(data.count, 900)
        for text in ["Private", "Secret", "toggleFullScreen", "보기"] { XCTAssertFalse(encoded.contains(text)) }
        XCTAssertEqual(detached.title, "Private detached title")
        for _ in 0..<260 { detached.addItem(NSMenuItem(title: "Private", action: nil, keyEquivalent: "")) }
        detached.addItem(NSMenuItem(title: "Beyond bounded scan", action: NSSelectorFromString("toggleTabOverview:"), keyEquivalent: ""))
        let wide = AppMenuLanguageController.diagnosticPayload(in: fixture.main, windows: fixture.window,
            help: fixture.help, event: .trackingEnd, observedMenu: detached)
        XCTAssertEqual(wide["t"] as? [Int], [2, 1])
        XCTAssertLessThanOrEqual(try XCTUnwrap(AppMenuLanguageController.Diagnostics.encodedEvent(wide)).count, 900)
    }

    @MainActor private func setLanguage(_ language: AppLanguage) { UserDefaults.standard.set(language.rawValue, forKey: AppPreferences.languageDefaultsKey) }
    @MainActor private func restoreLanguage(_ value: String?) {
        if let value { UserDefaults.standard.set(value, forKey: AppPreferences.languageDefaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: AppPreferences.languageDefaultsKey) }
    }
    @MainActor private func menus() -> (main: NSMenu, file: NSMenu, edit: NSMenu, view: NSMenu, window: NSMenu, help: NSMenu, custom: NSMenu) {
        _ = NSApplication.shared
        let main = NSMenu(title: "Main"), file = NSMenu(title: "파일"), edit = NSMenu(title: "편집"), view = NSMenu(title: "보기")
        let window = NSMenu(title: "윈도우"), help = NSMenu(title: "도움말"), custom = NSMenu(title: "김민수 작업공간")
        for key in ["t", "o", "w", "s"] { let item = NSMenuItem(title: key, action: nil, keyEquivalent: key); item.keyEquivalentModifierMask = .command; file.addItem(item) }
        for action in ["cut:", "copy:", "paste:"] { edit.addItem(NSMenuItem(title: action, action: NSSelectorFromString(action), keyEquivalent: "")) }
        view.addItem(NSMenuItem(title: "전체화면", action: NSSelectorFromString("toggleFullScreen:"), keyEquivalent: ""))
        for menu in [file, edit, view, window, help, custom] { let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: ""); item.submenu = menu; main.addItem(item) }
        return (main, file, edit, view, window, help, custom)
    }
}
