import ArgumentParser
import Darwin
import Foundation
import Logging
import ArcaDaemon

@main
struct Arca: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "arca",
        abstract: "Docker Engine API v1.51 for Apple Containerization",
        discussion: """
            Arca implements the Docker Engine API backed by Apple's Containerization framework,
            enabling Docker CLI, Docker Compose, and the entire Docker ecosystem to work with
            Apple's high-performance, VM-per-container architecture on macOS.

            Part of the Vas Solutus project - freeing containers on macOS.
            """,
        version: "0.1.0 (API v1.51)",
        subcommands: [Daemon.self],
        defaultSubcommand: Daemon.self
    )
}

struct Daemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the Arca daemon",
        subcommands: [Start.self, Stop.self, Status.self],
        defaultSubcommand: Start.self
    )
}

extension Daemon {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start the Arca daemon"
        )

        @Option(
            name: .long,
            help: "Unix socket path for the daemon (default: /var/run/arca.sock)"
        )
        var socketPath: String = "/var/run/arca.sock"

        @Option(
            name: .long,
            help: "Log level (trace, debug, info, warning, error, critical)"
        )
        var logLevel: String = "info"

        @Flag(
            name: .long,
            help: "Run in foreground mode"
        )
        var foreground: Bool = false

        func run() async throws {
            print("Arca - Docker Engine API v1.51 for Apple Containerization")
            print("Part of the Vas Solutus project")
            print()

            // Initialize logger
            var logger = Logger(label: "com.vassolutus.arca")
            logger.logLevel = parseLogLevel(logLevel)

            // Check if daemon is already running
            if ArcaDaemon.isRunning(socketPath: socketPath) {
                logger.error("Daemon appears to be already running", metadata: [
                    "socket_path": "\(socketPath)"
                ])
                print("Error: Socket already exists at \(socketPath)")
                print("If the daemon is not running, remove the socket file and try again.")
                throw ExitCode.failure
            }

            logger.info("Starting Arca daemon", metadata: [
                "socket_path": "\(socketPath)",
                "log_level": "\(logLevel)",
                "foreground": "\(foreground)"
            ])

            print("Starting daemon...")
            print("Socket path: \(socketPath)")
            print("Log level: \(logLevel)")
            print("Mode: \(foreground ? "foreground" : "background")")
            print()
            print("To use with Docker CLI:")
            print("  export DOCKER_HOST=unix://\(socketPath)")
            print("  docker ps")
            print()

            // Create and start daemon
            let daemon = ArcaDaemon(socketPath: socketPath, logger: logger)

            // Ignore SIGPIPE (broken pipe when client disconnects)
            signal(SIGPIPE, SIG_IGN)

            // Note: Signal handling for graceful shutdown (SIGINT/SIGTERM) will be added later
            // For now, use Ctrl+C to stop the daemon

            do {
                try await daemon.start()
            } catch {
                logger.error("Failed to start daemon", metadata: [
                    "error": "\(error)"
                ])
                print("Error starting daemon: \(error)")
                throw ExitCode.failure
            }
        }

        private func parseLogLevel(_ level: String) -> Logger.Level {
            switch level.lowercased() {
            case "trace": return .trace
            case "debug": return .debug
            case "info": return .info
            case "warning", "warn": return .warning
            case "error": return .error
            case "critical": return .critical
            default:
                print("Warning: Unknown log level '\(level)', using 'info'")
                return .info
            }
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop the Arca daemon"
        )

        @Option(
            name: .long,
            help: "Unix socket path for the daemon (default: /var/run/arca.sock)"
        )
        var socketPath: String = "/var/run/arca.sock"

        func run() throws {
            print("Stopping Arca daemon...")
            print("Socket path: \(socketPath)")
            print()

            // TODO: Send shutdown signal to daemon via socket
            // TODO: Wait for graceful shutdown
            // TODO: Remove PID file if exists

            print("⚠️  Daemon implementation in progress")
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check the status of the Arca daemon"
        )

        @Option(
            name: .long,
            help: "Unix socket path for the daemon (default: /var/run/arca.sock)"
        )
        var socketPath: String = "/var/run/arca.sock"

        func run() throws {
            print("Checking Arca daemon status...")
            print("Socket path: \(socketPath)")
            print()

            // TODO: Check if socket exists
            // TODO: Try to connect and ping the daemon
            // TODO: Display version, uptime, container count

            print("⚠️  Daemon implementation in progress")
        }
    }
}
