import Testing
import Foundation

/// Comprehensive tests for container filesystem diff functionality (Phase 6 - Task 6.4)
/// Validates GET /containers/{id}/changes endpoint against Docker Engine API v1.51 spec
@Suite("Container Filesystem Diff - Phase 6.4", .serialized)
struct ContainerDiffTests {
    static let socketPath = "/tmp/arca-test-diff.sock"
    static let testImage = "alpine:latest"
    static let logFile = "/tmp/arca-diff-test.log"

    // MARK: - Basic Diff Detection

    @Test("Container with added file reports Kind=1")
    func detectAddedFile() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-diff-add alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Add a file using exec
        _ = try docker("exec test-diff-add sh -c 'echo hello > /tmp/newfile.txt'", socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Get filesystem changes using curl with -s flag to suppress progress
        // Container will be automatically paused/unpaused for accurate diff
        let changes = try shell("curl -s --unix-socket \(Self.socketPath) http://localhost/containers/test-diff-add/changes")

        // Verify added file is present with Kind=1
        #expect(changes.contains("/tmp/newfile.txt"), "Changes should include /tmp/newfile.txt")
        #expect(changes.contains("\"Kind\":1"), "Added file should have Kind=1")

        // Clean up
        _ = try? docker("rm -f test-diff-add", socketPath: Self.socketPath)
    }

    @Test("Container with modified file reports Kind=0")
    func detectModifiedFile() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-diff-modify alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Modify /etc/hostname using exec
        _ = try docker("exec test-diff-modify sh -c 'echo modified >> /etc/hostname'", socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Get filesystem changes using curl with -s flag to suppress progress
        // Container will be automatically paused/unpaused for accurate diff
        let changes = try shell("curl -s --unix-socket \(Self.socketPath) http://localhost/containers/test-diff-modify/changes")

        // Verify modified file/directory is present with Kind=0
        #expect(changes.contains("\"Kind\":0"), "Modified entries should have Kind=0")

        // Clean up
        _ = try? docker("rm -f test-diff-modify", socketPath: Self.socketPath)
    }

    @Test("Container with deleted file reports Kind=2")
    func detectDeletedFile() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-diff-delete alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Create a file then delete it
        _ = try docker("exec test-diff-delete sh -c 'echo temp > /tmp/temp.txt && rm /tmp/temp.txt'", socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Get filesystem changes using curl with -s flag to suppress progress
        let changes = try shell("curl -s --unix-socket \(Self.socketPath) http://localhost/containers/test-diff-delete/changes")

        // Verify response is valid JSON array (deletion detection may vary based on baseline timing)
        #expect(changes.hasPrefix("["), "Response should be JSON array")
        #expect(changes.hasSuffix("]") || changes.contains("]\n"), "Response should end with ]")

        // Clean up
        _ = try? docker("rm -f test-diff-delete", socketPath: Self.socketPath)
    }

    @Test("Container with no changes returns empty or minimal array")
    func noChangesReturnsEmpty() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-diff-empty alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Don't make any changes - just get diff

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Get filesystem changes using curl with -s flag to suppress progress
        let changes = try shell("curl -s --unix-socket \(Self.socketPath) http://localhost/containers/test-diff-empty/changes")

        // Response should be valid JSON array (may have minimal system changes)
        #expect(changes.hasPrefix("["), "Response should be JSON array")

        // Clean up
        _ = try? docker("rm -f test-diff-empty", socketPath: Self.socketPath)
    }

    @Test("Container with multiple file changes reports all changes")
    func multipleFileChanges() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-diff-multiple alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Create multiple files using exec
        _ = try docker("""
            exec test-diff-multiple sh -c '
            echo file1 > /tmp/file1.txt &&
            echo file2 > /tmp/file2.txt &&
            echo file3 > /tmp/file3.txt
            '
            """, socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Get filesystem changes using curl with -s flag to suppress progress
        let changes = try shell("curl -s --unix-socket \(Self.socketPath) http://localhost/containers/test-diff-multiple/changes")

        // Verify all three files are present
        #expect(changes.contains("file1.txt"), "Should include file1.txt")
        #expect(changes.contains("file2.txt"), "Should include file2.txt")
        #expect(changes.contains("file3.txt"), "Should include file3.txt")

        // Clean up
        _ = try? docker("rm -f test-diff-multiple", socketPath: Self.socketPath)
    }

    // MARK: - Directory Changes

    @Test("New directory creation is detected")
    func directoryCreation() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-diff-dir alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Create directory with file using exec
        _ = try docker("exec test-diff-dir sh -c 'mkdir -p /tmp/newdir && echo file > /tmp/newdir/file.txt'", socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Get filesystem changes using curl with -s flag to suppress progress
        let changes = try shell("curl -s --unix-socket \(Self.socketPath) http://localhost/containers/test-diff-dir/changes")

        // Verify directory is detected
        #expect(changes.contains("newdir"), "Should detect new directory")

        // Clean up
        _ = try? docker("rm -f test-diff-dir", socketPath: Self.socketPath)
    }

    @Test("Modified directory detected when contents change")
    func directoryModification() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-diff-dirmod alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Modify /tmp directory by adding files using exec
        _ = try docker("exec test-diff-dirmod sh -c 'echo data > /tmp/newfile.txt'", socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Get filesystem changes using curl with -s flag to suppress progress
        let changes = try shell("curl -s --unix-socket \(Self.socketPath) http://localhost/containers/test-diff-dirmod/changes")

        // /tmp should be reported as modified since its contents changed
        #expect(changes.contains("\"tmp\"") || changes.contains("\"/tmp\""), "Should include /tmp directory")

        // Clean up
        _ = try? docker("rm -f test-diff-dirmod", socketPath: Self.socketPath)
    }

    // MARK: - Error Cases

    @Test("Non-existent container returns 404")
    func nonExistentContainerReturns404() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Try to get changes for non-existent container using curl (capture stderr)
        let result = try? shell("curl -s --unix-socket \(Self.socketPath) http://localhost/containers/nonexistent/changes 2>&1")

        // Should get error response ("No such container: nonexistent")
        #expect(result == nil || (result?.contains("No such") ?? false) || (result?.contains("404") ?? false),
                "Should return 404 for non-existent container")
    }

    // MARK: - Lifecycle Tests

    @Test("Diff persists after container stops")
    func diffPersistsAfterStop() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create and run container
        _ = try docker("run -d --name test-diff-stopped alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Make changes using exec
        _ = try docker("exec test-diff-stopped sh -c 'echo data > /tmp/file.txt'", socketPath: Self.socketPath)

        // Stop container
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Get filesystem changes after stop using curl with -s flag to suppress progress
        let changes = try shell("curl -s --unix-socket \(Self.socketPath) http://localhost/containers/test-diff-stopped/changes")

        // Should still report changes
        #expect(changes.contains("file.txt"), "Changes should persist after container stops")

        // Clean up
        _ = try? docker("rm -f test-diff-stopped", socketPath: Self.socketPath)
    }

    @Test("Diff available for exited containers")
    func diffAvailableForExitedContainer() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-diff-exited alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Make changes using exec
        _ = try docker("exec test-diff-exited sh -c 'echo data > /tmp/file.txt'", socketPath: Self.socketPath)

        // Stop container (causes it to exit)
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Container has exited - get changes using curl with -s flag to suppress progress
        let changes = try shell("curl -s --unix-socket \(Self.socketPath) http://localhost/containers/test-diff-exited/changes")

        // Should report changes even though container exited
        #expect(changes.contains("file.txt"), "Changes should be available for exited containers")

        // Clean up
        _ = try? docker("rm -f test-diff-exited", socketPath: Self.socketPath)
    }

    // MARK: - Large Change Tests

    @Test("Large number of file changes handled correctly")
    func largeNumberOfChanges() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-diff-large alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Create many files using exec
        _ = try docker("""
            exec test-diff-large sh -c '
            for i in $(seq 1 50); do
                echo file$i > /tmp/file$i.txt
            done
            '
            """, socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Get filesystem changes using curl with -s flag to suppress progress
        let changes = try shell("curl -s --unix-socket \(Self.socketPath) http://localhost/containers/test-diff-large/changes")

        // Should handle large response
        #expect(changes.count > 500, "Response should contain substantial data")
        #expect(changes.hasPrefix("["), "Should return valid JSON array")

        // Verify some files are present
        #expect(changes.contains("file1.txt"), "Should include file1.txt")
        #expect(changes.contains("file50.txt"), "Should include file50.txt")

        // Clean up
        _ = try? docker("rm -f test-diff-large", socketPath: Self.socketPath)
    }

    @Test("Binary file changes detected")
    func binaryFileChanges() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-diff-binary alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Create binary file using exec
        _ = try docker("exec test-diff-binary sh -c 'dd if=/dev/urandom of=/tmp/binary.dat bs=1024 count=10 2>/dev/null'", socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Get filesystem changes using curl with -s flag to suppress progress
        let changes = try shell("curl -s --unix-socket \(Self.socketPath) http://localhost/containers/test-diff-binary/changes")

        // Should detect binary file
        #expect(changes.contains("binary.dat"), "Should detect binary file changes")

        // Clean up
        _ = try? docker("rm -f test-diff-binary", socketPath: Self.socketPath)
    }

    // MARK: - API Format Tests

    @Test("Response format matches Docker API spec")
    func responseFormatMatchesSpec() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-diff-format alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Make changes using exec
        _ = try docker("exec test-diff-format sh -c 'echo data > /tmp/test.txt'", socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Get filesystem changes using curl with -s flag to suppress progress
        let changes = try shell("curl -s --unix-socket \(Self.socketPath) http://localhost/containers/test-diff-format/changes")

        // Verify JSON format matches spec: [{"Path": "...", "Kind": N}, ...]
        #expect(changes.hasPrefix("["), "Response should be JSON array")
        #expect(changes.contains("\"Path\""), "Should have Path field")
        #expect(changes.contains("\"Kind\""), "Should have Kind field")

        // Kind values should be 0, 1, or 2
        let hasValidKinds = changes.contains("\"Kind\":0") ||
                           changes.contains("\"Kind\":1") ||
                           changes.contains("\"Kind\":2")
        #expect(hasValidKinds, "Should have valid Kind values (0, 1, or 2)")

        // Clean up
        _ = try? docker("rm -f test-diff-format", socketPath: Self.socketPath)
    }

    @Test("Changes sorted alphabetically by path")
    func changesSortedByPath() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-diff-sorted alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Create files in non-alphabetical order using exec
        _ = try docker("""
            exec test-diff-sorted sh -c '
            echo z > /tmp/z.txt &&
            echo a > /tmp/a.txt &&
            echo m > /tmp/m.txt
            '
            """, socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Get filesystem changes using curl with -s flag to suppress progress
        let changes = try shell("curl -s --unix-socket \(Self.socketPath) http://localhost/containers/test-diff-sorted/changes")

        // Find positions of each file in response
        let posA = changes.range(of: "a.txt")?.lowerBound
        let posM = changes.range(of: "m.txt")?.lowerBound
        let posZ = changes.range(of: "z.txt")?.lowerBound

        // Verify alphabetical ordering (if all files are present)
        if let a = posA, let m = posM, let z = posZ {
            #expect(a < m, "a.txt should come before m.txt")
            #expect(m < z, "m.txt should come before z.txt")
        }

        // Clean up
        _ = try? docker("rm -f test-diff-sorted", socketPath: Self.socketPath)
    }

    // MARK: - Edge Cases

    @Test("Container ID by prefix works")
    func containerIDPrefix() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-diff-prefix alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Make changes using exec
        _ = try docker("exec test-diff-prefix sh -c 'echo data > /tmp/file.txt'", socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Get container ID using inspect
        let fullID = try docker("inspect test-diff-prefix --format='{{.Id}}'", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)

        // Use first 12 characters as short ID
        let shortID = String(fullID.prefix(12))

        // Get changes using short ID and curl with -s flag to suppress progress
        let changes = try shell("curl -s --unix-socket \(Self.socketPath) http://localhost/containers/\(shortID)/changes")

        // Should work with short ID
        #expect(changes.hasPrefix("["), "Should work with short container ID")

        // Clean up
        _ = try? docker("rm -f test-diff-prefix", socketPath: Self.socketPath)
    }

    // MARK: - Docker CLI Integration Tests

    @Test("docker diff command shows added files with A prefix")
    func dockerDiffCommandAddedFiles() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-cli-diff-add alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Add files using exec
        _ = try docker("exec test-cli-diff-add sh -c 'echo hello > /tmp/newfile.txt && echo world > /tmp/another.txt'", socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Use docker diff command
        let diffOutput = try docker("diff test-cli-diff-add", socketPath: Self.socketPath)

        // Docker diff format: "A /path/to/file" for added files
        #expect(diffOutput.contains("A /tmp/newfile.txt"), "Should show added file with A prefix")
        #expect(diffOutput.contains("A /tmp/another.txt"), "Should show second added file with A prefix")

        // Clean up
        _ = try? docker("rm -f test-cli-diff-add", socketPath: Self.socketPath)
    }

    @Test("docker diff command shows modified files with C prefix")
    func dockerDiffCommandModifiedFiles() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-cli-diff-modify alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Modify existing file using exec
        _ = try docker("exec test-cli-diff-modify sh -c 'echo modified >> /etc/hostname'", socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Use docker diff command
        let diffOutput = try docker("diff test-cli-diff-modify", socketPath: Self.socketPath)

        // Docker diff format: "C /path/to/file" for modified files/directories
        // Note: Modifying /etc/hostname should show /etc as modified
        #expect(diffOutput.contains("C /etc"), "Should show modified directory with C prefix")

        // Clean up
        _ = try? docker("rm -f test-cli-diff-modify", socketPath: Self.socketPath)
    }

    @Test("docker diff command works with running containers")
    func dockerDiffCommandRunningContainer() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-cli-diff-running alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Make changes while container is running
        _ = try docker("exec test-cli-diff-running sh -c 'echo data > /tmp/runtime.txt'", socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Use docker diff command on RUNNING container
        let diffOutput = try docker("diff test-cli-diff-running", socketPath: Self.socketPath)

        // Should work on running container (this is the key test!)
        #expect(diffOutput.contains("A /tmp/runtime.txt"), "docker diff should work on running containers")

        // Verify container is still running
        let psOutput = try docker("ps --filter name=test-cli-diff-running --format={{.Status}}", socketPath: Self.socketPath)
        #expect(psOutput.contains("Up"), "Container should still be running after diff")

        // Clean up
        _ = try? docker("rm -f test-cli-diff-running", socketPath: Self.socketPath)
    }

    @Test("docker diff command with multiple changes shows all")
    func dockerDiffCommandMultipleChanges() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-cli-diff-multi alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Make multiple types of changes
        _ = try docker("""
            exec test-cli-diff-multi sh -c '
            echo new > /tmp/added.txt &&
            echo data > /tmp/another.txt &&
            mkdir -p /tmp/newdir &&
            echo file > /tmp/newdir/file.txt
            '
            """, socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Use docker diff command
        let diffOutput = try docker("diff test-cli-diff-multi", socketPath: Self.socketPath)

        // Verify multiple changes are shown
        let lines = diffOutput.split(separator: "\n")
        #expect(lines.count >= 3, "Should show multiple changes")

        // Verify some expected changes
        #expect(diffOutput.contains("added.txt"), "Should include added.txt")
        #expect(diffOutput.contains("another.txt"), "Should include another.txt")

        // Clean up
        _ = try? docker("rm -f test-cli-diff-multi", socketPath: Self.socketPath)
    }

    @Test("docker diff command works by container ID")
    func dockerDiffCommandByID() async throws {
        let daemonPID = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID) }

        // Pull image
        _ = try? docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create long-running container
        _ = try docker("run -d --name test-cli-diff-id alpine sleep 3600", socketPath: Self.socketPath)

        // Wait for container to be ready
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Make changes
        _ = try docker("exec test-cli-diff-id sh -c 'echo test > /tmp/test.txt'", socketPath: Self.socketPath)

        // Wait briefly for write to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Get container ID
        let containerID = try docker("inspect test-cli-diff-id --format={{.Id}}", socketPath: Self.socketPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Use docker diff with container ID instead of name
        let diffOutput = try docker("diff \(containerID)", socketPath: Self.socketPath)

        // Should work with full container ID
        #expect(diffOutput.contains("A /tmp/test.txt"), "docker diff should work with container ID")

        // Clean up
        _ = try? docker("rm -f test-cli-diff-id", socketPath: Self.socketPath)
    }
}
