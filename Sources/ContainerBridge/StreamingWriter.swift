import Foundation
import Containerization

/// A Writer implementation that forwards container output to an AsyncStream
/// Used for streaming exec output back to Docker CLI in real-time
public final class StreamingWriter: Writer, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let streamType: UInt8  // 1 for stdout, 2 for stderr
    private let lock = NSLock()

    /// Create a new StreamingWriter
    /// - Parameters:
    ///   - continuation: AsyncStream continuation to send data to
    ///   - streamType: Docker multiplexed stream type (1=stdout, 2=stderr)
    public init(continuation: AsyncStream<Data>.Continuation, streamType: UInt8) {
        self.continuation = continuation
        self.streamType = streamType
    }

    /// Write data in Docker multiplexed stream format
    /// Format: [STREAM_TYPE, 0, 0, 0, SIZE1, SIZE2, SIZE3, SIZE4, ...DATA...]
    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        // Docker multiplexed stream header:
        // Byte 0: Stream type (1=stdout, 2=stderr)
        // Bytes 1-3: Padding (zeros)
        // Bytes 4-7: Payload size (big-endian uint32)
        var header = Data(count: 8)
        header[0] = streamType
        // Bytes 1-3 are already zero from initialization

        // Write size as big-endian uint32
        let size = UInt32(data.count)
        header[4] = UInt8((size >> 24) & 0xFF)
        header[5] = UInt8((size >> 16) & 0xFF)
        header[6] = UInt8((size >> 8) & 0xFF)
        header[7] = UInt8(size & 0xFF)

        // Combine header and payload
        let multiplexedData = header + data

        // Send to AsyncStream (non-blocking)
        continuation.yield(multiplexedData)
    }

    /// Close the writer
    public func close() throws {
        lock.lock()
        defer { lock.unlock() }

        // Signal end of stream
        continuation.finish()
    }
}
