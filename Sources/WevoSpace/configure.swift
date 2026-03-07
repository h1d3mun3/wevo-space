import NIOSSL
import Fluent
import FluentSQLiteDriver
import Vapor

// configures your application
public func configure(_ app: Application) async throws {
    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // リクエストサイズ制限: 1MBまで
    app.routes.defaultMaxBodySize = "1mb"
    
    // Rate Limiting: 1分間に60リクエストまで
    app.middleware.use(RateLimitMiddleware(maxRequests: 60, windowSeconds: 60))

    app.databases.use(DatabaseConfigurationFactory.sqlite(.file("db.sqlite")), as: .sqlite)

    app.migrations.add(CreateWevoProposeTables())

    // register routes
    try routes(app)
}
