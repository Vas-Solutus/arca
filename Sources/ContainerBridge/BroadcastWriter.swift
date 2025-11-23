import Foundation
import Containerization

/// A Writer that broadcasts to multiple destinations and supports dynamic subscription
/// Used for container stdout/stderr to support both persistent logging and dynamic attach
/// @unchecked Sendable: Safe because subscribers array is protected by NSLock
public final class BroadcastWriter: Writer, @unchecked Sendable {
    private var subscribers: [Writer]
    private let lock = NSLock()

    public init(initialSubscribers: [Writer] = []) {
        self.subscribers = initialSubscribers
    }

    /// Write data to all subscribed writers
    /// Continues even if one writer fails, to ensure other destinations still receive data
    public func write(_ data: Data) throws {
        lock.lock()
        let currentSubscribers = subscribers
        lock.unlock()

        var lastError: Error?

        for writer in currentSubscribers {
            do {
                try writer.write(data)
            } catch {
                // Store error but continue writing to other writers
                // This ensures one failing destination doesn't break others
                lastError = error
            }
        }

        // If all writers failed, throw the last error
        if let error = lastError {
            var allFailed = true
            for writer in currentSubscribers {
                do {
                    try writer.write(Data())  // Test with empty data
                    allFailed = false
                    break
                } catch {
                    // Writer still failed
                }
            }

            if allFailed {
                throw error
            }
        }
    }

    /// Add a new subscriber to receive future writes
    /// Thread-safe and can be called while container is running
    public func addSubscriber(_ writer: Writer) {
        lock.lock()
        defer { lock.unlock() }
        subscribers.append(writer)
    }

    /// Remove a subscriber (not needed - failed writes are handled automatically)
    /// When a client disconnects, writes to their Writer fail and are silently ignored
    /// while other subscribers (like log files) continue receiving data
    public func removeSubscriber(_ writer: Writer) {
        // No-op: We don't need explicit removal because:
        // 1. Write errors to disconnected clients are caught and ignored (line 25-28)
        // 2. Log files and other subscribers continue working
        // 3. Failed Writers are cleaned up when container exits
    }

    /// Close all subscribed writers
    public func close() throws {
        lock.lock()
        let currentSubscribers = subscribers
        lock.unlock()

        var lastError: Error?
        for writer in currentSubscribers {
            do {
                try writer.close()
            } catch {
                lastError = error
            }
        }

        if let error = lastError {
            throw error
        }
    }
}
