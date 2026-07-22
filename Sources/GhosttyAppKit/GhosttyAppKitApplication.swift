import AppKit
import SwiftUI
import GhosttyKit

struct GhosttyAppKitSurfaceConfiguration {
    var workingDirectory: String?
    var command: String?
    var initialInput: String?
    var manualIOWriteHandler: ((Data) -> Void)? = nil
}

@MainActor
final class GhosttyAppKitApplication: GhosttyAppDelegate {
    let core: Ghostty.App
    private var surfaces: [UUID: Weak<Ghostty.SurfaceView>] = [:]

    init(configDefaults: String? = nil) {
        core = Ghostty.App(
            configPath: ProcessInfo.processInfo.environment["GHOSTTY_CONFIG_PATH"],
            configDefaults: configDefaults)
        core.delegate = self
    }

    func makeSurface(configuration: GhosttyAppKitSurfaceConfiguration) -> GhosttyAppKitSurface? {
        guard let app = core.app else { return nil }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = configuration.workingDirectory
        config.command = configuration.command
        config.initialInput = configuration.initialInput
        if let handler = configuration.manualIOWriteHandler {
            config.ioMode = GHOSTTY_SURFACE_IO_MANUAL
            config.ioWriteHandler = handler
        }
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        surfaces[view.id] = Weak(view)
        return GhosttyAppKitSurface(hosting: view)
    }

    func findSurface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        surfaces[uuid]?.value
    }

    func ghosttyShouldTerminateApplication() -> Bool { false }

    func tick() { core.appTick() }
}

struct GhosttyAppKitSurfaceHost: View {
    @ObservedObject var surface: GhosttyAppKitSurface
    let application: GhosttyAppKitApplication

    var body: some View {
        Ghostty.SurfaceWrapper(surfaceView: surface.hostedView)
            .environmentObject(application.core)
    }
}
