import Foundation
import Logging
import Containerization
import ContainerizationExtras

/// Health checker actor that manages health check execution for containers
/// Reference: Docker Engine API v1.51 - Health checks
/// Phase 6 - Task 6.2
public actor HealthChecker {
    private let logger: Logger
    private let execManager: ExecManager

    /// Active health check tasks by container ID
    private var activeTasks: [String: Task<Void, Never>] = [:]

    /// Health status by container ID
    private var healthStatus: [String: HealthState] = [:]

    /// Internal health state tracking
    private struct HealthState {
        var status: String  // "starting", "healthy", "unhealthy"
        var failingStreak: Int
        var log: [HealthcheckResult]
        let config: EffectiveHealthConfig
        let containerStartTime: Date
    }

    /// Effective health config with defaults applied
    private struct EffectiveHealthConfig {
        let test: [String]
        let interval: TimeInterval  // seconds
        let timeout: TimeInterval   // seconds
        let retries: Int
        let startPeriod: TimeInterval  // seconds
        let startInterval: TimeInterval  // seconds

        init(from config: HealthConfig) {
            self.test = config.test ?? []

            // Convert nanoseconds to seconds, apply defaults
            self.interval = config.interval.map { TimeInterval($0) / 1_000_000_000 } ?? 30.0
            self.timeout = config.timeout.map { TimeInterval($0) / 1_000_000_000 } ?? 30.0
            self.retries = config.retries ?? 3
            self.startPeriod = config.startPeriod.map { TimeInterval($0) / 1_000_000_000 } ?? 0.0
            self.startInterval = config.startInterval.map { TimeInterval($0) / 1_000_000_000 } ?? 5.0
        }
    }

    public init(logger: Logger, execManager: ExecManager) {
        var logger = logger
        logger[metadataKey: "component"] = "HealthChecker"
        self.logger = logger
        self.execManager = execManager
    }

    /// Start health checks for a container
    public func start(containerID: String, config: HealthConfig, containerStartTime: Date) {
        logger.info("Starting health checks", metadata: [
            "container_id": "\(containerID)",
            "test": "\(config.test ?? [])",
            "interval": "\(config.interval ?? 0)",
            "timeout": "\(config.timeout ?? 0)",
            "retries": "\(config.retries ?? 0)"
        ])

        // Stop existing health check if any
        stop(containerID: containerID)

        let effectiveConfig = EffectiveHealthConfig(from: config)

        // Validate config
        guard !effectiveConfig.test.isEmpty else {
            logger.warning("Health check config has no test command", metadata: ["container_id": "\(containerID)"])
            return
        }

        // Check for NONE healthcheck (disabled)
        if effectiveConfig.test.count == 1 && effectiveConfig.test[0] == "NONE" {
            logger.info("Health check disabled for container", metadata: ["container_id": "\(containerID)"])
            healthStatus[containerID] = HealthState(
                status: "none",
                failingStreak: 0,
                log: [],
                config: effectiveConfig,
                containerStartTime: containerStartTime
            )
            return
        }

        // Initialize health state as "starting"
        healthStatus[containerID] = HealthState(
            status: "starting",
            failingStreak: 0,
            log: [],
            config: effectiveConfig,
            containerStartTime: containerStartTime
        )

        // Start health check loop in background task
        let task = Task {
            await runHealthCheckLoop(containerID: containerID)
        }

        activeTasks[containerID] = task
    }

    /// Stop health checks for a container
    public func stop(containerID: String) {
        logger.info("Stopping health checks", metadata: ["container_id": "\(containerID)"])

        activeTasks[containerID]?.cancel()
        activeTasks.removeValue(forKey: containerID)
        healthStatus.removeValue(forKey: containerID)
    }

    /// Get current health status for a container
    public func getStatus(containerID: String) -> Health? {
        guard let state = healthStatus[containerID] else {
            return nil
        }

        return Health(
            status: state.status,
            failingStreak: state.failingStreak,
            log: state.log.isEmpty ? nil : state.log
        )
    }

    /// Run the health check loop for a container
    private func runHealthCheckLoop(containerID: String) async {
        logger.debug("Health check loop started", metadata: ["container_id": "\(containerID)"])

        while !Task.isCancelled {
            guard let state = healthStatus[containerID] else {
                logger.warning("Health state not found, stopping loop", metadata: ["container_id": "\(containerID)"])
                break
            }

            // Determine check interval based on whether we're in start period
            let timeSinceStart = Date().timeIntervalSince(state.containerStartTime)
            let inStartPeriod = timeSinceStart < state.config.startPeriod
            let checkInterval = inStartPeriod ? state.config.startInterval : state.config.interval

            // Wait for next check
            do {
                try await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
            } catch {
                logger.debug("Health check loop cancelled during sleep", metadata: ["container_id": "\(containerID)"])
                break
            }

            if Task.isCancelled {
                break
            }

            // Run health check
            await performHealthCheck(containerID: containerID, inStartPeriod: inStartPeriod)
        }

        logger.debug("Health check loop stopped", metadata: ["container_id": "\(containerID)"])
    }

    /// Perform a single health check
    private func performHealthCheck(containerID: String, inStartPeriod: Bool) async {
        guard var state = healthStatus[containerID] else {
            return
        }

        let startTime = Date()
        let startISO = ISO8601DateFormatter().string(from: startTime)

        logger.debug("Running health check", metadata: [
            "container_id": "\(containerID)",
            "in_start_period": "\(inStartPeriod)",
            "current_status": "\(state.status)",
            "failing_streak": "\(state.failingStreak)"
        ])

        // Parse the health check command
        let (cmd, args) = parseHealthCommand(state.config.test)

        // Execute health check via exec
        let exitCode: Int
        let output: String

        do {
            // Create exec instance for health check
            let execID = try await execManager.createExec(
                containerID: containerID,
                cmd: [cmd] + args,
                env: nil,  // Use container's default environment
                workingDir: nil,  // Use container's working directory
                user: nil,  // Run as container's default user
                tty: false,
                attachStdin: false,
                attachStdout: true,
                attachStderr: true
            )

            // Buffer to collect output (uses safe owned storage)
            let outputWriter = BufferWriter()

            // Capture timeout value to avoid actor isolation issues
            // timeout is already in seconds and defaults to 30.0 via EffectiveHealthConfig
            let timeoutSeconds = state.config.timeout
            let timeoutNs = UInt64(timeoutSeconds * 1_000_000_000)

            // Start exec and wait for completion (with timeout)
            // Race the timeout against exec completion
            let didTimeout = await withTaskGroup(of: Bool.self) { group in
                // Task 1: Timeout
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNs)
                        return true  // Timed out
                    } catch {
                        return false  // Cancelled
                    }
                }

                // Task 2: Exec
                group.addTask {
                    do {
                        try await self.execManager.startExec(
                            execID: execID,
                            detach: false,
                            tty: false,
                            stdin: nil,
                            stdout: outputWriter,
                            stderr: outputWriter
                        )
                        return false  // Exec completed
                    } catch {
                        self.logger.warning("Health check exec failed", metadata: [
                            "container_id": "\(containerID)",
                            "error": "\(error)"
                        ])
                        return false  // Exec failed (not a timeout)
                    }
                }

                // Wait for first task to complete, then cancel the others
                guard let result = await group.next() else {
                    return true  // Should never happen
                }
                group.cancelAll()
                return result
            }

            if didTimeout {
                // Health check timed out
                exitCode = 2  // Reserved exit code for timeout (treated as unhealthy)
                output = "Health check timed out after \(state.config.timeout) seconds"
                logger.warning("Health check timed out", metadata: ["container_id": "\(containerID)"])
            } else {
                // Get exit code from exec info
                if let execInfo = await execManager.getExecInfo(execID: execID) {
                    exitCode = execInfo.exitCode ?? 1  // Default to unhealthy if no exit code
                    output = String(data: outputWriter.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                } else {
                    exitCode = 1  // Exec not found, treat as unhealthy
                    output = "Health check exec instance not found"
                }
            }
        } catch {
            // Failed to create/run exec
            exitCode = 1
            output = "Failed to execute health check: \(error)"
            logger.error("Failed to execute health check", metadata: [
                "container_id": "\(containerID)",
                "error": "\(error)"
            ])
        }

        let endTime = Date()
        let endISO = ISO8601DateFormatter().string(from: endTime)

        // Interpret exit code: 0 = healthy, 1 = unhealthy, 2 = reserved (unhealthy), other = error (unhealthy)
        let isHealthy = (exitCode == 0)

        // Create health check result
        let result = HealthcheckResult(
            start: startISO,
            end: endISO,
            exitCode: exitCode,
            output: output
        )

        // Update health status
        if isHealthy {
            // Successful check - transition to healthy immediately (even during start period)
            // Start period only prevents FAILURES from counting, not successes
            state.failingStreak = 0
            state.status = "healthy"
            if inStartPeriod {
                logger.info("Container became healthy during start period", metadata: ["container_id": "\(containerID)"])
            } else {
                logger.info("Container is healthy", metadata: ["container_id": "\(containerID)"])
            }
        } else {
            // Failed check
            if inStartPeriod {
                // During start period, failures don't count toward unhealthy
                logger.debug("Health check failed during start period (not counted)", metadata: [
                    "container_id": "\(containerID)",
                    "exit_code": "\(exitCode)"
                ])
            } else {
                // Outside start period, increment failing streak
                state.failingStreak += 1

                if state.failingStreak >= state.config.retries {
                    state.status = "unhealthy"
                    logger.warning("Container is unhealthy", metadata: [
                        "container_id": "\(containerID)",
                        "failing_streak": "\(state.failingStreak)",
                        "exit_code": "\(exitCode)"
                    ])
                } else {
                    logger.debug("Health check failed", metadata: [
                        "container_id": "\(containerID)",
                        "failing_streak": "\(state.failingStreak)",
                        "exit_code": "\(exitCode)"
                    ])
                }
            }
        }

        // Add result to log (keep last 5)
        state.log.append(result)
        if state.log.count > 5 {
            state.log.removeFirst()
        }

        // Update state
        healthStatus[containerID] = state
    }

    /// Parse health check command into executable form
    private func parseHealthCommand(_ test: [String]) -> (String, [String]) {
        guard !test.isEmpty else {
            return ("", [])
        }

        if test[0] == "CMD" {
            // Direct exec: ["CMD", "curl", "http://..."] -> exec ["curl", "http://..."]
            let cmd = test.dropFirst()
            return (cmd.first ?? "", Array(cmd.dropFirst()))
        } else if test[0] == "CMD-SHELL" {
            // Shell exec: ["CMD-SHELL", "curl http://..."] -> exec ["sh", "-c", "curl http://..."]
            let shellCmd = test.dropFirst().joined(separator: " ")
            return ("sh", ["-c", shellCmd])
        } else {
            // Malformed, treat as CMD
            return (test.first ?? "", Array(test.dropFirst()))
        }
    }
}

/// Simple writer that safely buffers output to Data
/// Uses owned storage with proper thread-safe locking (same pattern as DataWriter in ContainerHandlers)
private final class BufferWriter: Writer, @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
    }

    func close() throws {
        // Nothing to close for a buffer
    }

    /// Get the collected output data
    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
