// SPDX-License-Identifier: MPL-2.0
import AppKit
import CoreFoundation
import Foundation
import OSLog

/// AppKit's standard menu titles use the process launch language. Refresh only
/// identifiable application menu roles; never match or rewrite user text.
@MainActor
final class AppMenuLanguageController {
    enum DiagnosticEvent: String {
        case start, language, trackingBegin, trackingEnd, itemAdded, itemRemoved, itemChanged
        case mainMenu, submenu, title, coalesced

        var isStructural: Bool {
            switch self {
            case .itemAdded, .itemRemoved, .itemChanged, .mainMenu, .submenu, .coalesced: true
            default: false
            }
        }
    }

    /// Shares the existing QA opt-in, but never enables menu telemetry in a
    /// production bundle. Only numeric structure/state is logged, never titles.
    @MainActor
    enum Diagnostics {
        static let maximumEvents = 32
        // Independent reserves prevent title/structure churn during launch
        // from consuming language or real tracking observations.
        static let eventLimits = [8, 6, 4, 7, 7] // structure, title, language, begin, end
        static let maximumEventBytes = 900
        static let maximumItems = 12
        static let enabled = isEligible(
            environmentValue: ProcessInfo.processInfo.environment["EMBER_QA_BODY_FIT_DIAGNOSTICS"],
            bundleIdentifier: Bundle.main.bundleIdentifier,
            qaInfoValue: Bundle.main.object(forInfoDictionaryKey: "EmberQABodyFitDiagnostics"))
        private static let logger = Logger(subsystem: "com.vibepdf.mac", category: "native-menu-diagnostics")
        private static var emittedCounts = [0, 0, 0, 0, 0]

        static func isEligible(environmentValue: String?, bundleIdentifier: String?, qaInfoValue: Any?) -> Bool {
            guard bundleIdentifier?.hasPrefix("com.vibepdf.mac.releaseqa") == true else { return false }
            if environmentValue == "1" { return true }
            guard let value = qaInfoValue as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
            return value.boolValue
        }

        static func hasBudget(emittedCount: Int) -> Bool { (0..<maximumEvents).contains(emittedCount) }

        private static func budgetIndex(for event: DiagnosticEvent) -> Int {
            switch event {
            case .title: 1
            case .language: 2
            case .trackingBegin: 3
            case .trackingEnd: 4
            default: 0
            }
        }

        static func hasBudget(for event: DiagnosticEvent, counts: [Int]) -> Bool {
            guard counts.count == eventLimits.count,
                  zip(counts, eventLimits).allSatisfy({ (0...$0.1).contains($0.0) }),
                  hasBudget(emittedCount: counts.reduce(0, +)) else { return false }
            let index = budgetIndex(for: event)
            return counts[index] < eventLimits[index]
        }

        static func canRecord(_ event: DiagnosticEvent) -> Bool {
            enabled && hasBudget(for: event, counts: emittedCounts)
        }

        static func encodedEvent(_ payload: [String: Any]) -> Data? {
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                  data.count <= maximumEventBytes else { return nil }
            return data
        }

        static func record(_ payload: [String: Any], event: DiagnosticEvent) {
            guard canRecord(event) else { return }
            emittedCounts[budgetIndex(for: event)] += 1
            guard let data = encodedEvent(payload), let json = String(data: data, encoding: .utf8) else { return }
            logger.notice("\(json, privacy: .public)")
        }
    }

    typealias Menus = (main: NSMenu?, windows: NSMenu?, help: NSMenu?)
    private let notificationCenter: NotificationCenter
    private let menuProvider: @MainActor () -> Menus
    private let applicationProvider: @MainActor () -> NSApplication?
    private let translationProvider: @MainActor (String) -> String
    private var translationLanguage: AppLanguage?
    private var nativeTranslations: [String: String] = [:]
    // Only fixed application-owned keys may be retained. Never cache menu
    // titles, user text or dynamic history labels. At most 18 small strings.
    private static let nativeTranslationKeys: Set<String> = [
        "native_menu.file", "native_menu.edit", "native_menu.view", "native_menu.window", "native_menu.help",
        "menu.close", "native_menu.close_all", "native_menu.cut", "native_menu.copy", "native_menu.paste",
        "action.delete", "native_menu.select_all", "native_menu.hide_tab_bar", "native_menu.show_tab_bar",
        "native_menu.exit_tab_overview", "native_menu.show_all_tabs",
        "native_menu.enter_full_screen", "native_menu.exit_full_screen"
    ]
    private weak var observedApplication: NSApplication?
    private var applicationMenuObservation: NSKeyValueObservation?
    // Structural discovery must include unknown top-level items. SwiftUI may
    // populate or replace their submenu before a role fingerprint exists.
    private var submenuObservations: [NSKeyValueObservation] = []
    private var submenuItemIdentities: [ObjectIdentifier] = []
    private var titleObservations: [NSKeyValueObservation] = []
    private var titleIdentities: [ObjectIdentifier] = []
    private var observations: [NSObjectProtocol] = []
    private var pendingRefresh: Task<Void, Never>?
    private var isRefreshing = false

    init(notificationCenter: NotificationCenter = .default,
         applicationProvider: @escaping @MainActor () -> NSApplication? = { NSApp },
         menuProvider: @escaping @MainActor () -> Menus = {
             (NSApp?.mainMenu, NSApp?.windowsMenu, NSApp?.helpMenu)
         },
         translationProvider: @escaping @MainActor (String) -> String = { L10n.string($0) }) {
        self.notificationCenter = notificationCenter; self.menuProvider = menuProvider
        self.applicationProvider = applicationProvider
        self.translationProvider = translationProvider
    }
    func start() {
        guard observations.isEmpty else { return }
        observations.append(notificationCenter.addObserver(forName: .appLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh(event: .language)
                self?.scheduleRefresh()
            }
        })
        observations.append(notificationCenter.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
            // Tracking runs its own AppKit run loop. A queued Task can remain
            // pending until the menu closes, so update before it is presented.
            MainActor.assumeIsolated { self?.refresh(event: .trackingBegin, observedMenu: note.object as? NSMenu) }
        })
        observations.append(notificationCenter.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.recordDiagnostics(event: .trackingEnd, observedMenu: note.object as? NSMenu) }
        })
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification, NSMenu.didChangeItemNotification] {
            observations.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, !self.isRefreshing, let menu = note.object as? NSMenu,
                          let main = self.menuProvider().main,
                          menu === main || main.items.contains(where: { $0.submenu === menu }) else { return }
                    // A standard command can arrive after tracking begins.
                    // Repair titles synchronously: a MainActor Task can wait
                    // until tracking/modal processing returns. Own title writes
                    // are excluded by isRefreshing, without changing structure.
                    let event: DiagnosticEvent = name == NSMenu.didAddItemNotification ? .itemAdded
                        : (name == NSMenu.didRemoveItemNotification ? .itemRemoved : .itemChanged)
                    self.refresh(event: event)
                    self.scheduleRefresh()
                }
            })
        }
        refresh(event: .start)
        scheduleRefresh()
    }
    deinit {
        pendingRefresh?.cancel()
        observations.forEach(notificationCenter.removeObserver)
        applicationMenuObservation?.invalidate()
        titleObservations.forEach { $0.invalidate() }
        submenuObservations.forEach { $0.invalidate() }
    }

    private func scheduleRefresh() {
        guard pendingRefresh == nil else { return }
        pendingRefresh = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.pendingRefresh = nil
            self.refresh(event: .coalesced)
        }
    }

    private func refresh(event: DiagnosticEvent, observedMenu: NSMenu? = nil) {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        bindApplicationMenuIfNeeded()
        let menus = menuProvider()
        let roles = menus.main.map { Self.roles(in: $0, windows: menus.windows, help: menus.help) } ?? [:]
        bindTitleObservations(to: menus, roles: roles)
        guard let main = menus.main else { return }
        prepareTranslations(invalidate: event == .language)
        // Check both opt-in and the reserved category budget before any
        // diagnostic title/fingerprint collection, including after exhaustion.
        let shouldRecord = Diagnostics.canRecord(event)
        let before = shouldRecord
            ? Self.diagnosticTitleMatches(in: main, roles: roles, title: nativeTitle) : nil
        Self.apply(to: main, roles: roles, tabState: Self.nativeTabState,
                   fullScreenState: Self.nativeFullScreenState, title: nativeTitle)
        if shouldRecord {
            Diagnostics.record(Self.diagnosticPayload(in: main, windows: menus.windows, help: menus.help,
                roles: roles, event: event, beforeTitleMatches: before, title: nativeTitle, observedMenu: observedMenu), event: event)
        }
    }

    private func recordDiagnostics(event: DiagnosticEvent, observedMenu: NSMenu? = nil) {
        guard Diagnostics.canRecord(event) else { return }
        let menus = menuProvider()
        guard let main = menus.main else { return }
        let roles = Self.roles(in: main, windows: menus.windows, help: menus.help)
        prepareTranslations()
        Diagnostics.record(Self.diagnosticPayload(in: main, windows: menus.windows, help: menus.help,
            roles: roles, event: event, title: nativeTitle, observedMenu: observedMenu), event: event)
    }

    private func prepareTranslations(invalidate: Bool = false) {
        // Read the effective saved enum once per refresh. This also notices
        // direct UserDefaults edits that do not post appLanguageDidChange.
        let language = L10n.currentLanguage
        if invalidate || translationLanguage != language {
            nativeTranslations.removeAll(keepingCapacity: true)
            translationLanguage = language
        }
    }

    private func nativeTitle(_ key: String) -> String {
        guard Self.nativeTranslationKeys.contains(key) else { return translationProvider(key) }
        if let translated = nativeTranslations[key] { return translated }
        let translated = translationProvider(key)
        nativeTranslations[key] = translated
        return translated
    }

    private func bindApplicationMenuIfNeeded() {
        let application = applicationProvider()
        guard observedApplication !== application else { return }
        applicationMenuObservation?.invalidate()
        applicationMenuObservation = nil
        observedApplication = application
        applicationMenuObservation = application?.observe(\.mainMenu, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.nativeMenuDidChange(structuralChange: true, event: .mainMenu) }
        }
    }

    private func bindTitleObservations(to menus: Menus, roles: [ObjectIdentifier: String]) {
        let topItems = menus.main?.items ?? []
        let structuralIdentities = topItems.map(ObjectIdentifier.init)
        if structuralIdentities != submenuItemIdentities {
            submenuObservations.forEach { $0.invalidate() }
            submenuObservations.removeAll()
            submenuItemIdentities = structuralIdentities
            for item in topItems {
                // Observe replacement only; an unrecognized/custom title is
                // never observed or rewritten without a fresh unique role.
                submenuObservations.append(item.observe(\.submenu, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.nativeMenuDidChange(structuralChange: true, event: .submenu) }
                })
            }
        }
        let items = topItems.filter { roles[ObjectIdentifier($0)] != nil }
        let identities = items.flatMap { item -> [ObjectIdentifier] in
            guard let submenu = item.submenu else { return [] }
            return [ObjectIdentifier(item), ObjectIdentifier(submenu)]
        }
        guard identities != titleIdentities else { return }
        titleObservations.forEach { $0.invalidate() }
        titleObservations.removeAll()
        titleIdentities = identities
        for item in items {
            guard let submenu = item.submenu else { continue }
            // The menu bar displays NSMenu.title. AppKit can reset that
            // property without changing a child item or beginning tracking.
            titleObservations.append(submenu.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.nativeMenuDidChange() }
            })
            titleObservations.append(item.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.nativeMenuDidChange() }
            })
        }
    }

    private func nativeMenuDidChange(structuralChange: Bool = false, event: DiagnosticEvent = .title) {
        // Do not lose a replacement that arrives during an owned title write.
        // Own title notifications themselves must not start a refresh loop.
        if structuralChange { scheduleRefresh() }
        guard !isRefreshing else { return }
        // KVO delivery follows the real native setter. Repair immediately,
        // including inside AppKit's tracking run loop, then coalesce a final
        // pass in case SwiftUI is still assembling a replacement main menu.
        refresh(event: event)
        scheduleRefresh()
    }

    private static func roles(in main: NSMenu, windows: NSMenu?, help: NSMenu?) -> [ObjectIdentifier: String] {
        let items = main.items.filter { $0.submenu != nil }
        var roles: [ObjectIdentifier: String] = [:]
        func assignUnique(_ key: String, excludingKnownNativeRoles: Bool = false,
                          matching predicate: (NSMenuItem) -> Bool) {
            let matches = items.filter { item in
                let role = roles[ObjectIdentifier(item)]
                return (!excludingKnownNativeRoles || (role != "window" && role != "help")) && predicate(item)
            }
            guard matches.count == 1, let item = matches.first,
                  roles[ObjectIdentifier(item)] == nil else { return }
            roles[ObjectIdentifier(item)] = key
        }
        // Window/Help are official AppKit menu identities. File/Edit/View
        // use this app's standard public commands, independent of any title.
        if let windows { assignUnique("window") { $0.submenu === windows } }
        if let help { assignUnique("help") { $0.submenu === help } }
        assignUnique("file") { item in
            let keys = Set((item.submenu?.items ?? []).filter {
                $0.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == .command
            }.map { $0.keyEquivalent.lowercased() })
            return Set(["t", "o", "w"]).isSubset(of: keys)
        }
        func commandKeys(in item: NSMenuItem) -> Set<String> {
            Set((item.submenu?.items ?? []).filter {
                $0.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == .command
            }.map { $0.keyEquivalent.lowercased() })
        }
        assignUnique("edit") { item in
            let actions = Set((item.submenu?.items ?? []).compactMap { $0.action.map(NSStringFromSelector) })
            return Set(["cut:", "copy:", "paste:"]).isSubset(of: actions)
                || Set(["x", "c", "v", "z", "f"]).isSubset(of: commandKeys(in: item))
        }
        // Official Window/Help identities cannot become View. The application
        // also declares one gallery shortcut in CommandGroup(after: .sidebar),
        // which exists before AppKit adds fullscreen commands. All candidate
        // menus still participate in the same uniqueness check; no role is
        // remembered after its current structural evidence disappears.
        assignUnique("view", excludingKnownNativeRoles: true, matching: hasViewFingerprint)
        return roles
    }

    private static func hasViewFingerprint(_ item: NSMenuItem) -> Bool {
        (item.submenu?.items ?? []).contains {
            $0.action == NSSelectorFromString("toggleFullScreen:")
                || ($0.keyEquivalent.lowercased() == "f"
                    && $0.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [.command, .control])
                || hasGalleryShortcut($0)
        }
    }

    private static func hasGalleryShortcut(_ item: NSMenuItem) -> Bool {
        item.keyEquivalent.lowercased() == "g"
            && item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [.command, .shift]
    }

    private static func diagnosticTitleMatches(in main: NSMenu, roles: [ObjectIdentifier: String],
                                               title: (String) -> String) -> [ObjectIdentifier: Int] {
        return Dictionary(uniqueKeysWithValues: main.items.prefix(Diagnostics.maximumItems).map { item in
            let role = roles[ObjectIdentifier(item)]
            let expected = role.map { title("native_menu." + $0) }
            let matches = expected.map { (item.title == $0 ? 1 : 0) | (item.submenu?.title == $0 ? 2 : 0) } ?? 0
            return (ObjectIdentifier(item), matches)
        })
    }

    /// Numeric schema: c=file/edit/raw-View/eligible-View match counts;
    /// each i row=index/known-command bits/official identity bits/role/before/after.
    /// Title match bits are only booleans against the selected app translation.
    static func diagnosticPayload(in main: NSMenu, windows: NSMenu?, help: NSMenu?, event: DiagnosticEvent,
                                  beforeTitleMatches: [ObjectIdentifier: Int]? = nil, observedMenu: NSMenu? = nil) -> [String: Any] {
        let roles = Self.roles(in: main, windows: windows, help: help)
        return diagnosticPayload(in: main, windows: windows, help: help, roles: roles,
            event: event, beforeTitleMatches: beforeTitleMatches, title: { L10n.string($0) }, observedMenu: observedMenu)
    }

    private static func diagnosticPayload(in main: NSMenu, windows: NSMenu?, help: NSMenu?,
                                          roles: [ObjectIdentifier: String], event: DiagnosticEvent,
                                          beforeTitleMatches: [ObjectIdentifier: Int]? = nil,
                                          title: (String) -> String, observedMenu: NSMenu? = nil) -> [String: Any] {
        let after = diagnosticTitleMatches(in: main, roles: roles, title: title)
        let roleIDs = ["file": 1, "edit": 2, "view": 3, "window": 4, "help": 5]
        var counts = [0, 0, 0, 0]
        var rows: [[Int]] = []
        let knownActions = ["performClose:", "cut:", "copy:", "paste:", "selectAll:",
                            "toggleFullScreen:", "toggleTabBar:", "toggleTabOverview:"]
        for (index, item) in main.items.enumerated() {
            guard let submenu = item.submenu else { continue }
            let commands = submenu.items
            let actions = Set(commands.compactMap { $0.action.map(NSStringFromSelector) })
            let keys = Set(commands.filter {
                $0.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == .command
            }.map { $0.keyEquivalent.lowercased() })
            let file = Set(["t", "o", "w"]).isSubset(of: keys)
            let edit = Set(["cut:", "copy:", "paste:"]).isSubset(of: actions)
                || Set(["x", "c", "v", "z", "f"]).isSubset(of: keys)
            let view = hasViewFingerprint(item)
            let official = (submenu === windows ? 1 : 0) | (submenu === help ? 2 : 0)
            if file { counts[0] += 1 }; if edit { counts[1] += 1 }
            if view { counts[2] += 1; if official == 0 { counts[3] += 1 } }
            guard index < Diagnostics.maximumItems else { continue }
            var bits = 0
            for (bit, action) in knownActions.enumerated() where actions.contains(action) { bits |= 1 << bit }
            if file { bits |= 1 << 8 }; if edit { bits |= 1 << 9 }
            if view { bits |= 1 << 10 }
            let identity = ObjectIdentifier(item), current = after[identity] ?? 0
            rows.append([index, bits, official, roles[identity].flatMap { roleIDs[$0] } ?? 0,
                         beforeTitleMatches?[identity] ?? current, current])
        }
        var result: [String: Any] = ["schema": 2, "e": event.rawValue, "c": counts, "n": main.items.count,
                "x": main.items.count > Diagnostics.maximumItems, "i": rows]
        if let observedMenu { result["t"] = diagnosticTrackingContext(observedMenu, main: main) }
        return result
    }

    /// This observes notification identity only. A detached popup/copy is never
    /// promoted to an owned native role or translated based on these fields.
    /// t = relation (0 main, 1 direct child, 2 unrelated), known action bits.
    private static func diagnosticTrackingContext(_ menu: NSMenu, main: NSMenu) -> [Int] {
        let maximumCommands = 256
        let commands = menu.items.prefix(maximumCommands)
        var bits = 0
        for item in commands {
            if item.action == NSSelectorFromString("toggleFullScreen:") { bits |= 1 }
            if item.action == NSSelectorFromString("toggleTabBar:") { bits |= 2 }
            if item.action == NSSelectorFromString("toggleTabOverview:") { bits |= 4 }

        }
        let relation = menu === main ? 0 : (main.items.prefix(128).contains { $0.submenu === menu } ? 1 : 2)
        return [relation, bits]
    }

    static func apply(to main: NSMenu, windows: NSMenu?, help: NSMenu?,
                      tabState: @MainActor (NSMenuItem) -> (barVisible: Bool, overviewVisible: Bool)? = { nativeTabState($0) },
                      fullScreenState: @MainActor (NSMenuItem) -> Bool? = { nativeFullScreenState($0) },
                      title: (String) -> String = { L10n.string($0) }) {
        let roles = Self.roles(in: main, windows: windows, help: help)
        apply(to: main, roles: roles, tabState: tabState, fullScreenState: fullScreenState, title: title)
    }

    private static func nativeWindow(for command: NSMenuItem) -> NSWindow? {
        guard let action = command.action else { return nil }
        return (command.target as? NSWindow)
            ?? (NSApp?.target(forAction: action, to: command.target, from: command) as? NSWindow)
    }

    private static func nativeTabState(_ command: NSMenuItem) -> (barVisible: Bool, overviewVisible: Bool)? {
        guard let window = nativeWindow(for: command) else { return nil }
        return (window.tabGroup?.isTabBarVisible ?? false, window.tabGroup?.isOverviewVisible ?? false)
    }

    private static func nativeFullScreenState(_ command: NSMenuItem) -> Bool? {
        nativeWindow(for: command).map { $0.styleMask.contains(.fullScreen) }
    }

    private static func apply(to main: NSMenu, roles: [ObjectIdentifier: String],
                              tabState: @MainActor (NSMenuItem) -> (barVisible: Bool, overviewVisible: Bool)?,
                              fullScreenState: @MainActor (NSMenuItem) -> Bool?, title: (String) -> String) {
        let items = main.items.filter { $0.submenu != nil }
        for item in items {
            guard let role = roles[ObjectIdentifier(item)] else { continue }
            let localized = title("native_menu." + role)
            if item.title != localized { item.title = localized }
            if item.submenu?.title != localized { item.submenu?.title = localized }
            // Only AppKit commands in an identified native role are owned
            // here. Targets, shortcuts, validation and user menu text stay put.
            let commands: [String: String]
            switch role {
            case "file": commands = ["performClose:": "menu.close", "closeAll:": "native_menu.close_all", "closeAllDocuments:": "native_menu.close_all"]
            case "edit": commands = ["cut:": "native_menu.cut", "copy:": "native_menu.copy", "paste:": "native_menu.paste", "delete:": "action.delete", "selectAll:": "native_menu.select_all"]
            default: commands = [:]
            }
            for command in item.submenu?.items ?? [] {
                guard let action = command.action else { continue }
                let actionName = NSStringFromSelector(action)
                let key: String
                if role == "view", actionName == "toggleFullScreen:" {
                    guard let isFullScreen = fullScreenState(command) else { continue }
                    key = isFullScreen ? "native_menu.exit_full_screen" : "native_menu.enter_full_screen"
                } else if role == "view", ["toggleTabBar:", "toggleTabOverview:"].contains(actionName) {
                    // AppKit inserts these titles in the process launch language.
                    // Read the actual responder window; never infer toggle state
                    // from an old localized title or change action/validation.
                    guard let state = tabState(command) else { continue }
                    key = actionName == "toggleTabBar:"
                        ? (state.barVisible ? "native_menu.hide_tab_bar" : "native_menu.show_tab_bar")
                        : (state.overviewVisible ? "native_menu.exit_tab_overview" : "native_menu.show_all_tabs")
                } else {
                    guard let owned = commands[actionName] else { continue }
                    key = owned
                }
                let translated = title(key)
                if command.title != translated { command.title = translated }
            }
        }
    }
}
