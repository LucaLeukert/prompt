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

enum PromptPaneDropZone: String, Equatable {
    case center
    case top
    case bottom
    case left
    case right

    var axis: PromptSplitAxis? {
        switch self {
        case .center: nil
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        }
    }

    var placesSourceAfterTarget: Bool {
        switch self {
        case .center: false
        case .right, .bottom: true
        case .left, .top: false
        }
    }
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

    mutating func move(paneID: PromptPane.ID, relativeTo targetPaneID: PromptPane.ID, zone: PromptPaneDropZone) -> Bool {
        guard paneID != targetPaneID,
              let pane = panes.first(where: { $0.id == paneID }),
              let targetPane = panes.first(where: { $0.id == targetPaneID }) else { return false }

        if zone == .center {
            swap(paneID: paneID, with: targetPaneID, firstPane: pane, secondPane: targetPane)
            return true
        }

        guard let axis = zone.axis,
              let remaining = remove(paneID: paneID) else { return false }

        self = remaining
        return split(
            paneID: targetPaneID,
            axis: axis,
            newPane: pane,
            placingNewPaneAfter: zone.placesSourceAfterTarget)
    }

    mutating func resizeSplit(
        between firstPaneID: PromptPane.ID,
        and secondPaneID: PromptPane.ID,
        fraction: Double
    ) -> Bool {
        guard case .split(let axis, let currentFraction, var first, var second) = self else {
            return false
        }
        if first.resizeSplit(
            between: firstPaneID,
            and: secondPaneID,
            fraction: fraction
        ) || second.resizeSplit(
            between: firstPaneID,
            and: secondPaneID,
            fraction: fraction
        ) {
            self = .split(
                axis: axis,
                fraction: currentFraction,
                first: first,
                second: second)
            return true
        }
        guard first.panes.contains(where: { $0.id == firstPaneID }),
              second.panes.contains(where: { $0.id == secondPaneID }) else { return false }
        self = .split(
            axis: axis,
            fraction: min(max(fraction, 0.05), 0.95),
            first: first,
            second: second)
        return true
    }

    private mutating func swap(
        paneID firstPaneID: PromptPane.ID,
        with secondPaneID: PromptPane.ID,
        firstPane: PromptPane,
        secondPane: PromptPane
    ) {
        switch self {
        case .leaf(let pane) where pane.id == firstPaneID:
            self = .leaf(secondPane)
        case .leaf(let pane) where pane.id == secondPaneID:
            self = .leaf(firstPane)
        case .leaf:
            break
        case .split(let axis, let fraction, var first, var second):
            first.swap(
                paneID: firstPaneID,
                with: secondPaneID,
                firstPane: firstPane,
                secondPane: secondPane)
            second.swap(
                paneID: firstPaneID,
                with: secondPaneID,
                firstPane: firstPane,
                secondPane: secondPane)
            self = .split(axis: axis, fraction: fraction, first: first, second: second)
        }
    }
}
