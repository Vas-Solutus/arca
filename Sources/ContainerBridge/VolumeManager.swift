import Foundation
import Logging
import ContainerizationEXT4
import SystemPackage

/// Manages Docker named volumes
/// Volumes are stored as EXT4-formatted block devices at ~/.arca/volumes/{name}/volume.img
/// Metadata is persisted in StateStore (SQLite)
public actor VolumeManager {
    private let logger: Logger
    private let volumesBasePath: String
    private let stateStore: StateStore

    // In-memory volume tracking: [name: VolumeMetadata]
    private var volumes: [String: VolumeMetadata] = [:]

    /// Volume metadata for in-memory tracking
    public struct VolumeMetadata: Codable, Sendable {
        public let name: String
        public let driver: String
        public let format: String  // Filesystem format: "ext4" for block devices
        public let mountpoint: String  // Path to volume.img file (block device)
        public let createdAt: Date
        public let labels: [String: String]
        public let options: [String: String]?

        public init(
            name: String,
            driver: String = "local",
            format: String = "ext4",
            mountpoint: String,
            createdAt: Date = Date(),
            labels: [String: String] = [:],
            options: [String: String]? = nil
        ) {
            self.name = name
            self.driver = driver
            self.format = format
            self.mountpoint = mountpoint
            self.createdAt = createdAt
            self.labels = labels
            self.options = options
        }
    }

    /// Initialize VolumeManager
    /// - Parameters:
    ///   - volumesBasePath: Base directory for storing volumes (default: ~/.arca/volumes)
    ///   - stateStore: StateStore for persistence
    ///   - logger: Logger instance
    public init(volumesBasePath: String? = nil, stateStore: StateStore, logger: Logger) {
        self.logger = logger
        self.stateStore = stateStore

        // Use provided path or default to ~/.arca/volumes
        if let customPath = volumesBasePath {
            self.volumesBasePath = NSString(string: customPath).expandingTildeInPath
        } else {
            self.volumesBasePath = NSString(string: "~/.arca/volumes").expandingTildeInPath
        }
    }

    /// Initialize the volume manager
    /// Creates volumes directory and loads existing volumes from database
    public func initialize() async throws {
        logger.info("Initializing VolumeManager", metadata: [
            "volumesBasePath": "\(volumesBasePath)"
        ])

        // Create volumes directory if it doesn't exist
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: volumesBasePath) {
            try fileManager.createDirectory(
                atPath: volumesBasePath,
                withIntermediateDirectories: true,
                attributes: nil
            )
            logger.debug("Created volumes directory", metadata: ["path": "\(volumesBasePath)"])
        }

        // Load existing volumes from database
        try await loadVolumesFromDatabase()

        logger.info("VolumeManager initialized", metadata: [
            "volumeCount": "\(volumes.count)"
        ])
    }

    /// Create a new volume
    /// - Parameters:
    ///   - name: Volume name (auto-generated if nil)
    ///   - driver: Volume driver (only "local" supported)
    ///   - driverOpts: Driver options (ignored for local driver)
    ///   - labels: User-defined labels
    /// - Returns: Created volume metadata
    /// - Throws: VolumeError if creation fails
    public func createVolume(
        name: String?,
        driver: String?,
        driverOpts: [String: String]?,
        labels: [String: String]?
    ) async throws -> VolumeMetadata {
        // Validate driver (only "local" supported)
        let volumeDriver = driver ?? "local"
        guard volumeDriver == "local" else {
            logger.error("Unsupported volume driver", metadata: ["driver": "\(volumeDriver)"])
            throw VolumeError.unsupportedDriver(volumeDriver)
        }

        // Generate name if not provided
        let volumeName = name ?? generateVolumeName()

        // Check if volume already exists
        if volumes[volumeName] != nil {
            logger.error("Volume already exists", metadata: ["name": "\(volumeName)"])
            throw VolumeError.alreadyExists(volumeName)
        }

        // Create volume directory and EXT4 block device
        let volumeDir = "\(volumesBasePath)/\(volumeName)"
        let blockImagePath = "\(volumeDir)/volume.img"
        let fileManager = FileManager.default

        // Parse size from driverOpts (default 512GB)
        let sizeInBytes: UInt64
        if let sizeStr = driverOpts?["size"] {
            sizeInBytes = try parseSizeString(sizeStr)
        } else {
            sizeInBytes = 512 * 1024 * 1024 * 1024  // 512GB default (sparse)
        }

        do {
            // Create volume directory
            try fileManager.createDirectory(
                atPath: volumeDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            logger.debug("Created volume directory", metadata: [
                "name": "\(volumeName)",
                "path": "\(volumeDir)"
            ])

            // Create and format EXT4 block device
            logger.info("Creating EXT4 block device", metadata: [
                "name": "\(volumeName)",
                "path": "\(blockImagePath)",
                "size": "\(sizeInBytes) bytes"
            ])

            let formatter = try EXT4.Formatter(
                FilePath(blockImagePath),
                blockSize: 4096,
                minDiskSize: sizeInBytes
            )
            try formatter.close()

            logger.info("EXT4 block device created", metadata: [
                "name": "\(volumeName)",
                "path": "\(blockImagePath)"
            ])
        } catch {
            // Clean up on failure
            try? fileManager.removeItem(atPath: volumeDir)
            logger.error("Failed to create volume block device", metadata: [
                "name": "\(volumeName)",
                "error": "\(error)"
            ])
            throw VolumeError.creationFailed(volumeName, error.localizedDescription)
        }

        // Create metadata (mountpoint is the block device file, not directory)
        let createdAt = Date()
        let metadata = VolumeMetadata(
            name: volumeName,
            driver: volumeDriver,
            format: "ext4",
            mountpoint: blockImagePath,  // Path to volume.img file
            createdAt: createdAt,
            labels: labels ?? [:],
            options: driverOpts
        )

        // Store in memory
        volumes[volumeName] = metadata

        // Persist to database
        try await saveVolumeToDatabase(metadata: metadata)

        logger.info("Volume created", metadata: [
            "name": "\(volumeName)",
            "driver": "\(volumeDriver)",
            "mountpoint": "\(blockImagePath)"
        ])

        return metadata
    }

    /// List volumes with optional filters
    /// - Parameter filters: Filter criteria (label, name, dangling)
    /// - Returns: Array of volume metadata
    public func listVolumes(filters: [String: [String]]? = nil) async throws -> [VolumeMetadata] {
        var result = Array(volumes.values)

        // Apply filters
        if let filters = filters {
            // Filter by name
            if let names = filters["name"], !names.isEmpty {
                result = result.filter { volume in
                    names.contains { volume.name.contains($0) }
                }
            }

            // Filter by label
            if let labelFilters = filters["label"], !labelFilters.isEmpty {
                result = result.filter { volume in
                    labelFilters.contains { labelFilter in
                        if labelFilter.contains("=") {
                            let parts = labelFilter.split(separator: "=", maxSplits: 1)
                            let key = String(parts[0])
                            let value = parts.count > 1 ? String(parts[1]) : ""
                            return volume.labels[key] == value
                        } else {
                            return volume.labels[labelFilter] != nil
                        }
                    }
                }
            }

            // Filter by dangling (volumes not referenced by any container)
            if let danglingFilters = filters["dangling"], !danglingFilters.isEmpty {
                let danglingValue = danglingFilters.first ?? "false"
                let shouldBeDangling = (danglingValue.lowercased() == "true" || danglingValue == "1")

                var filteredResult: [VolumeMetadata] = []
                for volume in result {
                    let users = try await stateStore.getVolumeUsers(volumeName: volume.name)
                    let isDangling = users.isEmpty
                    if isDangling == shouldBeDangling {
                        filteredResult.append(volume)
                    }
                }
                result = filteredResult
            }
        }

        return result
    }

    /// Inspect a volume by name
    /// - Parameter name: Volume name
    /// - Returns: Volume metadata
    /// - Throws: VolumeError.notFound if volume doesn't exist
    public func inspectVolume(name: String) throws -> VolumeMetadata {
        guard let metadata = volumes[name] else {
            logger.error("Volume not found", metadata: ["name": "\(name)"])
            throw VolumeError.notFound(name)
        }
        return metadata
    }

    /// Delete a volume
    /// - Parameters:
    ///   - name: Volume name
    ///   - force: Force removal even if in use (not yet implemented)
    /// - Throws: VolumeError if deletion fails
    public func deleteVolume(name: String, force: Bool = false) async throws {
        guard let metadata = volumes[name] else {
            logger.error("Volume not found", metadata: ["name": "\(name)"])
            throw VolumeError.notFound(name)
        }

        // Check if volume is in use by any container (unless force is true)
        if !force {
            let users = try await stateStore.getVolumeUsers(volumeName: name)
            if !users.isEmpty {
                logger.error("Volume is in use by containers", metadata: [
                    "name": "\(name)",
                    "users": "\(users.joined(separator: ", "))"
                ])
                throw VolumeError.inUse(name, users)
            }
        }

        // Delete volume directory (containing volume.img)
        // mountpoint is path to volume.img, need to delete parent directory
        let volumeDir = NSString(string: metadata.mountpoint).deletingLastPathComponent
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(atPath: volumeDir)
            logger.debug("Deleted volume directory", metadata: [
                "name": "\(name)",
                "path": "\(volumeDir)"
            ])
        } catch {
            logger.error("Failed to delete volume directory", metadata: [
                "name": "\(name)",
                "path": "\(volumeDir)",
                "error": "\(error)"
            ])
            throw VolumeError.deletionFailed(name, error.localizedDescription)
        }

        // Remove from memory
        volumes.removeValue(forKey: name)

        // Delete from database
        try await stateStore.deleteVolume(name: name)

        logger.info("Volume deleted", metadata: ["name": "\(name)"])
    }

    /// Prune unused volumes
    /// - Parameter filters: Filter criteria for pruning
    /// - Returns: Tuple of (deleted volume names, space reclaimed in bytes)
    public func pruneVolumes(filters: [String: [String]]? = nil) async throws -> (volumesDeleted: [String], spaceReclaimed: Int64) {
        var deletedVolumes: [String] = []
        var spaceReclaimed: Int64 = 0

        // Get all volumes (dangling filter should be applied by caller)
        let allVolumes = try await listVolumes(filters: filters)

        // Filter out volumes that are in use by containers
        var volumesToPrune: [VolumeMetadata] = []
        for volume in allVolumes {
            let users = try await stateStore.getVolumeUsers(volumeName: volume.name)
            if users.isEmpty {
                volumesToPrune.append(volume)
            }
        }

        for volume in volumesToPrune {
            do {
                // Calculate space used by volume
                let volumeSize = calculateVolumeSize(path: volume.mountpoint)

                // Delete volume
                try await deleteVolume(name: volume.name, force: false)

                deletedVolumes.append(volume.name)
                spaceReclaimed += volumeSize

                logger.debug("Pruned volume", metadata: [
                    "name": "\(volume.name)",
                    "size": "\(volumeSize)"
                ])
            } catch {
                logger.warning("Failed to prune volume", metadata: [
                    "name": "\(volume.name)",
                    "error": "\(error)"
                ])
                // Continue pruning other volumes
            }
        }

        logger.info("Volume prune complete", metadata: [
            "deletedCount": "\(deletedVolumes.count)",
            "spaceReclaimed": "\(spaceReclaimed)"
        ])

        return (deletedVolumes, spaceReclaimed)
    }

    // MARK: - Private Helpers

    /// Generate a random volume name
    private func generateVolumeName() -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let random = UUID().uuidString.prefix(12).lowercased()
        return "\(timestamp)_\(random)"
    }

    /// Calculate size of volume directory in bytes
    private func calculateVolumeSize(path: String) -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0

        if let enumerator = fileManager.enumerator(atPath: path) {
            for case let file as String in enumerator {
                let filePath = "\(path)/\(file)"
                if let attrs = try? fileManager.attributesOfItem(atPath: filePath),
                   let fileSize = attrs[.size] as? Int64 {
                    totalSize += fileSize
                }
            }
        }

        return totalSize
    }

    /// Load volumes from database
    private func loadVolumesFromDatabase() async throws {
        let volumeRows = try await stateStore.loadAllVolumes()

        for row in volumeRows {
            // Decode labels JSON
            var labels: [String: String] = [:]
            if let labelsJSON = row.labelsJSON,
               let data = labelsJSON.data(using: .utf8) {
                labels = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            }

            // Decode options JSON
            var options: [String: String]? = nil
            if let optionsJSON = row.optionsJSON,
               let data = optionsJSON.data(using: .utf8) {
                options = try? JSONDecoder().decode([String: String].self, from: data)
            }

            let metadata = VolumeMetadata(
                name: row.name,
                driver: row.driver,
                format: row.format,
                mountpoint: row.mountpoint,
                createdAt: row.createdAt,
                labels: labels,
                options: options
            )

            volumes[row.name] = metadata
        }

        logger.debug("Loaded volumes from database", metadata: [
            "count": "\(volumeRows.count)"
        ])
    }

    /// Save volume to database
    private func saveVolumeToDatabase(metadata: VolumeMetadata) async throws {
        // Encode labels to JSON
        let labelsData = try JSONEncoder().encode(metadata.labels)
        let labelsJSON = String(data: labelsData, encoding: .utf8)

        // Encode options to JSON
        var optionsJSON: String? = nil
        if let options = metadata.options {
            let optionsData = try JSONEncoder().encode(options)
            optionsJSON = String(data: optionsData, encoding: .utf8)
        }

        try await stateStore.saveVolume(
            name: metadata.name,
            driver: metadata.driver,
            format: metadata.format,
            mountpoint: metadata.mountpoint,
            createdAt: metadata.createdAt,
            labelsJSON: labelsJSON,
            optionsJSON: optionsJSON
        )

        logger.debug("Volume saved to database", metadata: [
            "name": "\(metadata.name)"
        ])
    }

    /// Parse size string (e.g., "10G", "500M", "1T") to bytes
    private func parseSizeString(_ sizeStr: String) throws -> UInt64 {
        let trimmed = sizeStr.trimmingCharacters(in: .whitespaces).uppercased()
        let multipliers: [Character: UInt64] = [
            "K": 1024,
            "M": 1024 * 1024,
            "G": 1024 * 1024 * 1024,
            "T": 1024 * 1024 * 1024 * 1024
        ]

        guard let lastChar = trimmed.last else {
            throw VolumeError.invalidSize(sizeStr)
        }

        if let multiplier = multipliers[lastChar] {
            // Has unit suffix (e.g., "10G")
            let numericPart = String(trimmed.dropLast())
            guard let value = UInt64(numericPart) else {
                throw VolumeError.invalidSize(sizeStr)
            }
            return value * multiplier
        } else {
            // No suffix, assume bytes
            guard let value = UInt64(trimmed) else {
                throw VolumeError.invalidSize(sizeStr)
            }
            return value
        }
    }
}

// MARK: - VolumeError

public enum VolumeError: Error, CustomStringConvertible {
    case unsupportedDriver(String)
    case alreadyExists(String)
    case notFound(String)
    case creationFailed(String, String)
    case deletionFailed(String, String)
    case inUse(String, [String])  // volume name, container IDs
    case metadataLoadFailed(String)
    case metadataSaveFailed(String)
    case invalidSize(String)  // invalid size string

    public var description: String {
        switch self {
        case .unsupportedDriver(let driver):
            return "Unsupported volume driver: \(driver). Only 'local' driver is supported."
        case .alreadyExists(let name):
            return "Volume '\(name)' already exists"
        case .notFound(let name):
            return "Volume '\(name)' not found"
        case .creationFailed(let name, let reason):
            return "Failed to create volume '\(name)': \(reason)"
        case .deletionFailed(let name, let reason):
            return "Failed to delete volume '\(name)': \(reason)"
        case .inUse(let name, let containers):
            return "Volume '\(name)' is in use by containers: \(containers.joined(separator: ", "))"
        case .metadataLoadFailed(let reason):
            return "Failed to load volume metadata: \(reason)"
        case .metadataSaveFailed(let reason):
            return "Failed to save volume metadata: \(reason)"
        case .invalidSize(let sizeStr):
            return "Invalid size string: '\(sizeStr)'. Use format like '10G', '500M', or '1T'."
        }
    }
}
