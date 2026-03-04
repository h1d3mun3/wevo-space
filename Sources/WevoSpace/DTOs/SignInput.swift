//
//  Untitled.swift
//  WevoSpace
//
//  Created by hidemune on 3/5/26.
//

import Vapor

// 既存の提案に署名（Sign/Commit）を足す時の形
struct SignInput: Content {
    let publicKey: String
    let signature: String
}
