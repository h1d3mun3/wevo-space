import Vapor

// PATCH /v1/proposes/:id/sign
struct SignInput: Content {
    let counterpartySignature: String
    let createdAt: String
}

// DELETE /v1/proposes/:id (dissolved)
// PATCH  /v1/proposes/:id/honor
// PATCH  /v1/proposes/:id/part
struct TransitionInput: Content {
    let publicKey: String
    let signature: String
    let timestamp: String
}
