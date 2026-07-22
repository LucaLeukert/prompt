import Foundation

struct PromptRestorationState: Codable, Equatable {
    var workspaces: [PromptWorkspace]
    var selectedWorkspaceID: PromptWorkspace.ID?
    var windowFrame: String?
}
