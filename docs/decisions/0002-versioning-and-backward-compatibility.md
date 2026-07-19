# Decision 0002: Versioning and Backward Compatibility Policy

## Status

Accepted — 2026-07-18

## Context

This decision implements one part of the compatibility requirement fixed by
[Decision 0001](0001-forward-and-backward-compatibility-requirement.md): because
`wevo-space` deployments and `wevo` clients are decentralized and cannot be forced to
upgrade in lockstep, `wevo-space` must remain usable by `wevo` clients older than
itself. (The reverse direction — a `wevo` client remaining usable against a
`wevo-space` deployment older than itself, and this server's behavior toward clients
*newer* than itself — is not yet analyzed here; see Open Follow-ups below.)

WevoSpace and its client, [`wevo`](https://www.github.com/h1d3mun3/wevo), are versioned
independently, in separate git repositories. Each carries its own marketing/package
version number:

- `wevo-space`: the `version` string returned by the `/info` endpoint
  (`Sources/WevoSpace/routes.swift`), currently bumped to `2.0.0` on the `rc-2.0.0`
  branch.
- `wevo`: `MARKETING_VERSION` in `Wevo.xcodeproj/project.pbxproj`, currently also
  bumped to `2.0.0`.

Investigation of both repositories' history found that this `2.0.0` bump, in both
repos, was a standalone commit that changed only the version string (produced by the
`create-rc-branch.yml` CI workflow taking an arbitrary `X.Y.Z` input) — it introduced
no API or protocol change. The actual breaking work in this project's history — a
change to the signed-message format to embed the creator's public key, and the
addition of a `signatureVersion` field on `Propose`/`Dissolve`/`Honor`/`Part` records
(`Sources/WevoSpace/Migrations/AddSignatureVersionAndResetProposes.swift`,
`Sources/WevoSpace/Controllers/ProposeController.swift`) — had already shipped months
earlier, under what were `0.x` / `1.x` version numbers on both sides.

In other words: the marketing version number does not currently track, and has not
historically tracked, wire-protocol compatibility. Nothing enforces that correlation.
Today:

- All HTTP routes are grouped under a single `/v1` prefix
  (`Sources/WevoSpace/routes.swift`); no `/v2` group exists.
- `signatureVersion` is checked and can reject unrecognized values — see the test
  `"Rejects a propose with an unsupported signatureVersion"`
  (`Tests/WevoSpaceTests/SyncServiceTests.swift`) — but this guards peer-to-peer sync
  between WevoSpace nodes, not requests from `wevo` clients.
- There is no client-version negotiation of any kind: no `X-Client-Version` header, no
  `User-Agent` parsing, no minimum-supported-client gate anywhere in `Sources/`.
- No `CHANGELOG.md` or migration guide exists in this repository.

This ambiguity is a problem: a future release could pair a marketing version bump
with an actual breaking change, and nothing in the codebase or process would flag
that to client authors or operators.

## Decision

1. **The wire protocol version is tracked separately from the marketing/package
   version**, through two existing mechanisms, which we formalize as the source of
   truth for compatibility:
   - The **HTTP route prefix** (`/v1`, and a future `/v2`, ...) for breaking changes
     to request/response shape, auth, or endpoint behavior.
   - The **`signatureVersion` field** on signed payloads for breaking changes to the
     cryptographic signing/verification scheme.
2. **A bump to the `version` string served at `/info` does not, by itself, indicate a
   breaking change**, and must not be used by operators or client authors to infer
   compatibility. Conversely, the absence of a version bump does not guarantee
   compatibility either — only the mechanisms in (1) do.
3. **Any change that would require incrementing the `/vN` prefix or `signatureVersion`
   must be recorded in a new decision in this directory**, and a matching entry must
   be added to `wevo`'s `docs/decisions/`, cross-referenced by number.
4. Until item 5 is addressed, WevoSpace will continue to accept requests from any
   client, of any marketing version, that produces a request matching a
   `signatureVersion` the server recognizes under the current `/vN` route group.
5. **Open follow-up, not yet decided**: whether and how to add an explicit
   minimum-supported-client mechanism (e.g. a required client-version header with a
   server-enforced floor). No such mechanism exists today. Until a future decision
   addresses this, "backward compatibility" for `wevo` clients means: any client
   still speaking the current `/vN` HTTP shape and a recognized `signatureVersion`
   will continue to work, indefinitely, with no deprecation window guaranteed or
   enforced.
6. **Open follow-up, not yet decided**: this decision only covers WevoSpace's
   backward compatibility toward older `wevo` clients. Decision 0001 also requires
   *forward* compatibility — this server continuing to behave correctly when talked
   to by a `wevo` client newer than itself (e.g. tolerating unrecognized fields
   instead of rejecting the request outright, or degrading gracefully instead of
   corrupting state). No such analysis or mechanism exists yet and should be the
   subject of a future decision in this directory.

## Consequences

- Marketing version numbers (App Store versions, `/info` version string) can move for
  business/release reasons without implying, or requiring, a protocol change.
- Client authors and integrators can rely on the `/vN` prefix and `signatureVersion`
  as the only authoritative compatibility signals — not the marketing version.
- This policy is process, not code: nothing currently prevents a future PR from
  shipping a breaking change without bumping `/vN` or `signatureVersion`, or without
  writing the required decision entry. Reviewers should treat a missing entry on a
  protocol-facing change as a blocking gap.
- Because there is no enforced minimum client version, WevoSpace cannot currently
  drop support for old but still-`/v1`-compatible clients without a separate,
  future decision (see item 5 above).
- This decision is a partial implementation of Decision 0001: it addresses this
  server's backward compatibility toward older clients, but not yet its forward
  compatibility toward newer ones (see item 6 above). It should not be read as
  satisfying Decision 0001 in full.
