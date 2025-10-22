import Foundation
import Logging
import NIOHTTP1
import DockerAPI

/// Type alias for route handler functions
public typealias RouteHandler = @Sendable (HTTPRequest) async -> HTTPResponseType

/// A route pattern matcher and request dispatcher
/// Routes are registered during initialization and become immutable after setup
public final class Router: Sendable {
    private let logger: Logger
    private let routes: [(method: HTTPMethod, pattern: RoutePattern, handler: RouteHandler)]
    private let middlewares: [Middleware]

    /// Initialize router with routes and middlewares registered via builder
    fileprivate init(logger: Logger, routes: [(method: HTTPMethod, pattern: RoutePattern, handler: RouteHandler)], middlewares: [Middleware]) {
        self.logger = logger
        self.routes = routes
        self.middlewares = middlewares
    }

    /// Create a router builder for registering routes
    public static func builder(logger: Logger) -> RouterBuilder {
        return RouterBuilder(logger: logger)
    }

    /// Route an incoming request to the appropriate handler
    public func route(request: HTTPRequest) async -> HTTPResponseType {
        // Execute middleware chain before routing
        return await executeMiddlewareChain(request: request, middlewareIndex: 0)
    }

    /// Execute middleware chain recursively
    private func executeMiddlewareChain(request: HTTPRequest, middlewareIndex: Int) async -> HTTPResponseType {
        // If we've executed all middlewares, proceed to route matching
        if middlewareIndex >= middlewares.count {
            return await handleRoute(request: request)
        }

        // Execute current middleware
        let middleware = middlewares[middlewareIndex]
        return await middleware.handle(request) { modifiedRequest in
            // Continue to next middleware
            await self.executeMiddlewareChain(request: modifiedRequest, middlewareIndex: middlewareIndex + 1)
        }
    }

    /// Handle route matching and dispatch to handler
    private func handleRoute(request: HTTPRequest) async -> HTTPResponseType {
        let path = request.path

        logger.debug("Routing request", metadata: [
            "method": "\(request.method.rawValue)",
            "path": "\(path)"
        ])

        // Find matching route
        for route in routes {
            if route.method == request.method && route.pattern.matches(path) {
                logger.debug("Route matched", metadata: [
                    "pattern": "\(route.pattern.pattern)"
                ])

                // Extract path parameters and add to request
                let pathParams = route.pattern.extractParameters(from: path)
                var requestWithParams = request
                requestWithParams.pathParameters = pathParams

                if !pathParams.isEmpty {
                    logger.debug("Extracted path parameters", metadata: [
                        "parameters": "\(pathParams)"
                    ])
                }

                return await route.handler(requestWithParams)
            }
        }

        // Check if path matches any pattern but with wrong method
        for route in routes {
            if route.pattern.matches(path) {
                logger.warning("Path matched but wrong method", metadata: [
                    "expected": "\(route.method.rawValue)",
                    "received": "\(request.method.rawValue)"
                ])
                return .standard(HTTPResponse.error(
                    "Method \(request.method.rawValue) not allowed for \(request.path)",
                    status: .methodNotAllowed
                ))
            }
        }

        // No matching route found
        logger.warning("No route found", metadata: [
            "path": "\(request.path)"
        ])
        return .standard(HTTPResponse.error("Not found: \(request.path)", status: .notFound))
    }
}

/// Builder for constructing a Router with routes and middlewares
public final class RouterBuilder {
    private let logger: Logger
    private var routes: [(method: HTTPMethod, pattern: RoutePattern, handler: RouteHandler)] = []
    private var middlewares: [Middleware] = []

    fileprivate init(logger: Logger) {
        self.logger = logger
    }

    /// Register a middleware to be executed before route handlers
    public func use(_ middleware: Middleware) -> RouterBuilder {
        middlewares.append(middleware)
        logger.debug("Registered middleware", metadata: [
            "middleware": "\(type(of: middleware))"
        ])
        return self
    }

    /// Register a route handler
    public func register(method: HTTPMethod, pattern: String, handler: @escaping RouteHandler) -> RouterBuilder {
        let routePattern = RoutePattern(pattern: pattern)
        routes.append((method: method, pattern: routePattern, handler: handler))
        logger.debug("Registered route", metadata: [
            "method": "\(method.rawValue)",
            "pattern": "\(pattern)"
        ])
        return self
    }

    // MARK: - DSL Methods

    /// Register a GET route
    public func get(_ pattern: String, handler: @escaping RouteHandler) -> RouterBuilder {
        return register(method: .GET, pattern: pattern, handler: handler)
    }

    /// Register a POST route
    public func post(_ pattern: String, handler: @escaping RouteHandler) -> RouterBuilder {
        return register(method: .POST, pattern: pattern, handler: handler)
    }

    /// Register a PUT route
    public func put(_ pattern: String, handler: @escaping RouteHandler) -> RouterBuilder {
        return register(method: .PUT, pattern: pattern, handler: handler)
    }

    /// Register a DELETE route
    public func delete(_ pattern: String, handler: @escaping RouteHandler) -> RouterBuilder {
        return register(method: .DELETE, pattern: pattern, handler: handler)
    }

    /// Register a HEAD route
    public func head(_ pattern: String, handler: @escaping RouteHandler) -> RouterBuilder {
        return register(method: .HEAD, pattern: pattern, handler: handler)
    }

    /// Build the immutable router
    public func build() -> Router {
        return Router(logger: logger, routes: routes, middlewares: middlewares)
    }
}

/// Pattern matcher for routes
/// Supports path parameters using {paramName} syntax
/// Example: /containers/{id}/start matches /containers/abc123/start
struct RoutePattern {
    let pattern: String
    private let regex: NSRegularExpression?
    private let parameterNames: [String]

    init(pattern: String) {
        self.pattern = pattern

        // Extract parameter names from pattern (e.g., {id} -> "id")
        var names: [String] = []
        var regexPattern = "^"

        // Split pattern into components and process each
        let components = pattern.split(separator: "/", omittingEmptySubsequences: false)
        for (index, component) in components.enumerated() {
            if index > 0 {
                regexPattern += "/"
            }

            let componentStr = String(component)
            if componentStr.hasPrefix("{") && componentStr.hasSuffix("}") {
                // Extract parameter name and create capture group
                let paramName = String(componentStr.dropFirst().dropLast())
                names.append(paramName)
                regexPattern += "([^/]+)"  // Match any non-slash characters
            } else if !componentStr.isEmpty {
                // Regular path component - escape it
                regexPattern += NSRegularExpression.escapedPattern(for: componentStr)
            }
        }
        regexPattern += "$"

        self.parameterNames = names
        self.regex = try? NSRegularExpression(pattern: regexPattern)
    }

    func matches(_ path: String) -> Bool {
        guard let regex = regex else { return false }
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, range: range) != nil
    }

    /// Extract path parameters from a matching path
    func extractParameters(from path: String) -> [String: String] {
        guard let regex = regex else { return [:] }
        let range = NSRange(path.startIndex..., in: path)
        guard let match = regex.firstMatch(in: path, range: range) else { return [:] }

        var parameters: [String: String] = [:]
        for (index, paramName) in parameterNames.enumerated() {
            let captureIndex = index + 1  // Capture groups start at 1
            if captureIndex < match.numberOfRanges,
               let captureRange = Range(match.range(at: captureIndex), in: path) {
                parameters[paramName] = String(path[captureRange])
            }
        }

        return parameters
    }
}
