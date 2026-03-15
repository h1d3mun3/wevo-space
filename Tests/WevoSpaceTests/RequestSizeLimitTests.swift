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
            app.databases.use(.sqlite(.memory), as: .sqlite)
            app.routes.defaultMaxBodySize = "1mb"
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

    private func makeCreateInput(
        proposeId: UUID = UUID(),
        contentHash: String = "test-hash",
        creatorPublicKey: String? = nil,
        creatorSignature: String = "dummy-sig",
        counterpartyPublicKeys: [String] = ["counterparty-key"],
        createdAt: String = "2026-01-01T00:00:00Z"
    ) -> CreateProposeInput {
        let pubKey: String
        if let key = creatorPublicKey {
            pubKey = key
        } else {
            let pk = P256.Signing.PrivateKey()
            pubKey = pk.publicKey.x963Representation.base64EncodedString()
        }
        return CreateProposeInput(
            proposeId: proposeId.uuidString,
            contentHash: contentHash,
            creatorPublicKey: pubKey,
            creatorSignature: creatorSignature,
            counterpartyPublicKeys: counterpartyPublicKeys,
            createdAt: createdAt
        )
    }

    @Test("通常サイズのリクエストはサイズ制限を通過する")
    func normalSizeRequest() async throws {
        try await withApp { app in
            let privateKey = P256.Signing.PrivateKey()
            let counterpartyKey = P256.Signing.PrivateKey()
            let proposeId = UUID()
            let contentHash = "test-hash"
            let createdAt = "2026-01-01T00:00:00Z"
            let counterpartyPubKey = counterpartyKey.publicKey.x963Representation.base64EncodedString()
            let creatorPubKey = privateKey.publicKey.x963Representation.base64EncodedString()

            let message = proposeId.uuidString + contentHash + counterpartyPubKey + createdAt
            let sig = try privateKey.signature(for: Data(message.utf8))

            let input = CreateProposeInput(
                proposeId: proposeId.uuidString,
                contentHash: contentHash,
                creatorPublicKey: creatorPubKey,
                creatorSignature: sig.derRepresentation.base64EncodedString(),
                counterpartyPublicKeys: [counterpartyPubKey],
                createdAt: createdAt
            )

            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                // Should not be rejected by size limit (valid signature → created)
                #expect(res.status == .created)
            })
        }
    }

    @Test("2MBを超えるcontentHashはリクエストサイズ制限で拒否される")
    func extremelyLargeBody() async throws {
        try await withApp { app in
            let hugeContentHash = String(repeating: "a", count: 2_000_000)
            let input = makeCreateInput(contentHash: hugeContentHash)

            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(
                    res.status == .badRequest || res.status == .payloadTooLarge,
                    "Requests over 2 MB should be rejected by size limit or validation (actual: \(res.status))"
                )
            })
        }
    }

    @Test("2MBを超えるcreatorPublicKeyはリクエストサイズ制限で拒否される")
    func extremelyLargePublicKey() async throws {
        try await withApp { app in
            let hugeKey = String(repeating: "a", count: 2_000_000)
            let input = makeCreateInput(creatorPublicKey: hugeKey)

            try await app.testing().test(.POST, "v1/proposes", beforeRequest: { req in
                try req.content.encode(input)
            }, afterResponse: { res async throws in
                #expect(
                    res.status == .badRequest || res.status == .payloadTooLarge,
                    "Requests over 2 MB should be rejected by size limit or validation (actual: \(res.status))"
                )
            })
        }
    }
}
