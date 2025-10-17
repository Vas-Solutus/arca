import Foundation
import NIOHTTP1

/// Represents an HTTP request received by the server
public struct HTTPRequest {
    public let method: HTTPMethod
    public let uri: String
    public let headers: HTTPHeaders
    public let body: Data?

    /// Extract the path without query parameters
    public var path: String {
        guard let url = URLComponents(string: uri) else { return uri }
        return url.path
    }

    /// Extract query parameters
    public var queryParameters: [String: String] {
        guard let url = URLComponents(string: uri),
              let queryItems = url.queryItems else {
            return [:]
        }

        var params: [String: String] = [:]
        for item in queryItems {
            params[item.name] = item.value ?? ""
        }
        return params
    }

    public init(method: HTTPMethod, uri: String, headers: HTTPHeaders, body: Data?) {
        self.method = method
        self.uri = uri
        self.headers = headers
        self.body = body
    }
}

/// Represents an HTTP response to be sent by the server
public struct HTTPResponse {
    public let status: HTTPResponseStatus
    public let headers: HTTPHeaders
    public let body: Data?

    public init(status: HTTPResponseStatus, headers: HTTPHeaders = HTTPHeaders(), body: Data? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Create a JSON response
    public static func json<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        guard let data = try? encoder.encode(value) else {
            return HTTPResponse(
                status: .internalServerError,
                headers: HTTPHeaders([("Content-Type", "application/json")]),
                body: Data("{\"message\":\"Failed to encode response\"}".utf8)
            )
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(data.count)")

        return HTTPResponse(status: status, headers: headers, body: data)
    }

    /// Create a plain text response
    public static func text(_ text: String, status: HTTPResponseStatus = .ok) -> HTTPResponse {
        let data = Data(text.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain")
        headers.add(name: "Content-Length", value: "\(data.count)")
        return HTTPResponse(status: status, headers: headers, body: data)
    }

    /// Create an error response
    public static func error(_ message: String, status: HTTPResponseStatus) -> HTTPResponse {
        let errorBody = ["message": message]
        return json(errorBody, status: status)
    }
}
