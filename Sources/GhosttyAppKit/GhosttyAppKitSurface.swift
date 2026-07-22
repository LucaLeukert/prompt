import AppKit
import Combine
import GhosttyKit

/// Reusable AppKit host around Ghostty's mature terminal surface adapter.
///
/// Application targets interact with this object instead of depending on
/// Ghostty window, session, or terminal-controller types. Rendering, PTY I/O,
/// keyboard/mouse handling, IME, selection, accessibility and Metal remain in
/// the wrapped `Ghostty.SurfaceView`.
@dynamicMemberLookup
class GhosttyAppKitSurface: ObservableObject {
    let hostedView: Ghostty.SurfaceView
    private var changeObservation: AnyCancellable?

    init(hosting view: Ghostty.SurfaceView) {
        hostedView = view
        changeObservation = view.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var id: UUID { hostedView.id }
    var identity: ObjectIdentifier { ObjectIdentifier(hostedView) }
    var nativeView: NSView { hostedView }
    var surfaceHandle: ghostty_surface_t? { hostedView.surface }
    var title: String { hostedView.title }
    var workingDirectory: String? { hostedView.pwd }
    var isFocused: Bool { hostedView.focused }
    var hasBell: Bool { hostedView.bell }
    var window: NSWindow? { hostedView.window }

    subscript<Value>(dynamicMember keyPath: KeyPath<Ghostty.SurfaceView, Value>) -> Value {
        hostedView[keyPath: keyPath]
    }

    subscript<Value>(dynamicMember keyPath: ReferenceWritableKeyPath<Ghostty.SurfaceView, Value>) -> Value {
        get { hostedView[keyPath: keyPath] }
        set { hostedView[keyPath: keyPath] = newValue }
    }

    func sendText(_ text: String) {
        guard let surfaceHandle, !text.isEmpty else { return }
        text.withCString { ghostty_surface_text(surfaceHandle, $0, UInt(text.utf8.count)) }
    }

    func requestClose() {
        guard let surfaceHandle else { return }
        ghostty_surface_request_close(surfaceHandle)
    }

    func focus() {
        window?.makeFirstResponder(hostedView)
    }

    var isAlternateScreen: Bool {
        guard let surfaceHandle else { return false }
        return ghostty_surface_is_alternate_screen(surfaceHandle)
    }

    func setHostCursorVisible(_ visible: Bool) {
        guard let surfaceHandle else { return }
        ghostty_surface_set_host_cursor_visible(surfaceHandle, visible)
    }

    func promptInput() -> String? {
        guard let surfaceHandle else { return nil }
        var value = ghostty_text_s()
        guard ghostty_surface_read_prompt_input(surfaceHandle, &value) else { return nil }
        defer { ghostty_surface_free_text(surfaceHandle, &value) }
        guard let pointer = value.text else { return "" }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(value.text_len)), as: UTF8.self)
    }
}
