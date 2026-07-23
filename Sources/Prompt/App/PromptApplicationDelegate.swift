import AppKit
import Combine
import SwiftUI
import OSLog

@MainActor
final class PromptApplicationDelegate: NSObject, NSApplicationDelegate {
    static let logger = Logger(subsystem: "net.leukert.prompt", category: "application")

    let runtime = PromptTerminalRuntime()
    lazy var workspaceStore = PromptWorkspaceStore(runtime: runtime)
    private var windowController: PromptWindowController?
    private var tickTimer: Timer?
    private var shortcutMonitor: Any?
    private var workspaceObservation: AnyCancellable?
    private var explicitQuitRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        restoreOrCreateWorkspace()
        PromptSessionLauncher.refreshTailnetDiscovery()
        workspaceObservation = workspaceStore.$workspace.dropFirst().sink { [weak self] _ in
            self?.persistRestorationState()
        }
        PromptController.shared.install()
        installShortcutRouter()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runtime.application.tick() }
        }
    }

    // A terminal surface ending must never turn into application termination.
    // Users can still quit explicitly with Command-Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if explicitQuitRequested { return .terminateNow }
        Self.logger.error("Rejected non-user application termination request")
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistRestorationState()
        tickTimer?.invalidate()
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
    }

    @objc func newWindow(_ sender: Any?) {
        windowController?.showWindow(sender)
        windowController?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func newLocalSession(_ sender: Any?) {
        workspaceStore.isCommandPalettePresented = false
        workspaceStore.createLocal(directory: focusedDirectory ?? NSHomeDirectory())
    }

    @objc func chooseLocalFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: focusedDirectory ?? NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspaceStore.createLocal(directory: url.path)
    }

    @objc func splitRight(_ sender: Any?) {
        workspaceStore.isCommandPalettePresented = false
        workspaceStore.splitFocused(axis: .horizontal)
    }
    @objc func splitDown(_ sender: Any?) {
        workspaceStore.isCommandPalettePresented = false
        workspaceStore.splitFocused(axis: .vertical)
    }
    @objc func closePane(_ sender: Any?) {
        workspaceStore.isCommandPalettePresented = false
        workspaceStore.closeFocusedPane()
    }
    @objc func showCommandPalette(_ sender: Any?) {
        windowController?.isCommandPalettePresented.toggle()
    }
    @objc func showAIComposer(_ sender: Any?) { PromptController.shared.toggle() }

    @objc func quitApplication(_ sender: Any?) {
        explicitQuitRequested = true
        NSApp.terminate(sender)
    }

    private func installShortcutRouter() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.modifierFlags.contains(.command) else { return event }
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

                if modifiers == [.command], let number = Int(key), (1...9).contains(number) {
                    self.workspaceStore.focusSidebarSession(at: number - 1)
                    return nil
                }
                switch (key, modifiers) {
                case ("q", [.command]): self.quitApplication(nil)
                case ("t", [.command]): self.newLocalSession(nil)
                case ("w", [.command]): self.closePane(nil)
                case ("o", [.command]): self.chooseLocalFolder(nil)
                case ("p", [.command]): self.showCommandPalette(nil)
                case ("d", [.command]): self.splitRight(nil)
                case ("d", [.command, .shift]): self.splitDown(nil)
                case ("i", [.command]): self.showAIComposer(nil)
                case (" ", [.command, .shift]): self.showAIComposer(nil)
                default: return event
                }
                return nil
            }
        }
    }

    private var focusedDirectory: String? {
        guard let session = workspaceStore.workspace.sessions.first(where: { $0.id == workspaceStore.workspace.focusedSessionID }) else { return nil }
        return runtime.surface(for: session.focusedPaneID)?.workingDirectory
    }

    private func restoreOrCreateWorkspace() {
        var restoredWindowFrame: String?
        if let data = UserDefaults.standard.data(forKey: "PromptRestorationState"),
           let state = try? JSONDecoder().decode(PromptRestorationState.self, from: data),
           var restored = state.workspaces.first {
            restoredWindowFrame = state.windowFrame
            for index in restored.sessions.indices {
                restored.sessions[index].collapseToFocusedPane()
                let session = restored.sessions[index]
                for pane in session.splitTree.panes {
                    _ = runtime.createSurface(for: pane, configuration: session.configuration)
                }
            }
            workspaceStore.workspace = restored
        }
        if workspaceStore.workspace.sessions.isEmpty {
            workspaceStore.createLocal(directory: FileManager.default.currentDirectoryPath)
        }
        let controller = PromptWindowController(store: workspaceStore)
        windowController = controller
        if let restoredWindowFrame {
            controller.window?.setFrame(NSRectFromString(restoredWindowFrame), display: false)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func persistRestorationState() {
        let state = PromptRestorationState(
            workspaces: [workspaceStore.workspace],
            selectedWorkspaceID: workspaceStore.workspace.id,
            windowFrame: windowController?.window.map { NSStringFromRect($0.frame) })
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: "PromptRestorationState")
        }
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appRoot = NSMenuItem()
        let app = NSMenu(title: "Prompt")
        app.addItem(withTitle: "About Prompt", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let quit = app.addItem(withTitle: "Quit Prompt", action: #selector(quitApplication(_:)), keyEquivalent: "q")
        quit.target = self
        appRoot.submenu = app
        main.addItem(appRoot)

        let fileRoot = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(item("New Session", #selector(newLocalSession(_:)), "t", [.command]))
        file.addItem(item("Open Folder…", #selector(chooseLocalFolder(_:)), "o", [.command]))
        file.addItem(item("Close Pane", #selector(closePane(_:)), "w", [.command]))
        fileRoot.submenu = file
        main.addItem(fileRoot)

        let viewRoot = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(item("Command Palette", #selector(showCommandPalette(_:)), "p", [.command]))
        view.addItem(item("AI Composer", #selector(showAIComposer(_:)), "i", [.command]))
        view.addItem(item("Split Right", #selector(splitRight(_:)), "d", [.command]))
        view.addItem(item("Split Down", #selector(splitDown(_:)), "d", [.command, .shift]))
        viewRoot.submenu = view
        main.addItem(viewRoot)
        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: key)
        value.target = self
        value.keyEquivalentModifierMask = modifiers
        return value
    }
}
