import Vapor

// POST /v1/proposes
struct CreateProposeInput: Content {
    let proposeId: String
    let contentHash: String
    let creatorPublicKey: String
    let creatorSignature: String
    let counterpartyPublicKeys: [String]  // One or more counterparties
    let createdAt: String
}
