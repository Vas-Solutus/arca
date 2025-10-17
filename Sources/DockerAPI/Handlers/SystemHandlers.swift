import Foundation

/// Handlers for Docker Engine API system endpoints
/// Reference: Documentation/DockerEngineAPIv1.51.yaml
public struct SystemHandlers {

    /// Handle GET /_ping
    /// Returns: "OK" with 200 status
    public static func handlePing() -> PingResponse {
        return PingResponse(apiVersion: "1.51", osType: "darwin")
    }

    /// Handle GET /version
    /// Returns: Version information about the Docker Engine API
    public static func handleVersion() -> VersionResponse {
        return VersionResponse(
            version: "0.1.0",
            apiVersion: "1.51",
            minAPIVersion: "1.24",
            gitCommit: "unknown",
            goVersion: "go1.22.10",
            os: "darwin",
            arch: ProcessInfo.processInfo.machineArchitecture,
            kernelVersion: ProcessInfo.processInfo.kernelVersion,
            experimental: false,
            buildTime: "2024-01-01T00:00:00.000000000+00:00"
        )
    }
}

// MARK: - Response Models

/// Response for /_ping endpoint
public struct PingResponse: Codable {
    public let apiVersion: String
    public let osType: String

    enum CodingKeys: String, CodingKey {
        case apiVersion = "API-Version"
        case osType = "OSType"
    }

    public init(apiVersion: String, osType: String) {
        self.apiVersion = apiVersion
        self.osType = osType
    }
}

/// Response for /version endpoint
/// Based on Docker Engine API v1.51 specification
public struct VersionResponse: Codable {
    public let version: String
    public let apiVersion: String
    public let minAPIVersion: String
    public let gitCommit: String
    public let goVersion: String
    public let os: String
    public let arch: String
    public let kernelVersion: String
    public let experimental: Bool
    public let buildTime: String

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case apiVersion = "ApiVersion"
        case minAPIVersion = "MinAPIVersion"
        case gitCommit = "GitCommit"
        case goVersion = "GoVersion"
        case os = "Os"
        case arch = "Arch"
        case kernelVersion = "KernelVersion"
        case experimental = "Experimental"
        case buildTime = "BuildTime"
    }

    public init(
        version: String,
        apiVersion: String,
        minAPIVersion: String,
        gitCommit: String,
        goVersion: String,
        os: String,
        arch: String,
        kernelVersion: String,
        experimental: Bool,
        buildTime: String
    ) {
        self.version = version
        self.apiVersion = apiVersion
        self.minAPIVersion = minAPIVersion
        self.gitCommit = gitCommit
        self.goVersion = goVersion
        self.os = os
        self.arch = arch
        self.kernelVersion = kernelVersion
        self.experimental = experimental
        self.buildTime = buildTime
    }
}

// MARK: - ProcessInfo Extensions

extension ProcessInfo {
    /// Get the machine architecture (arm64, x86_64, etc.)
    var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// Get the kernel version
    var kernelVersion: String {
        var sysinfo = utsname()
        uname(&sysinfo)

        let release = withUnsafePointer(to: &sysinfo.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }

        return release
    }
}
