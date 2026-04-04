import Fluent
import Vapor
import Crypto
import Foundation

// Response DTO including counterparty details
struct ProposeResponse: Content {
    let id: UUID
    let contentHash: String
    let creatorPublicKey: String
    let creatorSignature: String
    let counterparties: [CounterpartyInfo]
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

    struct CounterpartyInfo: Content {
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

    init(from propose: Propose) throws {
        self.id = try propose.requireID()
        self.contentHash = propose.contentHash
        self.creatorPublicKey = propose.creatorPublicKey
        self.creatorSignature = propose.creatorSignature
        self.counterparties = propose.counterparties.map {
            CounterpartyInfo(
                publicKey: $0.publicKey,
                signSignature: $0.signSignature,
                signTimestamp: $0.signTimestamp,
                honorSignature: $0.honorSignature,
                honorTimestamp: $0.honorTimestamp,
                partSignature: $0.partSignature,
                partTimestamp: $0.partTimestamp,
                dissolveSignature: $0.dissolveSignature,
                dissolveTimestamp: $0.dissolveTimestamp
            )
        }
        self.honorCreatorSignature = propose.honorCreatorSignature
        self.honorCreatorTimestamp = propose.honorCreatorTimestamp
        self.partCreatorSignature = propose.partCreatorSignature
        self.partCreatorTimestamp = propose.partCreatorTimestamp
        self.dissolvedAt = propose.dissolvedAt
        self.creatorDissolveSignature = propose.creatorDissolveSignature
        self.creatorDissolveTimestamp = propose.creatorDissolveTimestamp
        self.status = propose.status
        self.signatureVersion = propose.signatureVersion
        self.createdAt = propose.createdAt
        self.updatedAt = propose.updatedAt
    }
}

struct ProposeController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let proposes = routes.grouped("proposes")
        proposes.post(use: create)
        proposes.get(":proposeID", use: getOne)
        proposes.patch(":proposeID", "sign", use: sign)
        proposes.delete(":proposeID", use: dissolve)
        proposes.patch(":proposeID", "honor", use: honor)
        proposes.patch(":proposeID", "part", use: part)
    }

    // POST /v1/proposes
    func create(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(CreateProposeInput.self)

        guard let proposeId = UUID(uuidString: input.proposeId) else {
            throw Abort(.badRequest, reason: "Invalid proposeId format")
        }

        guard !input.counterpartyPublicKeys.isEmpty else {
            throw Abort(.badRequest, reason: "counterpartyPublicKeys must contain at least one entry")
        }

        // Duplicate check
        if try await Propose.find(proposeId, on: req.db) != nil {
            throw Abort(.conflict, reason: "A Propose with the same ID already exists")
        }

        // Signature verification (v1):
        // "proposed." + proposeId + contentHash + creatorPublicKey + counterpartyPublicKeys(sorted & joined) + createdAt
        let sortedKeys = input.counterpartyPublicKeys.sorted().joined()
        let message = "proposed." + input.proposeId + input.contentHash + input.creatorPublicKey + sortedKeys + input.createdAt
        try verifySignature(publicKey: input.creatorPublicKey, signature: input.creatorSignature, message: message)

        let propose = Propose(
            id: proposeId,
            contentHash: input.contentHash,
            creatorPublicKey: input.creatorPublicKey,
            creatorSignature: input.creatorSignature,
            createdAt: input.createdAt
        )
        try await propose.save(on: req.db)

        for publicKey in input.counterpartyPublicKeys {
            let counterparty = ProposeCounterparty(proposeID: proposeId, publicKey: publicKey)
            try await counterparty.save(on: req.db)
        }

        return .created
    }

    // GET /v1/proposes/:id
    func getOne(req: Request) async throws -> ProposeResponse {
        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid Propose ID")
        }

        guard let propose = try await Propose.query(on: req.db)
            .filter(\.$id == proposeID)
            .with(\.$counterparties)
            .first() else {
            throw Abort(.notFound, reason: "Propose not found")
        }

        return try ProposeResponse(from: propose)
    }

    // PATCH /v1/proposes/:id/sign
    // proposed → signed (auto-transitions when all counterparties have signed)
    func sign(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(SignInput.self)

        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid Propose ID")
        }

        guard let propose = try await Propose.query(on: req.db)
            .filter(\.$id == proposeID)
            .with(\.$counterparties)
            .first() else {
            throw Abort(.notFound, reason: "Propose not found")
        }

        guard propose.proposeStatus == .proposed else {
            throw Abort(.conflict, reason: "Only a propose in 'proposed' state can be signed (current: \(propose.status))")
        }

        guard let counterparty = propose.counterparties.first(where: { $0.publicKey == input.signerPublicKey }) else {
            throw Abort(.forbidden, reason: "Not a counterparty of this Propose")
        }

        // Signature verification: "signed." + proposeId + contentHash + signerPublicKey + timestamp
        let message = "signed." + propose.id!.uuidString + propose.contentHash + input.signerPublicKey + input.timestamp
        try verifySignature(publicKey: input.signerPublicKey, signature: input.signature, message: message)

        counterparty.signSignature = input.signature
        counterparty.signTimestamp = input.timestamp
        try await counterparty.save(on: req.db)

        // Auto-transition to signed when all counterparties have signed
        if propose.counterparties.allSatisfy({ $0.signSignature != nil }) {
            propose.proposeStatus = .signed
            try await propose.save(on: req.db)
        }

        return .ok
    }

    // DELETE /v1/proposes/:id
    // proposed → dissolved (first party triggers transition; second party can also record their signature)
    func dissolve(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(TransitionInput.self)

        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid Propose ID")
        }

        guard let propose = try await Propose.query(on: req.db)
            .filter(\.$id == proposeID)
            .with(\.$counterparties)
            .first() else {
            throw Abort(.notFound, reason: "Propose not found")
        }

        // Allow proposed (first party) or dissolved (second party recording their signature)
        guard propose.proposeStatus == .proposed || propose.proposeStatus == .dissolved else {
            throw Abort(.conflict, reason: "Only a propose in 'proposed' or 'dissolved' state can accept a dissolve signature (current: \(propose.status))")
        }

        let isCreator = input.publicKey == propose.creatorPublicKey
        let counterparty = propose.counterparties.first { $0.publicKey == input.publicKey }
        guard isCreator || counterparty != nil else {
            throw Abort(.forbidden, reason: "Only a participant of this Propose can dissolve it")
        }

        // Idempotent: already recorded for this party
        if isCreator && propose.creatorDissolveSignature != nil {
            return .ok
        }
        if let cp = counterparty, cp.dissolveSignature != nil {
            return .ok
        }

        // Signature verification (v1): "dissolved." + proposeId + contentHash + signerPublicKey + timestamp
        let message = "dissolved." + propose.id!.uuidString + propose.contentHash + input.publicKey + input.timestamp
        try verifySignature(publicKey: input.publicKey, signature: input.signature, message: message)

        if isCreator {
            propose.creatorDissolveSignature = input.signature
            propose.creatorDissolveTimestamp = input.timestamp
            if propose.proposeStatus == .proposed {
                propose.proposeStatus = .dissolved
                propose.dissolvedAt = input.timestamp
            }
            try await propose.save(on: req.db)
        } else {
            counterparty!.dissolveSignature = input.signature
            counterparty!.dissolveTimestamp = input.timestamp
            try await counterparty!.save(on: req.db)
            if propose.proposeStatus == .proposed {
                propose.proposeStatus = .dissolved
                propose.dissolvedAt = input.timestamp
                try await propose.save(on: req.db)
            }
        }

        return .ok
    }

    // PATCH /v1/proposes/:id/honor
    // signed → honored (auto-transitions when creator + all counterparties have signed)
    func honor(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(TransitionInput.self)

        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid Propose ID")
        }

        guard let propose = try await Propose.query(on: req.db)
            .filter(\.$id == proposeID)
            .with(\.$counterparties)
            .first() else {
            throw Abort(.notFound, reason: "Propose not found")
        }

        guard propose.proposeStatus == .signed else {
            throw Abort(.conflict, reason: "Only a propose in 'signed' state can be honored (current: \(propose.status))")
        }

        let isCreator = input.publicKey == propose.creatorPublicKey
        let counterparty = propose.counterparties.first { $0.publicKey == input.publicKey }
        guard isCreator || counterparty != nil else {
            throw Abort(.forbidden, reason: "Only a participant of this Propose can honor it")
        }

        // Signature verification (v1): "honored." + proposeId + contentHash + signerPublicKey + timestamp
        let message = "honored." + propose.id!.uuidString + propose.contentHash + input.publicKey + input.timestamp
        try verifySignature(publicKey: input.publicKey, signature: input.signature, message: message)

        let creatorHonored: Bool
        if isCreator {
            propose.honorCreatorSignature = input.signature
            propose.honorCreatorTimestamp = input.timestamp
            try await propose.save(on: req.db)
            creatorHonored = true
        } else {
            counterparty!.honorSignature = input.signature
            counterparty!.honorTimestamp = input.timestamp
            try await counterparty!.save(on: req.db)
            // Re-fetch from DB to avoid stale in-memory read of honorCreatorSignature
            let refreshed = try await Propose.find(proposeID, on: req.db)
            creatorHonored = refreshed?.honorCreatorSignature != nil
        }

        // Auto-transition to honored when all participants have signed
        if creatorHonored && propose.counterparties.allSatisfy({ $0.honorSignature != nil }) {
            propose.proposeStatus = .honored
            try await propose.save(on: req.db)
        }

        return .ok
    }

    // PATCH /v1/proposes/:id/part
    // signed → parted (first party triggers transition; second party can also record their signature)
    func part(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(TransitionInput.self)

        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid Propose ID")
        }

        guard let propose = try await Propose.query(on: req.db)
            .filter(\.$id == proposeID)
            .with(\.$counterparties)
            .first() else {
            throw Abort(.notFound, reason: "Propose not found")
        }

        // Allow signed (first party) or parted (second party recording their signature)
        guard propose.proposeStatus == .signed || propose.proposeStatus == .parted else {
            throw Abort(.conflict, reason: "Only a propose in 'signed' or 'parted' state can accept a part signature (current: \(propose.status))")
        }

        let isCreator = input.publicKey == propose.creatorPublicKey
        let counterparty = propose.counterparties.first { $0.publicKey == input.publicKey }
        guard isCreator || counterparty != nil else {
            throw Abort(.forbidden, reason: "Only a participant of this Propose can part it")
        }

        // Idempotent: already recorded for this party
        if isCreator && propose.partCreatorSignature != nil {
            return .ok
        }
        if let cp = counterparty, cp.partSignature != nil {
            return .ok
        }

        // Signature verification (v1): "parted." + proposeId + contentHash + signerPublicKey + timestamp
        let message = "parted." + propose.id!.uuidString + propose.contentHash + input.publicKey + input.timestamp
        try verifySignature(publicKey: input.publicKey, signature: input.signature, message: message)

        if isCreator {
            propose.partCreatorSignature = input.signature
            propose.partCreatorTimestamp = input.timestamp
        } else {
            counterparty!.partSignature = input.signature
            counterparty!.partTimestamp = input.timestamp
            try await counterparty!.save(on: req.db)
        }

        // Transition to parted on first request; skip if already parted
        if propose.proposeStatus == .signed {
            propose.proposeStatus = .parted
        }
        try await propose.save(on: req.db)

        return .ok
    }

    // MARK: - Signature Verification Helper

    private func verifySignature(publicKey jwkString: String, signature: String, message: String) throws {
        guard let jsonData = jwkString.data(using: .utf8),
              let jwk = try? JSONDecoder().decode(JWKPublicKey.self, from: jsonData),
              let xData = Data(base64URLEncoded: jwk.x),
              let yData = Data(base64URLEncoded: jwk.y) else {
            throw Abort(.badRequest, reason: "Invalid JWK public key format")
        }

        var x963 = Data([0x04])
        x963.append(contentsOf: xData)
        x963.append(contentsOf: yData)

        guard let signatureData = Data(base64Encoded: signature) else {
            throw Abort(.badRequest, reason: "Failed to Base64-decode the signature")
        }

        guard let messageData = message.data(using: .utf8) else {
            throw Abort(.badRequest, reason: "Failed to encode the message")
        }

        let publicKeyObj: P256.Signing.PublicKey
        do {
            publicKeyObj = try P256.Signing.PublicKey(x963Representation: x963)
        } catch {
            throw Abort(.badRequest, reason: "Invalid public key format")
        }

        let ecdsaSignature: P256.Signing.ECDSASignature
        do {
            ecdsaSignature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        } catch {
            throw Abort(.badRequest, reason: "Invalid signature format")
        }

        guard publicKeyObj.isValidSignature(ecdsaSignature, for: messageData) else {
            throw Abort(.unauthorized, reason: "Signature verification failed")
        }
    }
}

// MARK: - JWK Helpers

private struct JWKPublicKey: Decodable {
    let x: String
    let y: String
}

private extension Data {
    /// Base64URL decoding ('-' → '+', '_' → '/', restores padding)
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: s)
    }
}
