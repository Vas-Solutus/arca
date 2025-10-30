import Foundation

// MARK: - Build Request Parameters

/// Parameters for POST /build endpoint (from query strings)
public struct BuildParameters: Sendable {
    /// Path within the build context to the Dockerfile
    public let dockerfile: String

    /// Image tags to apply (name:tag format)
    public let tags: [String]

    /// Build-time variables (key-value pairs)
    public let buildArgs: [String: String]

    /// Do not use cache when building
    public let noCache: Bool

    /// Attempt to pull image even if older exists locally
    public let pull: Bool

    /// Remove intermediate containers after build
    public let remove: Bool

    /// Always remove intermediate containers (even on failure)
    public let forceRemove: Bool

    /// Suppress verbose build output
    public let quiet: Bool

    /// Image labels to apply (key-value pairs)
    public let labels: [String: String]

    /// Network mode for RUN commands during build
    public let networkMode: String?

    /// Target build stage
    public let target: String?

    /// Platform (e.g., "linux/amd64", "linux/arm64")
    public let platform: String?

    public init(
        dockerfile: String = "Dockerfile",
        tags: [String] = [],
        buildArgs: [String: String] = [:],
        noCache: Bool = false,
        pull: Bool = false,
        remove: Bool = true,
        forceRemove: Bool = false,
        quiet: Bool = false,
        labels: [String: String] = [:],
        networkMode: String? = nil,
        target: String? = nil,
        platform: String? = nil
    ) {
        self.dockerfile = dockerfile
        self.tags = tags
        self.buildArgs = buildArgs
        self.noCache = noCache
        self.pull = pull
        self.remove = remove
        self.forceRemove = forceRemove
        self.quiet = quiet
        self.labels = labels
        self.networkMode = networkMode
        self.target = target
        self.platform = platform
    }
}

// MARK: - Build Response (Streaming)

/// Build progress status message (streamed as newline-delimited JSON)
public struct BuildStatus: Codable, Sendable {
    /// Status message (e.g., "Building", "Successfully built")
    public let stream: String?

    /// Error message (if build failed)
    public let error: String?

    /// Error detail object
    public let errorDetail: ErrorDetail?

    /// Auxiliary data (e.g., final image ID)
    public let aux: AuxData?

    public init(
        stream: String? = nil,
        error: String? = nil,
        errorDetail: ErrorDetail? = nil,
        aux: AuxData? = nil
    ) {
        self.stream = stream
        self.error = error
        self.errorDetail = errorDetail
        self.aux = aux
    }

    /// Error detail structure
    public struct ErrorDetail: Codable, Sendable {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    /// Auxiliary data structure (contains final image ID)
    public struct AuxData: Codable, Sendable {
        /// Final image ID after build
        public let ID: String?

        public init(ID: String?) {
            self.ID = ID
        }
    }
}

// MARK: - Build Response Final

/// Final build response (after streaming completes)
public struct BuildResponse: Codable, Sendable {
    /// Final image ID
    public let id: String?

    /// Warning messages
    public let warnings: [String]?

    public init(id: String?, warnings: [String]? = nil) {
        self.id = id
        self.warnings = warnings
    }
}
