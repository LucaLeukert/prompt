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
    private let lock = NSLock()
    private var authority: ghostty_surface_t?
    private var presentation: ghostty_surface_t?

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
        lock.unlock()
        guard let target else { return }
        ghostty_surface_process_output(target, bytes, count)
    }

    func disconnect() {
        lock.lock()
        let source = authority
        authority = nil
        presentation = nil
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
