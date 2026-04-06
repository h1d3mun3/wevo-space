@testable import WevoSpace
import VaporTesting
import Testing
import Fluent
import Foundation

@Suite("SyncService Tests", .serialized)
struct SyncServiceTests {

    // MARK: - App Setup

    private func withApp(test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            app.databases.use(.sqlite(.memory), as: .sqlite)
            app.migrations.add(CreateProposesTable())
            app.migrations.add(CreateCounterpartiesTable())
            app.migrations.add(AddSignatureVersionAndResetProposes())
            app.migrations.add(AddDissolveSignatureToPropose())
            app.migrations.add(AddPerPartyDissolveSignatures())
            app.migrations.add(CreateSyncCheckpointsTable())
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

    // MARK: - Mock

    /// Tracks calls to fetchProposes and returns pre-configured pages.
    actor MockSyncPeerClient: SyncPeerFetching {
        private let pages: [[ProposeResponse]]
        private(set) var callCount = 0
        private(set) var capturedOffsets: [Int] = []

        init(pages: [[ProposeResponse]]) {
            self.pages = pages
        }

        func fetchProposes(from peerURL: String, after: Date?, limit: Int, offset: Int) async throws -> [ProposeResponse] {
            capturedOffsets.append(offset)
            let index = callCount
            callCount += 1
            guard index < pages.count else { return [] }
            return pages[index]
        }
    }

    actor ThrowingPeerClient: SyncPeerFetching {
        func fetchProposes(from peerURL: String, after: Date?, limit: Int, offset: Int) async throws -> [ProposeResponse] {
            throw URLError(.notConnectedToInternet)
        }
    }

    // MARK: - Helpers

    /// Creates a minimal ProposeResponse with a unique ID for use as sync test data.
    private func makeProposeResponse(id: UUID = UUID()) throws -> ProposeResponse {
        let json = """
        {
            "id": "\(id.uuidString)",
            "contentHash": "test-hash",
            "creatorPublicKey": "creator-jwk",
            "creatorSignature": "creator-sig",
            "counterparties": [{"publicKey": "cp-jwk"}],
            "status": "proposed",
            "signatureVersion": 1,
            "createdAt": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        return try JSONDecoder().decode(ProposeResponse.self, from: json)
    }

    private func makePage(count: Int) throws -> [ProposeResponse] {
        try (0..<count).map { _ in try makeProposeResponse() }
    }

    // MARK: - Pagination Tests

    @Test("Fetches multiple pages and merges all records")
    func testFetchesMultiplePagesAndMergesAll() async throws {
        try await withApp { app in
            // 3 pages: 500 + 500 + 200 = 1200 total
            let page1 = try makePage(count: 500)
            let page2 = try makePage(count: 500)
            let page3 = try makePage(count: 200)
            let mock = MockSyncPeerClient(pages: [page1, page2, page3])

            let service = SyncService(app: app, peers: ["https://node-b.example.com"], syncSecret: nil, peerClient: mock)
            await service.pullFromAllPeers()

            let fetchCallCount = await mock.callCount
            let offsets = await mock.capturedOffsets

            #expect(fetchCallCount == 3)
            #expect(offsets == [0, 500, 1000])

            let dbCount = try await Propose.query(on: app.db).count()
            #expect(dbCount == 1200)
        }
    }

    @Test("Stops after single page when count is below page size")
    func testStopsAfterSinglePage() async throws {
        try await withApp { app in
            let page = try makePage(count: 42)
            let mock = MockSyncPeerClient(pages: [page])

            let service = SyncService(app: app, peers: ["https://node-b.example.com"], syncSecret: nil, peerClient: mock)
            await service.pullFromAllPeers()

            let fetchCallCount = await mock.callCount
            #expect(fetchCallCount == 1)

            let dbCount = try await Propose.query(on: app.db).count()
            #expect(dbCount == 42)
        }
    }

    @Test("Stops at exact page size boundary with empty last page")
    func testStopsAtPageBoundaryWithEmptyLastPage() async throws {
        try await withApp { app in
            // Exactly 500 records — fetches page 1 (500), then page 2 (0) and stops
            let page1 = try makePage(count: 500)
            let page2: [ProposeResponse] = []
            let mock = MockSyncPeerClient(pages: [page1, page2])

            let service = SyncService(app: app, peers: ["https://node-b.example.com"], syncSecret: nil, peerClient: mock)
            await service.pullFromAllPeers()

            let fetchCallCount = await mock.callCount
            #expect(fetchCallCount == 2)

            let dbCount = try await Propose.query(on: app.db).count()
            #expect(dbCount == 500)
        }
    }

    @Test("Handles peer fetch error gracefully without throwing")
    func testHandlesFetchErrorGracefully() async throws {
        try await withApp { app in
            let service = SyncService(app: app, peers: ["https://unreachable.example.com"], syncSecret: nil, peerClient: ThrowingPeerClient())

            // Should not throw
            await service.pullFromAllPeers()

            let dbCount = try await Propose.query(on: app.db).count()
            #expect(dbCount == 0)
        }
    }

    @Test("Syncs from multiple peers independently")
    func testSyncsFromMultiplePeers() async throws {
        try await withApp { app in
            // Each peer contributes 10 unique records
            var callIndex = 0
            let peer1Pages = [try makePage(count: 10)]
            let peer2Pages = [try makePage(count: 10)]
            let mock = MockSyncPeerClient(pages: peer1Pages + peer2Pages)

            let service = SyncService(
                app: app,
                peers: ["https://node-b.example.com", "https://node-c.example.com"],
                syncSecret: nil,
                peerClient: mock
            )
            await service.pullFromAllPeers()

            let dbCount = try await Propose.query(on: app.db).count()
            #expect(dbCount == 20)
        }
    }

    @Test("Upsert is idempotent across sync cycles")
    func testUpsertIsIdempotent() async throws {
        try await withApp { app in
            let page = try makePage(count: 5)
            // Same page returned twice (simulates two sync cycles with no new data)
            let mock = MockSyncPeerClient(pages: [page, page])

            let service = SyncService(app: app, peers: ["https://node-b.example.com"], syncSecret: nil, peerClient: mock)

            // First sync
            await service.pullFromAllPeers()
            // Second sync (same data)
            await service.pullFromAllPeers()

            let dbCount = try await Propose.query(on: app.db).count()
            #expect(dbCount == 5)
        }
    }
}
