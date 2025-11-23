import Foundation
import NIOHTTP1
import NIO
import DockerAPI

/// Represents an HTTP request received by the server
public struct HTTPRequest: Sendable {
    public let method: HTTPMethod
    public let uri: String
    public let headers: HTTPHeaders
    public let body: Data?
    public var pathParameters: [String: String]

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

    public init(method: HTTPMethod, uri: String, headers: HTTPHeaders, body: Data?, pathParameters: [String: String] = [:]) {
        self.method = method
        self.uri = uri
        self.headers = headers
        self.body = body
        self.pathParameters = pathParameters
    }
}
