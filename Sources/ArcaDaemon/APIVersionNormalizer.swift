import Foundation
import NIOHTTP1
import DockerAPI

/// Middleware that normalizes Docker API version prefixes
/// Transforms paths like /v1.51/containers/json to /containers/json
/// This allows route handlers to be registered without version prefixes
public struct APIVersionNormalizer: Middleware {

    public init() {}

    public func handle(_ request: HTTPRequest, next: @Sendable @escaping (HTTPRequest) async -> HTTPResponseType) async -> HTTPResponseType {
        // Normalize the path by removing API version prefix
        let normalizedPath = normalizePath(request.path)

        // If path was normalized, create new request with normalized path
        if normalizedPath != request.path {
            // Reconstruct URI with normalized path
            var newURI = normalizedPath
            if !request.queryParameters.isEmpty {
                // Preserve query parameters
                let queryString = request.queryParameters
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: "&")
                newURI += "?\(queryString)"
            }

            let normalizedRequest = HTTPRequest(
                method: request.method,
                uri: newURI,
                headers: request.headers,
                body: request.body,
                pathParameters: request.pathParameters
            )

            return await next(normalizedRequest)
        }

        // Path didn't need normalization, continue as-is
        return await next(request)
    }

    /// Normalize path by removing API version prefix
    /// Examples:
    ///   /v1.51/containers/json -> /containers/json
    ///   /v1.24/version -> /version
    ///   /version -> /version (unchanged)
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
