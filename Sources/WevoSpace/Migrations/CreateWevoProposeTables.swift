//
//  Untitled.swift
//  WevoSpace
//
//  Created by hidemune on 3/5/26.
//

import Fluent

struct CreateWevoProposeTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // 1. proposes テーブル
        try await database.schema("proposes")
            .id()
            .field("payload_hash", .string, .required)
            .field("created_at", .datetime)
            .create()

        // 2. signatures テーブル
        try await database.schema("signatures")
            .id()
            .field("propose_id", .uuid, .required, .references("proposes", "id", onDelete: .cascade))
            .field("public_key", .string, .required)
            .field("signature_data", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("signatures").delete()
        try await database.schema("proposes").delete()
    }
}
