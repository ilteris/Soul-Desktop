import Foundation

/// Process launch configuration consumed by ACP-compatible clients.
///
/// This is intentionally only the data shape. Provider-specific resolution
/// (`gemini`, `claude`, `codex`, bundled resources, registry environment, and
/// PATH lookup) remains in the app/runtime layer.
public struct ACPProviderSpawn: Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]?
    public var scrubEnvKeys: [String]
    public var cwd: String?

    public init(
        executablePath: String,
        arguments: [String],
        environment: [String: String]? = nil,
        scrubEnvKeys: [String] = [],
        cwd: String? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.scrubEnvKeys = scrubEnvKeys
        self.cwd = cwd
    }
}
