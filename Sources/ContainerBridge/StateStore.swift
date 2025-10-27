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

    // MARK: - Container Operations

    /// Save container state to database
    public func saveContainer(
        id: String,
        name: String,
        image: String,
        imageID: String,
        createdAt: Date,
        status: String,
        running: Bool,
        paused: Bool,
        restarting: Bool,
        pid: Int,
        exitCode: Int,
        startedAt: Date?,
        finishedAt: Date?,
        stoppedByUser: Bool,
        configJSON: String,
        hostConfigJSON: String
    ) throws {
        try db.run(containers.insert(or: .replace,
            self.id <- id,
            self.name <- name,
            self.image <- image,
            self.imageID <- imageID,
            self.createdAt <- createdAt.iso8601String,
            self.status <- status,
            self.running <- running,
            self.paused <- paused,
            self.restarting <- restarting,
            self.pid <- pid,
            self.exitCode <- exitCode,
            self.startedAt <- startedAt?.iso8601String,
            self.finishedAt <- finishedAt?.iso8601String,
            self.stoppedByUser <- stoppedByUser,
            self.configJSON <- configJSON,
            self.hostConfigJSON <- hostConfigJSON
        ))

        logger.debug("Container state saved", metadata: [
            "id": "\(id)",
            "name": "\(name)",
            "status": "\(status)"
        ])
    }

    /// Load all containers from database
    public func loadAllContainers() throws -> [(
        id: String,
        name: String,
        image: String,
        imageID: String,
        createdAt: Date,
        status: String,
        running: Bool,
        paused: Bool,
        restarting: Bool,
        pid: Int,
        exitCode: Int,
        startedAt: Date?,
        finishedAt: Date?,
        stoppedByUser: Bool,
        configJSON: String,
        hostConfigJSON: String
    )] {
        var result: [(
            id: String, name: String, image: String, imageID: String,
            createdAt: Date, status: String, running: Bool, paused: Bool,
            restarting: Bool, pid: Int, exitCode: Int, startedAt: Date?,
            finishedAt: Date?, stoppedByUser: Bool, configJSON: String,
            hostConfigJSON: String
        )] = []

        for row in try db.prepare(containers) {
            let createdDate = Date(iso8601String: row[createdAt]) ?? Date()
            let startedDate = row[startedAt].flatMap { Date(iso8601String: $0) }
            let finishedDate = row[finishedAt].flatMap { Date(iso8601String: $0) }

            result.append((
                id: row[id],
                name: row[name],
                image: row[image],
                imageID: row[imageID],
                createdAt: createdDate,
                status: row[status],
                running: row[running],
                paused: row[paused],
                restarting: row[restarting],
                pid: row[pid],
                exitCode: row[exitCode],
                startedAt: startedDate,
                finishedAt: finishedDate,
                stoppedByUser: row[stoppedByUser],
                configJSON: row[configJSON],
                hostConfigJSON: row[hostConfigJSON]
            ))
        }

        logger.info("Loaded containers from database", metadata: [
            "count": "\(result.count)"
        ])

        return result
    }

    /// Delete container from database
    public func deleteContainer(id: String) throws {
        let container = containers.filter(self.id == id)
        try db.run(container.delete())

        logger.debug("Container deleted from database", metadata: ["id": "\(id)"])
    }

    /// Get containers that need to be restarted based on restart policy
    public func getContainersToRestart() throws -> [(id: String, name: String, policy: String, exitCode: Int)] {
        var result: [(id: String, name: String, policy: String, exitCode: Int)] = []

        // Query containers that are exited and have a restart policy
        for row in try db.prepare(containers.filter(status == "exited")) {
            let hostConfig = row[hostConfigJSON]

            // Parse restart policy from JSON
            if let data = hostConfig.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let restartPolicy = json["restartPolicy"] as? [String: Any],
               let policyName = restartPolicy["name"] as? String {

                let shouldRestart: Bool
                switch policyName {
                case "always":
                    shouldRestart = true
                case "unless-stopped":
                    shouldRestart = !row[stoppedByUser]
                case "on-failure":
                    shouldRestart = row[exitCode] != 0
                default:
                    shouldRestart = false
                }

                if shouldRestart {
                    result.append((
                        id: row[id],
                        name: row[name],
                        policy: policyName,
                        exitCode: row[exitCode]
                    ))
                }
            }
        }

        logger.info("Found containers to restart", metadata: ["count": "\(result.count)"])
        return result
    }

    // MARK: - Network Operations

    /// Save network state to database
    public func saveNetwork(
        id: String,
        name: String,
        driver: String,
        scope: String,
        createdAt: Date,
        subnet: String,
        gateway: String,
        ipRange: String?,
        optionsJSON: String?,
        labelsJSON: String?,
        isDefault: Bool
    ) throws {
        try db.run(networks.insert(or: .replace,
            self.networkID <- id,
            self.networkName <- name,
            self.driver <- driver,
            self.scope <- scope,
            self.networkCreatedAt <- createdAt.iso8601String,
            self.subnet <- subnet,
            self.gateway <- gateway,
            self.ipRange <- ipRange,
            self.optionsJSON <- optionsJSON,
            self.labelsJSON <- labelsJSON,
            self.isDefault <- isDefault
        ))

        logger.debug("Network saved", metadata: [
            "id": "\(id)",
            "name": "\(name)",
            "driver": "\(driver)"
        ])
    }

    /// Load all networks from database
    public func loadAllNetworks() throws -> [(
        id: String,
        name: String,
        driver: String,
        scope: String,
        createdAt: Date,
        subnet: String,
        gateway: String,
        ipRange: String?,
        optionsJSON: String?,
        labelsJSON: String?,
        isDefault: Bool
    )] {
        var result: [(
            id: String, name: String, driver: String, scope: String,
            createdAt: Date, subnet: String, gateway: String,
            ipRange: String?, optionsJSON: String?, labelsJSON: String?,
            isDefault: Bool
        )] = []

        for row in try db.prepare(networks) {
            let createdDate = Date(iso8601String: row[networkCreatedAt]) ?? Date()

            result.append((
                id: row[networkID],
                name: row[networkName],
                driver: row[driver],
                scope: row[scope],
                createdAt: createdDate,
                subnet: row[subnet],
                gateway: row[gateway],
                ipRange: row[ipRange],
                optionsJSON: row[optionsJSON],
                labelsJSON: row[labelsJSON],
                isDefault: row[isDefault]
            ))
        }

        logger.info("Loaded networks from database", metadata: [
            "count": "\(result.count)"
        ])

        return result
    }

    /// Delete network from database
    public func deleteNetwork(id: String) throws {
        let network = networks.filter(self.networkID == id)
        try db.run(network.delete())

        logger.debug("Network deleted from database", metadata: ["id": "\(id)"])
    }

    // MARK: - Network Attachment Operations

    /// Save network attachment
    public func saveNetworkAttachment(
        containerID: String,
        networkID: String,
        ipAddress: String,
        macAddress: String,
        aliases: [String]
    ) throws {
        let aliasesData = try JSONEncoder().encode(aliases)
        let aliasesString = String(data: aliasesData, encoding: .utf8)

        try db.run(networkAttachments.insert(or: .replace,
            self.containerID <- containerID,
            self.attachedNetworkID <- networkID,
            self.ipAddress <- ipAddress,
            self.macAddress <- macAddress,
            self.aliasesJSON <- aliasesString,
            self.attachedAt <- Date().iso8601String
        ))

        logger.debug("Network attachment saved", metadata: [
            "container": "\(containerID)",
            "network": "\(networkID)"
        ])
    }

    /// Load network attachments for a container
    public func loadNetworkAttachments(containerID: String) throws -> [(
        networkID: String,
        ipAddress: String,
        macAddress: String,
        aliases: [String]
    )] {
        var result: [(networkID: String, ipAddress: String, macAddress: String, aliases: [String])] = []

        let query = networkAttachments.filter(self.containerID == containerID)
        for row in try db.prepare(query) {
            let aliases: [String]
            if let aliasesData = row[aliasesJSON]?.data(using: .utf8) {
                aliases = (try? JSONDecoder().decode([String].self, from: aliasesData)) ?? []
            } else {
                aliases = []
            }

            result.append((
                networkID: row[attachedNetworkID],
                ipAddress: row[ipAddress],
                macAddress: row[macAddress],
                aliases: aliases
            ))
        }

        return result
    }

    /// Delete network attachment
    public func deleteNetworkAttachment(containerID: String, networkID: String) throws {
        let attachment = networkAttachments
            .filter(self.containerID == containerID && self.attachedNetworkID == networkID)
        try db.run(attachment.delete())

        logger.debug("Network attachment deleted", metadata: [
            "container": "\(containerID)",
            "network": "\(networkID)"
        ])
    }

    // MARK: - Subnet Allocation Operations

    /// Get next available subnet byte for auto-allocation
    public func getNextSubnetByte() throws -> Int {
        guard let row = try db.pluck(subnetAllocation.filter(allocationID == 1)) else {
            // Initialize if not exists
            try db.run(subnetAllocation.insert(or: .replace,
                allocationID <- 1,
                nextSubnetByte <- 18
            ))
            return 18
        }

        return row[nextSubnetByte]
    }

    /// Update next available subnet byte
    public func updateNextSubnetByte(_ value: Int) throws {
        let allocation = subnetAllocation.filter(allocationID == 1)
        try db.run(allocation.update(nextSubnetByte <- value))

        logger.debug("Subnet allocation updated", metadata: ["nextSubnetByte": "\(value)"])
    }

    // MARK: - Transaction Support

    /// Execute operations in a transaction
    public func transaction<T>(_ block: () throws -> T) throws -> T {
        var result: T!
        try db.transaction {
            result = try block()
        }
        return result
    }
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
