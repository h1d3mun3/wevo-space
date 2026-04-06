import Foundation
import Vapor

// MARK: - Protocol

/// Abstraction over the HTTP layer for fetching proposes from a peer node.
/// Enables unit testing of SyncService's pagination loop without a real HTTP connection.
protocol SyncPeerFetching: Sendable {
    func fetchProposes(from peerURL: String, after: Date?, limit: Int, offset: Int) async throws -> [ProposeResponse]
}

// MARK: - Default Implementation

/// Production implementation using Vapor's HTTP client.
struct VaporSyncPeerClient: SyncPeerFetching {
    let app: Application
    let syncSecret: String?

    func fetchProposes(from peerURL: String, after: Date?, limit: Int, offset: Int) async throws -> [ProposeResponse] {
        var components = URLComponents(string: "\(peerURL)/v1/sync/proposes")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]
        if let after {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            queryItems.append(URLQueryItem(name: "after", value: formatter.string(from: after)))
        }
        components.queryItems = queryItems
        let urlString = components.url!.absoluteString

        var headers = HTTPHeaders()
        if let secret = syncSecret {
            headers.bearerAuthorization = BearerAuthorization(token: secret)
        }

        let response = try await app.client.get(URI(string: urlString), headers: headers)
        guard response.status == .ok else {
            throw Abort(.serviceUnavailable, reason: "Peer \(peerURL) returned \(response.status)")
        }
        return try response.content.decode([ProposeResponse].self)
    }
}
