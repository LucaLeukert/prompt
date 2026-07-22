import AppKit
import SwiftUI

/// Optional host integration points around Ghostty's native AppKit surface.
/// Ghostty.app leaves these unset; embedders can add chrome and intercept only
/// the host-owned gestures they understand.
@MainActor
enum GhosttyAppKitHooks {
    static var overlay: ((Ghostty.SurfaceView) -> AnyView?)?
    static var topBar: ((Ghostty.SurfaceView) -> AnyView?)?
    static var bottomBar: ((Ghostty.SurfaceView) -> AnyView?)?
    static var surfaceDidClose: ((Ghostty.SurfaceView) -> Void)?
    static var surfaceDidClick: ((Ghostty.SurfaceView) -> Void)?
    static var keyDown: ((Ghostty.SurfaceView, NSEvent, Bool) -> Bool)?
    static var terminalDidReset: ((Ghostty.SurfaceView) -> Void)?
    static var commandDidFinish: ((Ghostty.SurfaceView, Int, UInt64) -> Void)?
}
