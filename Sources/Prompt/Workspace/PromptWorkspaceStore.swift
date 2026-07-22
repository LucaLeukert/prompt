import AppKit

@MainActor
final class PromptWorkspaceStore: ObservableObject {
    enum SidebarLayout: String, CaseIterable { case flat, grouped }
    enum SidebarSort: String, CaseIterable { case manual, recent, name }

    @Published var workspace: PromptWorkspace
    @Published var isCommandPalettePresented = false
    @Published var sidebarLayout: SidebarLayout {
        didSet { UserDefaults.standard.set(sidebarLayout.rawValue, forKey: "PromptSidebarLayout") }
    }
    @Published var sidebarSort: SidebarSort {
        didSet { UserDefaults.standard.set(sidebarSort.rawValue, forKey: "PromptSidebarSort") }
    }
    @Published private(set) var sidebarFolders: [String]
    @Published private(set) var sessionFolders: [PromptSession.ID: String]
    @Published private(set) var sidebarVisualOrder: [PromptSession.ID] = []
    private var sessionRecency: [PromptSession.ID: Date] = [:]
    let runtime: PromptTerminalRuntime

    init(runtime: PromptTerminalRuntime) {
        self.runtime = runtime
        workspace = PromptWorkspace(name: "Workspace")
        sidebarLayout = SidebarLayout(rawValue: UserDefaults.standard.string(forKey: "PromptSidebarLayout") ?? "") ?? .flat
        sidebarSort = SidebarSort(rawValue: UserDefaults.standard.string(forKey: "PromptSidebarSort") ?? "") ?? .manual
        sidebarFolders = UserDefaults.standard.stringArray(forKey: "PromptSidebarFolders") ?? []
        let assignments = UserDefaults.standard.dictionary(forKey: "PromptSidebarAssignments") as? [String: String] ?? [:]
        sessionFolders = Dictionary(uniqueKeysWithValues: assignments.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        runtime.onRemotePaneInventory = { [weak self] originPaneID, panes in
            self?.reconcileRemotePanes(originPaneID: originPaneID, descriptors: panes)
        }
    }

    @discardableResult
    func createLocal(directory: String, command: String? = nil, title: String? = nil) -> PromptSession? {
        let pane = PromptPane(title: title ?? URL(fileURLWithPath: directory).lastPathComponent)
        let config = PromptSessionConfiguration.local(.init(workingDirectory: directory, command: command))
        guard runtime.createSurface(for: pane, configuration: config) != nil else { return nil }
        let session = PromptSession(title: title ?? pane.title, configuration: config, rootPane: pane)
        updateWorkspace { $0.append(session) }
        return session
    }

    @discardableResult
    func createRemote(_ config: PromptRemoteSessionConfiguration, title: String? = nil) -> PromptSession? {
        let pane = PromptPane(title: title ?? config.destination)
        let sessionConfig = PromptSessionConfiguration.remote(config)
        guard runtime.createSurface(for: pane, configuration: sessionConfig) != nil else { return nil }
        let session = PromptSession(title: title ?? config.destination, configuration: sessionConfig, rootPane: pane)
        updateWorkspace { $0.append(session) }
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
        guard workspace.sessions.contains(where: { $0.id == sessionID }) else { return }
        updateWorkspace {
            $0.focusedSessionID = sessionID
            guard let index = $0.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            $0.sessions[index].focusedPaneID = paneID
        }
        runtime.surface(for: paneID)?.focus()
        runtime.focusRemotePane(paneID)
        sessionRecency[sessionID] = Date()
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
        updateWorkspace { _ = $0.removeSession(id: id) }
        focusCurrentSession()
        session.splitTree.panes.forEach { closeRuntimePane($0.id) }
        sessionFolders.removeValue(forKey: id)
        persistSidebarFolders()
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

    private func persistSidebarFolders() {
        UserDefaults.standard.set(sidebarFolders, forKey: "PromptSidebarFolders")
        let encoded = sessionFolders.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }
        UserDefaults.standard.set(encoded, forKey: "PromptSidebarAssignments")
    }

    private func updateWorkspace(_ update: (inout PromptWorkspace) -> Void) {
        var updated = workspace
        update(&updated)
        workspace = updated
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
        workspace = updated
    }

    static func makeRemoteSplitTree(
        _ descriptors: [PromptTerminalRuntime.RemotePaneDescriptor],
        panes: [String: PromptPane]
    ) -> PromptSplitTree? {
        guard let first = descriptors.first, let fallbackPane = panes[first.id] else { return nil }
        guard descriptors.count > 1 else { return .leaf(fallbackPane) }

        let orderedX = descriptors.sorted { $0.left < $1.left }
        for index in 1..<orderedX.count {
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
        for index in 1..<orderedY.count {
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
