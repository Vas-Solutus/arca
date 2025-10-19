import Foundation
import Logging
import ContainerizationExtras

/// Formats Apple Containerization ProgressEvents into Docker-compatible JSON progress messages
///
/// Shows honest aggregate progress instead of faking per-layer progress.
/// Apple's API only provides aggregate statistics without per-blob identification.
public actor DockerProgressFormatter {
    private let logger: Logger
    private let imageReference: String
    private let manifestDigest: String
    private let layerDigests: [String]

    // Aggregate progress tracking
    private var totalDownloadSize: Int64 = 0  // Total bytes to download (all blobs)
    private var downloadedBytes: Int64 = 0     // Bytes downloaded so far
    private var totalItems: Int = 0            // Total blobs to download
    private var completedItems: Int = 0        // Blobs completed
    private var lastCompletedItems: Int = 0    // Track last completed count to detect new completions

    // Throttling
    private var lastProgressUpdate: Date = Date()

    public init(logger: Logger, imageReference: String, layerDigests: [String], layerSizes: [Int64], manifestDigest: String) {
        self.logger = logger
        self.imageReference = imageReference
        self.manifestDigest = manifestDigest
        self.layerDigests = layerDigests

        logger.debug("Initialized aggregate progress formatter", metadata: [
            "layer_count": "\(layerDigests.count)",
            "total_layer_size": "\(layerSizes.reduce(0, +))"
        ])
    }

    /// Process progress events and return Docker-formatted JSON lines
    public func formatProgress(events: [ProgressEvent]) -> [String] {
        var output: [String] = []

        for event in events {
            switch event.event {
            case "add-total-size":
                if let size = event.value as? Int64 {
                    totalDownloadSize += size
                }

            case "add-total-items":
                if let count = event.value as? Int {
                    totalItems += count
                }

            case "add-size":
                if let size = event.value as? Int64 {
                    downloadedBytes += size

                    // Throttle progress updates to avoid spam (every 100ms or when complete)
                    let now = Date()
                    if now.timeIntervalSince(lastProgressUpdate) >= 0.1 || downloadedBytes >= totalDownloadSize {
                        lastProgressUpdate = now
                        output.append(formatDownloadProgress())
                    }
                }

            case "add-items":
                if let count = event.value as? Int {
                    completedItems += count

                    // Only emit completion messages for first two items (manifest and config)
                    // Items 2+ all use the same bulk download ID, so we'll mark that complete at the end
                    while lastCompletedItems < min(completedItems, 2) {
                        let itemIndex = lastCompletedItems
                        output.append(formatItemCompletion(itemIndex: itemIndex))
                        lastCompletedItems += 1
                    }
                }

            case "container-setup-start":
                if let containerID = event.value as? String {
                    output.append(formatContainerStatus(containerID: containerID, status: "Preparing"))
                }

            case "container-setup-complete":
                // Container setup is complete - no need for a progress message
                // The final container ID response will be sent after this
                break

            default:
                logger.debug("Unknown progress event", metadata: ["event": "\(event.event)"])
            }
        }

        return output
    }

    /// Get digest ID for a specific item index
    /// Uses real digests from the image manifest
    private func getIDForItem(_ itemIndex: Int) -> String {
        // First blob (manifest): use manifest digest
        if itemIndex == 0 {
            return shortDigest(manifestDigest)
        }
        // Second blob (config): use first layer digest
        else if itemIndex == 1, !layerDigests.isEmpty {
            return shortDigest(layerDigests[0])
        }
        // All subsequent blobs (bulk layers): use second layer digest
        else if layerDigests.count > 1 {
            return shortDigest(layerDigests[1])
        }
        // Fallback: use manifest digest
        else {
            return shortDigest(manifestDigest)
        }
    }

    /// Get appropriate digest ID based on completed items
    /// Uses real digests from the image manifest for initial small blobs,
    /// then consolidates to image reference for bulk layer downloads
    private func getProgressID() -> String {
        return getIDForItem(completedItems)
    }

    /// Convert a digest to short form (12 chars, no sha256: prefix)
    private func shortDigest(_ digest: String) -> String {
        let stripped = digest.replacingOccurrences(of: "sha256:", with: "")
        return String(stripped.prefix(12))
    }

    /// Format completion message for a specific item
    private func formatItemCompletion(itemIndex: Int) -> String {
        var json: [String: Any] = [
            "id": getIDForItem(itemIndex),
            "status": "Download complete",
            "progressDetail": [String: Any]()  // Empty progressDetail clears the progress bar
        ]

        return encodeJSON(json)
    }

    /// Format aggregate download progress
    private func formatDownloadProgress() -> String {
        var json: [String: Any] = [
            "id": getProgressID(),
            "status": "Downloading"
        ]

        json["progressDetail"] = [
            "current": downloadedBytes,
            "total": totalDownloadSize
        ]

        // Add progress bar
        if totalDownloadSize > 0 {
            json["progress"] = formatProgressBar(current: downloadedBytes, total: totalDownloadSize)
        }

        return encodeJSON(json)
    }

    /// Format final completion message for the bulk download line
    /// This ensures the final bulk download line is marked complete
    public func formatCompletion() -> String {
        // Mark the bulk download item as complete (second layer digest)
        let completionID = layerDigests.count > 1 ? shortDigest(layerDigests[1]) : shortDigest(manifestDigest)

        var json: [String: Any] = [
            "id": completionID,
            "status": "Download complete",
            "progressDetail": [String: Any]()  // Empty progressDetail clears the progress bar
        ]

        return encodeJSON(json)
    }

    /// Format container status message (for setup/preparation phases)
    private func formatContainerStatus(containerID: String, status: String) -> String {
        let json: [String: Any] = [
            "id": shortDigest(containerID),
            "status": status,
            "progressDetail": [String: Any]()
        ]

        return encodeJSON(json)
    }

    /// Encode dictionary to JSON string
    private func encodeJSON(_ json: [String: Any]) -> String {
        if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: []),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        return ""
    }

    /// Format progress bar like Docker: "[========>          ]  1.234MB/5.678MB"
    private func formatProgressBar(current: Int64, total: Int64) -> String {
        let percentage = total > 0 ? Double(current) / Double(total) : 0.0
        let barWidth = 20
        let filled = Int(percentage * Double(barWidth))

        var bar = "["
        for i in 0..<barWidth {
            if i < filled - 1 {
                bar += "="
            } else if i == filled - 1 {
                bar += ">"
            } else {
                bar += " "
            }
        }
        bar += "]"

        let currentStr = formatBytes(current)
        let totalStr = formatBytes(total)

        return "\(bar)  \(currentStr)/\(totalStr)"
    }

    /// Format bytes into human-readable string (e.g., "1.23MB")
    private func formatBytes(_ bytes: Int64) -> String {
        let kb: Double = 1024
        let mb = kb * 1024
        let gb = mb * 1024

        let value = Double(bytes)

        if value >= gb {
            return String(format: "%.2fGB", value / gb)
        } else if value >= mb {
            return String(format: "%.2fMB", value / mb)
        } else if value >= kb {
            return String(format: "%.2fkB", value / kb)
        } else {
            return "\(bytes)B"
        }
    }
}
