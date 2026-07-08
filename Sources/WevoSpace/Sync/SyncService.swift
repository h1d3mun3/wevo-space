import Fluent
import Vapor

// Pulls Proposes from peer nodes and merges them into the local database.
// Actor isolation protects in-flight state; sync checkpoints are persisted in DB.
actor SyncService {
    private let app: Application
    let peers: [String]
    let syncSecret: String?
    private let peerClient: any SyncPeerFetching
    private let verifier: any SignatureVerifier
    private let pageSize: Int
    // Per-peer, per-cycle bounds so a malicious/compromised peer that always returns full pages
    // cannot spin pullFromPeer forever (starving other peers and exhausting CPU/DB/disk).
    private let maxPagesPerCycle: Int
    private let maxSecondsPerPeer: TimeInterval

    init(app: Application, peers: [String], syncSecret: String?, verifier: any SignatureVerifier = P256SignatureVerifier(),
         pageSize: Int = 500, maxPagesPerCycle: Int = 200, maxSecondsPerPeer: TimeInterval = 30) {
        self.app = app
        self.peers = peers
        self.syncSecret = syncSecret
        self.peerClient = VaporSyncPeerClient(app: app, syncSecret: syncSecret)
        self.verifier = verifier
        self.pageSize = pageSize
        self.maxPagesPerCycle = maxPagesPerCycle
        self.maxSecondsPerPeer = maxSecondsPerPeer
    }

    /// Initializer for testing: accepts injected SyncPeerFetching and SignatureVerifier implementations.
    init(app: Application, peers: [String], syncSecret: String?, peerClient: some SyncPeerFetching, verifier: any SignatureVerifier = P256SignatureVerifier(),
         pageSize: Int = 500, maxPagesPerCycle: Int = 200, maxSecondsPerPeer: TimeInterval = 30) {
        self.app = app
        self.peers = peers
        self.syncSecret = syncSecret
        self.peerClient = peerClient
        self.verifier = verifier
        self.pageSize = pageSize
        self.maxPagesPerCycle = maxPagesPerCycle
        self.maxSecondsPerPeer = maxSecondsPerPeer
    }

    func pullFromAllPeers() async {
        for peer in peers {
            await pullFromPeer(peer)
        }
    }

    private func pullFromPeer(_ peerURL: String) async {
        let syncStartedAt = Date()

        // Load last checkpoint from DB; buffer by 1 minute to handle clock skew
        let checkpoint: SyncCheckpoint?
        do {
            checkpoint = try await SyncCheckpoint.query(on: app.db)
                .filter(\.$peerURL == peerURL)
                .first()
        } catch {
            app.logger.error("[Sync] \(peerURL): failed to load checkpoint — \(error)")
            return
        }
        let after = checkpoint?.lastSyncAt.addingTimeInterval(-60)

        var offset = 0
        var totalMerged = 0
        var pages = 0
        var drained = false
        var maxUpdatedAt: Date?
        let deadline = syncStartedAt.addingTimeInterval(maxSecondsPerPeer)

        do {
            while true {
                if pages >= maxPagesPerCycle {
                    app.logger.warning("[Sync] \(peerURL): reached max pages (\(maxPagesPerCycle)) this cycle — resuming next cycle")
                    break
                }
                if Date() > deadline {
                    app.logger.warning("[Sync] \(peerURL): exceeded time budget (\(Int(maxSecondsPerPeer))s) this cycle — resuming next cycle")
                    break
                }
                let page = try await peerClient.fetchProposes(
                    from: peerURL,
                    after: after,
                    limit: pageSize,
                    offset: offset
                )
                for propose in page {
                    try await SyncService.upsertPropose(propose, on: app.db, logger: app.logger, verifier: self.verifier)
                    if let u = propose.updatedAt, maxUpdatedAt == nil || u > maxUpdatedAt! { maxUpdatedAt = u }
                }
                totalMerged += page.count
                pages += 1
                // If fewer results than page size, we've reached the last page
                if page.count < pageSize { drained = true; break }
                offset += pageSize
            }
        } catch {
            // Peer unreachable or returned invalid data — skip and retry next cycle
            app.logger.warning("[Sync] \(peerURL) skipped: \(error)")
            return
        }

        // Advance the checkpoint. On a full drain, use the pull start time (so proposes created
        // during this pull are picked up next cycle). On an early break (hit the page/time cap),
        // advance only to the newest record we actually processed — clamped to the start time so
        // a peer cannot future-date `updatedAt` to make us skip ahead — so the remainder is
        // resumed next cycle without being skipped and without re-pulling from scratch.
        let newCheckpoint: Date
        if drained {
            newCheckpoint = syncStartedAt
        } else if let m = maxUpdatedAt {
            newCheckpoint = min(m, syncStartedAt)
        } else {
            newCheckpoint = checkpoint?.lastSyncAt ?? syncStartedAt
        }
        do {
            if let existing = checkpoint {
                existing.lastSyncAt = newCheckpoint
                try await existing.save(on: app.db)
            } else {
                try await SyncCheckpoint(peerURL: peerURL, lastSyncAt: newCheckpoint).save(on: app.db)
            }
        } catch {
            app.logger.error("[Sync] \(peerURL): failed to persist checkpoint — \(error)")
        }

        if totalMerged > 0 {
            app.logger.info("[Sync] \(peerURL): merged \(totalMerged) propose(s)")
        }
    }

    // MARK: - Merge (static: no actor isolation needed, safe to call from anywhere)

    static func upsertPropose(_ incoming: ProposeResponse, on db: any Database, logger: Logger, verifier: any SignatureVerifier = P256SignatureVerifier()) async throws {
        if let existing = try await Propose.query(on: db)
            .filter(\.$id == incoming.id)
            .with(\.$counterparties)
            .first() {
            try await mergeInto(existing: existing, incoming: incoming, on: db, logger: logger, verifier: verifier)
        } else {
            try await createFrom(incoming: incoming, on: db, logger: logger, verifier: verifier)
        }
    }

    private static func mergeInto(existing: Propose, incoming: ProposeResponse, on db: any Database, logger: Logger, verifier: any SignatureVerifier) async throws {
        var changed = false
        let idStr = incoming.id.uuidString

        // A propose's identity — creator key and content hash — is fixed at creation and bound by
        // the creator signature. Never merge a record that disagrees on these (forgery or ID
        // collision), and always derive signature messages from the LOCAL stored values so a peer
        // cannot substitute a different creatorKey/hash to make its own signatures verify.
        guard incoming.creatorPublicKey == existing.creatorPublicKey,
              incoming.contentHash == existing.contentHash else {
            logger.warning("[Sync] propose \(idStr): creatorPublicKey/contentHash mismatch — merge rejected")
            return
        }
        let hash = existing.contentHash
        let creatorKey = existing.creatorPublicKey

        // Verifies an incoming signature+timestamp pair against the local value.
        // Returns (sig, ts) to adopt when local is nil and the incoming signature is valid.
        // When both local and peer have a value, verifies the peer and logs the outcome — but always keeps local.
        func adopt(
            localSig: String?, localTs: String?,
            peerSig: String?, peerTs: String?,
            message: (String) -> String,
            publicKey: String,
            field: String
        ) -> (sig: String, ts: String)? {
            guard let peerSig else { return nil }
            guard localSig == nil else {
                if localSig != peerSig {
                    if let ts = peerTs {
                        if verifier.verify(signature: peerSig, message: message(ts), publicKey: publicKey) {
                            logger.warning("[Sync] propose \(idStr) '\(field)': both valid — keeping local (first-writer wins)")
                        } else {
                            logger.warning("[Sync] propose \(idStr) '\(field)': peer signature invalid — keeping local")
                        }
                    } else {
                        logger.warning("[Sync] propose \(idStr) '\(field)': peer signature has no timestamp — keeping local")
                    }
                }
                return nil
            }
            guard let ts = peerTs else {
                logger.warning("[Sync] propose \(idStr) '\(field)': signature present but timestamp missing — rejected")
                return nil
            }
            if verifier.verify(signature: peerSig, message: message(ts), publicKey: publicKey) {
                return (peerSig, ts)
            }
            logger.warning("[Sync] propose \(idStr) '\(field)': invalid signature from peer — rejected")
            return nil
        }

        if let a = adopt(
            localSig: existing.honorCreatorSignature, localTs: existing.honorCreatorTimestamp,
            peerSig: incoming.honorCreatorSignature, peerTs: incoming.honorCreatorTimestamp,
            message: { ts in "honored.\(idStr)\(hash)\(creatorKey)\(ts)" },
            publicKey: creatorKey, field: "honorCreatorSignature"
        ) {
            existing.honorCreatorSignature = a.sig
            existing.honorCreatorTimestamp = a.ts
            changed = true
        }

        if let a = adopt(
            localSig: existing.partCreatorSignature, localTs: existing.partCreatorTimestamp,
            peerSig: incoming.partCreatorSignature, peerTs: incoming.partCreatorTimestamp,
            message: { ts in "parted.\(idStr)\(hash)\(creatorKey)\(ts)" },
            publicKey: creatorKey, field: "partCreatorSignature"
        ) {
            existing.partCreatorSignature = a.sig
            existing.partCreatorTimestamp = a.ts
            changed = true
        }

        // NOTE: incoming.dissolvedAt is deliberately NOT adopted here. It is a peer-supplied
        // string that previously drove the .dissolved status with no signature behind it. The
        // dissolved state is now derived from verified dissolve signatures (see computeStatus),
        // and dissolvedAt is recomputed from verified timestamps below (deriveDissolvedAt).

        if let a = adopt(
            localSig: existing.creatorDissolveSignature, localTs: existing.creatorDissolveTimestamp,
            peerSig: incoming.creatorDissolveSignature, peerTs: incoming.creatorDissolveTimestamp,
            message: { ts in "dissolved.\(idStr)\(hash)\(creatorKey)\(ts)" },
            publicKey: creatorKey, field: "creatorDissolveSignature"
        ) {
            existing.creatorDissolveSignature = a.sig
            existing.creatorDissolveTimestamp = a.ts
            changed = true
        }

        for incomingCP in incoming.counterparties {
            if let existingCP = existing.counterparties.first(where: { $0.publicKey == incomingCP.publicKey }) {
                var cpChanged = false
                let cpKey = incomingCP.publicKey
                let cpPrefix = String(cpKey.prefix(16))

                func adoptCP(
                    localSig: String?, localTs: String?,
                    peerSig: String?, peerTs: String?,
                    message: (String) -> String,
                    field: String
                ) -> (sig: String, ts: String)? {
                    adopt(
                        localSig: localSig, localTs: localTs,
                        peerSig: peerSig, peerTs: peerTs,
                        message: message, publicKey: cpKey,
                        field: "counterparty[\(cpPrefix)].\(field)"
                    )
                }

                if let a = adoptCP(
                    localSig: existingCP.signSignature, localTs: existingCP.signTimestamp,
                    peerSig: incomingCP.signSignature, peerTs: incomingCP.signTimestamp,
                    message: { ts in "signed.\(idStr)\(hash)\(cpKey)\(ts)" },
                    field: "signSignature"
                ) { existingCP.signSignature = a.sig; existingCP.signTimestamp = a.ts; cpChanged = true }

                if let a = adoptCP(
                    localSig: existingCP.honorSignature, localTs: existingCP.honorTimestamp,
                    peerSig: incomingCP.honorSignature, peerTs: incomingCP.honorTimestamp,
                    message: { ts in "honored.\(idStr)\(hash)\(cpKey)\(ts)" },
                    field: "honorSignature"
                ) { existingCP.honorSignature = a.sig; existingCP.honorTimestamp = a.ts; cpChanged = true }

                if let a = adoptCP(
                    localSig: existingCP.partSignature, localTs: existingCP.partTimestamp,
                    peerSig: incomingCP.partSignature, peerTs: incomingCP.partTimestamp,
                    message: { ts in "parted.\(idStr)\(hash)\(cpKey)\(ts)" },
                    field: "partSignature"
                ) { existingCP.partSignature = a.sig; existingCP.partTimestamp = a.ts; cpChanged = true }

                if let a = adoptCP(
                    localSig: existingCP.dissolveSignature, localTs: existingCP.dissolveTimestamp,
                    peerSig: incomingCP.dissolveSignature, peerTs: incomingCP.dissolveTimestamp,
                    message: { ts in "dissolved.\(idStr)\(hash)\(cpKey)\(ts)" },
                    field: "dissolveSignature"
                ) { existingCP.dissolveSignature = a.sig; existingCP.dissolveTimestamp = a.ts; cpChanged = true }

                if cpChanged {
                    try await existingCP.save(on: db)
                    changed = true
                }
            } else {
                // Counterparty present on the peer but not locally — REJECT it. The counterparty
                // set is fixed at creation: the creator-signature message embeds the sorted
                // counterparty keys (see createFrom / ProposeController.create), so a legitimate
                // propose never gains members afterward. Accepting a peer-supplied member would let
                // a rogue node inject an unsigned "phantom" counterparty (which breaks the
                // allSatisfy checks in computeStatus and permanently downgrades honored/signed
                // proposes back to .proposed) or a self-signed key (forging .parted/.dissolved on
                // someone else's agreement). Membership is never re-bound to the creator signature
                // here, so the only safe action is to skip.
                logger.warning("[Sync] propose \(idStr): counterparty \(String(incomingCP.publicKey.prefix(16))) is not in the creator-signed set — rejected")
            }
        }

        if changed {
            existing.dissolvedAt = deriveDissolvedAt(propose: existing, counterparties: existing.counterparties)
            existing.proposeStatus = computeStatus(propose: existing, counterparties: existing.counterparties)
            try await existing.save(on: db)
        }
    }

    private static func createFrom(incoming: ProposeResponse, on db: any Database, logger: Logger, verifier: any SignatureVerifier) async throws {
        let idStr = incoming.id.uuidString
        let hash = incoming.contentHash
        let creatorKey = incoming.creatorPublicKey

        // Reject oversized records so a peer cannot push a propose with tens of thousands of
        // counterparties (storage/CPU amplification), matching the public create-path limit.
        guard incoming.counterparties.count <= ProposeController.maxCounterparties else {
            logger.warning("[Sync] propose \(idStr): too many counterparties (\(incoming.counterparties.count)) — skipped")
            return
        }

        // Only accept signature schemes this build actually understands. Otherwise the
        // peer-supplied signatureVersion would be stored unvalidated and the record verified
        // against the wrong message format.
        guard incoming.signatureVersion == 1 else {
            logger.warning("[Sync] propose \(idStr): unsupported signatureVersion \(incoming.signatureVersion) — skipped")
            return
        }

        // Verify creation signature before persisting anything
        let sortedKeys = incoming.counterparties.map { $0.publicKey }.sorted().joined()
        let createMsg = "proposed.\(idStr)\(hash)\(creatorKey)\(sortedKeys)\(incoming.createdAt)"
        guard verifier.verify(signature: incoming.creatorSignature, message: createMsg, publicKey: creatorKey) else {
            logger.warning("[Sync] propose \(idStr): invalid creatorSignature — skipped")
            return
        }

        let propose = Propose(
            id: incoming.id,
            contentHash: hash,
            creatorPublicKey: creatorKey,
            creatorSignature: incoming.creatorSignature,
            createdAt: incoming.createdAt,
            signatureVersion: incoming.signatureVersion
        )

        func verifyAndSet(sig: String?, ts: String?, message: (String) -> String, field: String) -> (sig: String, ts: String)? {
            guard let sig, let ts else { return nil }
            if verifier.verify(signature: sig, message: message(ts), publicKey: creatorKey) { return (sig, ts) }
            logger.warning("[Sync] propose \(idStr): invalid \(field) — skipped")
            return nil
        }

        if let a = verifyAndSet(sig: incoming.honorCreatorSignature, ts: incoming.honorCreatorTimestamp,
                                message: { ts in "honored.\(idStr)\(hash)\(creatorKey)\(ts)" }, field: "honorCreatorSignature") {
            propose.honorCreatorSignature = a.sig; propose.honorCreatorTimestamp = a.ts
        }
        if let a = verifyAndSet(sig: incoming.partCreatorSignature, ts: incoming.partCreatorTimestamp,
                                message: { ts in "parted.\(idStr)\(hash)\(creatorKey)\(ts)" }, field: "partCreatorSignature") {
            propose.partCreatorSignature = a.sig; propose.partCreatorTimestamp = a.ts
        }
        if let a = verifyAndSet(sig: incoming.creatorDissolveSignature, ts: incoming.creatorDissolveTimestamp,
                                message: { ts in "dissolved.\(idStr)\(hash)\(creatorKey)\(ts)" }, field: "creatorDissolveSignature") {
            propose.creatorDissolveSignature = a.sig; propose.creatorDissolveTimestamp = a.ts
        }
        // dissolvedAt is derived from verified dissolve signatures below, never copied from the peer.

        var counterparties: [ProposeCounterparty] = []
        for cp in incoming.counterparties {
            let cpKey = cp.publicKey
            let counterparty = ProposeCounterparty(proposeID: incoming.id, publicKey: cpKey)

            func verifyCP(sig: String?, ts: String?, prefix: String, message: (String) -> String) -> (sig: String, ts: String)? {
                guard let sig, let ts else { return nil }
                if verifier.verify(signature: sig, message: message(ts), publicKey: cpKey) { return (sig, ts) }
                logger.warning("[Sync] propose \(idStr): invalid counterparty \(prefix) for \(String(cpKey.prefix(16))) — skipped")
                return nil
            }

            if let a = verifyCP(sig: cp.signSignature, ts: cp.signTimestamp, prefix: "signSignature",
                                message: { ts in "signed.\(idStr)\(hash)\(cpKey)\(ts)" }) {
                counterparty.signSignature = a.sig; counterparty.signTimestamp = a.ts
            }
            if let a = verifyCP(sig: cp.honorSignature, ts: cp.honorTimestamp, prefix: "honorSignature",
                                message: { ts in "honored.\(idStr)\(hash)\(cpKey)\(ts)" }) {
                counterparty.honorSignature = a.sig; counterparty.honorTimestamp = a.ts
            }
            if let a = verifyCP(sig: cp.partSignature, ts: cp.partTimestamp, prefix: "partSignature",
                                message: { ts in "parted.\(idStr)\(hash)\(cpKey)\(ts)" }) {
                counterparty.partSignature = a.sig; counterparty.partTimestamp = a.ts
            }
            if let a = verifyCP(sig: cp.dissolveSignature, ts: cp.dissolveTimestamp, prefix: "dissolveSignature",
                                message: { ts in "dissolved.\(idStr)\(hash)\(cpKey)\(ts)" }) {
                counterparty.dissolveSignature = a.sig; counterparty.dissolveTimestamp = a.ts
            }

            counterparties.append(counterparty)
        }

        propose.dissolvedAt = deriveDissolvedAt(propose: propose, counterparties: counterparties)
        propose.proposeStatus = computeStatus(propose: propose, counterparties: counterparties)
        try await propose.save(on: db)
        for cp in counterparties {
            try await cp.save(on: db)
        }
    }

    // Recomputes status from the signatures actually present.
    // Never trusts the status field received from a peer.
    static func computeStatus(propose: Propose, counterparties: [ProposeCounterparty]) -> ProposeStatus {
        if propose.honorCreatorSignature != nil,
           !counterparties.isEmpty,
           counterparties.allSatisfy({ $0.honorSignature != nil }) {
            return .honored
        }
        if propose.partCreatorSignature != nil || counterparties.contains(where: { $0.partSignature != nil }) {
            return .parted
        }
        // Dissolved only when at least one VERIFIED dissolve signature is present. The previous
        // `dissolvedAt != nil` test trusted a peer-supplied string with no signature behind it,
        // letting any peer force a propose to .dissolved. dissolvedAt is now display-only.
        if propose.creatorDissolveSignature != nil
            || counterparties.contains(where: { $0.dissolveSignature != nil }) {
            return .dissolved
        }
        if !counterparties.isEmpty, counterparties.allSatisfy({ $0.signSignature != nil }) {
            return .signed
        }
        return .proposed
    }

    /// Derives dissolvedAt from VERIFIED dissolve signatures only (creator or any counterparty),
    /// never from the peer-supplied dissolvedAt field. Dissolve signatures are only ever stored
    /// after `verifier.verify` succeeds, so the associated timestamps are trustworthy for display.
    /// Returns the earliest timestamp (ISO8601 strings sort chronologically), or nil if undissolved.
    static func deriveDissolvedAt(propose: Propose, counterparties: [ProposeCounterparty]) -> String? {
        var stamps: [String] = []
        if propose.creatorDissolveSignature != nil, let ts = propose.creatorDissolveTimestamp {
            stamps.append(ts)
        }
        for cp in counterparties where cp.dissolveSignature != nil {
            if let ts = cp.dissolveTimestamp { stamps.append(ts) }
        }
        return stamps.min()
    }
}

// MARK: - Application Storage

extension Application {
    var syncService: SyncService? {
        get { storage[SyncServiceKey.self] }
        set { storage[SyncServiceKey.self] = newValue }
    }

    private struct SyncServiceKey: StorageKey {
        typealias Value = SyncService
    }

    /// Verifier used by the batch sync endpoint. Defaults to P256SignatureVerifier.
    /// Override in tests to inject a permissive verifier for synthetic payloads.
    var syncVerifier: any SignatureVerifier {
        get { storage[SyncVerifierKey.self] ?? P256SignatureVerifier() }
        set { storage[SyncVerifierKey.self] = newValue }
    }

    private struct SyncVerifierKey: StorageKey {
        typealias Value = any SignatureVerifier
    }
}
