//
//  ProposeControllerTests.swift
//  WevoSpace
//
//  Created by hidemune on 3/6/26.
//

@testable import WevoSpace
import VaporTesting
import Testing
import Fluent
import FluentSQLiteDriver
import Crypto

@Suite("ProposeController Tests", .serialized)
struct ProposeControllerTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            // テストごとにインメモリデータベースを使用
            app.databases.use(.sqlite(.memory), as: .sqlite)
            
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
    private func generateTestSignature(message: String) throws -> (publicKey: String, signature: String, privateKey: P256.Signing.PrivateKey) {
        let privateKey = P256.Signing.PrivateKey()
        let messageData = Data(message.utf8)
        let signature = try privateKey.signature(for: messageData)
        
        let publicKeyBase64 = privateKey.publicKey.x963Representation.base64EncodedString()
        let signatureBase64 = signature.derRepresentation.base64EncodedString()
        
        return (publicKeyBase64, signatureBase64, privateKey)
    }
    
    // MARK: - Create Tests
    
    @Test("正常な署名でProposeを作成できる")
    func createProposeWithValidSignature() async throws {
        try await withApp { app in
            let proposeID = UUID()
            let payloadHash = "test-payload-hash"
            let (publicKey, signature, _) = try generateTestSignature(message: payloadHash)
            
            let input = ProposeInput(
                id: proposeID,
                payloadHash: payloadHash,
                signatures: [SignatureInput(publicKey: publicKey, signature: signature)]
            )
            
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)

                // DBに保存されたか確認
                let propose = try await Propose.find(proposeID, on: app.db)
                #expect(propose != nil)
                #expect(propose?.payloadHash == payloadHash)
                
                // 署名も保存されたか確認
                let signatures = try await Signature.query(on: app.db)
                    .filter(\.$propose.$id == proposeID)
                    .all()
                #expect(signatures.count == 1)
                #expect(signatures.first?.publicKey == publicKey)
                #expect(signatures.first?.signatureData == signature)
            })
        }
    }
    
    @Test("不正な署名でProposeを作成するとエラーになる")
    func createProposeWithInvalidSignature() async throws {
        try await withApp { app in
            let proposeID = UUID()
            let payloadHash = "test-payload-hash"
            let (publicKey, _, _) = try generateTestSignature(message: payloadHash)
            
            // 別のメッセージで署名を生成（不正な署名）
            let (_, wrongSignature, _) = try generateTestSignature(message: "wrong-message")
            
            let input = ProposeInput(
                id: proposeID,
                payloadHash: payloadHash,
                signatures: [SignatureInput(publicKey: publicKey, signature: wrongSignature)]
            )
            
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
                
                // DBに保存されていないことを確認
                let propose = try await Propose.find(proposeID, on: app.db)
                #expect(propose == nil)
            })
        }
    }
    
    @Test("不正なBase64形式の公開鍵でエラーになる")
    func createProposeWithInvalidPublicKeyFormat() async throws {
        try await withApp { app in
            let proposeID = UUID()
            let payloadHash = "test-payload-hash"
            
            let input = ProposeInput(
                id: proposeID,
                payloadHash: payloadHash,
                signatures: [SignatureInput(publicKey: "invalid-base64!!!", signature: "invalid-signature!!!")]
            )
            
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }
    
    // MARK: - Sign Tests
    
    @Test("正常な署名で既存のProposeに署名を追加できる")
    func signExistingProposeWithValidSignature() async throws {
        try await withApp { app in
            // まず最初のProposeを作成
            let proposeID = UUID()
            let payloadHash = "test-payload-hash"
            let (publicKey1, signature1, _) = try generateTestSignature(message: payloadHash)
            
            let propose = Propose(id: proposeID, payloadHash: payloadHash)
            try await propose.save(on: app.db)
            
            let firstSignature = Signature(proposeID: proposeID, publicKey: publicKey1, signatureData: signature1)
            try await firstSignature.save(on: app.db)
            
            // 2人目の署名を追加
            let (publicKey2, signature2, _) = try generateTestSignature(message: payloadHash)
            
            let updateInput = ProposeInput(
                id: proposeID,
                payloadHash: payloadHash,
                signatures: [
                    SignatureInput(publicKey: publicKey1, signature: signature1),
                    SignatureInput(publicKey: publicKey2, signature: signature2)
                ]
            )
            
            try await app.testing().test(.PUT, "v1/proposes/\(proposeID)", beforeRequest: { req in
                try req.content.encode(updateInput)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                
                // 署名が2つになったか確認
                let signatures = try await Signature.query(on: app.db)
                    .filter(\.$propose.$id == proposeID)
                    .all()
                #expect(signatures.count == 2)
                
                let publicKeys = signatures.map { $0.publicKey }
                #expect(publicKeys.contains(publicKey1))
                #expect(publicKeys.contains(publicKey2))
            })
        }
    }
    
    @Test("不正な署名で既存のProposeに署名を追加するとエラーになる")
    func signExistingProposeWithInvalidSignature() async throws {
        try await withApp { app in
            // まず最初のProposeを作成
            let proposeID = UUID()
            let payloadHash = "test-payload-hash"
            let (publicKey1, signature1, _) = try generateTestSignature(message: payloadHash)
            
            let propose = Propose(id: proposeID, payloadHash: payloadHash)
            try await propose.save(on: app.db)
            
            let firstSignature = Signature(proposeID: proposeID, publicKey: publicKey1, signatureData: signature1)
            try await firstSignature.save(on: app.db)
            
            // 不正な署名で追加を試みる
            let (publicKey2, _, _) = try generateTestSignature(message: payloadHash)
            let (_, wrongSignature, _) = try generateTestSignature(message: "wrong-message")
            
            let updateInput = ProposeInput(
                id: proposeID,
                payloadHash: payloadHash,
                signatures: [
                    SignatureInput(publicKey: publicKey1, signature: signature1),
                    SignatureInput(publicKey: publicKey2, signature: wrongSignature)
                ]
            )
            
            try await app.testing().test(.PUT, "v1/proposes/\(proposeID)", beforeRequest: { req in
                try req.content.encode(updateInput)
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
                
                // 署名は1つのままであることを確認
                let signatures = try await Signature.query(on: app.db)
                    .filter(\.$propose.$id == proposeID)
                    .all()
                #expect(signatures.count == 1)
                #expect(signatures.first?.publicKey == publicKey1)
            })
        }
    }
    
    @Test("存在しないProposeに署名を追加するとエラーになる")
    func signNonExistentPropose() async throws {
        try await withApp { app in
            let nonExistentID = UUID()
            let payloadHash = "test-payload-hash"
            let (publicKey, signature, _) = try generateTestSignature(message: payloadHash)
            
            let updateInput = ProposeInput(
                id: nonExistentID,
                payloadHash: payloadHash,
                signatures: [SignatureInput(publicKey: publicKey, signature: signature)]
            )
            
            try await app.testing().test(.PUT, "v1/proposes/\(nonExistentID)", beforeRequest: { req in
                try req.content.encode(updateInput)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }
    
    @Test("無効なUUID形式でアクセスするとエラーになる")
    func signWithInvalidUUID() async throws {
        try await withApp { app in
            let payloadHash = "test-payload-hash"
            let (publicKey, signature, _) = try generateTestSignature(message: payloadHash)
            
            let updateInput = ProposeInput(
                id: UUID(), // 一応有効なUUIDを使用
                payloadHash: payloadHash,
                signatures: [SignatureInput(publicKey: publicKey, signature: signature)]
            )
            
            try await app.testing().test(.PUT, "v1/proposes/invalid-uuid", beforeRequest: { req in
                try req.content.encode(updateInput)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }
    
    @Test("同じ公開鍵で複数回署名できる")
    func signMultipleTimesWithSamePublicKey() async throws {
        try await withApp { app in
            // 最初のProposeを作成
            let proposeID = UUID()
            let payloadHash = "test-payload-hash"
            let (publicKey, signature, privateKey) = try generateTestSignature(message: payloadHash)
            
            let propose = Propose(id: proposeID, payloadHash: payloadHash)
            try await propose.save(on: app.db)
            
            let firstSignature = Signature(proposeID: proposeID, publicKey: publicKey, signatureData: signature)
            try await firstSignature.save(on: app.db)
            
            // 同じ鍵で再度署名（タイムスタンプが違うだけ）
            let messageData = Data(payloadHash.utf8)
            let signature2 = try privateKey.signature(for: messageData)
            let signatureBase64_2 = signature2.derRepresentation.base64EncodedString()
            
            let updateInput = ProposeInput(
                id: proposeID,
                payloadHash: payloadHash,
                signatures: [
                    SignatureInput(publicKey: publicKey, signature: signature),
                    SignatureInput(publicKey: publicKey, signature: signatureBase64_2)
                ]
            )
            
            try await app.testing().test(.PUT, "v1/proposes/\(proposeID)", beforeRequest: { req in
                try req.content.encode(updateInput)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                
                // 署名が2つになったことを確認
                let signatures = try await Signature.query(on: app.db)
                    .filter(\.$propose.$id == proposeID)
                    .all()
                #expect(signatures.count == 2)
                
                // どちらも同じ公開鍵
                #expect(signatures.allSatisfy { $0.publicKey == publicKey })
            })
        }
    }
    
    // MARK: - Input Size Validation Tests
    
    @Test("payloadHashが256文字を超えるとエラーになる")
    func payloadHashTooLong() async throws {
        try await withApp { app in
            let proposeID = UUID()
            let longPayloadHash = String(repeating: "a", count: 257) // 257文字
            let (publicKey, signature, _) = try generateTestSignature(message: "test")
            
            let input = ProposeInput(
                id: proposeID,
                payloadHash: longPayloadHash,
                signatures: [SignatureInput(publicKey: publicKey, signature: signature)]
            )
            
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }
    
    @Test("署名が1000個を超えるとエラーになる")
    func tooManySignatures() async throws {
        try await withApp { app in
            let proposeID = UUID()
            let payloadHash = "test-payload-hash"
            
            // 1001個の署名を生成
            var signatures: [SignatureInput] = []
            for _ in 0...1000 {
                let (publicKey, signature, _) = try generateTestSignature(message: payloadHash)
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
                #expect(res.status == .badRequest)
            })
        }
    }
    
    @Test("公開鍵が500文字を超えるとエラーになる")
    func publicKeyTooLong() async throws {
        try await withApp { app in
            let proposeID = UUID()
            let payloadHash = "test-payload-hash"
            let longPublicKey = String(repeating: "a", count: 501) // 501文字
            
            let input = ProposeInput(
                id: proposeID,
                payloadHash: payloadHash,
                signatures: [SignatureInput(publicKey: longPublicKey, signature: "test")]
            )
            
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }
    
    @Test("署名データが500文字を超えるとエラーになる")
    func signatureTooLong() async throws {
        try await withApp { app in
            let proposeID = UUID()
            let payloadHash = "test-payload-hash"
            let (publicKey, _, _) = try generateTestSignature(message: payloadHash)
            let longSignature = String(repeating: "a", count: 501) // 501文字
            
            let input = ProposeInput(
                id: proposeID,
                payloadHash: payloadHash,
                signatures: [SignatureInput(publicKey: publicKey, signature: longSignature)]
            )
            
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }
    
    @Test("256文字のpayloadHashは許可される")
    func payloadHashMaxLength() async throws {
        try await withApp { app in
            let proposeID = UUID()
            let maxPayloadHash = String(repeating: "a", count: 256) // ちょうど256文字
            let (publicKey, signature, _) = try generateTestSignature(message: maxPayloadHash)
            
            let input = ProposeInput(
                id: proposeID,
                payloadHash: maxPayloadHash,
                signatures: [SignatureInput(publicKey: publicKey, signature: signature)]
            )
            
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })
        }
    }
    
    @Test("1000個の署名は許可される")
    func exactlyThousandSignatures() async throws {
        try await withApp { app in
            let proposeID = UUID()
            let payloadHash = "test-payload-hash"
            
            // ちょうど1000個の署名を生成
            var signatures: [SignatureInput] = []
            for _ in 0..<1000 {
                let (publicKey, signature, _) = try generateTestSignature(message: payloadHash)
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
                #expect(res.status == .created)
                
                // 全ての署名が保存されたか確認
                let savedSignatures = try await Signature.query(on: app.db)
                    .filter(\.$propose.$id == proposeID)
                    .all()
                #expect(savedSignatures.count == 1000)
            })
        }
    }
}
