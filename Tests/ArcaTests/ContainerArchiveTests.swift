import Testing
import Foundation

/// Comprehensive tests for container archive operations (Phase 6 - Task 6.5)
/// Validates GET/PUT /containers/{id}/archive endpoints (docker cp functionality)
/// Uses WireGuard RPC with Go's archive/tar library - works universally without requiring tar in container
@Suite("Container Archive Operations - Phase 6.5", .serialized)
struct ContainerArchiveTests {
    static let socketPath = "/tmp/arca-test-archive.sock"
    static let testImage = "alpine:latest"
    static let logFile = "/tmp/arca-archive-test.log"

    // MARK: - GET /containers/{id}/archive Tests (docker cp FROM container)

    @Test("Copy single file from container")
    func copySingleFileFromContainer() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-cp-single alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Create a test file in the container
        _ = try docker("exec test-cp-single sh -c 'echo \"Hello from container\" > /tmp/test.txt'", socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Copy file FROM container using docker cp
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try docker("cp test-cp-single:/tmp/test.txt \(tempDir.path)/", socketPath: Self.socketPath)

        // Verify file was copied
        let copiedFile = tempDir.appendingPathComponent("test.txt")
        #expect(FileManager.default.fileExists(atPath: copiedFile.path), "Copied file should exist")

        let content = try String(contentsOf: copiedFile, encoding: .utf8)
        #expect(content.contains("Hello from container"), "File content should match")

        // Clean up
        _ = try? docker("rm -f test-cp-single", socketPath: Self.socketPath)
    }

    @Test("Copy directory from container")
    func copyDirectoryFromContainer() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-cp-dir alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Create a directory with multiple files
        _ = try docker("exec test-cp-dir sh -c 'mkdir -p /tmp/testdir && echo file1 > /tmp/testdir/file1.txt && echo file2 > /tmp/testdir/file2.txt'", socketPath: Self.socketPath)

        // Wait briefly for writes to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Copy directory FROM container
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try docker("cp test-cp-dir:/tmp/testdir \(tempDir.path)/", socketPath: Self.socketPath)

        // Verify directory and files were copied
        let copiedDir = tempDir.appendingPathComponent("testdir")
        #expect(FileManager.default.fileExists(atPath: copiedDir.path), "Copied directory should exist")

        let file1 = copiedDir.appendingPathComponent("file1.txt")
        let file2 = copiedDir.appendingPathComponent("file2.txt")
        #expect(FileManager.default.fileExists(atPath: file1.path), "file1.txt should exist")
        #expect(FileManager.default.fileExists(atPath: file2.path), "file2.txt should exist")

        let content1 = try String(contentsOf: file1, encoding: .utf8)
        let content2 = try String(contentsOf: file2, encoding: .utf8)
        #expect(content1.contains("file1"), "file1.txt content should match")
        #expect(content2.contains("file2"), "file2.txt content should match")

        // Clean up
        _ = try? docker("rm -f test-cp-dir", socketPath: Self.socketPath)
    }

    @Test("Copy /etc/hostname from container")
    func copySystemFileFromContainer() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-cp-etc alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Copy /etc/hostname FROM container
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try docker("cp test-cp-etc:/etc/hostname \(tempDir.path)/", socketPath: Self.socketPath)

        // Verify file was copied
        let copiedFile = tempDir.appendingPathComponent("hostname")
        #expect(FileManager.default.fileExists(atPath: copiedFile.path), "Copied hostname file should exist")

        // Clean up
        _ = try? docker("rm -f test-cp-etc", socketPath: Self.socketPath)
    }

    @Test("Copy non-existent path returns error")
    func copyNonExistentPath() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-cp-missing alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Try to copy non-existent file
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // This should fail
        let failed = dockerExpectFailure("cp test-cp-missing:/nonexistent/path \(tempDir.path)/", socketPath: Self.socketPath)
        #expect(failed, "Copying non-existent path should fail")

        // Clean up
        _ = try? docker("rm -f test-cp-missing", socketPath: Self.socketPath)
    }

    // MARK: - PUT /containers/{id}/archive Tests (docker cp TO container)

    @Test("Copy single file to container")
    func copySingleFileToContainer() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-cp-to-single alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Create a test file on host
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("upload.txt")
        try "Hello from host".write(to: testFile, atomically: true, encoding: .utf8)

        // Copy file TO container
        _ = try docker("cp \(testFile.path) test-cp-to-single:/tmp/", socketPath: Self.socketPath)

        // Verify file exists in container
        let result = try docker("exec test-cp-to-single cat /tmp/upload.txt", socketPath: Self.socketPath)
        #expect(result.contains("Hello from host"), "File content should match in container")

        // Clean up
        _ = try? docker("rm -f test-cp-to-single", socketPath: Self.socketPath)
    }

    @Test("Copy directory to container")
    func copyDirectoryToContainer() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-cp-to-dir alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Create a directory with files on host
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let uploadDir = tempDir.appendingPathComponent("uploaddir")
        try FileManager.default.createDirectory(at: uploadDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "content1".write(to: uploadDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try "content2".write(to: uploadDir.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        // Copy directory TO container
        _ = try docker("cp \(uploadDir.path) test-cp-to-dir:/tmp/", socketPath: Self.socketPath)

        // Verify directory and files exist in container
        let result1 = try docker("exec test-cp-to-dir cat /tmp/uploaddir/file1.txt", socketPath: Self.socketPath)
        let result2 = try docker("exec test-cp-to-dir cat /tmp/uploaddir/file2.txt", socketPath: Self.socketPath)
        #expect(result1.contains("content1"), "file1.txt content should match in container")
        #expect(result2.contains("content2"), "file2.txt content should match in container")

        // Clean up
        _ = try? docker("rm -f test-cp-to-dir", socketPath: Self.socketPath)
    }

    @Test("Copy to non-existent destination fails")
    func copyToNonExistentDestination() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-cp-to-bad alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Create a test file on host
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test.txt")
        try "test".write(to: testFile, atomically: true, encoding: .utf8)

        // Try to copy to non-existent directory (should fail)
        let failed = dockerExpectFailure("cp \(testFile.path) test-cp-to-bad:/nonexistent/directory/", socketPath: Self.socketPath)
        #expect(failed, "Copying to non-existent directory should fail")

        // Clean up
        _ = try? docker("rm -f test-cp-to-bad", socketPath: Self.socketPath)
    }

    // MARK: - Distroless Container Tests

    @Test("Copy from distroless container (no tar binary)")
    func copyFromDistrolessContainer() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Simulate distroless environment: Use alpine but remove tar binary
        // This tests that our RPC-based approach works without tar in container
        _ = try? docker("pull alpine:latest", socketPath: Self.socketPath)

        // Create container and remove tar binary to simulate distroless
        _ = try docker("run -d --name test-distroless alpine sh -c 'rm -f /bin/tar /usr/bin/tar && sleep 3600'", socketPath: Self.socketPath)

        // Wait for container to be ready and tar to be removed
        try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

        // Copy /etc/os-release from container WITHOUT tar binary (should work via RPC)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try docker("cp test-distroless:/etc/os-release \(tempDir.path)/", socketPath: Self.socketPath)

        // Verify file was copied (proves we don't need tar in container)
        let copiedFile = tempDir.appendingPathComponent("os-release")
        #expect(FileManager.default.fileExists(atPath: copiedFile.path), "Should copy from distroless container without tar")

        // Clean up
        _ = try? docker("rm -f test-distroless", socketPath: Self.socketPath)
    }

    // MARK: - Round-Trip Tests

    @Test("Round-trip: Copy file out, modify, copy back in")
    func roundTripCopyOperation() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-roundtrip alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Create initial file in container
        _ = try docker("exec test-roundtrip sh -c 'echo \"original content\" > /tmp/roundtrip.txt'", socketPath: Self.socketPath)
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Copy file OUT of container
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        _ = try docker("cp test-roundtrip:/tmp/roundtrip.txt \(tempDir.path)/", socketPath: Self.socketPath)

        // Verify original content
        let copiedFile = tempDir.appendingPathComponent("roundtrip.txt")
        var content = try String(contentsOf: copiedFile, encoding: .utf8)
        #expect(content.contains("original content"), "Original content should be preserved")

        // Modify the file on host
        try "modified content".write(to: copiedFile, atomically: true, encoding: .utf8)

        // Copy modified file BACK into container
        _ = try docker("cp \(copiedFile.path) test-roundtrip:/tmp/", socketPath: Self.socketPath)

        // Verify modified content in container
        let result = try docker("exec test-roundtrip cat /tmp/roundtrip.txt", socketPath: Self.socketPath)
        #expect(result.contains("modified content"), "Modified content should be in container")

        // Clean up
        _ = try? docker("rm -f test-roundtrip", socketPath: Self.socketPath)
    }

    // MARK: - Error Cases

    @Test("Cannot copy from stopped container")
    func cannotCopyFromStoppedContainer() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container but don't start it
        _ = try docker("create --name test-cp-stopped alpine echo hello", socketPath: Self.socketPath)

        // Try to copy from stopped container (should fail - RPC requires running container)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let failed = dockerExpectFailure("cp test-cp-stopped:/etc/hostname \(tempDir.path)/", socketPath: Self.socketPath)
        #expect(failed, "Copying from stopped container should fail")

        // Clean up
        _ = try? docker("rm -f test-cp-stopped", socketPath: Self.socketPath)
    }

    @Test("Cannot copy to stopped container")
    func cannotCopyToStoppedContainer() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container but don't start it
        _ = try docker("create --name test-cp-to-stopped alpine echo hello", socketPath: Self.socketPath)

        // Create a test file on host
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test.txt")
        try "test".write(to: testFile, atomically: true, encoding: .utf8)

        // Try to copy to stopped container (should fail - RPC requires running container)
        let failed = dockerExpectFailure("cp \(testFile.path) test-cp-to-stopped:/tmp/", socketPath: Self.socketPath)
        #expect(failed, "Copying to stopped container should fail")

        // Clean up
        _ = try? docker("rm -f test-cp-to-stopped", socketPath: Self.socketPath)
    }
}
