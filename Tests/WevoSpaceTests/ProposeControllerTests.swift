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
            app.databases.use(.sqlite(.memory), as: .sqlite)
            app.migrations.add(CreateProposesTable())
            try await app.autoMigrate()
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

    // MARK: - Helpers

    private struct KeyPair {
        let privateKey: P256.Signing.PrivateKey
        let publicKeyBase64: String

        init() {
            privateKey = P256.Signing.PrivateKey()
            publicKeyBase64 = privateKey.publicKey.x963Representation.base64EncodedString()
        }

        func sign(_ message: String) throws -> String {
            let data = Data(message.utf8)
            let sig = try privateKey.signature(for: data)
            return sig.derRepresentation.base64EncodedString()
        }
    }

    /// Encodes a Base64 public key for use as a URL query parameter (encodes + as %2B)
    private func encodePublicKey(_ key: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+")
        return key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
    }

    /// Creates a Propose for testing and returns its key data
    private func createPropose(
        app: Application,
        proposeId: UUID = UUID(),
        contentHash: String = "test-content-hash",
        createdAt: String = "2026-01-01T00:00:00Z",
        creatorKeyPair: KeyPair = KeyPair(),
        counterpartyKeyPair: KeyPair = KeyPair()
    ) async throws -> (proposeId: UUID, contentHash: String, createdAt: String, creator: KeyPair, counterparty: KeyPair) {
        let message = proposeId.uuidString + contentHash + counterpartyKeyPair.publicKeyBase64 + createdAt
        let creatorSig = try creatorKeyPair.sign(message)

        let input = CreateProposeInput(
            proposeId: proposeId.uuidString,
            contentHash: contentHash,
            creatorPublicKey: creatorKeyPair.publicKeyBase64,
            creatorSignature: creatorSig,
            counterpartyPublicKey: counterpartyKeyPair.publicKeyBase64,
            createdAt: createdAt
        )

        try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
            try req.content.encode(input)
        }, afterResponse: { res async throws in
            #expect(res.status == .created)
        })

        return (proposeId, contentHash, createdAt, creatorKeyPair, counterpartyKeyPair)
    }

    // MARK: - POST /v1/proposes

    @Test("正常なProposeを作成できる")
    func createProposeSuccess() async throws {
        try await withApp { app in
            let proposeId = UUID()
            let contentHash = "test-hash"
            let createdAt = "2026-01-01T00:00:00Z"
            let creator = KeyPair()
            let counterparty = KeyPair()

            let message = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let creatorSig = try creator.sign(message)

            let input = CreateProposeInput(
                proposeId: proposeId.uuidString,
                contentHash: contentHash,
                creatorPublicKey: creator.publicKeyBase64,
                creatorSignature: creatorSig,
                counterpartyPublicKey: counterparty.publicKeyBase64,
                createdAt: createdAt
            )

            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)

                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose != nil)
                #expect(propose?.contentHash == contentHash)
                #expect(propose?.proposeStatus == .proposed)
                #expect(propose?.creatorPublicKey == creator.publicKeyBase64)
                #expect(propose?.counterpartyPublicKey == counterparty.publicKeyBase64)
            })
        }
    }

    @Test("不正な署名でProposeを作成するとエラーになる")
    func createProposeWithInvalidSignature() async throws {
        try await withApp { app in
            let proposeId = UUID()
            let contentHash = "test-hash"
            let creator = KeyPair()
            let counterparty = KeyPair()
            let wrongSig = try creator.sign("wrong-message")

            let input = CreateProposeInput(
                proposeId: proposeId.uuidString,
                contentHash: contentHash,
                creatorPublicKey: creator.publicKeyBase64,
                creatorSignature: wrongSig,
                counterpartyPublicKey: counterparty.publicKeyBase64,
                createdAt: "2026-01-01T00:00:00Z"
            )

            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose == nil)
            })
        }
    }

    @Test("同じIDのProposeを重複作成するとエラーになる")
    func createDuplicateProposeReturnsConflict() async throws {
        try await withApp { app in
            let proposeId = UUID()
            let contentHash = "test-hash"
            let createdAt = "2026-01-01T00:00:00Z"
            let creator = KeyPair()
            let counterparty = KeyPair()

            let message = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let creatorSig = try creator.sign(message)

            let input = CreateProposeInput(
                proposeId: proposeId.uuidString,
                contentHash: contentHash,
                creatorPublicKey: creator.publicKeyBase64,
                creatorSignature: creatorSig,
                counterpartyPublicKey: counterparty.publicKeyBase64,
                createdAt: createdAt
            )

            // 1回目は成功
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            // 2回目は409 Conflict
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
            })
        }
    }

    @Test("不正なproposeIdの形式でエラーになる")
    func createProposeWithInvalidIdFormat() async throws {
        try await withApp { app in
            let creator = KeyPair()
            let counterparty = KeyPair()
            let input = CreateProposeInput(
                proposeId: "not-a-uuid",
                contentHash: "test-hash",
                creatorPublicKey: creator.publicKeyBase64,
                creatorSignature: "dummy",
                counterpartyPublicKey: counterparty.publicKeyBase64,
                createdAt: "2026-01-01T00:00:00Z"
            )

            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    // MARK: - GET /v1/proposes/:id

    @Test("既存のProposeをIDで取得できる")
    func getOnePropose() async throws {
        try await withApp { app in
            let (proposeId, contentHash, _, _, _) = try await createPropose(app: app)

            try await app.testing().test(.GET, "v1/proposes/\(proposeId)", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let propose = try res.content.decode(Propose.self)
                #expect(propose.id == proposeId)
                #expect(propose.contentHash == contentHash)
                #expect(propose.proposeStatus == .proposed)
            })
        }
    }

    @Test("存在しないIDで404になる")
    func getOneNotFound() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/proposes/\(UUID())", afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("無効なUUID形式で詳細取得すると400になる")
    func getOneWithInvalidUUIDReturnsBadRequest() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/proposes/not-a-uuid", afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    // MARK: - GET /v1/proposes?publicKey=...&status=...

    @Test("publicKeyなしでリスト取得すると400になる")
    func listWithoutPublicKeyReturnsBadRequest() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/proposes", afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("publicKeyでProposeを検索できる（creator）")
    func listByCreatorPublicKey() async throws {
        try await withApp { app in
            let creator = KeyPair()
            let counterparty = KeyPair()
            try await createPropose(app: app, creatorKeyPair: creator, counterpartyKeyPair: counterparty)

            let encodedKey = encodePublicKey(creator.publicKeyBase64)

            try await app.testing().test(.GET, "v1/proposes?publicKey=\(encodedKey)", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let page = try res.content.decode(Page<Propose>.self)
                #expect(page.items.count == 1)
            })
        }
    }

    @Test("publicKeyでProposeを検索できる（counterparty）")
    func listByCounterpartyPublicKey() async throws {
        try await withApp { app in
            let creator = KeyPair()
            let counterparty = KeyPair()
            try await createPropose(app: app, creatorKeyPair: creator, counterpartyKeyPair: counterparty)

            let encodedKey = encodePublicKey(counterparty.publicKeyBase64)

            try await app.testing().test(.GET, "v1/proposes?publicKey=\(encodedKey)", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let page = try res.content.decode(Page<Propose>.self)
                #expect(page.items.count == 1)
            })
        }
    }

    @Test("statusフィルタで絞り込みができる")
    func listFilterByStatus() async throws {
        try await withApp { app in
            let creator = KeyPair()
            let counterparty = KeyPair()
            let (proposeId, contentHash, createdAt, _, counterpartyKP) = try await createPropose(
                app: app,
                creatorKeyPair: creator,
                counterpartyKeyPair: counterparty
            )

            // proposed → signed へ遷移させる
            let signMessage = proposeId.uuidString + contentHash + counterpartyKP.publicKeyBase64 + createdAt
            let counterpartySig = try counterpartyKP.sign(signMessage)
            let signInput = SignInput(counterpartySignature: counterpartySig, createdAt: createdAt)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(signInput)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let encodedKey = encodePublicKey(creator.publicKeyBase64)

            // proposed フィルタ → 0件
            try await app.testing().test(.GET, "v1/proposes?publicKey=\(encodedKey)&status=proposed", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let page = try res.content.decode(Page<Propose>.self)
                #expect(page.items.count == 0)
            })

            // signed フィルタ → 1件
            try await app.testing().test(.GET, "v1/proposes?publicKey=\(encodedKey)&status=signed", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let page = try res.content.decode(Page<Propose>.self)
                #expect(page.items.count == 1)
            })

            // proposed,signed フィルタ → 1件
            try await app.testing().test(.GET, "v1/proposes?publicKey=\(encodedKey)&status=proposed,signed", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let page = try res.content.decode(Page<Propose>.self)
                #expect(page.items.count == 1)
            })
        }
    }

    // MARK: - PATCH /v1/proposes/:id/sign

    @Test("counterpartyが署名するとsigned状態になる")
    func signProposeSuccess() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, _, counterparty) = try await createPropose(app: app)

            let message = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let sig = try counterparty.sign(message)
            let input = SignInput(counterpartySignature: sig, createdAt: createdAt)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .signed)
                #expect(propose?.counterpartySignature == sig)
            })
        }
    }

    @Test("不正な署名でsignするとエラーになる")
    func signProposeWithInvalidSignature() async throws {
        try await withApp { app in
            let (proposeId, _, createdAt, _, counterparty) = try await createPropose(app: app)

            let wrongSig = try counterparty.sign("wrong-message")
            let input = SignInput(counterpartySignature: wrongSig, createdAt: createdAt)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)

                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .proposed)
            })
        }
    }

    @Test("createdAtが一致しないとエラーになる")
    func signProposeWithWrongCreatedAt() async throws {
        try await withApp { app in
            let (proposeId, contentHash, _, _, counterparty) = try await createPropose(app: app)

            let wrongCreatedAt = "2099-01-01T00:00:00Z"
            let message = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + wrongCreatedAt
            let sig = try counterparty.sign(message)
            let input = SignInput(counterpartySignature: sig, createdAt: wrongCreatedAt)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("存在しないProposeをsignすると404になる")
    func signNonExistentProposeReturnsNotFound() async throws {
        try await withApp { app in
            let proposeId = UUID()
            let input = SignInput(counterpartySignature: "dummy", createdAt: "2026-01-01T00:00:00Z")

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("proposed以外の状態でsignするとエラーになる")
    func signNonProposedProposeReturnsConflict() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, _, counterparty) = try await createPropose(app: app)

            // 1回目のsign（proposed → signed）
            let message = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let sig = try counterparty.sign(message)
            let input = SignInput(counterpartySignature: sig, createdAt: createdAt)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            // 2回目のsign → conflict
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
            })
        }
    }

    // MARK: - DELETE /v1/proposes/:id (dissolve)

    @Test("creatorがdissolveできる")
    func dissolveByCreator() async throws {
        try await withApp { app in
            let (proposeId, contentHash, _, creator, _) = try await createPropose(app: app)

            let timestamp = "2026-01-02T00:00:00Z"
            let message = "dissolved." + proposeId.uuidString + contentHash + timestamp
            let sig = try creator.sign(message)
            let input = TransitionInput(publicKey: creator.publicKeyBase64, signature: sig, timestamp: timestamp)

            try await app.testing().test(.DELETE, "v1/proposes/\(proposeId)", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .dissolved)
            })
        }
    }

    @Test("counterpartyがdissolveできる")
    func dissolveByCounterparty() async throws {
        try await withApp { app in
            let (proposeId, contentHash, _, _, counterparty) = try await createPropose(app: app)

            let timestamp = "2026-01-02T00:00:00Z"
            let message = "dissolved." + proposeId.uuidString + contentHash + timestamp
            let sig = try counterparty.sign(message)
            let input = TransitionInput(publicKey: counterparty.publicKeyBase64, signature: sig, timestamp: timestamp)

            try await app.testing().test(.DELETE, "v1/proposes/\(proposeId)", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .dissolved)
            })
        }
    }

    @Test("存在しないProposeをdissolveすると404になる")
    func dissolveNonExistentProposeReturnsNotFound() async throws {
        try await withApp { app in
            let actor = KeyPair()
            let proposeId = UUID()
            let timestamp = "2026-01-02T00:00:00Z"
            let message = "dissolved." + proposeId.uuidString + "hash" + timestamp
            let sig = try actor.sign(message)
            let input = TransitionInput(publicKey: actor.publicKeyBase64, signature: sig, timestamp: timestamp)

            try await app.testing().test(.DELETE, "v1/proposes/\(proposeId)", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("不正な署名でdissolveするとエラーになる（参加者の鍵で誤ったメッセージ）")
    func dissolveWithInvalidSignatureReturnsUnauthorized() async throws {
        try await withApp { app in
            let (proposeId, _, _, creator, _) = try await createPropose(app: app)

            let timestamp = "2026-01-02T00:00:00Z"
            let wrongSig = try creator.sign("wrong-message")
            let input = TransitionInput(publicKey: creator.publicKeyBase64, signature: wrongSig, timestamp: timestamp)

            try await app.testing().test(.DELETE, "v1/proposes/\(proposeId)", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)

                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .proposed)
            })
        }
    }

    @Test("第三者がdissolveしようとすると403になる")
    func dissolveByThirdPartyReturnsForbidden() async throws {
        try await withApp { app in
            let (proposeId, contentHash, _, _, _) = try await createPropose(app: app)

            let thirdParty = KeyPair()
            let timestamp = "2026-01-02T00:00:00Z"
            let message = "dissolved." + proposeId.uuidString + contentHash + timestamp
            let sig = try thirdParty.sign(message)
            let input = TransitionInput(publicKey: thirdParty.publicKeyBase64, signature: sig, timestamp: timestamp)

            try await app.testing().test(.DELETE, "v1/proposes/\(proposeId)", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("signed状態のProposeはdissolveできない")
    func dissolveSignedProposeReturnsConflict() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(counterpartySignature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            // dissolve試行 → conflict
            let timestamp = "2026-01-02T00:00:00Z"
            let dissolveMessage = "dissolved." + proposeId.uuidString + contentHash + timestamp
            let dissolveSig = try creator.sign(dissolveMessage)
            let input = TransitionInput(publicKey: creator.publicKeyBase64, signature: dissolveSig, timestamp: timestamp)

            try await app.testing().test(.DELETE, "v1/proposes/\(proposeId)", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
            })
        }
    }

    // MARK: - PATCH /v1/proposes/:id/honor

    @Test("両者がhonor署名するとhonored状態になる")
    func honorBothPartiesSuccess() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(counterpartySignature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let timestamp = "2026-01-03T00:00:00Z"
            let honorMessage = "honored." + proposeId.uuidString + contentHash + timestamp

            // creatorがhonor
            let creatorHonorSig = try creator.sign(honorMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/honor", beforeRequest: { req in
                try req.content.encode(TransitionInput(publicKey: creator.publicKeyBase64, signature: creatorHonorSig, timestamp: timestamp))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                // まだsigned
                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .signed)
            })

            // counterpartyがhonor → honored
            let counterpartyHonorSig = try counterparty.sign(honorMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/honor", beforeRequest: { req in
                try req.content.encode(TransitionInput(publicKey: counterparty.publicKeyBase64, signature: counterpartyHonorSig, timestamp: timestamp))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .honored)
            })
        }
    }

    @Test("第三者がhonorしようとすると403になる")
    func honorByThirdPartyReturnsForbidden() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, _, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(counterpartySignature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let thirdParty = KeyPair()
            let timestamp = "2026-01-03T00:00:00Z"
            let message = "honored." + proposeId.uuidString + contentHash + timestamp
            let sig = try thirdParty.sign(message)
            let input = TransitionInput(publicKey: thirdParty.publicKeyBase64, signature: sig, timestamp: timestamp)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/honor", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("不正な署名でhonorするとエラーになる")
    func honorWithInvalidSignatureReturnsUnauthorized() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(counterpartySignature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let timestamp = "2026-01-03T00:00:00Z"
            let wrongSig = try creator.sign("wrong-message")
            let input = TransitionInput(publicKey: creator.publicKeyBase64, signature: wrongSig, timestamp: timestamp)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/honor", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("存在しないProposeをhonorすると404になる")
    func honorNonExistentProposeReturnsNotFound() async throws {
        try await withApp { app in
            let creator = KeyPair()
            let proposeId = UUID()
            let timestamp = "2026-01-03T00:00:00Z"
            let message = "honored." + proposeId.uuidString + "hash" + timestamp
            let sig = try creator.sign(message)
            let input = TransitionInput(publicKey: creator.publicKeyBase64, signature: sig, timestamp: timestamp)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/honor", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("proposed状態のProposeはhonorできない")
    func honorProposedProposeReturnsConflict() async throws {
        try await withApp { app in
            let (proposeId, contentHash, _, creator, _) = try await createPropose(app: app)

            let timestamp = "2026-01-03T00:00:00Z"
            let message = "honored." + proposeId.uuidString + contentHash + timestamp
            let sig = try creator.sign(message)
            let input = TransitionInput(publicKey: creator.publicKeyBase64, signature: sig, timestamp: timestamp)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/honor", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
            })
        }
    }

    // MARK: - PATCH /v1/proposes/:id/part

    @Test("両者がpart署名するとparted状態になる")
    func partBothPartiesSuccess() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(counterpartySignature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let timestamp = "2026-01-03T00:00:00Z"
            let partMessage = "parted." + proposeId.uuidString + contentHash + timestamp

            // creatorがpart
            let creatorPartSig = try creator.sign(partMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/part", beforeRequest: { req in
                try req.content.encode(TransitionInput(publicKey: creator.publicKeyBase64, signature: creatorPartSig, timestamp: timestamp))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .signed)
            })

            // counterpartyがpart → parted
            let counterpartyPartSig = try counterparty.sign(partMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/part", beforeRequest: { req in
                try req.content.encode(TransitionInput(publicKey: counterparty.publicKeyBase64, signature: counterpartyPartSig, timestamp: timestamp))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .parted)
            })
        }
    }

    @Test("不正な署名でpartするとエラーになる")
    func partWithInvalidSignatureReturnsUnauthorized() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(counterpartySignature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let timestamp = "2026-01-03T00:00:00Z"
            let wrongSig = try creator.sign("wrong-message")
            let input = TransitionInput(publicKey: creator.publicKeyBase64, signature: wrongSig, timestamp: timestamp)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/part", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("存在しないProposeをpartすると404になる")
    func partNonExistentProposeReturnsNotFound() async throws {
        try await withApp { app in
            let creator = KeyPair()
            let proposeId = UUID()
            let timestamp = "2026-01-03T00:00:00Z"
            let message = "parted." + proposeId.uuidString + "hash" + timestamp
            let sig = try creator.sign(message)
            let input = TransitionInput(publicKey: creator.publicKeyBase64, signature: sig, timestamp: timestamp)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/part", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("proposed状態のProposeはpartできない")
    func partProposedProposeReturnsConflict() async throws {
        try await withApp { app in
            let (proposeId, contentHash, _, creator, _) = try await createPropose(app: app)

            let timestamp = "2026-01-03T00:00:00Z"
            let message = "parted." + proposeId.uuidString + contentHash + timestamp
            let sig = try creator.sign(message)
            let input = TransitionInput(publicKey: creator.publicKeyBase64, signature: sig, timestamp: timestamp)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/part", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
            })
        }
    }

    @Test("同一参加者が二回目のpart署名を送信してもエラーにならない")
    func partSamePartyTwiceIsAccepted() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(counterpartySignature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let timestamp = "2026-01-03T00:00:00Z"
            let partMessage = "parted." + proposeId.uuidString + contentHash + timestamp
            let creatorPartSig = try creator.sign(partMessage)
            let input = TransitionInput(publicKey: creator.publicKeyBase64, signature: creatorPartSig, timestamp: timestamp)

            // 1回目（counterparty未送信なのでまだsigned）
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/part", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .signed)
            })

            // 2回目（署名を上書き送信。まだparted未完のためsigned状態のまま受け付けられる）
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/part", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .signed)
            })
        }
    }

    @Test("第三者がpartしようとすると403になる")
    func partByThirdPartyReturnsForbidden() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, _, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(counterpartySignature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let thirdParty = KeyPair()
            let timestamp = "2026-01-03T00:00:00Z"
            let message = "parted." + proposeId.uuidString + contentHash + timestamp
            let sig = try thirdParty.sign(message)
            let input = TransitionInput(publicKey: thirdParty.publicKeyBase64, signature: sig, timestamp: timestamp)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/part", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .forbidden)
            })
        }
    }

    // MARK: - 終端状態からの不正遷移

    @Test("honored状態のProposeはdissolveできない")
    func dissolveHonoredProposeReturnsConflict() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(counterpartySignature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in #expect(res.status == .ok) })

            // signed → honored
            let timestamp = "2026-01-03T00:00:00Z"
            let honorMessage = "honored." + proposeId.uuidString + contentHash + timestamp
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/honor", beforeRequest: { req in
                try req.content.encode(TransitionInput(publicKey: creator.publicKeyBase64, signature: try creator.sign(honorMessage), timestamp: timestamp))
            }, afterResponse: { res async throws in #expect(res.status == .ok) })
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/honor", beforeRequest: { req in
                try req.content.encode(TransitionInput(publicKey: counterparty.publicKeyBase64, signature: try counterparty.sign(honorMessage), timestamp: timestamp))
            }, afterResponse: { res async throws in #expect(res.status == .ok) })

            // honored → dissolve試行 → conflict
            let dissolveTimestamp = "2026-01-04T00:00:00Z"
            let dissolveMessage = "dissolved." + proposeId.uuidString + contentHash + dissolveTimestamp
            let input = TransitionInput(publicKey: creator.publicKeyBase64, signature: try creator.sign(dissolveMessage), timestamp: dissolveTimestamp)

            try await app.testing().test(.DELETE, "v1/proposes/\(proposeId)", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
            })
        }
    }

    @Test("parted状態のProposeはsignできない")
    func signPartedProposeReturnsConflict() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(counterpartySignature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in #expect(res.status == .ok) })

            // signed → parted
            let timestamp = "2026-01-03T00:00:00Z"
            let partMessage = "parted." + proposeId.uuidString + contentHash + timestamp
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/part", beforeRequest: { req in
                try req.content.encode(TransitionInput(publicKey: creator.publicKeyBase64, signature: try creator.sign(partMessage), timestamp: timestamp))
            }, afterResponse: { res async throws in #expect(res.status == .ok) })
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/part", beforeRequest: { req in
                try req.content.encode(TransitionInput(publicKey: counterparty.publicKeyBase64, signature: try counterparty.sign(partMessage), timestamp: timestamp))
            }, afterResponse: { res async throws in #expect(res.status == .ok) })

            // parted → sign試行 → conflict
            let newSig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(counterpartySignature: newSig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
            })
        }
    }

    @Test("dissolved状態のProposeはsignできない")
    func signDissolvedProposeReturnsConflict() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → dissolved
            let dissolveTimestamp = "2026-01-02T00:00:00Z"
            let dissolveMessage = "dissolved." + proposeId.uuidString + contentHash + dissolveTimestamp
            let dissolveInput = TransitionInput(publicKey: creator.publicKeyBase64, signature: try creator.sign(dissolveMessage), timestamp: dissolveTimestamp)
            try await app.testing().test(.DELETE, "v1/proposes/\(proposeId)", beforeRequest: { req in
                try req.content.encode(dissolveInput)
            }, afterResponse: { res async throws in #expect(res.status == .ok) })

            // dissolved → sign試行 → conflict
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let sig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(counterpartySignature: sig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
            })
        }
    }
}
