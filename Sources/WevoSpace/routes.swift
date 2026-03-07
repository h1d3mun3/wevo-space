import Fluent
import Vapor

func routes(_ app: Application) throws {
    app.get { req async in
        "It works!"
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }
    
    // ヘルスチェックエンドポイント（監視用）
    app.get("health") { req async -> [String: String] in
        return [
            "status": "ok",
            "timestamp": "\(Date().timeIntervalSince1970)"
        ]
    }

    try app.register(collection: ProposeController())
}
