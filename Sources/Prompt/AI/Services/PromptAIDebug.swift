import AppKit
import CoreText
import Darwin
import GhosttyKit
import MarkdownUI
import SwiftMath
import SwiftUI

#if DEBUG
    struct PromptAIDebugEvent: Identifiable {
        let id = UUID()
        let date = Date()
        let service: String
        let level: String
        let message: String
    }

    @MainActor
    final class PromptAIDebugModel: ObservableObject {
        static let shared = PromptAIDebugModel()
        @Published private(set) var events: [PromptAIDebugEvent] = []
        private init() {}

        func append(service: String, level: String, message: String) {
            events.append(.init(service: service, level: level, message: message))
            if events.count > 500 { events.removeFirst(events.count - 500) }
        }

        func clear() { events.removeAll() }
        func latest(for service: String) -> PromptAIDebugEvent? { events.last { $0.service == service } }

        var exportText: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return events.map {
                "\(formatter.string(from: $0.date)) [\($0.service)] [\($0.level)] \($0.message)"
            }.joined(separator: "\n")
        }
    }

    enum PromptAIDebug {
        static func emit(_ service: String, _ level: String, _ message: String) {
            DispatchQueue.main.async {
                PromptAIDebugModel.shared.append(service: service, level: level, message: message)
            }
        }
    }
#endif
