import Foundation

struct PromptWorkspace: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var sessions: [PromptSession]
    var focusedSessionID: PromptSession.ID?

    init(id: UUID = UUID(), name: String, sessions: [PromptSession] = [], focusedSessionID: PromptSession.ID? = nil) {
        self.id = id
        self.name = name
        self.sessions = sessions
        self.focusedSessionID = focusedSessionID ?? sessions.first?.id
    }

    mutating func append(_ session: PromptSession) {
        sessions.append(session)
        focusedSessionID = session.id
    }

    @discardableResult
    mutating func removeSession(id: PromptSession.ID) -> PromptSession? {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = sessions.remove(at: index)
        if focusedSessionID == id {
            focusedSessionID = sessions.indices.contains(index) ? sessions[index].id : sessions.last?.id
        }
        return removed
    }
}
