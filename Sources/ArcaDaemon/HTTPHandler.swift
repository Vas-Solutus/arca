import Foundation
import Logging
import NIO
import NIOHTTP1
import DockerAPI

/// SwiftNIO-based stream writer for chunked HTTP responses
/// @unchecked Sendable: Safe because all operations are executed on the channel's event loop
final class NIOHTTPStreamWriter: HTTPStreamWriter, @unchecked Sendable {
    private let context: ChannelHandlerContext
    private let logger: Logger
    private var finished = false

    init(context: ChannelHandlerContext, logger: Logger) {
        self.context = context
        self.logger = logger
    }

    func write(_ data: Data) async throws {
        guard !finished else {
            throw StreamError.alreadyFinished
        }

        return try await withCheckedThrowingContinuation { continuation in
            context.eventLoop.execute {
                // Check if channel is still active before writing
                guard self.context.channel.isActive else {
                    self.logger.warning("Attempted to write to inactive channel, aborting stream")
                    self.finished = true
                    continuation.resume(throwing: StreamError.channelInactive)
                    return
                }

                var buffer = self.context.channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                let part = HTTPServerResponsePart.body(.byteBuffer(buffer))
                self.context.writeAndFlush(NIOAny(part), promise: nil)
                continuation.resume()
            }
        }
    }

    func finish() async throws {
        guard !finished else { return }
        finished = true

        return try await withCheckedThrowingContinuation { continuation in
            context.eventLoop.execute {
                // Check if channel is still active before finishing
                guard self.context.channel.isActive else {
                    self.logger.warning("Attempted to finish stream on inactive channel")
                    continuation.resume(throwing: StreamError.channelInactive)
                    return
                }

                // Send the end part to complete the HTTP response
                let endPart = HTTPServerResponsePart.end(nil)
                self.context.writeAndFlush(NIOAny(endPart), promise: nil)
                continuation.resume()
            }
        }
    }

    enum StreamError: Error {
        case alreadyFinished
        case channelInactive
    }
}

/// SwiftNIO channel handler for processing HTTP requests
/// @unchecked Sendable: Safe because NIO guarantees each handler instance is only accessed
/// from its associated channel's event loop, providing thread-safety through event loop isolation
final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: Router
    private let logger: Logger

    private var requestMethod: HTTPMethod?
    private var requestURI: String?
    private var requestHeaders: HTTPHeaders?
    private var bodyBuffer: ByteBuffer?
    private var channelActive: Bool = true

    init(router: Router, logger: Logger) {
        self.router = router
        self.logger = logger
    }

    func channelInactive(context: ChannelHandlerContext) {
        channelActive = false
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let requestPart = unwrapInboundIn(data)

        switch requestPart {
        case .head(let head):
            // Start of a new request
            requestMethod = head.method
            requestURI = head.uri
            requestHeaders = head.headers
            bodyBuffer = nil

        case .body(var buffer):
            // Accumulate request body
            if bodyBuffer == nil {
                bodyBuffer = buffer
            } else {
                bodyBuffer?.writeBuffer(&buffer)
            }

        case .end:
            // Request complete, process it
            handleRequest(context: context)
        }
    }

    private func handleRequest(context: ChannelHandlerContext) {
        guard let method = requestMethod,
              let uri = requestURI,
              let headers = requestHeaders else {
            sendErrorResponse(context: context, status: .badRequest, message: "Invalid request")
            return
        }

        // Convert body buffer to Data if present
        var bodyData: Data?
        if let buffer = bodyBuffer {
            bodyData = Data(buffer: buffer)
        }

        // Create request object
        let request = HTTPRequest(method: method, uri: uri, headers: headers, body: bodyData)

        // Log the request
        logger.info("Incoming request", metadata: [
            "method": "\(method.rawValue)",
            "path": "\(request.path)",
            "uri": "\(uri)"
        ])

        // Route the request asynchronously
        let eventLoop = context.eventLoop

        // Capture context with nonisolated(unsafe) to suppress Sendable warnings.
        // This is safe because:
        // 1. NIO guarantees handlers are only accessed from their event loop
        // 2. We only use capturedContext inside eventLoop.execute callbacks
        // 3. Those callbacks are guaranteed to run on the same event loop
        nonisolated(unsafe) let capturedContext = context

        // Queue the Task creation on the event loop to ensure proper ordering
        // This is the key pattern for bridging NIO event loop with Swift Concurrency
        eventLoop.execute {
            Task {
                let responseType = await self.router.route(request: request)

                // Send response on the event loop
                eventLoop.execute {
                    // Double-check channel is still active and context is valid
                    // This prevents "Bad file descriptor" errors when the channel closes
                    // during long-running operations (container creation, image pull, etc.)
                    guard self.channelActive && capturedContext.channel.isActive else {
                        self.logger.debug("Skipping response send - channel inactive", metadata: [
                            "handlerActive": "\(self.channelActive)",
                            "contextActive": "\(capturedContext.channel.isActive)"
                        ])
                        self.reset()
                        return
                    }
                    self.sendResponseType(context: capturedContext, responseType: responseType)
                    self.reset()
                }
            }
        }
    }

    private func sendResponseType(context: ChannelHandlerContext, responseType: HTTPResponseType) {
        switch responseType {
        case .standard(let response):
            sendResponse(context: context, response: response)

        case .streaming(let status, var headers, let callback):
            // Send response head with chunked transfer encoding
            headers.add(name: "Server", value: "Arca/0.1.8-alpha")
            headers.add(name: "Transfer-Encoding", value: "chunked")

            let responseHead = HTTPResponseHead(
                version: .http1_1,
                status: status,
                headers: headers
            )
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.flush()

            // Create stream writer and invoke callback
            let writer = NIOHTTPStreamWriter(context: context, logger: logger)

            // Execute callback on event loop
            context.eventLoop.execute {
                Task {
                    do {
                        try await callback(writer)
                        try await writer.finish()
                        self.logger.debug("Streaming response completed")
                    } catch {
                        self.logger.error("Streaming response error", metadata: ["error": "\(error)"])
                        // Try to finish the stream gracefully
                        try? await writer.finish()
                    }
                }
            }
        }
    }

    private func sendResponse(context: ChannelHandlerContext, response: HTTPResponse) {
        // Send response head
        var headers = response.headers
        headers.add(name: "Server", value: "Arca/0.1.8-alpha")

        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: response.status,
            headers: headers
        )
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

        // Send response body if present
        if let body = response.body {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }

        // Send end with a promise to track completion
        let endPromise = context.eventLoop.makePromise(of: Void.self)
        endPromise.futureResult.whenComplete { result in
            switch result {
            case .success:
                self.logger.debug("Response sent", metadata: [
                    "status": "\(response.status.code)",
                    "body_size": "\(response.body?.count ?? 0)"
                ])
            case .failure(let error):
                self.logger.warning("Failed to send response", metadata: [
                    "status": "\(response.status.code)",
                    "error": "\(error)"
                ])
            }
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: endPromise)
    }

    private func sendErrorResponse(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        let response = HTTPResponse.error(message, status: status)
        sendResponse(context: context, response: response)
        reset()
    }

    private func reset() {
        requestMethod = nil
        requestURI = nil
        requestHeaders = nil
        bodyBuffer = nil
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Error caught in HTTP handler", metadata: [
            "error": "\(error)"
        ])

        // Only close if channel is still active to avoid "Bad file descriptor" errors
        // when the channel is already closing/closed
        if context.channel.isActive {
            context.close(promise: nil)
        }
    }
}

// Helper extension to convert ByteBuffer to Data
extension Data {
    init(buffer: ByteBuffer) {
        var buffer = buffer
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        self.init(bytes)
    }
}
