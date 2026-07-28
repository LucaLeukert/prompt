import Foundation

@MainActor
enum AISystem {
    private static var bootstrapped = false

    static func bootstrap(cwd: String) {
        let registry = AIProviderRegistry.shared
        if !bootstrapped {
            registry.register(CodexProvider.shared)
            registry.register(CopilotProvider.shared)
            registry.register(OpenAIProvider.shared)
            bootstrapped = true
        }
        // External provider runtimes are lazy. Starting every configured
        // executable here can trigger protected-volume access before the user
        // invokes its capability.
        OpenAIProvider.shared.start(cwd: cwd)
        _ = CapabilityRouter.shared
    }
}
