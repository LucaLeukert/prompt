import AppKit
import Combine
import Logging
import SwiftUI

@MainActor
final class PromptApplicationDelegate: NSObject, NSApplicationDelegate {
    static var logger: Logger { PromptLog.application }

    let runtime = PromptTerminalRuntime()
    lazy var workspaceStore = PromptWorkspaceStore(runtime: runtime)
    private var windowController: PromptWindowController?
    private var tickTimer: Timer?
    private var workspaceObservation: AnyCancellable?
    private var explicitQuitRequested = false
    private var isPersistingRestorationState = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.logger.info("Application finished launching")
        installMainMenu()
        restoreOrCreateWorkspace()
        PromptSessionLauncher.refreshTailnetDiscovery()
        workspaceObservation = workspaceStore.$workspace.dropFirst().sink { [weak self] _ in
            self?.persistRestorationState()
        }
        PromptController.shared.install()
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
        Self.logger.info("Application will terminate")
        persistRestorationState()
        tickTimer?.invalidate()
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
    @objc func showCommandActions(_ sender: Any?) {
        _ = workspaceStore.inputRouter.dispatch(.actions)
    }
    @objc func showAIComposer(_ sender: Any?) { PromptController.shared.toggle() }
    #if DEBUG
        @objc func showAIDiagnostics(_ sender: Any?) {
            AIDiagnosticsWindowController.shared.show()
        }
    #endif
    @objc func focusSessionFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        workspaceStore.focusSidebarSession(at: item.tag)
    }

    @objc func quitApplication(_ sender: Any?) {
        explicitQuitRequested = true
        NSApp.terminate(sender)
    }

    private var focusedDirectory: String? {
        guard let session = workspaceStore.workspace.sessions.first(where: { $0.id == workspaceStore.workspace.focusedSessionID }) else { return nil }
        return runtime.surface(for: session.focusedPaneID)?.workingDirectory
    }

    private func restoreOrCreateWorkspace() {
        var restoredWindowFrame: String?
        if let state: PromptRestorationState = PromptSettings.shared.value(forKey: "PromptRestorationState"),
           var restored = state.workspaces.first {
            restoredWindowFrame = state.windowFrame
            restored.sessions.removeAll {
                guard case .local(let configuration) = $0.configuration else { return false }
                return configuration.behavior == .disposable
            }
            for index in restored.sessions.indices {
                if case .local(var configuration) = restored.sessions[index].configuration {
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(
                        atPath: configuration.workingDirectory,
                        isDirectory: &isDirectory)
                    if !exists || !isDirectory.boolValue {
                        configuration.workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
                        restored.sessions[index].configuration = .local(configuration)
                    }
                    // Never repeat a completed task or an elevation request
                    // merely because the application was relaunched.
                    if (configuration.behavior == .task && configuration.lastExitCode != nil)
                        || configuration.behavior == .privileged {
                        configuration.command = nil
                        restored.sessions[index].configuration = .local(configuration)
                    }
                }
                let session = restored.sessions[index]
                for pane in session.splitTree.panes {
                    _ = runtime.createSurface(for: pane, configuration: session.configuration)
                }
            }
            workspaceStore.workspace = restored
            Self.logger.info(
                "Restored workspace",
                metadata: ["session_count": "\(restored.sessions.count)"])
        }
        if workspaceStore.workspace.sessions.isEmpty {
            Self.logger.info("Creating initial local session")
            workspaceStore.createLocal(directory: FileManager.default.homeDirectoryForCurrentUser.path)
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
        // Persistence is normally driven by `$workspace`. Keep this guard even
        // though workspaceForRestoration returns a value snapshot: it prevents
        // any future restoration enrichment from recursively publishing and
        // overflowing the main-thread stack while a session is being created.
        guard !isPersistingRestorationState else { return }
        isPersistingRestorationState = true
        defer { isPersistingRestorationState = false }

        let workspace = workspaceStore.workspaceForRestoration()
        let state = PromptRestorationState(
            workspaces: [workspace],
            selectedWorkspaceID: workspace.id,
            windowFrame: windowController?.window.map { NSStringFromRect($0.frame) })
        PromptSettings.shared.set(state, forKey: "PromptRestorationState")
    }

    private func installMainMenu() {
        let main = NSMenu()

        let appRoot = NSMenuItem()
        let app = NSMenu(title: "Prompt")
        app.addItem(withTitle: "About Prompt", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        app.addItem(services)
        NSApp.servicesMenu = services.submenu
        app.addItem(.separator())
        app.addItem(systemItem("Hide Prompt", #selector(NSApplication.hide(_:)), "h", [.command]))
        app.addItem(systemItem(
            "Hide Others",
            #selector(NSApplication.hideOtherApplications(_:)),
            "h",
            [.command, .option]))
        app.addItem(systemItem(
            "Show All",
            #selector(NSApplication.unhideAllApplications(_:)),
            "",
            []))
        app.addItem(.separator())
        let quit = app.addItem(withTitle: "Quit Prompt", action: #selector(quitApplication(_:)), keyEquivalent: "q")
        quit.target = self
        appRoot.submenu = app
        main.addItem(appRoot)

        let fileRoot = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(item("New Window", #selector(newWindow(_:)), "n", [.command, .shift]))
        file.addItem(item("New Session", #selector(newLocalSession(_:)), "t", [.command]))
        file.addItem(item("Open Folder…", #selector(chooseLocalFolder(_:)), "o", [.command]))
        file.addItem(.separator())
        file.addItem(item("Close Pane", #selector(closePane(_:)), "w", [.command]))
        fileRoot.submenu = file
        main.addItem(fileRoot)

        let editRoot = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(systemItem("Undo", Selector(("undo:")), "z", [.command]))
        edit.addItem(systemItem("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(systemItem("Cut", #selector(NSText.cut(_:)), "x", [.command]))
        edit.addItem(systemItem("Copy", #selector(NSText.copy(_:)), "c", [.command]))
        edit.addItem(systemItem("Paste", #selector(NSText.paste(_:)), "v", [.command]))
        edit.addItem(systemItem("Select All", #selector(NSText.selectAll(_:)), "a", [.command]))
        editRoot.submenu = edit
        main.addItem(editRoot)

        let viewRoot = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(item("Command Palette", #selector(showCommandPalette(_:)), "p", [.command]))
        view.addItem(item("Actions", #selector(showCommandActions(_:)), "k", [.command]))
        view.addItem(item("AI Composer", #selector(showAIComposer(_:)), "i", [.command]))
        view.addItem(.separator())
        view.addItem(item("Split Right", #selector(splitRight(_:)), "d", [.command]))
        view.addItem(item("Split Down", #selector(splitDown(_:)), "d", [.command, .shift]))
        viewRoot.submenu = view
        main.addItem(viewRoot)

        #if DEBUG
            let debugRoot = NSMenuItem()
            let debug = NSMenu(title: "Debug")
            debug.addItem(item(
                "AI Diagnostics…",
                #selector(showAIDiagnostics(_:)),
                "i",
                [.command, .option]))
            debugRoot.submenu = debug
            main.addItem(debugRoot)
        #endif

        let sessionRoot = NSMenuItem()
        let session = NSMenu(title: "Session")
        for index in 0 ..< 9 {
            let value = item(
                "Select Session \(index + 1)",
                #selector(focusSessionFromMenu(_:)),
                String(index + 1),
                [.command])
            value.tag = index
            session.addItem(value)
        }
        sessionRoot.submenu = session
        main.addItem(sessionRoot)

        let windowRoot = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(systemItem(
            "Minimize",
            #selector(NSWindow.performMiniaturize(_:)),
            "m",
            [.command]))
        window.addItem(systemItem("Zoom", #selector(NSWindow.performZoom(_:)), "", []))
        window.addItem(.separator())
        window.addItem(systemItem(
            "Bring All to Front",
            #selector(NSApplication.arrangeInFront(_:)),
            "",
            []))
        windowRoot.submenu = window
        main.addItem(windowRoot)

        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: key)
        value.target = self
        value.keyEquivalentModifierMask = modifiers
        return value
    }

    private func systemItem(
        _ title: String,
        _ action: Selector,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: key)
        value.keyEquivalentModifierMask = modifiers
        return value
    }
}
