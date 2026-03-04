//
//  Propose.swift
//  WevoSpace
//
//  Created by hidemune on 3/5/26.
//

import Fluent
import Vapor

// 提案の本体（指紋とタイムスタンプを管理）
final class Propose: Model, Content, @unchecked Sendable {
    static let schema = "proposes"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "payload_hash")
    var payloadHash: String // 本文のハッシュ値

    @Children(for: \.$propose)
    var signatures: [Signature] // この提案に紐づく署名リスト

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(id: UUID? = nil, payloadHash: String) {
        self.id = id
        self.payloadHash = payloadHash
    }
}
