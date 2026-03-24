# wevo — Private Beta

> *What if the record of an agreement belonged to the people who made it?*

---

## The problem with trust on the internet

Every time you collaborate online, a record of that collaboration gets created somewhere. But you don't own it.

It lives in a Slack thread, a PDF behind a portal, a freelance platform's rating system. When those services change, shut down, or quietly revise their terms, your history disappears with them — or worse, it stays, but under rules you never agreed to.

Most trust and reputation systems share the same underlying flaw:

- **Opaque** — you can't see how scores or ratings are derived
- **Non-portable** — you can't take your history anywhere else
- **Platform-owned** — the platform decides what counts and what doesn't

There is no standard for "this happened, and these people agreed to it" that works outside of a specific service.

---

## What wevo explores

wevo is an experiment in making agreements portable and self-certifying.

Instead of asking a platform to "trust us that this happened," wevo records *the cryptographic evidence itself* — who signed what, when, and how the agreement resolved. Signatures are generated on-device using **P256 ECDSA** via Apple CryptoKit, stored in the Keychain, and verified locally.

The server (wevo-space) stores nothing private. It holds only SHA256 hashes of message content and public-key-signed attestations. **The message body never leaves your device.**

```
You sign.
They sign.
The proof lives on both devices —
verifiable without trusting any middleman.
```

The name encodes the idea: **W**eb of **E**ndorsed **V**erifiable **O**aths. Not scores. Not ratings. Signed commitments you carry with you.

---

## Why it might interest iOS engineers specifically

This beta is for people who will appreciate what's happening under the hood.

- **Keychain + CryptoKit** used for something beyond "sign in with biometrics" — each Identity is a `P256.Signing.PrivateKey` used to attest real-world commitments
- **Local-first architecture** — full functionality offline; server sync is best-effort, not a dependency
- **SwiftData + iCloud** as the persistence layer, with a custom file-based exchange protocol (`.wevo-propose`, `.wevo-contact`, `.wevo-identity`)
- **AirDrop as a trust ceremony** — sharing a public key fingerprint in person, then verifying it out-of-band before signing
- **Clean Architecture** — UseCase/Repository separation throughout; the backend (wevo-space) is a Vapor app small enough to read in an afternoon

The system as a whole is deliberately small. There's no magic. Every signature, every state transition, every byte sent to the server is documented and auditable.

---

## What this is (and isn't)

This is a **private beta** shared with a small group. wevo is not a finished product and not a formal protocol. It's an exploration of a design space that doesn't quite have a name yet.

Expect rough edges. Expect ideas that don't fully work yet. Expect an app that asks questions it doesn't yet answer.

What's useful to hear from beta testers:

- Does the mental model click? Or does something feel off?
- After getting past the setup, is the signing flow intuitive?
- What feels unnecessary? What feels missing?
- Is "privacy-first, server-as-optional-sync" a meaningful distinction in practice?

---

## Getting started

→ [Getting Started guide](./getting-started.md)

Two devices make the full signing flow much more satisfying to test. If you only have one, you can still explore identity creation, Propose authoring, and the local data model — but you'll need a second device (or a friend nearby) to complete the loop.
