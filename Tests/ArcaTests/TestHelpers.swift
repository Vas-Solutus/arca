import Foundation

// MARK: - Shared Test Helpers

/// Execute a shell command and return output
@discardableResult
func shell(_ command: String, environment: [String: String]? = nil) throws -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["-c", command]

    if let env = environment {
        var taskEnv = ProcessInfo.processInfo.environment
        for (key, value) in env {
            taskEnv[key] = value
        }
        task.environment = taskEnv
    }

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe

    try task.run()
    task.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    guard task.terminationStatus == 0 else {
        throw ArcaTestError.commandFailed(command: command, output: output, exitCode: task.terminationStatus)
    }

    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Execute a docker command with DOCKER_HOST set
@discardableResult
func docker(_ args: String, socketPath: String) throws -> String {
    let env = ["DOCKER_HOST": "unix://\(socketPath)"]
    return try shell("docker \(args)", environment: env)
}

/// Start Arca daemon and return process ID
func startDaemon(socketPath: String, arcaBinary: String = ".build/debug/Arca", logFile: String) throws -> Int32 {
    // Clean up old socket
    try? FileManager.default.removeItem(atPath: socketPath)

    // Start daemon in background
    let task = Process()
    task.executableURL = URL(fileURLWithPath: arcaBinary)
    task.arguments = ["daemon", "start", "--socket-path", socketPath, "--log-level", "debug"]

    let logHandle = FileHandle(forWritingAtPath: logFile) ?? FileHandle.standardOutput
    task.standardOutput = logHandle
    task.standardError = logHandle

    try task.run()

    // Wait for socket to appear (helper VM takes ~20-30 seconds to start)
    var attempts = 0
    while attempts < 60 {  // 60 * 0.5s = 30 second timeout
        if FileManager.default.fileExists(atPath: socketPath) {
            Thread.sleep(forTimeInterval: 3.0) // Extra time for full initialization (bridge creation, etc)
            return task.processIdentifier
        }
        Thread.sleep(forTimeInterval: 0.5)
        attempts += 1
    }

    throw ArcaTestError.daemonStartFailed
}

/// Stop Arca daemon gracefully
func stopDaemon(pid: Int32) throws {
    kill(pid, SIGTERM)

    // Wait for process to exit
    var attempts = 0
    while attempts < 20 {
        let result = kill(pid, 0)
        if result != 0 {
            // Process no longer exists
            Thread.sleep(forTimeInterval: 0.5) // Brief wait for cleanup
            return
        }
        Thread.sleep(forTimeInterval: 0.5)
        attempts += 1
    }

    // Force kill if it didn't exit gracefully
    kill(pid, SIGKILL)
}

// MARK: - Error Types

enum ArcaTestError: Error, CustomStringConvertible {
    case commandFailed(command: String, output: String, exitCode: Int32)
    case daemonStartFailed

    var description: String {
        switch self {
        case .commandFailed(let command, let output, let exitCode):
            return "Command failed: \(command)\nExit code: \(exitCode)\nOutput:\n\(output)"
        case .daemonStartFailed:
            return "Failed to start Arca daemon (socket did not appear within timeout)"
        }
    }
}
