import Foundation
import Logging
import SWCompression

/// Helper for extracting files from tar archives using SWCompression
///
/// Provides utilities for working with Docker build contexts (tar archives)
public struct TarExtractor {
    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    /// Extract a single file from a tar archive
    ///
    /// - Parameters:
    ///   - tarData: The tar archive data
    ///   - filePath: Path to the file within the archive (e.g., "Dockerfile" or "docker/Dockerfile")
    /// - Returns: The extracted file contents as a string
    /// - Throws: TarError if extraction fails
    public func extractFile(from tarData: Data, filePath: String) throws -> String {
        logger.debug("Extracting file from tar archive", metadata: [
            "filePath": "\(filePath)",
            "tarSize": "\(tarData.count) bytes"
        ])

        // Parse tar container
        let entries: [TarEntry]
        do {
            entries = try TarContainer.open(container: tarData)
        } catch {
            throw TarError.extractionFailed("Failed to parse tar archive: \(error)")
        }

        logger.debug("Tar archive contains \(entries.count) entries")

        // Find the requested file
        guard let entry = entries.first(where: { $0.info.name == filePath }) else {
            // Log all available files for debugging
            let availableFiles = entries.map { $0.info.name }.joined(separator: ", ")
            logger.debug("Available files in tar: \(availableFiles)")
            throw TarError.fileNotFound(filePath)
        }

        // Extract file data
        guard let data = entry.data else {
            throw TarError.readFailed("File has no data")
        }

        // Convert to string
        guard let contents = String(data: data, encoding: .utf8) else {
            throw TarError.readFailed("File is not valid UTF-8")
        }

        logger.debug("Successfully extracted file", metadata: [
            "filePath": "\(filePath)",
            "size": "\(contents.count) bytes"
        ])

        return contents
    }

    /// List all files in a tar archive
    ///
    /// - Parameter tarData: The tar archive data
    /// - Returns: Array of file paths in the archive
    /// - Throws: TarError if parsing fails
    public func listFiles(in tarData: Data) throws -> [String] {
        logger.debug("Listing files in tar archive", metadata: [
            "tarSize": "\(tarData.count) bytes"
        ])

        let entries: [TarEntry]
        do {
            entries = try TarContainer.open(container: tarData)
        } catch {
            throw TarError.extractionFailed("Failed to parse tar archive: \(error)")
        }

        let files = entries.map { $0.info.name }
        logger.debug("Tar archive contains \(files.count) entries")

        return files
    }

    /// Extract all files from tar archive to a dictionary
    ///
    /// - Parameter tarData: The tar archive data
    /// - Returns: Dictionary mapping file paths to their contents (as Data)
    /// - Throws: TarError if extraction fails
    public func extractAll(from tarData: Data) throws -> [String: Data] {
        logger.debug("Extracting all files from tar archive", metadata: [
            "tarSize": "\(tarData.count) bytes"
        ])

        let entries: [TarEntry]
        do {
            entries = try TarContainer.open(container: tarData)
        } catch {
            throw TarError.extractionFailed("Failed to parse tar archive: \(error)")
        }

        var files: [String: Data] = [:]
        for entry in entries {
            if let data = entry.data {
                files[entry.info.name] = data
            }
        }

        logger.debug("Extracted \(files.count) files from tar archive")

        return files
    }
}

// MARK: - Errors

public enum TarError: Error, CustomStringConvertible {
    case extractionFailed(String)
    case fileNotFound(String)
    case readFailed(String)

    public var description: String {
        switch self {
        case .extractionFailed(let message):
            return "Tar extraction failed: \(message)"
        case .fileNotFound(let path):
            return "File not found in tar archive: \(path)"
        case .readFailed(let message):
            return "Failed to read extracted file: \(message)"
        }
    }
}
