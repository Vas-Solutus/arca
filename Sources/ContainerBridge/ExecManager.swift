import Foundation
import Logging
import Containerization
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS

/// Manages exec instances for running containers
public actor ExecManager {
    private let containerManager: ContainerManager
    private let logger: Logger

    /// Information about an exec instance
    public struct ExecInfo: Sendable {
        public let id: String
        public let containerID: String
        public let config: ExecConfig
        public var process: LinuxProcess?
        public var running: Bool
        public var exitCode: Int?
        public var pid: Int32?
        public let createdAt: Date
        public var startedAt: Date?
        public var finishedAt: Date?

        public struct ExecConfig: Sendable {
            public let cmd: [String]
            public let env: [String]
            public let workingDir: String
            public let user: String?
            public let tty: Bool
            public let attachStdin: Bool
            public let attachStdout: Bool
            public let attachStderr: Bool
        }
    }

    /// Tracked exec instances by exec ID
    private var execInstances: [String: ExecInfo] = [:]

    public init(containerManager: ContainerManager, logger: Logger) {
        self.containerManager = containerManager
        self.logger = logger
    }

    /// Create a new exec instance
    public func createExec(
        containerID: String,
        cmd: [String],
        env: [String]?,
        workingDir: String?,
        user: String?,
        tty: Bool,
        attachStdin: Bool,
        attachStdout: Bool,
        attachStderr: Bool
    ) async throws -> String {
        logger.info("Creating exec instance", metadata: [
            "container_id": "\(containerID)",
            "cmd": "\(cmd)",
            "tty": "\(tty)"
        ])

        // Validate command
        guard !cmd.isEmpty else {
            throw ExecManagerError.invalidCommand("Command cannot be empty")
        }

        // Check container exists and is running
        guard let containerState = await containerManager.getContainerState(id: containerID) else {
            throw ExecManagerError.containerNotFound(containerID)
        }

        guard containerState == "running" else {
            throw ExecManagerError.containerNotRunning(containerID)
        }

        // Generate exec ID
        let execID = generateExecID()

        // Store exec instance info
        let execConfig = ExecInfo.ExecConfig(
            cmd: cmd,
            env: env ?? [],
            workingDir: workingDir ?? "/",
            user: user,
            tty: tty,
            attachStdin: attachStdin,
            attachStdout: attachStdout,
            attachStderr: attachStderr
        )

        let execInfo = ExecInfo(
            id: execID,
            containerID: containerID,
            config: execConfig,
            process: nil,
            running: false,
            exitCode: nil,
            pid: nil,
            createdAt: Date(),
            startedAt: nil,
            finishedAt: nil
        )

        execInstances[execID] = execInfo

        logger.info("Exec instance created", metadata: [
            "exec_id": "\(execID)",
            "container_id": "\(containerID)"
        ])

        return execID
    }

    /// Start an exec instance
    public func startExec(
        execID: String,
        detach: Bool,
        tty: Bool?,
        stdin: ReaderStream? = nil,
        stdout: Writer? = nil,
        stderr: Writer? = nil
    ) async throws {
        logger.info("Starting exec instance", metadata: [
            "exec_id": "\(execID)",
            "detach": "\(detach)"
        ])

        guard var execInfo = execInstances[execID] else {
            throw ExecManagerError.execNotFound(execID)
        }

        guard !execInfo.running else {
            throw ExecManagerError.execAlreadyRunning(execID)
        }

        // Get the container's native instance
        guard let nativeContainer = await containerManager.getNativeContainer(id: execInfo.containerID) else {
            throw ExecManagerError.containerNotFound(execInfo.containerID)
        }

        // Create process configuration
        var processConfig = LinuxContainer.Configuration.Process()
        processConfig.arguments = execInfo.config.cmd

        // Only override environment if user specified any, otherwise keep defaults (including PATH)
        if !execInfo.config.env.isEmpty {
            processConfig.environmentVariables = execInfo.config.env
        }

        processConfig.workingDirectory = execInfo.config.workingDir
        processConfig.terminal = tty ?? execInfo.config.tty

        // Set up I/O streams based on attach configuration
        // For attached exec, we must provide writers/readers even if caller didn't specify
        // For detached exec, we shouldn't set them
        if !detach {
            // Set stdin if provided and attachStdin is true
            if let stdin = stdin, execInfo.config.attachStdin {
                processConfig.stdin = stdin
            }

            if let stdout = stdout {
                processConfig.stdout = stdout
            } else if execInfo.config.attachStdout {
                // Attached but no writer provided - this shouldn't happen in practice
                // but we need to handle it to avoid crashes
                logger.warning("Attached exec without stdout writer", metadata: ["exec_id": "\(execID)"])
            }

            // Only set stderr when NOT using a terminal (TTY merges stderr into stdout)
            if let stderr = stderr, !processConfig.terminal {
                processConfig.stderr = stderr
            } else if execInfo.config.attachStderr && !processConfig.terminal {
                // Attached but no writer provided
                logger.warning("Attached exec without stderr writer", metadata: ["exec_id": "\(execID)"])
            }
        }

        // Parse user if provided
        if let userStr = execInfo.config.user {
            processConfig.user = parseUser(userStr)
        }

        // Create LinuxProcess
        let process = try await nativeContainer.exec(execID, configuration: processConfig)

        // Start the process
        try await process.start()

        // Update exec info
        execInfo.process = process
        execInfo.running = true
        execInfo.pid = process.pid
        execInfo.startedAt = Date()
        execInstances[execID] = execInfo

        logger.info("Exec instance started", metadata: [
            "exec_id": "\(execID)",
            "pid": "\(process.pid)"
        ])

        // If not detached, wait for process to complete
        if !detach {
            let exitStatus = try await process.wait()

            // Close output streams to signal completion
            // This finishes the AsyncStream continuations
            // Cast to StreamingWriter to access close() method
            if let streamingWriter = stdout as? StreamingWriter {
                do {
                    try streamingWriter.close()
                } catch {
                    logger.warning("Failed to close stdout writer", metadata: [
                        "exec_id": "\(execID)",
                        "error": "\(error)"
                    ])
                }
            }

            if let streamingWriter = stderr as? StreamingWriter {
                do {
                    try streamingWriter.close()
                } catch {
                    logger.warning("Failed to close stderr writer", metadata: [
                        "exec_id": "\(execID)",
                        "error": "\(error)"
                    ])
                }
            }

            // Update exec info with exit status
            execInfo.running = false
            execInfo.exitCode = Int(exitStatus.exitCode)
            execInfo.finishedAt = Date()
            execInstances[execID] = execInfo

            // Clean up process
            try await process.delete()

            logger.info("Exec instance completed", metadata: [
                "exec_id": "\(execID)",
                "exit_code": "\(exitStatus.exitCode)"
            ])
        }
    }

    /// Get exec instance info
    public func getExecInfo(execID: String) -> ExecInfo? {
        return execInstances[execID]
    }

    /// Resize the TTY for an exec instance
    public func resizeExec(execID: String, height: Int?, width: Int?) async throws {
        guard let execInfo = execInstances[execID] else {
            throw ExecManagerError.execNotFound(execID)
        }

        guard let process = execInfo.process else {
            throw ExecManagerError.startFailed("Exec process not started")
        }

        guard execInfo.config.tty else {
            // Not an error - just silently ignore resize for non-TTY exec
            logger.debug("Ignoring resize for non-TTY exec", metadata: ["exec_id": "\(execID)"])
            return
        }

        let h = UInt16(height ?? 24)
        let w = UInt16(width ?? 80)

        logger.debug("Resizing exec TTY", metadata: [
            "exec_id": "\(execID)",
            "height": "\(h)",
            "width": "\(w)"
        ])

        let size = Terminal.Size(width: w, height: h)
        try await process.resize(to: size)
    }

    /// Delete an exec instance
    public func deleteExec(execID: String) async throws {
        logger.info("Deleting exec instance", metadata: ["exec_id": "\(execID)"])

        guard let execInfo = execInstances[execID] else {
            throw ExecManagerError.execNotFound(execID)
        }

        // If process exists and is running, clean it up
        if let process = execInfo.process {
            do {
                try await process.delete()
            } catch {
                logger.warning("Failed to delete process", metadata: [
                    "exec_id": "\(execID)",
                    "error": "\(error)"
                ])
            }
        }

        execInstances.removeValue(forKey: execID)

        logger.info("Exec instance deleted", metadata: ["exec_id": "\(execID)"])
    }

    // MARK: - Helper Methods

    /// Generate a unique exec ID (similar to container ID format)
    private func generateExecID() -> String {
        // Docker exec IDs are 64-character hex strings
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return uuid.lowercased() + uuid.lowercased()
    }

    /// Parse user string into User struct
    /// Format: "username" or "uid" or "username:group" or "uid:gid"
    private func parseUser(_ userStr: String) -> ContainerizationOCI.User {
        // Handle empty user string
        guard !userStr.isEmpty else {
            return ContainerizationOCI.User()
        }

        let parts = userStr.split(separator: ":", maxSplits: 1)

        // Handle case where split resulted in empty array
        guard !parts.isEmpty else {
            return ContainerizationOCI.User()
        }

        var user = ContainerizationOCI.User()

        // Parse UID or username
        if let uid = UInt32(parts[0]) {
            user.uid = uid
        } else {
            user.username = String(parts[0])
        }

        // Parse GID if provided (groupname not supported by OCI spec)
        if parts.count > 1 {
            if let gid = UInt32(parts[1]) {
                user.gid = gid
            }
            // Note: groupname is not supported in ContainerizationOCI.User
            // Only numeric GID is supported
        }

        return user
    }
}

// MARK: - Error Types

public enum ExecManagerError: Error, CustomStringConvertible {
    case execNotFound(String)
    case execAlreadyRunning(String)
    case containerNotFound(String)
    case containerNotRunning(String)
    case invalidCommand(String)
    case startFailed(String)

    public var description: String {
        switch self {
        case .execNotFound(let id):
            return "No such exec instance: \(id)"
        case .execAlreadyRunning(let id):
            return "Exec instance already running: \(id)"
        case .containerNotFound(let id):
            return "No such container: \(id)"
        case .containerNotRunning(let id):
            return "Container is not running: \(id)"
        case .invalidCommand(let msg):
            return "Invalid command: \(msg)"
        case .startFailed(let msg):
            return "Failed to start exec: \(msg)"
        }
    }
}
