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
}
