import Foundation

/// Handlers for Docker Engine API events endpoints
/// Reference: Documentation/DOCKER_ENGINE_API_SPEC.md - /events endpoint
public struct EventHandlers: Sendable {
    private let eventManager: EventManager

    public init(eventManager: EventManager) {
        self.eventManager = eventManager
    }

    /// Handle GET /events
    /// Streams real-time events from the daemon
    /// - Parameters:
    ///   - since: Show events created since this timestamp (Unix timestamp or ISO8601)
    ///   - until: Show events created until this timestamp (Unix timestamp or ISO8601)
    ///   - filters: JSON-encoded filters
    /// - Returns: AsyncStream of EventMessage (newline-delimited JSON)
    public func handleEvents(
        since: String?,
        until: String?,
        filters: String?
    ) async -> AsyncStream<EventMessage> {
        // Parse since timestamp
        let sinceDate: Date? = if let since = since {
            parseTimestamp(since)
        } else {
            nil
        }

        // Parse until timestamp
        let untilDate: Date? = if let until = until {
            parseTimestamp(until)
        } else {
            nil
        }

        // Parse filters
        let eventFilters = EventFilters.parse(filters)

        // Subscribe to events
        return await eventManager.subscribe(
            since: sinceDate,
            until: untilDate,
            filters: eventFilters
        )
    }

    /// Parse timestamp from string (Unix timestamp or ISO8601)
    private func parseTimestamp(_ str: String) -> Date? {
        // Try Unix timestamp first
        if let timestamp = Int64(str) {
            return Date(timeIntervalSince1970: TimeInterval(timestamp))
        }

        // Try ISO8601
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: str) {
            return date
        }

        // Try with fractional seconds
        formatter.formatOptions.insert(.withFractionalSeconds)
        if let date = formatter.date(from: str) {
            return date
        }

        return nil
    }
}
