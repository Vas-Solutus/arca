import Foundation
import Containerization

/// A ReaderStream implementation that provides data from a Data buffer
/// Used for non-interactive operations like archive injection
public final class DataReaderStream: ReaderStream, @unchecked Sendable {
    private let data: Data

    public init(data: Data) {
        self.data = data
    }

    /// ReaderStream conformance - yields all data in one chunk
    public func stream() -> AsyncStream<Data> {
        return AsyncStream<Data> { continuation in
            continuation.yield(self.data)
            continuation.finish()
        }
    }
}
