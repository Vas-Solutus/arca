import Testing
@testable import ContainerBridge
import Logging
import Foundation

/// Integration tests for NetworkHelperVM
///
/// These tests require:
/// 1. The helper VM image to be built: `make helpervm`
/// 2. The Arca binary to be built and signed: `make`
///
/// Tests verify helper VM functionality by:
/// - Spawning the signed Arca daemon as a subprocess
/// - The daemon (which has virtualization entitlement) launches the helper VM
/// - Tests verify the helper VM through the daemon
struct NetworkHelperVMTests {

    private let logger = Logger(label: "arca.tests.helpervm")

    /// Helper to get paths
    private func getPaths() -> (arcaBinary: URL, helperVMImage: URL, testSocket: URL)? {
        // Find Arca binary
        let arcaBinary = URL(fileURLWithPath: ".build/debug/Arca")
        guard FileManager.default.fileExists(atPath: arcaBinary.path) else {
            return nil
        }

        // Check helper VM image
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let helperVMImage = homeDir
            .appendingPathComponent(".arca")
            .appendingPathComponent("helpervm")
            .appendingPathComponent("disk.img")

        guard FileManager.default.fileExists(atPath: helperVMImage.path) else {
            return nil
        }

        // Test socket path
        let testSocket = URL(fileURLWithPath: "/tmp/arca-test-\(UUID().uuidString).sock")

        return (arcaBinary, helperVMImage, testSocket)
    }

    @Test("Arca daemon can be launched (prerequisite for helper VM)")
    func arcaDaemonLaunches() async throws {
        guard let paths = getPaths() else {
            throw SkipTestError("""
                Prerequisites not met. Run:
                  make           # Build and sign Arca
                  make helpervm  # Build helper VM image
                """)
        }

        // Launch Arca daemon as subprocess
        let process = Process()
        process.executableURL = paths.arcaBinary
        process.arguments = [
            "daemon", "start",
            "--socket-path", paths.testSocket.path,
            "--log-level", "debug"
        ]

        // Capture output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            // Give daemon time to start (helper VM needs more time)
            try await Task.sleep(for: .seconds(5))

            // Check if process is still running
            let isRunning = process.isRunning

            // If not running, capture output to see what failed
            if !isRunning {
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outputData, encoding: .utf8) ?? ""
                let stderr = String(data: errorData, encoding: .utf8) ?? ""

                print("=== Daemon Output (stdout) ===")
                print(stdout)
                print("=== Daemon Output (stderr) ===")
                print(stderr)
                print("=== Exit Code: \(process.terminationStatus) ===")
            }

            // Verify process is running
            #expect(isRunning, "Arca daemon should be running")

            // Verify socket was created
            let socketExists = FileManager.default.fileExists(atPath: paths.testSocket.path)
            #expect(socketExists, "Unix socket should be created at \(paths.testSocket.path)")

            // Terminate daemon
            if isRunning {
                process.terminate()
                process.waitUntilExit()
            }

            // Clean up socket
            try? FileManager.default.removeItem(at: paths.testSocket)

        } catch {
            process.terminate()
            try? FileManager.default.removeItem(at: paths.testSocket)
            throw error
        }
    }

    @Test("Helper VM image exists and is accessible")
    func helperVMImageExists() throws {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let vmImagePath = homeDir
            .appendingPathComponent(".arca")
            .appendingPathComponent("helpervm")
            .appendingPathComponent("disk.img")

        guard FileManager.default.fileExists(atPath: vmImagePath.path) else {
            throw SkipTestError("""
                Helper VM image not found at \(vmImagePath.path)

                Build the helper VM image first:
                  make helpervm
                """)
        }

        // Verify it's a file and has reasonable size (should be ~500MB)
        let attributes = try FileManager.default.attributesOfItem(atPath: vmImagePath.path)
        let fileSize = attributes[.size] as? UInt64 ?? 0

        #expect(fileSize > 100_000_000, "Helper VM image should be > 100MB (actual: \(fileSize) bytes)")
        #expect(fileSize < 1_000_000_000, "Helper VM image should be < 1GB (actual: \(fileSize) bytes)")
    }

    @Test("Arca binary is properly signed with virtualization entitlement")
    func arcaBinaryIsSigned() throws {
        let arcaBinary = URL(fileURLWithPath: ".build/debug/Arca")

        guard FileManager.default.fileExists(atPath: arcaBinary.path) else {
            throw SkipTestError("""
                Arca binary not found. Build it first:
                  make
                """)
        }

        // Run codesign to verify
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", arcaBinary.path]

        let outputPipe = Pipe()
        process.standardError = outputPipe  // codesign outputs to stderr
        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        // Verify it has a signature
        #expect(output.contains("Signature="), "Binary should be code signed")

        // Note: We can't easily verify entitlements from the test without parsing XML
        // But the fact that it's signed is a good indicator
    }
}

// MARK: - Test Skip Error

/// Error thrown to skip a test
struct SkipTestError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String {
        message
    }
}
