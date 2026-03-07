import NIOSSL
import Fluent
import FluentSQLiteDriver
import FluentPostgresDriver
import Vapor

// configures your application
public func configure(_ app: Application) async throws {
    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // リクエストサイズ制限: 1MBまで
    app.routes.defaultMaxBodySize = "1mb"

    // Rate Limiting: 1分間に60リクエストまで
    app.middleware.use(RateLimitMiddleware(maxRequests: 60, windowSeconds: 60))

    // データベース設定
    try configureDatabase(app)

    app.migrations.add(CreateWevoProposeTables())

    // register routes
    try routes(app)
}

// データベース設定を環境に応じて切り替え
private func configureDatabase(_ app: Application) throws {
    // 環境変数でデータベースURLが指定されている場合はPostgreSQLを使用
    if let databaseURL = Environment.get("DATABASE_URL") {
        try configureDatabaseURL(app, url: databaseURL)
    } else if app.environment == .production {
        // 本番環境では個別の環境変数からPostgreSQL設定を読み取る
        try configurePostgreSQL(app)
    } else {
        // 開発/テスト環境ではSQLiteを使用
        app.databases.use(.sqlite(.file("db.sqlite")), as: .sqlite)
        app.logger.info("Using SQLite database (development mode)")
    }
}

// DATABASE_URL環境変数からPostgreSQL接続設定を解析
private func configureDatabaseURL(_ app: Application, url: String) throws {
    guard var postgresConfig = try? PostgresConfiguration(url: url) else {
        throw Abort(.internalServerError, reason: "Invalid DATABASE_URL format")
    }

    // TLS設定（Heroku、Fly.io等のクラウドプロバイダー対応）
    // 本番環境では自己署名証明書を許可
    if app.environment == .production {
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        postgresConfig.tlsConfiguration = tlsConfig
    }

    app.databases.use(.postgres(configuration: postgresConfig), as: .psql)
    app.logger.info("Using PostgreSQL database from DATABASE_URL")
}

// 個別の環境変数からPostgreSQL設定を構築
private func configurePostgreSQL(_ app: Application) throws {
    let hostname = Environment.get("DATABASE_HOST") ?? "localhost"
    let port = Environment.get("DATABASE_PORT").flatMap(Int.init) ?? 5432
    let username = Environment.get("DATABASE_USERNAME") ?? "vapor"
    let password = Environment.get("DATABASE_PASSWORD") ?? ""
    let database = Environment.get("DATABASE_NAME") ?? "wevospace"

    var postgresConfig = PostgresConfiguration(
        hostname: hostname,
        port: port,
        username: username,
        password: password,
        database: database
    )

    // TLS設定（本番環境では自己署名証明書を許可）
    if app.environment == .production {
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        postgresConfig.tlsConfiguration = tlsConfig
    }

    app.databases.use(.postgres(configuration: postgresConfig), as: .psql)
    app.logger.info("Using PostgreSQL database: \(hostname):\(port)/\(database)")
}
