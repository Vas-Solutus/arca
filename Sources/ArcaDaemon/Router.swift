import Foundation
import Logging
import NIOHTTP1

/// Type alias for route handler functions
public typealias RouteHandler = (HTTPRequest) async -> HTTPResponse

/// A route pattern matcher and request dispatcher
public final class Router {
    private let logger: Logger
    private var routes: [(method: HTTPMethod, pattern: RoutePattern, handler: RouteHandler)] = []

    public init(logger: Logger) {
        self.logger = logger
    }

    /// Register a route handler
    public func register(method: HTTPMethod, pattern: String, handler: @escaping RouteHandler) {
        let routePattern = RoutePattern(pattern: pattern)
        routes.append((method: method, pattern: routePattern, handler: handler))
        logger.debug("Registered route", metadata: [
            "method": "\(method.rawValue)",
            "pattern": "\(pattern)"
        ])
    }

    /// Route an incoming request to the appropriate handler
    public func route(request: HTTPRequest) async -> HTTPResponse {
        // Normalize the path by removing API version prefix if present
        let normalizedPath = normalizePath(request.path)

        logger.debug("Routing request", metadata: [
            "method": "\(request.method.rawValue)",
            "original_path": "\(request.path)",
            "normalized_path": "\(normalizedPath)"
        ])

        // Find matching route
        for route in routes {
            if route.method == request.method && route.pattern.matches(normalizedPath) {
                logger.debug("Route matched", metadata: [
                    "pattern": "\(route.pattern.pattern)"
                ])
                return await route.handler(request)
            }
        }

        // Check if path matches any pattern but with wrong method
        for route in routes {
            if route.pattern.matches(normalizedPath) {
                logger.warning("Path matched but wrong method", metadata: [
                    "expected": "\(route.method.rawValue)",
                    "received": "\(request.method.rawValue)"
                ])
                return HTTPResponse.error(
                    "Method \(request.method.rawValue) not allowed for \(request.path)",
                    status: .methodNotAllowed
                )
            }
        }

        // No matching route found
        logger.warning("No route found", metadata: [
            "path": "\(request.path)"
        ])
        return HTTPResponse.error("Not found: \(request.path)", status: .notFound)
    }

    /// Normalize path by removing API version prefix
    /// Examples:
    ///   /v1.51/containers/json -> /containers/json
    ///   /v1.24/version -> /version
    ///   /version -> /version
    private func normalizePath(_ path: String) -> String {
        // Match /vX.Y/ prefix (e.g., /v1.51/, /v1.24/)
        let versionPattern = #"^/v\d+\.\d+(/.*)?$"#
        guard let regex = try? NSRegularExpression(pattern: versionPattern),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) else {
            return path
        }

        // If there's a capture group (the part after version), return it
        if match.numberOfRanges > 1,
           let captureRange = Range(match.range(at: 1), in: path) {
            let captured = String(path[captureRange])
            return captured.isEmpty ? "/" : captured
        }

        return path
    }
}

/// Pattern matcher for routes
struct RoutePattern {
    let pattern: String
    private let regex: NSRegularExpression?

    init(pattern: String) {
        self.pattern = pattern

        // Convert route pattern to regex
        // For now, we'll use exact matching, but this could be extended
        // to support path parameters like /containers/:id
        let escapedPattern = NSRegularExpression.escapedPattern(for: pattern)
        self.regex = try? NSRegularExpression(pattern: "^" + escapedPattern + "$")
    }

    func matches(_ path: String) -> Bool {
        guard let regex = regex else { return false }
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, range: range) != nil
    }
}
