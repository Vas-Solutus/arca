import Foundation
import Logging
import NIOHTTP1
import DockerAPI

/// Type alias for route handler functions
public typealias RouteHandler = (HTTPRequest) async -> HTTPResponseType

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
    public func route(request: HTTPRequest) async -> HTTPResponseType {
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

                // Extract path parameters and add to request
                let pathParams = route.pattern.extractParameters(from: normalizedPath)
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
            if route.pattern.matches(normalizedPath) {
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
