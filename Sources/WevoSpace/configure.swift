import NIOSSL
import Fluent
import FluentSQLiteDriver
import Vapor

// configures your application
public func configure(_ app: Application) async throws {
    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // Rate Limiting: 1分間に60リクエストまで
    app.middleware.use(RateLimitMiddleware(maxRequests: 60, windowSeconds: 60))

    app.databases.use(DatabaseConfigurationFactory.sqlite(.file("db.sqlite")), as: .sqlite)

    app.migrations.add(CreateWevoProposeTables())

    // register routes
    try routes(app)
}
