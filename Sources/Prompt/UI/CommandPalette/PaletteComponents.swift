import SwiftUI
import UniformTypeIdentifiers
import AppKit

private struct PromptGlassEffectContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

extension View {
    @ViewBuilder
    func promptLiquidGlassSurface(tint: Color? = nil, cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                tint.map { Glass.regular.tint($0) } ?? .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }

    @ViewBuilder
    func promptGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self.buttonStyle(.plain)
        }
    }

    func promptPaletteFooterAction(active: Bool = false) -> some View {
        modifier(PromptPaletteFooterActionModifier(active: active))
    }
}

private struct PromptPaletteFooterActionModifier: ViewModifier {
    let active: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .padding(.horizontal, 9)
            .frame(height: 38)
            .background(
                Color.primary.opacity(active || isHovered ? 0.075 : 0),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: active || isHovered)
    }
}

struct PromptCommandAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let shortcut: [String]
    let action: () -> Void
}

private struct PromptCommandPresentation {
    private(set) var id = UUID()
    let title: String
    private(set) var subtitle: String?
    private(set) var description: String?
    private(set) var symbols: [String]?
    private(set) var leadingIcon: String?
    private(set) var leadingColor: Color?
    private(set) var badge: String?
    private(set) var emphasis = false
    private(set) var contextualActions: (() -> [PromptCommandAction])?
    private(set) var primaryActionTitle: String
    private(set) var opensDestination = false
    private(set) var isEnabled = true

    init(_ title: String) {
        self.title = title
        self.primaryActionTitle = title
    }

    func identified(by id: UUID) -> Self {
        setting(\.id, to: id)
    }

    func subtitle(_ value: String?) -> Self {
        setting(\.subtitle, to: value)
    }

    func help(_ value: String?) -> Self {
        setting(\.description, to: value)
    }

    func shortcut(_ symbols: String...) -> Self {
        setting(\.symbols, to: symbols)
    }

    func shortcut(_ symbols: [String]) -> Self {
        setting(\.symbols, to: symbols)
    }

    func icon(_ name: String?) -> Self {
        setting(\.leadingIcon, to: name)
    }

    func color(_ value: Color?) -> Self {
        setting(\.leadingColor, to: value)
    }

    func badge(_ value: String?) -> Self {
        setting(\.badge, to: value)
    }

    func emphasized(_ value: Bool = true) -> Self {
        setting(\.emphasis, to: value)
    }

    func primaryAction(_ title: String) -> Self {
        setting(\.primaryActionTitle, to: title)
    }

    func actions(_ actions: @escaping () -> [PromptCommandAction]) -> Self {
        setting(\.contextualActions, to: actions)
    }

    func destination(_ value: Bool = true) -> Self {
        setting(\.opensDestination, to: value)
    }

    func enabled(_ value: Bool) -> Self {
        setting(\.isEnabled, to: value)
    }

    private func setting<Value>(
        _ keyPath: WritableKeyPath<Self, Value>,
        to value: Value
    ) -> Self {
        var copy = self
        copy[keyPath: keyPath] = value
        return copy
    }

    var hasActionMenu: Bool {
        !(contextualActions?().isEmpty ?? true)
    }
}

private struct PromptRenderedCommand: Equatable {
    let presentation: PromptCommandPresentation
    let activate: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.presentation.id == rhs.presentation.id &&
            lhs.presentation.title == rhs.presentation.title &&
            lhs.presentation.subtitle == rhs.presentation.subtitle &&
            lhs.presentation.primaryActionTitle == rhs.presentation.primaryActionTitle &&
            lhs.presentation.hasActionMenu == rhs.presentation.hasActionMenu &&
            lhs.presentation.opensDestination == rhs.presentation.opensDestination &&
            lhs.presentation.isEnabled == rhs.presentation.isEnabled
    }
}

private struct PromptRenderedCommandsKey: PreferenceKey {
    static var defaultValue: [PromptRenderedCommand] = []

    static func reduce(
        value: inout [PromptRenderedCommand],
        nextValue: () -> [PromptRenderedCommand]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct PromptPaletteQueryKey: EnvironmentKey {
    static let defaultValue = ""
}

private struct PromptPaletteSelectionKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

private struct PromptPaletteHoverKey: EnvironmentKey {
    static let defaultValue: (UUID) -> Void = { _ in }
}

private extension EnvironmentValues {
    var promptPaletteQuery: String {
        get { self[PromptPaletteQueryKey.self] }
        set { self[PromptPaletteQueryKey.self] = newValue }
    }

    var promptPaletteSelection: UUID? {
        get { self[PromptPaletteSelectionKey.self] }
        set { self[PromptPaletteSelectionKey.self] = newValue }
    }

    var promptPaletteHover: (UUID) -> Void {
        get { self[PromptPaletteHoverKey.self] }
        set { self[PromptPaletteHoverKey.self] = newValue }
    }
}

/// A command is a rendered SwiftUI primitive. The page discovers visible
/// commands through preferences solely for keyboard navigation; the registry
/// never drives view construction.
struct PromptPaletteCommand: View {
    private var presentation: PromptCommandPresentation
    private var action: () -> Void
    private var destination: (() -> AnyView)?
    @State private var id = UUID()

    init(_ title: String, action: @escaping () -> Void = {}) {
        presentation = PromptCommandPresentation(title)
        self.action = action
    }

    var body: some View {
        PromptPaletteCommandBody(
            presentation: presentation.identified(by: id),
            action: action,
            destination: destination)
    }

    func subtitle(_ value: String?) -> Self { modifying { $0.presentation = $0.presentation.subtitle(value) } }
    func help(_ value: String?) -> Self { modifying { $0.presentation = $0.presentation.help(value) } }
    func shortcut(_ symbols: String...) -> Self { modifying { $0.presentation = $0.presentation.shortcut(symbols) } }
    func icon(_ name: String?) -> Self { modifying { $0.presentation = $0.presentation.icon(name) } }
    func color(_ value: Color?) -> Self { modifying { $0.presentation = $0.presentation.color(value) } }
    func badge(_ value: String?) -> Self { modifying { $0.presentation = $0.presentation.badge(value) } }
    func emphasized(_ value: Bool = true) -> Self {
        modifying { $0.presentation = $0.presentation.emphasized(value) }
    }
    func primaryAction(_ title: String) -> Self {
        modifying { $0.presentation = $0.presentation.primaryAction(title) }
    }
    func actions(_ actions: @escaping () -> [PromptCommandAction]) -> Self {
        modifying { $0.presentation = $0.presentation.actions(actions) }
    }
    func enabled(_ value: Bool) -> Self {
        modifying { $0.presentation = $0.presentation.enabled(value) }
    }

    func destination<Destination: View>(
        title: String? = nil,
        @ViewBuilder _ destination: @escaping () -> Destination
    ) -> Self {
        modifying {
            $0.presentation = $0.presentation.destination()
            if let title {
                $0.presentation = $0.presentation.primaryAction(title)
            }
            $0.destination = { AnyView(destination()) }
        }
    }

    private func modifying(_ transform: (inout Self) -> Void) -> Self {
        var copy = self
        transform(&copy)
        return copy
    }
}

private struct PromptPaletteCommandBody: View {
    let presentation: PromptCommandPresentation
    let action: () -> Void
    let destination: (() -> AnyView)?
    @EnvironmentObject private var navigator: PromptPaletteNavigator
    @Environment(\.promptPaletteQuery) private var query
    @Environment(\.promptPaletteSelection) private var selectedID
    @Environment(\.promptPaletteHover) private var hover

    private var matches: Bool {
        query.isEmpty ||
            presentation.title.promptMatchedIndices(for: query) != nil ||
            presentation.subtitle?.promptMatchedIndices(for: query) != nil ||
            colorMatchScore > 0
    }

    private var colorMatchScore: Double {
        guard let color = presentation.leadingColor else { return 0 }
        let platformColor = NSColor(color)
        return NSColor.colorNames.reduce(into: 0) { best, name in
            guard query.lowercased().contains(name),
                  let candidate = NSColor(named: name) else { return }
            let distance = platformColor.distance(to: candidate)
            if distance < 1.5 {
                best = max(best, 1 - (distance / 1.5))
            }
        }
    }

    var body: some View {
        if matches {
            CommandRow(
                presentation: presentation,
                query: query,
                isSelected: selectedID == presentation.id,
                onHover: {
                    if presentation.isEnabled {
                        hover(presentation.id)
                    }
                },
                action: activate)
                .disabled(!presentation.isEnabled)
                .opacity(presentation.isEnabled ? 1 : 0.45)
                .id(presentation.id)
                .preference(
                    key: PromptRenderedCommandsKey.self,
                    value: [PromptRenderedCommand(presentation: presentation, activate: activate)])
        }
    }

    private func activate() {
        if let destination {
            navigator.push(destination)
            return
        }
        action()
    }
}

struct PromptPaletteDestinationID: Hashable {
    let rawValue = UUID()
}

@MainActor
final class PromptPaletteNavigator: ObservableObject {
    @Published var path: [PromptPaletteDestinationID] = []
    private var destinations: [PromptPaletteDestinationID: () -> AnyView] = [:]

    func push(_ destination: @escaping () -> AnyView) {
        let id = PromptPaletteDestinationID()
        destinations[id] = destination
        path.append(id)
    }

    func pop() {
        if let removed = path.popLast() {
            destinations.removeValue(forKey: removed)
        }
    }

    func reset() {
        path.removeAll()
        destinations.removeAll()
    }

    @ViewBuilder
    func destination(for id: PromptPaletteDestinationID) -> some View {
        if let destination = destinations[id] {
            destination()
                .environmentObject(self)
        }
    }
}

struct PromptPaletteHost<Root: View>: View {
    @ViewBuilder let root: () -> Root
    @StateObject private var navigator = PromptPaletteNavigator()

    var body: some View {
        NavigationStack(path: $navigator.path) {
            root()
                .environmentObject(navigator)
                .navigationDestination(for: PromptPaletteDestinationID.self) { id in
                    navigator.destination(for: id)
                }
        }
        .onDisappear { navigator.reset() }
    }
}

struct PromptPaletteSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @State private var hasVisibleCommands = true

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Section {
            content()
        } header: {
            if hasVisibleCommands {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
            }
        }
        .onPreferenceChange(PromptRenderedCommandsKey.self) {
            hasVisibleCommands = !$0.isEmpty
        }
    }
}

private struct PromptPaletteScrollMetrics: Equatable {
    var contentHeight: CGFloat = 0
    var contentOffset: CGFloat = 0
}

private struct PromptPaletteScrollObserver: NSViewRepresentable {
    final class MarkerView: NSView {
        var onChange: (PromptPaletteScrollMetrics, CGFloat) -> Void
        private weak var observedScrollView: NSScrollView?
        private var observations: [NSObjectProtocol] = []

        init(onChange: @escaping (PromptPaletteScrollMetrics, CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            observations.forEach(NotificationCenter.default.removeObserver)
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attachToScrollView()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachToScrollView()
        }

        func attachToScrollView() {
            guard let scrollView = enclosingScrollView else {
                DispatchQueue.main.async { [weak self] in
                    self?.attachToScrollView()
                }
                return
            }
            guard observedScrollView !== scrollView else {
                publishMetrics()
                return
            }

            observations.forEach(NotificationCenter.default.removeObserver)
            observations.removeAll()
            observedScrollView = scrollView
            // Keep the document viewport full-width. The custom indicator is
            // drawn over the outer gutter and must not reserve a native
            // scroller column from the command rows.
            scrollView.scrollerStyle = .overlay
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.hasVerticalScroller = false
            scrollView.verticalScroller?.isHidden = true
            scrollView.autohidesScrollers = true
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.documentView?.postsFrameChangedNotifications = true

            observations.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.publishMetrics()
            })
            if let documentView = scrollView.documentView {
                observations.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: documentView,
                    queue: .main
                ) { [weak self] _ in
                    self?.publishMetrics()
                })
            }
            publishMetrics()
        }

        func publishMetrics() {
            guard let scrollView = observedScrollView else { return }
            let viewportHeight = scrollView.contentView.bounds.height
            let contentHeight = scrollView.documentView?.frame.height ?? viewportHeight
            let contentOffset = max(0, scrollView.contentView.bounds.minY)
            let metrics = PromptPaletteScrollMetrics(
                contentHeight: contentHeight,
                contentOffset: contentOffset)
            DispatchQueue.main.async { [weak self] in
                self?.onChange(metrics, viewportHeight)
            }
        }
    }

    func makeNSView(context: Context) -> MarkerView {
        MarkerView(onChange: onChange)
    }

    func updateNSView(_ marker: MarkerView, context: Context) {
        marker.onChange = onChange
        marker.attachToScrollView()
    }

    let onChange: (PromptPaletteScrollMetrics, CGFloat) -> Void
}

private struct PromptPaletteScrollView<Content: View>: View {
    let selectedID: UUID?
    @ViewBuilder let content: () -> Content

    @State private var metrics = PromptPaletteScrollMetrics()
    @State private var viewportHeight: CGFloat = 0
    @State private var indicatorIsVisible = false
    @State private var didRevealInitially = false
    @State private var fadeTask: Task<Void, Never>?

    private var isScrollable: Bool {
        metrics.contentHeight > viewportHeight + 1
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    content()
                        .background {
                            PromptPaletteScrollObserver { updated, measuredViewportHeight in
                                updateMetrics(updated, viewportHeight: measuredViewportHeight)
                            }
                            .frame(width: 0, height: 0)
                        }
                }
                .scrollIndicators(.hidden)
                .overlay(alignment: .trailing) {
                    if isScrollable {
                        scrollThumb
                            .opacity(indicatorIsVisible ? 1 : 0)
                            .animation(.easeOut(duration: 0.18), value: indicatorIsVisible)
                    }
                }
                .onAppear {
                    viewportHeight = geometry.size.height
                }
                .onChange(of: geometry.size.height) { height in
                    viewportHeight = height
                    revealInitiallyIfNeeded()
                }
                .onChange(of: selectedID) { id in
                    if let id {
                        proxy.scrollTo(id)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .onDisappear {
            fadeTask?.cancel()
        }
    }

    private var scrollThumb: some View {
        let availableHeight = max(0, viewportHeight - 12)
        let proportionalHeight = availableHeight * viewportHeight / metrics.contentHeight
        let thumbHeight = min(56, max(28, proportionalHeight))
        let maximumOffset = max(1, metrics.contentHeight - viewportHeight)
        let progress = min(1, max(0, metrics.contentOffset / maximumOffset))
        let thumbOffset = progress * max(0, availableHeight - thumbHeight)

        return ZStack(alignment: .topTrailing) {
            Capsule()
                .fill(Color.primary.opacity(0.48))
                .frame(width: 4, height: thumbHeight)
                .offset(y: 6 + thumbOffset)
                .animation(.linear(duration: 0.08), value: thumbOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.trailing, 4)
        .allowsHitTesting(false)
    }

    private func revealInitiallyIfNeeded() {
        guard isScrollable, !didRevealInitially else { return }
        didRevealInitially = true
        revealIndicator()
    }

    private func updateMetrics(_ updated: PromptPaletteScrollMetrics, viewportHeight: CGFloat) {
        let didScroll = abs(updated.contentOffset - metrics.contentOffset) > 0.5
        metrics = updated
        self.viewportHeight = viewportHeight
        if didScroll {
            revealIndicator()
        } else {
            revealInitiallyIfNeeded()
        }
    }

    private func revealIndicator() {
        guard isScrollable else { return }
        fadeTask?.cancel()
        withAnimation(.easeOut(duration: 0.1)) {
            indicatorIsVisible = true
        }
        fadeTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.28)) {
                    indicatorIsVisible = false
                }
            }
        }
    }
}

struct PromptPalettePage<Content: View>: View {
    @ObservedObject var store: PromptWorkspaceStore
    @Binding var isPresented: Bool
    var title: String?
    @ViewBuilder let content: () -> Content

    @EnvironmentObject private var navigator: PromptPaletteNavigator
    @State private var query = ""
    @State private var commands: [PromptRenderedCommand] = []
    @State private var selectedID: UUID?
    @State private var actionsArePresented = false
    @State private var keyboardOwner = UUID()
    @State private var pointerLocationAtKeyboardNavigation: CGPoint?
    @State private var pointerTrackingStarted = false

    private var selectedCommand: PromptRenderedCommand? {
        commands.first { $0.presentation.id == selectedID } ?? commands.first
    }

    private var searchQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                CommandPaletteQuery(
                    query: $query,
                    title: title,
                    canGoBack: !navigator.path.isEmpty,
                    onBack: goBack)

                Divider().opacity(0.55)

                PromptPaletteScrollView(selectedID: selectedID) {
                    VStack(alignment: .leading, spacing: 3) {
                        content()
                    }
                    .padding(.horizontal, 10)
                    .environment(\.promptPaletteQuery, searchQuery)
                    .environment(\.promptPaletteSelection, selectedID)
                    .environment(\.promptPaletteHover, pointerSelected)
                }
                .frame(maxHeight: 420)
                .allowsHitTesting(!actionsArePresented)
                .onPreferenceChange(PromptRenderedCommandsKey.self, perform: updateCommands)

                Divider().opacity(0.55)
                footer
            }

            if actionsArePresented, let selectedCommand, selectedCommand.presentation.hasActionMenu {
                CommandActionsView(
                    presentation: selectedCommand.presentation,
                    keyboard: store.inputRouter,
                    onPrimary: { activate(selectedCommand) },
                    onDismiss: dismissActions)
                    .frame(width: 330)
                    .padding(.trailing, 12)
                    .padding(.bottom, 54)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                    .zIndex(4)
            }
        }
        .onAppear {
            pointerLocationAtKeyboardNavigation = NSEvent.mouseLocation
            pointerTrackingStarted = true
            claimKeyboard()
        }
        .onDisappear {
            store.inputRouter.release(owner: keyboardOwner)
        }
        .onChange(of: query) { _ in
            selectedID = commands.first?.presentation.id
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            PaletteHint(keys: ["↑", "↓"], label: "Navigate")
            Spacer()
            if let selectedCommand {
                if selectedCommand.presentation.hasActionMenu {
                    Button { toggleActions() } label: {
                        PaletteLabelFirstHint(label: "Actions", keys: ["⌘", "K"])
                    }
                    .promptPaletteFooterAction(active: actionsArePresented)

                    Divider().frame(height: 18).opacity(0.45)
                }

                Button { activate(selectedCommand) } label: {
                    PaletteLabelFirstHint(
                        label: selectedCommand.presentation.opensDestination ? "Open" : "Run",
                        systemKeys: ["return"])
                }
                .promptPaletteFooterAction()
            }
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 18)
        .frame(height: 48)
    }

    private func updateCommands(_ updated: [PromptRenderedCommand]) {
        let enabled = updated.filter(\.presentation.isEnabled)
        commands = enabled
        if let selectedID, enabled.contains(where: { $0.presentation.id == selectedID }) {
            return
        }
        selectedID = enabled.first?.presentation.id
    }

    private func pointerSelected(_ id: UUID) {
        let location = NSEvent.mouseLocation
        guard pointerTrackingStarted,
              PromptPalettePointerPolicy.hasMoved(
                  from: pointerLocationAtKeyboardNavigation,
                  to: location) else { return }
        pointerLocationAtKeyboardNavigation = nil
        selectedID = id
    }

    private func activate(_ command: PromptRenderedCommand) {
        guard command.presentation.isEnabled else { return }
        actionsArePresented = false
        if command.presentation.opensDestination {
            command.activate()
        } else {
            isPresented = false
            command.activate()
        }
    }

    private func move(_ offset: Int) {
        guard !commands.isEmpty else { return }
        pointerLocationAtKeyboardNavigation = NSEvent.mouseLocation
        let current = commands.firstIndex { $0.presentation.id == selectedID } ?? 0
        selectedID = commands[(current + offset + commands.count) % commands.count].presentation.id
    }

    private func claimKeyboard() {
        store.inputRouter.claim(owner: keyboardOwner, acceptsTextInput: true) { command in
            switch command {
            case .moveUp: move(-1)
            case .moveDown: move(1)
            case .submit:
                if let selectedCommand { activate(selectedCommand) }
            case .back:
                if actionsArePresented {
                    actionsArePresented = false
                } else {
                    goBack()
                }
            case .actions: toggleActions()
            case .delete, .textInput: return false
            }
            return true
        }
    }

    private func goBack() {
        if navigator.path.isEmpty {
            isPresented = false
        } else {
            navigator.pop()
        }
    }

    private func toggleActions() {
        guard selectedCommand?.presentation.hasActionMenu == true else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            actionsArePresented.toggle()
        }
    }

    private func dismissActions() {
        actionsArePresented = false
    }
}

struct PromptPaletteSubmitGate {
    private(set) var isLatched = false

    mutating func begin() -> Bool {
        guard !isLatched else { return false }
        isLatched = true
        return true
    }

    mutating func reset() {
        isLatched = false
    }
}

private struct PromptSidebarVisualEditor: View {
    @ObservedObject var store: PromptWorkspaceStore
    let keyboard: PromptInputRouter
    let onBack: () -> Void
    @State private var selection: UUID?
    @State private var actionsVisible = false
    @State private var keyboardOwner = UUID()

    private var groups: [(String, [PromptSession])] {
        let sessions = store.orderedSessions
        var result = store.sidebarFolders.map { folder in (folder, sessions.filter { store.folder(for: $0) == folder }) }
        let automatic = sessions.filter { store.folder(for: $0) == nil }
        let names = Array(Set(automatic.map { machine($0.configuration) })).sorted()
        result += names.map { name in (name, automatic.filter { machine($0.configuration) == name }) }
        return result
    }
    private var sessions: [PromptSession] { groups.flatMap(\.1) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    PaletteHeaderLeading(canGoBack: true, onBack: onBack)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Edit sidebar").font(.system(size: 17, weight: .semibold))
                        Text("Drag sessions into groups or reorder them").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { createFolder() } label: { Label("Folder", systemImage: "folder.badge.plus") }.promptGlassButtonStyle()
                }.padding(.horizontal, 18).frame(height: 62)
                Divider().opacity(0.55)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(groups, id: \.0) { name, sessions in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Image(systemName: store.sidebarFolders.contains(name) ? "folder" : "desktopcomputer")
                                    Text(name).fontWeight(.semibold)
                                    Spacer(); Text("\(sessions.count)").foregroundStyle(.tertiary)
                                }
                                .font(.system(size: 13)).padding(.horizontal, 10).frame(height: 32)
                                .contextMenu { folderMenu(name) }
                                .modifier(PromptSessionDropTarget(store: store, target: sessions.first?.id, folder: store.sidebarFolders.contains(name) ? name : nil))
                                ForEach(sessions) { session in
                                    editorRow(session)
                                        .draggable(PromptSessionDragPayload(id: session.id))
                                        .modifier(PromptSessionDropTarget(store: store, target: session.id, folder: store.sidebarFolders.contains(name) ? name : nil))
                                }
                                if sessions.isEmpty {
                                    Text("Drop a session here").font(.caption).foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity).frame(height: 38)
                                }
                            }
                            .padding(7)
                            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }.padding(12)
                }.frame(height: 410)
                Divider().opacity(0.55)
                HStack { PaletteHint(keys: ["drag"], label: "Move"); PaletteHint(keys: ["⌘", "K"], label: "Actions"); PaletteHint(keys: ["esc"], label: "Back"); Spacer(); Text("Changes apply instantly").foregroundStyle(.tertiary) }
                    .font(.system(size: 11, weight: .medium)).padding(.horizontal, 18).frame(height: 48)
            }
            if actionsVisible, let session = selectedSession {
                CommandActionsView(
                    presentation: actionPresentation(session),
                    keyboard: keyboard,
                    onPrimary: { store.focus(sessionID: session.id, paneID: session.focusedPaneID) },
                    onDismiss: dismissActions,
                    customActions: actionItems(session))
                    .frame(width: 330).padding(.trailing, 12).padding(.bottom, 54)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
        }
        .onAppear {
            if selection == nil { selection = sessions.first?.id }
            claimKeyboard()
        }
        .onDisappear { keyboard.release(owner: keyboardOwner) }
    }

    private var selectedSession: PromptSession? { selection.flatMap { id in store.workspace.sessions.first { $0.id == id } } }

    private func editorRow(_ session: PromptSession) -> some View {
        Button { selection = session.id; actionsVisible = false } label: {
            HStack(spacing: 10) {
                Image(systemName: session.configuration.isRemote ? "network" : "terminal").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) { Text(session.title).fontWeight(.medium); Text((store.runtime.surface(for: session.focusedPaneID)?.workingDirectory ?? session.configuration.configuredDirectory ?? "Starting…").promptDisplayPath).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer(); Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            }.padding(.horizontal, 10).frame(height: 48).contentShape(Rectangle())
                .background(selection == session.id ? PromptTheme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).contextMenu { sessionMenu(session) }
    }

    private func actionPresentation(_ session: PromptSession) -> PromptCommandPresentation {
        PromptCommandPresentation(session.title)
            .subtitle((store.runtime.surface(for: session.focusedPaneID)?.workingDirectory ?? session.configuration.configuredDirectory)?.promptDisplayPath)
            .help("Sidebar session")
    }

    private func actionItems(_ session: PromptSession) -> [PromptCommandAction] {
        var items = [
            PromptCommandAction(title: "Open Session", icon: "return", shortcut: ["↩"]) { store.focus(sessionID: session.id, paneID: session.focusedPaneID) },
            PromptCommandAction(title: "Rename…", icon: "pencil", shortcut: []) { rename(session) },
            PromptCommandAction(title: "Move to Top", icon: "arrow.up.to.line", shortcut: []) { store.moveSession(session.id, before: store.workspace.sessions.first?.id) },
            PromptCommandAction(title: "Automatic Group", icon: "desktopcomputer", shortcut: []) { store.assignSession(session.id, to: nil) },
        ]
        items += store.sidebarFolders.map { folder in PromptCommandAction(title: "Move to \(folder)", icon: "folder", shortcut: []) { store.assignSession(session.id, to: folder) } }
        items.append(PromptCommandAction(title: "Close Session", icon: "xmark", shortcut: []) { store.closeSession(session.id) })
        return items
    }

    private func moveSelection(_ delta: Int) {
        guard !sessions.isEmpty else { return }
        let current = selection.flatMap { id in sessions.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : 0)
        let next = (current + delta + sessions.count) % sessions.count
        selection = sessions[next].id
        actionsVisible = false
    }

    private func claimKeyboard() {
        keyboard.claim(owner: keyboardOwner) { command in
            switch command {
            case .moveUp: moveSelection(-1)
            case .moveDown: moveSelection(1)
            case .actions:
                if selectedSession != nil {
                    withAnimation(.easeOut(duration: 0.14)) { actionsVisible.toggle() }
                }
            case .back:
                if actionsVisible { actionsVisible = false } else { onBack() }
            case .submit:
                if let selectedSession {
                    store.focus(
                        sessionID: selectedSession.id,
                        paneID: selectedSession.focusedPaneID)
                }
            case .delete:
                return false
            case .textInput:
                return false
            }
            return true
        }
    }

    private func dismissActions() {
        actionsVisible = false
    }

    @ViewBuilder private func sessionMenu(_ session: PromptSession) -> some View { Button("Rename…") { rename(session) }; Menu("Move to group") { moveMenu(session) }; Divider(); Button("Close Session", role: .destructive) { store.closeSession(session.id) } }
    @ViewBuilder private func moveMenu(_ session: PromptSession) -> some View { Button("Automatic") { store.assignSession(session.id, to: nil) }; ForEach(store.sidebarFolders, id: \.self) { folder in Button(folder) { store.assignSession(session.id, to: folder) } } }
    @ViewBuilder private func folderMenu(_ name: String) -> some View { if store.sidebarFolders.contains(name) { Button("Rename…") { renameFolder(name) }; Button("Delete Folder", role: .destructive) { store.deleteSidebarFolder(name) } } }
    private func machine(_ config: PromptSessionConfiguration) -> String { switch config { case .local: "Local"; case .remote(let value): value.destination } }
    private func createFolder() { if let value = PromptSidebarPrompts.text(title: "New sidebar folder", value: "") { store.createSidebarFolder(named: value) } }
    private func rename(_ session: PromptSession) { if let value = PromptSidebarPrompts.text(title: "Rename session", value: session.title) { store.renameSession(session.id, to: value) } }
    private func renameFolder(_ name: String) { if let value = PromptSidebarPrompts.text(title: "Rename folder", value: name) { store.renameSidebarFolder(name, to: value) } }
}

struct PromptFolderPickerEntry: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    var subtitle: String? = nil
    var icon: String = "folder"
}

struct PromptFolderPickerConfiguration {
    let initialDirectory: String
    let displayName: (String) -> String
    let directories: (String) async throws -> [PromptFolderPickerEntry]
    let onSelect: (String) -> Void
    let onReveal: ((String) -> Void)?
    var cachedDirectories: ((String) -> [PromptFolderPickerEntry]?)? = nil
    var resolvePath: (String) -> String? = { PromptFolderPath.resolve($0) }
    var browsingDirectory: (String) -> String? = { PromptFolderPath.existingDirectory($0) }
    var createDirectory: ((String) throws -> Void)? = nil
    var prepareDirectory: ((String) async throws -> Void)? = nil
    var errorMessage: (Error) -> String = { $0.localizedDescription }
    var sectionTitle = "Directories"
    var actionTitle = "Add"
    var emptyText = "No subdirectories"
    var selectsEntries = false
}

struct PromptGitPickerEntry: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let repository: String
    let branch: String?
    let isMainWorktree: Bool
}

struct PromptGitPickerConfiguration {
    let cachedLocations: [PromptGitPickerEntry]
    let locations: () async throws -> [PromptGitPickerEntry]
    let onSelect: (String) -> Void
    var emptyText = "No Git repositories found"
}

struct PromptFolderPickerDestination: View {
    let configuration: PromptFolderPickerConfiguration
    @Binding var isPresented: Bool
    let keyboard: PromptInputRouter
    @EnvironmentObject private var navigator: PromptPaletteNavigator

    var body: some View {
        FolderPickerView(
            configuration: configuration,
            isPresented: $isPresented,
            keyboard: keyboard,
            onBack: navigator.pop)
    }
}

struct PromptGitPickerDestination: View {
    let configuration: PromptGitPickerConfiguration
    @Binding var isPresented: Bool
    let keyboard: PromptInputRouter
    @EnvironmentObject private var navigator: PromptPaletteNavigator

    var body: some View {
        GitPickerView(
            configuration: configuration,
            isPresented: $isPresented,
            keyboard: keyboard,
            onBack: navigator.pop)
    }
}

struct PromptSidebarEditorDestination: View {
    let store: PromptWorkspaceStore
    let keyboard: PromptInputRouter
    @EnvironmentObject private var navigator: PromptPaletteNavigator

    var body: some View {
        PromptSidebarVisualEditor(
            store: store,
            keyboard: keyboard,
            onBack: navigator.pop)
    }
}

enum PromptFolderPath {
    struct BrowsingContext: Equatable {
        let directory: String
        let query: String
        let exists: Bool
    }

    static func resolve(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(
            fileURLWithPath: (trimmed as NSString).expandingTildeInPath
        ).standardizedFileURL.path
    }

    static func existingDirectory(_ value: String, fileManager: FileManager = .default) -> String? {
        guard let resolved = resolve(value) else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return resolved
    }

    static func browsingContext(
        _ value: String,
        fileManager: FileManager = .default
    ) -> BrowsingContext? {
        guard let resolved = resolve(value) else { return nil }
        if existingDirectory(resolved, fileManager: fileManager) != nil {
            return BrowsingContext(directory: resolved, query: "", exists: true)
        }
        let url = URL(fileURLWithPath: resolved)
        let parent = url.deletingLastPathComponent().path
        guard existingDirectory(parent, fileManager: fileManager) != nil else { return nil }
        return BrowsingContext(
            directory: parent,
            query: url.lastPathComponent,
            exists: false)
    }
}

enum PromptRemoteFolderPath {
    /// Normalizes a POSIX path without consulting the local filesystem or
    /// expanding `~` to the local account's home directory.
    static func resolve(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let prefix: String
        let remainder: Substring
        if trimmed == "~" || trimmed == "~/" {
            return "~"
        } else if trimmed.hasPrefix("~/") {
            prefix = "~"
            remainder = trimmed.dropFirst(2)
        } else if trimmed.hasPrefix("/") {
            prefix = "/"
            remainder = trimmed.dropFirst()
        } else {
            return nil
        }

        var components: [Substring] = []
        for component in remainder.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        guard !components.isEmpty else { return prefix }
        return prefix == "/"
            ? "/" + components.joined(separator: "/")
            : "~/" + components.joined(separator: "/")
    }
}

private struct GitPickerView: View {
    private struct Group: Identifiable {
        var id: String { repository.path }
        let repository: PromptGitPickerEntry
        let worktrees: [PromptGitPickerEntry]
    }

    let configuration: PromptGitPickerConfiguration
    @Binding var isPresented: Bool
    let keyboard: PromptInputRouter
    let onBack: () -> Void

    @State private var query = ""
    @State private var entries: [PromptGitPickerEntry]
    @State private var selectedIndex = 0
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var keyboardOwner = UUID()
    @State private var pointerLocationAtSelection: CGPoint?

    init(
        configuration: PromptGitPickerConfiguration,
        isPresented: Binding<Bool>,
        keyboard: PromptInputRouter,
        onBack: @escaping () -> Void
    ) {
        self.configuration = configuration
        _isPresented = isPresented
        self.keyboard = keyboard
        self.onBack = onBack
        _entries = State(initialValue: configuration.cachedLocations)
        _isLoading = State(initialValue: configuration.cachedLocations.isEmpty)
    }

    private var visibleGroups: [Group] {
        let grouped = Dictionary(grouping: entries, by: \.repository)
        return grouped.keys.sorted {
            URL(fileURLWithPath: $0).lastPathComponent.localizedStandardCompare(
                URL(fileURLWithPath: $1).lastPathComponent) == .orderedAscending
        }.compactMap { repository in
            let values = grouped[repository, default: []]
            guard let main = values.first(where: \.isMainWorktree) else { return nil }
            let worktrees = values.filter { !$0.isMainWorktree }.sorted {
                ($0.branch ?? $0.name).localizedStandardCompare($1.branch ?? $1.name) == .orderedAscending
            }
            guard !query.isEmpty else { return Group(repository: main, worktrees: worktrees) }
            let repositoryMatches = matches(
                [URL(fileURLWithPath: repository).lastPathComponent, repository],
                query: query)
            let matchingWorktrees = worktrees.filter {
                matches([$0.name, $0.branch, $0.path].compactMap { $0 }, query: query)
            }
            guard repositoryMatches || !matchingWorktrees.isEmpty else { return nil }
            return Group(
                repository: main,
                worktrees: repositoryMatches ? worktrees : matchingWorktrees)
        }
    }

    private var visibleEntries: [PromptGitPickerEntry] {
        visibleGroups.flatMap { [$0.repository] + $0.worktrees }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CommandPaletteQuery(
                query: $query,
                title: "Git repositories",
                canGoBack: true,
                onBack: leavePicker)
                .onChange(of: query) { _ in selectedIndex = 0 }

            Divider().opacity(0.55)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Text("GIT REPOSITORIES")
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.7)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                            .padding(.bottom, 4)

                        ForEach(visibleGroups) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                gitRow(group.repository)
                                ForEach(group.worktrees) { worktree in
                                    gitRow(worktree)
                                }
                            }
                            .background(alignment: .topLeading) {
                                if !group.worktrees.isEmpty {
                                    GitTreeConnector(childCount: group.worktrees.count)
                                }
                            }
                        }

                        if isLoading, entries.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Finding repositories…").foregroundStyle(.secondary)
                            }
                            .padding(18)
                        } else if let loadError, entries.isEmpty {
                            Text(loadError).font(.caption).foregroundStyle(.secondary).padding(18)
                        } else if visibleEntries.isEmpty {
                            Text(query.isEmpty ? configuration.emptyText : "No matching repositories or worktrees")
                                .foregroundStyle(.secondary)
                                .padding(18)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 420)
                .onChange(of: selectedIndex) { index in
                    guard visibleEntries.indices.contains(index) else { return }
                    proxy.scrollTo(visibleEntries[index].id)
                }
            }

            Divider().opacity(0.55)
            HStack(spacing: 16) {
                PaletteHint(keys: ["↑", "↓"], label: "Navigate")
                Spacer()
                Button(action: openSelected) {
                    PaletteLabelFirstHint(label: "Open", systemKeys: ["return"])
                }
                .promptGlassButtonStyle()
                .disabled(visibleEntries.isEmpty)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 18)
            .frame(height: 48)
        }
        .task { await load() }
        .onAppear {
            pointerLocationAtSelection = NSEvent.mouseLocation
            claimKeyboard()
        }
        .onDisappear { keyboard.release(owner: keyboardOwner) }
    }

    private func matches(_ values: [String], query: String) -> Bool {
        values.contains { $0.promptMatchedIndices(for: query) != nil }
    }

    private func activate(_ entry: PromptGitPickerEntry) {
        isPresented = false
        configuration.onSelect(entry.path)
    }

    private func openSelected() {
        guard visibleEntries.indices.contains(selectedIndex) else { return }
        activate(visibleEntries[selectedIndex])
    }

    private func leavePicker() {
        keyboard.release(owner: keyboardOwner)
        onBack()
    }

    private func moveSelection(_ delta: Int) {
        let count = visibleEntries.count
        guard count > 0 else { return }
        pointerLocationAtSelection = NSEvent.mouseLocation
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func gitRow(_ entry: PromptGitPickerEntry) -> some View {
        let index = visibleEntries.firstIndex(of: entry) ?? 0
        return GitPickerRow(entry: entry, selected: selectedIndex == index) {
            activate(entry)
        }
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            let location = NSEvent.mouseLocation
            guard PromptPalettePointerPolicy.hasMoved(
                from: pointerLocationAtSelection,
                to: location
            ) else { return }
            pointerLocationAtSelection = location
            selectedIndex = index
        }
        .id(entry.id)
    }

    private func claimKeyboard() {
        keyboard.claim(owner: keyboardOwner, acceptsTextInput: true) { command in
            switch command {
            case .moveUp: moveSelection(-1)
            case .moveDown: moveSelection(1)
            case .submit: openSelected()
            case .back: leavePicker()
            case .delete, .actions, .textInput: return false
            }
            return true
        }
    }

    private func load() async {
        isLoading = entries.isEmpty
        loadError = nil
        do {
            let refreshed = try await configuration.locations()
            if !refreshed.isEmpty {
                let selectedPath = visibleEntries.indices.contains(selectedIndex)
                    ? visibleEntries[selectedIndex].path
                    : nil
                let previousIndex = selectedIndex
                entries = refreshed
                if let selectedPath,
                   let refreshedIndex = visibleEntries.firstIndex(where: { $0.path == selectedPath }) {
                    selectedIndex = refreshedIndex
                } else {
                    selectedIndex = min(previousIndex, max(visibleEntries.count - 1, 0))
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

private struct GitPickerRow: View {
    let entry: PromptGitPickerEntry
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    if !entry.isMainWorktree {
                        Color.clear
                            .frame(width: 48)
                    }
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.secondary.opacity(0.10))
                                .frame(width: 34, height: 34)
                            Image(systemName: entry.isMainWorktree ? "folder.badge.gearshape" : "arrow.triangle.branch")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 14, weight: .medium))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.isMainWorktree ? entry.name : (entry.branch ?? entry.name))
                                .font(.body)
                                .lineLimit(1)
                            Text(entry.path.promptDisplayPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 38)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .background(
                        selected ? Color.primary.opacity(0.055) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .leading) {
                        if !entry.isMainWorktree {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.38))
                                .frame(width: selected ? 13 : 10, height: 1)
                                .offset(x: selected ? -3 : 0)
                        }
                    }
                    .scaleEffect(selected ? 1.012 : 1, anchor: .leading)
                    .offset(x: selected ? 3 : 0)
                    .animation(.spring(response: 0.18, dampingFraction: 0.72), value: selected)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .contentShape(Rectangle())

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 34)
                    .padding(.trailing, 8)
                    .opacity(selected ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct GitTreeConnector: View {
    let childCount: Int

    var body: some View {
        Canvas { context, size in
            // Rows are 50 points tall with two points between them. The spine
            // is centered exactly beneath the repository's 34-point icon.
            let rowHeight: CGFloat = 50
            let rowSpacing: CGFloat = 2
            let stride = rowHeight + rowSpacing
            let spineX: CGFloat = 27
            let parentCenterY = rowHeight / 2
            let iconRadius: CGFloat = 17
            let parentBackdropBottomY = parentCenterY + iconRadius
            let childSurfaceLeftX: CGFloat = 48
            let lastChildCenterY = parentCenterY + CGFloat(childCount) * stride
            var path = Path()
            path.move(to: CGPoint(x: spineX, y: parentBackdropBottomY))
            path.addLine(to: CGPoint(x: spineX, y: lastChildCenterY))
            for child in 1 ... childCount {
                let childCenterY = parentCenterY + CGFloat(child) * stride
                path.move(to: CGPoint(x: spineX, y: childCenterY))
                path.addLine(to: CGPoint(x: childSurfaceLeftX, y: childCenterY))
            }
            context.stroke(
                path,
                with: .color(Color.secondary.opacity(0.38)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 76)
        .allowsHitTesting(false)
    }
}

private struct FolderPickerView: View {
    let configuration: PromptFolderPickerConfiguration
    @Binding var isPresented: Bool
    let keyboard: PromptInputRouter
    let onBack: () -> Void

    @State private var directory: String
    @State private var pathField: String
    @State private var entries: [PromptFolderPickerEntry] = []
    @State private var selectedIndex = 0
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var prefersParentSelection = false
    @State private var keyboardOwner = UUID()
    @State private var isListNavigationActive = false
    @FocusState private var pathFocused: Bool

    init(
        configuration: PromptFolderPickerConfiguration,
        isPresented: Binding<Bool>,
        keyboard: PromptInputRouter,
        onBack: @escaping () -> Void
    ) {
        self.configuration = configuration
        _isPresented = isPresented
        self.keyboard = keyboard
        self.onBack = onBack
        _directory = State(initialValue: configuration.initialDirectory)
        _pathField = State(initialValue: configuration.displayName(configuration.initialDirectory))
        _entries = State(initialValue: configuration.cachedDirectories?(configuration.initialDirectory) ?? [])
    }

    private var parentPath: String? {
        if directory == "/" || directory == "~" { return nil }
        if directory.hasPrefix("~/") {
            let value = String(directory.dropLast(directory.split(separator: "/").last?.count ?? 0))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return value.isEmpty ? "~" : value
        }
        let parent = (directory as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private var typedContext: PromptFolderPath.BrowsingContext? {
        guard configuration.createDirectory != nil else { return nil }
        return PromptFolderPath.browsingContext(pathField)
    }

    private var visibleEntries: [PromptFolderPickerEntry] {
        guard let query = typedContext?.query, !query.isEmpty else { return entries }
        return entries.filter {
            $0.name.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive, .anchored]
            ) != nil
        }
    }

    private var actionTitle: String {
        if typedContext?.exists == false { return "Create & Add" }
        return configuration.actionTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                PaletteHeaderLeading(canGoBack: true, onBack: leavePicker)

                TextField("Folder path", text: $pathField)
                    .font(.system(size: 17, weight: .regular))
                    .textFieldStyle(.plain)
                    .focused($pathFocused)
                    .onChange(of: pathField) { value in
                        // Keep the user's spelling and caret untouched while
                        // making both complete paths and partial final
                        // components drive the directory list.
                        let followsNavigation = value == configuration.displayName(directory)
                        if !followsNavigation { prefersParentSelection = false }
                        let nextDirectory = configuration.createDirectory == nil
                            ? configuration.browsingDirectory(value)
                            : PromptFolderPath.browsingContext(value)?.directory
                        guard let nextDirectory, nextDirectory != directory else {
                            updateDefaultSelection()
                            return
                        }
                        directory = nextDirectory
                        updateDefaultSelection()
                    }

                Button { chooseCurrentDirectory() } label: {
                    HStack(spacing: 8) {
                        Text(actionTitle)
                            .foregroundStyle(.primary)
                        Text("⌘ Enter")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                }
                .promptGlassButtonStyle(prominent: true)

                Button(action: chooseCurrentDirectory) { Color.clear }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)
            .frame(height: 62)

            Divider().opacity(0.55)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        Text(configuration.sectionTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)

                        if let parentPath {
                            FolderPickerRow(name: "..", icon: "arrow.turn.up.left", selected: selectedIndex == 0) {
                                navigate(to: parentPath, preferringParent: true)
                            }
                            .id("__parent")
                        }

                        ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                            let rowIndex = index + (parentPath == nil ? 0 : 1)
                            FolderPickerRow(
                                name: entry.name,
                                subtitle: entry.subtitle,
                                icon: entry.icon,
                                selected: selectedIndex == rowIndex) {
                                    activate(entry)
                                }
                                .id(entry.id)
                        }

                        if isLoading {
                            ProgressView().controlSize(.small).padding(18)
                        } else if let loadError {
                            Text(loadError)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(18)
                        } else if visibleEntries.isEmpty {
                            Text(typedContext?.query.isEmpty == false
                                ? "No matching directories"
                                : configuration.emptyText)
                                .foregroundStyle(.secondary)
                                .padding(18)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 420)
                .onChange(of: selectedIndex) { _ in
                    if selectedIndex == 0, parentPath != nil { proxy.scrollTo("__parent") }
                    else {
                        let offset = selectedIndex - (parentPath == nil ? 0 : 1)
                        if visibleEntries.indices.contains(offset) {
                            proxy.scrollTo(visibleEntries[offset].id)
                        }
                    }
                }
            }
            Divider().opacity(0.55)

            HStack(spacing: 14) {
                PaletteHint(keys: ["↑", "↓"], label: "Navigate")
                PaletteHint(keys: ["↩"], label: "Open")
                PaletteHint(keys: ["⌫"], label: "Back")
                PaletteHint(keys: ["esc"], label: "Back")
                Spacer()
                if let onReveal = configuration.onReveal {
                    Button("Open in Finder") { onReveal(directory) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 18)
            .frame(height: 48)
        }
        .task(id: directory) { await loadDirectory() }
        .onAppear {
            claimKeyboard()
            DispatchQueue.main.async { pathFocused = false }
        }
        .onDisappear { keyboard.release(owner: keyboardOwner) }
    }

    private func openSelected() {
        if selectedIndex == 0, let parentPath {
            navigate(to: parentPath, preferringParent: true)
            return
        }
        let offset = selectedIndex - (parentPath == nil ? 0 : 1)
        if visibleEntries.indices.contains(offset) { activate(visibleEntries[offset]) }
    }

    private func leavePicker() {
        keyboard.release(owner: keyboardOwner)
        onBack()
    }

    private func activate(_ entry: PromptFolderPickerEntry) {
        if configuration.selectsEntries {
            isPresented = false
            configuration.onSelect(entry.path)
        } else {
            navigate(to: entry.path)
        }
    }

    private func navigate(to value: String, preferringParent: Bool = false) {
        guard let resolved = configuration.resolvePath(value) else { return }
        prefersParentSelection = preferringParent
        directory = resolved
        pathField = configuration.displayName(resolved)
        updateDefaultSelection()
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        // Arrow navigation deliberately leaves path editing and hands focus to
        // the directory list, so the following Return opens the highlighted row.
        pathFocused = false
        isListNavigationActive = true
        let count = visibleEntries.count + (parentPath == nil ? 0 : 1)
        guard count > 0 else { return }
        if direction == .up { selectedIndex = selectedIndex == 0 ? count - 1 : selectedIndex - 1 }
        if direction == .down { selectedIndex = (selectedIndex + 1) % count }
    }

    private func goToParent() {
        guard let parentPath else { return }
        navigate(to: parentPath, preferringParent: true)
    }

    private func claimKeyboard() {
        keyboard.claim(
            owner: keyboardOwner,
            acceptsTextInput: true,
            focusInput: { pathFocused = true }
        ) { command in
            switch command {
            case .moveUp: moveSelection(.up)
            case .moveDown: moveSelection(.down)
            case .submit: openSelected()
            case .back: leavePicker()
            case .delete:
                guard PromptFolderPickerKeyboardPolicy.shouldNavigateToParent(
                    isListNavigationActive: isListNavigationActive
                ) else { return false }
                goToParent()
            case .actions:
                return false
            case .textInput:
                isListNavigationActive = false
                return false
            }
            return true
        }
    }

    private func choose(_ value: String) {
        guard let resolved = configuration.resolvePath(value) else { return }
        if configuration.browsingDirectory(resolved) == nil,
           let createDirectory = configuration.createDirectory {
            do {
                try createDirectory(resolved)
            } catch {
                loadError = error.localizedDescription
                return
            }
        }
        guard let prepareDirectory = configuration.prepareDirectory else {
            finishChoosing(resolved)
            return
        }
        Task {
            do {
                try await prepareDirectory(resolved)
                guard !Task.isCancelled else { return }
                finishChoosing(resolved)
            } catch {
                guard !Task.isCancelled else { return }
                loadError = configuration.errorMessage(error)
            }
        }
    }

    private func chooseCurrentDirectory() {
        choose(pathField)
    }

    private func finishChoosing(_ directory: String) {
        isPresented = false
        configuration.onSelect(directory)
    }

    private func loadDirectory() async {
        let requestedDirectory = directory
        if let cached = configuration.cachedDirectories?(requestedDirectory) {
            entries = cached
        }
        isLoading = entries.isEmpty
        loadError = nil
        do {
            let refreshed = try await configuration.directories(requestedDirectory)
            guard PromptFolderPickerRefreshPolicy.shouldApply(
                requestedDirectory: requestedDirectory,
                currentDirectory: directory,
                isCancelled: Task.isCancelled
            ) else { return }
            entries = refreshed
        } catch {
            guard PromptFolderPickerRefreshPolicy.shouldApply(
                requestedDirectory: requestedDirectory,
                currentDirectory: directory,
                isCancelled: Task.isCancelled
            ) else { return }
            loadError = configuration.errorMessage(error)
        }
        updateDefaultSelection()
        isLoading = false
    }

    private func updateDefaultSelection() {
        selectedIndex = PromptFolderPickerSelectionPolicy.defaultIndex(
            hasParent: parentPath != nil,
            entryCount: visibleEntries.count,
            prefersParent: prefersParentSelection)
    }
}

enum PromptFolderPickerSelectionPolicy {
    static func defaultIndex(
        hasParent: Bool,
        entryCount: Int,
        prefersParent: Bool
    ) -> Int {
        if hasParent, prefersParent { return 0 }
        if entryCount > 0 { return hasParent ? 1 : 0 }
        return 0
    }
}

enum PromptFolderPickerKeyboardPolicy {
    static func shouldNavigateToParent(isListNavigationActive: Bool) -> Bool {
        isListNavigationActive
    }
}

enum PromptFolderPickerRefreshPolicy {
    static func shouldApply(
        requestedDirectory: String,
        currentDirectory: String,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && requestedDirectory == currentDirectory
    }
}

private struct FolderPickerRow: View {
    let name: String
    var subtitle: String? = nil
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 15, weight: .medium))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: subtitle == nil ? 34 : 46)
            .background(selected ? Color.secondary.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CommandActionsView: View {
    let presentation: PromptCommandPresentation
    let keyboard: PromptInputRouter
    let onPrimary: () -> Void
    let onDismiss: () -> Void
    var customActions: [PromptCommandAction]? = nil

    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var keyboardOwner = UUID()
    @FocusState private var searchFocused: Bool

    private var actions: [PromptCommandAction] {
        if let customActions { return customActions }
        let primary = PromptCommandAction(
            title: presentation.primaryActionTitle,
            icon: "return",
            shortcut: ["↩"],
            action: onPrimary)
        return [primary] + (presentation.contextualActions?() ?? [])
    }

    private var filteredActions: [PromptCommandAction] {
        guard !query.isEmpty else { return actions }
        return actions.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(presentation.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 44)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(filteredActions.enumerated()), id: \.offset) { index, item in
                            Button { perform(item) } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 14, weight: .medium))
                                        .frame(width: 20)
                                    Text(item.title)
                                        .font(.system(size: 14, weight: .medium))
                                    Spacer()
                                    if !item.shortcut.isEmpty {
                                        HStack(spacing: 3) {
                                            ForEach(item.shortcut, id: \.self) { key in
                                                Text(key)
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(.secondary)
                                                    .padding(.horizontal, 6)
                                                    .frame(height: 24)
                                                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 11)
                                .frame(height: 40)
                                .background(index == selectedIndex ? Color.secondary.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selectedIndex) { index in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
            .frame(maxHeight: 205)

            Divider().opacity(0.55)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("Search for actions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit { activateSelected() }
            }
            .padding(.horizontal, 13)
            .frame(height: 44)
        }
        .promptLiquidGlassSurface(cornerRadius: 20)
        .onAppear {
            searchFocused = true
            DispatchQueue.main.async { searchFocused = true }
            claimKeyboard()
        }
        .onDisappear { keyboard.release(owner: keyboardOwner) }
        .onChange(of: query) { _ in selectedIndex = 0 }
    }

    private func activateSelected() {
        guard filteredActions.indices.contains(selectedIndex) else { return }
        perform(filteredActions[selectedIndex])
    }

    private func perform(_ item: PromptCommandAction) {
        keyboard.release(owner: keyboardOwner)
        onDismiss()
        item.action()
    }

    private func claimKeyboard() {
        keyboard.claim(
            owner: keyboardOwner,
            acceptsTextInput: true,
            focusInput: { searchFocused = true }
        ) { command in
            switch command {
            case .moveUp:
                if !filteredActions.isEmpty {
                    selectedIndex = selectedIndex == 0 ? filteredActions.count - 1 : selectedIndex - 1
                }
            case .moveDown:
                if !filteredActions.isEmpty {
                    selectedIndex = (selectedIndex + 1) % filteredActions.count
                }
            case .submit: activateSelected()
            case .back:
                keyboard.release(owner: keyboardOwner)
                onDismiss()
            case .actions:
                keyboard.release(owner: keyboardOwner)
                onDismiss()
            case .delete:
                return false
            case .textInput:
                return false
            }
            return true
        }
    }
}

private struct PaletteHeaderLeading: View {
    let canGoBack: Bool
    let onBack: () -> Void

    var body: some View {
        Group {
            if canGoBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Back")
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
        }
    }
}

/// The text field for building the query for the command palette.
private struct CommandPaletteQuery: View {
    @Binding var query: String
    var title: String?
    var canGoBack: Bool
    var onBack: () -> Void
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            PaletteHeaderLeading(canGoBack: canGoBack, onBack: onBack)
            TextField(title.map { "Search \($0.lowercased())…" } ?? "Search sessions and commands…", text: $query)
                .font(.system(size: 17, weight: .regular))
                .textFieldStyle(.plain)
                .focused($isTextFieldFocused)
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .textFieldStyle(.plain)
        .onAppear {
            // Grab focus on the first appearance.
            // Debug and Release build using Xcode 26.4,
            // has same issue again
            // Fixes: https://github.com/ghostty-org/ghostty/issues/8497
            // SearchOverlay works magically as expected, I don't know
            // why it's different here, but dispatching to next loop fixes it
            DispatchQueue.main.async {
                isTextFieldFocused = true
            }
        }
    }
}

struct PromptPalettePointerPolicy {
    static func hasMoved(
        from keyboardLocation: CGPoint?,
        to currentLocation: CGPoint,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        guard let keyboardLocation else { return true }
        return abs(currentLocation.x - keyboardLocation.x) > tolerance ||
            abs(currentLocation.y - keyboardLocation.y) > tolerance
    }
}

/// A single row in the command palette.
private struct CommandRow: View {
    let presentation: PromptCommandPresentation
    var query: String
    var isSelected: Bool
    var onHover: () -> Void
    var action: () -> Void

    private var highlightedTitle: Text {
        guard !query.isEmpty,
              let indices = presentation.title.promptMatchedIndices(for: query) else {
            return Text(presentation.title)
                .fontWeight(presentation.emphasis ? .medium : .regular)
        }

        var attributed = AttributedString(presentation.title)
        attributed[attributed.startIndex...].font = .body
            .weight(presentation.emphasis ? .medium : .regular)

        for idx in indices {
            let offset = presentation.title.distance(from: presentation.title.startIndex, to: idx)
            let attrStart = attributed.index(attributed.startIndex, offsetByCharacters: offset)
            let attrEnd = attributed.index(attrStart, offsetByCharacters: 1)
            attributed[attrStart ..< attrEnd].font = .body.bold()
            attributed[attrStart ..< attrEnd].foregroundColor = Color.accentColor
        }

        return Text(attributed)
    }

    private func highlightedSubtitle(_ subtitle: String) -> Text {
        guard !query.isEmpty,
              presentation.title.promptMatchedIndices(for: query) == nil,
              let indices = subtitle.promptMatchedIndices(for: query) else {
            return Text(subtitle)
        }

        var attributed = AttributedString(subtitle)

        for idx in indices {
            let offset = subtitle.distance(from: subtitle.startIndex, to: idx)
            let attrStart = attributed.index(attributed.startIndex, offsetByCharacters: offset)
            let attrEnd = attributed.index(attrStart, offsetByCharacters: 1)
            attributed[attrStart ..< attrEnd].font = .caption.bold()
            attributed[attrStart ..< attrEnd].foregroundColor = Color.accentColor
        }

        return Text(attributed)
    }

    private var fixedTrailingWidth: CGFloat {
        let symbolCount = presentation.symbols?.count ?? 0
        let symbolsWidth = symbolCount == 0 ? 0 : CGFloat(symbolCount * 13 + symbolCount - 1)
        let showsChevron = isSelected
        return symbolsWidth + (symbolCount > 0 && showsChevron ? 10 : 0) + (showsChevron ? 8 : 0)
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .trailing) {
                HStack(spacing: 12) {
                    if let color = presentation.leadingColor {
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)
                    }

                    if let icon = presentation.leadingIcon {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.secondary.opacity(0.10))
                                .frame(width: 34, height: 34)
                            Image(systemName: icon)
                                .foregroundStyle(presentation.emphasis ? Color.accentColor : .secondary)
                                .font(.system(size: 14, weight: .medium))
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        highlightedTitle

                        if let subtitle = presentation.subtitle {
                            highlightedSubtitle(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if let badge = presentation.badge, !badge.isEmpty {
                        Text(badge)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Color.accentColor.opacity(0.15))
                            )
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.trailing, fixedTrailingWidth)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .background(
                    isSelected ? Color.primary.opacity(0.055) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .scaleEffect(isSelected ? 1.012 : 1, anchor: .leading)
                .offset(x: isSelected ? 3 : 0)
                .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isSelected)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(presentation.emphasis && !isSelected ? 0.3 : 0), lineWidth: 1.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack(spacing: 10) {
                    if let symbols = presentation.symbols {
                        ShortcutSymbolsView(symbols: symbols)
                            .foregroundStyle(.secondary)
                    }
                    if isSelected {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .transition(.opacity)
                    }
                }
                .padding(.trailing, 10)
                .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isSelected)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .help(presentation.description ?? "")
        .buttonStyle(.plain)
        .onContinuousHover { phase in
            if case .active = phase { onHover() }
        }
    }
}

private struct PaletteHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { key in
                PaletteKeycap(key: key)
            }
            Text(label).foregroundStyle(.secondary)
        }
    }
}

private struct PaletteLabelFirstHint: View {
    let label: String
    var keys: [String] = []
    var systemKeys: [String] = []

    var body: some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            ForEach(keys, id: \.self) { key in
                PaletteKeycap(key: key)
            }
            ForEach(systemKeys, id: \.self) { key in
                Image(systemName: key)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

private struct PaletteKeycap: View {
    let key: String

    var body: some View {
        Group {
            if key == "↩" {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
            } else {
                Text(key)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
        }
        .padding(.horizontal, 5)
        .frame(minWidth: 22, minHeight: 22, alignment: .center)
        .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// A row of Text representing a shortcut.
private struct ShortcutSymbolsView: View {
    let symbols: [String]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol)
                    .frame(minWidth: 13)
            }
        }
    }
}

extension String {
    /// Returns the character indices that match `query`, trying a substring match first,
    /// then falling back to initials matching (first letter of each word).
    /// - Returns: `nil` if neither matches.
    func promptMatchedIndices(for query: String) -> [String.Index]? {
        guard !query.isEmpty else { return nil }

        // Prefer substring match.
        if let range = self.range(of: query, options: .caseInsensitive) {
            return Array(self[range].indices)
        }

        // Fall back to initials match.
        let words = self.split(whereSeparator: \.isWhitespace)
        var queryIndex = query.startIndex
        var matched: [String.Index] = []

        for word in words {
            guard queryIndex < query.endIndex else { break }

            if word.first?.lowercased() == query[queryIndex].lowercased() {
                matched.append(word.startIndex)
                queryIndex = query.index(after: queryIndex)
            }
        }

        return queryIndex == query.endIndex ? matched : nil
    }
}
