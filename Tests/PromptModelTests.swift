import XCTest
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
