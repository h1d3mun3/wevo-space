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
import Crypto

@Suite("ProposeController Tests", .serialized)
struct ProposeControllerTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
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
                publicKey: publicKey,
                signature: signature
            )
            
            try await app.testing().test(.POST, "proposes", beforeRequest: { req in
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
                publicKey: publicKey,
                signature: wrongSignature
            )
            
            try await app.testing().test(.POST, "proposes", beforeRequest: { req in
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
                publicKey: "invalid-base64!!!",
                signature: "invalid-signature!!!"
            )
            
            try await app.testing().test(.POST, "proposes", beforeRequest: { req in
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
            let signInput = SignInput(publicKey: publicKey2, signature: signature2)
            
            try await app.testing().test(.POST, "proposes/\(proposeID)/sign", beforeRequest: { req in
                try req.content.encode(signInput)
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
            let signInput = SignInput(publicKey: publicKey2, signature: wrongSignature)
            
            try await app.testing().test(.POST, "proposes/\(proposeID)/sign", beforeRequest: { req in
                try req.content.encode(signInput)
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
            
            let signInput = SignInput(publicKey: publicKey, signature: signature)
            
            try await app.testing().test(.POST, "proposes/\(nonExistentID)/sign", beforeRequest: { req in
                try req.content.encode(signInput)
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
            
            let signInput = SignInput(publicKey: publicKey, signature: signature)
            
            try await app.testing().test(.POST, "proposes/invalid-uuid/sign", beforeRequest: { req in
                try req.content.encode(signInput)
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
            
            let signInput = SignInput(publicKey: publicKey, signature: signatureBase64_2)
            
            try await app.testing().test(.POST, "proposes/\(proposeID)/sign", beforeRequest: { req in
                try req.content.encode(signInput)
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
}
