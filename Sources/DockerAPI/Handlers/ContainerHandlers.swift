import Foundation
import Logging
import ContainerBridge

/// Handlers for Docker Engine API container endpoints
/// Reference: Documentation/DOCKER_ENGINE_API_SPEC.md
public struct ContainerHandlers {
    private let containerManager: ContainerManager
    private let logger: Logger

    public init(containerManager: ContainerManager, logger: Logger) {
        self.containerManager = containerManager
        self.logger = logger
    }

    /// Handle GET /containers/json
    /// Lists all containers
    ///
    /// Query parameters:
    /// - all: Show all containers (default shows just running)
    /// - limit: Limit the number of results
    /// - size: Return container size information
    /// - filters: JSON encoded filters
    public func handleListContainers(all: Bool = false, limit: Int? = nil, size: Bool = false, filters: [String: String] = [:]) async -> ContainerListResponse {
        logger.debug("Handling list containers request", metadata: [
            "all": "\(all)",
            "limit": "\(limit?.description ?? "none")",
            "size": "\(size)",
            "filters": "\(filters)"
        ])

        do {
            // Get containers from ContainerManager
            var containers = try await containerManager.listContainers(all: all, filters: filters)

            // Apply limit if specified
            if let limit = limit, limit > 0 {
                containers = Array(containers.prefix(limit))
            }

            // Convert to Docker API format
            let dockerContainers = containers.map { summary in
                ContainerListItem(
                    id: summary.id,
                    names: summary.names,
                    image: summary.image,
                    imageID: summary.imageID,
                    command: summary.command,
                    created: summary.created,
                    state: summary.state,
                    status: summary.status,
                    ports: summary.ports.map { port in
                        Port(
                            privatePort: port.privatePort,
                            publicPort: port.publicPort,
                            type: port.type,
                            ip: port.ip
                        )
                    },
                    labels: summary.labels,
                    sizeRw: size ? summary.sizeRw : nil,
                    sizeRootFs: size ? summary.sizeRootFs : nil
                )
            }

            logger.info("Listed containers", metadata: [
                "count": "\(dockerContainers.count)"
            ])

            return ContainerListResponse(containers: dockerContainers)
        } catch {
            logger.error("Failed to list containers", metadata: [
                "error": "\(error)"
            ])

            return ContainerListResponse(containers: [], error: error)
        }
    }

    /// Handle POST /containers/create
    /// Creates a new container
    public func handleCreateContainer(request: ContainerCreateRequest, name: String?) async -> Result<ContainerCreateResponse, ContainerError> {
        logger.info("Handling create container request", metadata: [
            "image": "\(request.image)",
            "name": "\(name ?? "auto")"
        ])

        do {
            let containerID = try await containerManager.createContainer(
                image: request.image,
                name: name,
                command: request.cmd,
                env: request.env,
                workingDir: request.workingDir,
                labels: request.labels
            )

            logger.info("Container created", metadata: [
                "id": "\(containerID)"
            ])

            return .success(ContainerCreateResponse(id: containerID))
        } catch {
            logger.error("Failed to create container", metadata: [
                "error": "\(error)"
            ])

            return .failure(ContainerError.creationFailed(error.localizedDescription))
        }
    }

    /// Handle POST /containers/{id}/start
    /// Starts a container
    public func handleStartContainer(id: String) async -> Result<Void, ContainerError> {
        logger.info("Handling start container request", metadata: [
            "id": "\(id)"
        ])

        do {
            try await containerManager.startContainer(id: id)

            logger.info("Container started", metadata: [
                "id": "\(id)"
            ])

            return .success(())
        } catch {
            logger.error("Failed to start container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.startFailed(error.localizedDescription))
        }
    }

    /// Handle POST /containers/{id}/stop
    /// Stops a container
    public func handleStopContainer(id: String, timeout: Int?) async -> Result<Void, ContainerError> {
        logger.info("Handling stop container request", metadata: [
            "id": "\(id)",
            "timeout": "\(timeout ?? 10)"
        ])

        do {
            try await containerManager.stopContainer(id: id, timeout: timeout)

            logger.info("Container stopped", metadata: [
                "id": "\(id)"
            ])

            return .success(())
        } catch {
            logger.error("Failed to stop container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.stopFailed(error.localizedDescription))
        }
    }

    /// Handle DELETE /containers/{id}
    /// Removes a container
    public func handleRemoveContainer(id: String, force: Bool, removeVolumes: Bool) async -> Result<Void, ContainerError> {
        logger.info("Handling remove container request", metadata: [
            "id": "\(id)",
            "force": "\(force)",
            "volumes": "\(removeVolumes)"
        ])

        do {
            try await containerManager.removeContainer(id: id, force: force, removeVolumes: removeVolumes)

            logger.info("Container removed", metadata: [
                "id": "\(id)"
            ])

            return .success(())
        } catch {
            logger.error("Failed to remove container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.removeFailed(error.localizedDescription))
        }
    }

    /// Handle GET /containers/{id}/json
    /// Inspects a container
    public func handleInspectContainer(id: String) async -> Result<ContainerInspect, ContainerError> {
        logger.info("Handling inspect container request", metadata: [
            "id": "\(id)"
        ])

        do {
            guard let container = try await containerManager.getContainer(id: id) else {
                logger.warning("Container not found", metadata: [
                    "id": "\(id)"
                ])
                return .failure(ContainerError.notFound(id))
            }

            // Convert internal Container type to Docker API ContainerInspect
            let inspect = ContainerInspect(
                id: container.id,
                created: ISO8601DateFormatter().string(from: container.created),
                path: container.path,
                args: container.args,
                state: ContainerStateInspect(
                    status: container.state.status,
                    running: container.state.running,
                    paused: container.state.paused,
                    restarting: container.state.restarting,
                    oomKilled: container.state.oomKilled,
                    dead: container.state.dead,
                    pid: container.state.pid,
                    exitCode: container.state.exitCode,
                    error: container.state.error,
                    startedAt: container.state.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "0001-01-01T00:00:00Z",
                    finishedAt: container.state.finishedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "0001-01-01T00:00:00Z"
                ),
                image: container.image,
                name: "/\(container.name)",
                hostConfig: HostConfigInspect(
                    binds: container.hostConfig.binds,
                    networkMode: container.hostConfig.networkMode,
                    portBindings: [:],  // TODO: Map port bindings
                    restartPolicy: RestartPolicyInspect(
                        name: container.hostConfig.restartPolicy.name,
                        maximumRetryCount: container.hostConfig.restartPolicy.maximumRetryCount
                    ),
                    autoRemove: container.hostConfig.autoRemove,
                    privileged: container.hostConfig.privileged
                ),
                config: ContainerConfigInspect(
                    hostname: container.config.hostname,
                    domainname: container.config.domainname,
                    user: container.config.user,
                    attachStdin: container.config.attachStdin,
                    attachStdout: container.config.attachStdout,
                    attachStderr: container.config.attachStderr,
                    tty: container.config.tty,
                    openStdin: container.config.openStdin,
                    stdinOnce: container.config.stdinOnce,
                    env: container.config.env,
                    cmd: container.config.cmd,
                    image: container.config.image,
                    volumes: nil,
                    workingDir: container.config.workingDir,
                    entrypoint: container.config.entrypoint,
                    labels: container.config.labels
                ),
                networkSettings: NetworkSettingsInspect(
                    ipAddress: container.networkSettings.ipAddress,
                    ipPrefixLen: container.networkSettings.ipPrefixLen,
                    gateway: container.networkSettings.gateway,
                    macAddress: container.networkSettings.macAddress,
                    networks: container.networkSettings.networks.mapValues { endpoint in
                        NetworkEndpointInspect(
                            networkID: endpoint.networkID,
                            endpointID: endpoint.endpointID,
                            gateway: endpoint.gateway,
                            ipAddress: endpoint.ipAddress,
                            ipPrefixLen: endpoint.ipPrefixLen,
                            macAddress: endpoint.macAddress
                        )
                    }
                )
            )

            logger.info("Container inspected", metadata: [
                "id": "\(id)"
            ])

            return .success(inspect)
        } catch {
            logger.error("Failed to inspect container", metadata: [
                "id": "\(id)",
                "error": "\(error)"
            ])

            return .failure(ContainerError.inspectFailed(error.localizedDescription))
        }
    }

    /// Handle GET /containers/{id}/logs
    /// Gets container logs
    ///
    /// Query parameters:
    /// - follow: Keep connection after returning logs (not yet supported)
    /// - stdout: Return logs from stdout
    /// - stderr: Return logs from stderr
    /// - since: Only return logs since this time (UNIX timestamp)
    /// - until: Only return logs before this time (UNIX timestamp)
    /// - timestamps: Add timestamps to every log line
    /// - tail: Only return this number of log lines from the end
    public func handleLogsContainer(idOrName: String, stdout: Bool, stderr: Bool, follow: Bool, since: Int?, until: Int?, timestamps: Bool, tail: String?) async -> Result<Data, ContainerError> {
        logger.info("Handling container logs request", metadata: [
            "id_or_name": "\(idOrName)",
            "stdout": "\(stdout)",
            "stderr": "\(stderr)",
            "follow": "\(follow)",
            "timestamps": "\(timestamps)",
            "tail": "\(tail ?? "all")"
        ])

        // Resolve container name or ID to Docker ID
        guard let dockerID = await containerManager.resolveContainer(idOrName: idOrName) else {
            logger.warning("Container not found", metadata: [
                "id_or_name": "\(idOrName)"
            ])
            return .failure(ContainerError.notFound(idOrName))
        }

        logger.debug("Resolved container", metadata: [
            "input": "\(idOrName)",
            "docker_id": "\(dockerID)"
        ])

        // Get log file paths
        guard let logPaths = containerManager.getLogPaths(dockerID: dockerID) else {
            logger.warning("No logs found for container", metadata: ["docker_id": "\(dockerID)"])
            return .failure(ContainerError.notFound("logs for \(idOrName)"))
        }

        do {
            // Retrieve and filter logs
            let logs = try retrieveLogs(
                logPaths: logPaths,
                stdout: stdout,
                stderr: stderr,
                since: since,
                until: until,
                timestamps: timestamps,
                tail: tail
            )

            logger.info("Container logs retrieved", metadata: [
                "id": "\(dockerID)",
                "entries": "\(logs.count)"
            ])

            // Convert to Docker multiplexed stream format
            let multiplexedData = formatMultiplexedStream(logs: logs)
            return .success(multiplexedData)
        } catch {
            logger.error("Failed to retrieve logs", metadata: [
                "docker_id": "\(dockerID)",
                "error": "\(error)"
            ])
            return .failure(ContainerError.inspectFailed("Failed to retrieve logs: \(error)"))
        }
    }

    /// Retrieve and filter container logs from JSON log files
    /// Returns array of log entries with stream type, message, and timestamp
    private func retrieveLogs(
        logPaths: ContainerBridge.ContainerLogManager.LogPaths,
        stdout: Bool,
        stderr: Bool,
        since: Int?,
        until: Int?,
        timestamps: Bool,
        tail: String?
    ) throws -> [LogEntry] {
        var allLogs: [LogEntry] = []

        // Helper to parse log files
        func parseLogs(from path: URL, forStream stream: String) throws {
            guard FileManager.default.fileExists(atPath: path.path) else {
                return
            }

            let content = try String(contentsOf: path, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)

            for line in lines {
                guard !line.isEmpty else { continue }

                // Parse JSON log entry
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let logStream = json["stream"] as? String,
                      let logMessage = json["log"] as? String,
                      let timeString = json["time"] as? String else {
                    continue
                }

                // Parse timestamp
                let formatter = ISO8601DateFormatter()
                guard let timestamp = formatter.date(from: timeString) else {
                    continue
                }

                allLogs.append(LogEntry(
                    stream: logStream,
                    message: logMessage,
                    timestamp: timestamp,
                    includeTimestamp: timestamps
                ))
            }
        }

        // Read from stdout log file if requested
        if stdout {
            try parseLogs(from: logPaths.stdoutPath, forStream: "stdout")
        }

        // Read from stderr log file if requested
        if stderr {
            try parseLogs(from: logPaths.stderrPath, forStream: "stderr")
        }

        // Sort by timestamp (logs from different streams need to be interleaved chronologically)
        allLogs.sort { $0.timestamp < $1.timestamp }

        // Filter by time range
        if let since = since {
            let sinceDate = Date(timeIntervalSince1970: TimeInterval(since))
            allLogs = allLogs.filter { $0.timestamp >= sinceDate }
        }

        if let until = until {
            let untilDate = Date(timeIntervalSince1970: TimeInterval(until))
            allLogs = allLogs.filter { $0.timestamp <= untilDate }
        }

        // Apply tail limit
        if let tailStr = tail, let tailCount = Int(tailStr) {
            allLogs = Array(allLogs.suffix(tailCount))
        }

        return allLogs
    }

    /// Format log entries as Docker multiplexed stream
    /// Docker format: [stream_type (1 byte)][padding (3 bytes)][size (4 bytes big-endian)][payload]
    /// Stream types: 0=stdin, 1=stdout, 2=stderr
    private func formatMultiplexedStream(logs: [LogEntry]) -> Data {
        var result = Data()
        let formatter = ISO8601DateFormatter()

        for entry in logs {
            // Determine stream type
            let streamType: UInt8 = entry.stream == "stdout" ? 1 : 2

            // Format message (with timestamp if requested)
            var message = entry.message
            if entry.includeTimestamp {
                let timestampStr = formatter.string(from: entry.timestamp)
                message = "\(timestampStr) \(message)"
            }

            // Convert message to data
            guard let messageData = message.data(using: .utf8) else {
                continue
            }

            // Build frame header: [stream_type][padding][size]
            var header = Data()
            header.append(streamType)                    // 1 byte: stream type
            header.append(contentsOf: [0, 0, 0])        // 3 bytes: padding

            // 4 bytes: size (big-endian UInt32)
            let size = UInt32(messageData.count)
            header.append(UInt8((size >> 24) & 0xFF))
            header.append(UInt8((size >> 16) & 0xFF))
            header.append(UInt8((size >> 8) & 0xFF))
            header.append(UInt8(size & 0xFF))

            // Append header + payload
            result.append(header)
            result.append(messageData)
        }

        return result
    }

    /// Internal structure for log entry parsing
    private struct LogEntry {
        let stream: String
        let message: String
        let timestamp: Date
        let includeTimestamp: Bool
    }

    /// Handle POST /containers/{id}/wait
    /// Wait for a container to stop
    public func handleWaitContainer(idOrName: String) async -> Result<Int, ContainerError> {
        logger.info("Handling container wait request", metadata: [
            "id_or_name": "\(idOrName)"
        ])

        // Resolve container name or ID to Docker ID
        guard let dockerID = await containerManager.resolveContainer(idOrName: idOrName) else {
            logger.warning("Container not found", metadata: [
                "id_or_name": "\(idOrName)"
            ])
            return .failure(ContainerError.notFound(idOrName))
        }

        do {
            // Wait for container to finish
            let exitCode = try await containerManager.waitContainer(id: dockerID)

            logger.info("Container wait completed", metadata: [
                "id": "\(dockerID)",
                "exit_code": "\(exitCode)"
            ])

            return .success(exitCode)
        } catch {
            logger.error("Failed to wait for container", metadata: [
                "id": "\(dockerID)",
                "error": "\(error)"
            ])
            return .failure(ContainerError.inspectFailed(error.localizedDescription))
        }
    }
}

// MARK: - Response Types

/// Response wrapper for list containers
public struct ContainerListResponse {
    public let containers: [ContainerListItem]
    public let error: Error?

    public init(containers: [ContainerListItem], error: Error? = nil) {
        self.containers = containers
        self.error = error
    }
}

// MARK: - Error Types

public enum ContainerError: Error, CustomStringConvertible {
    case creationFailed(String)
    case startFailed(String)
    case stopFailed(String)
    case removeFailed(String)
    case inspectFailed(String)
    case notFound(String)
    case invalidRequest(String)

    public var description: String {
        switch self {
        case .creationFailed(let msg):
            return "Failed to create container: \(msg)"
        case .startFailed(let msg):
            return "Failed to start container: \(msg)"
        case .stopFailed(let msg):
            return "Failed to stop container: \(msg)"
        case .removeFailed(let msg):
            return "Failed to remove container: \(msg)"
        case .inspectFailed(let msg):
            return "Failed to inspect container: \(msg)"
        case .notFound(let id):
            return "Container not found: \(id)"
        case .invalidRequest(let msg):
            return "Invalid request: \(msg)"
        }
    }
}
