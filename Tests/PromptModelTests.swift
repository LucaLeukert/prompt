import XCTest
import AppKit
import Combine
@testable import Prompt

final class PromptModelTests: XCTestCase {
    @MainActor private static let integrationRuntime = PromptTerminalRuntime()

    private func session() -> PromptSession {
        PromptSession(title: "Project", configuration: .local(.init(workingDirectory: "/tmp")), rootPane: PromptPane())
    }

    func testWorkspaceFocusTracksInsertionAndRemoval() {
        var workspace = PromptWorkspace(name: "Work")
        let first = session()
        let second = session()
        workspace.append(first)
        workspace.append(second)
        XCTAssertEqual(workspace.focusedSessionID, second.id)
        workspace.removeSession(id: second.id)
        XCTAssertEqual(workspace.focusedSessionID, first.id)
    }

    @MainActor
    func testTerminalFocusRoutingPreservesEditableTextControls() {
        let textView = NSTextView()
        textView.isEditable = true
        XCTAssertTrue(PromptKeyboardFocusRouting.preservesEditableControl(textView))
        textView.isEditable = false
        XCTAssertFalse(PromptKeyboardFocusRouting.preservesEditableControl(textView))

        let textField = NSTextField()
        textField.isEditable = true
        textField.isEnabled = true
        XCTAssertTrue(PromptKeyboardFocusRouting.preservesEditableControl(textField))
        textField.isEnabled = false
        XCTAssertFalse(PromptKeyboardFocusRouting.preservesEditableControl(textField))

        XCTAssertFalse(PromptKeyboardFocusRouting.preservesEditableControl(NSButton()))
    }

    @MainActor
    func testClosingFocusedSessionSelectsRemainingSession() throws {
        let runtime = Self.integrationRuntime
        let store = PromptWorkspaceStore(runtime: runtime)
        let local = try XCTUnwrap(store.createLocal(directory: NSTemporaryDirectory(), title: "Local"))
        let second = try XCTUnwrap(store.createLocal(directory: NSTemporaryDirectory(), title: "Second"))

        store.closeSession(second.id)

        XCTAssertEqual(store.workspace.sessions.map(\.id), [local.id])
        XCTAssertEqual(store.workspace.focusedSessionID, local.id)
        XCTAssertNotNil(runtime.surface(for: local.focusedPaneID))
        XCTAssertNil(runtime.surface(for: second.focusedPaneID))
    }

    func testSessionSplitsFocusesAndClosesPanes() {
        var value = session()
        let original = value.focusedPaneID
        let second = PromptPane(title: "Logs")
        XCTAssertTrue(value.splitFocused(axis: .horizontal, newPane: second))
        XCTAssertEqual(value.splitTree.panes.map(\.id), [original, second.id])
        XCTAssertEqual(value.focusedPaneID, second.id)
        XCTAssertTrue(value.closeFocusedPane())
        XCTAssertEqual(value.splitTree.panes.map(\.id), [original])
        XCTAssertFalse(value.closeFocusedPane())
    }

    func testRestoredSessionCollapsesToFocusedPane() {
        var value = session()
        let second = PromptPane(title: "Logs")
        XCTAssertTrue(value.splitFocused(axis: .horizontal, newPane: second))

        value.collapseToFocusedPane()

        XCTAssertEqual(value.splitTree.panes.map(\.id), [second.id])
        XCTAssertEqual(value.focusedPaneID, second.id)
    }

    func testRestorationRoundTrip() throws {
        let workspace = PromptWorkspace(name: "Restored", sessions: [session()])
        let state = PromptRestorationState(workspaces: [workspace], selectedWorkspaceID: workspace.id, windowFrame: "{{0,0},{800,600}}")
        XCTAssertEqual(try JSONDecoder().decode(PromptRestorationState.self, from: JSONEncoder().encode(state)), state)
    }

    func testPromptPathsKeepConfigurationAndCacheUnderPromptHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = PromptPaths(homeDirectory: home)

        try paths.prepare()

        XCTAssertEqual(paths.settings.path, home.appendingPathComponent(".prompt/config.json").path)
        XCTAssertEqual(paths.cacheFile("example.cache").path, home.appendingPathComponent(".prompt/cache/example.cache").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.cache.path))
        try? FileManager.default.removeItem(at: home)
    }

    func testPromptSettingsRoundTripsValuesAndMigratesLegacyDefaults() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PromptModelTests.Settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        defaults.set(["legacy"], forKey: "hosts")
        let paths = PromptPaths(homeDirectory: home)
        let settings = PromptSettings(paths: paths, legacyDefaults: [defaults])

        let hosts: [String]? = settings.value(forKey: "hosts")
        settings.set(["enabled": true], forKey: "features")
        let reloaded = PromptSettings(paths: paths, legacyDefaults: [])
        let features: [String: Bool]? = reloaded.value(forKey: "features")

        XCTAssertEqual(hosts, ["legacy"])
        XCTAssertNil(defaults.object(forKey: "hosts"))
        XCTAssertEqual(features, ["enabled": true])
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(contentsOf: paths.settings)))
    }

    func testPromptSettingsRetainsLegacyValueWhenMigrationCannotBeWritten() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PromptModelTests.FailedMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: home.appendingPathComponent(".prompt"))
        defaults.set("legacy", forKey: "setting")

        let settings = PromptSettings(paths: PromptPaths(homeDirectory: home), legacyDefaults: [defaults])
        let migrated: String? = settings.value(forKey: "setting")

        XCTAssertEqual(migrated, "legacy")
        XCTAssertEqual(defaults.string(forKey: "setting"), "legacy")
    }

    func testPromptSettingsSearchesAllLegacyDefaultsDomains() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstSuite = "PromptModelTests.FirstDefaults.\(UUID().uuidString)"
        let ghosttySuite = "PromptModelTests.GhosttyDefaults.\(UUID().uuidString)"
        let first = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
        let ghostty = try XCTUnwrap(UserDefaults(suiteName: ghosttySuite))
        defer {
            first.removePersistentDomain(forName: firstSuite)
            ghostty.removePersistentDomain(forName: ghosttySuite)
            try? FileManager.default.removeItem(at: home)
        }
        ghostty.set(true, forKey: "ghostty-setting")

        let settings = PromptSettings(
            paths: PromptPaths(homeDirectory: home),
            legacyDefaults: [first, ghostty])
        let migrated: Bool? = settings.value(forKey: "ghostty-setting")

        XCTAssertEqual(migrated, true)
        XCTAssertNil(ghostty.object(forKey: "ghostty-setting"))
    }

    func testPromptSettingsNeverOverwritesMalformedConfiguration() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PromptModelTests.MalformedConfig.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        let paths = PromptPaths(homeDirectory: home)
        try paths.prepare()
        let malformed = Data(#"{"valid":"value","broken":"#.utf8)
        try malformed.write(to: paths.settings)
        defaults.set("legacy", forKey: "legacy-setting")

        let settings = PromptSettings(paths: paths, legacyDefaults: [defaults])
        settings.set("new", forKey: "new-setting")
        let legacy: String? = settings.value(forKey: "legacy-setting")

        XCTAssertEqual(legacy, "legacy")
        XCTAssertEqual(defaults.string(forKey: "legacy-setting"), "legacy")
        XCTAssertEqual(try Data(contentsOf: paths.settings), malformed)
    }

    func testRemoteConfigurationRoundTrip() throws {
        let remote = PromptRemoteSessionConfiguration(destination: "host", workingDirectory: "/srv/app", persistentSessionName: "prompt", attachOnly: true)
        let value = PromptSessionConfiguration.remote(remote)
        XCTAssertEqual(try JSONDecoder().decode(PromptSessionConfiguration.self, from: JSONEncoder().encode(value)), value)
    }

    @MainActor
    func testTerminalSurfaceAbstractionHasStableIdentityAndLifecycle() throws {
        let runtime = Self.integrationRuntime
        let pane = PromptPane(title: "Adapter")
        let configuration = PromptSessionConfiguration.local(.init(workingDirectory: NSTemporaryDirectory()))
        let surface = try XCTUnwrap(runtime.createSurface(for: pane, configuration: configuration))

        XCTAssertTrue(surface === PromptTerminalSurface.wrap(surface.hostedView))
        XCTAssertTrue(surface.nativeView === surface.hostedView)
        XCTAssertNotNil(surface.surfaceHandle)
        XCTAssertFalse(surface.isAlternateScreen)

        runtime.close(paneID: pane.id)
        XCTAssertNil(runtime.surface(for: pane.id))
    }

    @MainActor
    func testWorkspaceStoreCreatesSplitsFocusesAndClosesLocalSession() throws {
        let runtime = Self.integrationRuntime
        let store = PromptWorkspaceStore(runtime: runtime)
        let session = try XCTUnwrap(store.createLocal(directory: NSTemporaryDirectory(), title: "Local"))
        let original = session.focusedPaneID
        XCTAssertNotNil(runtime.surface(for: original))

        store.splitFocused(axis: .horizontal)
        let splitSession = try XCTUnwrap(store.workspace.sessions.first)
        XCTAssertEqual(splitSession.splitTree.paneCount, 2)
        XCTAssertNotEqual(splitSession.focusedPaneID, original)
        XCTAssertNotNil(runtime.surface(for: splitSession.focusedPaneID))

        store.focus(sessionID: splitSession.id, paneID: original)
        XCTAssertEqual(store.workspace.sessions.first?.focusedPaneID, original)
        store.closeFocusedPane()
        XCTAssertEqual(store.workspace.sessions.first?.splitTree.paneCount, 1)
        XCTAssertNil(runtime.surface(for: original))
    }

    @MainActor
    func testWorkspaceStorePublishesSessionFocusChanges() throws {
        let runtime = Self.integrationRuntime
        let store = PromptWorkspaceStore(runtime: runtime)
        let first = try XCTUnwrap(store.createLocal(directory: NSTemporaryDirectory(), title: "First"))
        _ = try XCTUnwrap(store.createLocal(directory: NSTemporaryDirectory(), title: "Second"))
        var changes = 0
        let observation = store.objectWillChange.sink { changes += 1 }

        store.focus(sessionID: first.id, paneID: first.focusedPaneID)

        XCTAssertEqual(store.workspace.focusedSessionID, first.id)
        XCTAssertEqual(changes, 1)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testWorkspaceStoreCreatesRemoteSessionWithPersistentConfiguration() throws {
        let runtime = Self.integrationRuntime
        let store = PromptWorkspaceStore(runtime: runtime)
        let configuration = PromptRemoteSessionConfiguration(
            destination: "example.invalid",
            workingDirectory: "/srv/project",
            persistentSessionName: "prompt-test",
            attachOnly: false)
        let session = try XCTUnwrap(store.createRemote(configuration, title: "Remote"))
        XCTAssertEqual(session.configuration, .remote(configuration))
        XCTAssertNotNil(runtime.surface(for: session.focusedPaneID))
        runtime.close(paneID: session.focusedPaneID)
    }
}
