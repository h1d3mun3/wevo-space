//
//  Untitled.swift
//  WevoSpace
//
//  Created by hidemune on 3/5/26.
//

import Vapor

// 最初の提案（Propose）を送る時の形
struct ProposeInput: Content {
    let id: UUID // iPhone側で生成したID
    let payloadHash: String
    let publicKey: String
    let signature: String
}
