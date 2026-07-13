import Fluent
import Vapor

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

        // Bound the counterparty set: a single self-signed request could otherwise carry tens of
        // thousands of entries and trigger that many row inserts (storage/CPU amplification DoS).
        guard input.counterpartyPublicKeys.count <= ProposeController.maxCounterparties else {
            throw Abort(.badRequest, reason: "Too many counterparties (max \(ProposeController.maxCounterparties))")
        }
        guard Set(input.counterpartyPublicKeys).count == input.counterpartyPublicKeys.count else {
            throw Abort(.badRequest, reason: "counterpartyPublicKeys must not contain duplicates")
        }
        for key in input.counterpartyPublicKeys where !ProposeController.isValidJWK(key) {
            throw Abort(.badRequest, reason: "Invalid counterparty public key (expected P-256 JWK)")
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

        // Batch insert in a single round-trip instead of N awaited saves.
        let counterparties = input.counterpartyPublicKeys.map {
            ProposeCounterparty(proposeID: proposeId, publicKey: $0)
        }
        try await counterparties.create(on: req.db)

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

        guard let counterparty = propose.counterparties.first(where: { $0.publicKey == input.signerPublicKey }) else {
            throw Abort(.forbidden, reason: "Not a counterparty of this Propose")
        }

        // Idempotent: already recorded for this party (check before state machine to handle retries)
        if counterparty.signSignature != nil {
            return .ok
        }

        guard propose.proposeStatus == .proposed else {
            throw Abort(.conflict, reason: "Only a propose in 'proposed' state can be signed (current: \(propose.status))")
        }

        // Signature verification: "signed." + proposeId + contentHash + signerPublicKey + timestamp
        let message = "signed." + propose.id!.uuidString + propose.contentHash + input.signerPublicKey + input.timestamp
        try verifySignature(publicKey: input.signerPublicKey, signature: input.signature, message: message)

        counterparty.signSignature = input.signature
        counterparty.signTimestamp = input.timestamp
        try await counterparty.save(on: req.db)

        try await recomputeAndSaveStatus(proposeID: proposeID, on: req.db)

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

        let isCreator = input.publicKey == propose.creatorPublicKey
        let counterparty = propose.counterparties.first { $0.publicKey == input.publicKey }
        guard isCreator || counterparty != nil else {
            throw Abort(.forbidden, reason: "Only a participant of this Propose can dissolve it")
        }

        // Idempotent: already recorded for this party (check before state machine to handle retries)
        if isCreator && propose.creatorDissolveSignature != nil {
            return .ok
        }
        if let cp = counterparty, cp.dissolveSignature != nil {
            return .ok
        }

        // Allow proposed (first party) or dissolved (second party recording their signature)
        guard propose.proposeStatus == .proposed || propose.proposeStatus == .dissolved else {
            throw Abort(.conflict, reason: "Only a propose in 'proposed' or 'dissolved' state can accept a dissolve signature (current: \(propose.status))")
        }

        // Signature verification (v1): "dissolved." + proposeId + contentHash + signerPublicKey + timestamp
        let message = "dissolved." + propose.id!.uuidString + propose.contentHash + input.publicKey + input.timestamp
        try verifySignature(publicKey: input.publicKey, signature: input.signature, message: message)

        if isCreator {
            propose.creatorDissolveSignature = input.signature
            propose.creatorDissolveTimestamp = input.timestamp
            if propose.proposeStatus == .proposed {
                propose.dissolvedAt = input.timestamp
            }
            try await propose.save(on: req.db)
        } else {
            counterparty!.dissolveSignature = input.signature
            counterparty!.dissolveTimestamp = input.timestamp
            try await counterparty!.save(on: req.db)
            if propose.proposeStatus == .proposed {
                propose.dissolvedAt = input.timestamp
                try await propose.save(on: req.db)
            }
        }

        try await recomputeAndSaveStatus(proposeID: proposeID, on: req.db)

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

        let isCreator = input.publicKey == propose.creatorPublicKey
        let counterparty = propose.counterparties.first { $0.publicKey == input.publicKey }
        guard isCreator || counterparty != nil else {
            throw Abort(.forbidden, reason: "Only a participant of this Propose can honor it")
        }

        // Idempotent: already recorded for this party (check before state machine to handle retries)
        if isCreator && propose.honorCreatorSignature != nil {
            return .ok
        }
        if let cp = counterparty, cp.honorSignature != nil {
            return .ok
        }

        guard propose.proposeStatus == .signed else {
            throw Abort(.conflict, reason: "Only a propose in 'signed' state can be honored (current: \(propose.status))")
        }

        // Signature verification (v1): "honored." + proposeId + contentHash + signerPublicKey + timestamp
        let message = "honored." + propose.id!.uuidString + propose.contentHash + input.publicKey + input.timestamp
        try verifySignature(publicKey: input.publicKey, signature: input.signature, message: message)

        if isCreator {
            propose.honorCreatorSignature = input.signature
            propose.honorCreatorTimestamp = input.timestamp
            try await propose.save(on: req.db)
        } else {
            counterparty!.honorSignature = input.signature
            counterparty!.honorTimestamp = input.timestamp
            try await counterparty!.save(on: req.db)
        }

        try await recomputeAndSaveStatus(proposeID: proposeID, on: req.db)

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

        let isCreator = input.publicKey == propose.creatorPublicKey
        let counterparty = propose.counterparties.first { $0.publicKey == input.publicKey }
        guard isCreator || counterparty != nil else {
            throw Abort(.forbidden, reason: "Only a participant of this Propose can part it")
        }

        // Idempotent: already recorded for this party (check before state machine to handle retries)
        if isCreator && propose.partCreatorSignature != nil {
            return .ok
        }
        if let cp = counterparty, cp.partSignature != nil {
            return .ok
        }

        // Allow signed (first party) or parted (second party recording their signature)
        guard propose.proposeStatus == .signed || propose.proposeStatus == .parted else {
            throw Abort(.conflict, reason: "Only a propose in 'signed' or 'parted' state can accept a part signature (current: \(propose.status))")
        }

        // Signature verification (v1): "parted." + proposeId + contentHash + signerPublicKey + timestamp
        let message = "parted." + propose.id!.uuidString + propose.contentHash + input.publicKey + input.timestamp
        try verifySignature(publicKey: input.publicKey, signature: input.signature, message: message)

        if isCreator {
            propose.partCreatorSignature = input.signature
            propose.partCreatorTimestamp = input.timestamp
            try await propose.save(on: req.db)
        } else {
            counterparty!.partSignature = input.signature
            counterparty!.partTimestamp = input.timestamp
            try await counterparty!.save(on: req.db)
        }

        try await recomputeAndSaveStatus(proposeID: proposeID, on: req.db)

        return .ok
    }

    // MARK: - Status Recomputation Helper

    /// Re-fetches the Propose and all counterparties from DB, recomputes status from
    /// the signatures actually present, and always saves to advance updatedAt so that
    /// peer nodes pick up counterparty changes even when status hasn't changed.
    private func recomputeAndSaveStatus(proposeID: UUID, on db: any Database) async throws {
        guard let propose = try await Propose.query(on: db)
            .filter(\.$id == proposeID)
            .with(\.$counterparties)
            .first() else { return }

        propose.proposeStatus = SyncService.computeStatus(propose: propose, counterparties: propose.counterparties)
        try await propose.save(on: db)
    }

    // MARK: - Limits

    /// Upper bound on counterparties per propose, applied on both the public create path and the
    /// sync ingest path, to prevent storage/CPU amplification from a single request.
    static let maxCounterparties = 64

    /// True if `key` is a well-formed P-256 JWK (decodable with base64url x/y components).
    static func isValidJWK(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8),
              let jwk = try? JSONDecoder().decode(JWKPublicKey.self, from: data),
              Data(base64URLEncoded: jwk.x) != nil,
              Data(base64URLEncoded: jwk.y) != nil else {
            return false
        }
        return true
    }

    // MARK: - Signature Verification Helper

    private func verifySignature(publicKey: String, signature: String, message: String) throws {
        guard let jsonData = publicKey.data(using: .utf8),
              let jwk = try? JSONDecoder().decode(JWKPublicKey.self, from: jsonData),
              Data(base64URLEncoded: jwk.x) != nil,
              Data(base64URLEncoded: jwk.y) != nil else {
            throw Abort(.badRequest, reason: "Invalid JWK public key format")
        }
        guard P256SignatureVerifier().verify(signature: signature, message: message, publicKey: publicKey) else {
            throw Abort(.unauthorized, reason: "Signature verification failed")
        }
    }
}
