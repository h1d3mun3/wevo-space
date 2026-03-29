# WevoSpace Propose API Documentation

## Overview

A Propose is a mechanism for recording and managing multi-party agreements with cryptographic signatures. One **creator** and one or more **counterparties** are involved. All state transitions are secured by signature verification — no authentication tokens are required.

**Base URL**:
- Development: `http://localhost:8080/v1`
- Production: `https://api.wevospace.example.com/v1`

---

## Data Model

### ProposeResponse

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Propose ID (client-generated) |
| `contentHash` | string | Hash of the content |
| `creatorPublicKey` | string | Creator's public key (JWK JSON string) |
| `creatorSignature` | string | Creator's signature (Base64 / DER) |
| `counterparties` | CounterpartyInfo[] | List of counterparties and their signatures |
| `honorCreatorSignature` | string? | Creator's honor signature |
| `honorCreatorTimestamp` | string? | Creator's honor timestamp (ISO8601) |
| `partCreatorSignature` | string? | Creator's part signature |
| `partCreatorTimestamp` | string? | Creator's part timestamp (ISO8601) |
| `dissolvedAt` | string? | Dissolution timestamp (ISO8601) |
| `status` | string | Current status (see below) |
| `signatureVersion` | integer | Signature scheme version (current: 1) |
| `createdAt` | string | Creation timestamp (ISO8601, client-generated) |
| `updatedAt` | string? | Last updated timestamp (server-managed) |

### CounterpartyInfo

| Field | Type | Description |
|---|---|---|
| `publicKey` | string | Counterparty's public key (JWK JSON string) |
| `signSignature` | string? | Signature for `/sign` (set after signing) |
| `signTimestamp` | string? | Timestamp for `/sign` (ISO8601) |
| `honorSignature` | string? | Signature for `/honor` |
| `honorTimestamp` | string? | Timestamp for `/honor` (ISO8601) |
| `partSignature` | string? | Signature for `/part` |
| `partTimestamp` | string? | Timestamp for `/part` (ISO8601) |

### Status Values

| status | Meaning |
|---|---|
| `proposed` | Created by creator, awaiting all counterparty signatures |
| `signed` | All counterparties signed; agreement established |
| `honored` | Creator + all counterparties submitted honor signatures |
| `dissolved` | Dissolved from `proposed` state |
| `parted` | Any participant submitted a part signature (immediate transition) |

### State Transition Diagram

```
proposed ──sign (all counterparties)──→ signed ──honor (all)──→ honored
    │                                      │
  dissolve                              part (any one → immediate)
    │                                      │
    ↓                                      ↓
dissolved                               parted
```

---

## Signature Specification

- Key algorithm: **P-256 ECDSA**
- Public key format: **JWK (JSON Web Key)** — a JSON string with `crv`, `kty`, `x`, `y` fields (x and y are Base64URL-encoded 32-byte coordinates)
- Signature format: Base64-encoded **DER format**

**Public key example:**
```json
{"crv":"P-256","kty":"EC","x":"IrH3k5a8Q2mXvP1nQ7rAbCdEfGhIjKlMnOpQrSt","y":"UvWxYzAaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPp"}
```

### Message to Sign

The string to sign for each operation is formed by concatenating the following fields (no separator):

| Operation | Message |
|---|---|
| Create | `"proposed." + proposeId + contentHash + creatorPublicKey + counterpartyPublicKeys(sorted & joined) + createdAt` |
| sign | `"signed." + proposeId + contentHash + signerPublicKey + timestamp` |
| dissolve | `"dissolved." + proposeId + contentHash + publicKey + timestamp` |
| honor | `"honored." + proposeId + contentHash + publicKey + timestamp` |
| part | `"parted." + proposeId + contentHash + publicKey + timestamp` |

> **Note**: Use the uppercase UUID string format for `proposeId` (e.g., `550E8400-E29B-41D4-A716-446655440000`).
>
> For **create**, sort `counterpartyPublicKeys` lexicographically and join them (no separator) before signing.

---

## Endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/proposes` | Create a propose |
| `GET` | `/proposes/:id` | Get propose details |
| `PATCH` | `/proposes/:id/sign` | A counterparty signs (auto-transitions to `signed` when all have signed) |
| `DELETE` | `/proposes/:id` | Dissolve (proposed → dissolved) |
| `PATCH` | `/proposes/:id/honor` | Submit honor signature (signed → honored when all submitted) |
| `PATCH` | `/proposes/:id/part` | Submit part signature (signed → parted immediately when any participant submits) |

---

## 1. POST /proposes — Create a Propose

The creator creates a new Propose. Sign `"proposed." + proposeId + contentHash + creatorPublicKey + counterpartyPublicKeys(sorted & joined) + createdAt`.

### Request Body

```json
{
  "proposeId": "550E8400-E29B-41D4-A716-446655440000",
  "contentHash": "abc123def456",
  "creatorPublicKey": "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"IrH3...\",\"y\":\"UvWx...\"}",
  "creatorSignature": "MEUC...",
  "counterpartyPublicKeys": [
    "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"AbCd...\",\"y\":\"EfGh...\"}",
    "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"IjKl...\",\"y\":\"MnOp...\"}"
  ],
  "createdAt": "2026-01-01T00:00:00Z"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `proposeId` | string | ✅ | UUID string (client-generated) |
| `contentHash` | string | ✅ | Hash of the content |
| `creatorPublicKey` | string | ✅ | Creator's public key |
| `creatorSignature` | string | ✅ | Creator's signature |
| `counterpartyPublicKeys` | string[] | ✅ | Counterparty public keys (1 or more) |
| `createdAt` | string | ✅ | ISO8601 creation timestamp |

### Responses

| Status | Description |
|---|---|
| 201 Created | Propose created successfully |
| 400 | Invalid `proposeId` format, or `counterpartyPublicKeys` is empty |
| 401 | Signature verification failed |
| 409 Conflict | A Propose with the same ID already exists |

---

## 2. GET /proposes/:id — Get Propose Details

### Request Example

```
GET /v1/proposes/550E8400-E29B-41D4-A716-446655440000
```

### Response (200 OK)

Returns a `ProposeResponse` object (see Data Model above).

### Errors

| Status | Reason |
|---|---|
| 400 | Invalid UUID format |
| 404 | Propose not found |

---

## 3. PATCH /proposes/:id/sign — Counterparty Signs (proposed → signed when all done)

A counterparty signs `"signed." + proposeId + contentHash + signerPublicKey + timestamp`.
The Propose transitions to `signed` automatically once **all** counterparties have signed.

### Request Body

```json
{
  "signerPublicKey": "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"AbCd...\",\"y\":\"EfGh...\"}",
  "signature": "MEUC...",
  "timestamp": "2026-01-01T00:00:00Z"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `signerPublicKey` | string | ✅ | Signer's public key (must be a registered counterparty) |
| `signature` | string | ✅ | Signer's signature |
| `timestamp` | string | ✅ | Operation timestamp (ISO8601) |

### Responses

| Status | Description |
|---|---|
| 200 OK | Signed successfully; transitions to `signed` when all counterparties have signed |
| 400 | Invalid Propose ID |
| 401 | Signature verification failed |
| 403 Forbidden | `signerPublicKey` is not a registered counterparty |
| 404 | Propose not found |
| 409 Conflict | Propose is not in `proposed` state |

---

## 4. DELETE /proposes/:id — Dissolve (proposed → dissolved)

The creator or any counterparty signs `"dissolved." + proposeId + contentHash + publicKey + timestamp` to dissolve. Only allowed from `proposed` state.

### Request Body

```json
{
  "publicKey": "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"IrH3...\",\"y\":\"UvWx...\"}",
  "signature": "MEUC...",
  "timestamp": "2026-01-02T00:00:00Z"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `publicKey` | string | ✅ | Requester's public key (creator or counterparty) |
| `signature` | string | ✅ | Requester's signature |
| `timestamp` | string | ✅ | Operation timestamp (ISO8601) |

### Responses

| Status | Description |
|---|---|
| 200 OK | Dissolved successfully; transitions to `dissolved` |
| 401 | Signature verification failed |
| 403 Forbidden | Public key does not belong to a participant |
| 404 | Propose not found |
| 409 Conflict | Propose is not in `proposed` state |

---

## 5. PATCH /proposes/:id/honor — Submit Honor Signature (signed → honored)

Each participant signs `"honored." + proposeId + contentHash + publicKey + timestamp`. Once the creator and **all** counterparties have submitted, the Propose automatically transitions to `honored`.

### Request Body

```json
{
  "publicKey": "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"IrH3...\",\"y\":\"UvWx...\"}",
  "signature": "MEUC...",
  "timestamp": "2026-01-03T00:00:00Z"
}
```

### Responses

| Status | Description |
|---|---|
| 200 OK | Signature recorded; transitions to `honored` when all participants have submitted |
| 401 | Signature verification failed |
| 403 Forbidden | Public key does not belong to a participant |
| 404 | Propose not found |
| 409 Conflict | Propose is not in `signed` state |

---

## 6. PATCH /proposes/:id/part — Submit Part Signature (signed → parted immediately)

Any participant signs `"parted." + proposeId + contentHash + publicKey + timestamp`. The Propose transitions to `parted` **immediately** when any one participant submits — no need to wait for all participants.

### Request Body

```json
{
  "publicKey": "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"IrH3...\",\"y\":\"UvWx...\"}",
  "signature": "MEUC...",
  "timestamp": "2026-01-03T00:00:00Z"
}
```

### Responses

| Status | Description |
|---|---|
| 200 OK | Signature recorded; transitions to `parted` immediately |
| 401 | Signature verification failed |
| 403 Forbidden | Public key does not belong to a participant |
| 404 | Propose not found |
| 409 Conflict | Propose is not in `signed` state |

---

## Utility Endpoints

### GET /health — Health Check

Returns the server's operational status. Not versioned (no `/v1` prefix).

```
GET /health
```

**Response (200 OK)**

```json
{
  "status": "ok",
  "timestamp": "1711234567.0"
}
```

---

### GET /info — Server Info

Returns the protocol name, version, and supported capabilities. Not versioned (no `/v1` prefix).

```
GET /info
```

**Response (200 OK)**

```json
{
  "protocol": "wevo",
  "version": "0.1.0",
  "capabilities": [
    "proposes.create",
    "proposes.read",
    "proposes.sign"
  ]
}
```

---

## Rate Limiting

Rate limiting is applied to all endpoints.

| Header | Description |
|---|---|
| `X-RateLimit-Limit` | Maximum requests allowed (60/min) |
| `X-RateLimit-Remaining` | Remaining requests in current window |
| `X-RateLimit-Reset` | Unix timestamp when the limit resets |
| `Retry-After` | Seconds until retry is allowed (when limited) |

Response when limit is exceeded: **429 Too Many Requests**

---

## cURL Examples

### Create a Propose (2 counterparties)

```bash
CREATOR_JWK='{"crv":"P-256","kty":"EC","x":"IrH3...","y":"UvWx..."}'
COUNTERPARTY1_JWK='{"crv":"P-256","kty":"EC","x":"AbCd...","y":"EfGh..."}'
COUNTERPARTY2_JWK='{"crv":"P-256","kty":"EC","x":"IjKl...","y":"MnOp..."}'

curl -X POST http://localhost:8080/v1/proposes \
  -H "Content-Type: application/json" \
  -d "{
    \"proposeId\": \"550E8400-E29B-41D4-A716-446655440000\",
    \"contentHash\": \"abc123def456\",
    \"creatorPublicKey\": $CREATOR_JWK,
    \"creatorSignature\": \"MEUC...\",
    \"counterpartyPublicKeys\": [$COUNTERPARTY1_JWK, $COUNTERPARTY2_JWK],
    \"createdAt\": \"2026-01-01T00:00:00Z\"
  }"
```

### Sign (counterparty)

```bash
COUNTERPARTY_JWK='{"crv":"P-256","kty":"EC","x":"AbCd...","y":"EfGh..."}'

curl -X PATCH http://localhost:8080/v1/proposes/550E8400-E29B-41D4-A716-446655440000/sign \
  -H "Content-Type: application/json" \
  -d "{
    \"signerPublicKey\": $COUNTERPARTY_JWK,
    \"signature\": \"MEUC...\",
    \"timestamp\": \"2026-01-01T00:00:00Z\"
  }"
```

### Dissolve

```bash
CREATOR_JWK='{"crv":"P-256","kty":"EC","x":"IrH3...","y":"UvWx..."}'

curl -X DELETE http://localhost:8080/v1/proposes/550E8400-E29B-41D4-A716-446655440000 \
  -H "Content-Type: application/json" \
  -d "{
    \"publicKey\": $CREATOR_JWK,
    \"signature\": \"MEUC...\",
    \"timestamp\": \"2026-01-02T00:00:00Z\"
  }"
```

### Submit Honor Signature

```bash
CREATOR_JWK='{"crv":"P-256","kty":"EC","x":"IrH3...","y":"UvWx..."}'

curl -X PATCH http://localhost:8080/v1/proposes/550E8400-E29B-41D4-A716-446655440000/honor \
  -H "Content-Type: application/json" \
  -d "{
    \"publicKey\": $CREATOR_JWK,
    \"signature\": \"MEUC...\",
    \"timestamp\": \"2026-01-03T00:00:00Z\"
  }"
```

---

## Version

API Version: 1.0.0
Last updated: 2026-03-19
