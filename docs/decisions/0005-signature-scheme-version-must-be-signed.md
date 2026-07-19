# Decision 0005: The Signature Scheme Version Must Be Covered by the Signature (v2+)

## Status

Accepted — 2026-07-19

## Context

This is the server-side mirror of Decision 0005 in the
[`wevo`](https://www.github.com/h1d3mun3/wevo) client repository's
`docs/decisions/` — *"The Signature Scheme Version Must Be Covered by the
Signature (v2+)"*. Both must stay in sync because this concerns the signed
message format on the wire, which both sides independently verify.

Each `Propose` carries a `signatureVersion` field that governs *how* its
signatures are to be interpreted. Version 1 (v1) defines each operation's signed
message as `"<verb>." + proposeId + contentHash + signerPublicKey + timestamp`
(the creator's `proposed.` message additionally binds the sorted counterparty
keys and `createdAt`), where `<verb>` is one of
`proposed`/`signed`/`honored`/`parted`/`dissolved`.

WevoSpace does not merely store signatures — it **verifies** them. During
peer-to-peer sync, `SyncService` reconstructs the v1 signed messages and checks
each one via `P256SignatureVerifier` before persisting (e.g.
`"proposed.\(idStr)\(hash)\(creatorKey)\(sortedKeys)\(createdAt)"`,
`"honored.\(idStr)\(hash)\(key)\(ts)"`). That reconstruction is **hardcoded to
the v1 layout** and does not branch on `signatureVersion`.

`signatureVersion` itself is **not** part of the bytes that get signed. It is
persisted and round-tripped, but no signature commits to it. Today this is not
exploitable, because only v1 exists and `SyncService.createFrom` already
**refuses any record whose `signatureVersion != 1`** (skipping it with a warning)
rather than verifying it against the wrong message format. That guard is the
server-side manifestation of the principle below — but it only works because
there is exactly one scheme to accept.

The risk is forward-looking. The moment a second scheme (v2) is introduced with a
different signed-message layout, the value that decides *how to interpret a
signature* would sit outside the signed data. A record could then be relabelled
across versions and — absent the current single-version guard, once v2 must also
be accepted — verified under the wrong layout (signature/version confusion). This
is the same domain-separation principle the client applied when it removed an
arbitrary-text signing oracle and bound a Propose's displayed content to its
signed hash.

We cannot close this by adding `signatureVersion` to the v1 signed message now:
that would change the bytes every existing v1 signature was computed over,
invalidating all of them — a backward-compatibility break forbidden by Decisions
0001 and 0002.

## Decision

1. **The v1 signed-message format is frozen.** It MUST NOT change — in
   particular, `signatureVersion` is deliberately *not* retrofitted into v1
   signed bytes, because that would break every signature already in existence.
2. **Any future scheme version (v2+) MUST include `signatureVersion` in the
   signed byte string** (for example as a leading `"v2."`-style term or an
   explicit version field within the signed message), so a signature
   cryptographically commits to the scheme under which it was produced and cannot
   be reinterpreted under another.
3. **When the server adds v2 support, its verification (`SyncService` /
   `SignatureVerifier`) MUST select the message layout from the record's
   `signatureVersion` and, for v2+, confirm the version embedded in the signed
   bytes matches the record's** — never fall back to the v1 layout for a
   v2-labelled record, and never accept a record whose declared version disagrees
   with the signed one. The existing `signatureVersion == 1` acceptance guard MUST
   be widened deliberately (to the exact set of schemes the build understands),
   never removed.
4. **No code change is made now.** Only v1 exists and the single-version guard
   already fails safe; this decision records the constraint while the gap is
   understood, so it is honored by design when v2 is first drafted.

## Consequences

- The `signatureVersion` field remains a plain, unauthenticated label for as long
  as only v1 exists — safe today (and further protected by the reject-unknown
  guard), but load-bearing the instant v2 is added, at which point rule 2 is
  mandatory.
- This entry mirrors `wevo`'s Decision 0005 and must remain consistent with it;
  changes to the signed-message format require updating both, per this directory's
  README.
- Introducing v2 is itself a protocol change subject to Decision 0002's
  backward/forward-compatibility policy: v1 verification must keep working for v1
  records, and the two schemes must be distinguishable precisely because the
  version is now signed.
- This decision only fixes *that the version must be signed* in v2+. It does not
  design v2's message layout, decide when v2 is warranted, or plan the migration —
  those remain separate, per-change decisions.
