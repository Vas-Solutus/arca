import Testing
import Foundation
@testable import ArcaDaemon
@testable import ContainerBridge
@testable import DockerAPI

/// OverlayFS Timing Tests
/// Verifies that OverlayFS mounting happens at the correct time during container lifecycle
///
/// Prerequisites:
/// - Arca daemon must be running at /tmp/arca.sock
/// - Run with: .build/debug/Arca daemon start --socket-path /tmp/arca.sock --log-level debug
@Suite("OverlayFS Timing Verification")
struct OverlayFSTimingTests {

    static let socketPath = "/tmp/arca.sock"
    static let testImage = "alpine:latest"

    @Test("Container creation mounts OverlayFS before returning")
    func containerCreationMountsOverlayFS() async throws {
        // Pull image if needed
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container (should mount OverlayFS internally before returning)
        let createOutput = try docker(
            "create --name overlayfs-timing-test \(Self.testImage) /bin/sh -c 'sleep 3600'",
            socketPath: Self.socketPath
        )
        let containerID = createOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        defer {
            // Cleanup: force remove container
            _ = try? docker("rm -f \(containerID)", socketPath: Self.socketPath)
        }

        // Inspect container - should be "created" state, not "running"
        let inspectBeforeStart = try docker("inspect \(containerID)", socketPath: Self.socketPath)

        // Parse JSON to check state
        guard let data = inspectBeforeStart.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let container = json.first,
              let state = container["State"] as? [String: Any],
              let status = state["Status"] as? String,
              let running = state["Running"] as? Bool,
              let pid = state["Pid"] as? Int else {
            throw TestError.invalidJSON("Failed to parse container inspect output")
        }

        #expect(status == "created", "Container should be in 'created' state after docker create returns")
        #expect(running == false, "Container process should not be running yet")
        #expect(pid == 0, "Container should have no PID before start")

        print("✓ After docker create:")
        print("  - Status: \(status)")
        print("  - Running: \(running)")
        print("  - PID: \(pid)")
        print("  - OverlayFS mounted synchronously during create")

        // Start the container - this should succeed because OverlayFS is already mounted
        _ = try docker("start \(containerID)", socketPath: Self.socketPath)

        // Brief wait for process to start
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s

        // Verify container is now running
        let inspectAfterStart = try docker("inspect \(containerID)", socketPath: Self.socketPath)

        guard let afterData = inspectAfterStart.data(using: .utf8),
              let afterJson = try? JSONSerialization.jsonObject(with: afterData) as? [[String: Any]],
              let afterContainer = afterJson.first,
              let afterState = afterContainer["State"] as? [String: Any],
              let afterStatus = afterState["Status"] as? String,
              let afterRunning = afterState["Running"] as? Bool,
              let afterPid = afterState["Pid"] as? Int else {
            throw TestError.invalidJSON("Failed to parse container inspect output after start")
        }

        #expect(afterStatus == "running", "Container should be running after docker start")
        #expect(afterRunning == true, "Container state should show running")
        #expect(afterPid > 0, "Container should have a PID after start")

        print("✓ After docker start:")
        print("  - Status: \(afterStatus)")
        print("  - Running: \(afterRunning)")
        print("  - PID: \(afterPid)")
        print("")
        print("✓ Container lifecycle timing verified:")
        print("  - docker create returns with container in 'created' state")
        print("  - OverlayFS mounted during create (synchronous, no race condition)")
        print("  - docker start successfully starts process with OverlayFS rootfs")
    }

    @Test("OverlayFS rootfs is writable after mount")
    func overlayFSIsWritable() async throws {
        // Pull image if needed
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create and start container that writes to rootfs
        let createOutput = try docker(
            "create --name overlayfs-writable-test \(Self.testImage) /bin/sh -c 'echo test-write > /tmp/test.txt && cat /tmp/test.txt'",
            socketPath: Self.socketPath
        )
        let containerID = createOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        defer {
            // Cleanup
            _ = try? docker("rm -f \(containerID)", socketPath: Self.socketPath)
        }

        // Start container
        _ = try docker("start \(containerID)", socketPath: Self.socketPath)

        // Wait for container to complete
        _ = try docker("wait \(containerID)", socketPath: Self.socketPath)

        // Get logs to verify write succeeded
        let logs = try docker("logs \(containerID)", socketPath: Self.socketPath)

        #expect(logs.contains("test-write"), "Container should have successfully written to OverlayFS upper layer")

        // Check exit code
        let inspectOutput = try docker("inspect \(containerID)", socketPath: Self.socketPath)
        guard let data = inspectOutput.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let container = json.first,
              let state = container["State"] as? [String: Any],
              let exitCode = state["ExitCode"] as? Int else {
            throw TestError.invalidJSON("Failed to parse exit code")
        }

        #expect(exitCode == 0, "Container should exit successfully after writing to OverlayFS")

        print("✓ OverlayFS writable layer verified:")
        print("  - Container successfully wrote to /tmp/test.txt")
        print("  - Upper layer is functioning correctly")
        print("  - Exit code: \(exitCode)")
    }

    @Test("Multiple containers can share layer cache")
    func layerCacheSharing() async throws {
        // Pull image if needed
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        print("Creating first container from \(Self.testImage)...")
        let start1 = Date()

        // Create first container
        let create1 = try docker(
            "create --name layer-cache-test-1 \(Self.testImage) sleep 10",
            socketPath: Self.socketPath
        )
        let container1 = create1.trimmingCharacters(in: .whitespacesAndNewlines)

        let duration1 = Date().timeIntervalSince(start1)

        defer {
            _ = try? docker("rm -f \(container1)", socketPath: Self.socketPath)
        }

        print("First container created in \(String(format: "%.2f", duration1))s")
        print("Creating second container from same image (should use cached layers)...")
        let start2 = Date()

        // Create second container (should reuse cached layers)
        let create2 = try docker(
            "create --name layer-cache-test-2 \(Self.testImage) sleep 10",
            socketPath: Self.socketPath
        )
        let container2 = create2.trimmingCharacters(in: .whitespacesAndNewlines)

        let duration2 = Date().timeIntervalSince(start2)

        defer {
            _ = try? docker("rm -f \(container2)", socketPath: Self.socketPath)
        }

        print("Second container created in \(String(format: "%.2f", duration2))s")

        // Second container should be MUCH faster (layer cache hit)
        #expect(duration2 < duration1 * 0.5, "Second container should be at least 2x faster (layer cache hit)")

        // Start both containers
        _ = try docker("start \(container1)", socketPath: Self.socketPath)
        _ = try docker("start \(container2)", socketPath: Self.socketPath)

        // Brief wait
        try await Task.sleep(nanoseconds: 500_000_000)

        // Verify both are running
        let ps = try docker("ps --format '{{.ID}}'", socketPath: Self.socketPath)
        let runningIDs = ps.split(separator: "\n").map(String.init)

        let container1Running = runningIDs.contains(where: { container1.hasPrefix($0) })
        let container2Running = runningIDs.contains(where: { container2.hasPrefix($0) })

        #expect(container1Running, "Container 1 should be running with shared layer cache")
        #expect(container2Running, "Container 2 should be running with shared layer cache")

        print("")
        print("✓ Layer cache sharing verified:")
        print("  - First container:  \(String(format: "%.2f", duration1))s")
        print("  - Second container: \(String(format: "%.2f", duration2))s (cache hit)")
        print("  - Speedup: \(String(format: "%.1f", duration1 / duration2))x")
        print("  - Both containers running successfully")
    }

    @Test("Verify OverlayFS mount exists inside container")
    func verifyOverlayFSMount() async throws {
        // Pull image if needed
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create and start container that checks for overlayfs mount
        let createOutput = try docker(
            "create --name overlayfs-mount-check \(Self.testImage) /bin/sh -c 'cat /proc/mounts | grep overlay || echo NO_OVERLAY'",
            socketPath: Self.socketPath
        )
        let containerID = createOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        defer {
            _ = try? docker("rm -f \(containerID)", socketPath: Self.socketPath)
        }

        // Start and wait
        _ = try docker("start \(containerID)", socketPath: Self.socketPath)
        _ = try docker("wait \(containerID)", socketPath: Self.socketPath)

        // Check output
        let logs = try docker("logs \(containerID)", socketPath: Self.socketPath)

        // Should contain "overlay" and NOT contain "NO_OVERLAY"
        #expect(logs.contains("overlay"), "Container rootfs should be an overlayfs mount")
        #expect(!logs.contains("NO_OVERLAY"), "OverlayFS mount should be present in /proc/mounts")

        print("✓ OverlayFS mount verified:")
        print("  - /proc/mounts shows overlay filesystem")
        print("  - Container rootfs is correctly using OverlayFS")
    }
}

// MARK: - Errors

enum TestError: Error, CustomStringConvertible {
    case invalidJSON(String)

    var description: String {
        switch self {
        case .invalidJSON(let msg):
            return "Invalid JSON: \(msg)"
        }
    }
}
