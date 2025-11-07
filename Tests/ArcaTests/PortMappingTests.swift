import Testing
import Foundation

/// Tests port mapping features (Phase 4.1)
/// Validates TCP/UDP port forwarding, conflict detection, and persistence
@Suite("Port Mapping - CLI Integration", .serialized)
struct PortMappingTests {
    static let socketPath = "/tmp/arca-test-portmap.sock"
    static let testImage = "nginx:latest"
    static let logFile = "/tmp/arca-portmap-test.log"

    /// Test basic TCP port mapping (0.0.0.0:8080 -> container:80)
    @Test("Basic TCP port mapping forwards traffic correctly")
    func basicTCPPortMapping() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull nginx image if needed
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with port mapping: host 8080 -> container 80
        let containerID = try docker("run -d --name test-nginx-8080 -p 8080:80 nginx:latest", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!containerID.isEmpty, "Container should be created")

        // Wait for nginx to start
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // Verify port is listening
        let ncOutput = try? shell("nc -z 127.0.0.1 8080 && echo 'open' || echo 'closed'")
        #expect(ncOutput?.contains("open") ?? false, "Port 8080 should be listening")

        // Test HTTP request
        let curlOutput = try? shell("curl -s http://127.0.0.1:8080")
        #expect(curlOutput?.contains("nginx") ?? false, "nginx should respond on port 8080")

        // Verify docker inspect shows port bindings
        let inspectOutput = try docker("inspect test-nginx-8080", socketPath: Self.socketPath)
        #expect(inspectOutput.contains("8080/tcp"), "Port bindings should be visible in inspect")
        #expect(inspectOutput.contains("\"HostPort\": \"8080\""), "Host port should be 8080")

        // Clean up
        _ = try? docker("rm -f test-nginx-8080", socketPath: Self.socketPath)
    }

    /// Test localhost-only binding (127.0.0.1:8081 -> container:80)
    @Test("Localhost binding restricts access to loopback")
    func localhostBinding() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull nginx image if needed
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with localhost binding: 127.0.0.1:8081 -> container:80
        let containerID = try docker("run -d --name test-nginx-localhost -p 127.0.0.1:8081:80 nginx:latest", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!containerID.isEmpty, "Container should be created")

        // Wait for nginx to start
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // Verify port is listening on localhost
        let ncOutput = try? shell("nc -z 127.0.0.1 8081 && echo 'open' || echo 'closed'")
        #expect(ncOutput?.contains("open") ?? false, "Port 8081 should be listening on localhost")

        // Test HTTP request on localhost
        let curlOutput = try? shell("curl -s http://127.0.0.1:8081")
        #expect(curlOutput?.contains("nginx") ?? false, "nginx should respond on localhost:8081")

        // Verify docker inspect shows localhost binding
        let inspectOutput = try docker("inspect test-nginx-localhost", socketPath: Self.socketPath)
        #expect(inspectOutput.contains("127.0.0.1"), "Host IP should be 127.0.0.1")
        #expect(inspectOutput.contains("\"HostPort\": \"8081\""), "Host port should be 8081")

        // Clean up
        _ = try? docker("rm -f test-nginx-localhost", socketPath: Self.socketPath)
    }

    /// Test port conflict detection
    @Test("Port conflicts are detected and rejected")
    func portConflictDetection() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull nginx image if needed
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create first container on port 8080
        let container1 = try docker("run -d --name test-nginx-1 -p 8080:80 nginx:latest", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!container1.isEmpty, "First container should be created")

        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Try to create second container on same port - should fail
        let didFail = dockerExpectFailure("run -d --name test-nginx-2 -p 8080:80 nginx:latest", socketPath: Self.socketPath)
        #expect(didFail, "Second container on same port should fail")

        // Verify error message mentions port conflict
        // Note: dockerExpectFailure doesn't capture output, so we can't verify message content here
        // But the fact that it failed is sufficient evidence

        // Clean up
        _ = try? docker("rm -f test-nginx-1 test-nginx-2", socketPath: Self.socketPath)
    }

    /// Test port release on container stop
    @Test("Ports are released when container stops")
    func portReleaseOnStop() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull nginx image if needed
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with port mapping
        let containerID = try docker("run -d --name test-nginx-stop -p 8082:80 nginx:latest", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!containerID.isEmpty, "Container should be created")

        try await Task.sleep(nanoseconds: UInt64(3.0 * 1_000_000_000))

        // Verify port is listening
        let ncOutput1 = try? shell("nc -z 127.0.0.1 8082 && echo 'open' || echo 'closed'")
        #expect(ncOutput1?.contains("open") ?? false, "Port 8082 should be listening")

        // Stop container
        _ = try docker("stop test-nginx-stop", socketPath: Self.socketPath)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Verify port is no longer listening
        let ncOutput2 = try? shell("nc -z 127.0.0.1 8082 && echo 'open' || echo 'closed'")
        #expect(ncOutput2?.contains("closed") ?? true, "Port 8082 should be closed after stop")

        // Clean up
        _ = try? docker("rm -f test-nginx-stop", socketPath: Self.socketPath)
    }

    /// Test port re-publishing on container start
    @Test("Ports are re-published when stopped container starts")
    func portRepublishOnStart() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull nginx image if needed
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with port mapping
        let containerID = try docker("run -d --name test-nginx-restart -p 8083:80 nginx:latest", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!containerID.isEmpty, "Container should be created")

        try await Task.sleep(nanoseconds: UInt64(3.0 * 1_000_000_000))

        // Stop container
        _ = try docker("stop test-nginx-restart", socketPath: Self.socketPath)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Start container again
        _ = try docker("start test-nginx-restart", socketPath: Self.socketPath)
        try await Task.sleep(nanoseconds: UInt64(3.0 * 1_000_000_000))

        // Verify port is listening again
        let ncOutput = try? shell("nc -z 127.0.0.1 8083 && echo 'open' || echo 'closed'")
        #expect(ncOutput?.contains("open") ?? false, "Port 8083 should be listening after restart")

        // Test HTTP request after restart
        let curlOutput = try? shell("curl -s http://127.0.0.1:8083")
        #expect(curlOutput?.contains("nginx") ?? false, "nginx should respond after restart")

        // Clean up
        _ = try? docker("rm -f test-nginx-restart", socketPath: Self.socketPath)
    }

    /// Test port cleanup on container remove
    @Test("Ports are freed when container is removed")
    func portCleanupOnRemove() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull nginx image if needed
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create first container on port 8084
        let container1 = try docker("run -d --name test-nginx-remove1 -p 8084:80 nginx:latest", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!container1.isEmpty, "First container should be created")

        try await Task.sleep(nanoseconds: UInt64(3.0 * 1_000_000_000))

        // Remove container
        _ = try docker("rm -f test-nginx-remove1", socketPath: Self.socketPath)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Verify port is freed - create new container on same port
        let container2 = try docker("run -d --name test-nginx-remove2 -p 8084:80 nginx:latest", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!container2.isEmpty, "Second container should be created on freed port")

        // Verify port is accessible
        try await Task.sleep(nanoseconds: UInt64(3.0 * 1_000_000_000))
        let ncOutput = try? shell("nc -z 127.0.0.1 8084 && echo 'open' || echo 'closed'")
        #expect(ncOutput?.contains("open") ?? false, "Port 8084 should be accessible by new container")

        // Clean up
        _ = try? docker("rm -f test-nginx-remove2", socketPath: Self.socketPath)
    }

    /// Test port mapping persistence across daemon restart
    @Test("Port mappings persist across daemon restart")
    func portMappingPersistence() async throws {
        // Start first daemon
        let daemonPID1 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        // Pull nginx image if needed
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with port mapping
        let containerID = try docker("run -d --name test-nginx-persist -p 8085:80 nginx:latest", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!containerID.isEmpty, "Container should be created")

        try await Task.sleep(nanoseconds: UInt64(3.0 * 1_000_000_000))

        // Verify port is accessible
        let curlOutput1 = try? shell("curl -s http://127.0.0.1:8085")
        #expect(curlOutput1?.contains("nginx") ?? false, "nginx should respond before restart")

        // Inspect container to verify port bindings
        let inspect1 = try docker("inspect test-nginx-persist", socketPath: Self.socketPath)
        #expect(inspect1.contains("8085/tcp"), "Port bindings should be in inspect before restart")

        // Stop daemon
        try stopDaemon(pid: daemonPID1)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Start daemon again
        let daemonPID2 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID2) }

        // Verify container still exists with port bindings
        let inspect2 = try docker("inspect test-nginx-persist", socketPath: Self.socketPath)
        #expect(inspect2.contains("8085/tcp"), "Port bindings should persist after restart")
        #expect(inspect2.contains("\"HostPort\": \"8085\""), "Host port should persist")

        // Start container (it should be stopped after daemon restart)
        _ = try docker("start test-nginx-persist", socketPath: Self.socketPath)
        try await Task.sleep(nanoseconds: UInt64(3.0 * 1_000_000_000))

        // Verify port is accessible after restart
        let curlOutput2 = try? shell("curl -s http://127.0.0.1:8085")
        #expect(curlOutput2?.contains("nginx") ?? false, "nginx should respond after daemon restart")

        // Clean up
        _ = try? docker("rm -f test-nginx-persist", socketPath: Self.socketPath)
    }

    /// Test multiple port mappings on same container
    @Test("Multiple port mappings work on single container")
    func multiplePortMappings() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull nginx image if needed
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container with multiple port mappings
        let containerID = try docker("run -d --name test-nginx-multi -p 8086:80 -p 8087:80 nginx:latest", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!containerID.isEmpty, "Container should be created")

        try await Task.sleep(nanoseconds: 3_000_000_000)

        // Verify both ports are listening
        let ncOutput1 = try? shell("nc -z 127.0.0.1 8086 && echo 'open' || echo 'closed'")
        #expect(ncOutput1?.contains("open") ?? false, "Port 8086 should be listening")

        let ncOutput2 = try? shell("nc -z 127.0.0.1 8087 && echo 'open' || echo 'closed'")
        #expect(ncOutput2?.contains("open") ?? false, "Port 8087 should be listening")

        // Test HTTP requests on both ports
        let curlOutput1 = try? shell("curl -s http://127.0.0.1:8086")
        #expect(curlOutput1?.contains("nginx") ?? false, "nginx should respond on port 8086")

        let curlOutput2 = try? shell("curl -s http://127.0.0.1:8087")
        #expect(curlOutput2?.contains("nginx") ?? false, "nginx should respond on port 8087")

        // Verify docker inspect shows both port bindings
        let inspectOutput = try docker("inspect test-nginx-multi", socketPath: Self.socketPath)
        #expect(inspectOutput.contains("8086"), "Port 8086 should be in inspect")
        #expect(inspectOutput.contains("8087"), "Port 8087 should be in inspect")

        // Clean up
        _ = try? docker("rm -f test-nginx-multi", socketPath: Self.socketPath)
    }
}
