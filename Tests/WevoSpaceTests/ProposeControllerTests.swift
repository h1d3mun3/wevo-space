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
            app.migrations.add(CreateCounterpartiesTable())
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
        // Single counterparty: sorted().joined() == publicKeyBase64
        let message = proposeId.uuidString + contentHash + counterpartyKeyPair.publicKeyBase64 + createdAt
        let creatorSig = try creatorKeyPair.sign(message)

        let input = CreateProposeInput(
            proposeId: proposeId.uuidString,
            contentHash: contentHash,
            creatorPublicKey: creatorKeyPair.publicKeyBase64,
            creatorSignature: creatorSig,
            counterpartyPublicKeys: [counterpartyKeyPair.publicKeyBase64],
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

    @Test("Can create a valid Propose")
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
                counterpartyPublicKeys: [counterparty.publicKeyBase64],
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

                let counterparties = try await ProposeCounterparty.query(on: app.db)
                    .filter(\.$publicKey == counterparty.publicKeyBase64)
                    .all()
                #expect(counterparties.count == 1)
            })
        }
    }

    @Test("Creating a Propose with an invalid signature returns an error")
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
                counterpartyPublicKeys: [counterparty.publicKeyBase64],
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

    @Test("Duplicate Propose creation with the same ID returns an error")
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
                counterpartyPublicKeys: [counterparty.publicKeyBase64],
                createdAt: createdAt
            )

            // First request succeeds
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            // Second request returns 409 Conflict
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
            })
        }
    }

    @Test("Invalid proposeId format returns an error")
    func createProposeWithInvalidIdFormat() async throws {
        try await withApp { app in
            let creator = KeyPair()
            let counterparty = KeyPair()
            let input = CreateProposeInput(
                proposeId: "not-a-uuid",
                contentHash: "test-hash",
                creatorPublicKey: creator.publicKeyBase64,
                creatorSignature: "dummy",
                counterpartyPublicKeys: [counterparty.publicKeyBase64],
                createdAt: "2026-01-01T00:00:00Z"
            )

            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Empty counterpartyPublicKeys returns an error")
    func createProposeWithEmptyCounterpartiesReturnsBadRequest() async throws {
        try await withApp { app in
            let proposeId = UUID()
            let creator = KeyPair()
            let input = CreateProposeInput(
                proposeId: proposeId.uuidString,
                contentHash: "test-hash",
                creatorPublicKey: creator.publicKeyBase64,
                creatorSignature: "dummy",
                counterpartyPublicKeys: [],
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

    @Test("Can retrieve an existing Propose by ID")
    func getOnePropose() async throws {
        try await withApp { app in
            let (proposeId, contentHash, _, _, _) = try await createPropose(app: app)

            try await app.testing().test(.GET, "v1/proposes/\(proposeId)", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let propose = try res.content.decode(ProposeResponse.self)
                #expect(propose.id == proposeId)
                #expect(propose.contentHash == contentHash)
                #expect(propose.status == ProposeStatus.proposed.rawValue)
            })
        }
    }

    @Test("Non-existent ID returns 404")
    func getOneNotFound() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/proposes/\(UUID())", afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("Fetching detail with invalid UUID format returns 400")
    func getOneWithInvalidUUIDReturnsBadRequest() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/proposes/not-a-uuid", afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    // MARK: - GET /v1/proposes?publicKey=...&status=...

    @Test("Listing without publicKey returns 400")
    func listWithoutPublicKeyReturnsBadRequest() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/proposes", afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Can search Proposes by publicKey (creator)")
    func listByCreatorPublicKey() async throws {
        try await withApp { app in
            let creator = KeyPair()
            let counterparty = KeyPair()
            try await createPropose(app: app, creatorKeyPair: creator, counterpartyKeyPair: counterparty)

            let encodedKey = encodePublicKey(creator.publicKeyBase64)

            try await app.testing().test(.GET, "v1/proposes?publicKey=\(encodedKey)", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let page = try res.content.decode(Page<ProposeResponse>.self)
                #expect(page.items.count == 1)
            })
        }
    }

    @Test("Can search Proposes by publicKey (counterparty)")
    func listByCounterpartyPublicKey() async throws {
        try await withApp { app in
            let creator = KeyPair()
            let counterparty = KeyPair()
            try await createPropose(app: app, creatorKeyPair: creator, counterpartyKeyPair: counterparty)

            let encodedKey = encodePublicKey(counterparty.publicKeyBase64)

            try await app.testing().test(.GET, "v1/proposes?publicKey=\(encodedKey)", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let page = try res.content.decode(Page<ProposeResponse>.self)
                #expect(page.items.count == 1)
            })
        }
    }

    @Test("Can filter by status")
    func listFilterByStatus() async throws {
        try await withApp { app in
            let creator = KeyPair()
            let counterparty = KeyPair()
            let (proposeId, contentHash, createdAt, _, counterpartyKP) = try await createPropose(
                app: app,
                creatorKeyPair: creator,
                counterpartyKeyPair: counterparty
            )

            // Transition from proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterpartyKP.publicKeyBase64 + createdAt
            let counterpartySig = try counterpartyKP.sign(signMessage)
            let signInput = SignInput(signerPublicKey: counterpartyKP.publicKeyBase64, signature: counterpartySig, createdAt: createdAt)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(signInput)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let encodedKey = encodePublicKey(creator.publicKeyBase64)

            // proposed filter → 0 results
            try await app.testing().test(.GET, "v1/proposes?publicKey=\(encodedKey)&status=proposed", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let page = try res.content.decode(Page<ProposeResponse>.self)
                #expect(page.items.count == 0)
            })

            // signed filter → 1 result
            try await app.testing().test(.GET, "v1/proposes?publicKey=\(encodedKey)&status=signed", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let page = try res.content.decode(Page<ProposeResponse>.self)
                #expect(page.items.count == 1)
            })

            // proposed,signed filter → 1 result
            try await app.testing().test(.GET, "v1/proposes?publicKey=\(encodedKey)&status=proposed,signed", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let page = try res.content.decode(Page<ProposeResponse>.self)
                #expect(page.items.count == 1)
            })
        }
    }

    // MARK: - PATCH /v1/proposes/:id/sign

    @Test("Counterparty signing transitions to signed state")
    func signProposeSuccess() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, _, counterparty) = try await createPropose(app: app)

            // sign message: proposeId + contentHash + signerPublicKey + createdAt
            let message = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let sig = try counterparty.sign(message)
            let input = SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: sig, createdAt: createdAt)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)

                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .signed)

                let cp = try await ProposeCounterparty.query(on: app.db)
                    .filter(\.$publicKey == counterparty.publicKeyBase64)
                    .first()
                #expect(cp?.signSignature == sig)
            })
        }
    }

    @Test("Signing with an invalid signature returns an error")
    func signProposeWithInvalidSignature() async throws {
        try await withApp { app in
            let (proposeId, _, createdAt, _, counterparty) = try await createPropose(app: app)

            let wrongSig = try counterparty.sign("wrong-message")
            let input = SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: wrongSig, createdAt: createdAt)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)

                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .proposed)
            })
        }
    }

    @Test("Mismatched createdAt returns an error")
    func signProposeWithWrongCreatedAt() async throws {
        try await withApp { app in
            let (proposeId, contentHash, _, _, counterparty) = try await createPropose(app: app)

            let wrongCreatedAt = "2099-01-01T00:00:00Z"
            let message = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + wrongCreatedAt
            let sig = try counterparty.sign(message)
            let input = SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: sig, createdAt: wrongCreatedAt)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Signing a non-existent Propose returns 404")
    func signNonExistentProposeReturnsNotFound() async throws {
        try await withApp { app in
            let proposeId = UUID()
            let input = SignInput(signerPublicKey: "dummy-key", signature: "dummy-sig", createdAt: "2026-01-01T00:00:00Z")

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("Non-counterparty signing returns 403")
    func signByNonCounterpartyReturnsForbidden() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, _, _) = try await createPropose(app: app)

            let thirdParty = KeyPair()
            let message = proposeId.uuidString + contentHash + thirdParty.publicKeyBase64 + createdAt
            let sig = try thirdParty.sign(message)
            let input = SignInput(signerPublicKey: thirdParty.publicKeyBase64, signature: sig, createdAt: createdAt)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .forbidden)
            })
        }
    }

    @Test("Signing a Propose in a non-proposed state returns an error")
    func signNonProposedProposeReturnsConflict() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, _, counterparty) = try await createPropose(app: app)

            // First sign (proposed → signed)
            let message = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let sig = try counterparty.sign(message)
            let input = SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: sig, createdAt: createdAt)

            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            // Second sign → conflict (already in signed state)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
            })
        }
    }

    // MARK: - DELETE /v1/proposes/:id (dissolve)

    @Test("Creator can dissolve")
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

    @Test("Counterparty can dissolve")
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

    @Test("Dissolving a non-existent Propose returns 404")
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

    @Test("Dissolving with an invalid signature returns an error (wrong message signed by participant key)")
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

    @Test("Third party attempting to dissolve returns 403")
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

    @Test("A Propose in signed state cannot be dissolved")
    func dissolveSignedProposeReturnsConflict() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            // Dissolve attempt → conflict
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

    @Test("Both parties honoring transitions to honored state")
    func honorBothPartiesSuccess() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let timestamp = "2026-01-03T00:00:00Z"
            let honorMessage = "honored." + proposeId.uuidString + contentHash + timestamp

            // Creator honors
            let creatorHonorSig = try creator.sign(honorMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/honor", beforeRequest: { req in
                try req.content.encode(TransitionInput(publicKey: creator.publicKeyBase64, signature: creatorHonorSig, timestamp: timestamp))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                // Still signed
                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .signed)
            })

            // Counterparty honors → honored
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

    @Test("Third party attempting to honor returns 403")
    func honorByThirdPartyReturnsForbidden() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, _, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: counterpartySig, createdAt: createdAt))
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

    @Test("Honoring with an invalid signature returns an error")
    func honorWithInvalidSignatureReturnsUnauthorized() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: counterpartySig, createdAt: createdAt))
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

    @Test("Honoring a non-existent Propose returns 404")
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

    @Test("A Propose in proposed state cannot be honored")
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

    @Test("Creator parting immediately transitions to parted state")
    func partByCreatorImmediatelyTransitionsToParted() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let timestamp = "2026-01-03T00:00:00Z"
            let partMessage = "parted." + proposeId.uuidString + contentHash + timestamp

            // Creator parts → immediately parted
            let creatorPartSig = try creator.sign(partMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/part", beforeRequest: { req in
                try req.content.encode(TransitionInput(publicKey: creator.publicKeyBase64, signature: creatorPartSig, timestamp: timestamp))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .parted)
            })
        }
    }

    @Test("Counterparty parting immediately transitions to parted state")
    func partByCounterpartyImmediatelyTransitionsToParted() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, _, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let timestamp = "2026-01-03T00:00:00Z"
            let partMessage = "parted." + proposeId.uuidString + contentHash + timestamp

            // Counterparty parts → immediately parted
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

    @Test("Parting with an invalid signature returns an error")
    func partWithInvalidSignatureReturnsUnauthorized() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: counterpartySig, createdAt: createdAt))
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

    @Test("Parting a non-existent Propose returns 404")
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

    @Test("A Propose in proposed state cannot be parted")
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

    @Test("A second part request after already parted returns 409")
    func partAlreadyPartedReturnsConflict() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let timestamp = "2026-01-03T00:00:00Z"
            let partMessage = "parted." + proposeId.uuidString + contentHash + timestamp
            let creatorPartSig = try creator.sign(partMessage)
            let input = TransitionInput(publicKey: creator.publicKeyBase64, signature: creatorPartSig, timestamp: timestamp)

            // First part → immediately parted
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/part", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .parted)
            })

            // Second part → 409 conflict (already parted)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/part", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
            })
        }
    }

    @Test("Third party attempting to part returns 403")
    func partByThirdPartyReturnsForbidden() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, _, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: counterpartySig, createdAt: createdAt))
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

    // MARK: - Invalid transitions from terminal states

    @Test("A Propose in honored state cannot be dissolved")
    func dissolveHonoredProposeReturnsConflict() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: counterpartySig, createdAt: createdAt))
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

            // honored → dissolve attempt → conflict
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

    @Test("A Propose in parted state cannot be signed")
    func signPartedProposeReturnsConflict() async throws {
        try await withApp { app in
            let (proposeId, contentHash, createdAt, creator, counterparty) = try await createPropose(app: app)

            // proposed → signed
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let counterpartySig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: counterpartySig, createdAt: createdAt))
            }, afterResponse: { res async throws in #expect(res.status == .ok) })

            // signed → parted
            let timestamp = "2026-01-03T00:00:00Z"
            let partMessage = "parted." + proposeId.uuidString + contentHash + timestamp
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/part", beforeRequest: { req in
                try req.content.encode(TransitionInput(publicKey: creator.publicKeyBase64, signature: try creator.sign(partMessage), timestamp: timestamp))
            }, afterResponse: { res async throws in #expect(res.status == .ok) })

            // parted → sign attempt → conflict
            let newSig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: newSig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
            })
        }
    }

    // MARK: - Multiple counterparties (1:n)

    @Test("Two counterparties both signing transitions to signed state")
    func signWithTwoCounterpartiesTransitionsToSigned() async throws {
        try await withApp { app in
            let proposeId = UUID()
            let contentHash = "test-content-hash"
            let createdAt = "2026-01-01T00:00:00Z"
            let creator = KeyPair()
            let counterparty1 = KeyPair()
            let counterparty2 = KeyPair()

            // Signature message: counterpartyPublicKeys sorted & joined
            let sortedKeys = [counterparty1.publicKeyBase64, counterparty2.publicKeyBase64].sorted().joined()
            let createMessage = proposeId.uuidString + contentHash + sortedKeys + createdAt
            let creatorSig = try creator.sign(createMessage)

            let createInput = CreateProposeInput(
                proposeId: proposeId.uuidString,
                contentHash: contentHash,
                creatorPublicKey: creator.publicKeyBase64,
                creatorSignature: creatorSig,
                counterpartyPublicKeys: [counterparty1.publicKeyBase64, counterparty2.publicKeyBase64],
                createdAt: createdAt
            )
            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(createInput)
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
            })

            // counterparty1 signs → still proposed (counterparty2 has not signed)
            let sign1Message = proposeId.uuidString + contentHash + counterparty1.publicKeyBase64 + createdAt
            let sig1 = try counterparty1.sign(sign1Message)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(signerPublicKey: counterparty1.publicKeyBase64, signature: sig1, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .proposed)
            })

            // counterparty2 signs → transitions to signed
            let sign2Message = proposeId.uuidString + contentHash + counterparty2.publicKeyBase64 + createdAt
            let sig2 = try counterparty2.sign(sign2Message)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(signerPublicKey: counterparty2.publicKeyBase64, signature: sig2, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let propose = try await Propose.find(proposeId, on: app.db)
                #expect(propose?.proposeStatus == .signed)
            })
        }
    }

    @Test("A Propose in dissolved state cannot be signed")
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

            // dissolved → sign attempt → conflict
            let signMessage = proposeId.uuidString + contentHash + counterparty.publicKeyBase64 + createdAt
            let sig = try counterparty.sign(signMessage)
            try await app.testing().test(.PATCH, "v1/proposes/\(proposeId)/sign", beforeRequest: { req in
                try req.content.encode(SignInput(signerPublicKey: counterparty.publicKeyBase64, signature: sig, createdAt: createdAt))
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
            })
        }
    }
}
