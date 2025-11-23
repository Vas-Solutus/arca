import Foundation
import NIOHTTP1
import DockerAPI

/// Middleware that processes requests in a pipeline before they reach route handlers
public protocol Middleware: Sendable {
    /// Process a request and optionally call the next middleware in the chain
    /// - Parameters:
    ///   - request: The incoming HTTP request
    ///   - next: Closure to invoke the next middleware/handler in the chain
    /// - Returns: The HTTP response (can be modified by middleware)
    func handle(_ request: HTTPRequest, next: @Sendable @escaping (HTTPRequest) async -> HTTPResponseType) async -> HTTPResponseType
}

/// Context for passing data between middlewares
/// Uses actor isolation to safely share state across middleware pipeline
public actor MiddlewareContext {
    private var storage: [String: Any] = [:]

    public init() {}

    /// Store a value in the context
    public func set<T>(_ key: String, value: T) {
        storage[key] = value
    }

    /// Retrieve a value from the context
    public func get<T>(_ key: String) -> T? {
        return storage[key] as? T
    }

    /// Remove a value from the context
    public func remove(_ key: String) {
        storage.removeValue(forKey: key)
    }
}
