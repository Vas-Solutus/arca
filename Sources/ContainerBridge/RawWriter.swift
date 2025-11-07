import Foundation
import Containerization

/// A Writer implementation that forwards container output to an AsyncStream WITHOUT multiplexing
/// Used for TTY mode where Docker expects raw output (no stream type headers)
public final class RawWriter: Writer, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()

    /// Create a new RawWriter
    /// - Parameter continuation: AsyncStream continuation to send data to
    public init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    /// Write data in raw format (no multiplexing headers)
    /// This is used for TTY mode where output should be streamed directly
    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        // Send raw data to AsyncStream (no headers in TTY mode)
        continuation.yield(data)
    }

    /// Close the writer
    public func close() throws {
        lock.lock()
        defer { lock.unlock() }

        // Signal end of stream
        continuation.finish()
    }
}
