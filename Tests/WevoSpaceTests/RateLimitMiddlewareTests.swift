@testable import WevoSpace
import VaporTesting
import Testing
import Fluent
import FluentSQLiteDriver

@Suite("RateLimitMiddleware Tests", .serialized)
struct RateLimitMiddlewareTests {
    // Struct for decoding error responses
    private struct ErrorResponse: Codable {
        let error: Bool
        let reason: String
    }

    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            // Use in-memory database per test
            app.databases.use(.sqlite(.memory), as: .sqlite)

            // Register migrations
            app.migrations.add(CreateProposesTable())

            // Run migrations
            try await app.autoMigrate()

            // Apply rate limiting (test config: 5 requests / 10 seconds)
            let rateLimiter = RateLimitMiddleware(requestLimit: 5, timeWindow: 10)

            // Define routes with rate limit middleware
            let limited = app.grouped(rateLimiter)

            limited.get { req async in
                "It works!"
            }

            limited.get("hello") { req async -> String in
                "Hello, world!"
            }

            // Register ProposeController separately
            try limited.register(collection: ProposeController())

            try await test(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("Rate Limit以内のリクエストは成功する")
    func requestsWithinLimit() async throws {
        try await withApp { app in
            // All 5 requests should succeed
            for i in 1...5 {
                try await app.testing().test(.GET, "hello", afterResponse: { res async throws in
                    #expect(res.status == .ok, "Request \(i) should succeed")

                    // Verify rate limit headers
                    let limit = res.headers.first(name: "X-RateLimit-Limit")
                    #expect(limit == "5", "X-RateLimit-Limit should be set correctly: \(limit ?? "nil")")

                    let remaining = res.headers.first(name: "X-RateLimit-Remaining")
                    #expect(remaining != nil, "X-RateLimit-Remaining should exist: \(remaining ?? "nil")")
                })
            }
        }
    }

    @Test("Rate Limitを超えるとエラーになる")
    func requestsExceedingLimit() async throws {
        try await withApp { app in
            // Send 5 requests
            for _ in 1...5 {
                try await app.testing().test(.GET, "hello", afterResponse: { res async throws in
                    #expect(res.status == .ok)
                })
            }

            // The 6th request should fail
            try await app.testing().test(.GET, "hello", afterResponse: { res async throws in
                #expect(res.status == .tooManyRequests, "The 6th request should return a rate limit error")

                // Verify rate limit headers
                let limit = res.headers.first(name: "X-RateLimit-Limit")
                #expect(limit == "5")

                let remaining = res.headers.first(name: "X-RateLimit-Remaining")
                #expect(remaining == "0")

                let retryAfter = res.headers.first(name: "Retry-After")
                #expect(retryAfter != nil, "Retry-After header should exist")

                // Verify response body
                let errorResponse = try res.content.decode(ErrorResponse.self)
                #expect(errorResponse.error == true, "error field should be true")
                #expect(errorResponse.reason.isEmpty == false, "Error message should be present")
            })
        }
    }

    @Test("異なるエンドポイントでもRate Limitが適用される")
    func rateLimitAcrossEndpoints() async throws {
        try await withApp { app in
            // 3 requests to hello endpoint
            for _ in 1...3 {
                try await app.testing().test(.GET, "hello", afterResponse: { res async throws in
                    #expect(res.status == .ok)
                })
            }

            // 2 requests to root endpoint
            for _ in 1...2 {
                try await app.testing().test(.GET, "", afterResponse: { res async throws in
                    #expect(res.status == .ok)
                })
            }

            // The 6th request (any endpoint) should fail
            try await app.testing().test(.GET, "hello", afterResponse: { res async throws in
                #expect(res.status == .tooManyRequests)
            })
        }
    }

    @Test("Rate Limitヘッダーが正しく設定される")
    func rateLimitHeaders() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async throws in
                #expect(res.status == .ok)

                // Verify required headers
                let limit = res.headers.first(name: "X-RateLimit-Limit")
                #expect(limit == "5", "X-RateLimit-Limit: 5")

                let remaining = res.headers.first(name: "X-RateLimit-Remaining")
                #expect(remaining == "4", "After 1 request, remaining should be 4")

                let reset = res.headers.first(name: "X-RateLimit-Reset")
                #expect(reset != nil, "X-RateLimit-Reset should exist")

                // Verify reset time is in the future
                if let resetString = reset, let resetTimestamp = Double(resetString) {
                    let resetDate = Date(timeIntervalSince1970: resetTimestamp)
                    #expect(resetDate > Date(), "Reset time should be in the future")
                }
            })
        }
    }
}
