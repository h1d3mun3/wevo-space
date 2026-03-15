import Vapor

/// Rate limiting middleware.
/// Limits the number of requests per client IP address.
actor RateLimitMiddleware: AsyncMiddleware {

    /// Stores the request history for a client.
    struct RequestHistory {
        var timestamps: [Date]
        var windowStart: Date
    }

    /// Rate limit information.
    struct RateLimitInfo {
        let allowed: Bool
        let remaining: Int
        let resetTime: Date
        let retryAfter: TimeInterval
    }

    /// Maximum number of requests allowed.
    private let requestLimit: Int

    /// Time window in seconds.
    private let timeWindow: TimeInterval

    /// Request history keyed by IP address.
    private var histories: [String: RequestHistory] = [:]

    /// - Parameters:
    ///   - requestLimit: Maximum requests allowed within the time window (default: 100)
    ///   - timeWindow: Length of the time window in seconds (default: 60)
    init(requestLimit: Int = 100, timeWindow: TimeInterval = 60) {
        self.requestLimit = requestLimit
        self.timeWindow = timeWindow
    }

    /// Middleware responder.
    nonisolated func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // Get client IP address (fall back to default IP if unavailable)
        let clientIP = getClientIP(from: request) ?? "127.0.0.1"

        // Check rate limit and retrieve info
        let info = await checkRateLimitAndGetInfo(for: clientIP)

        if !info.allowed {
            request.logger.warning("Rate limit exceeded for IP: \(clientIP)")

            // Build rate limit error response
            var response = Response(status: .tooManyRequests)
            response.headers.add(name: "X-RateLimit-Limit", value: "\(requestLimit)")
            response.headers.add(name: "X-RateLimit-Remaining", value: "0")
            response.headers.add(name: "X-RateLimit-Reset", value: "\(Int(info.resetTime.timeIntervalSince1970))")
            response.headers.add(name: "Retry-After", value: "\(Int(info.retryAfter))")
            response.headers.add(name: "Content-Type", value: "application/json; charset=utf-8")

            // Return error message as JSON
            let errorBody: [String: Any] = [
                "error": true,
                "reason": "Rate limit exceeded. Please wait a moment before retrying."
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: errorBody) {
                response.body = Response.Body(data: jsonData)
            }

            return response
        }

        // Pass the request to the next middleware/handler
        var response = try await next.respond(to: request)

        // Add rate limit headers
        response.headers.add(name: "X-RateLimit-Limit", value: "\(requestLimit)")
        response.headers.add(name: "X-RateLimit-Remaining", value: "\(info.remaining)")
        response.headers.add(name: "X-RateLimit-Reset", value: "\(Int(info.resetTime.timeIntervalSince1970))")

        return response
    }

    /// Checks the rate limit and returns detailed info.
    /// - Parameter clientIP: Client IP address
    /// - Returns: Rate limit information
    private func checkRateLimitAndGetInfo(for clientIP: String) async -> RateLimitInfo {
        let now = Date()

        // Retrieve existing history, or create a new one
        var history = histories[clientIP] ?? RequestHistory(timestamps: [], windowStart: now)

        // Remove timestamps outside the time window
        history.timestamps.removeAll { now.timeIntervalSince($0) > timeWindow }

        // Update window start time
        if history.timestamps.isEmpty {
            history.windowStart = now
        } else if let oldest = history.timestamps.first {
            history.windowStart = oldest
        }

        // Calculate reset time
        let resetTime = history.windowStart.addingTimeInterval(timeWindow)

        // Check if request count exceeds the limit
        if history.timestamps.count >= requestLimit {
            let retryAfter = resetTime.timeIntervalSince(now)
            return RateLimitInfo(
                allowed: false,
                remaining: 0,
                resetTime: resetTime,
                retryAfter: max(0, retryAfter)
            )
        }

        // Add new timestamp
        history.timestamps.append(now)
        histories[clientIP] = history

        let remaining = requestLimit - history.timestamps.count

        return RateLimitInfo(
            allowed: true,
            remaining: remaining,
            resetTime: resetTime,
            retryAfter: 0
        )
    }

    /// Returns the client IP address.
    /// - Parameter request: The incoming request
    /// - Returns: IP address, or nil if unavailable
    nonisolated private func getClientIP(from request: Request) -> String? {
        // For proxied requests, read from X-Forwarded-For header
        if let forwarded = request.headers.first(name: "X-Forwarded-For") {
            // If multiple IPs are comma-separated, use the first one (client IP)
            let ip = forwarded.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
            if let ip = ip, !ip.isEmpty {
                return ip
            }
        }

        // Check X-Real-IP header
        if let realIP = request.headers.first(name: "X-Real-IP") {
            return realIP
        }

        // For direct connections, read from remote address
        return request.remoteAddress?.ipAddress
    }

    /// Cleans up stale history entries (for memory management).
    /// Recommended to be called periodically.
    func cleanup() async {
        let now = Date()

        // Remove all entries outside the time window
        for (ip, history) in histories {
            let validTimestamps = history.timestamps.filter { now.timeIntervalSince($0) <= timeWindow }

            if validTimestamps.isEmpty {
                histories.removeValue(forKey: ip)
            } else {
                let windowStart = validTimestamps.first ?? now
                histories[ip] = RequestHistory(timestamps: validTimestamps, windowStart: windowStart)
            }
        }
    }
}
