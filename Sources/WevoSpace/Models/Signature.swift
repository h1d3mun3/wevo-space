//
//  Signature.swift
//  WevoSpace
//
//  Created by hidemune on 3/5/26.
//

import Fluent
import Vapor

// 署名データ（提案者と同意者のハンコ）
final class Signature: Model, Content, @unchecked Sendable {
    static let schema = "signatures"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "propose_id")
    var propose: Propose

    @Field(key: "public_key")
    var publicKey: String // 署名者の公開鍵（ID）

    @Field(key: "signature_data")
    var signatureData: String // 署名値

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(id: UUID? = nil, proposeID: Propose.IDValue, publicKey: String, signatureData: String) {
        self.$propose.id = proposeID
        self.publicKey = publicKey
        self.signatureData = signatureData
    }
}
