import Vapor

// PATCH /v1/proposes/:id/sign
// signerPublicKey must be one of the counterpartyPublicKeys registered at creation.
struct SignInput: Content {
    let signerPublicKey: String
    let signature: String
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
