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
        version: "0.1.5-alpha (API v1.51)",
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
            help: "Unix socket path for the daemon (default: ~/.arca/arca.sock)"
        )
        var socketPath: String = {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            return "\(homeDir)/.arca/arca.sock"
        }()

        @Option(
            name: .long,
            help: "Path to Linux kernel (default: ~/.arca/vmlinux)"
        )
        var kernelPath: String?

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

            // Check if daemon is already running (stale sockets are automatically cleaned)
            if ArcaDaemon.isRunning(socketPath: socketPath) {
                logger.error("Daemon is already running", metadata: [
                    "socket_path": "\(socketPath)"
                ])
                print("Error: Daemon is already running at \(socketPath)")
                print("Stop the daemon first: launchctl unload ~/Library/LaunchAgents/com.liquescent.arca.plist")
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
            let daemon = ArcaDaemon(socketPath: socketPath, kernelPath: kernelPath, logger: logger)
            let shutdownLogger = logger  // Capture for signal handlers

            // Ignore SIGPIPE (broken pipe when client disconnects)
            signal(SIGPIPE, SIG_IGN)

            // Block SIGTERM and SIGINT so we can handle them with DispatchSource
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)

            // Set up graceful shutdown on SIGTERM/SIGINT using DispatchSourceSignal
            let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())

            termSource.setEventHandler { @Sendable in
                shutdownLogger.info("Received SIGTERM, initiating graceful shutdown...")
                Task { @Sendable in
                    do {
                        try await daemon.shutdown()
                        shutdownLogger.info("Graceful shutdown complete")
                        Darwin.exit(0)
                    } catch {
                        shutdownLogger.error("Error during shutdown", metadata: ["error": "\(error)"])
                        Darwin.exit(1)
                    }
                }
            }

            intSource.setEventHandler { @Sendable in
                shutdownLogger.info("Received SIGINT (Ctrl+C), initiating graceful shutdown...")
                Task { @Sendable in
                    do {
                        try await daemon.shutdown()
                        shutdownLogger.info("Graceful shutdown complete")
                        Darwin.exit(0)
                    } catch {
                        shutdownLogger.error("Error during shutdown", metadata: ["error": "\(error)"])
                        Darwin.exit(1)
                    }
                }
            }

            termSource.resume()
            intSource.resume()

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
            help: "Unix socket path for the daemon (default: ~/.arca/arca.sock)"
        )
        var socketPath: String = {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            return "\(homeDir)/.arca/arca.sock"
        }()

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
            help: "Unix socket path for the daemon (default: ~/.arca/arca.sock)"
        )
        var socketPath: String = {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            return "\(homeDir)/.arca/arca.sock"
        }()

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
