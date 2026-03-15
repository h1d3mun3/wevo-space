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
| `creatorPublicKey` | string | Creator's public key (Base64 / X.963) |
| `creatorSignature` | string | Creator's signature (Base64 / DER) |
| `counterparties` | CounterpartyInfo[] | List of counterparties and their signatures |
| `honorCreatorSignature` | string? | Creator's honor signature |
| `partCreatorSignature` | string? | Creator's part signature |
| `status` | string | Current status (see below) |
| `createdAt` | string | Creation timestamp (ISO8601, client-generated) |
| `updatedAt` | string? | Last updated timestamp (server-managed) |

### CounterpartyInfo

| Field | Type | Description |
|---|---|---|
| `publicKey` | string | Counterparty's public key (Base64 / X.963) |
| `signSignature` | string? | Signature for `/sign` (set after signing) |
| `honorSignature` | string? | Signature for `/honor` |
| `partSignature` | string? | Signature for `/part` |

### Status Values

| status | Meaning |
|---|---|
| `proposed` | Created by creator, awaiting all counterparty signatures |
| `signed` | All counterparties signed; agreement established |
| `honored` | Creator + all counterparties submitted honor signatures |
| `dissolved` | Dissolved from `proposed` state |
| `parted` | Creator + all counterparties submitted part signatures |

### State Transition Diagram

```
proposed ──sign (all counterparties)──→ signed ──honor (all)──→ honored
    │                                      │
  dissolve                              part (all)
    │                                      │
    ↓                                      ↓
dissolved                               parted
```

---

## Signature Specification

- Key algorithm: **P-256 ECDSA**
- Public key format: Base64-encoded **X.963 format** (65 bytes)
- Signature format: Base64-encoded **DER format**

### Message to Sign

The string to sign for each operation is formed by concatenating the following fields (no separator):

| Operation | Message |
|---|---|
| Create | `proposeId + contentHash + counterpartyPublicKeys(sorted & joined) + createdAt` |
| sign | `proposeId + contentHash + signerPublicKey + createdAt` |
| dissolve | `"dissolved." + proposeId + contentHash + timestamp` |
| honor | `"honored." + proposeId + contentHash + timestamp` |
| part | `"parted." + proposeId + contentHash + timestamp` |

> **Note**: Use the uppercase UUID string format for `proposeId` (e.g., `550E8400-E29B-41D4-A716-446655440000`).
>
> For **create**, sort `counterpartyPublicKeys` lexicographically and join them (no separator) before signing.

---

## Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/proposes` | List proposes |
| `POST` | `/proposes` | Create a propose |
| `GET` | `/proposes/:id` | Get propose details |
| `PATCH` | `/proposes/:id/sign` | A counterparty signs (auto-transitions to `signed` when all have signed) |
| `DELETE` | `/proposes/:id` | Dissolve (proposed → dissolved) |
| `PATCH` | `/proposes/:id/honor` | Submit honor signature (signed → honored when all submitted) |
| `PATCH` | `/proposes/:id/part` | Submit part signature (signed → parted when all submitted) |

---

## 1. GET /proposes — List Proposes

Returns proposes where the specified public key is either the creator or one of the counterparties.

### Query Parameters

| Parameter | Required | Description |
|---|---|---|
| `publicKey` | ✅ | Public key to search by (Base64 / X.963) |
| `status` | ✗ | Filter by status (comma-separated for multiple) |
| `page` | ✗ | Page number (default: 1) |
| `per` | ✗ | Items per page (default: 10) |

### Request Example

```
GET /v1/proposes?publicKey=BHqG...&status=proposed,signed
```

### Response (200 OK)

```json
{
  "items": [
    {
      "id": "550E8400-E29B-41D4-A716-446655440000",
      "contentHash": "abc123def456",
      "creatorPublicKey": "BHqG...",
      "creatorSignature": "MEUC...",
      "counterparties": [
        {
          "publicKey": "BIrH...",
          "signSignature": null,
          "honorSignature": null,
          "partSignature": null
        }
      ],
      "honorCreatorSignature": null,
      "partCreatorSignature": null,
      "status": "proposed",
      "createdAt": "2026-01-01T00:00:00Z",
      "updatedAt": "2026-01-01T00:00:00Z"
    }
  ],
  "metadata": {
    "page": 1,
    "per": 10,
    "total": 1
  }
}
```

### Errors

| Status | Reason |
|---|---|
| 400 | `publicKey` is missing |

---

## 2. POST /proposes — Create a Propose

The creator creates a new Propose. Sign `proposeId + contentHash + counterpartyPublicKeys(sorted & joined) + createdAt`.

### Request Body

```json
{
  "proposeId": "550E8400-E29B-41D4-A716-446655440000",
  "contentHash": "abc123def456",
  "creatorPublicKey": "BHqG...",
  "creatorSignature": "MEUC...",
  "counterpartyPublicKeys": ["BIrH...", "BJsI..."],
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

## 3. GET /proposes/:id — Get Propose Details

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

## 4. PATCH /proposes/:id/sign — Counterparty Signs (proposed → signed when all done)

A counterparty signs `proposeId + contentHash + signerPublicKey + createdAt`.
The Propose transitions to `signed` automatically once **all** counterparties have signed.

### Request Body

```json
{
  "signerPublicKey": "BIrH...",
  "signature": "MEUC...",
  "createdAt": "2026-01-01T00:00:00Z"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `signerPublicKey` | string | ✅ | Signer's public key (must be a registered counterparty) |
| `signature` | string | ✅ | Signer's signature |
| `createdAt` | string | ✅ | Must match the Propose's `createdAt` |

### Responses

| Status | Description |
|---|---|
| 200 OK | Signed successfully; transitions to `signed` when all counterparties have signed |
| 400 | `createdAt` mismatch or invalid UUID |
| 401 | Signature verification failed |
| 403 Forbidden | `signerPublicKey` is not a registered counterparty |
| 404 | Propose not found |
| 409 Conflict | Propose is not in `proposed` state |

---

## 5. DELETE /proposes/:id — Dissolve (proposed → dissolved)

The creator or any counterparty signs `"dissolved." + proposeId + contentHash + timestamp` to dissolve. Only allowed from `proposed` state.

### Request Body

```json
{
  "publicKey": "BHqG...",
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

## 6. PATCH /proposes/:id/honor — Submit Honor Signature (signed → honored)

Each participant signs `"honored." + proposeId + contentHash + timestamp`. Once the creator and **all** counterparties have submitted, the Propose automatically transitions to `honored`.

### Request Body

```json
{
  "publicKey": "BHqG...",
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

## 7. PATCH /proposes/:id/part — Submit Part Signature (signed → parted)

Each participant signs `"parted." + proposeId + contentHash + timestamp`. Once the creator and **all** counterparties have submitted, the Propose automatically transitions to `parted`.

### Request Body

```json
{
  "publicKey": "BHqG...",
  "signature": "MEUC...",
  "timestamp": "2026-01-03T00:00:00Z"
}
```

### Responses

| Status | Description |
|---|---|
| 200 OK | Signature recorded; transitions to `parted` when all participants have submitted |
| 401 | Signature verification failed |
| 403 Forbidden | Public key does not belong to a participant |
| 404 | Propose not found |
| 409 Conflict | Propose is not in `signed` state |

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
curl -X POST http://localhost:8080/v1/proposes \
  -H "Content-Type: application/json" \
  -d '{
    "proposeId": "550E8400-E29B-41D4-A716-446655440000",
    "contentHash": "abc123def456",
    "creatorPublicKey": "BHqG...",
    "creatorSignature": "MEUC...",
    "counterpartyPublicKeys": ["BIrH...", "BJsI..."],
    "createdAt": "2026-01-01T00:00:00Z"
  }'
```

### Sign (counterparty)

```bash
curl -X PATCH http://localhost:8080/v1/proposes/550E8400-E29B-41D4-A716-446655440000/sign \
  -H "Content-Type: application/json" \
  -d '{
    "signerPublicKey": "BIrH...",
    "signature": "MEUC...",
    "createdAt": "2026-01-01T00:00:00Z"
  }'
```

### Dissolve

```bash
curl -X DELETE http://localhost:8080/v1/proposes/550E8400-E29B-41D4-A716-446655440000 \
  -H "Content-Type: application/json" \
  -d '{
    "publicKey": "BHqG...",
    "signature": "MEUC...",
    "timestamp": "2026-01-02T00:00:00Z"
  }'
```

### Submit Honor Signature

```bash
curl -X PATCH http://localhost:8080/v1/proposes/550E8400-E29B-41D4-A716-446655440000/honor \
  -H "Content-Type: application/json" \
  -d '{
    "publicKey": "BHqG...",
    "signature": "MEUC...",
    "timestamp": "2026-01-03T00:00:00Z"
  }'
```

---

## Version

API Version: 1.0.0
Last updated: 2026-03-15
