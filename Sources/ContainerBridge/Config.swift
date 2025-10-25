import Foundation
import Logging

/// Network backend type
public enum NetworkBackend: String, Codable, Sendable {
    case ovs = "ovs"      // Full Docker compatibility with OVS/OVN (default)
    case vmnet = "vmnet"  // High performance native vmnet (limited features)
}

/// Configuration for Arca daemon
public struct ArcaConfig: Codable, Sendable {
    public let kernelPath: String
    public let socketPath: String
    public let logLevel: String
    public let networkBackend: NetworkBackend

    enum CodingKeys: String, CodingKey {
        case kernelPath
        case socketPath
        case logLevel
        case networkBackend
    }

    public init(kernelPath: String, socketPath: String, logLevel: String, networkBackend: NetworkBackend = .ovs) {
        self.kernelPath = kernelPath
        self.socketPath = socketPath
        self.logLevel = logLevel
        self.networkBackend = networkBackend
    }
}

/// Manages configuration loading and path resolution
public final class ConfigManager {
    private let logger: Logger

    /// Default configuration
    private static let defaultConfig = ArcaConfig(
        kernelPath: "~/.arca/vmlinux",
        socketPath: "/var/run/arca.sock",
        logLevel: "info",
        networkBackend: .ovs  // Default to OVS for full Docker compatibility
    )

    public init(logger: Logger) {
        self.logger = logger
    }

    /// Load configuration from file
    /// - Parameter path: Path to config file (defaults to ~/.arca/config.json)
    /// - Returns: Loaded configuration with expanded paths
    public func loadConfig(from configPath: String? = nil) throws -> ArcaConfig {
        let path = configPath ?? "~/.arca/config.json"
        let expandedPath = expandTilde(path)

        logger.info("Loading configuration", metadata: [
            "config_path": "\(expandedPath)"
        ])

        // Check if config file exists
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            logger.warning("Config file not found, using defaults", metadata: [
                "config_path": "\(expandedPath)"
            ])
            return expandPaths(Self.defaultConfig)
        }

        // Read and parse config file
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: expandedPath))
            let decoder = JSONDecoder()
            let config = try decoder.decode(ArcaConfig.self, from: data)

            logger.info("Configuration loaded successfully", metadata: [
                "kernel_path": "\(config.kernelPath)",
                "socket_path": "\(config.socketPath)",
                "log_level": "\(config.logLevel)",
                "network_backend": "\(config.networkBackend.rawValue)"
            ])

            // Expand ~ in all paths
            return expandPaths(config)
        } catch {
            logger.error("Failed to load config file, using defaults", metadata: [
                "config_path": "\(expandedPath)",
                "error": "\(error)"
            ])
            return expandPaths(Self.defaultConfig)
        }
    }

    /// Validate that required files exist
    public func validateConfig(_ config: ArcaConfig) throws {
        let kernelPath = expandTilde(config.kernelPath)

        // Check if kernel file exists
        guard FileManager.default.fileExists(atPath: kernelPath) else {
            throw ConfigError.kernelNotFound(kernelPath)
        }

        // Check if kernel is readable
        guard FileManager.default.isReadableFile(atPath: kernelPath) else {
            throw ConfigError.kernelNotReadable(kernelPath)
        }

        logger.info("Configuration validated", metadata: [
            "kernel_path": "\(kernelPath)"
        ])
    }

    /// Expand ~ to home directory in path
    private func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~") {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            return path.replacingOccurrences(of: "~", with: homeDir, options: [.anchored])
        }
        return path
    }

    /// Expand ~ in all paths in config
    private func expandPaths(_ config: ArcaConfig) -> ArcaConfig {
        return ArcaConfig(
            kernelPath: expandTilde(config.kernelPath),
            socketPath: expandTilde(config.socketPath),
            logLevel: config.logLevel,
            networkBackend: config.networkBackend
        )
    }
}

// MARK: - Errors

public enum ConfigError: Error, CustomStringConvertible {
    case kernelNotFound(String)
    case kernelNotReadable(String)
    case invalidConfig(String)

    public var description: String {
        switch self {
        case .kernelNotFound(let path):
            return "Kernel file not found at: \(path)\nPlease run: arca setup"
        case .kernelNotReadable(let path):
            return "Kernel file not readable at: \(path)\nPlease check file permissions"
        case .invalidConfig(let msg):
            return "Invalid configuration: \(msg)"
        }
    }
}
