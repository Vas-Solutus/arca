import Foundation
import NIOHTTP1

/// Convenience extensions for creating HTTPResponse objects
extension HTTPResponse {

    // MARK: - Success Responses (2xx)

    /// Create a 200 OK response with JSON body
    public static func ok<T: Encodable>(_ value: T) -> HTTPResponse {
        return json(value, status: .ok)
    }

    /// Create a 200 OK response with plain text
    public static func ok(_ text: String) -> HTTPResponse {
        return HTTPResponse.text(text, status: .ok)
    }

    /// Create a 200 OK response with no body
    public static func ok() -> HTTPResponse {
        return HTTPResponse(status: .ok)
    }

    /// Create a 201 Created response with JSON body
    public static func created<T: Encodable>(_ value: T) -> HTTPResponse {
        return json(value, status: .created)
    }

    /// Create a 201 Created response with plain text
    public static func created(_ text: String) -> HTTPResponse {
        return HTTPResponse.text(text, status: .created)
    }

    /// Create a 204 No Content response
    public static func noContent() -> HTTPResponse {
        return HTTPResponse(status: .noContent)
    }

    // MARK: - Client Error Responses (4xx)

    /// Create a 400 Bad Request error response
    public static func badRequest(_ message: String) -> HTTPResponse {
        return error(message, status: .badRequest)
    }

    /// Create a 401 Unauthorized error response
    public static func unauthorized(_ message: String = "Unauthorized") -> HTTPResponse {
        return error(message, status: .unauthorized)
    }

    /// Create a 403 Forbidden error response
    public static func forbidden(_ message: String = "Forbidden") -> HTTPResponse {
        return error(message, status: .forbidden)
    }

    /// Create a 404 Not Found error response
    public static func notFound(_ message: String) -> HTTPResponse {
        return error(message, status: .notFound)
    }

    /// Create a 404 Not Found for a specific resource type
    public static func notFound(_ resourceType: String, id: String) -> HTTPResponse {
        return error("No such \(resourceType): \(id)", status: .notFound)
    }

    /// Create a 409 Conflict error response
    public static func conflict(_ message: String) -> HTTPResponse {
        return error(message, status: .conflict)
    }

    /// Create a 422 Unprocessable Entity error response
    public static func unprocessableEntity(_ message: String) -> HTTPResponse {
        return error(message, status: .unprocessableEntity)
    }

    // MARK: - Server Error Responses (5xx)

    /// Create a 500 Internal Server Error response
    public static func internalServerError(_ message: String = "Internal server error") -> HTTPResponse {
        return error(message, status: .internalServerError)
    }

    /// Create a 500 Internal Server Error from an Error
    public static func internalServerError(_ error: Error) -> HTTPResponse {
        return self.error(error.localizedDescription, status: .internalServerError)
    }

    /// Create a 501 Not Implemented response
    public static func notImplemented(_ message: String = "Not implemented") -> HTTPResponse {
        return error(message, status: .notImplemented)
    }

    /// Create a 503 Service Unavailable response
    public static func serviceUnavailable(_ message: String = "Service unavailable") -> HTTPResponse {
        return error(message, status: .serviceUnavailable)
    }
}
