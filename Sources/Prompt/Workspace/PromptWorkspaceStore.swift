import AppKit

@MainActor
final class PromptWorkspaceStore: ObservableObject {
    enum SidebarLayout: String, CaseIterable { case flat, grouped }
    enum SidebarSort: String, CaseIterable { case manual, recent, name }

    @Published var workspace: PromptWorkspace
    let inputRouter = PromptInputRouter()
    @Published var isCommandPalettePresented = false {
        didSet { inputRouter.isOverlayPresented = isCommandPalettePresented }
    }
    @Published var sidebarLayout: SidebarLayout {
        didSet { settings.set(sidebarLayout.rawValue, forKey: "PromptSidebarLayout") }
    }
    @Published var sidebarSort: SidebarSort {
        didSet { settings.set(sidebarSort.rawValue, forKey: "PromptSidebarSort") }
    }
    @Published private(set) var sidebarFolders: [String]
    @Published private(set) var sessionFolders: [PromptSession.ID: String]
    @Published private(set) var sidebarVisualOrder: [PromptSession.ID] = []
    private var sessionRecency: [PromptSession.ID: Date] = [:]
    let runtime: PromptTerminalRuntime
    private let settings: PromptSettings

    init(runtime: PromptTerminalRuntime, settings: PromptSettings = .shared) {
        self.runtime = runtime
        self.settings = settings
        workspace = PromptWorkspace(name: "Workspace")
        sidebarLayout = SidebarLayout(rawValue: settings.value(forKey: "PromptSidebarLayout") ?? "") ?? .flat
        sidebarSort = SidebarSort(rawValue: settings.value(forKey: "PromptSidebarSort") ?? "") ?? .manual
        sidebarFolders = settings.value(forKey: "PromptSidebarFolders") ?? []
        let assignments: [String: String] = settings.value(forKey: "PromptSidebarAssignments") ?? [:]
        sessionFolders = Dictionary(uniqueKeysWithValues: assignments.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        runtime.onRemotePaneInventory = { [weak self] originPaneID, panes in
            self?.reconcileRemotePanes(originPaneID: originPaneID, descriptors: panes)
        }
        runtime.onLocalCommandFinished = { [weak self] paneID, exitCode, childExited in
            self?.localCommandFinished(paneID: paneID, exitCode: exitCode, childExited: childExited)
        }
    }

    @discardableResult
    func createLocal(
        directory: String,
        command: String? = nil,
        title: String? = nil,
        behavior: PromptLocalSessionConfiguration.Behavior = .standard,
        details: PromptLocalSessionDetails? = nil,
        environment: [String: String] = [:]
    ) -> PromptSession? {
        let pane = PromptPane(title: title ?? URL(fileURLWithPath: directory).lastPathComponent)
        let config = PromptSessionConfiguration.local(.init(
            workingDirectory: directory,
            command: command,
            environment: environment,
            behavior: behavior,
            details: details))
        guard runtime.createSurface(for: pane, configuration: config) != nil else {
            PromptLog.sessions.error(
                "Local terminal surface creation failed",
                metadata: ["behavior": "\(behavior.rawValue)"])
            return nil
        }
        resetAnchoredSessionIfNeeded(id: workspace.focusedSessionID)
        let session = PromptSession(title: title ?? pane.title, configuration: config, rootPane: pane)
        updateWorkspace { $0.append(session) }
        PromptLog.sessions.info(
            "Created local session",
            metadata: [
                "behavior": "\(behavior.rawValue)",
                "session_id": "\(session.id.uuidString)",
            ])
        return session
    }

    @discardableResult
    func createRemote(_ requestedConfiguration: PromptRemoteSessionConfiguration, title: String? = nil) -> PromptSession? {
        var config = requestedConfiguration
        if config.transport == .controlMode,
           config.persistentSessionName?.isEmpty != false {
            config.persistentSessionName = PromptSessionLauncher.newRemoteSessionName()
        }
        let pane = PromptPane(title: title ?? config.destination)
        let sessionConfig = PromptSessionConfiguration.remote(config)
        guard runtime.createSurface(for: pane, configuration: sessionConfig) != nil else {
            PromptLog.sessions.error(
                "Remote terminal surface creation failed",
                metadata: ["transport": "\(config.transport.rawValue)"])
            return nil
        }
        resetAnchoredSessionIfNeeded(id: workspace.focusedSessionID)
        let session = PromptSession(title: title ?? config.destination, configuration: sessionConfig, rootPane: pane)
        updateWorkspace { $0.append(session) }
        PromptLog.sessions.info(
            "Created remote session",
            metadata: [
                "session_id": "\(session.id.uuidString)",
                "transport": "\(config.transport.rawValue)",
            ])
        return session
    }

    func splitFocused(axis: PromptSplitAxis) {
        guard let index = workspace.sessions.firstIndex(where: { $0.id == workspace.focusedSessionID }) else { return }
        if runtime.splitRemotePane(workspace.sessions[index].focusedPaneID, axis: axis) { return }
        let pane = PromptPane()
        let config = workspace.sessions[index].configuration
        guard runtime.createSurface(for: pane, configuration: config) != nil else { return }
        updateWorkspace { _ = $0.sessions[index].splitFocused(axis: axis, newPane: pane) }
    }

    func movePane(
        in sessionID: PromptSession.ID,
        sourceSurfaceID: UUID,
        relativeTo targetPaneID: PromptPane.ID,
        zone: PromptPaneDropZone
    ) -> Bool {
        guard let sourcePaneID = runtime.paneID(forSurfaceID: sourceSurfaceID),
              let index = workspace.sessions.firstIndex(where: { $0.id == sessionID }),
              workspace.sessions[index].splitTree.panes.contains(where: { $0.id == sourcePaneID }),
              workspace.sessions[index].splitTree.panes.contains(where: { $0.id == targetPaneID }),
              sourcePaneID != targetPaneID else { return false }

        var updated = workspace
        guard updated.sessions[index].splitTree.move(
            paneID: sourcePaneID,
            relativeTo: targetPaneID,
            zone: zone) else { return false }
        updated.sessions[index].focusedPaneID = sourcePaneID
        workspace = updated
        runtime.surface(for: sourcePaneID)?.focus()
        return true
    }

    func closeFocusedPane() {
        guard let index = workspace.sessions.firstIndex(where: { $0.id == workspace.focusedSessionID }) else { return }
        let paneID = workspace.sessions[index].focusedPaneID
        var updated = workspace
        if updated.sessions[index].closeFocusedPane() {
            workspace = updated
            closeRuntimePane(paneID, terminateRemotePane: true)
        } else {
            _ = updated.removeSession(id: updated.sessions[index].id)
            workspace = updated
            focusCurrentSession()
            closeRuntimePane(paneID)
        }
    }

    func focus(sessionID: PromptSession.ID, paneID: PromptPane.ID) {
        guard updateFocusedPane(sessionID: sessionID, paneID: paneID) else { return }
        runtime.surface(for: paneID)?.focus()
        runtime.focusRemotePane(paneID)
    }

    /// Ghostty consumes the first mouse-down used to transfer focus between
    /// terminal surfaces. Mirror that native focus change into the workspace
    /// model without trying to focus the already-focused surface again.
    func focusFromSurface(sessionID: PromptSession.ID, paneID: PromptPane.ID) {
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
              workspace.focusedSessionID != sessionID || session.focusedPaneID != paneID,
              updateFocusedPane(sessionID: sessionID, paneID: paneID) else { return }
        runtime.focusRemotePane(paneID)
    }

    func resizeSplit(
        in sessionID: PromptSession.ID,
        between firstPaneID: PromptPane.ID,
        and secondPaneID: PromptPane.ID,
        fraction: Double
    ) {
        guard let index = workspace.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        updateWorkspace {
            _ = $0.sessions[index].splitTree.resizeSplit(
                between: firstPaneID,
                and: secondPaneID,
                fraction: fraction)
        }
    }

    var orderedSessions: [PromptSession] {
        switch sidebarSort {
        case .manual: workspace.sessions
        case .recent: workspace.sessions.sorted { sessionRecency[$0.id, default: .distantPast] > sessionRecency[$1.id, default: .distantPast] }
        case .name: workspace.sessions.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    func focusSidebarSession(at index: Int) {
        let ids = sidebarVisualOrder.isEmpty ? orderedSessions.map(\.id) : sidebarVisualOrder
        guard ids.indices.contains(index),
              let session = workspace.sessions.first(where: { $0.id == ids[index] }) else { return }
        focus(sessionID: session.id, paneID: session.focusedPaneID)
    }

    func updateSidebarVisualOrder(_ ids: [PromptSession.ID]) {
        guard sidebarVisualOrder != ids else { return }
        sidebarVisualOrder = ids
    }

    func createSidebarFolder(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !sidebarFolders.contains(name) else { return }
        sidebarFolders.append(name)
        persistSidebarFolders()
    }

    func assignFocusedSession(to folder: String?) {
        guard let id = workspace.focusedSessionID else { return }
        assignSession(id, to: folder)
    }

    func assignSession(_ id: PromptSession.ID, to folder: String?) {
        if let folder { sessionFolders[id] = folder } else { sessionFolders.removeValue(forKey: id) }
        persistSidebarFolders()
    }

    func moveSession(_ id: PromptSession.ID, before targetID: PromptSession.ID?) {
        guard let source = workspace.sessions.firstIndex(where: { $0.id == id }) else { return }
        var updated = workspace
        let session = updated.sessions.remove(at: source)
        let destination = targetID.flatMap { target in updated.sessions.firstIndex(where: { $0.id == target }) } ?? updated.sessions.endIndex
        updated.sessions.insert(session, at: destination)
        workspace = updated
        sidebarSort = .manual
    }

    func renameSession(_ id: PromptSession.ID, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = workspace.sessions.firstIndex(where: { $0.id == id }) else { return }
        updateWorkspace { $0.sessions[index].title = name }
    }

    func closeSession(_ id: PromptSession.ID) {
        guard let session = workspace.sessions.first(where: { $0.id == id }) else { return }
        PromptLog.sessions.info(
            "Closing session",
            metadata: [
                "pane_count": "\(session.splitTree.panes.count)",
                "session_id": "\(id.uuidString)",
            ])
        updateWorkspace { _ = $0.removeSession(id: id) }
        focusCurrentSession()
        session.splitTree.panes.forEach { closeRuntimePane($0.id) }
        sessionFolders.removeValue(forKey: id)
        persistSidebarFolders()
        cleanupOwnedResources(for: session)
    }

    func renameSidebarFolder(_ oldName: String, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != oldName, !sidebarFolders.contains(name),
              let index = sidebarFolders.firstIndex(of: oldName) else { return }
        sidebarFolders[index] = name
        let affected = sessionFolders.compactMap { $0.value == oldName ? $0.key : nil }
        for id in affected { sessionFolders[id] = name }
        persistSidebarFolders()
    }

    func deleteSidebarFolder(_ name: String) {
        sidebarFolders.removeAll { $0 == name }
        sessionFolders = sessionFolders.filter { $0.value != name }
        persistSidebarFolders()
    }

    func folder(for session: PromptSession) -> String? { sessionFolders[session.id] }

    /// Returns a codable snapshot enriched with ephemeral terminal state.
    /// This deliberately does not publish a workspace mutation: persistence is
    /// itself triggered by `$workspace`, so mutating here would recurse.
    func workspaceForRestoration() -> PromptWorkspace {
        var updated = workspace
        for sessionIndex in updated.sessions.indices {
            guard case .local(var configuration) = updated.sessions[sessionIndex].configuration,
                  configuration.behavior == .standard,
                  let directory = runtime.surface(for: updated.sessions[sessionIndex].focusedPaneID)?.workingDirectory,
                  !directory.isEmpty, directory != configuration.workingDirectory else { continue }
            configuration.workingDirectory = directory
            updated.sessions[sessionIndex].configuration = .local(configuration)
        }
        return updated
    }

    private func persistSidebarFolders() {
        settings.set(sidebarFolders, forKey: "PromptSidebarFolders")
        let encoded = sessionFolders.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }
        settings.set(encoded, forKey: "PromptSidebarAssignments")
    }

    private func updateWorkspace(_ update: (inout PromptWorkspace) -> Void) {
        var updated = workspace
        update(&updated)
        workspace = updated
    }

    private func resetAnchoredSessionIfNeeded(id: PromptSession.ID?) {
        guard let id,
              let session = workspace.sessions.first(where: { $0.id == id }),
              case .local(let configuration) = session.configuration,
              configuration.behavior == .anchored else { return }

        let command = "cd -- \(Self.shellQuote(configuration.workingDirectory)) && clear"
        for pane in session.splitTree.panes {
            guard let surface = runtime.surface(for: pane.id) else { continue }
            surface.interruptForegroundProcess()
            surface.sendText(command)
            PromptController.pressReturn(on: surface)
        }
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func localCommandFinished(paneID: PromptPane.ID, exitCode: Int32, childExited: Bool) {
        guard let index = workspace.sessions.firstIndex(where: {
            $0.splitTree.panes.contains(where: { $0.id == paneID })
        }), case .local(var configuration) = workspace.sessions[index].configuration else { return }
        configuration.lastExitCode = exitCode
        updateWorkspace { $0.sessions[index].configuration = .local(configuration) }
        if configuration.behavior == .disposable,
           configuration.command != nil || childExited {
            let sessionID = workspace.sessions[index].id
            // Completion is delivered only after the command has exited. Any
            // password prompt, TTY confirmation, or other interaction keeps
            // the process alive and therefore keeps the session open.
            DispatchQueue.main.async { [weak self] in self?.closeSession(sessionID) }
        }
    }

    private func cleanupOwnedResources(for session: PromptSession) {
        guard case .local(let configuration) = session.configuration else { return }
        if configuration.behavior == .scratch,
           let directory = configuration.details?.scratchDirectory {
            do { try PromptLocalSessionLauncher.cleanupScratchDirectory(directory) }
            catch {
                PromptLog.sessions.error(
                    "Scratch cleanup failed",
                    metadata: ["error": "\(error)"])
            }
        }
        if configuration.behavior == .worktree,
           configuration.details?.worktreeOwnership == .prompt,
           let repository = configuration.details?.repository,
           let path = configuration.details?.worktreePath {
            let worktree = PromptLocalSessionLauncher.Worktree(
                path: path,
                repository: repository,
                branch: configuration.details?.branch,
                isMain: false)
            do { try PromptLocalSessionLauncher.removePromptWorktree(worktree, ownership: .prompt) }
            catch {
                PromptLog.sessions.error(
                    "Worktree cleanup failed",
                    metadata: ["error": "\(error)"])
            }
        }
    }

    private func focusCurrentSession() {
        guard let session = workspace.sessions.first(where: { $0.id == workspace.focusedSessionID }) else { return }
        runtime.surface(for: session.focusedPaneID)?.focus()
        runtime.focusRemotePane(session.focusedPaneID)
    }

    private func closeRuntimePane(_ paneID: PromptPane.ID, terminateRemotePane: Bool = false) {
        // Composite remote surfaces can currently be mounted in the SwiftUI
        // hierarchy. Publish the workspace removal first, then tear them down
        // on the next main-loop turn so AppKit never destroys the active view
        // while handling its close action.
        if runtime.surface(for: paneID)?.isComposite == true {
            DispatchQueue.main.async { [weak runtime] in
                runtime?.close(paneID: paneID, terminateRemotePane: terminateRemotePane)
            }
        } else {
            runtime.close(paneID: paneID, terminateRemotePane: terminateRemotePane)
        }
    }

    private func updateFocusedPane(
        sessionID: PromptSession.ID,
        paneID: PromptPane.ID
    ) -> Bool {
        guard workspace.sessions.contains(where: { $0.id == sessionID }) else { return false }
        if workspace.focusedSessionID != sessionID {
            resetAnchoredSessionIfNeeded(id: workspace.focusedSessionID)
        }
        updateWorkspace {
            $0.focusedSessionID = sessionID
            guard let index = $0.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            $0.sessions[index].focusedPaneID = paneID
        }
        sessionRecency[sessionID] = Date()
        return true
    }

    private func reconcileRemotePanes(
        originPaneID: PromptPane.ID,
        descriptors: [PromptTerminalRuntime.RemotePaneDescriptor]
    ) {
        guard !descriptors.isEmpty,
              let sessionIndex = workspace.sessions.firstIndex(where: {
                  $0.splitTree.panes.contains(where: { $0.id == originPaneID })
              }),
              case .remote(let baseConfiguration) = workspace.sessions[sessionIndex].configuration,
              baseConfiguration.transport == .controlMode else { return }

        var paneByTmuxID: [String: PromptPane] = [:]
        for pane in workspace.sessions[sessionIndex].splitTree.panes {
            if let tmuxID = runtime.remoteTmuxPaneIDs[pane.id] { paneByTmuxID[tmuxID] = pane }
        }
        if paneByTmuxID.isEmpty,
           let active = descriptors.first(where: \.active) ?? descriptors.first,
           let root = workspace.sessions[sessionIndex].splitTree.panes.first {
            runtime.remoteTmuxPaneIDs[root.id] = active.id
            paneByTmuxID[active.id] = root
        }

        for descriptor in descriptors where paneByTmuxID[descriptor.id] == nil {
            let pane = PromptPane(title: descriptor.command)
            var configuration = baseConfiguration
            configuration.workingDirectory = descriptor.workingDirectory
            configuration.tmuxPaneID = descriptor.id
            guard runtime.createSurface(for: pane, configuration: .remote(configuration)) != nil else { continue }
            paneByTmuxID[descriptor.id] = pane
        }

        let liveIDs = Set(descriptors.map(\.id))
        let stalePanes = paneByTmuxID.filter { !liveIDs.contains($0.key) }
        for (tmuxID, pane) in stalePanes {
            runtime.close(paneID: pane.id)
            paneByTmuxID.removeValue(forKey: tmuxID)
        }
        let layoutDescriptors = descriptors.filter { paneByTmuxID[$0.id] != nil }
        guard let tree = Self.makeRemoteSplitTree(layoutDescriptors, panes: paneByTmuxID) else { return }
        var updated = workspace
        updated.sessions[sessionIndex].splitTree = tree
        let currentFocused = updated.sessions[sessionIndex].focusedPaneID
        if !tree.panes.contains(where: { $0.id == currentFocused }),
           let active = descriptors.first(where: \.active), let focused = paneByTmuxID[active.id] {
            updated.sessions[sessionIndex].focusedPaneID = focused.id
        }
        // The remote monitor reports the complete tmux inventory on every
        // poll. Publishing the same tree needlessly rebuilds the SwiftUI
        // hierarchy around its mounted AppKit surfaces. In particular, doing
        // that while the command palette overlay is entering the hierarchy can
        // re-enter AttributeGraph and terminate the process.
        guard updated.sessions[sessionIndex] != workspace.sessions[sessionIndex] else { return }
        workspace = updated
    }

    static func makeRemoteSplitTree(
        _ descriptors: [PromptTerminalRuntime.RemotePaneDescriptor],
        panes: [String: PromptPane]
    ) -> PromptSplitTree? {
        guard let first = descriptors.first, let fallbackPane = panes[first.id] else { return nil }
        guard descriptors.count > 1 else { return .leaf(fallbackPane) }

        let orderedX = descriptors.sorted { $0.left < $1.left }
        for index in 1 ..< orderedX.count {
            let left = Array(orderedX[..<index])
            let right = Array(orderedX[index...])
            let leftEdge = left.map { $0.left + $0.width }.max() ?? 0
            let rightEdge = right.map(\.left).min() ?? 0
            if leftEdge <= rightEdge,
               let lhs = makeRemoteSplitTree(left, panes: panes),
               let rhs = makeRemoteSplitTree(right, panes: panes) {
                let leftWidth = max(1, left.map { $0.left + $0.width }.max()! - left.map(\.left).min()!)
                let rightWidth = max(1, right.map { $0.left + $0.width }.max()! - right.map(\.left).min()!)
                return .split(
                    axis: .horizontal,
                    fraction: Double(leftWidth) / Double(leftWidth + rightWidth),
                    first: lhs,
                    second: rhs)
            }
        }

        let orderedY = descriptors.sorted { $0.top < $1.top }
        for index in 1 ..< orderedY.count {
            let top = Array(orderedY[..<index])
            let bottom = Array(orderedY[index...])
            let topEdge = top.map { $0.top + $0.height }.max() ?? 0
            let bottomEdge = bottom.map(\.top).min() ?? 0
            if topEdge <= bottomEdge,
               let lhs = makeRemoteSplitTree(top, panes: panes),
               let rhs = makeRemoteSplitTree(bottom, panes: panes) {
                let topHeight = max(1, top.map { $0.top + $0.height }.max()! - top.map(\.top).min()!)
                let bottomHeight = max(1, bottom.map { $0.top + $0.height }.max()! - bottom.map(\.top).min()!)
                return .split(
                    axis: .vertical,
                    fraction: Double(topHeight) / Double(topHeight + bottomHeight),
                    first: lhs,
                    second: rhs)
            }
        }

        return descriptors.dropFirst().reduce(PromptSplitTree.leaf(fallbackPane)) { tree, descriptor in
            guard let pane = panes[descriptor.id] else { return tree }
            return .split(axis: .horizontal, fraction: 0.5, first: tree, second: .leaf(pane))
        }
    }
}
