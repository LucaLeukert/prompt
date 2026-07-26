import AppKit
import CoreText
import Darwin
import GhosttyKit
import MarkdownUI
import SwiftMath
import SwiftUI

struct PromptRichBlock: Identifiable {
    enum State { case streaming, complete, failed, cancelled }
    let id: UUID
    let surfaceID: ObjectIdentifier
    let anchorRow: Int
    var reservedRows: Int
    var measuredHeight: CGFloat
    var reservationFrozen: Bool
    let request: String
    let lane: PromptAILane
    var response: String
    var toolCalls: [PromptToolCall]
    var recommendationActions: [PromptRecommendationAction]
    let model: String
    var state: State
}

/// Rich conversation history is deliberately separate from the VT screen.
/// Ghostty owns terminal cells; this store owns host-rendered request/response
/// cards anchored to blank layout rows in the same scrollback coordinate space.
@MainActor
final class PromptRichContentStore: ObservableObject {
    static let shared = PromptRichContentStore()
    @Published private(set) var blocks: [PromptRichBlock] = []
    private var pending: [UUID: String] = [:]
    private var timers: [UUID: Timer] = [:]
    private var completions: [UUID: () -> Void] = [:]
    private var drainSizes: [UUID: Int] = [:]

    func begin(request: String, lane: PromptAILane, model: String, on surface: PromptTerminalSurface) -> UUID {
        let id = UUID()
        let anchor = absoluteCursorRow(on: surface)
        // Start compact and grow the backing terminal rows as tools and the
        // structured response arrive.
        let rows = 6
        if PromptTerminalCapabilities.remoteContext(for: surface) == nil || surface.isComposite {
            reserve(rows: rows, on: surface, clearPromptRow: true)
        }
        blocks.append(.init(
            id: id,
            surfaceID: ObjectIdentifier(surface),
            anchorRow: anchor,
            reservedRows: rows,
            measuredHeight: 0,
            reservationFrozen: false,
            request: request,
            lane: lane,
            response: "",
            toolCalls: [],
            recommendationActions: [],
            model: model,
            state: .streaming))
        return id
    }

    func presentRecommendation(
        _ recommendation: PromptAmbientRecommendation,
        on surface: PromptTerminalSurface
    ) {
        let id = UUID()
        let anchor = absoluteCursorRow(on: surface)
        let rows = 3
        reserve(rows: rows, on: surface, clearPromptRow: true)
        blocks.append(.init(
            id: id,
            surfaceID: ObjectIdentifier(surface),
            anchorRow: anchor,
            reservedRows: rows,
            measuredHeight: 0,
            reservationFrozen: true,
            request: "",
            lane: .assistant,
            response: "",
            toolCalls: [],
            recommendationActions: recommendation.actions,
            model: "",
            state: .complete))
        PromptController.pressReturn(on: surface)
    }

    func enqueue(_ delta: String, to id: UUID, on surface: PromptTerminalSurface) {
        guard !delta.isEmpty, blocks.contains(where: { $0.id == id }) else { return }
        pending[id, default: ""] += delta
        guard timers[id] == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self, weak surface] _ in
            guard let self, let surface else { return }
            MainActor.assumeIsolated { self.drain(id, on: surface) }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[id] = timer
    }

    func finishWhenDrained(_ id: UUID, on surface: PromptTerminalSurface, completion: @escaping () -> Void) {
        let remaining = pending[id]?.count ?? 0
        drainSizes[id] = max(12, Int(ceil(Double(remaining) / 30.0)))
        completions[id] = completion
        if remaining == 0 { finishDrain(id, on: surface) }
    }

    func fail(_ text: String, id: UUID, on surface: PromptTerminalSurface) {
        timers.removeValue(forKey: id)?.invalidate()
        pending.removeValue(forKey: id)
        completions.removeValue(forKey: id)
        drainSizes.removeValue(forKey: id)
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        var block = blocks[index]
        block.response = text
        block.state = .failed
        blocks[index] = block
    }

    func cancel(_ id: UUID, on surface: PromptTerminalSurface) {
        timers.removeValue(forKey: id)?.invalidate()
        pending.removeValue(forKey: id)
        completions.removeValue(forKey: id)
        drainSizes.removeValue(forKey: id)
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        var block = blocks[index]
        if block.response.isEmpty { block.response = "Generation cancelled." }
        block.state = .cancelled
        blocks[index] = block
    }

    func clear(for surface: PromptTerminalSurface) {
        let ids = Set(blocks.filter { $0.surfaceID == ObjectIdentifier(surface) }.map(\.id))
        for id in ids {
            timers.removeValue(forKey: id)?.invalidate()
            pending.removeValue(forKey: id)
            completions.removeValue(forKey: id)
            drainSizes.removeValue(forKey: id)
        }
        blocks.removeAll { ids.contains($0.id) }
    }

    func blocks(for surface: PromptTerminalSurface) -> [PromptRichBlock] {
        blocks.filter { $0.surfaceID == ObjectIdentifier(surface) }
    }

    /// Once the user submits more terminal input, the live prompt no longer
    /// sits immediately after an in-flight card. Growing that card with VT
    /// insert-line sequences would then move or overwrite unrelated output.
    /// Freeze its existing inline allocation; excess content scrolls inside
    /// the card instead.
    func freezeReservations(for surface: PromptTerminalSurface) {
        let surfaceID = ObjectIdentifier(surface)
        for index in blocks.indices where blocks[index].surfaceID == surfaceID {
            blocks[index].reservationFrozen = true
        }
    }

    func upsertToolCall(_ call: PromptToolCall, blockID: UUID, on surface: PromptTerminalSurface) {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        var block = blocks[index]
        if let callIndex = block.toolCalls.firstIndex(where: { $0.id == call.id }) {
            block.toolCalls[callIndex] = call
        } else {
            block.toolCalls.append(call)
        }
        blocks[index] = block
    }

    func updateMeasuredHeight(_ height: CGFloat, for id: UUID, on surface: PromptTerminalSurface) {
        guard PromptTerminalCapabilities.remoteContext(for: surface) == nil || surface.isComposite else { return }
        guard height.isFinite, height > 0,
              let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].measuredHeight = height
        let cellHeight = max(1, surface.cellSize.height)
        // Include the small visual separation above the following prompt and
        // convert the native SwiftUI layout to the VT's physical row grid.
        let required = max(6, Int(ceil((height + 4) / cellHeight)))
        let target = Self.nextReservationRows(
            current: blocks[index].reservedRows,
            required: required,
            maximum: maximumCardRows(on: surface),
            frozen: blocks[index].reservationFrozen)
        guard target > blocks[index].reservedRows else { return }
        let additional = target - blocks[index].reservedRows
        insertRowsBeforePrompt(additional, on: surface)
        blocks[index].reservedRows = target
    }

    nonisolated static func requiredRows(
        request: String,
        response: String,
        toolCalls: Int,
        columns: Int
    ) -> Int {
        func visualLines(_ text: String) -> Int {
            text.components(separatedBy: .newlines).reduce(0) { total, line in
                total + max(1, Int(ceil(Double(max(1, line.count)) / Double(max(1, columns)))))
            }
        }
        // Header, AI label and card padding consume four terminal rows. Tool
        // calls are compact one-row pills; response wrapping uses terminal
        // columns with a little safety for proportional Markdown typography.
        let rows = 4 + min(2, visualLines(request)) + toolCalls + visualLines(response)
        return min(80, max(6, rows + 2))
    }

    nonisolated static func nextReservationRows(
        current: Int,
        required: Int,
        maximum: Int,
        frozen: Bool
    ) -> Int {
        guard !frozen else { return current }
        return max(current, min(required, maximum))
    }

    private func insertRowsBeforePrompt(_ rows: Int, on surface: PromptTerminalSurface) {
        guard rows > 0, let terminal = surface.surface else { return }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(terminal, &x, &y, &width, &height)
        let column = max(1, Int(x / max(1, surface.cellSize.width)) + 1)
        // IL shifts the complete prompt row down without repainting it. Move
        // Ghostty's parser cursor by the same amount and restore its column so
        // subsequent readline/ZLE input continues at the shifted prompt.
        let sequence = "\r\u{001B}[\(rows)L\u{001B}[\(rows)B\u{001B}[\(column)G"
        sequence.withCString { ghostty_surface_process_output(terminal, $0, UInt(sequence.utf8.count)) }
    }

    private func drain(_ id: UUID, on surface: PromptTerminalSurface) {
        guard var buffer = pending[id], !buffer.isEmpty,
              let index = blocks.firstIndex(where: { $0.id == id }) else {
            if completions[id] != nil { finishDrain(id, on: surface) }
            return
        }
        let amount = min(buffer.count, drainSizes[id] ?? 12)
        let end = buffer.index(buffer.startIndex, offsetBy: amount)
        var block = blocks[index]
        block.response += String(buffer[..<end])
        blocks[index] = block
        growReservationIfNeeded(for: id, on: surface)
        buffer.removeSubrange(..<end)
        pending[id] = buffer
        if buffer.isEmpty, completions[id] != nil { finishDrain(id, on: surface) }
    }

    private func growReservationIfNeeded(for id: UUID, on surface: PromptTerminalSurface) {
        guard PromptTerminalCapabilities.remoteContext(for: surface) == nil || surface.isComposite else { return }
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        let block = blocks[index]
        let columns = max(20, Int(surface.nativeView.bounds.width / max(1, surface.cellSize.width)))
        let required = Self.requiredRows(
            request: block.request,
            response: block.response,
            toolCalls: block.toolCalls.count,
            columns: columns)
        let target = Self.nextReservationRows(
            current: block.reservedRows,
            required: required,
            maximum: maximumCardRows(on: surface),
            frozen: block.reservationFrozen)
        guard target > block.reservedRows else { return }
        insertRowsBeforePrompt(target - block.reservedRows, on: surface)
        blocks[index].reservedRows = target
    }

    private func maximumCardRows(on surface: PromptTerminalSurface) -> Int {
        let viewportRows = Int(surface.nativeView.bounds.height / max(1, surface.cellSize.height))
        // Leave enough terminal visible to retain spatial context and expose
        // the prompt below the card. Taller responses scroll inside the card.
        return max(6, viewportRows - 4)
    }

    private func finishDrain(_ id: UUID, on surface: PromptTerminalSurface) {
        timers.removeValue(forKey: id)?.invalidate()
        pending.removeValue(forKey: id)
        drainSizes.removeValue(forKey: id)
        if let index = blocks.firstIndex(where: { $0.id == id }) {
            var block = blocks[index]
            block.state = .complete
            blocks[index] = block
        }
        completions.removeValue(forKey: id)?()
    }

    private func absoluteCursorRow(on surface: PromptTerminalSurface) -> Int {
        guard let terminal = surface.surface else { return Int(surface.scrollbar?.offset ?? 0) }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(terminal, &x, &y, &width, &height)
        let viewportRow = Int(max(0, y) / max(1, surface.cellSize.height))
        return Int(surface.scrollbar?.offset ?? 0) + viewportRow
    }

    private func reserve(rows: Int, on surface: PromptTerminalSurface, clearPromptRow: Bool) {
        guard rows > 0, let terminal = surface.surface else { return }
        var layout = clearPromptRow ? "\r\u{001B}[2K" : ""
        layout += String(repeating: "\r\n", count: rows)
        layout.withCString { ghostty_surface_process_output(terminal, $0, UInt(layout.utf8.count)) }
    }
}

struct PromptRichContentLayer: View {
    @ObservedObject var surfaceView: PromptTerminalSurface
    @ObservedObject private var store = PromptRichContentStore.shared
    @State private var viewportOffset = 0
    @State private var previousTotal = 0
    @State private var allowsRichContent = true
    private let environmentTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            if allowsRichContent {
                ForEach(store.blocks(for: surfaceView)) { block in
                    let height = CGFloat(block.reservedRows) * max(1, surfaceView.cellSize.height)
                    PromptInlineRichBlockFrame(
                        block: block,
                        surfaceView: surfaceView,
                        width: max(240, geometry.size.width - 16),
                        height: height)
                        .position(
                            x: geometry.size.width / 2,
                            // The cursor row includes Ghostty's prompt line. Pull
                            // the host block into that cleared row, leaving only a
                            // compact four-point separation from prior TTY output.
                            y: CGFloat(block.anchorRow - viewportOffset) * max(1, surfaceView.cellSize.height)
                                + height / 2 - max(0, surfaceView.cellSize.height - 4))
                }
            }
        }
        .clipped()
        .onPreferenceChange(PromptRichCardHeightPreference.self) { heights in
            for (id, height) in heights {
                store.updateMeasuredHeight(height, for: id, on: surfaceView)
            }
        }
        .onAppear {
            allowsRichContent = PromptTerminalEnvironment.allowsRichContent(on: surfaceView)
            viewportOffset = Int(surfaceView.scrollbar?.offset ?? 0)
            previousTotal = Int(surfaceView.scrollbar?.total ?? 0)
        }
        .onReceive(environmentTimer) { _ in
            allowsRichContent = PromptTerminalEnvironment.allowsRichContent(on: surfaceView)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDidUpdateScrollbar, object: surfaceView)) { note in
            guard let scrollbar = note.userInfo?[Notification.Name.ScrollbarKey] as? Ghostty.Action.Scrollbar else { return }
            if previousTotal > 0 && Int(scrollbar.total) < previousTotal {
                store.clear(for: surfaceView)
            }
            previousTotal = Int(scrollbar.total)
            viewportOffset = Int(scrollbar.offset)
        }
    }
}

private struct PromptInlineRichBlockFrame: View {
    let block: PromptRichBlock
    @ObservedObject var surfaceView: PromptTerminalSurface
    let width: CGFloat
    let height: CGFloat

    private var overflowsReservation: Bool {
        block.measuredHeight > height + 1
    }

    var body: some View {
        Group {
            if overflowsReservation {
                ScrollView(.vertical, showsIndicators: true) {
                    richContent.frame(width: width)
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            } else {
                richContent
                    .frame(width: width)
                    .frame(height: height, alignment: .top)
                    .clipped()
            }
        }
        .frame(width: width, height: height, alignment: .top)
        // Static assistant cards are visual terminal history, so let Ghostty
        // receive wheel/trackpad events through them. A card only becomes the
        // scroll owner when its content exceeds its fixed inline reservation;
        // agent approvals and ambient actions remain interactive as well.
        .allowsHitTesting(
            overflowsReservation
                || block.lane == .agent
                || !block.recommendationActions.isEmpty)
    }

    @ViewBuilder
    private var richContent: some View {
        if !block.recommendationActions.isEmpty {
            PromptAmbientActionButtons(
                actions: block.recommendationActions,
                blockID: block.id,
                surfaceView: surfaceView)
        } else {
            PromptRichConversationCard(block: block, surfaceView: surfaceView)
        }
    }
}

/// Remote tmux owns the complete VT screen. Responses therefore float above
/// the terminal instead of reserving rows or injecting cursor movement into it.
struct PromptRemoteAIOverlay: View {
    @ObservedObject var surfaceView: PromptTerminalSurface
    @ObservedObject private var store = PromptRichContentStore.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear.allowsHitTesting(false)
            if let block = store.blocks(for: surfaceView).last {
                PromptRichConversationCard(block: block, surfaceView: surfaceView)
                    .frame(maxWidth: 720)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
    }
}

/// Controlled remotes keep tmux's VT grid authoritative. Rich content lives in
/// a genuine host layout inset, so it reduces terminal height instead of
/// painting over terminal cells or moving Ghostty's parser cursor.
struct PromptRemoteRichTranscript: View {
    @ObservedObject var surfaceView: PromptTerminalSurface
    @ObservedObject private var store = PromptRichContentStore.shared
    @State private var collapsed = false

    private var blocks: [PromptRichBlock] { store.blocks(for: surfaceView) }

    var body: some View {
        if !blocks.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").foregroundStyle(Color.mint)
                    Text("AI transcript").font(.custom(PromptTypography.sans, size: 11).weight(.semibold))
                    Spacer()
                    Button { withAnimation(.easeOut(duration: 0.16)) { collapsed.toggle() } } label: {
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .help(collapsed ? "Show AI transcript" : "Collapse AI transcript")
                }
                .padding(.horizontal, 12)
                .frame(height: 34)

                if !collapsed {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(blocks) { block in
                                PromptRichConversationCard(block: block, surfaceView: surfaceView)
                                    .id(block.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                    .frame(height: 230)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.98))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

private struct PromptRichCardHeightPreference: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct PromptAmbientActionButtons: View {
    let actions: [PromptRecommendationAction]
    let blockID: UUID
    let surfaceView: PromptTerminalSurface
    @ObservedObject private var model = PromptModel.shared

    var body: some View {
        HStack(spacing: 6) {
            ForEach(actions) { action in
                Button {
                    model.performRecommendation(action, on: surfaceView)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8).padding(.top, 4)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: PromptRichCardHeightPreference.self,
                    value: [blockID: geometry.size.height])
            }
        }
    }
}

private struct PromptRichConversationCard: View {
    let block: PromptRichBlock
    let surfaceView: PromptTerminalSurface
    @ObservedObject private var model = PromptModel.shared

    private var laneLabel: String {
        switch block.lane {
        case .assistant: "ASSISTANT"
        case .agent: "AGENT"
        }
    }

    private var laneSymbol: String {
        switch block.lane {
        case .assistant: "bubble.left.and.text.bubble.right"
        case .agent: "hammer"
        }
    }

    private var stateColor: Color {
        switch block.state {
        case .failed: .red
        case .cancelled: .orange
        case .streaming, .complete: .accentColor
        }
    }

    private var stateSymbol: String {
        switch block.state {
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "stop.circle.fill"
        case .streaming: "sparkles"
        case .complete: "checkmark.circle.fill"
        }
    }

    private func toolSymbol(_ call: PromptToolCall) -> String {
        let name = call.title.lowercased()
        if name.contains("read_commands") { return "clock.arrow.trianglehead.counterclockwise.rotate.90" }
        if name.contains("read") { return "text.viewfinder" }
        if name.contains("insert") { return "text.cursor" }
        if name.contains("run") { return "play.fill" }
        return "wrench.and.screwdriver"
    }

    private func toolStateSymbol(_ state: PromptToolCall.State) -> String {
        switch state {
        case .running: "ellipsis.circle"
        case .complete: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func toolStateColor(_ state: PromptToolCall.State) -> Color {
        switch state {
        case .running: .secondary
        case .complete: .green
        case .failed: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: laneSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(stateColor)
                    .frame(width: 28, height: 28)
                    .background(stateColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(laneLabel)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(block.model)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    Text(block.request)
                        .font(.custom(PromptTypography.mono, size: 12.25))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if block.state == .streaming {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: stateSymbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(stateColor)
                }
            }

            if !block.toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(block.toolCalls) { call in
                        HStack(spacing: 8) {
                            Image(systemName: toolSymbol(call))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(call.title.replacingOccurrences(of: "Tool ", with: ""))
                                    .fontWeight(.medium)
                                if !call.detail.isEmpty {
                                    Text(call.detail).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: toolStateSymbol(call.state))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(toolStateColor(call.state))
                        }
                        .font(.custom(PromptTypography.mono, size: 11.25))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        if call.id != block.toolCalls.last?.id { Divider().padding(.leading, 33) }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.48), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
                }
            }
            if block.lane == .agent {
                ForEach(model.approvals.filter { $0.richBlockID == block.id }) { approval in
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Approval required").fontWeight(.semibold)
                            Text(approval.summary).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Button("Decline") { model.approve(approval, decision: "decline") }
                        Button("Allow") { model.approve(approval, decision: "accept") }
                            .buttonStyle(.borderedProminent)
                    }
                    .font(.custom(PromptTypography.sans, size: 11.5))
                    .controlSize(.small)
                    .padding(9)
                    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.orange.opacity(0.2), lineWidth: 0.5)
                    }
                }
            }
            if block.response.isEmpty && block.state == .streaming {
                HStack(spacing: 7) {
                    Image(systemName: "ellipsis")
                    Text("Thinking")
                }
                .font(.custom(PromptTypography.sans, size: 12.5))
                .foregroundStyle(.tertiary)
            } else {
                Divider()
                PromptRichDocument(source: block.response)
            }
        }
        // Rich history owns selection inside its visible card. Outside these
        // painted bounds the transparent overlay has no hit-test content, so
        // pointer events continue to reach Ghostty normally.
        .textSelection(.enabled)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // The parent frame represents rows already reserved in the VT. Do not
        // let that stale proposal constrain layout measurement: Markdown,
        // tools and approvals must report their intrinsic native height first.
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: PromptRichCardHeightPreference.self,
                    value: [block.id: geometry.size.height])
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
        .overlay(alignment: .leading) {
            Capsule().fill(stateColor).frame(width: 2).padding(.vertical, 9)
        }
    }
}

enum PromptRichSegment: Identifiable, Equatable {
    case markdown(String)
    case math(String)

    var id: String {
        switch self {
        case .markdown(let value): "markdown:\(value)"
        case .math(let value): "math:\(value)"
        }
    }
}

/// A single linear scan separates display/inline TeX from CommonMark. The
/// actual typesetting is delegated to native parsers (cmark and SwiftMath), so
/// no WebView, JavaScript runtime, or HTML layout pass is involved.
enum PromptRichParser {
    static func segments(_ source: String) -> [PromptRichSegment] {
        var result: [PromptRichSegment] = []
        var markdown = ""
        var cursor = source.startIndex

        func flushMarkdown() {
            guard !markdown.isEmpty else { return }
            result.append(.markdown(markdown))
            markdown = ""
        }

        while cursor < source.endIndex {
            let suffix = source[cursor...]
            let opener: String
            let closer: String
            if suffix.hasPrefix("$$") { opener = "$$"; closer = "$$" }
            else if suffix.hasPrefix("\\[") { opener = "\\["; closer = "\\]" }
            else if suffix.hasPrefix("$") { opener = "$"; closer = "$" }
            else {
                markdown.append(source[cursor])
                cursor = source.index(after: cursor)
                continue
            }

            let bodyStart = source.index(cursor, offsetBy: opener.count)
            guard let closeRange = source.range(of: closer, range: bodyStart ..< source.endIndex) else {
                // An unfinished delimiter is common during streaming. Leave it
                // as Markdown until the matching delta arrives.
                markdown.append(contentsOf: source[cursor...])
                cursor = source.endIndex
                break
            }
            flushMarkdown()
            let formula = String(source[bodyStart ..< closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !formula.isEmpty { result.append(.math(formula)) }
            cursor = closeRange.upperBound
        }
        flushMarkdown()
        return result
    }
}

private struct PromptRichDocument: View {
    let source: String

    var body: some View {
        let segments = PromptRichParser.segments(source)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments) { segment in
                switch segment {
                case .markdown(let markdown):
                    Markdown(markdown)
                        .markdownTextStyle { FontFamily(.custom(PromptTypography.sans)) }
                        .markdownTextStyle { FontSize(13.5) }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                case .math(let formula):
                    PromptMathView(latex: formula)
                        .frame(minHeight: 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct PromptMathView: NSViewRepresentable {
    let latex: String

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.textAlignment = .left
        label.labelMode = .display
        label.contentInsets = MTEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
        return label
    }

    func updateNSView(_ view: MTMathUILabel, context: Context) {
        guard view.latex != latex else { return }
        view.latex = latex
        view.font = MTFontManager().font(withName: MathFont.latinModernFont.rawValue, size: 17)
        view.textColor = NSColor.labelColor
        view.invalidateIntrinsicContentSize()
    }
}

struct PromptRecommendationAction: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case insertCommand
        case askAI
    }

    let kind: Kind
    let title: String
    let value: String
    let systemImage: String

    var id: String { "\(kind.rawValue):\(title):\(value)" }
}

struct PromptAmbientRecommendation: Equatable {
    let actions: [PromptRecommendationAction]
}

enum PromptAmbientAnalysisResult {
    static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "worthAnalyzing": ["type": "boolean"],
            "actions": [
                "type": "array",
                "maxItems": 3,
                "items": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": ["insertCommand", "askAI"]],
                        "title": ["type": "string"],
                        "value": ["type": "string"],
                        "systemImage": ["type": "string"],
                    ],
                    "required": ["kind", "title", "value", "systemImage"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["worthAnalyzing", "actions"],
        "additionalProperties": false,
    ]

    static func parse(_ text: String) -> PromptAmbientRecommendation? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["worthAnalyzing"] as? Bool == true,
              let rawActions = object["actions"] as? [[String: Any]] else { return nil }
        let actions = rawActions.prefix(3).compactMap { value -> PromptRecommendationAction? in
            guard let rawKind = value["kind"] as? String,
                  let kind = PromptRecommendationAction.Kind(rawValue: rawKind),
                  let title = value["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let payload = value["value"] as? String,
                  !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !payload.contains("\n"), !payload.contains("\r") else { return nil }
            if kind == .insertCommand, !PromptSuggestedCommand.isValid(payload) { return nil }
            let proposedSymbol = value["systemImage"] as? String ?? ""
            let symbol = NSImage(systemSymbolName: proposedSymbol, accessibilityDescription: nil) == nil
                ? "sparkles"
                : proposedSymbol
            return .init(kind: kind, title: title, value: payload, systemImage: symbol)
        }
        guard !actions.isEmpty else { return nil }
        return .init(actions: actions)
    }
}
