import AppKit
import GhosttyKit

private func promptCompositeOutputTee(
    _ userdata: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<CChar>?,
    _ count: UInt
) {
    guard let userdata, let bytes, count > 0 else { return }
    Unmanaged<PromptCompositeIORouter>.fromOpaque(userdata)
        .takeUnretainedValue()
        .forwardOutput(bytes, count: count)
}

/// Connects the manually-rendered presentation terminal to the hidden surface
/// that owns SSH/tmux. Output is mirrored byte-for-byte; already-encoded input
/// travels in the other direction without text/paste re-encoding.
final class PromptCompositeIORouter: @unchecked Sendable {
    static let remoteReadyMarker = Data("\u{1B}]777;prompt-remote-ready\u{07}".utf8)

    private let lock = NSLock()
    private let suppressOutputUntilRemoteReady: Bool
    private var authority: ghostty_surface_t?
    private var presentation: ghostty_surface_t?
    private var awaitingRemoteReady: Bool
    private var pendingOutput = Data()

    init(suppressOutputUntilRemoteReady: Bool = false) {
        self.suppressOutputUntilRemoteReady = suppressOutputUntilRemoteReady
        awaitingRemoteReady = suppressOutputUntilRemoteReady
    }

    func install(authority: ghostty_surface_t, presentation: ghostty_surface_t) {
        lock.lock()
        self.authority = authority
        self.presentation = presentation
        lock.unlock()
        ghostty_surface_set_pty_tee_cb(
            authority,
            promptCompositeOutputTee,
            Unmanaged.passUnretained(self).toOpaque())
    }

    func forwardInput(_ data: Data) {
        // Terminal replies generated while parsing mirrored output run on the
        // authority's IO thread. The authority already generated its own reply,
        // so only user/AppKit input from the main thread is forwarded.
        guard Thread.isMainThread, !data.isEmpty else { return }
        lock.lock()
        let target = authority
        lock.unlock()
        guard let target else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_write_input(target, base, UInt(raw.count))
        }
    }

    func forwardOutput(_ bytes: UnsafePointer<CChar>, count: UInt) {
        lock.lock()
        let target = presentation
        var output = Data(bytes: bytes, count: Int(count))
        if awaitingRemoteReady {
            pendingOutput.append(output)
            if let marker = pendingOutput.range(of: Self.remoteReadyMarker) {
                output = Data(pendingOutput[marker.upperBound...])
                pendingOutput.removeAll()
                awaitingRemoteReady = false
            } else {
                // Retain only enough suffix to recognize a marker split across
                // callback chunks. All earlier bytes belong to the local
                // authority shell and must never reach the remote terminal.
                let retained = min(pendingOutput.count, Self.remoteReadyMarker.count - 1)
                pendingOutput = Data(pendingOutput.suffix(retained))
                output.removeAll()
            }
        }
        lock.unlock()
        guard let target, !output.isEmpty else { return }
        output.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_process_output(target, base, UInt(raw.count))
        }
    }

    func disconnect() {
        lock.lock()
        let source = authority
        authority = nil
        presentation = nil
        pendingOutput.removeAll()
        awaitingRemoteReady = suppressOutputUntilRemoteReady
        lock.unlock()
        if let source { ghostty_surface_set_pty_tee_cb(source, nil, nil) }
    }
}

/// Prompt's concrete terminal boundary. One stable wrapper exists for each
/// hosted AppKit surface so models and AI state can use its identity safely.
@MainActor
final class PromptTerminalSurface: GhosttyAppKitSurface {
    private static let wrappers = NSMapTable<Ghostty.SurfaceView, PromptTerminalSurface>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory)

    private(set) var authoritativeSurface: GhosttyAppKitSurface?
    private var compositeRouter: PromptCompositeIORouter?

    static func wrap(_ view: Ghostty.SurfaceView) -> PromptTerminalSurface {
        if let existing = wrappers.object(forKey: view) { return existing }
        let wrapper = PromptTerminalSurface(hosting: view)
        wrappers.setObject(wrapper, forKey: view)
        return wrapper
    }

    static func find(in view: NSView) -> PromptTerminalSurface? {
        if let hosted = view as? Ghostty.SurfaceView { return wrap(hosted) }
        for child in view.subviews {
            if let result = find(in: child) { return result }
        }
        return nil
    }

    static func find(containing view: NSView?) -> PromptTerminalSurface? {
        var current = view
        while let candidate = current {
            if let hosted = candidate as? Ghostty.SurfaceView { return wrap(hosted) }
            current = candidate.superview
        }
        return nil
    }

    func configureComposite(
        authority: GhosttyAppKitSurface,
        router: PromptCompositeIORouter
    ) {
        authoritativeSurface = authority
        compositeRouter = router
        guard let authorityHandle = authority.surfaceHandle,
              let presentationHandle = surfaceHandle else { return }
        router.install(authority: authorityHandle, presentation: presentationHandle)
    }

    var isComposite: Bool { authoritativeSurface != nil }

    var compositeIsAlternateScreen: Bool {
        authoritativeSurface?.isAlternateScreen ?? isAlternateScreen
    }

    func synchronizeCompositeSize(_ size: CGSize) {
        authoritativeSurface?.hostedView.sizeDidChange(size)
    }

    func closeComposite() {
        compositeRouter?.disconnect()
        authoritativeSurface?.requestClose()
        authoritativeSurface = nil
        compositeRouter = nil
    }

    /// Interrupts the foreground process just as if the user pressed Control-C.
    func interruptForegroundProcess() {
        guard let surface = surfaceHandle else { return }
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.keycode = 0x08 // macOS virtual key code for C
        event.text = nil
        event.composing = false
        event.mods = GHOSTTY_MODS_CTRL
        event.consumed_mods = GHOSTTY_MODS_NONE
        event.unshifted_codepoint = 99
        _ = ghostty_surface_key(surface, event)
    }
}

@MainActor
enum PromptLibghostty {
    static func isAlternateScreen(_ surface: PromptTerminalSurface) -> Bool {
        surface.compositeIsAlternateScreen
    }

    static func setHostCursorVisible(_ visible: Bool, on surface: PromptTerminalSurface) {
        surface.setHostCursorVisible(visible)
    }
}
