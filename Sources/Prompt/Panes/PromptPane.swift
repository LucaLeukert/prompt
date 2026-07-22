import Foundation

struct PromptPane: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var surfaceID: UUID?

    init(id: UUID = UUID(), title: String = "Terminal", surfaceID: UUID? = nil) {
        self.id = id
        self.title = title
        self.surfaceID = surfaceID
    }
}

enum PromptSplitAxis: String, Codable, Equatable {
    case horizontal
    case vertical
}

indirect enum PromptSplitTree: Codable, Equatable {
    case leaf(PromptPane)
    case split(axis: PromptSplitAxis, fraction: Double, first: PromptSplitTree, second: PromptSplitTree)

    var panes: [PromptPane] {
        switch self {
        case .leaf(let pane): [pane]
        case .split(_, _, let first, let second): first.panes + second.panes
        }
    }

    var paneCount: Int { panes.count }

    mutating func split(paneID: PromptPane.ID, axis: PromptSplitAxis, newPane: PromptPane, placingNewPaneAfter: Bool) -> Bool {
        switch self {
        case .leaf(let pane) where pane.id == paneID:
            let old = PromptSplitTree.leaf(pane)
            let new = PromptSplitTree.leaf(newPane)
            self = .split(axis: axis, fraction: 0.5, first: placingNewPaneAfter ? old : new, second: placingNewPaneAfter ? new : old)
            return true
        case .leaf:
            return false
        case .split(let currentAxis, let fraction, var first, var second):
            if first.split(paneID: paneID, axis: axis, newPane: newPane, placingNewPaneAfter: placingNewPaneAfter) {
                self = .split(axis: currentAxis, fraction: fraction, first: first, second: second)
                return true
            }
            if second.split(paneID: paneID, axis: axis, newPane: newPane, placingNewPaneAfter: placingNewPaneAfter) {
                self = .split(axis: currentAxis, fraction: fraction, first: first, second: second)
                return true
            }
            return false
        }
    }

    mutating func remove(paneID: PromptPane.ID) -> PromptSplitTree? {
        switch self {
        case .leaf(let pane): return pane.id == paneID ? nil : self
        case .split(let axis, let fraction, var first, var second):
            let newFirst = first.remove(paneID: paneID)
            let newSecond = second.remove(paneID: paneID)
            switch (newFirst, newSecond) {
            case (nil, nil): return nil
            case (let remaining?, nil), (nil, let remaining?): return remaining
            case (let lhs?, let rhs?):
                self = .split(axis: axis, fraction: fraction, first: lhs, second: rhs)
                return self
            }
        }
    }
}
