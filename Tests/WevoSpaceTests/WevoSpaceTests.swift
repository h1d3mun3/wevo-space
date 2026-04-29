@testable import WevoSpace
import VaporTesting
import Testing
import Fluent

@Suite("App Tests with DB", .serialized)
struct WevoSpaceTests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("Health check route returns ok")
    func healthCheck() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "health", afterResponse: { res async in
                #expect(res.status == .ok)
                let body = try? res.content.decode([String: String].self)
                #expect(body?["status"] == "ok")
            })
        }
    }

    @Test("Info route returns protocol metadata")
    func infoRoute() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "info", afterResponse: { res async in
                #expect(res.status == .ok)
                let body = try? res.content.decode(InfoResponse.self)
                #expect(body?.protocolName == "wevo")
                #expect(body?.version == "0.3.0")
            })
        }
    }
}
