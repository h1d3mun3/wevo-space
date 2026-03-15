import Fluent
import Vapor

// Counterparty record for a Propose.
// Tracks the invited public key and signatures for each transition (sign/honor/part).
final class ProposeCounterparty: Model, Content, @unchecked Sendable {
    static let schema = "propose_counterparties"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "propose_id")
    var propose: Propose

    @Field(key: "public_key")
    var publicKey: String

    // Signature for /sign (proposed → signed)
    @OptionalField(key: "sign_signature")
    var signSignature: String?

    // Signature for /honor (signed → honored)
    @OptionalField(key: "honor_signature")
    var honorSignature: String?

    // Signature for /part (signed → parted)
    @OptionalField(key: "part_signature")
    var partSignature: String?

    init() { }

    init(proposeID: UUID, publicKey: String) {
        self.id = UUID()
        self.$propose.id = proposeID
        self.publicKey = publicKey
    }
}
