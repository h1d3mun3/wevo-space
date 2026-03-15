import Fluent
import Vapor
import Crypto
import Foundation

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
    func list(req: Request) async throws -> Page<Propose> {
        guard let publicKey = req.query[String.self, at: "publicKey"] else {
            throw Abort(.badRequest, reason: "publicKeyを指定してください")
        }

        var query = Propose.query(on: req.db)
            .group(.or) { group in
                group.filter(\.$creatorPublicKey == publicKey)
                group.filter(\.$counterpartyPublicKey == publicKey)
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

        return try await query
            .sort(\.$updatedAt, .descending)
            .paginate(for: req)
    }

    // POST /v1/proposes
    func create(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(CreateProposeInput.self)

        guard let proposeId = UUID(uuidString: input.proposeId) else {
            throw Abort(.badRequest, reason: "proposeIdの形式が無効です")
        }

        // 重複チェック
        if try await Propose.find(proposeId, on: req.db) != nil {
            throw Abort(.conflict, reason: "同じIDのProposeが既に存在します")
        }

        // 署名検証: proposeId + contentHash + counterpartyPublicKey + createdAt
        let message = input.proposeId + input.contentHash + input.counterpartyPublicKey + input.createdAt
        try verifySignature(publicKey: input.creatorPublicKey, signature: input.creatorSignature, message: message)

        let propose = Propose(
            id: proposeId,
            contentHash: input.contentHash,
            creatorPublicKey: input.creatorPublicKey,
            creatorSignature: input.creatorSignature,
            counterpartyPublicKey: input.counterpartyPublicKey,
            createdAt: input.createdAt
        )
        try await propose.save(on: req.db)

        return .created
    }

    // GET /v1/proposes/:id
    func getOne(req: Request) async throws -> Propose {
        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "無効なPropose IDです")
        }

        guard let propose = try await Propose.find(proposeID, on: req.db) else {
            throw Abort(.notFound, reason: "Proposeが見つかりません")
        }

        return propose
    }

    // PATCH /v1/proposes/:id/sign
    // proposed → signed
    func sign(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(SignInput.self)

        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "無効なPropose IDです")
        }

        guard let propose = try await Propose.find(proposeID, on: req.db) else {
            throw Abort(.notFound, reason: "Proposeが見つかりません")
        }

        guard propose.proposeStatus == .proposed else {
            throw Abort(.conflict, reason: "proposed状態のProposeのみ署名できます（現在: \(propose.status)）")
        }

        guard input.createdAt == propose.createdAt else {
            throw Abort(.badRequest, reason: "createdAtがProposeの値と一致しません")
        }

        // 署名検証: proposeId + contentHash + counterpartyPublicKey + createdAt
        let message = propose.id!.uuidString + propose.contentHash + propose.counterpartyPublicKey + propose.createdAt
        try verifySignature(publicKey: propose.counterpartyPublicKey, signature: input.counterpartySignature, message: message)

        propose.counterpartySignature = input.counterpartySignature
        propose.proposeStatus = .signed
        try await propose.save(on: req.db)

        return .ok
    }

    // DELETE /v1/proposes/:id
    // proposed → dissolved
    func dissolve(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(TransitionInput.self)

        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "無効なPropose IDです")
        }

        guard let propose = try await Propose.find(proposeID, on: req.db) else {
            throw Abort(.notFound, reason: "Proposeが見つかりません")
        }

        guard propose.proposeStatus == .proposed else {
            throw Abort(.conflict, reason: "proposed状態のProposeのみ解消できます（現在: \(propose.status)）")
        }

        guard input.publicKey == propose.creatorPublicKey || input.publicKey == propose.counterpartyPublicKey else {
            throw Abort(.forbidden, reason: "このProposeの参加者のみが解消できます")
        }

        // 署名検証: "dissolved." + proposeId + contentHash + timestamp
        let message = "dissolved." + propose.id!.uuidString + propose.contentHash + input.timestamp
        try verifySignature(publicKey: input.publicKey, signature: input.signature, message: message)

        propose.proposeStatus = .dissolved
        try await propose.save(on: req.db)

        return .ok
    }

    // PATCH /v1/proposes/:id/honor
    // signed → honored（両者の署名が揃ったら自動遷移）
    func honor(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(TransitionInput.self)

        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "無効なPropose IDです")
        }

        guard let propose = try await Propose.find(proposeID, on: req.db) else {
            throw Abort(.notFound, reason: "Proposeが見つかりません")
        }

        guard propose.proposeStatus == .signed else {
            throw Abort(.conflict, reason: "signed状態のProposeのみhonorできます（現在: \(propose.status)）")
        }

        let isCreator = input.publicKey == propose.creatorPublicKey
        let isCounterparty = input.publicKey == propose.counterpartyPublicKey
        guard isCreator || isCounterparty else {
            throw Abort(.forbidden, reason: "このProposeの参加者のみがhonorできます")
        }

        // 署名検証: "honored." + proposeId + contentHash + timestamp
        let message = "honored." + propose.id!.uuidString + propose.contentHash + input.timestamp
        try verifySignature(publicKey: input.publicKey, signature: input.signature, message: message)

        if isCreator {
            propose.honorCreatorSignature = input.signature
        } else {
            propose.honorCounterpartySignature = input.signature
        }

        // 両者の署名が揃ったら自動でhonored
        if propose.honorCreatorSignature != nil && propose.honorCounterpartySignature != nil {
            propose.proposeStatus = .honored
        }

        try await propose.save(on: req.db)

        return .ok
    }

    // PATCH /v1/proposes/:id/part
    // signed → parted（両者の署名が揃ったら自動遷移）
    func part(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(TransitionInput.self)

        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "無効なPropose IDです")
        }

        guard let propose = try await Propose.find(proposeID, on: req.db) else {
            throw Abort(.notFound, reason: "Proposeが見つかりません")
        }

        guard propose.proposeStatus == .signed else {
            throw Abort(.conflict, reason: "signed状態のProposeのみpartできます（現在: \(propose.status)）")
        }

        let isCreator = input.publicKey == propose.creatorPublicKey
        let isCounterparty = input.publicKey == propose.counterpartyPublicKey
        guard isCreator || isCounterparty else {
            throw Abort(.forbidden, reason: "このProposeの参加者のみがpartできます")
        }

        // 署名検証: "parted." + proposeId + contentHash + timestamp
        let message = "parted." + propose.id!.uuidString + propose.contentHash + input.timestamp
        try verifySignature(publicKey: input.publicKey, signature: input.signature, message: message)

        if isCreator {
            propose.partCreatorSignature = input.signature
        } else {
            propose.partCounterpartySignature = input.signature
        }

        // 両者の署名が揃ったら自動でparted
        if propose.partCreatorSignature != nil && propose.partCounterpartySignature != nil {
            propose.proposeStatus = .parted
        }

        try await propose.save(on: req.db)

        return .ok
    }

    // MARK: - 署名検証ヘルパー

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
