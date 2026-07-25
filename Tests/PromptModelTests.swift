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

    func testPaletteFocusLossDoesNotDismissDuringInternalNavigation() {
        XCTAssertFalse(PromptPaletteFocusLossPolicy.shouldDismiss(
            focused: false,
            dismissOnFocusLoss: true,
            suppressesFocusLoss: true))
        XCTAssertTrue(PromptPaletteFocusLossPolicy.shouldDismiss(
            focused: false,
            dismissOnFocusLoss: true,
            suppressesFocusLoss: false))
    }

    func testPaletteSubmitGateSuppressesRedispatchedReturn() {
        var gate = PromptPaletteSubmitGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        gate.reset()
        XCTAssertTrue(gate.begin())
    }

    func testPalettePointerOnlyOverridesKeyboardSelectionAfterPhysicalMovement() {
        let anchor = CGPoint(x: 240, y: 180)
        XCTAssertFalse(PromptPalettePointerPolicy.hasMoved(from: anchor, to: anchor))
        XCTAssertFalse(PromptPalettePointerPolicy.hasMoved(
            from: anchor,
            to: CGPoint(x: 240.4, y: 180.4)))
        XCTAssertTrue(PromptPalettePointerPolicy.hasMoved(
            from: anchor,
            to: CGPoint(x: 241, y: 180)))
        XCTAssertTrue(PromptPalettePointerPolicy.hasMoved(
            from: nil,
            to: anchor))
    }

    func testFolderPickerResolvesDisplayPathsBeforeLaunching() {
        XCTAssertEqual(
            PromptFolderPath.resolve("~/"),
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        XCTAssertEqual(PromptFolderPath.resolve("  /tmp/../tmp  "), "/tmp")
        XCTAssertNil(PromptFolderPath.resolve(" \n "))
        XCTAssertEqual(
            PromptFolderPath.existingDirectory("~/"),
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        XCTAssertNil(PromptFolderPath.existingDirectory("/definitely/not/a/prompt/directory"))
    }

    func testFolderPickerUsesExistingParentForPartialDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-folder-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            PromptFolderPath.browsingContext(root.appendingPathComponent("new-folder").path),
            .init(directory: root.path, query: "new-folder", exists: false))
        XCTAssertEqual(
            PromptFolderPath.browsingContext(root.path),
            .init(directory: root.path, query: "", exists: true))
    }

    @MainActor
    func testFolderPickerExposesMacOSVolumesAtFilesystemRoot() {
        guard FileManager.default.fileExists(atPath: "/Volumes") else { return }
        XCTAssertTrue(PromptSessionLauncher.localDirectories(at: "/").contains {
            $0.path == "/Volumes" && $0.name == "Volumes"
        })
    }

    func testFolderPickerBackspaceDependsOnKeyboardMode() {
        XCTAssertTrue(PromptFolderPickerKeyboardPolicy.shouldNavigateToParent(
            isListNavigationActive: true))
        XCTAssertFalse(PromptFolderPickerKeyboardPolicy.shouldNavigateToParent(
            isListNavigationActive: false))
    }

    func testFolderPickerDefaultsToFirstFolderUnlessNavigatingUp() {
        XCTAssertEqual(PromptFolderPickerSelectionPolicy.defaultIndex(
            hasParent: true,
            entryCount: 3,
            prefersParent: false), 1)
        XCTAssertEqual(PromptFolderPickerSelectionPolicy.defaultIndex(
            hasParent: false,
            entryCount: 3,
            prefersParent: false), 0)
        XCTAssertEqual(PromptFolderPickerSelectionPolicy.defaultIndex(
            hasParent: true,
            entryCount: 3,
            prefersParent: true), 0)
        XCTAssertEqual(PromptFolderPickerSelectionPolicy.defaultIndex(
            hasParent: true,
            entryCount: 0,
            prefersParent: false), 0)
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

    func testLegacyLocalConfigurationDefaultsToStandardBehavior() throws {
        let json = #"{"workingDirectory":"/tmp","command":null,"environment":{}}"#
        let configuration = try JSONDecoder().decode(PromptLocalSessionConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(configuration.behavior, .standard)
    }

    func testAnchoredLocalConfigurationRoundTrip() throws {
        let configuration = PromptLocalSessionConfiguration(
            workingDirectory: "/tmp/build",
            behavior: .anchored)
        XCTAssertEqual(
            try JSONDecoder().decode(
                PromptLocalSessionConfiguration.self,
                from: JSONEncoder().encode(configuration)),
            configuration)
    }

    func testAllLocalSessionTypesRoundTripWithDetails() throws {
        for behavior in PromptLocalSessionConfiguration.Behavior.allTestCases {
            let configuration = PromptLocalSessionConfiguration(
                workingDirectory: "/tmp/project",
                command: "printf '%s' done",
                environment: ["PROMPT_TEST": "it's safe"],
                behavior: behavior,
                details: .init(
                    repository: "/tmp/project",
                    branch: "feature/session-types",
                    worktreePath: "/tmp/worktree",
                    worktreeOwnership: .external,
                    scratchDirectory: "/tmp/dev.prompt.scratch/00000000-0000-0000-0000-000000000000",
                    container: "app"),
                lastExitCode: behavior == .task ? 0 : nil)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    PromptLocalSessionConfiguration.self,
                    from: JSONEncoder().encode(configuration)),
                configuration)
        }
    }

    func testEnvironmentLaunchCommandQuotesValuesAndRejectsUnsafeKeys() {
        let configuration = PromptLocalSessionConfiguration(
            workingDirectory: "/tmp",
            command: "printf done",
            environment: ["SAFE_KEY": "it's here", "BAD-NAME": "ignored"])
        XCTAssertEqual(
            PromptTerminalRuntime.localLaunchCommand(configuration),
            "env SAFE_KEY='it'\\''s here' /bin/sh -lc 'printf done'")
    }

    func testScratchCleanupOnlyRemovesExactPromptDirectory() throws {
        let fileManager = FileManager.default
        let directory = try PromptLocalSessionLauncher.createScratchDirectory(fileManager: fileManager)
        XCTAssertTrue(fileManager.fileExists(atPath: directory))
        try PromptLocalSessionLauncher.cleanupScratchDirectory(directory, fileManager: fileManager)
        XCTAssertFalse(fileManager.fileExists(atPath: directory))

        XCTAssertThrowsError(try PromptLocalSessionLauncher.cleanupScratchDirectory(
            fileManager.temporaryDirectory.path,
            fileManager: fileManager))
    }

    func testProjectRootAndAgentStyleWorktreeAreDiscoveredFromGitMetadata() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-git-\(UUID().uuidString)")
        let root = base.appendingPathComponent("repository")
        let agentWorktree = base.appendingPathComponent(".t3/worktrees/prompt/t3code-b4ebbdd0")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path, "worktree", "remove", "--force", agentWorktree.path]
            try? process.run()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: base)
        }
        try runGit(["init", "-q"], in: root)
        try runGit(["config", "user.email", "prompt@example.test"], in: root)
        try runGit(["config", "user.name", "Prompt Tests"], in: root)
        try "test".write(to: root.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try runGit(["add", "README"], in: root)
        try runGit(["commit", "-qm", "initial"], in: root)
        try runGit(["worktree", "add", "-qb", "agent/test", agentWorktree.path], in: root)

        let resolvedProject = PromptLocalSessionLauncher.projectRoot(containing: agentWorktree.path)
        XCTAssertTrue(resolvedProject.hasSuffix("/.t3/worktrees/prompt/t3code-b4ebbdd0"))
        let values = try PromptLocalSessionLauncher.worktrees(containing: agentWorktree.path)
        XCTAssertTrue(values.contains {
            $0.path.hasSuffix("/.t3/worktrees/prompt/t3code-b4ebbdd0")
                && $0.branch == "agent/test"
                && $0.repository.hasSuffix("/repository")
        })
        let locations = PromptLocalSessionLauncher.gitLocations(searching: base.path)
        XCTAssertEqual(locations.count, 2)
        XCTAssertTrue(locations.contains {
            $0.isMainWorktree && $0.repository.hasSuffix("/repository")
        })
        XCTAssertTrue(locations.contains {
            !$0.isMainWorktree
                && $0.branch == "agent/test"
                && $0.path.hasSuffix("/.t3/worktrees/prompt/t3code-b4ebbdd0")
        })
    }

    func testGitDiscoveryIncludesSeedRepositoriesOutsideSearchScope() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-git-seed-\(UUID().uuidString)")
        let search = base.appendingPathComponent("search")
        let repository = base.appendingPathComponent("elsewhere/repository")
        try FileManager.default.createDirectory(at: search, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try runGit(["init", "-q"], in: repository)

        let locations = PromptLocalSessionLauncher.gitLocations(
            searching: search.path,
            seeds: [repository.path])

        XCTAssertEqual(locations.count, 1)
        XCTAssertTrue(locations[0].path.hasSuffix("/elsewhere/repository"))
        XCTAssertTrue(locations[0].isMainWorktree)
    }

    func testGitDiscoveryTraversesNestedProjectDirectories() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-git-bounded-\(UUID().uuidString)")
        let parent = base.appendingPathComponent("projects")
        let repository = parent.appendingPathComponent("nested/repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try runGit(["init", "-q"], in: repository)

        let locations = PromptLocalSessionLauncher.gitLocations(searching: parent.path)
        XCTAssertEqual(locations.count, 1)
        XCTAssertTrue(locations[0].path.hasSuffix("/projects/nested/repository"))
    }

    func testGitDiscoveryStopsAtItsDepthLimit() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-git-depth-\(UUID().uuidString)")
        let repository = base.appendingPathComponent("one/two/three/four/five/repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try runGit(["init", "-q"], in: repository)

        XCTAssertTrue(PromptLocalSessionLauncher.gitLocations(searching: base.path).isEmpty)
    }

    @MainActor
    func testGitDiscoveryCacheUsesPromptCacheAndRemovesStaleSelections() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-git-cache-\(UUID().uuidString)")
        let paths = PromptPaths(homeDirectory: home)
        defer { try? FileManager.default.removeItem(at: home) }
        let missing = PromptLocalSessionLauncher.GitLocation(
            path: "/missing/worktree",
            repository: "/missing/repository",
            branch: "cached",
            isMainWorktree: false)

        PromptSessionLauncher.rememberGitLocations([missing], paths: paths)
        XCTAssertEqual(
            PromptSessionLauncher.cachedGitLocations(paths: paths),
            [missing])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.cacheFile("git-locations.json").path))
        XCTAssertEqual(
            PromptLocalSessionLauncher.gitLocations(
                searching: "/definitely/missing",
                cached: PromptSessionLauncher.cachedGitLocations(paths: paths)),
            [missing])

        PromptSessionLauncher.forgetCachedGitLocation(missing.path, paths: paths)
        XCTAssertTrue(PromptSessionLauncher.cachedGitLocations(paths: paths).isEmpty)
    }

    func testContainerAndPrivilegedCommandsUseShellQuoting() {
        XCTAssertTrue(PromptLocalSessionLauncher.containerCommand(identity: "app name").contains("'app name'"))
        XCTAssertTrue(PromptLocalSessionLauncher.composeCommand(service: "web worker").contains("'web worker'"))
        XCTAssertTrue(PromptLocalSessionLauncher.privilegedCommand("echo it's ready").contains("'echo it'\\''s ready'"))
    }

    func testExecutableDiscoveryUsesStandardPathsWithoutInheritedShellPath() throws {
        let executable = try XCTUnwrap(PromptLocalSessionLauncher.executable(named: "sh", searchPath: ""))
        XCTAssertTrue(executable == "/usr/bin/sh" || executable == "/bin/sh")
    }

    func testSessionResetShellQuotesCreationDirectory() {
        XCTAssertEqual(
            PromptWorkspaceStore.shellQuote("/tmp/it's here"),
            "'/tmp/it'\\''s here'")
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

    func testPromptSettingsRoundTripsValues() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = PromptPaths(homeDirectory: home)
        let settings = PromptSettings(paths: paths)

        settings.set(["local"], forKey: "hosts")
        settings.set(["enabled": true], forKey: "features")
        let reloaded = PromptSettings(paths: paths)
        let hosts: [String]? = reloaded.value(forKey: "hosts")
        let features: [String: Bool]? = reloaded.value(forKey: "features")

        XCTAssertEqual(hosts, ["local"])
        XCTAssertEqual(features, ["enabled": true])
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(contentsOf: paths.settings)))
    }

    func testPromptSettingsDoesNotReplaceBlockedPromptDirectory() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let marker = Data("not a directory".utf8)
        let promptHome = home.appendingPathComponent(".prompt")
        try marker.write(to: promptHome)

        let settings = PromptSettings(paths: PromptPaths(homeDirectory: home))
        settings.set("new", forKey: "setting")

        XCTAssertEqual(settings.value(String.self, forKey: "setting"), "new")
        XCTAssertEqual(try Data(contentsOf: promptHome), marker)
    }

    func testPromptSettingsNeverOverwritesMalformedConfiguration() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = PromptPaths(homeDirectory: home)
        try paths.prepare()
        let malformed = Data(#"{"valid":"value","broken":"#.utf8)
        try malformed.write(to: paths.settings)

        let settings = PromptSettings(paths: paths)
        settings.set("new", forKey: "new-setting")

        XCTAssertEqual(settings.value(String.self, forKey: "new-setting"), "new")
        XCTAssertEqual(try Data(contentsOf: paths.settings), malformed)
    }

    func testRemoteConfigurationRoundTrip() throws {
        let remote = PromptRemoteSessionConfiguration(destination: "host", workingDirectory: "/srv/app", persistentSessionName: "prompt", attachOnly: true)
        let value = PromptSessionConfiguration.remote(remote)
        XCTAssertEqual(try JSONDecoder().decode(PromptSessionConfiguration.self, from: JSONEncoder().encode(value)), value)
    }

    func testControlModeReadinessGateIsOptional() {
        let remote = PromptRemoteSessionConfiguration(
            destination: "host", workingDirectory: nil,
            persistentSessionName: "prompt", attachOnly: false)
        XCTAssertFalse(PromptRemoteCommand.buildControlMode(remote).contains("remote-ready"))
        XCTAssertTrue(PromptRemoteCommand.buildControlMode(
            remote, readinessFile: "/tmp/remote-ready").contains("'/tmp/remote-ready'"))
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
    func testLocalSurfaceReportsDirectoryChangesForRestoration() async throws {
        let runtime = Self.integrationRuntime
        let pane = PromptPane(title: "Directory")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            runtime.close(paneID: pane.id)
            try? FileManager.default.removeItem(at: root)
        }
        let surface = try XCTUnwrap(runtime.createSurface(
            for: pane,
            configuration: .local(.init(workingDirectory: NSHomeDirectory()))))

        surface.sendText("cd \(root.path)")
        PromptController.pressReturn(on: surface)

        let deadline = ContinuousClock.now + .seconds(2)
        while surface.workingDirectory != root.path, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(surface.workingDirectory, root.path)
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
    func testRestorationSnapshotDoesNotPublishWorkspaceMutation() {
        let store = PromptWorkspaceStore(runtime: Self.integrationRuntime)
        var changes = 0
        let observation = store.objectWillChange.sink { changes += 1 }

        _ = store.workspaceForRestoration()

        XCTAssertEqual(changes, 0)
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

    @MainActor
    func testManagedRemoteStoresUUIDTmuxIdentityInSessionConfiguration() throws {
        let runtime = Self.integrationRuntime
        let store = PromptWorkspaceStore(runtime: runtime)
        let requested = PromptRemoteSessionConfiguration(
            destination: "example.invalid",
            workingDirectory: "~",
            persistentSessionName: nil,
            attachOnly: false)

        let session = try XCTUnwrap(store.createRemote(requested, title: "Remote"))
        guard case .remote(let stored) = session.configuration else {
            return XCTFail("Expected remote configuration")
        }
        let identity = try XCTUnwrap(stored.persistentSessionName)
        XCTAssertTrue(PromptSessionLauncher.isSafeSession(identity))
        XCTAssertTrue(identity.hasPrefix("prompt-"))
        runtime.close(paneID: session.focusedPaneID)
    }
}

private extension PromptLocalSessionConfiguration.Behavior {
    static let allTestCases: [Self] = [
        .standard, .anchored, .task, .disposable, .scratch, .project, .worktree, .container, .privileged,
    ]
}

private func runGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw NSError(
            domain: "PromptGitTest",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)])
    }
}
