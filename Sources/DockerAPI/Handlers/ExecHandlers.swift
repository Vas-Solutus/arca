import Foundation
import Logging
import ContainerBridge
import NIOHTTP1

/// Handlers for Docker Engine API exec endpoints
/// Reference: Documentation/DOCKER_ENGINE_API_SPEC.md
public struct ExecHandlers: Sendable {
    private let execManager: ExecManager
    private let logger: Logger

    public init(execManager: ExecManager, logger: Logger) {
        self.execManager = execManager
        self.logger = logger
    }

    /// Get error description for HTTP responses
    private func errorDescription(_ error: Error) -> String {
        return error.localizedDescription
    }

    /// Handle POST /containers/{id}/exec
    /// Creates an exec instance in a running container
    ///
    /// Path parameters:
    /// - id: Container ID or name
    ///
    /// Request body: ExecConfig
    public func handleCreateExec(
        containerID: String,
        config: ExecConfig
    ) async -> Result<ExecCreateResponse, ExecError> {
        logger.info("Handling create exec request", metadata: [
            "container_id": "\(containerID)",
            "cmd": "\(config.cmd ?? [])"
        ])

        // Validate command
        guard let cmd = config.cmd, !cmd.isEmpty else {
            logger.warning("Exec command is empty or missing")
            return .failure(.invalidConfig("Command cannot be empty"))
        }

        do {
            let execID = try await execManager.createExec(
                containerID: containerID,
                cmd: cmd,
                env: config.env,
                workingDir: config.workingDir,
                user: config.user,
                tty: config.tty ?? false,
                attachStdin: config.attachStdin ?? false,
                attachStdout: config.attachStdout ?? true,
                attachStderr: config.attachStderr ?? true
            )

            logger.info("Exec instance created", metadata: [
                "exec_id": "\(execID)",
                "container_id": "\(containerID)"
            ])

            return .success(ExecCreateResponse(id: execID))
        } catch let error as ExecManagerError {
            logger.error("Failed to create exec instance", metadata: [
                "container_id": "\(containerID)",
                "error": "\(error)"
            ])

            // Map ExecManagerError to ExecError
            switch error {
            case .containerNotFound(let id):
                return .failure(.containerNotRunning(id))
            case .containerNotRunning(let id):
                return .failure(.containerNotRunning(id))
            case .invalidCommand(let msg):
                return .failure(.invalidConfig(msg))
            default:
                return .failure(.createFailed(errorDescription(error)))
            }
        } catch {
            logger.error("Failed to create exec instance", metadata: [
                "container_id": "\(containerID)",
                "error": "\(error)"
            ])

            return .failure(.createFailed(errorDescription(error)))
        }
    }

    /// Handle POST /exec/{id}/start
    /// Starts a previously created exec instance
    ///
    /// Path parameters:
    /// - id: Exec instance ID
    ///
    /// Request body: ExecStartConfig
    public func handleStartExec(
        execID: String,
        config: ExecStartConfig
    ) async -> HTTPResponseType {
        logger.info("Handling start exec request", metadata: [
            "exec_id": "\(execID)",
            "detach": "\(config.detach ?? false)"
        ])

        let detach = config.detach ?? false

        // For detached exec, start and return immediately
        if detach {
            do {
                try await execManager.startExec(
                    execID: execID,
                    detach: true,
                    tty: config.tty
                )

                logger.info("Exec instance started (detached)", metadata: [
                    "exec_id": "\(execID)"
                ])

                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: "0")
                return .standard(HTTPResponse(status: .ok, headers: headers))
            } catch let error as ExecManagerError {
                logger.error("Failed to start exec instance", metadata: [
                    "exec_id": "\(execID)",
                    "error": "\(error)"
                ])

                return .standard(HTTPResponse.error(
                    errorDescription(error),
                    status: error.description.contains("not found") ? .notFound : .internalServerError
                ))
            } catch {
                logger.error("Failed to start exec instance", metadata: [
                    "exec_id": "\(execID)",
                    "error": "\(error)"
                ])

                return .standard(HTTPResponse.error(errorDescription(error), status: .internalServerError))
            }
        }

        // TODO: For attached exec with HTTP upgrade (Connection: Upgrade, Upgrade: tcp)
        // The request is intercepted by DockerRawStreamUpgrader before reaching this handler
        // Need to move exec logic to upgrader or provide callback mechanism

        logger.warning("Exec start reached handler - upgrade should have intercepted this", metadata: [
            "exec_id": "\(execID)"
        ])

        return .standard(HTTPResponse.error(
            "Internal error: HTTP protocol upgrade not handled",
            status: .internalServerError
        ))
    }

    /// Handle GET /exec/{id}/json
    /// Returns low-level information about an exec instance
    ///
    /// Path parameters:
    /// - id: Exec instance ID
    public func handleInspectExec(execID: String) async -> Result<ExecInspect, ExecError> {
        logger.debug("Handling inspect exec request", metadata: [
            "exec_id": "\(execID)"
        ])

        guard let execInfo = await execManager.getExecInfo(execID: execID) else {
            logger.warning("Exec instance not found", metadata: [
                "exec_id": "\(execID)"
            ])
            return .failure(.execNotFound(execID))
        }

        // Convert ExecInfo to ExecInspect
        let inspect = ExecInspect(
            id: execInfo.id,
            running: execInfo.running,
            exitCode: execInfo.exitCode,
            containerID: execInfo.containerID,
            user: execInfo.config.user,
            workingDir: execInfo.config.workingDir,
            cmd: execInfo.config.cmd,
            tty: execInfo.config.tty,
            attachStdin: execInfo.config.attachStdin,
            attachStdout: execInfo.config.attachStdout,
            attachStderr: execInfo.config.attachStderr,
            pid: execInfo.pid.map(Int.init)
        )

        logger.debug("Exec instance inspected", metadata: [
            "exec_id": "\(execID)",
            "running": "\(inspect.running)"
        ])

        return .success(inspect)
    }

    /// Handle POST /exec/{id}/resize
    /// Resize the TTY session used by an exec instance
    ///
    /// Path parameters:
    /// - id: Exec instance ID
    ///
    /// Query parameters:
    /// - h: Height of the TTY session in characters
    /// - w: Width of the TTY session in characters
    public func handleResizeExec(execID: String, height: Int?, width: Int?) async -> HTTPResponseType {
        logger.debug("Handling resize exec request", metadata: [
            "exec_id": "\(execID)",
            "height": "\(height ?? 0)",
            "width": "\(width ?? 0)"
        ])

        do {
            try await execManager.resizeExec(execID: execID, height: height, width: width)

            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "0")
            return .standard(HTTPResponse(status: .ok, headers: headers))
        } catch let error as ExecManagerError {
            return .standard(HTTPResponse.error(
                errorDescription(error),
                status: error.description.contains("not found") ? .notFound : .badRequest
            ))
        } catch {
            return .standard(HTTPResponse.error(errorDescription(error), status: .internalServerError))
        }
    }
}
