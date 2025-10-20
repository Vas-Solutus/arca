import Foundation

// MARK: - Docker API Exec Models
// Reference: Documentation/DOCKER_ENGINE_API_SPEC.md

/// Request for POST /containers/{id}/exec endpoint
/// Creates an exec instance
public struct ExecConfig: Codable {
    /// Attach to stdin
    public let attachStdin: Bool?
    /// Attach to stdout
    public let attachStdout: Bool?
    /// Attach to stderr
    public let attachStderr: Bool?
    /// Override the key sequence for detaching a container
    public let detachKeys: String?
    /// Allocate a pseudo-TTY
    public let tty: Bool?
    /// A list of environment variables in the form ["VAR=value", ...]
    public let env: [String]?
    /// Command to run specified as a string or an array of strings
    public let cmd: [String]?
    /// Runs the exec process with extended privileges
    public let privileged: Bool?
    /// The user, and optionally, group to run the exec process inside the container
    public let user: String?
    /// The working directory for the exec process inside the container
    public let workingDir: String?

    enum CodingKeys: String, CodingKey {
        case attachStdin = "AttachStdin"
        case attachStdout = "AttachStdout"
        case attachStderr = "AttachStderr"
        case detachKeys = "DetachKeys"
        case tty = "Tty"
        case env = "Env"
        case cmd = "Cmd"
        case privileged = "Privileged"
        case user = "User"
        case workingDir = "WorkingDir"
    }

    public init(
        attachStdin: Bool? = nil,
        attachStdout: Bool? = nil,
        attachStderr: Bool? = nil,
        detachKeys: String? = nil,
        tty: Bool? = nil,
        env: [String]? = nil,
        cmd: [String]? = nil,
        privileged: Bool? = nil,
        user: String? = nil,
        workingDir: String? = nil
    ) {
        self.attachStdin = attachStdin
        self.attachStdout = attachStdout
        self.attachStderr = attachStderr
        self.detachKeys = detachKeys
        self.tty = tty
        self.env = env
        self.cmd = cmd
        self.privileged = privileged
        self.user = user
        self.workingDir = workingDir
    }
}

/// Response for POST /containers/{id}/exec endpoint
public struct ExecCreateResponse: Codable {
    /// The ID of the created exec instance
    public let id: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }

    public init(id: String) {
        self.id = id
    }
}

/// Request for POST /exec/{id}/start endpoint
/// Starts a previously created exec instance
public struct ExecStartConfig: Codable, Sendable {
    /// Detach from the command
    public let detach: Bool?
    /// Allocate a pseudo-TTY
    public let tty: Bool?

    enum CodingKeys: String, CodingKey {
        case detach = "Detach"
        case tty = "Tty"
    }

    public init(detach: Bool? = nil, tty: Bool? = nil) {
        self.detach = detach
        self.tty = tty
    }
}

/// Response for GET /exec/{id}/json endpoint
/// Inspect an exec instance
public struct ExecInspect: Codable {
    /// The ID of the exec instance
    public let id: String
    /// Whether the exec instance is running
    public let running: Bool
    /// The exit code of the exec instance (only valid if running is false)
    public let exitCode: Int?
    /// The ID of the container that this exec instance is associated with
    public let containerID: String
    /// The user that is running the exec process
    public let user: String?
    /// The working directory of the exec process
    public let workingDir: String?
    /// The command being executed
    public let cmd: [String]?
    /// Whether the exec process has a TTY
    public let tty: Bool
    /// Whether stdin is attached
    public let attachStdin: Bool
    /// Whether stdout is attached
    public let attachStdout: Bool
    /// Whether stderr is attached
    public let attachStderr: Bool
    /// The process ID of the exec process
    public let pid: Int?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case running = "Running"
        case exitCode = "ExitCode"
        case containerID = "ContainerID"
        case user = "User"
        case workingDir = "WorkingDir"
        case cmd = "Cmd"
        case tty = "Tty"
        case attachStdin = "AttachStdin"
        case attachStdout = "AttachStdout"
        case attachStderr = "AttachStderr"
        case pid = "Pid"
    }

    public init(
        id: String,
        running: Bool,
        exitCode: Int?,
        containerID: String,
        user: String?,
        workingDir: String?,
        cmd: [String]?,
        tty: Bool,
        attachStdin: Bool,
        attachStdout: Bool,
        attachStderr: Bool,
        pid: Int?
    ) {
        self.id = id
        self.running = running
        self.exitCode = exitCode
        self.containerID = containerID
        self.user = user
        self.workingDir = workingDir
        self.cmd = cmd
        self.tty = tty
        self.attachStdin = attachStdin
        self.attachStdout = attachStdout
        self.attachStderr = attachStderr
        self.pid = pid
    }
}

// MARK: - Error Types

public enum ExecError: Error, CustomStringConvertible {
    case execNotFound(String)
    case containerNotRunning(String)
    case createFailed(String)
    case startFailed(String)
    case inspectFailed(String)
    case invalidConfig(String)

    public var description: String {
        switch self {
        case .execNotFound(let id):
            return "No such exec instance: \(id)"
        case .containerNotRunning(let id):
            return "Container is not running: \(id)"
        case .createFailed(let msg):
            return "Failed to create exec instance: \(msg)"
        case .startFailed(let msg):
            return "Failed to start exec instance: \(msg)"
        case .inspectFailed(let msg):
            return "Failed to inspect exec instance: \(msg)"
        case .invalidConfig(let msg):
            return "Invalid exec configuration: \(msg)"
        }
    }
}
