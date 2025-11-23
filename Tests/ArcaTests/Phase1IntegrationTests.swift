import Testing
import Foundation
@testable import ArcaDaemon
@testable import ContainerBridge
@testable import DockerAPI

/// Phase 1 MVP Integration Tests
/// Tests basic Docker container lifecycle operations against a running Arca daemon
///
/// Prerequisites:
/// - Arca daemon must be running at /tmp/arca.sock
/// - Run with: .build/debug/Arca daemon start --socket-path /tmp/arca.sock --log-level debug
@Suite("Phase 1 MVP - Container Lifecycle")
struct Phase1IntegrationTests {

    static let socketPath = "/tmp/arca.sock"
    static let testImage = "alpine:latest"

    // Note: Cannot use async init in Swift Testing, so we check connectivity in each test

    // MARK: - System Tests

    @Test("Ping daemon")
    func ping() async throws {
        let client = DockerClient(socketPath: Self.socketPath)
        let response = try await client.ping()
        #expect(response.apiVersion == "1.51")
        #expect(response.osType == "linux")
    }

    @Test("Get daemon version")
    func version() async throws {
        let client = DockerClient(socketPath: Self.socketPath)
        let version = try await client.version()
        #expect(version.apiVersion == "1.51")
        #expect(version.osType == "linux")
        #expect(!version.version.isEmpty)
    }

    // MARK: - Image Tests

    @Test("Pull image with progress")
    func pullImage() async throws {
        let client = DockerClient(socketPath: Self.socketPath)

        // Pull image
        try await client.pullImage(fromImage: Self.testImage)

        // Verify it exists
        let images = try await client.listImages()
        #expect(images.contains(where: { $0.repoTags?.contains(Self.testImage) == true }))
    }

    @Test("Remove image by short ID")
    func removeImageByID() async throws {
        let client = DockerClient(socketPath: Self.socketPath)

        // Pull image first
        try await client.pullImage(fromImage: Self.testImage)

        // Get image ID
        let images = try await client.listImages()
        guard let image = images.first(where: { $0.repoTags?.contains(Self.testImage) == true }) else {
            Issue.record("Image not found after pull")
            return
        }

        // Remove by short ID (first 12 chars, skip "sha256:" prefix)
        let fullID = image.id.replacingOccurrences(of: "sha256:", with: "")
        let shortID = String(fullID.prefix(12))
        try await client.removeImage(name: shortID)

        // Verify removed
        let afterRemoval = try await client.listImages()
        #expect(!afterRemoval.contains(where: { $0.id == image.id }))
    }

    @Test("Remove image by name")
    func removeImageByName() async throws {
        let client = DockerClient(socketPath: Self.socketPath)

        // Pull image first
        try await client.pullImage(fromImage: Self.testImage)

        // Remove by name - this removes the tag but may leave the image if it has other tags
        try await client.removeImage(name: Self.testImage)

        // Verify the specific tag is removed (image may still exist with other tags like docker.io/library/alpine:latest)
        let images = try await client.listImages()
        let imageStillExists = images.contains(where: { image in
            image.repoTags?.contains(Self.testImage) == true
        })
        #expect(!imageStillExists, "Image should not have the '\(Self.testImage)' tag after removal")
    }

    // MARK: - Container Lifecycle Tests

    @Test("Create container")
    func createContainer() async throws {
        let client = DockerClient(socketPath: Self.socketPath)

        // Ensure image exists
        try await client.pullImage(fromImage: Self.testImage)

        let name = "arca-test-create-\(Date().timeIntervalSince1970)"

        let containerID = try await client.createContainer(
            image: Self.testImage,
            cmd: ["echo", "Hello from Arca"],
            name: name
        )
        #expect(!containerID.isEmpty)

        // Clean up
        try await client.removeContainer(id: containerID, force: true)
    }

    @Test("Start container")
    func startContainer() async throws {
        let client = DockerClient(socketPath: Self.socketPath)

        // Ensure image exists
        try await client.pullImage(fromImage: Self.testImage)

        let name = "arca-test-start-\(Date().timeIntervalSince1970)"

        let containerID = try await client.createContainer(
            image: Self.testImage,
            cmd: ["sleep", "30"],
            name: name
        )

        // Start container
        try await client.startContainer(id: containerID)

        // Verify it's running
        let containers = try await client.listContainers(all: false)
        #expect(containers.contains(where: { $0.id == containerID }))

        // Clean up
        try await client.removeContainer(id: containerID, force: true)
    }

    @Test("Stop container by short ID")
    func stopContainer() async throws {
        let client = DockerClient(socketPath: Self.socketPath)

        // Ensure image exists
        try await client.pullImage(fromImage: Self.testImage)

        let name = "arca-test-stop-\(Date().timeIntervalSince1970)"
        let containerID = try await client.createContainer(
            image: Self.testImage,
            cmd: ["sleep", "300"],
            name: name
        )
        try await client.startContainer(id: containerID)

        // Stop container with short ID
        let shortID = String(containerID.prefix(12))
        try await client.stopContainer(id: shortID, timeout: 10)

        // Verify it's stopped
        let containers = try await client.listContainers(all: false)
        #expect(!containers.contains(where: { $0.id == containerID }))

        // Clean up
        try await client.removeContainer(id: containerID, force: true)
    }

    @Test("Remove stopped container")
    func removeContainer() async throws {
        let client = DockerClient(socketPath: Self.socketPath)

        // Ensure image exists
        try await client.pullImage(fromImage: Self.testImage)

        let name = "arca-test-remove-\(Date().timeIntervalSince1970)"
        let containerID = try await client.createContainer(
            image: Self.testImage,
            cmd: ["echo", "test"],
            name: name
        )

        // Remove container
        try await client.removeContainer(id: containerID, force: false)

        // Verify it's removed
        let containers = try await client.listContainers(all: true)
        #expect(!containers.contains(where: { $0.id == containerID }))
    }

    @Test("Force remove running container")
    func forceRemoveRunningContainer() async throws {
        let client = DockerClient(socketPath: Self.socketPath)

        // Ensure image exists
        try await client.pullImage(fromImage: Self.testImage)

        let name = "arca-test-force-remove-\(Date().timeIntervalSince1970)"
        let containerID = try await client.createContainer(
            image: Self.testImage,
            cmd: ["sleep", "300"],
            name: name
        )
        try await client.startContainer(id: containerID)

        // Force remove running container
        let shortID = String(containerID.prefix(12))
        try await client.removeContainer(id: shortID, force: true)

        // Verify it's removed
        let containers = try await client.listContainers(all: true)
        #expect(!containers.contains(where: { $0.id == containerID }))
    }

    @Test("View container logs")
    func containerLogs() async throws {
        let client = DockerClient(socketPath: Self.socketPath)

        // Ensure image exists
        try await client.pullImage(fromImage: Self.testImage)

        let name = "arca-test-logs-\(Date().timeIntervalSince1970)"
        let containerID = try await client.createContainer(
            image: Self.testImage,
            cmd: ["sh", "-c", "echo 'Hello from Arca'; sleep 2; echo 'Goodbye'"],
            name: name
        )
        try await client.startContainer(id: containerID)

        // Wait for container to finish
        try await Task.sleep(for: .seconds(3))

        // Get logs
        let logs = try await client.containerLogs(id: containerID)
        #expect(logs.contains("Hello from Arca"))

        // Clean up
        try await client.removeContainer(id: containerID, force: true)
    }

    @Test("Remove container created without starting")
    func removeContainerWithoutStarting() async throws {
        let client = DockerClient(socketPath: Self.socketPath)

        // Ensure image exists
        try await client.pullImage(fromImage: Self.testImage)

        let name = "arca-test-create-only-\(Date().timeIntervalSince1970)"
        let containerID = try await client.createContainer(
            image: Self.testImage,
            cmd: ["echo", "test"],
            name: name
        )
        let shortID = String(containerID.prefix(12))

        // Remove without starting
        try await client.removeContainer(id: shortID, force: false)

        // Verify it's removed
        let containers = try await client.listContainers(all: true)
        #expect(!containers.contains(where: { $0.id == containerID }))
    }

    // MARK: - Error Handling Tests

    @Test("Error: Remove non-existent image")
    func removeNonExistentImage() async throws {
        let client = DockerClient(socketPath: Self.socketPath)

        await #expect(throws: (any Error).self) {
            try await client.removeImage(name: "nonexistent:image")
        }
    }

    @Test("Error: Stop non-existent container")
    func stopNonExistentContainer() async throws {
        let client = DockerClient(socketPath: Self.socketPath)

        await #expect(throws: (any Error).self) {
            try await client.stopContainer(id: "nonexistent123", timeout: 10)
        }
    }
}

// MARK: - Docker Client Helper

/// Simple HTTP client for Docker API over Unix socket
actor DockerClient {
    let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func ping() async throws -> (apiVersion: String, osType: String) {
        let response = try await request(method: "GET", path: "/_ping")
        let apiVersion = response.headers["API-Version"] ?? ""
        let osType = response.headers["OSType"] ?? ""
        return (apiVersion, osType)
    }

    func version() async throws -> (version: String, apiVersion: String, osType: String) {
        let response = try await request(method: "GET", path: "/version")
        guard let data = response.body,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DockerClientError.invalidResponse
        }

        return (
            version: json["Version"] as? String ?? "",
            apiVersion: json["ApiVersion"] as? String ?? "",
            osType: json["Os"] as? String ?? ""
        )
    }

    func listImages() async throws -> [DockerImage] {
        let response = try await request(method: "GET", path: "/images/json")
        guard let data = response.body else {
            return []
        }

        let decoder = JSONDecoder()
        return try decoder.decode([DockerImage].self, from: data)
    }

    func pullImage(fromImage: String) async throws {
        // Docker API expects fromImage to include the tag (e.g., "alpine:latest")
        // If no tag is specified, Docker defaults to "latest"
        let queryItems = [
            URLQueryItem(name: "fromImage", value: fromImage)
        ]
        _ = try await request(method: "POST", path: "/images/create", queryItems: queryItems)
    }

    func removeImage(name: String) async throws {
        _ = try await request(method: "DELETE", path: "/images/\(name)")
    }

    func listContainers(all: Bool = false) async throws -> [DockerContainer] {
        let queryItems = all ? [URLQueryItem(name: "all", value: "true")] : []
        let response = try await request(method: "GET", path: "/containers/json", queryItems: queryItems)
        guard let data = response.body else {
            return []
        }

        let decoder = JSONDecoder()
        return try decoder.decode([DockerContainer].self, from: data)
    }

    func createContainer(image: String, cmd: [String], name: String? = nil) async throws -> String {
        // Build JSON manually
        let requestBody: [String: Any] = [
            "Image": image,
            "Cmd": cmd
        ]
        let body = try JSONSerialization.data(withJSONObject: requestBody)

        var queryItems: [URLQueryItem] = []
        if let name = name {
            queryItems.append(URLQueryItem(name: "name", value: name))
        }

        let response = try await self.request(method: "POST", path: "/containers/create", queryItems: queryItems, body: body)
        guard let data = response.body,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["Id"] as? String else {
            throw DockerClientError.invalidResponse
        }

        return id
    }

    func startContainer(id: String) async throws {
        _ = try await request(method: "POST", path: "/containers/\(id)/start")
    }

    func stopContainer(id: String, timeout: Int) async throws {
        let queryItems = [URLQueryItem(name: "t", value: String(timeout))]
        _ = try await request(method: "POST", path: "/containers/\(id)/stop", queryItems: queryItems)
    }

    func removeContainer(id: String, force: Bool) async throws {
        let queryItems = force ? [URLQueryItem(name: "force", value: "true")] : []
        _ = try await request(method: "DELETE", path: "/containers/\(id)", queryItems: queryItems)
    }

    func containerLogs(id: String) async throws -> String {
        let queryItems = [
            URLQueryItem(name: "stdout", value: "true"),
            URLQueryItem(name: "stderr", value: "true")
        ]
        let response = try await request(method: "GET", path: "/containers/\(id)/logs", queryItems: queryItems)
        guard let data = response.body else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Low-level HTTP

    private func request(method: String, path: String, queryItems: [URLQueryItem] = [], body: Data? = nil) async throws -> HTTPResponse {
        print("[DockerClient] Starting request: \(method) \(path)")
        return try await withCheckedThrowingContinuation { continuation in
            do {
                print("[DockerClient] Creating socket...")
                // Create Unix domain socket
                let sock = socket(AF_UNIX, SOCK_STREAM, 0)
                guard sock >= 0 else {
                    print("[DockerClient] ERROR: Failed to create socket")
                    throw DockerClientError.invalidRequest
                }

                defer {
                    print("[DockerClient] Closing socket")
                    close(sock)
                }

                // Set receive timeout to avoid blocking forever on chunked responses
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                print("[DockerClient] Connecting to \(socketPath)...")
                // Connect to Unix socket
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)

                let pathCString = socketPath.utf8CString
                withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
                    for (index, byte) in pathCString.enumerated() {
                        ptr[index] = byte
                    }
                }

                let connectResult = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }

                guard connectResult >= 0 else {
                    print("[DockerClient] ERROR: Failed to connect (errno: \(errno))")
                    throw DockerClientError.invalidRequest
                }
                print("[DockerClient] Connected successfully")

                // Build HTTP request
                var pathWithQuery = path
                if !queryItems.isEmpty {
                    var components = URLComponents()
                    components.queryItems = queryItems
                    if let queryString = components.percentEncodedQuery {
                        pathWithQuery = "\(path)?\(queryString)"
                    }
                }

                var request = "\(method) \(pathWithQuery) HTTP/1.1\r\n"
                request += "Host: localhost\r\n"
                request += "Connection: close\r\n"

                if let body = body {
                    request += "Content-Type: application/json\r\n"
                    request += "Content-Length: \(body.count)\r\n"
                }

                request += "\r\n"

                guard let requestData = request.data(using: .utf8) else {
                    print("[DockerClient] ERROR: Failed to encode request")
                    throw DockerClientError.invalidRequest
                }

                print("[DockerClient] Sending request (\(requestData.count) bytes)...")
                // Send request
                var allData = requestData
                if let body = body {
                    allData.append(body)
                    print("[DockerClient] Including body (\(body.count) bytes)")
                }

                let bytesSent = allData.withUnsafeBytes { ptr in
                    send(sock, ptr.baseAddress, allData.count, 0)
                }
                print("[DockerClient] Sent \(bytesSent) bytes")

                print("[DockerClient] Reading response...")
                // Read response
                var responseData = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                var readCount = 0

                while true {
                    let bytesRead = recv(sock, &buffer, buffer.count, 0)
                    readCount += 1
                    print("[DockerClient] recv() call #\(readCount): \(bytesRead) bytes")
                    if bytesRead <= 0 {
                        print("[DockerClient] recv() returned \(bytesRead), ending read loop")
                        break
                    }
                    responseData.append(contentsOf: buffer[0..<bytesRead])
                }

                print("[DockerClient] Total response size: \(responseData.count) bytes")
                print("[DockerClient] Parsing response...")
                let response = try parseHTTPResponse(responseData)
                print("[DockerClient] Response parsed successfully (status: \(response.statusCode))")
                continuation.resume(returning: response)
            } catch {
                print("[DockerClient] ERROR: \(error)")
                continuation.resume(throwing: error)
            }
        }
    }

    private func parseHTTPResponse(_ data: Data) throws -> HTTPResponse {
        guard let string = String(data: data, encoding: .utf8) else {
            throw DockerClientError.invalidResponse
        }

        let parts = string.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 1 else {
            throw DockerClientError.invalidResponse
        }

        let headerLines = parts[0].components(separatedBy: "\r\n")
        guard let statusLine = headerLines.first else {
            throw DockerClientError.invalidResponse
        }

        // Parse status code
        let statusParts = statusLine.components(separatedBy: " ")
        guard statusParts.count >= 2,
              let statusCode = Int(statusParts[1]) else {
            throw DockerClientError.invalidResponse
        }

        // Parse headers
        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            let headerParts = line.components(separatedBy: ": ")
            if headerParts.count == 2 {
                headers[headerParts[0]] = headerParts[1]
            }
        }

        // Get body if present
        var body: Data?
        if parts.count > 1 {
            let bodyString = parts[1...].joined(separator: "\r\n\r\n")
            body = bodyString.data(using: .utf8)
        }

        // Check for error status codes
        if statusCode >= 400 {
            let errorMessage = body.flatMap { String(data: $0, encoding: .utf8) } ?? "HTTP \(statusCode)"
            throw DockerClientError.httpError(statusCode, errorMessage)
        }

        return HTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }

    struct HTTPResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data?
    }
}

enum DockerClientError: Error {
    case invalidRequest
    case invalidResponse
    case httpError(Int, String)
}

// MARK: - Simple Models

struct DockerImage: Codable {
    let id: String
    let repoTags: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case repoTags = "RepoTags"
    }
}

struct DockerContainer: Codable {
    let id: String
    let names: [String]?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case names = "Names"
        case state = "State"
    }
}
