import Foundation
import NIOHTTP1
import DockerAPI

/// Convenience extensions for type-safe parameter access on HTTPRequest
extension HTTPRequest {

    // MARK: - Query Parameter Helpers

    /// Parse boolean query parameter with default value
    /// Handles common boolean string representations: "true", "1", "false", "0"
    public func queryBool(_ key: String, default defaultValue: Bool = false) -> Bool {
        guard let value = queryParameters[key] else {
            return defaultValue
        }

        let lowercased = value.lowercased()
        if lowercased == "true" || lowercased == "1" {
            return true
        } else if lowercased == "false" || lowercased == "0" {
            return false
        }

        return defaultValue
    }

    /// Parse integer query parameter
    /// Returns nil if parameter is missing or not a valid integer
    public func queryInt(_ key: String) -> Int? {
        guard let value = queryParameters[key] else {
            return nil
        }
        return Int(value)
    }

    /// Get string query parameter
    /// Returns nil if parameter is missing
    public func queryString(_ key: String) -> String? {
        return queryParameters[key]
    }

    /// Parse array query parameter (comma-separated values)
    /// Example: ?filters=status=running,status=paused -> ["status=running", "status=paused"]
    public func queryArray(_ key: String) -> [String]? {
        guard let value = queryParameters[key] else {
            return nil
        }
        return value.split(separator: ",").map(String.init)
    }

    // MARK: - Path Parameter Helpers

    /// Type-safe path parameter access
    /// Returns nil if parameter is not present in path
    public func pathParam(_ key: String) -> String? {
        return pathParameters[key]
    }

    /// Get required path parameter
    /// Throws error if parameter is missing
    public func requiredPathParam(_ key: String) throws -> String {
        guard let value = pathParameters[key] else {
            throw RequestError.missingPathParameter(key)
        }
        return value
    }

    // MARK: - Body Helpers

    /// Decode JSON body to Decodable type
    /// Throws error if body is missing or invalid JSON
    public func jsonBody<T: Decodable>(_ type: T.Type) throws -> T {
        guard let body = body, !body.isEmpty else {
            throw RequestError.missingBody
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: body)
        } catch {
            throw RequestError.invalidJSON(error)
        }
    }

    /// Try to decode JSON body, returning nil if missing or invalid
    /// Does not throw - returns nil on any error
    public func optionalJSONBody<T: Decodable>(_ type: T.Type) -> T? {
        return try? jsonBody(T.self)
    }

    // MARK: - Header Helpers

    /// Get header value by name (case-insensitive)
    public func header(_ name: String) -> String? {
        return headers[name].first
    }

    /// Check if request has specific header value
    public func hasHeader(_ name: String, value: String) -> Bool {
        guard let headerValue = header(name) else {
            return false
        }
        return headerValue.lowercased() == value.lowercased()
    }

    /// Get Content-Type header
    public var contentType: String? {
        return header("Content-Type")
    }

    /// Check if request is JSON
    public var isJSON: Bool {
        guard let contentType = contentType else {
            return false
        }
        return contentType.lowercased().contains("application/json")
    }
}

/// Errors that can occur during request parameter parsing
public enum RequestError: Error, CustomStringConvertible {
    case missingPathParameter(String)
    case missingBody
    case invalidJSON(Error)

    public var description: String {
        switch self {
        case .missingPathParameter(let key):
            return "Missing required path parameter: \(key)"
        case .missingBody:
            return "Request body is required but missing"
        case .invalidJSON(let error):
            return "Invalid JSON in request body: \(error.localizedDescription)"
        }
    }
}
