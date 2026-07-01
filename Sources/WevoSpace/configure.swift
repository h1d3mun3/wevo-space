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
    // Middleware covers VaporTesting (pre-collected ByteBuffer); defaultMaxBodySize covers streaming bodies.
    app.middleware.use(RequestSizeLimitMiddleware(maxBytes: 1_000_000))
    app.routes.defaultMaxBodySize = "1mb"

    // Rate limiting: up to 60 requests per minute.
    // TRUSTED_PROXIES (comma-separated IPs) controls whose X-Forwarded-For / X-Real-IP headers are
    // honored; without it the limiter keys on the real transport peer, so the limit cannot be
    // bypassed by spoofing headers. A scheduler periodically evicts stale entries to bound memory.
    let trustedProxies = Set((Environment.get("TRUSTED_PROXIES") ?? "")
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty })
    let rateLimiter = RateLimitMiddleware(requestLimit: 60, timeWindow: 60, trustedProxies: trustedProxies)
    app.middleware.use(rateLimiter)
    app.lifecycle.use(RateLimitCleanupScheduler(middleware: rateLimiter, interval: 60))

    // Database configuration
    try configureDatabase(app)

    app.migrations.add(CreateProposesTable())
    app.migrations.add(CreateCounterpartiesTable())
    app.migrations.add(AddSignatureVersionAndResetProposes())
    app.migrations.add(AddDissolveSignatureToPropose())
    app.migrations.add(AddPerPartyDissolveSignatures())
    app.migrations.add(CreateSyncCheckpointsTable())

    // register routes
    try routes(app)

    // Node sync (optional — single-server mode when PEER_NODES is not set)
    let peerNodes = (Environment.get("PEER_NODES") ?? "")
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    if !peerNodes.isEmpty {
        // Federation requires inter-node authentication. Refuse to boot when peers are
        // configured but no usable SYNC_SECRET is set, rather than silently running an
        // unauthenticated sync surface.
        let syncSecret = Environment.get("SYNC_SECRET")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let syncSecret, !syncSecret.isEmpty else {
            throw ConfigurationError(reason: "PEER_NODES is configured but SYNC_SECRET is unset or empty — refusing to start federation without inter-node authentication.")
        }
        let syncInterval = Environment.get("SYNC_INTERVAL_SECONDS").flatMap(Double.init) ?? 60.0
        let syncService = SyncService(app: app, peers: peerNodes, syncSecret: syncSecret)
        app.syncService = syncService
        app.lifecycle.use(SyncScheduler(syncService: syncService, interval: syncInterval))
        app.logger.info("Node sync enabled: \(peerNodes.count) peer(s), interval \(Int(syncInterval))s")
    }
}

/// Thrown during application configuration when the environment is invalid or unsafe to start with.
struct ConfigurationError: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

private func isLocalHost(_ host: String?) -> Bool {
    guard let host else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
}

/// Resolves the PostgreSQL TLS policy. `DATABASE_SSL_MODE` overrides (`disable` / `require`);
/// otherwise verified TLS is used for remote hosts and disabled for localhost. `nil` means
/// plaintext. This makes managed-DB (Heroku/Railway/…) connections encrypted-by-default, while an
/// internal trusted network (e.g. docker-compose) can opt out with `DATABASE_SSL_MODE=disable`.
private func postgresTLSConfiguration(host: String?) -> TLSConfiguration? {
    switch Environment.get("DATABASE_SSL_MODE")?.lowercased() {
    case "disable": return nil
    case "require": return .makeClientConfiguration()
    default: return isLocalHost(host) ? nil : .makeClientConfiguration()
    }
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
    guard var postgresConfig = PostgresConfiguration(url: url) else {
        throw Abort(.internalServerError, reason: "Invalid DATABASE_URL format")
    }

    // PostgresConfiguration(url:) only enables TLS when the URL carries sslmode=require/ssl=true.
    // Enforce our policy so a managed-DB URL that omits sslmode is not connected in cleartext.
    let host = URLComponents(string: url)?.host
    switch Environment.get("DATABASE_SSL_MODE")?.lowercased() {
    case "disable":
        postgresConfig.tlsConfiguration = nil
    case "require":
        postgresConfig.tlsConfiguration = .makeClientConfiguration()
    default:
        if postgresConfig.tlsConfiguration == nil, !isLocalHost(host) {
            postgresConfig.tlsConfiguration = .makeClientConfiguration()
            app.logger.notice("DATABASE_URL host is remote and has no sslmode — enabling verified TLS (set DATABASE_SSL_MODE=disable to opt out).")
        }
    }

    app.databases.use(.postgres(configuration: postgresConfig), as: .psql)
    app.logger.info("Using PostgreSQL database from DATABASE_URL (TLS: \(postgresConfig.tlsConfiguration == nil ? "off" : "on"))")
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
    let tls = postgresTLSConfiguration(host: hostname)

    let postgresConfig = PostgresConfiguration(
        hostname: hostname,
        port: port,
        username: username,
        password: password,
        database: database,
        tlsConfiguration: tls
    )

    app.databases.use(.postgres(configuration: postgresConfig), as: .psql)
    app.logger.info("Using PostgreSQL database: \(hostname):\(port)/\(database) (TLS: \(tls == nil ? "off" : "on"))")
}
