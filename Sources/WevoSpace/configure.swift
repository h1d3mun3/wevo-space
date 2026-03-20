import NIOSSL
import Fluent
import FluentSQLiteDriver
import FluentPostgresDriver
import Vapor

// configures your application
public func configure(_ app: Application) async throws {
    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // Request size limit: up to 1 MB
    app.routes.defaultMaxBodySize = "1mb"

    // Rate limiting: up to 60 requests per minute
    app.middleware.use(RateLimitMiddleware(requestLimit: 60, timeWindow: 60))

    // Database configuration
    try configureDatabase(app)

    app.migrations.add(CreateProposesTable())
    app.migrations.add(CreateCounterpartiesTable())
    app.migrations.add(AddSignatureVersionAndResetProposes())

    // register routes
    try routes(app)
}

// Switch database configuration based on environment
private func configureDatabase(_ app: Application) throws {
    // Use PostgreSQL if DATABASE_URL environment variable is set
    if let databaseURL = Environment.get("DATABASE_URL") {
        try configureDatabaseURL(app, url: databaseURL)
    } else if app.environment == .production {
        // In production, read PostgreSQL settings from individual environment variables
        try configurePostgreSQL(app)
    } else {
        // Use SQLite in development/test environments
        app.databases.use(.sqlite(.file("db.sqlite")), as: .sqlite)
        app.logger.info("Using SQLite database (development mode)")
    }
}

// Parse PostgreSQL connection settings from DATABASE_URL environment variable
private func configureDatabaseURL(_ app: Application, url: String) throws {
    guard let postgresConfig = try? PostgresConfiguration(url: url) else {
        throw Abort(.internalServerError, reason: "Invalid DATABASE_URL format")
    }

    app.databases.use(.postgres(configuration: postgresConfig), as: .psql)
    app.logger.info("Using PostgreSQL database from DATABASE_URL")
}

// Build PostgreSQL settings from individual environment variables
private func configurePostgreSQL(_ app: Application) throws {
    let hostname = Environment.get("DATABASE_HOST") ?? "localhost"
    let port = Environment.get("DATABASE_PORT").flatMap(Int.init) ?? 5432
    let username = Environment.get("DATABASE_USERNAME") ?? "vapor"
    guard let password = Environment.get("DATABASE_PASSWORD") else {
        throw Abort(.internalServerError, reason: "DATABASE_PASSWORD environment variable is required in production")
    }
    let database = Environment.get("DATABASE_NAME") ?? "wevospace"

    let postgresConfig = PostgresConfiguration(
        hostname: hostname,
        port: port,
        username: username,
        password: password,
        database: database
    )

    app.databases.use(.postgres(configuration: postgresConfig), as: .psql)
    app.logger.info("Using PostgreSQL database: \(hostname):\(port)/\(database)")
}
