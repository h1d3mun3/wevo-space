# wevo Getting Started

wevo is an iOS app that uses P256 ECDSA signatures to prove "who agreed to what."
Signing happens entirely on-device using the Keychain. The server (wevo-space) is an optional sync layer.

> **Audience:** This is a TestFlight beta document for iOS engineers.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Setup](#2-setup)
3. [Core Workflow](#3-core-workflow)
4. [Technical Reference](#4-technical-reference)
5. [Known Limitations](#5-known-limitations)

---

## 1. Architecture Overview

### Key Concepts

| Concept | Description |
|---------|-------------|
| **Identity** | A P256 signing key pair that represents you. Stored in the Keychain. You can have multiple. |
| **Space** | A group that organizes Proposes. Linked to a wevo-space server URL. |
| **Contact** | A stored public key (JWK format) of another person. Used as a Propose counterparty. |
| **Propose** | A message that two parties sign. The message body is stored locally only. |

### Data Flow

```
[You]                                 [Counterparty]
  |                                         |
  | ① Create Identity (Keychain)            |
  |                                         |
  | ②── AirDrop .wevo-identity ────────────▶ |
  |       (saved as Contact on their side)  |
  |                                         |
  | ③ Create & sign Propose                 |
  |                                         |
  | ④── AirDrop .wevo-propose ─────────────▶ |
  |                                         |
  |                   ⑤ Counterparty signs  |
  |                                         |
  | ⑥ Both parties: Honor / Part / Dissolve |
```

### wevo vs. wevo-space

- **wevo (this app):** The client. Handles signature generation, verification, and local storage.
- **wevo-space:** A Vapor backend server. Stores signed hashes and mediates sync between devices.
- **Local-first design:** All signing operations work offline. Server communication is best-effort.

---

## 2. Setup

### 2-1. Create an Identity

An Identity is your signing key. Create at least one before doing anything else.

1. Tap **Manage Keys** at the bottom of the sidebar
2. Tap **+** in the top right
3. Enter a nickname (e.g. `Jane Smith (iPhone)`)
4. Tap **Create**

Internally, a `P256.Signing.PrivateKey` is generated and saved to the Keychain.
The public key is stored in JWK format. The first 8 bytes of its SHA256 hash are shown as a fingerprint.

> **Note:** Exporting an Identity requires biometric authentication. Make sure Face ID or Touch ID is enabled on your device.

### 2-2. Create a Space

A Space is a container for Proposes. Create one per project or relationship.

1. Tap **+** in the sidebar
2. Enter a name (e.g. `Project Alpha`)
3. Enter your wevo-space server URL (e.g. `https://your-server.example.com`)
4. Select a default Identity for quick signing (can be changed later)
5. Tap **Add**

> **About the URL:** The app works locally without a URL. Leave it blank if you don't need server sync.

---

## 3. Core Workflow

### 3-1. Register a Contact (receive the counterparty's public key)

To create a Propose, you need the counterparty's public key. Have them send you a Contact file first.

**Counterparty's side (sending their public key):**

1. Go to **Manage Keys** → tap the Identity to share
2. Tap **Share as Contact**
3. Send via AirDrop

**Your side (receiving):**

1. Accept the `.wevo-contact` file via AirDrop
2. It is automatically saved as a Contact
3. You can verify the public key and fingerprint in the Contacts list

> **Fingerprint verification recommended:** To prevent public key spoofing, confirm the fingerprint out-of-band (in person, via Slack, etc.).

---

### 3-2. Create a Propose and Send It

1. Open the target Space
2. Tap **Create Propose**
3. Fill in the following:
   - **Identity:** Select the Identity you will sign with
   - **Counterparty:** Select the contact to sign with you
   - **Message:** Enter the content of the agreement (stored locally only)
4. Tap **Create**

The following signature message is constructed internally:

```
proposeId + SHA256(message) + counterpartyPublicKey + createdAt
```

- Saved locally to SwiftData
- A POST to the wevo-space server is attempted (local save is preserved even if it fails)

**Sending the Propose:**

1. Tap the created Propose
2. Tap **Export** → AirDrop the `.wevo-propose` file to the counterparty

---

### 3-3. Receive a Propose and Sign It

1. Accept the `.wevo-propose` file via AirDrop
2. Select the destination Space
3. The Propose appears in the **Active** tab with status `proposed`
4. Tap the Propose → tap **Sign**
5. Select the Identity to sign with (only Identities whose public key matches the Creator's designated counterparty are shown)

The following signature message is constructed:

```
"signed." + proposeId + SHA256(message) + signerPublicKey + timestamp
```

After signing, the status becomes `signed`.

**Send the signature to the server (optional):**

Tap **Sync to Server** after signing to send your signature to wevo-space.
The counterparty can then fetch it from the server.

---

### 3-4. Honor / Part / Dissolve

Once a Propose reaches `signed` status, the following actions are available:

| Action | Meaning | Signature message prefix |
|--------|---------|--------------------------|
| **Honor** | Both parties declare the agreement complete | `"honored."` |
| **Part** | One party exits early | `"part."` |
| **Dissolve** | Discard the Propose | — |

- Proposes in `honored` or `parted` state move to the Completed tab
- All state transitions are sent to the wevo-space server

---

## 4. Technical Reference

### How Signatures Work

| Item | Detail |
|------|--------|
| Algorithm | P256 ECDSA (Apple CryptoKit) |
| Public key format | JWK (JSON Web Key) |
| Signature encoding | Base64 DER |
| Hashing | SHA256 (message body → contentHash) |

Only the contentHash (SHA256) is sent to the server. **The message body is never transmitted.**
For privacy reasons, the body is stored only in local SwiftData.

### File Formats

All files are JSON.

| Extension | Contents |
|-----------|----------|
| `.wevo-propose` | Propose data (includes message body and signatures) |
| `.wevo-identity` | Identity data (**includes private key — handle with care**) |
| `.wevo-contact` | Public key only (safe to share) |

### Persistence

| Data | Storage |
|------|---------|
| Identity private key | Keychain (synced via iCloud Keychain) |
| Propose / Space / Contact | SwiftData (iCloud sync) |
| Message body | SwiftData (local only) |

### wevo-space API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/v1/proposes` | Create a Propose |
| PATCH | `/v1/proposes/:id/sign` | Sign a Propose |
| PATCH | `/v1/proposes/:id/honor` | Honor a Propose |
| PATCH | `/v1/proposes/:id/part` | Part a Propose |
| DELETE | `/v1/proposes/:id` | Dissolve a Propose |
| GET | `/v1/proposes/:id` | Get a Propose |
| GET | `/v1/proposes?publicKey=...` | List Proposes |

---

## 5. Known Limitations

- **Single counterparty only:** The current Propose creation UI supports two-party agreements only (Creator + 1 Counterparty)
- **Message body is unrecoverable:** If the `.wevo-propose` file is lost, the message body cannot be recovered — only the hash is on the server
- **HTTP allowed (beta only):** `NSAllowsArbitraryLoads: true` is enabled. HTTPS will be enforced before production release
- **Data loss on schema change:** SwiftData schema migrations during the TestFlight period may erase local data
- **Two devices recommended:** Testing the full signing flow requires two iOS devices

---

*This document is for the wevo TestFlight Beta. Please submit feedback via the TestFlight feedback feature.*
