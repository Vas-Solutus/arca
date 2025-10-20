import Foundation
import Containerization

/// A ReaderStream implementation that provides container stdin from an AsyncStream
/// Used for reading stdin from Docker CLI during interactive exec sessions
public final class ChannelReader: ReaderStream, @unchecked Sendable {
    private let byteStream: AsyncStream<UInt8>
    public let continuation: AsyncStream<UInt8>.Continuation

    public init() {
        var cont: AsyncStream<UInt8>.Continuation!
        self.byteStream = AsyncStream<UInt8> { continuation in
            cont = continuation
        }
        self.continuation = cont
    }

    /// ReaderStream conformance - returns stream of Data chunks
    /// For interactive TTY, yields each byte immediately for real-time response
    public func stream() -> AsyncStream<Data> {
        return AsyncStream<Data> { continuation in
            Task {
                for await byte in self.byteStream {
                    // Yield each byte immediately for interactive TTY response
                    continuation.yield(Data([byte]))
                }
                continuation.finish()
            }
        }
    }

    /// Close the reader
    public func close() {
        continuation.finish()
    }
}
