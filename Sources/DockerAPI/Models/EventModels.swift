import Foundation

/// Event message representing a Docker event
/// Reference: Docker Engine API v1.51 - EventMessage definition
public struct EventMessage: Codable, Sendable {
    public let type: String           // "container", "image", "network", "volume", etc.
    public let action: String         // "create", "start", "stop", "die", "destroy", etc.
    public let actor: EventActor
    public let scope: String          // "local" or "swarm"
    public let time: Int64            // Unix timestamp in seconds
    public let timeNano: Int64        // Unix timestamp in nanoseconds

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case action = "Action"
        case actor = "Actor"
        case scope
        case time
        case timeNano
    }

    public init(
        type: String,
        action: String,
        actor: EventActor,
        scope: String = "local",
        time: Int64,
        timeNano: Int64
    ) {
        self.type = type
        self.action = action
        self.actor = actor
        self.scope = scope
        self.time = time
        self.timeNano = timeNano
    }

    /// Create event from current timestamp
    public static func now(
        type: String,
        action: String,
        actor: EventActor,
        scope: String = "local"
    ) -> EventMessage {
        let now = Date()
        let time = Int64(now.timeIntervalSince1970)
        let timeNano = Int64(now.timeIntervalSince1970 * 1_000_000_000)

        return EventMessage(
            type: type,
            action: action,
            actor: actor,
            scope: scope,
            time: time,
            timeNano: timeNano
        )
    }
}

/// Actor in an event (container, image, network, etc.)
/// Reference: Docker Engine API v1.51 - EventActor definition
public struct EventActor: Codable, Sendable {
    public let id: String
    public let attributes: [String: String]

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case attributes = "Attributes"
    }

    public init(id: String, attributes: [String: String] = [:]) {
        self.id = id
        self.attributes = attributes
    }
}

/// Event filters for /events endpoint
public struct EventFilters: Sendable {
    public let container: [String]?
    public let image: [String]?
    public let network: [String]?
    public let volume: [String]?
    public let event: [String]?      // Action filter
    public let type: [String]?       // Type filter (container, image, network, etc.)
    public let label: [String]?

    public init(
        container: [String]? = nil,
        image: [String]? = nil,
        network: [String]? = nil,
        volume: [String]? = nil,
        event: [String]? = nil,
        type: [String]? = nil,
        label: [String]? = nil
    ) {
        self.container = container
        self.image = image
        self.network = network
        self.volume = volume
        self.event = event
        self.type = type
        self.label = label
    }

    /// Parse filters from JSON string (Docker API format)
    public static func parse(_ jsonString: String?) -> EventFilters? {
        guard let jsonString = jsonString,
              let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else {
            return nil
        }

        return EventFilters(
            container: dict["container"],
            image: dict["image"],
            network: dict["network"],
            volume: dict["volume"],
            event: dict["event"],
            type: dict["type"],
            label: dict["label"]
        )
    }

    /// Check if an event matches these filters
    public func matches(_ event: EventMessage) -> Bool {
        // Type filter
        if let types = type, !types.isEmpty {
            if !types.contains(event.type) {
                return false
            }
        }

        // Action filter
        if let actions = self.event, !actions.isEmpty {
            if !actions.contains(event.action) {
                return false
            }
        }

        // Container filter
        if let containers = container, !containers.isEmpty {
            if event.type != "container" {
                return false
            }
            let matches = containers.contains { filter in
                // Match by ID (prefix match) or name
                event.actor.id.hasPrefix(filter) ||
                event.actor.attributes["name"] == filter
            }
            if !matches {
                return false
            }
        }

        // Image filter
        if let images = image, !images.isEmpty {
            if event.type != "image" {
                return false
            }
            let matches = images.contains { filter in
                event.actor.id.hasPrefix(filter) ||
                event.actor.attributes["name"] == filter
            }
            if !matches {
                return false
            }
        }

        // Network filter
        if let networks = network, !networks.isEmpty {
            if event.type != "network" {
                return false
            }
            let matches = networks.contains { filter in
                event.actor.id.hasPrefix(filter) ||
                event.actor.attributes["name"] == filter
            }
            if !matches {
                return false
            }
        }

        // Volume filter
        if let volumes = volume, !volumes.isEmpty {
            if event.type != "volume" {
                return false
            }
            let matches = volumes.contains { filter in
                event.actor.id.hasPrefix(filter) ||
                event.actor.attributes["name"] == filter
            }
            if !matches {
                return false
            }
        }

        // Label filter
        if let labels = label, !labels.isEmpty {
            let matches = labels.contains { filter in
                // Label filter format: "key" or "key=value"
                if filter.contains("=") {
                    // Match exact key=value
                    let parts = filter.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { return false }
                    let key = String(parts[0])
                    let value = String(parts[1])
                    return event.actor.attributes[key] == value
                } else {
                    // Match key existence
                    return event.actor.attributes[filter] != nil
                }
            }
            if !matches {
                return false
            }
        }

        return true
    }
}
