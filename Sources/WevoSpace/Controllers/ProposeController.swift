//
//  ProposeController.swift
//  WevoSpace
//
//  Created by hidemune on 3/5/26.
//

import Fluent
import Vapor

struct ProposeController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let proposes = routes.grouped("proposes")

        // GET /proposes/:proposeID -> 指定したUUIDのPropose詳細を取得
        proposes.get(":proposeID", use: getOne)

        // GET /proposes?publicKey=xxx&page=1&per=20
        proposes.get(use: list)

        // POST /proposes -> 最初の提案を作成
        proposes.post(use: create)

        // POST /proposes/:proposeID/sign -> 2人目の署名を追記
        proposes.group(":proposeID") { propose in
            propose.post("sign", use: sign)
        }
    }

    // 1. 新規作成ロジック
    func create(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(ProposeInput.self)

        let newPropose = Propose(id: input.id, payloadHash: input.payloadHash)
        try await newPropose.save(on: req.db)

        let firstSignature = Signature(proposeID: newPropose.id!, publicKey: input.publicKey, signatureData: input.signature)
        try await firstSignature.save(on: req.db)

        return .created
    }

    // POST /proposes/:proposeID/sign
    func sign(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(SignInput.self)

        // 1. URLからUUIDを取得
        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid Propose ID.")
        }

        // 2. 親（Propose）が本当に存在するかチェック
        guard let parentPropose = try await Propose.find(proposeID, on: req.db) else {
            throw Abort(.notFound, reason: "Propose not found.")
        }

        // 3. 署名を保存
        let additionalSignature = Signature(
            proposeID: parentPropose.id!,
            publicKey: input.publicKey,
            signatureData: input.signature
        )
        try await additionalSignature.save(on: req.db)

        return .ok
    }

    func getOne(req: Request) async throws -> Propose {
        // 1. URLからUUIDを取得
        guard let proposeID = req.parameters.get("proposeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "UUIDの形式が正しくないよ")
        }

        // 2. DBから検索（署名リストも一緒に読み込む）
        guard let propose = try await Propose.query(on: req.db)
            .filter(\.$id == proposeID)
            .with(\.$signatures) // ここで紐づく署名を全部持ってくる
            .first() else {
            throw Abort(.notFound, reason: "そのProposeは見つからなかったよ")
        }

        return propose
    }

    func list(req: Request) async throws -> Page<Propose> { // 戻り値を Page<T> に
        guard let publicKey = req.query[String.self, at: "publicKey"] else {
            throw Abort(.badRequest, reason: "publicKeyを指定してね")
        }

        return try await Propose.query(on: req.db)
            .join(Signature.self, on: \Propose.$id == \Signature.$propose.$id)
            .filter(Signature.self, \.$publicKey == publicKey)
            .with(\.$signatures)
            .sort(\.$createdAt, .descending)
            .paginate(for: req) // これが Page<Propose> を返してくれる
    }
}
