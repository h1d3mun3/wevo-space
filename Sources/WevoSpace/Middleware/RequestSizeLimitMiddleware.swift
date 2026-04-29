import Vapor

// Rejects requests whose body exceeds maxBytes.
// Checks the Content-Length header first (covers both streaming and collected bodies),
// then falls back to the collected ByteBuffer size (covers VaporTesting requests that
// bypass the streaming collection pipeline and therefore ignore defaultMaxBodySize).
struct RequestSizeLimitMiddleware: AsyncMiddleware {
    let maxBytes: Int

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let contentLength = request.headers.first(name: .contentLength).flatMap(Int.init)
        let size = contentLength ?? request.body.data?.readableBytes
        if let size, size > maxBytes {
            throw Abort(.payloadTooLarge, reason: "Request body exceeds maximum allowed size")
        }
        return try await next.respond(to: request)
    }
}
