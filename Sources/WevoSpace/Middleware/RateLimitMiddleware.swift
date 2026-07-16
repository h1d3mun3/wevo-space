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

    /// Direct-peer IPs of trusted reverse proxies. The X-Forwarded-For / X-Real-IP headers are
    /// honored ONLY when the request's transport peer is one of these. Otherwise those headers are
    /// client-settable and would allow trivial rate-limit bypass and unbounded key growth.
    private let trustedProxies: Set<String>

    /// Hard upper bound on the number of distinct tracked client keys. Bounds memory even under a
    /// key-rotation flood between cleanup cycles; when exceeded, the entry with the oldest window
    /// is evicted before a new key is inserted.
    private let maxTrackedKeys: Int

    /// Request history keyed by client IP address.
    private var histories: [String: RequestHistory] = [:]

    /// - Parameters:
    ///   - requestLimit: Maximum requests allowed within the time window (default: 100)
    ///   - timeWindow: Length of the time window in seconds (default: 60)
    ///   - trustedProxies: Direct-peer IPs whose forwarding headers may be trusted (default: none)
    ///   - maxTrackedKeys: Upper bound on distinct tracked client keys (default: 50_000)
    init(requestLimit: Int = 100, timeWindow: TimeInterval = 60, trustedProxies: Set<String> = [], maxTrackedKeys: Int = 50_000) {
        self.requestLimit = requestLimit
        self.timeWindow = timeWindow
        self.trustedProxies = trustedProxies
        self.maxTrackedKeys = maxTrackedKeys
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

        // Bound memory: if this is a brand-new key and we're at capacity, evict the entry with
        // the oldest window before inserting. Cheap O(n) scan, only on the capacity boundary.
        if histories[clientIP] == nil, histories.count >= maxTrackedKeys {
            if let oldestKey = histories.min(by: { $0.value.windowStart < $1.value.windowStart })?.key {
                histories.removeValue(forKey: oldestKey)
            }
        }

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
        let directPeer = request.remoteAddress?.ipAddress

        // Only honor forwarding headers when the direct transport peer is a configured trusted
        // proxy. Otherwise a client could spoof X-Forwarded-For / X-Real-IP to bypass the per-IP
        // limit and mint unbounded distinct keys (memory exhaustion).
        if let directPeer, trustedProxies.contains(directPeer) {
            if let forwarded = request.headers.first(name: "X-Forwarded-For") {
                // Take the right-most entry — the address the trusted proxy actually observed —
                // rather than a client-prepended value.
                let ip = forwarded.split(separator: ",").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
                if let ip, !ip.isEmpty {
                    return ip
                }
            }
            if let realIP = request.headers.first(name: "X-Real-IP")?.trimmingCharacters(in: .whitespaces), !realIP.isEmpty {
                return realIP
            }
        }

        // Default: trust only the actual transport peer address.
        return directPeer
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

/// Periodically invokes RateLimitMiddleware.cleanup() so its in-memory history map is reclaimed
/// even for client keys that never recur. Without this the map only ever shrinks lazily per-IP,
/// so a flood of distinct keys grows it without bound. Mirrors SyncScheduler's lifecycle pattern.
final class RateLimitCleanupScheduler: LifecycleHandler {
    private let middleware: RateLimitMiddleware
    private let interval: TimeInterval
    private nonisolated(unsafe) var task: Task<Void, Never>?

    init(middleware: RateLimitMiddleware, interval: TimeInterval) {
        self.middleware = middleware
        self.interval = interval
    }

    func didBoot(_ application: Application) throws {
        task = Task { [middleware, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await middleware.cleanup()
            }
        }
    }

    func shutdown(_ application: Application) {
        task?.cancel()
    }
}
