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
    let partCreatorSignature: String?
    let status: String
    let createdAt: String
    let updatedAt: Date?

    struct CounterpartyInfo: Content {
        let publicKey: String
        let signSignature: String?
        let honorSignature: String?
        let partSignature: String?
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
                honorSignature: $0.honorSignature,
                partSignature: $0.partSignature
            )
        }
        self.honorCreatorSignature = propose.honorCreatorSignature
        self.partCreatorSignature = propose.partCreatorSignature
        self.status = propose.status
        self.createdAt = propose.createdAt
        self.updatedAt = propose.updatedAt
    }
}

struct ProposeController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let proposes = routes.grouped("proposes")
        proposes.get(use: list)
        proposes.post(use: create)
        proposes.get(":proposeID", use: getOne)
        proposes.patch(":proposeID", "sign", use: sign)
        proposes.delete(":proposeID", use: dissolve)
        proposes.patch(":proposeID", "honor", use: honor)
        proposes.patch(":proposeID", "part", use: part)
    }

    // GET /v1/proposes?publicKey=...&status=proposed,signed
    func list(req: Request) async throws -> Page<ProposeResponse> {
        guard let publicKey = req.query[String.self, at: "publicKey"] else {
            throw Abort(.badRequest, reason: "publicKeyを指定してください")
        }

        // Find propose IDs where publicKey is registered as a counterparty
        let counterpartyProposeIDs = try await ProposeCounterparty.query(on: req.db)
            .filter(\.$publicKey == publicKey)
            .all()
            .map { $0.$propose.id }

        var query = Propose.query(on: req.db).with(\.$counterparties)

        if counterpartyProposeIDs.isEmpty {
            query = query.filter(\.$creatorPublicKey == publicKey)
        } else {
            query = query.group(.or) { group in
                group.filter(\.$creatorPublicKey == publicKey)
                group.filter(\.$id ~~ counterpartyProposeIDs)
            }
        }

        if let statusParam = req.query[String.self, at: "status"] {
            let statuses = statusParam
                .split(separator: ",")
                .map { String($0) }
                .filter { ProposeStatus(rawValue: $0) != nil }
            if !statuses.isEmpty {
                query = query.filter(\.$status ~~ statuses)
            }
        }

        let page = try await query
            .sort(\.$updatedAt, .descending)
            .paginate(for: req)

        let items = try page.items.map { try ProposeResponse(from: $0) }
        return Page(items: items, metadata: page.metadata)
    }

    // POST /v1/proposes
    func create(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(CreateProposeInput.self)

        guard let proposeId = UUID(uuidString: input.proposeId) else {
            throw Abort(.badRequest, reason: "proposeIdの形式が無効です")
        }

        guard !input.counterpartyPublicKeys.isEmpty else {
            throw Abort(.badRequest, reason: "counterpartyPublicKeysは1件以上必要です")
        }

        // Duplicate check
        if try await Propose.find(proposeId, on: req.db) != nil {
            throw Abort(.conflict, reason: "同じIDのProposeが既に存在します")
        }

        // Signature verification:
        // proposeId + contentHash + counterpartyPublicKeys(sorted & joined) + createdAt
        let sortedKeys = input.counterpartyPublicKeys.sorted().joined()
        let message = input.proposeId + input.contentHash + sortedKeys + input.createdAt
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
            throw Abort(.badRequest, reason: "無効なPropose IDです")
        }

        guard let propose = try await Propose.query(on: req.db)
            .filter(\.$id == proposeID)
            .with(\.$counterparties)
            .first() else {
            throw Abort(.notFound, reason: "Proposeが見つかりません")
        }

        return try ProposeResponse(from: propose)
    }

    // PATCH /v1/proposes/:id/sign
    // proposed → signed (auto-transitions when all counterparties have signed)
    func sign(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(SignInput.self)

        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "無効なPropose IDです")
        }

        guard let propose = try await Propose.query(on: req.db)
            .filter(\.$id == proposeID)
            .with(\.$counterparties)
            .first() else {
            throw Abort(.notFound, reason: "Proposeが見つかりません")
        }

        guard propose.proposeStatus == .proposed else {
            throw Abort(.conflict, reason: "proposed状態のProposeのみ署名できます（現在: \(propose.status)）")
        }

        guard let counterparty = propose.counterparties.first(where: { $0.publicKey == input.signerPublicKey }) else {
            throw Abort(.forbidden, reason: "このProposeのcounterpartyではありません")
        }

        guard input.createdAt == propose.createdAt else {
            throw Abort(.badRequest, reason: "createdAtがProposeの値と一致しません")
        }

        // Signature verification: proposeId + contentHash + signerPublicKey + createdAt
        let message = propose.id!.uuidString + propose.contentHash + input.signerPublicKey + propose.createdAt
        try verifySignature(publicKey: input.signerPublicKey, signature: input.signature, message: message)

        counterparty.signSignature = input.signature
        try await counterparty.save(on: req.db)

        // Auto-transition to signed when all counterparties have signed
        if propose.counterparties.allSatisfy({ $0.signSignature != nil }) {
            propose.proposeStatus = .signed
            try await propose.save(on: req.db)
        }

        return .ok
    }

    // DELETE /v1/proposes/:id
    // proposed → dissolved
    func dissolve(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(TransitionInput.self)

        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "無効なPropose IDです")
        }

        guard let propose = try await Propose.query(on: req.db)
            .filter(\.$id == proposeID)
            .with(\.$counterparties)
            .first() else {
            throw Abort(.notFound, reason: "Proposeが見つかりません")
        }

        guard propose.proposeStatus == .proposed else {
            throw Abort(.conflict, reason: "proposed状態のProposeのみ解消できます（現在: \(propose.status)）")
        }

        let isCreator = input.publicKey == propose.creatorPublicKey
        let isCounterparty = propose.counterparties.contains { $0.publicKey == input.publicKey }
        guard isCreator || isCounterparty else {
            throw Abort(.forbidden, reason: "このProposeの参加者のみが解消できます")
        }

        // Signature verification: "dissolved." + proposeId + contentHash + timestamp
        let message = "dissolved." + propose.id!.uuidString + propose.contentHash + input.timestamp
        try verifySignature(publicKey: input.publicKey, signature: input.signature, message: message)

        propose.proposeStatus = .dissolved
        try await propose.save(on: req.db)

        return .ok
    }

    // PATCH /v1/proposes/:id/honor
    // signed → honored (auto-transitions when creator + all counterparties have signed)
    func honor(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(TransitionInput.self)

        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "無効なPropose IDです")
        }

        guard let propose = try await Propose.query(on: req.db)
            .filter(\.$id == proposeID)
            .with(\.$counterparties)
            .first() else {
            throw Abort(.notFound, reason: "Proposeが見つかりません")
        }

        guard propose.proposeStatus == .signed else {
            throw Abort(.conflict, reason: "signed状態のProposeのみhonorできます（現在: \(propose.status)）")
        }

        let isCreator = input.publicKey == propose.creatorPublicKey
        let counterparty = propose.counterparties.first { $0.publicKey == input.publicKey }
        guard isCreator || counterparty != nil else {
            throw Abort(.forbidden, reason: "このProposeの参加者のみがhonorできます")
        }

        // Signature verification: "honored." + proposeId + contentHash + timestamp
        let message = "honored." + propose.id!.uuidString + propose.contentHash + input.timestamp
        try verifySignature(publicKey: input.publicKey, signature: input.signature, message: message)

        let creatorHonored: Bool
        if isCreator {
            propose.honorCreatorSignature = input.signature
            try await propose.save(on: req.db)
            creatorHonored = true
        } else {
            counterparty!.honorSignature = input.signature
            try await counterparty!.save(on: req.db)
            creatorHonored = propose.honorCreatorSignature != nil
        }

        // Auto-transition to honored when all participants have signed
        if creatorHonored && propose.counterparties.allSatisfy({ $0.honorSignature != nil }) {
            propose.proposeStatus = .honored
            try await propose.save(on: req.db)
        }

        return .ok
    }

    // PATCH /v1/proposes/:id/part
    // signed → parted (auto-transitions when creator + all counterparties have signed)
    func part(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(TransitionInput.self)

        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "無効なPropose IDです")
        }

        guard let propose = try await Propose.query(on: req.db)
            .filter(\.$id == proposeID)
            .with(\.$counterparties)
            .first() else {
            throw Abort(.notFound, reason: "Proposeが見つかりません")
        }

        guard propose.proposeStatus == .signed else {
            throw Abort(.conflict, reason: "signed状態のProposeのみpartできます（現在: \(propose.status)）")
        }

        let isCreator = input.publicKey == propose.creatorPublicKey
        let counterparty = propose.counterparties.first { $0.publicKey == input.publicKey }
        guard isCreator || counterparty != nil else {
            throw Abort(.forbidden, reason: "このProposeの参加者のみがpartできます")
        }

        // Signature verification: "parted." + proposeId + contentHash + timestamp
        let message = "parted." + propose.id!.uuidString + propose.contentHash + input.timestamp
        try verifySignature(publicKey: input.publicKey, signature: input.signature, message: message)

        let creatorParted: Bool
        if isCreator {
            propose.partCreatorSignature = input.signature
            try await propose.save(on: req.db)
            creatorParted = true
        } else {
            counterparty!.partSignature = input.signature
            try await counterparty!.save(on: req.db)
            creatorParted = propose.partCreatorSignature != nil
        }

        // Auto-transition to parted when all participants have signed
        if creatorParted && propose.counterparties.allSatisfy({ $0.partSignature != nil }) {
            propose.proposeStatus = .parted
            try await propose.save(on: req.db)
        }

        return .ok
    }

    // MARK: - Signature Verification Helper

    private func verifySignature(publicKey: String, signature: String, message: String) throws {
        guard let publicKeyData = Data(base64Encoded: publicKey) else {
            throw Abort(.badRequest, reason: "公開鍵のBase64デコードに失敗しました")
        }

        guard let signatureData = Data(base64Encoded: signature) else {
            throw Abort(.badRequest, reason: "署名のBase64デコードに失敗しました")
        }

        guard let messageData = message.data(using: .utf8) else {
            throw Abort(.badRequest, reason: "メッセージのエンコードに失敗しました")
        }

        let publicKeyObj: P256.Signing.PublicKey
        do {
            publicKeyObj = try P256.Signing.PublicKey(x963Representation: publicKeyData)
        } catch {
            throw Abort(.badRequest, reason: "公開鍵の形式が無効です")
        }

        let ecdsaSignature: P256.Signing.ECDSASignature
        do {
            ecdsaSignature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        } catch {
            throw Abort(.badRequest, reason: "署名の形式が無効です")
        }

        guard publicKeyObj.isValidSignature(ecdsaSignature, for: messageData) else {
            throw Abort(.unauthorized, reason: "署名検証に失敗しました")
        }
    }
}
