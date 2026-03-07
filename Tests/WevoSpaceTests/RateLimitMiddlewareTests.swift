//
//  RateLimitMiddlewareTests.swift
//  WevoSpace
//
//  Created on 3/7/26.
//

@testable import WevoSpace
import VaporTesting
import Testing
import Fluent
import FluentSQLiteDriver

@Suite("RateLimitMiddleware Tests", .serialized)
struct RateLimitMiddlewareTests {
    // エラーレスポンスのデコード用構造体
    private struct ErrorResponse: Codable {
        let error: Bool
        let reason: String
    }
    
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            // テストごとにインメモリデータベースを使用
            app.databases.use(.sqlite(.memory), as: .sqlite)
            
            // マイグレーションを登録
            app.migrations.add(CreateWevoProposeTables())
            
            // マイグレーション実行
            try await app.autoMigrate()
            
            // Rate Limitingを適用（テスト用: 5リクエスト/10秒）
            let rateLimiter = RateLimitMiddleware(maxRequests: 5, windowSeconds: 10)
            
            // ルートを定義（Rate Limitミドルウェア付き）
            let limited = app.grouped(rateLimiter)
            
            limited.get { req async in
                "It works!"
            }
            
            limited.get("hello") { req async -> String in
                "Hello, world!"
            }
            
            // ProposeControllerは個別に登録
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
            // 5回のリクエストは成功するはず
            for i in 1...5 {
                try await app.testing().test(.GET, "hello", afterResponse: { res async throws in
                    #expect(res.status == .ok, "リクエスト\(i)は成功するべき")
                    
                    // Rate Limitヘッダーの確認
                    let limit = res.headers.first(name: "X-RateLimit-Limit")
                    #expect(limit == "5", "X-RateLimit-Limit が正しく設定されている: \(limit ?? "nil")")
                    
                    let remaining = res.headers.first(name: "X-RateLimit-Remaining")
                    #expect(remaining != nil, "X-RateLimit-Remaining が存在する: \(remaining ?? "nil")")
                })
            }
        }
    }
    
    @Test("Rate Limitを超えるとエラーになる")
    func requestsExceedingLimit() async throws {
        try await withApp { app in
            // 5回のリクエストを送る
            for _ in 1...5 {
                try await app.testing().test(.GET, "hello", afterResponse: { res async throws in
                    #expect(res.status == .ok)
                })
            }
            
            // 6回目のリクエストは失敗するはず
            try await app.testing().test(.GET, "hello", afterResponse: { res async throws in
                #expect(res.status == .tooManyRequests, "6回目のリクエストはRate Limitエラーになるべき")
                
                // Rate Limitヘッダーの確認
                let limit = res.headers.first(name: "X-RateLimit-Limit")
                #expect(limit == "5")
                
                let remaining = res.headers.first(name: "X-RateLimit-Remaining")
                #expect(remaining == "0")
                
                let retryAfter = res.headers.first(name: "Retry-After")
                #expect(retryAfter != nil, "Retry-After ヘッダーが存在する")
                
                // レスポンスボディの確認
                let errorResponse = try res.content.decode(ErrorResponse.self)
                #expect(errorResponse.error == true, "error フィールドが true")
                #expect(errorResponse.reason.isEmpty == false, "エラーメッセージが含まれている")
            })
        }
    }
    
    @Test("異なるエンドポイントでもRate Limitが適用される")
    func rateLimitAcrossEndpoints() async throws {
        try await withApp { app in
            // hello エンドポイントに3回
            for _ in 1...3 {
                try await app.testing().test(.GET, "hello", afterResponse: { res async throws in
                    #expect(res.status == .ok)
                })
            }
            
            // ルートエンドポイントに2回
            for _ in 1...2 {
                try await app.testing().test(.GET, "", afterResponse: { res async throws in
                    #expect(res.status == .ok)
                })
            }
            
            // 6回目のリクエスト（どのエンドポイントでも）は失敗
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
                
                // 必須ヘッダーの確認
                let limit = res.headers.first(name: "X-RateLimit-Limit")
                #expect(limit == "5", "X-RateLimit-Limit: 5")
                
                let remaining = res.headers.first(name: "X-RateLimit-Remaining")
                #expect(remaining == "4", "1回リクエストしたので残り4")
                
                let reset = res.headers.first(name: "X-RateLimit-Reset")
                #expect(reset != nil, "X-RateLimit-Reset が存在する")
                
                // リセット時刻が未来であることを確認
                if let resetString = reset, let resetTimestamp = Double(resetString) {
                    let resetDate = Date(timeIntervalSince1970: resetTimestamp)
                    #expect(resetDate > Date(), "リセット時刻は未来")
                }
            })
        }
    }
}
