import Vapor

// POST /v1/proposes
struct CreateProposeInput: Content {
    let proposeId: String
    let contentHash: String
    let creatorPublicKey: String
    let creatorSignature: String
    let counterpartyPublicKey: String
    let createdAt: String
}
