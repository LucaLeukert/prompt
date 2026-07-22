import AppKit
import SwiftUI

@MainActor
enum PromptTerminalIntegration {
    static func install() {
        GhosttyAppKitHooks.overlay = { view in
            let surface = PromptTerminalSurface.wrap(view)
            guard !PromptTerminalCapabilities.isCompositeAuthority(surface) else { return nil }
            if let remote = PromptTerminalCapabilities.remoteContext(for: surface) {
                if remote.supportsInlineRichContent {
                    return AnyView(ZStack {
                        PromptRichContentLayer(surfaceView: surface).zIndex(9)
                        PromptNativeModeBadge(surfaceView: surface).zIndex(10)
                    })
                }
                return AnyView(PromptRemoteAIOverlay(surfaceView: surface))
            }
            guard PromptComposerPresentation.current == .inline else { return nil }
            return AnyView(ZStack {
                PromptRichContentLayer(surfaceView: surface).zIndex(9)
                PromptNativeAutocompleteOverlay(surfaceView: surface).zIndex(10)
                PromptNativeModeBadge(surfaceView: surface).zIndex(11)
            })
        }
        GhosttyAppKitHooks.topBar = { view in
            let surface = PromptTerminalSurface.wrap(view)
            guard !PromptTerminalCapabilities.isCompositeAuthority(surface) else { return nil }
            return nil
        }
        GhosttyAppKitHooks.bottomBar = { view in
            let surface = PromptTerminalSurface.wrap(view)
            guard !PromptTerminalCapabilities.isCompositeAuthority(surface) else { return nil }
            let needsRemoteFallbackBar = PromptTerminalCapabilities.remoteContext(for: surface)
                .map { !$0.supportsInlineRichContent } ?? false
            guard PromptComposerPresentation.current == .commandBar || needsRemoteFallbackBar else { return nil }
            return AnyView(PromptTerminalCommandBar(
                surfaceView: surface,
                presentation: .commandBar))
        }
        GhosttyAppKitHooks.surfaceDidClose = { view in
            // This hook runs from SurfaceView.deinit. Never create or register a
            // wrapper for an Objective-C object that is already deallocating.
            PromptTerminalCapabilities.unregister(view)
        }
        GhosttyAppKitHooks.surfaceDidClick = { view in
            NotificationCenter.default.post(
                name: .promptSurfaceDidClick,
                object: PromptTerminalSurface.wrap(view))
        }
        GhosttyAppKitHooks.terminalDidReset = { view in
            PromptRichContentStore.shared.clear(for: PromptTerminalSurface.wrap(view))
        }
        GhosttyAppKitHooks.commandDidFinish = { view, exitCode, duration in
            NotificationCenter.default.post(
                name: .ghosttyCommandDidFinish,
                object: PromptTerminalSurface.wrap(view),
                userInfo: [
                    Notification.Name.CommandExitCodeKey: exitCode,
                    Notification.Name.CommandDurationNanosecondsKey: duration,
                ])
        }
        GhosttyAppKitHooks.keyDown = handleKeyDown
    }

    private static func handleKeyDown(_ view: Ghostty.SurfaceView, _ event: NSEvent, _ hasMarkedText: Bool) -> Bool {
        let surface = PromptTerminalSurface.wrap(view)
        guard !PromptTerminalCapabilities.isCompositeAuthority(surface) else { return false }
        PromptNativeInputRouter.observeRemoteKeyDown(event, on: surface)
        if event.keyCode == 0x08, event.modifierFlags.contains(.control) {
            if PromptModel.shared.cancelTerminalTurn(on: surface) { return true }
            if PromptTerminalCapabilities.isManagedRemote(surface) {
                NotificationCenter.default.post(name: .promptRemoteControlC, object: surface)
            }
        }
        if event.keyCode == 0x28, event.modifierFlags.contains(.command) {
            PromptRichContentStore.shared.clear(for: surface)
        }
        if (event.keyCode == 0x7E || event.keyCode == 0x7D),
           event.modifierFlags.contains(.shift),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           !hasMarkedText,
           PromptAutocompleteModel.shared.cycle(on: surface, direction: event.keyCode == 0x7D ? 1 : -1) { return true }
        if event.keyCode == 0x30,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           !hasMarkedText {
            switch PromptNativeInputRouter.tabDisposition(on: surface) {
            case .passToTerminal: break
            case .consume: return true
            case .acceptAutocomplete:
                _ = PromptAutocompleteModel.shared.accept(on: surface)
                return true
            case .switchMode(let mode):
                PromptNativeInputRouter.selectSurfaceModeFromKeyboard(mode, for: surface)
                return true
            }
        }
        if (event.keyCode == 0x24 || event.keyCode == 0x4C),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           !hasMarkedText {
            PromptRichContentStore.shared.freezeReservations(for: surface)
            if PromptNativeInputRouter.handleReturn(on: surface) { return true }
        }
        return false
    }
}

extension Notification.Name {
    static let ghosttyCommandDidFinish = Notification.Name("dev.prompt.commandDidFinish")
    static let CommandExitCodeKey = ghosttyCommandDidFinish.rawValue + ".exitCode"
    static let CommandDurationNanosecondsKey = ghosttyCommandDidFinish.rawValue + ".durationNanoseconds"
    static let promptRemoteControlC = Notification.Name("dev.prompt.remoteControlC")
}
