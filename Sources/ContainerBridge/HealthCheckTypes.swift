import Foundation

// MARK: - Health Check Types (Phase 6 - Task 6.2)
// These types are defined in ContainerBridge to avoid circular dependencies
// DockerAPI imports ContainerBridge and re-exports these for API responses

/// Health check configuration for containers
/// Reference: Docker Engine API v1.51 - HealthConfig
public struct HealthConfig: Codable, Sendable {
    /// The test to perform:
    /// - [] inherit healthcheck from image
    /// - ["NONE"] disable healthcheck
    /// - ["CMD", args...] exec arguments directly
    /// - ["CMD-SHELL", command] run command with system's default shell
    public let test: [String]?

    /// The time to wait between checks in nanoseconds (0 means inherit)
    public let interval: Int64?

    /// The time to wait before considering the check hung in nanoseconds (0 means inherit)
    public let timeout: Int64?

    /// The number of consecutive failures needed to consider unhealthy (0 means inherit)
    public let retries: Int?

    /// Start period for container to initialize before counting retries (0 means inherit)
    public let startPeriod: Int64?

    /// The time to wait between checks during start period in nanoseconds (0 means inherit)
    public let startInterval: Int64?

    enum CodingKeys: String, CodingKey {
        case test = "Test"
        case interval = "Interval"
        case timeout = "Timeout"
        case retries = "Retries"
        case startPeriod = "StartPeriod"
        case startInterval = "StartInterval"
    }

    public init(
        test: [String]? = nil,
        interval: Int64? = nil,
        timeout: Int64? = nil,
        retries: Int? = nil,
        startPeriod: Int64? = nil,
        startInterval: Int64? = nil
    ) {
        self.test = test
        self.interval = interval
        self.timeout = timeout
        self.retries = retries
        self.startPeriod = startPeriod
        self.startInterval = startInterval
    }
}

/// Health status information for containers
/// Reference: Docker Engine API v1.51 - Health
public struct Health: Codable, Sendable {
    /// Status is one of: none, starting, healthy, unhealthy
    public let status: String

    /// FailingStreak is the number of consecutive failures
    public let failingStreak: Int

    /// Log contains the last few results (oldest first)
    public let log: [HealthcheckResult]?

    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case failingStreak = "FailingStreak"
        case log = "Log"
    }

    public init(
        status: String,
        failingStreak: Int = 0,
        log: [HealthcheckResult]? = nil
    ) {
        self.status = status
        self.failingStreak = failingStreak
        self.log = log
    }
}

/// Result from a single healthcheck probe
/// Reference: Docker Engine API v1.51 - HealthcheckResult
public struct HealthcheckResult: Codable, Sendable {
    /// Start time in RFC 3339 format with nanoseconds
    public let start: String?

    /// End time in RFC 3339 format with nanoseconds
    public let end: String?

    /// Exit code: 0 = healthy, 1 = unhealthy, 2 = reserved (unhealthy), other = error
    public let exitCode: Int

    /// Output from the check
    public let output: String

    enum CodingKeys: String, CodingKey {
        case start = "Start"
        case end = "End"
        case exitCode = "ExitCode"
        case output = "Output"
    }

    public init(
        start: String? = nil,
        end: String? = nil,
        exitCode: Int,
        output: String
    ) {
        self.start = start
        self.end = end
        self.exitCode = exitCode
        self.output = output
    }
}
