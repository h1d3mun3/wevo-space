//
//  ProposeInput.swift
//  WevoSpace
//
//  Created by hidemune on 3/5/26.
//

import Vapor

// 提案（Propose）を送る時の形（署名の配列を含む）
struct ProposeInput: Content {
    let id: UUID // iPhone側で生成したID
    let payloadHash: String
    let signatures: [SignatureInput] // 署名のリスト
}

// 署名の単位
struct SignatureInput: Content, Equatable {
    let publicKey: String
    let signature: String
}
