import Foundation
import SQLite
import Logging

/// StateStore manages persistent container and network state in SQLite
/// All operations are atomic and thread-safe via actor isolation
/// The Connection is nonisolated because SQLite.swift handles thread safety internally
public actor StateStore {
    private nonisolated(unsafe) let db: Connection
    private let logger: Logger

    // Table definitions (nonisolated - immutable and thread-safe)
    private nonisolated(unsafe) let containers = Table("containers")
    private nonisolated(unsafe) let networks = Table("networks")
    private nonisolated(unsafe) let networkAttachments = Table("network_attachments")
    private nonisolated(unsafe) let subnetAllocation = Table("subnet_allocation")
    private nonisolated(unsafe) let schemaVersion = Table("schema_version")

    // Container columns (nonisolated - immutable and thread-safe)
    private nonisolated(unsafe) let id = Expression<String>("id")
    private nonisolated(unsafe) let name = Expression<String>("name")
    private nonisolated(unsafe) let image = Expression<String>("image")
    private nonisolated(unsafe) let imageID = Expression<String>("image_id")
    private nonisolated(unsafe) let createdAt = Expression<String>("created_at")
    private nonisolated(unsafe) let status = Expression<String>("status")
    private nonisolated(unsafe) let running = Expression<Bool>("running")
    private nonisolated(unsafe) let paused = Expression<Bool>("paused")
    private nonisolated(unsafe) let restarting = Expression<Bool>("restarting")
    private nonisolated(unsafe) let pid = Expression<Int>("pid")
    private nonisolated(unsafe) let exitCode = Expression<Int>("exit_code")
    private nonisolated(unsafe) let startedAt = Expression<String?>("started_at")
    private nonisolated(unsafe) let finishedAt = Expression<String?>("finished_at")
    private nonisolated(unsafe) let stoppedByUser = Expression<Bool>("stopped_by_user")
    private nonisolated(unsafe) let configJSON = Expression<String>("config_json")
    private nonisolated(unsafe) let hostConfigJSON = Expression<String>("host_config_json")

    // Network columns (nonisolated - immutable and thread-safe)
    private nonisolated(unsafe) let networkID = Expression<String>("id")
    private nonisolated(unsafe) let networkName = Expression<String>("name")
    private nonisolated(unsafe) let driver = Expression<String>("driver")
    private nonisolated(unsafe) let scope = Expression<String>("scope")
    private nonisolated(unsafe) let networkCreatedAt = Expression<String>("created_at")
    private nonisolated(unsafe) let subnet = Expression<String>("subnet")
    private nonisolated(unsafe) let gateway = Expression<String>("gateway")
    private nonisolated(unsafe) let ipRange = Expression<String?>("ip_range")
    private nonisolated(unsafe) let optionsJSON = Expression<String?>("options_json")
    private nonisolated(unsafe) let labelsJSON = Expression<String?>("labels_json")
    private nonisolated(unsafe) let isDefault = Expression<Bool>("is_default")

    // Network attachment columns (nonisolated - immutable and thread-safe)
    private nonisolated(unsafe) let attachmentID = Expression<Int64>("id")
    private nonisolated(unsafe) let containerID = Expression<String>("container_id")
    private nonisolated(unsafe) let attachedNetworkID = Expression<String>("network_id")
    private nonisolated(unsafe) let ipAddress = Expression<String>("ip_address")
    private nonisolated(unsafe) let macAddress = Expression<String>("mac_address")
    private nonisolated(unsafe) let aliasesJSON = Expression<String?>("aliases_json")
    private nonisolated(unsafe) let attachedAt = Expression<String>("attached_at")

    // Subnet allocation columns (nonisolated - immutable and thread-safe)
    private nonisolated(unsafe) let allocationID = Expression<Int>("id")
    private nonisolated(unsafe) let nextSubnetByte = Expression<Int>("next_subnet_byte")

    // Schema version columns (nonisolated - immutable and thread-safe)
    private nonisolated(unsafe) let version = Expression<Int>("version")
    private nonisolated(unsafe) let appliedAt = Expression<String>("applied_at")

    public enum StateStoreError: Error, CustomStringConvertible {
        case databaseInitFailed(String)
        case containerNotFound(String)
        case networkNotFound(String)
        case invalidJSON(String)
        case transactionFailed(String)

        public var description: String {
            switch self {
            case .databaseInitFailed(let reason):
                return "Database initialization failed: \(reason)"
            case .containerNotFound(let id):
                return "Container not found: \(id)"
            case .networkNotFound(let id):
                return "Network not found: \(id)"
            case .invalidJSON(let reason):
                return "Invalid JSON: \(reason)"
            case .transactionFailed(let reason):
                return "Transaction failed: \(reason)"
            }
        }
    }

    /// Initialize StateStore with database at specified path
    /// Creates database and schema if it doesn't exist
    public init(path: String, logger: Logger) throws {
        self.logger = logger

        // Expand tilde in path
        let expandedPath = NSString(string: path).expandingTildeInPath

        // Create parent directory if needed
        let parentDir = URL(fileURLWithPath: expandedPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Connect to database
        do {
            self.db = try Connection(expandedPath)
            logger.info("Connected to state database", metadata: ["path": "\(expandedPath)"])
        } catch {
            throw StateStoreError.databaseInitFailed("Failed to connect: \(error)")
        }

        // Initialize schema (synchronous because init can't be async)
        do {
            try initializeSchemaSynchronously()
        } catch {
            throw StateStoreError.databaseInitFailed("Failed to initialize schema: \(error)")
        }
    }

    // MARK: - Schema Initialization

    /// Synchronous schema initialization for use in init
    private nonisolated func initializeSchemaSynchronously() throws {
        // Check current schema version
        let currentVersion = try? db.scalar(schemaVersion.select(version.max)) ?? 0

        if currentVersion == 0 {
            print("Creating initial schema (v1)")
            try createSchemaV1Synchronously()
        }

        // Future migrations would go here
    }

    private nonisolated func createSchemaV1Synchronously() throws {
        try db.transaction {
            // Schema version table
            try db.run(schemaVersion.create(ifNotExists: true) { t in
                t.column(version, primaryKey: true)
                t.column(appliedAt, defaultValue: Date().iso8601String)
            })

            // Containers table
            try db.run(containers.create(ifNotExists: true) { t in
                t.column(id, primaryKey: true)
                t.column(name, unique: true)
                t.column(image)
                t.column(imageID)
                t.column(createdAt)
                t.column(status, defaultValue: "created")
                t.column(running, defaultValue: false)
                t.column(paused, defaultValue: false)
                t.column(restarting, defaultValue: false)
                t.column(pid, defaultValue: 0)
                t.column(exitCode, defaultValue: 0)
                t.column(startedAt)
                t.column(finishedAt)
                t.column(stoppedByUser, defaultValue: false)
                t.column(configJSON)
                t.column(hostConfigJSON)

                // Note: SQLite.swift doesn't support .in() for check constraints
                // We'll enforce this in the application layer
            })

            // Container indexes
            try db.run(containers.createIndex(name, ifNotExists: true))
            try db.run(containers.createIndex(status, ifNotExists: true))
            try db.run(containers.createIndex(image, ifNotExists: true))
            try db.run(containers.createIndex(running, ifNotExists: true))

            // Networks table
            try db.run(networks.create(ifNotExists: true) { t in
                t.column(networkID, primaryKey: true)
                t.column(networkName, unique: true)
                t.column(driver)
                t.column(scope, defaultValue: "local")
                t.column(networkCreatedAt)
                t.column(subnet)
                t.column(gateway)
                t.column(ipRange)
                t.column(optionsJSON)
                t.column(labelsJSON)
                t.column(isDefault, defaultValue: false)

                // Note: SQLite.swift doesn't support .in() for check constraints
                // We'll enforce this in the application layer
            })

            // Network indexes
            try db.run(networks.createIndex(networkName, ifNotExists: true))
            try db.run(networks.createIndex(driver, ifNotExists: true))

            // Network attachments table
            try db.run(networkAttachments.create(ifNotExists: true) { t in
                t.column(attachmentID, primaryKey: .autoincrement)
                t.column(containerID)
                t.column(attachedNetworkID)
                t.column(ipAddress)
                t.column(macAddress)
                t.column(aliasesJSON)
                t.column(attachedAt, defaultValue: Date().iso8601String)

                t.foreignKey(containerID, references: containers, id, delete: .cascade)
                t.foreignKey(attachedNetworkID, references: networks, networkID, delete: .cascade)
                t.unique(containerID, attachedNetworkID)
            })

            // Network attachment indexes
            try db.run(networkAttachments.createIndex(containerID, ifNotExists: true))
            try db.run(networkAttachments.createIndex(attachedNetworkID, ifNotExists: true))

            // Subnet allocation table (singleton)
            try db.run(subnetAllocation.create(ifNotExists: true) { t in
                t.column(allocationID, primaryKey: true)
                t.column(nextSubnetByte, defaultValue: 18)

                t.check(allocationID == 1)
                t.check(nextSubnetByte >= 18 && nextSubnetByte <= 31)
            })

            // Insert initial subnet allocation state
            try db.run(subnetAllocation.insert(or: .ignore,
                allocationID <- 1,
                nextSubnetByte <- 18
            ))

            // Mark schema as v1
            try db.run(schemaVersion.insert(version <- 1))

            print("Schema v1 created successfully")
        }
    }

    // MARK: - Public API will be added in next steps
}

// MARK: - Helper Extensions

extension Date {
    var iso8601String: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: self)
    }

    init?(iso8601String: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso8601String) else {
            return nil
        }
        self = date
    }
}
