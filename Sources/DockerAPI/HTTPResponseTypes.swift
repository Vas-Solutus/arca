import Foundation
import NIOHTTP1

/// Streaming chunk writer for HTTP responses
public protocol HTTPStreamWriter: Sendable {
    /// Write a chunk of data to the stream
    func write(_ data: Data) async throws

    /// Finish the stream
    func finish() async throws
}

/// Callback type for streaming responses
public typealias HTTPStreamingCallback = @Sendable (HTTPStreamWriter) async throws -> Void

/// Represents a streaming or standard HTTP response
public enum HTTPResponseType {
    case standard(HTTPResponse)
    case streaming(status: HTTPResponseStatus, headers: HTTPHeaders, callback: HTTPStreamingCallback)
}

/// Standard HTTP response (non-streaming)
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
