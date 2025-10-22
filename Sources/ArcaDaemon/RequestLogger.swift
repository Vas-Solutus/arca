import Foundation
import Logging
import NIOHTTP1
import DockerAPI

/// Middleware that logs HTTP requests and responses
public struct RequestLogger: Middleware {
    private let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    public func handle(_ request: HTTPRequest, next: @Sendable @escaping (HTTPRequest) async -> HTTPResponseType) async -> HTTPResponseType {
        // Log incoming request
        let startTime = Date()

        logger.info("→ Incoming request", metadata: [
            "method": "\(request.method.rawValue)",
            "path": "\(request.path)",
            "uri": "\(request.uri)"
        ])

        // Include body info for POST/PUT requests
        if (request.method == .POST || request.method == .PUT), let body = request.body {
            logger.debug("Request body", metadata: [
                "size_bytes": "\(body.count)",
                "content_type": "\(request.contentType ?? "unknown")"
            ])
        }

        // Process request through middleware chain
        let responseType = await next(request)

        // Calculate request duration
        let duration = Date().timeIntervalSince(startTime)
        let durationMs = String(format: "%.2f", duration * 1000)

        // Log response based on type
        switch responseType {
        case .standard(let response):
            let statusCode = response.status.code
            let logLevel: Logger.Level = statusCode >= 400 ? .warning : .info

            logger.log(level: logLevel, "← Response", metadata: [
                "method": "\(request.method.rawValue)",
                "path": "\(request.path)",
                "status": "\(statusCode)",
                "duration_ms": "\(durationMs)"
            ])

            // Log error details for failed requests
            if statusCode >= 400, let body = response.body, let errorMessage = String(data: body, encoding: .utf8) {
                logger.debug("Error response body", metadata: [
                    "body": "\(errorMessage)"
                ])
            }

        case .streaming(let status, _, _):
            logger.info("← Streaming response", metadata: [
                "method": "\(request.method.rawValue)",
                "path": "\(request.path)",
                "status": "\(status.code)",
                "duration_ms": "\(durationMs)"
            ])
        }

        return responseType
    }
}
