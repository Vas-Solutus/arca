import Foundation
import Logging
import ContainerBridge

/// Manages Docker events - broadcasts to subscribers and stores recent history
/// Thread-safe via actor isolation
public actor EventManager: EventEmitter {
    private let logger: Logger

    /// Recent events buffer (for `since` parameter support)
    /// Stores last 1000 events
    private var recentEvents: [EventMessage] = []
    private let maxRecentEvents = 1000

    /// Active event subscribers
    private var subscribers: [UUID: EventSubscriber] = [:]

    /// Event subscriber
    private struct EventSubscriber {
        let id: UUID
        let continuation: AsyncStream<EventMessage>.Continuation
        let filters: EventFilters?
        let until: Date?

        func matches(_ event: EventMessage) -> Bool {
            // Check until timestamp
            if let until = until {
                let eventTime = Date(timeIntervalSince1970: TimeInterval(event.time))
                if eventTime > until {
                    return false
                }
            }

            // Check filters
            if let filters = filters {
                return filters.matches(event)
            }

            return true
        }
    }

    public init(logger: Logger) {
        self.logger = logger
    }

    /// Emit an event to all subscribers and store in recent history
    public func emit(_ event: EventMessage) {
        // Add to recent events buffer
        recentEvents.append(event)
        if recentEvents.count > maxRecentEvents {
            recentEvents.removeFirst(recentEvents.count - maxRecentEvents)
        }

        logger.debug("Event emitted", metadata: [
            "type": "\(event.type)",
            "action": "\(event.action)",
            "id": "\(event.actor.id.prefix(12))",
            "subscribers": "\(subscribers.count)"
        ])

        // Broadcast to subscribers
        var completedSubscribers: [UUID] = []
        for (id, subscriber) in subscribers {
            // Check if event matches subscriber's filters
            guard subscriber.matches(event) else {
                continue
            }

            // Check if we've reached the until timestamp
            if let until = subscriber.until {
                let eventTime = Date(timeIntervalSince1970: TimeInterval(event.time))
                if eventTime >= until {
                    // Stop streaming - reached until timestamp
                    subscriber.continuation.finish()
                    completedSubscribers.append(id)
                    continue
                }
            }

            // Send event to subscriber
            subscriber.continuation.yield(event)
        }

        // Remove completed subscribers
        for id in completedSubscribers {
            subscribers.removeValue(forKey: id)
        }
    }

    /// Subscribe to events
    /// - Parameters:
    ///   - since: Only return events since this timestamp
    ///   - until: Stop streaming after this timestamp (nil = stream indefinitely)
    ///   - filters: Event filters
    /// - Returns: AsyncStream of events
    public func subscribe(
        since: Date?,
        until: Date?,
        filters: EventFilters?
    ) -> AsyncStream<EventMessage> {
        let id = UUID()

        return AsyncStream { continuation in
            // Send historical events if `since` is specified
            if let since = since {
                let sinceTimestamp = Int64(since.timeIntervalSince1970)
                for event in recentEvents {
                    if event.time >= sinceTimestamp {
                        // Check filters
                        if let filters = filters, !filters.matches(event) {
                            continue
                        }
                        continuation.yield(event)
                    }
                }
            }

            // Check if we should stop immediately (until in the past)
            if let until = until, until < Date() {
                continuation.finish()
                return
            }

            // Register subscriber for future events
            let subscriber = EventSubscriber(
                id: id,
                continuation: continuation,
                filters: filters,
                until: until
            )

            Task { [weak self] in
                await self?.addSubscriber(id: id, subscriber: subscriber)
            }

            continuation.onTermination = { _ in
                Task { [weak self] in
                    await self?.removeSubscriber(id: id)
                }
            }
        }
    }

    private func addSubscriber(id: UUID, subscriber: EventSubscriber) {
        subscribers[id] = subscriber
        logger.debug("Event subscriber added", metadata: [
            "id": "\(id)",
            "total_subscribers": "\(subscribers.count)"
        ])
    }

    private func removeSubscriber(id: UUID) {
        subscribers.removeValue(forKey: id)
        logger.debug("Event subscriber removed", metadata: [
            "id": "\(id)",
            "total_subscribers": "\(subscribers.count)"
        ])
    }

    /// Emit a container event
    public func emitContainerEvent(
        action: String,
        containerID: String,
        attributes: [String: String]
    ) {
        let actor = EventActor(id: containerID, attributes: attributes)
        let event = EventMessage.now(type: "container", action: action, actor: actor)
        emit(event)
    }

    /// Emit an image event
    public func emitImageEvent(
        action: String,
        imageID: String,
        attributes: [String: String]
    ) {
        let actor = EventActor(id: imageID, attributes: attributes)
        let event = EventMessage.now(type: "image", action: action, actor: actor)
        emit(event)
    }

    /// Emit a network event
    public func emitNetworkEvent(
        action: String,
        networkID: String,
        attributes: [String: String]
    ) {
        let actor = EventActor(id: networkID, attributes: attributes)
        let event = EventMessage.now(type: "network", action: action, actor: actor)
        emit(event)
    }

    /// Emit a volume event
    public func emitVolumeEvent(
        action: String,
        volumeName: String,
        attributes: [String: String]
    ) {
        let actor = EventActor(id: volumeName, attributes: attributes)
        let event = EventMessage.now(type: "volume", action: action, actor: actor)
        emit(event)
    }
}
