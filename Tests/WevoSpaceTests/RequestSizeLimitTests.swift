//
//  RequestSizeLimitTests.swift
//  WevoSpace
//
//  Created on 3/7/26.
//

@testable import WevoSpace
import VaporTesting
import Testing
import Fluent
import FluentSQLiteDriver
import Crypto

@Suite("Request Size Limit Tests", .serialized)
struct RequestSizeLimitTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            // テストごとにインメモリデータベースを使用
            app.databases.use(.sqlite(.memory), as: .sqlite)
            
            // リクエストサイズ制限を設定
            app.routes.defaultMaxBodySize = "1mb"
            
            // マイグレーションを登録
            app.migrations.add(CreateWevoProposeTables())
            
            // マイグレーション実行
            try await app.autoMigrate()
            
            // routesを登録
            try routes(app)
            
            try await test(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
    
    // MARK: - Helper Methods
    
    /// テスト用の鍵ペアと署名を生成するヘルパー
    private func generateTestSignature(message: String) throws -> (publicKey: String, signature: String) {
        let privateKey = P256.Signing.PrivateKey()
        let messageData = Data(message.utf8)
        let signature = try privateKey.signature(for: messageData)
        
        let publicKeyBase64 = privateKey.publicKey.x963Representation.base64EncodedString()
        let signatureBase64 = signature.derRepresentation.base64EncodedString()
        
        return (publicKeyBase64, signatureBase64)
    }
    
    // MARK: - Tests
    
    @Test("通常サイズのリクエストは成功する")
    func normalSizeRequest() async throws {
        try await withApp { app in
            let proposeID = UUID()
            let payloadHash = "test-payload-hash"
            let (publicKey, signature) = try generateTestSignature(message: payloadHash)
            
            let input = ProposeInput(
                id: proposeID,
                payloadHash: payloadHash,
                signatures: [SignatureInput(publicKey: publicKey, signature: signature)]
            )
            
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .created, "通常サイズのリクエストは成功する")
            })
        }
    }
    
    @Test("大量の署名を含むリクエストでもサイズ制限内なら成功する")
    func manySignaturesWithinLimit() async throws {
        try await withApp { app in
            let proposeID = UUID()
            let payloadHash = "test-payload-hash"
            
            // 100個の署名を生成（それでも1MB以内）
            var signatures: [SignatureInput] = []
            for _ in 0..<100 {
                let (publicKey, signature) = try generateTestSignature(message: payloadHash)
                signatures.append(SignatureInput(publicKey: publicKey, signature: signature))
            }
            
            let input = ProposeInput(
                id: proposeID,
                payloadHash: payloadHash,
                signatures: signatures
            )
            
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .created, "100個の署名でも1MB以内なら成功する")
                
                // DBに保存されたか確認
                let savedSignatures = try await Signature.query(on: app.db)
                    .filter(\.$propose.$id == proposeID)
                    .all()
                #expect(savedSignatures.count == 100)
            })
        }
    }
    
    @Test("極端に長いpayloadHashは制限される")
    func extremelyLongPayloadHash() async throws {
        try await withApp { app in
            let proposeID = UUID()
            // 1MB以上の文字列を生成
            let hugePayloadHash = String(repeating: "a", count: 2_000_000) // 2MB
            let (publicKey, signature) = try generateTestSignature(message: "test")
            
            let input = ProposeInput(
                id: proposeID,
                payloadHash: hugePayloadHash,
                signatures: [SignatureInput(publicKey: publicKey, signature: signature)]
            )
            
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                // リクエストサイズ制限またはフィールドバリデーションで拒否される
                #expect(res.status == .badRequest || res.status == .payloadTooLarge, 
                       "1MBを超えるリクエストは拒否される (actual: \(res.status))")
            })
        }
    }
    
    @Test("極端に長い公開鍵は制限される")
    func extremelyLongPublicKey() async throws {
        try await withApp { app in
            let proposeID = UUID()
            let payloadHash = "test-payload-hash"
            // 1MB以上の公開鍵文字列
            let hugePublicKey = String(repeating: "a", count: 2_000_000) // 2MB
            
            let input = ProposeInput(
                id: proposeID,
                payloadHash: payloadHash,
                signatures: [SignatureInput(publicKey: hugePublicKey, signature: "test")]
            )
            
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                // リクエストサイズ制限またはフィールドバリデーションで拒否される
                #expect(res.status == .badRequest || res.status == .payloadTooLarge, 
                       "1MBを超えるリクエストは拒否される (actual: \(res.status))")
            })
        }
    }
    
    @Test("リクエストサイズの境界値テスト")
    func boundarySizeRequest() async throws {
        try await withApp { app in
            let proposeID = UUID()
            let payloadHash = "test-payload-hash"
            
            // 約1MB弱のデータを生成（署名を多数含める）
            var signatures: [SignatureInput] = []
            // 各署名は約200バイト程度なので、5000個で約1MB
            for _ in 0..<5000 {
                let (publicKey, signature) = try generateTestSignature(message: payloadHash)
                signatures.append(SignatureInput(publicKey: publicKey, signature: signature))
            }
            
            let input = ProposeInput(
                id: proposeID,
                payloadHash: payloadHash,
                signatures: signatures
            )
            
            // JSONエンコードしてサイズを確認
            let encoder = JSONEncoder()
            let data = try encoder.encode(input)
            let sizeInMB = Double(data.count) / 1_048_576.0
            print("リクエストサイズ: \(sizeInMB) MB")
            
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                // 1MB以内なら成功、超えていれば400または413エラー
                if sizeInMB <= 1.0 {
                    // 署名数制限（1000個）により400エラーになる
                    #expect(res.status == .badRequest, "署名数が1000を超えているため400エラー")
                } else {
                    #expect(res.status == .badRequest || res.status == .payloadTooLarge, 
                           "1MBを超えるリクエストは拒否される")
                }
            })
        }
    }
}
