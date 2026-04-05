import Vapor

// Drives periodic pulls from peer nodes.
// Runs one full pull on startup (initial catch-up), then repeats at the configured interval.
// Each cycle waits for completion before sleeping — no overlapping pulls.
final class SyncScheduler: LifecycleHandler {
    private let syncService: SyncService
    private let interval: TimeInterval
    private nonisolated(unsafe) var task: Task<Void, Never>?

    init(syncService: SyncService, interval: TimeInterval) {
        self.syncService = syncService
        self.interval = interval
    }

    func didBoot(_ application: Application) throws {
        task = Task {
            // Initial full pull on startup (lastSyncAt is empty, so no ?after param)
            await syncService.pullFromAllPeers()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await syncService.pullFromAllPeers()
            }
        }
        application.logger.info("[Sync] Scheduler started (\(Int(interval))s interval, \(syncService.peers.count) peer(s))")
    }

    func shutdown(_ application: Application) {
        task?.cancel()
        application.logger.info("[Sync] Scheduler stopped")
    }
}
