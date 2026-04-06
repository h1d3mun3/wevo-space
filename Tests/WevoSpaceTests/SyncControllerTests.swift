@testable import WevoSpace
import VaporTesting
import Testing
import Fluent
import Crypto
import Foundation

@Suite("SyncController Tests", .serialized)
struct SyncControllerTests {

    // MARK: - App Setup

    private func withApp(
        syncSecret: String? = nil,
        test: (Application) async throws -> ()
    ) async throws {
        if let secret = syncSecret {
            setenv("SYNC_SECRET", secret, 1)
        }
        defer {
            if syncSecret != nil { unsetenv("SYNC_SECRET") }
        }

        let app = try await Application.make(.testing)
        do {
            app.databases.use(.sqlite(.memory), as: .sqlite)
            app.migrations.add(CreateProposesTable())
            app.migrations.add(CreateCounterpartiesTable())
            app.migrations.add(AddSignatureVersionAndResetProposes())
            app.migrations.add(AddDissolveSignatureToPropose())
            app.migrations.add(AddPerPartyDissolveSignatures())
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
        let publicKeyJWK: String

        init() {
            privateKey = P256.Signing.PrivateKey()
            let raw = privateKey.publicKey.rawRepresentation
            let x = raw.prefix(32).base64URLEncodedString()
            let y = raw.suffix(32).base64URLEncodedString()
            publicKeyJWK = #"{"crv":"P-256","kty":"EC","x":"\#(x)","y":"\#(y)"}"#
        }

        func sign(_ message: String) throws -> String {
            let sig = try privateKey.signature(for: Data(message.utf8))
            return sig.derRepresentation.base64EncodedString()
        }
    }

    /// Creates a propose via the API and returns its ProposeResponse.
    private func createPropose(
        app: Application,
        proposeId: UUID = UUID(),
        contentHash: String = "test-content-hash",
        createdAt: String = "2026-01-01T00:00:00Z"
    ) async throws -> ProposeResponse {
        let creator = KeyPair()
        let counterparty = KeyPair()
        let message = "proposed." + proposeId.uuidString + contentHash
            + creator.publicKeyJWK + counterparty.publicKeyJWK + createdAt
        let sig = try creator.sign(message)

        let input = CreateProposeInput(
            proposeId: proposeId.uuidString,
            contentHash: contentHash,
            creatorPublicKey: creator.publicKeyJWK,
            creatorSignature: sig,
            counterpartyPublicKeys: [counterparty.publicKeyJWK],
            createdAt: createdAt
        )
        try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
            try req.content.encode(input)
        }, afterResponse: { res async throws in
            #expect(res.status == .created)
        })

        var response: ProposeResponse?
        try await app.testing().test(.GET, "v1/proposes/\(proposeId.uuidString)", afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(ProposeResponse.self)
        })
        return response!
    }

    /// Builds minimal JSON for a ProposeResponse for use as batch input.
    /// Uses a plain Encodable struct so we're not constrained by ProposeResponse's init.
    private struct SyncPropose: Content {
        struct CP: Content {
            let publicKey: String
            let signSignature: String?
            let signTimestamp: String?
            let honorSignature: String?
            let honorTimestamp: String?
            let partSignature: String?
            let partTimestamp: String?
            let dissolveSignature: String?
            let dissolveTimestamp: String?
        }
        let id: UUID
        let contentHash: String
        let creatorPublicKey: String
        let creatorSignature: String
        let counterparties: [CP]
        let honorCreatorSignature: String?
        let honorCreatorTimestamp: String?
        let partCreatorSignature: String?
        let partCreatorTimestamp: String?
        let dissolvedAt: String?
        let creatorDissolveSignature: String?
        let creatorDissolveTimestamp: String?
        let status: String
        let signatureVersion: Int
        let createdAt: String
        let updatedAt: Date?
    }

    private func makePropose(
        id: UUID = UUID(),
        contentHash: String = "hash-abc",
        creatorJWK: String = "creator-jwk",
        creatorSig: String = "creator-sig",
        counterpartyJWK: String = "cp-jwk",
        signSignature: String? = nil,
        signTimestamp: String? = nil,
        honorCreatorSignature: String? = nil,
        honorCreatorTimestamp: String? = nil
    ) -> SyncPropose {
        SyncPropose(
            id: id,
            contentHash: contentHash,
            creatorPublicKey: creatorJWK,
            creatorSignature: creatorSig,
            counterparties: [
                SyncPropose.CP(
                    publicKey: counterpartyJWK,
                    signSignature: signSignature,
                    signTimestamp: signTimestamp,
                    honorSignature: nil,
                    honorTimestamp: nil,
                    partSignature: nil,
                    partTimestamp: nil,
                    dissolveSignature: nil,
                    dissolveTimestamp: nil
                )
            ],
            honorCreatorSignature: honorCreatorSignature,
            honorCreatorTimestamp: honorCreatorTimestamp,
            partCreatorSignature: nil,
            partCreatorTimestamp: nil,
            dissolvedAt: nil,
            creatorDissolveSignature: nil,
            creatorDissolveTimestamp: nil,
            status: "proposed",
            signatureVersion: 1,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: nil
        )
    }

    // MARK: - GET /info

    @Test("Info route returns peers as empty array when no peers configured")
    func infoReturnsEmptyPeers() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "info", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(InfoResponse.self)
                #expect(body.peers == [])
            })
        }
    }

    // MARK: - GET /v1/sync/proposes

    @Test("Returns all proposes when no after parameter")
    func syncListReturnsAllProposes() async throws {
        try await withApp { app in
            _ = try await createPropose(app: app)
            _ = try await createPropose(app: app)

            try await app.testing().test(.GET, "v1/sync/proposes", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([ProposeResponse].self)
                #expect(body.count == 2)
            })
        }
    }

    @Test("Returns empty array when no proposes exist")
    func syncListReturnsEmptyArray() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/sync/proposes", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([ProposeResponse].self)
                #expect(body.isEmpty)
            })
        }
    }

    @Test("Filters proposes by after parameter")
    func syncListFiltersAfterTimestamp() async throws {
        try await withApp { app in
            _ = try await createPropose(app: app)
            try await Task.sleep(nanoseconds: 1_100_000_000)
            let cutoff = ISO8601DateFormatter().string(from: Date())
            try await Task.sleep(nanoseconds: 1_100_000_000)
            _ = try await createPropose(app: app)

            let encoded = cutoff.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cutoff
            try await app.testing().test(.GET, "v1/sync/proposes?after=\(encoded)", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([ProposeResponse].self)
                #expect(body.count == 1)
            })
        }
    }

    @Test("Returns 400 for invalid after parameter")
    func syncListInvalidAfterReturns400() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/sync/proposes?after=not-a-date", afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Returns 401 when sync secret required but missing")
    func syncListReturns401WhenSecretMissing() async throws {
        try await withApp(syncSecret: "s3cr3t") { app in
            try await app.testing().test(.GET, "v1/sync/proposes", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Returns 401 when wrong sync secret provided")
    func syncListReturns401WhenSecretWrong() async throws {
        try await withApp(syncSecret: "s3cr3t") { app in
            try await app.testing().test(.GET, "v1/sync/proposes", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: "wrong-secret")
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Accepts request when correct sync secret provided")
    func syncListAcceptsCorrectSecret() async throws {
        try await withApp(syncSecret: "s3cr3t") { app in
            try await app.testing().test(.GET, "v1/sync/proposes", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: "s3cr3t")
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })
        }
    }

    // MARK: - POST /v1/sync/proposes/batch

    @Test("Batch insert creates new proposes")
    func batchInsertCreatesNewProposes() async throws {
        try await withApp { app in
            let propose = makePropose()

            try await app.testing().test(.POST, "v1/sync/proposes/batch", beforeRequest: { req in
                try req.content.encode([propose])
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.GET, "v1/sync/proposes", afterResponse: { res async throws in
                let body = try res.content.decode([ProposeResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.id == propose.id)
            })
        }
    }

    @Test("Batch insert is idempotent")
    func batchInsertIdempotent() async throws {
        try await withApp { app in
            let propose = makePropose()

            for _ in 0..<2 {
                try await app.testing().test(.POST, "v1/sync/proposes/batch", beforeRequest: { req in
                    try req.content.encode([propose])
                }, afterResponse: { res async in
                    #expect(res.status == .ok)
                })
            }

            try await app.testing().test(.GET, "v1/sync/proposes", afterResponse: { res async throws in
                let body = try res.content.decode([ProposeResponse].self)
                #expect(body.count == 1)
            })
        }
    }

    @Test("Batch merge does not overwrite existing non-nil signature fields")
    func batchMergeDoesNotOverwriteExistingSignatures() async throws {
        try await withApp { app in
            let id = UUID()
            // Insert with signSignature set
            let withSig = makePropose(id: id, signSignature: "original-sig", signTimestamp: "2026-01-01T00:00:00Z")
            try await app.testing().test(.POST, "v1/sync/proposes/batch", beforeRequest: { req in
                try req.content.encode([withSig])
            }, afterResponse: { res async in #expect(res.status == .ok) })

            // Attempt to overwrite with a different signature
            let withDifferentSig = makePropose(id: id, signSignature: "DIFFERENT-SIG", signTimestamp: "2026-06-01T00:00:00Z")
            try await app.testing().test(.POST, "v1/sync/proposes/batch", beforeRequest: { req in
                try req.content.encode([withDifferentSig])
            }, afterResponse: { res async in #expect(res.status == .ok) })

            try await app.testing().test(.GET, "v1/sync/proposes", afterResponse: { res async throws in
                let body = try res.content.decode([ProposeResponse].self)
                #expect(body.first?.counterparties.first?.signSignature == "original-sig")
            })
        }
    }

    @Test("Batch merge propagates new signature fields to existing propose")
    func batchMergeAddsNewSignatureFields() async throws {
        try await withApp { app in
            let id = UUID()
            // Insert base with no honor signature
            let base = makePropose(id: id)
            try await app.testing().test(.POST, "v1/sync/proposes/batch", beforeRequest: { req in
                try req.content.encode([base])
            }, afterResponse: { res async in #expect(res.status == .ok) })

            // Merge with honorCreatorSignature filled in
            let withHonor = makePropose(id: id, honorCreatorSignature: "honor-sig", honorCreatorTimestamp: "2026-03-01T00:00:00Z")
            try await app.testing().test(.POST, "v1/sync/proposes/batch", beforeRequest: { req in
                try req.content.encode([withHonor])
            }, afterResponse: { res async in #expect(res.status == .ok) })

            try await app.testing().test(.GET, "v1/sync/proposes", afterResponse: { res async throws in
                let body = try res.content.decode([ProposeResponse].self)
                #expect(body.first?.honorCreatorSignature == "honor-sig")
            })
        }
    }

    @Test("Batch returns 401 when sync secret required but missing")
    func batchReturns401WhenSecretMissing() async throws {
        try await withApp(syncSecret: "s3cr3t") { app in
            try await app.testing().test(.POST, "v1/sync/proposes/batch", beforeRequest: { req in
                try req.content.encode([SyncPropose]())
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Batch accepts request when correct sync secret provided")
    func batchAcceptsCorrectSecret() async throws {
        try await withApp(syncSecret: "s3cr3t") { app in
            try await app.testing().test(.POST, "v1/sync/proposes/batch", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: "s3cr3t")
                try req.content.encode([SyncPropose]())
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }
}

// MARK: - Helpers

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
