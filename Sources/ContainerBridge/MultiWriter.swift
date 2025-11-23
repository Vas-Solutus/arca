import Foundation
import Containerization

/// A Writer that multiplexes output to multiple destination writers
/// Used to send container output to both log files and attach handles simultaneously
public final class MultiWriter: Writer, @unchecked Sendable {
    private let writers: [Writer]
    private let lock = NSLock()

    public init(writers: [Writer]) {
        self.writers = writers
    }

    /// Write data to all destination writers
    /// Continues even if one writer fails, to ensure other destinations still receive data
    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        var lastError: Error?

        for writer in writers {
            do {
                try writer.write(data)
            } catch {
                // Store error but continue writing to other writers
                // This ensures one failing destination doesn't break others
                lastError = error
            }
        }

        // If all writers failed, throw the last error
        if let error = lastError, writers.allSatisfy({ writer in
            // Check if this writer failed by attempting a zero-byte write
            do {
                try writer.write(Data())
                return false  // Succeeded
            } catch {
                return true  // Failed
            }
        }) {
            throw error
        }
    }

    /// Close is handled by the individual writer owners
    /// MultiWriter does not take ownership of the writers it multiplexes to
    public func close() throws {
        // No-op: writers are owned and closed by their respective managers
    }
}
