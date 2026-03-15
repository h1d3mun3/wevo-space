import Fluent
import Vapor

enum ProposeStatus: String, Codable, Sendable {
    case proposed
    case signed
    case honored
    case dissolved
    case parted
}

// 提案本体。状態遷移は署名検証によって担保される
final class Propose: Model, Content, @unchecked Sendable {
    static let schema = "proposes"

    // クライアントが生成するUUID
    @ID(key: .id)
    var id: UUID?

    @Field(key: "content_hash")
    var contentHash: String

    @Field(key: "creator_public_key")
    var creatorPublicKey: String

    @Field(key: "creator_signature")
    var creatorSignature: String

    @Field(key: "counterparty_public_key")
    var counterpartyPublicKey: String

    @OptionalField(key: "counterparty_signature")
    var counterpartySignature: String?

    @OptionalField(key: "honor_creator_signature")
    var honorCreatorSignature: String?

    @OptionalField(key: "honor_counterparty_signature")
    var honorCounterpartySignature: String?

    @OptionalField(key: "part_creator_signature")
    var partCreatorSignature: String?

    @OptionalField(key: "part_counterparty_signature")
    var partCounterpartySignature: String?

    @Field(key: "status")
    var status: String  // ProposeStatus の rawValue を格納

    // ISO8601形式、クライアントが生成
    @Field(key: "created_at")
    var createdAt: String

    // サーバーが管理する更新日時
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID,
        contentHash: String,
        creatorPublicKey: String,
        creatorSignature: String,
        counterpartyPublicKey: String,
        createdAt: String
    ) {
        self.id = id
        self.contentHash = contentHash
        self.creatorPublicKey = creatorPublicKey
        self.creatorSignature = creatorSignature
        self.counterpartyPublicKey = counterpartyPublicKey
        self.status = ProposeStatus.proposed.rawValue
        self.createdAt = createdAt
        self.updatedAt = Date()
    }

    var proposeStatus: ProposeStatus {
        get { ProposeStatus(rawValue: status) ?? .proposed }
        set { status = newValue.rawValue }
    }
}
