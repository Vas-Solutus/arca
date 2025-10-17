import Foundation
import Logging
import NIO
import NIOHTTP1

/// SwiftNIO channel handler for processing HTTP requests
final class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: Router
    private let logger: Logger

    private var requestMethod: HTTPMethod?
    private var requestURI: String?
    private var requestHeaders: HTTPHeaders?
    private var bodyBuffer: ByteBuffer?

    init(router: Router, logger: Logger) {
        self.router = router
        self.logger = logger
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
        eventLoop.execute {
            Task {
                let response = await self.router.route(request: request)

                // Send response on the event loop
                eventLoop.execute {
                    self.sendResponse(context: context, response: response)
                    self.reset()
                }
            }
        }
    }

    private func sendResponse(context: ChannelHandlerContext, response: HTTPResponse) {
        // Send response head
        var headers = response.headers
        headers.add(name: "Server", value: "Arca/0.1.0")

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

        // Send end
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)

        logger.debug("Response sent", metadata: [
            "status": "\(response.status.code)",
            "body_size": "\(response.body?.count ?? 0)"
        ])
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
        context.close(promise: nil)
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
