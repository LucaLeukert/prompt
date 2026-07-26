import AppKit
import CoreText
import Darwin
import GhosttyKit
import MarkdownUI
import SwiftMath
import SwiftUI

@MainActor
private final class PromptModeTabMonitor: ObservableObject {
    private let inputOwner = UUID()
    private var dismissWork: DispatchWorkItem?

    func start(for surfaceView: PromptTerminalSurface) {
        stop()
        scheduleDismiss(for: surfaceView)
        inputRouter?.claimSessionInterceptor(owner: inputOwner) { [weak surfaceView] event in
            guard event.type == .keyDown, let surfaceView else { return false }
            if event.keyCode == 0x35,
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                NotificationCenter.default.post(name: .promptDismissModePicker, object: surfaceView)
                return true
            }
            guard event.keyCode == 0x30,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                return false
            }

            switch PromptNativeInputRouter.tabDisposition(on: surfaceView) {
            case .passToTerminal:
                return false
            case .consume:
                return true
            case .acceptAutocomplete:
                _ = PromptAutocompleteModel.shared.accept(on: surfaceView)
                return true
            case .switchMode(let mode):
                PromptNativeInputRouter.selectSurfaceModeFromKeyboard(mode, for: surfaceView)
                return true
            }
        }
    }

    func stop() {
        dismissWork?.cancel()
        dismissWork = nil
        inputRouter?.releaseSessionInterceptor(owner: inputOwner)
    }

    private var inputRouter: PromptInputRouter? {
        (NSApp.delegate as? PromptApplicationDelegate)?.workspaceStore.inputRouter
    }

    private func scheduleDismiss(for surfaceView: PromptTerminalSurface) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak surfaceView] in
            guard let surfaceView else { return }
            NotificationCenter.default.post(name: .promptDismissModePicker, object: surfaceView)
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

}

private struct PromptSelectorGlassContainer: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }
}

private struct PromptSelectorBadgeGlass: ViewModifier {
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
                .glassEffectID("mode-selector-glass", in: namespace)
                .glassEffectTransition(.matchedGeometry)
        } else {
            content
        }
    }
}

private struct PromptSelectorPanelGlass: ViewModifier {
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                .glassEffectID("mode-selector-glass", in: namespace)
                .glassEffectTransition(.matchedGeometry)
        } else {
            content
        }
    }
}

private struct PromptPointingHandCursor: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.iBeam.set() }
        }
    }
}

#if DEBUG
    private struct PromptAIDebugView: View {
        @ObservedObject private var debug = PromptAIDebugModel.shared
        @Environment(\.dismiss) private var dismiss
        @State private var service = "All"
        private let services = ["All", "Main AI", "Copilot Completion"]

        private var visibleEvents: [PromptAIDebugEvent] {
            service == "All" ? debug.events : debug.events.filter { $0.service == service }
        }

        var body: some View {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI SERVICE INSPECTOR")
                            .font(.custom(PromptTypography.mono, size: 15).weight(.bold))
                        Text("live app-server telemetry · DEBUG build")
                            .font(.custom(PromptTypography.mono, size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy log", action: copyLog)
                    Button("Clear") { debug.clear() }
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(16)

                HStack(spacing: 10) {
                    serviceCard("Main AI", icon: "sparkles")
                    serviceCard("Copilot Completion", icon: "text.cursor")
                }
                .padding(.horizontal, 16).padding(.bottom, 12)

                HStack(spacing: 5) {
                    ForEach(services, id: \.self) { value in
                        Button { service = value } label: {
                            Text(value)
                                .font(.custom(PromptTypography.mono, size: 10).weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(service == value ? Color.primary.opacity(0.13) : .clear, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    Text("\(visibleEvents.count) EVENTS")
                        .font(.custom(PromptTypography.mono, size: 9).weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Color.primary.opacity(0.035))

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleEvents) { event in
                                eventRow(event).id(event.id)
                            }
                        }
                    }
                    .onChange(of: visibleEvents.count) { _ in
                        if let id = visibleEvents.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                .background(Color.black.opacity(0.18))
            }
            .frame(minWidth: 760, idealWidth: 860, minHeight: 500, idealHeight: 620)
            .background(Color(nsColor: .windowBackgroundColor))
        }

        private func serviceCard(_ name: String, icon: String) -> some View {
            let latest = debug.latest(for: name)
            let failed = latest?.level == "error" || latest?.level == "stderr"
            return HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(failed ? Color.red : Color.mint)
                    .frame(width: 30, height: 30)
                    .background((failed ? Color.red : Color.mint).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(name).font(.custom(PromptTypography.sans, size: 12).weight(.bold))
                        Spacer()
                        Circle().fill(failed ? Color.red : Color.mint).frame(width: 6, height: 6)
                    }
                    Text(latest?.message ?? "No telemetry yet")
                        .font(.custom(PromptTypography.mono, size: 9))
                        .foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        }

        private func eventRow(_ event: PromptAIDebugEvent) -> some View {
            HStack(alignment: .top, spacing: 10) {
                Text(Self.timeFormatter.string(from: event.date))
                    .foregroundStyle(.tertiary).frame(width: 82, alignment: .leading)
                Text(event.service == "Copilot Completion" ? "COPILOT" : "MAIN")
                    .foregroundStyle(event.service == "Copilot Completion" ? Color.cyan : Color.mint)
                    .frame(width: 58, alignment: .leading)
                Text(event.level.uppercased())
                    .foregroundStyle(event.level == "error" || event.level == "stderr" ? Color.red : Color.secondary)
                    .frame(width: 82, alignment: .leading)
                Text(event.message).foregroundStyle(Color.primary).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .font(.custom(PromptTypography.mono, size: 10))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(event.level == "error" || event.level == "stderr" ? Color.red.opacity(0.055) : .clear)
            .overlay(alignment: .bottom) { Divider().opacity(0.25) }
        }

        private func copyLog() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(debug.exportText, forType: .string)
        }

        private static let timeFormatter: DateFormatter = {
            let value = DateFormatter()
            value.dateFormat = "HH:mm:ss.SSS"
            return value
        }()
    }

    @MainActor
    final class PromptAIDebugWindowController: NSWindowController {
        static let shared = PromptAIDebugWindowController()

        private init() {
            let window = NSWindow(contentViewController: NSHostingController(rootView: PromptAIDebugView()))
            window.title = "AI Service Inspector"
            window.setContentSize(NSSize(width: 860, height: 620))
            window.minSize = NSSize(width: 760, height: 500)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            super.init(window: window)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func show() {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
#endif

/// A click-through status ornament for the real terminal prompt. It follows
/// Ghostty's native caret but never replaces or captures terminal input.
struct PromptNativeModeBadge: View {
    @ObservedObject var surfaceView: PromptTerminalSurface
    @ObservedObject private var model = PromptModel.shared
    @ObservedObject private var autocomplete = PromptAutocompleteModel.shared
    @StateObject private var tabMonitor = PromptModeTabMonitor()
    @State private var input: String? = nil
    @State private var selectedSurfaceMode: PromptSurfaceMode = .autoShell
    @State private var showsModePicker = false
    @State private var showsKeyboardModePicker = false
    @State private var hoverSelectionEnabled = false
    @State private var hoveredSurfaceMode: PromptSurfaceMode?
    @State private var hoverDismissWork: DispatchWorkItem?
    @State private var cursorRect = CGRect(x: 12, y: 12, width: 1, height: 20)
    @Namespace private var selectorGlass
    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    private var surfaceMode: PromptSurfaceMode {
        selectedSurfaceMode
    }

    private var mode: PromptInputMode {
        PromptNativeInputRouter.route(for: surfaceView, text: input ?? "")
    }

    private var isSuggested: Bool {
        guard let input else { return false }
        return PromptNativeInputRouter.isSuggestedCommand(input, for: surfaceView)
    }

    private var selectorLabel: String {
        if isSuggested { return "Suggested" }
        switch surfaceMode {
        case .autoShell:
            return mode == .shell ? "Auto › Shell" : "Auto › Assistant"
        case .shell: return "Shell"
        case .assistant: return "Assistant"
        case .agent: return "Agent"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if input != nil && !model.ownsTerminalInput(surfaceView) {
                if !showsKeyboardModePicker {
                    Button { showsModePicker.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isSuggested ? "arrow.down.to.line.compact" : surfaceMode.icon)
                            Text(selectorLabel)
                            if model.isRunning { ProgressView().controlSize(.mini) }
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .bold))
                        }
                        .font(.custom(PromptTypography.sans, size: 10).weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .modifier(PromptSelectorBadgeGlass(namespace: selectorGlass))
                        .contentShape(Capsule())
                        .modifier(PromptPointingHandCursor())
                        .onHover { hovering in
                            if hovering { openSelectorFromHover() } else { scheduleHoverDismiss() }
                        }
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .position(x: geometry.size.width - 58, y: cursorRect.midY)
                    .popover(isPresented: $showsModePicker, arrowEdge: .bottom) {
                        PromptModePicker(
                            selection: surfaceMode,
                            supportsAgent: !PromptTerminalCapabilities.isManagedRemote(surfaceView),
                            select: { candidate in
                                showsModePicker = false
                                PromptNativeInputRouter.selectSurfaceMode(candidate, for: surfaceView)
                            })
                    }
                }

                if showsKeyboardModePicker {
                    PromptModePickerPreview(
                        selection: surfaceMode,
                        supportsAgent: !PromptTerminalCapabilities.isManagedRemote(surfaceView),
                        hovered: hoveredSurfaceMode,
                        hoverSelect: { candidate in
                            guard hoverSelectionEnabled else { return }
                            hoveredSurfaceMode = candidate
                        },
                        confirm: { candidate in
                            PromptNativeInputRouter.selectSurfaceMode(candidate, for: surfaceView)
                            hoveredSurfaceMode = nil
                            dismissHoverSelector()
                            surfaceView.focus()
                        })
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                        .onHover { hovering in
                            if hovering { cancelHoverDismiss() } else { dismissHoverSelector() }
                        }
                        .modifier(PromptSelectorPanelGlass(namespace: selectorGlass))
                        .fixedSize()
                        .position(
                            x: max(188, geometry.size.width - 188),
                            y: min(max(112, cursorRect.midY + 112), max(112, geometry.size.height - 112)))
                }
            }
        }
        .modifier(PromptSelectorGlassContainer())
        .onAppear {
            selectedSurfaceMode = PromptNativeInputRouter.surfaceMode(for: surfaceView)
            refresh()
        }
        .onDisappear { tabMonitor.stop() }
        .onReceive(timer) { _ in refresh() }
        .onChange(of: showsModePicker) { visible in
            if !visible { DispatchQueue.main.async { surfaceView.focus() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .promptModeDidChange)) { note in
            guard note.object as AnyObject? === surfaceView else { return }
            withAnimation(.easeOut(duration: 0.1)) {
                selectedSurfaceMode = note.userInfo?[Notification.Name.PromptModeKey] as? PromptSurfaceMode
                    ?? PromptNativeInputRouter.surfaceMode(for: surfaceView)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .promptShowModePicker)) { note in
            guard note.object as AnyObject? === surfaceView else { return }
            showsModePicker = false
            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                showsKeyboardModePicker = true
            }
            tabMonitor.start(for: surfaceView)
            surfaceView.focus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .promptSurfaceDidClick)) { note in
            guard note.object as AnyObject? === surfaceView else { return }
            withAnimation(.easeOut(duration: 0.12)) { showsKeyboardModePicker = false }
            tabMonitor.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .promptDismissModePicker)) { note in
            guard note.object as AnyObject? === surfaceView else { return }
            withAnimation(.easeOut(duration: 0.12)) { showsKeyboardModePicker = false }
            tabMonitor.stop()
            surfaceView.focus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .promptFocusCommandBar)) { note in
            guard note.object as AnyObject? === surfaceView else { return }
            PromptNativeInputRouter.setOverride(.ai, for: surfaceView)
            refresh()
            surfaceView.focus()
        }
        .onDisappear { tabMonitor.stop() }
    }

    private func refresh() {
        guard PromptTerminalEnvironment.allowsRichContent(on: surfaceView) else {
            input = nil
            return
        }
        input = PromptNativeInputRouter.promptInput(on: surfaceView)
        guard let surface = surfaceView.surface else { return }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        cursorRect = CGRect(x: x, y: y, width: width, height: max(height, surfaceView.cellSize.height))
    }

    private func openSelectorFromHover() {
        cancelHoverDismiss()
        guard !showsKeyboardModePicker else { return }
        hoverSelectionEnabled = false
        hoveredSurfaceMode = nil
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            showsKeyboardModePicker = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if showsKeyboardModePicker { hoverSelectionEnabled = true }
        }
    }

    private func scheduleHoverDismiss() {
        hoverDismissWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.12)) { showsKeyboardModePicker = false }
            hoverSelectionEnabled = false
            hoveredSurfaceMode = nil
            tabMonitor.stop()
        }
        hoverDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    private func cancelHoverDismiss() {
        hoverDismissWork?.cancel()
        hoverDismissWork = nil
    }

    private func dismissHoverSelector() {
        cancelHoverDismiss()
        withAnimation(.easeOut(duration: 0.12)) { showsKeyboardModePicker = false }
        hoverSelectionEnabled = false
        hoveredSurfaceMode = nil
        tabMonitor.stop()
        NSCursor.iBeam.set()
    }
}

private struct PromptModePicker: View {
    let selection: PromptSurfaceMode
    let supportsAgent: Bool
    let select: (PromptSurfaceMode) -> Void

    private func details(_ mode: PromptSurfaceMode) -> (String, String) {
        switch mode {
        case .autoShell: (mode.icon, "Run shell syntax directly; otherwise use Assistant")
        case .shell: (mode.icon, "Send every submission directly to the shell")
        case .assistant: (mode.icon, "Answer, inspect terminal state, and insert commands for review")
        case .agent: (mode.icon, "Perform bounded terminal tasks with approval before execution")
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(PromptSurfaceMode.allCases, id: \.self) { mode in
                let detail = details(mode)
                let available = mode != .agent || supportsAgent
                Button { select(mode) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: detail.0).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.rawValue).fontWeight(.semibold)
                            Text(available ? detail.1 : "Unavailable for remote sessions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .frame(width: 260, alignment: .leading)
                        }
                        Spacer(minLength: 18)
                        if mode == selection { Image(systemName: "checkmark").foregroundStyle(.mint) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!available)
                .opacity(available ? 1 : 0.42)
            }
        }
        .font(.custom(PromptTypography.sans, size: 12))
        .padding(6)
        .frame(width: 360)
    }
}

private struct PromptModePickerPreview: View {
    let selection: PromptSurfaceMode
    let supportsAgent: Bool
    let hovered: PromptSurfaceMode?
    let hoverSelect: (PromptSurfaceMode) -> Void
    let confirm: (PromptSurfaceMode) -> Void

    private func details(_ mode: PromptSurfaceMode) -> (String, String) {
        switch mode {
        case .autoShell: (mode.icon, "Run shell syntax directly; otherwise use Assistant")
        case .shell: (mode.icon, "Send every submission directly to the shell")
        case .assistant: (mode.icon, "Answer, inspect terminal state, and insert commands for review")
        case .agent: (mode.icon, "Perform bounded terminal tasks with approval before execution")
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(PromptSurfaceMode.allCases, id: \.self) { mode in
                let detail = details(mode)
                let available = mode != .agent || supportsAgent
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: detail.0).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.rawValue).fontWeight(.semibold)
                            Text(available ? detail.1 : "Unavailable for remote sessions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .frame(width: 260, alignment: .leading)
                        }
                    }
                    .foregroundStyle(Color.primary)
                    .scaleEffect(hovered == mode ? 1.018 : 1, anchor: .leading)
                    .offset(x: hovered == mode ? 3 : 0)
                    .animation(.spring(response: 0.18, dampingFraction: 0.72), value: hovered)
                    Spacer(minLength: 18)
                    if mode == selection { Image(systemName: "checkmark").foregroundStyle(.mint) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .contentShape(Rectangle())
                .opacity(available ? 1 : 0.42)
                .onHover { hovering in
                    if hovering && available { hoverSelect(mode) }
                }
                .onTapGesture { if available { confirm(mode) } }
            }
        }
        .font(.custom(PromptTypography.sans, size: 12))
        .padding(6)
        .frame(width: 360)
    }
}

struct PromptNativeAutocompleteOverlay: View {
    @ObservedObject var surfaceView: PromptTerminalSurface
    @ObservedObject private var autocomplete = PromptAutocompleteModel.shared
    @State private var input: String?
    @State private var cursorRect = CGRect(x: 12, y: 12, width: 1, height: 20)
    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { _ in
            if input != nil {
                let suggestion = autocomplete.suggestion(for: surfaceView)
                if !suggestion.isEmpty {
                    let textWidth = CGFloat(max(1, suggestion.count)) * surfaceView.cellSize.width
                    let hasSelector = autocomplete.selectionLabel(for: surfaceView) != nil
                    HStack(spacing: 7) {
                        Text(suggestion).font(.custom(PromptTypography.mono, size: 14))
                            .foregroundStyle(Color.secondary.opacity(0.48))
                        if let label = autocomplete.selectionLabel(for: surfaceView) {
                            Text("\(label)  ⇧↑↓").font(.custom(PromptTypography.sans, size: 9).weight(.semibold))
                                .foregroundStyle(Color.secondary.opacity(0.42))
                        }
                    }
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .position(
                        x: cursorRect.maxX + (textWidth + (hasSelector ? 54 : 0)) / 2,
                        y: cursorRect.midY - surfaceView.cellSize.height)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { refresh() }
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        guard PromptTerminalEnvironment.allowsRichContent(on: surfaceView) else {
            input = nil
            autocomplete.clear(on: surfaceView)
            return
        }
        input = PromptNativeInputRouter.promptInput(on: surfaceView)
        if let input { autocomplete.observe(prefix: input, on: surfaceView) }
        guard let surface = surfaceView.surface else { return }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        cursorRect = CGRect(x: x, y: y, width: width, height: max(height, surfaceView.cellSize.height))
    }
}

/// The single input surface for Prompt. Shell submissions go to the PTY; AI
/// submissions go to Codex and render back into the same Ghostty scrollback.
struct PromptTerminalCommandBar: View {
    @ObservedObject var surfaceView: PromptTerminalSurface
    let presentation: PromptComposerPresentation
    @ObservedObject private var model = PromptModel.shared
    @State private var text = ""
    @State private var routeOverride: PromptRouteOverride = .automatic
    @State private var isComposerVisible = false
    @FocusState private var focused: Bool
    @State private var cursorRect = CGRect(x: 12, y: 12, width: 1, height: 20)
    private let cursorTimer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    init(surfaceView: PromptTerminalSurface, presentation: PromptComposerPresentation = .commandBar) {
        self.surfaceView = surfaceView
        self.presentation = presentation
    }

    private var detectedMode: PromptInputMode {
        switch routeOverride {
        case .automatic: PromptInputClassifier.classify(text)
        case .shell: .shell
        case .ai: .ai
        }
    }

    var body: some View {
        Group {
            switch presentation {
            case .commandBar:
                composer
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                    .overlay(alignment: .top) { Divider() }
            case .inline:
                GeometryReader { geometry in
                    let available = max(180, geometry.size.width - cursorRect.minX - 8)
                    if isComposerVisible {
                        inlineComposer
                            .frame(width: min(560, available), height: max(22, cursorRect.height))
                            .position(
                                x: cursorRect.minX + min(560, available) / 2,
                                y: min(cursorRect.midY, geometry.size.height - cursorRect.height / 2))
                    }
                }
            }
        }
        .onReceive(cursorTimer) { _ in refreshCursorRect() }
        .onAppear {
            refreshCursorRect()
            if presentation == .inline && !PromptTerminalCapabilities.isManagedRemote(surfaceView) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { activateComposer() }
            }
        }
        .onDisappear { setTerminalCursorVisible(true) }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyCommandDidFinish)) { note in
            guard note.object as AnyObject? === surfaceView else { return }
            guard !model.isRunning else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { activateComposer() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .promptSurfaceDidClick)) { note in
            guard note.object as AnyObject? === surfaceView, isComposerVisible else { return }
            focused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .promptFocusCommandBar)) { note in
            guard note.object as AnyObject? === surfaceView else { return }
            routeOverride = .ai
            if presentation == .inline { activateComposer() } else { focused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .promptProposeCommand)) { note in
            guard note.object as AnyObject? === surfaceView,
                  let command = note.userInfo?[Notification.Name.PromptCommandKey] as? String else { return }
            text = command
            routeOverride = .shell
            if presentation == .inline { activateComposer() } else { focused = true }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Menu {
                    Picker("Input routing", selection: $routeOverride) {
                        ForEach(PromptRouteOverride.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: detectedMode == .shell ? "terminal" : "sparkles")
                        Text(routeOverride == .automatic ? detectedMode.rawValue : routeOverride.rawValue)
                        if routeOverride == .automatic { Text("Auto").foregroundStyle(.tertiary) }
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.custom(PromptTypography.sans, size: 11).weight(.semibold))
                    .foregroundStyle(detectedMode == .ai ? Color.mint : Color.primary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .menuStyle(.borderlessButton).fixedSize()

                TextField(detectedMode == .shell ? "Command" : "Message Assistant", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.custom(PromptTypography.mono, size: 14))
                    .lineLimit(1 ... 4).focused($focused)
                    .onSubmit(submit)
                if model.isRunning && detectedMode == .ai { ProgressView().controlSize(.small) }
                Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (detectedMode == .ai && model.isRunning))
            }
            if let remote = PromptTerminalCapabilities.remoteContext(for: surfaceView) {
                HStack(spacing: 5) {
                    Image(systemName: "network")
                    Text(remote.destination)
                    Text("· Terminal context and command suggestions")
                    Text("· Files and Agent unavailable")
                        .foregroundStyle(.tertiary)
                }
                .font(.custom(PromptTypography.sans, size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            }
        }
    }

    /// A prompt-row editor, not a command bar. The shell's own prompt remains
    /// in Ghostty cells immediately to the left of this view.
    private var inlineComposer: some View {
        HStack(spacing: 5) {
            Menu {
                Picker("Input routing", selection: $routeOverride) {
                    ForEach(PromptRouteOverride.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: detectedMode == .shell ? "terminal" : "sparkles")
                    .font(.custom(PromptTypography.sans, size: 11).weight(.semibold))
                    .foregroundStyle(detectedMode == .ai ? Color.mint : Color.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            TextField(detectedMode == .shell ? "command" : "ask Prompt", text: $text)
                .textFieldStyle(.plain)
                .font(.custom(PromptTypography.mono, size: 14))
                .focused($focused)
                .onSubmit(submit)

            if model.isRunning && detectedMode == .ai {
                ProgressView().controlSize(.mini)
            }
            if PromptTerminalCapabilities.isManagedRemote(surfaceView) {
                Text("Remote · terminal only · no files/Agent")
                    .font(.custom(PromptTypography.sans, size: 8).weight(.medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private func refreshCursorRect() {
        guard let terminal = surfaceView.surface else { return }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(terminal, &x, &y, &width, &height)
        let next = CGRect(x: max(8, x), y: max(4, y), width: max(1, width), height: max(surfaceView.cellSize.height, height))
        if abs(next.minX - cursorRect.minX) > 0.5 || abs(next.minY - cursorRect.minY) > 0.5 {
            cursorRect = next
        }
    }

    private func setTerminalCursorVisible(_ visible: Bool) {
        PromptLibghostty.setHostCursorVisible(visible, on: surfaceView)
    }

    private func activateComposer() {
        guard presentation == .inline else { return }
        refreshCursorRect()
        isComposerVisible = true
        setTerminalCursorVisible(false)
        focused = true
    }

    private func submit() {
        let value = PromptInputClassifier.strippedInput(text)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let mode = detectedMode
        guard model.submitFromTerminal(value, mode: mode, surface: surfaceView) else { return }
        text = ""
        if presentation == .inline {
            isComposerVisible = false
            focused = false
            setTerminalCursorVisible(true)
        }
    }
}

struct PromptPanelView: View {
    @EnvironmentObject var model: PromptModel
    @State private var showThreads = false
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if showThreads { threadPicker }
            if expanded {
                Divider()
                timeline
            } else if let last = model.messages.last(where: { $0.kind == .assistant }) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(.mint)
                    Text(last.text).lineLimit(3).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if let command = firstCommand(in: last.text) {
                        Button("Insert") { model.insertIntoTerminal(command) }
                        Button("Run") { model.runInTerminal(command) }.buttonStyle(.borderedProminent)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.bottom, 8)
            }
            if !model.approvals.isEmpty { approvals }
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 520, minHeight: expanded ? 460 : 170)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Assistant").font(.subheadline.weight(.semibold))
                Text(model.projectRoot.promptDisplayPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(model.selectedModel.contains("spark") ? "Spark" : model.selectedModel)
                .font(.caption.weight(.medium)).foregroundStyle(.mint).lineLimit(1)
            Button { showThreads.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }
                .help("Project threads")
            Button { expanded.toggle() } label: { Image(systemName: expanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical") }
                .help(expanded ? "Hide AI history" : "Show AI history")
            Menu {
                Text(model.rateLimits)
                Button("New thread", action: model.newThread)
                Button("Fork thread", action: model.forkThread)
                Button("Resume in terminal", action: model.handoffCLI)
                Button("Open in Codex app", action: model.openCodexDesktop)
                Divider()
                Button("Archive thread", role: .destructive, action: model.archiveThread)
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var threadPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(model.threads) { thread in
                    Button {
                        model.select(thread); showThreads = false
                    } label: {
                        VStack(alignment: .leading) {
                            Text(thread.title).lineLimit(1)
                            Text(URL(fileURLWithPath: thread.cwd).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        }.frame(width: 180, alignment: .leading).padding(8)
                    }.buttonStyle(.bordered)
                }
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }.background(.quaternary.opacity(0.4))
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("AI, where your shell context already is.").font(.title2.bold())
                            Text("Prompt captured the visible terminal and resolved this Codex project. Ask for an explanation, a fix, or the next command.").foregroundStyle(.secondary)
                            HStack {
                                suggestion("Explain the last error")
                                suggestion("What changed in this project?")
                                suggestion("Propose the next command")
                            }
                        }.padding(24)
                    }
                    ForEach(model.messages) { message in
                        messageCard(message).id(message.id)
                    }
                    if model.isRunning { ProgressView().controlSize(.small).padding(.leading, 18) }
                }.padding(.vertical, 14)
            }
            .onChange(of: model.messages.count) { _ in
                if let id = model.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    private func messageCard(_ message: PromptMessage) -> some View {
        HStack {
            if message.kind == .user { Spacer(minLength: 70) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.kind == .user ? "You" : message.kind == .assistant ? "Codex" : "Activity")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Text(message.text).textSelection(.enabled).font(message.kind == .activity ? .system(.body, design: .monospaced) : .body)
                if message.kind == .assistant, let command = firstCommand(in: message.text) {
                    HStack {
                        Button("Insert") { model.insertIntoTerminal(command) }
                        Button("Run") { model.runInTerminal(command) }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(12)
            .background(message.kind == .user ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            if message.kind != .user { Spacer(minLength: 50) }
        }.padding(.horizontal, 16)
    }

    private var approvals: some View {
        VStack(spacing: 8) {
            ForEach(model.approvals) { approval in
                HStack {
                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                    Text(approval.summary).lineLimit(2)
                    Spacer()
                    Button("Decline") { model.approve(approval, decision: "decline") }
                    Button("Allow") { model.approve(approval, decision: "accept") }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(12).background(.orange.opacity(0.08))
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom) {
                Button(action: model.captureTerminal) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Refresh terminal context")
                TextField("Message the terminal assistant…", text: $model.prompt, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1 ... 5)
                    .onSubmit(model.send)
                Button(action: model.send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).disabled(model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRunning)
            }
            .padding(9).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text(model.status).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                Text("⌘⇧Space to hide").font(.caption2).foregroundStyle(.tertiary)
            }
        }.padding(.horizontal, 12).padding(.bottom, 10)
    }

    private func suggestion(_ title: String) -> some View {
        Button(title) { model.prompt = title; model.send() }.buttonStyle(.bordered)
    }

    private func firstCommand(in text: String) -> String? {
        guard let start = text.range(of: "```") else { return nil }
        let after = text[start.upperBound...]
        guard let newline = after.firstIndex(of: "\n") else { return nil }
        let body = after[after.index(after: newline)...]
        guard let end = body.range(of: "```") else { return nil }
        let command = body[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}
