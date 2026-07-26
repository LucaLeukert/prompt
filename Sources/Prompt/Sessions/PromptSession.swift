import Foundation

enum PromptAgentCommand {
    /// Ghostty starts explicit commands through a non-login shell, so it
    /// cannot rely on a user's shell profile to add Homebrew to PATH.
    static var codex: String {
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "codex"
    }
}

extension String {
    /// A presentation-only path form. Commands and persistence continue using
    /// the original absolute value.
    var promptDisplayPath: String {
        let localHome = FileManager.default.homeDirectoryForCurrentUser.path
        if self == localHome { return "~/" }
        if hasPrefix(localHome + "/") { return "~/" + dropFirst(localHome.count + 1) }

        // Remote Unix homes aren't necessarily the same as the local account.
        // Recognize the standard user-home layouts without changing root-level
        // paths that merely happen to contain the same text later on.
        if let match = range(of: #"^/(?:home|Users)/[^/]+(?:/|$)"#, options: .regularExpression) {
            let suffix = self[match.upperBound...]
            return suffix.isEmpty ? "~/" : "~/" + suffix
        }
        if self == "/root" { return "~/" }
        if hasPrefix("/root/") { return "~/" + dropFirst(6) }
        return self
    }
}

enum PromptSessionConfiguration: Codable, Equatable {
    case local(PromptLocalSessionConfiguration)
    case remote(PromptRemoteSessionConfiguration)
}

struct PromptLocalSessionConfiguration: Codable, Equatable {
    enum Behavior: String, Codable {
        case standard
        case anchored
        case task
        case disposable
        case scratch
        case project
        case worktree
        case container
        case privileged
    }

    var workingDirectory: String
    var command: String?
    var environment: [String: String]
    var behavior: Behavior
    var details: PromptLocalSessionDetails?
    var lastExitCode: Int32?

    init(
        workingDirectory: String,
        command: String? = nil,
        environment: [String: String] = [:],
        behavior: Behavior = .standard,
        details: PromptLocalSessionDetails? = nil,
        lastExitCode: Int32? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.environment = environment
        self.behavior = behavior
        self.details = details
        self.lastExitCode = lastExitCode
    }

    private enum CodingKeys: String, CodingKey {
        case workingDirectory, command, environment, behavior, details, lastExitCode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workingDirectory = try values.decode(String.self, forKey: .workingDirectory)
        command = try values.decodeIfPresent(String.self, forKey: .command)
        environment = try values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        behavior = try values.decodeIfPresent(Behavior.self, forKey: .behavior) ?? .standard
        details = try values.decodeIfPresent(PromptLocalSessionDetails.self, forKey: .details)
        lastExitCode = try values.decodeIfPresent(Int32.self, forKey: .lastExitCode)
    }
}

struct PromptLocalSessionDetails: Codable, Equatable {
    enum Ownership: String, Codable {
        case prompt
        case external
    }

    var repository: String?
    var branch: String?
    var worktreePath: String?
    var worktreeOwnership: Ownership?
    var scratchDirectory: String?
    var container: String?
    var composeService: String?

    init(
        repository: String? = nil,
        branch: String? = nil,
        worktreePath: String? = nil,
        worktreeOwnership: Ownership? = nil,
        scratchDirectory: String? = nil,
        container: String? = nil,
        composeService: String? = nil
    ) {
        self.repository = repository
        self.branch = branch
        self.worktreePath = worktreePath
        self.worktreeOwnership = worktreeOwnership
        self.scratchDirectory = scratchDirectory
        self.container = container
        self.composeService = composeService
    }
}

struct PromptRemoteSessionConfiguration: Codable, Equatable {
    var destination: String
    var workingDirectory: String?
    var persistentSessionName: String?
    var attachOnly: Bool
    var transport: PromptRemoteTransport = .controlMode
    var tmuxPaneID: String?

    init(
        destination: String,
        workingDirectory: String?,
        persistentSessionName: String?,
        attachOnly: Bool,
        transport: PromptRemoteTransport = .controlMode,
        tmuxPaneID: String? = nil
    ) {
        self.destination = destination
        self.workingDirectory = workingDirectory
        self.persistentSessionName = persistentSessionName
        self.attachOnly = attachOnly
        self.transport = transport
        self.tmuxPaneID = tmuxPaneID
    }

    private enum CodingKeys: String, CodingKey {
        case destination, workingDirectory, persistentSessionName, attachOnly, transport, tmuxPaneID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        destination = try values.decode(String.self, forKey: .destination)
        workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory)
        persistentSessionName = try values.decodeIfPresent(String.self, forKey: .persistentSessionName)
        attachOnly = try values.decode(Bool.self, forKey: .attachOnly)
        transport = try values.decodeIfPresent(PromptRemoteTransport.self, forKey: .transport) ?? .controlMode
        tmuxPaneID = try values.decodeIfPresent(String.self, forKey: .tmuxPaneID)
    }
}

enum PromptRemoteTransport: String, Codable, Equatable {
    case controlMode
    case legacyTTY
}

struct PromptSession: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var configuration: PromptSessionConfiguration
    var splitTree: PromptSplitTree
    var focusedPaneID: PromptPane.ID

    init(id: UUID = UUID(), title: String, configuration: PromptSessionConfiguration, rootPane: PromptPane) {
        self.id = id
        self.title = title
        self.configuration = configuration
        self.splitTree = .leaf(rootPane)
        self.focusedPaneID = rootPane.id
    }

    mutating func splitFocused(axis: PromptSplitAxis, newPane: PromptPane, placingNewPaneAfter: Bool = true) -> Bool {
        guard splitTree.split(paneID: focusedPaneID, axis: axis, newPane: newPane, placingNewPaneAfter: placingNewPaneAfter) else { return false }
        focusedPaneID = newPane.id
        return true
    }

    mutating func closeFocusedPane() -> Bool {
        guard splitTree.paneCount > 1, let replacement = splitTree.remove(paneID: focusedPaneID) else { return false }
        splitTree = replacement
        focusedPaneID = splitTree.panes.first!.id
        return true
    }

    mutating func collapseToFocusedPane() {
        guard let pane = splitTree.panes.first(where: { $0.id == focusedPaneID }) ?? splitTree.panes.first else { return }
        splitTree = .leaf(pane)
        focusedPaneID = pane.id
    }
}
