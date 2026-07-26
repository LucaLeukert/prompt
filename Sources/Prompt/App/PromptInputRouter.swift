import AppKit
import Combine

@MainActor
final class PromptInputRouter: ObservableObject {
    enum Command: Equatable {
        case moveUp
        case moveDown
        case submit
        case back
        case delete
        case actions
        case textInput
    }

    enum Disposition: Equatable {
        case consume
        case focusedControl
        case activeSession
    }

    private struct Owner {
        let id: UUID
        let acceptsTextInput: Bool
        let focusInput: (() -> Void)?
        let handler: (Command) -> Bool
    }

    private var owners: [Owner] = []
    private var sessionInterceptors: [(id: UUID, handler: (NSEvent) -> Bool)] = []
    var isOverlayPresented = false {
        didSet {
            if !isOverlayPresented { owners.removeAll() }
        }
    }
    @Published private(set) var isCommandKeyPressed = false

    var hasOwner: Bool { !owners.isEmpty }
    var ownerCount: Int { owners.count }

    func claim(
        owner id: UUID,
        acceptsTextInput: Bool = false,
        focusInput: (() -> Void)? = nil,
        handler: @escaping (Command) -> Bool
    ) {
        owners.removeAll { $0.id == id }
        owners.append(Owner(
            id: id,
            acceptsTextInput: acceptsTextInput,
            focusInput: focusInput,
            handler: handler))
    }

    func release(owner id: UUID) {
        owners.removeAll { $0.id == id }
    }

    func dispatch(_ command: Command) -> Bool {
        owners.last?.handler(command) == true
    }

    func claimSessionInterceptor(owner id: UUID, handler: @escaping (NSEvent) -> Bool) {
        sessionInterceptors.removeAll { $0.id == id }
        sessionInterceptors.append((id, handler))
    }

    func releaseSessionInterceptor(owner id: UUID) {
        sessionInterceptors.removeAll { $0.id == id }
    }

    func route(_ event: NSEvent, editableControlIsFocused: Bool) -> Disposition {
        isCommandKeyPressed = event.modifierFlags.contains(.command)
        if let owner = owners.last {
            if event.type == .keyDown, let command = command(for: event) {
                let handled = owner.handler(command)
                if command == .delete, !handled, owner.acceptsTextInput {
                    owner.focusInput?()
                    return .focusedControl
                }
                return .consume
            }
            if event.type == .keyDown {
                _ = owner.handler(.textInput)
            }
            guard owner.acceptsTextInput, isTextEditingEvent(event) else { return .consume }
            owner.focusInput?()
            return .focusedControl
        }

        if isOverlayPresented { return .consume }
        if !editableControlIsFocused,
           sessionInterceptors.reversed().contains(where: { $0.handler(event) }) {
            return .consume
        }
        return editableControlIsFocused ? .focusedControl : .activeSession
    }

    private func command(for event: NSEvent) -> Command? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == [.control] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "p": return .moveUp
            case "n": return .moveDown
            default: return nil
            }
        }
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 126: return .moveUp
        case 125: return .moveDown
        case 36, 76: return .submit
        case 53: return .back
        case 51: return .delete
        default: return nil
        }
    }

    private func isTextEditingEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return true }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers.contains(.command) else { return true }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return switch (key, modifiers) {
        case ("a", [.command]),
             ("c", [.command]),
             ("v", [.command]),
             ("x", [.command]),
             ("z", [.command]),
             ("z", [.command, .shift]):
            true
        default:
            false
        }
    }
}
