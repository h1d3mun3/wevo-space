@testable import WevoSpace
import VaporTesting
import Testing
import Fluent
import FluentSQLiteDriver
import Crypto
import Foundation

private extension P256.Signing.PublicKey {
    var jwkString: String {
        let raw = rawRepresentation
        let x = raw.prefix(32).base64URLEncodedString()
        let y = raw.suffix(32).base64URLEncodedString()
        return #"{"crv":"P-256","kty":"EC","x":"\#(x)","y":"\#(y)"}"#
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@Suite("Request Size Limit Tests", .serialized)
struct RequestSizeLimitTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            app.databases.use(.sqlite(.memory), as: .sqlite)
            app.routes.defaultMaxBodySize = "1mb"
            app.migrations.add(CreateProposesTable())
            app.migrations.add(CreateCounterpartiesTable())
            app.migrations.add(AddSignatureVersionAndResetProposes())
            app.migrations.add(AddDissolveSignatureToPropose())
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
            pubKey = pk.publicKey.jwkString
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

    @Test("Normal-sized requests pass the size limit")
    func normalSizeRequest() async throws {
        try await withApp { app in
            let privateKey = P256.Signing.PrivateKey()
            let counterpartyKey = P256.Signing.PrivateKey()
            let proposeId = UUID()
            let contentHash = "test-hash"
            let createdAt = "2026-01-01T00:00:00Z"
            let counterpartyPubKey = counterpartyKey.publicKey.jwkString
            let creatorPubKey = privateKey.publicKey.jwkString

            // v1: "proposed." + proposeId + contentHash + creatorPublicKey + sortedCounterpartyKeys + createdAt
            let message = "proposed." + proposeId.uuidString + contentHash + creatorPubKey + counterpartyPubKey + createdAt
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

    @Test("contentHash exceeding 2 MB is rejected by the request size limit")
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

    @Test("creatorPublicKey exceeding 2 MB is rejected by the request size limit")
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
