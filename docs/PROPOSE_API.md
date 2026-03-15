# WevoSpace Propose API Documentation

## Overview

A Propose is a mechanism for recording and managing two-party agreements with cryptographic signatures. Two parties are involved: the **creator** and the **counterparty**. All state transitions are secured by signature verification — no authentication tokens are required.

**Base URL**:
- Development: `http://localhost:8080/v1`
- Production: `https://api.wevospace.example.com/v1`

---

## Data Model

### Propose

| Field | Type | Description |
|---|---|---|
| `id` | UUID | Propose ID (client-generated) |
| `contentHash` | string | Hash of the content |
| `creatorPublicKey` | string | Creator's public key (Base64 / DER) |
| `creatorSignature` | string | Creator's signature (Base64 / DER) |
| `counterpartyPublicKey` | string | Counterparty's public key (Base64 / DER) |
| `counterpartySignature` | string? | Counterparty's signature (set after signing) |
| `honorCreatorSignature` | string? | Creator's honor signature |
| `honorCounterpartySignature` | string? | Counterparty's honor signature |
| `partCreatorSignature` | string? | Creator's part signature |
| `partCounterpartySignature` | string? | Counterparty's part signature |
| `status` | string | Current status (see below) |
| `createdAt` | string | Creation timestamp (ISO8601, client-generated) |
| `updatedAt` | string | Last updated timestamp (server-managed) |

### Status Values

| status | Meaning |
|---|---|
| `proposed` | Created by creator, awaiting counterparty signature |
| `signed` | Counterparty signed; agreement established |
| `honored` | Both parties submitted honor signatures |
| `dissolved` | Dissolved from `proposed` state |
| `parted` | Both parties submitted part signatures |

### State Transition Diagram

```
proposed ──sign──→ signed ──honor (both)──→ honored
    │                 │
  dissolve         part (both)
    │                 │
    ↓                 ↓
dissolved           parted
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
| Create / sign | `proposeId + contentHash + counterpartyPublicKey + createdAt` |
| dissolved | `"dissolved." + proposeId + contentHash + timestamp` |
| honored | `"honored." + proposeId + contentHash + timestamp` |
| parted | `"parted." + proposeId + contentHash + timestamp` |

> **Note**: Use the uppercase UUID string format for `proposeId` (e.g., `550E8400-E29B-41D4-A716-446655440000`).

---

## Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/proposes` | List proposes |
| `POST` | `/proposes` | Create a propose |
| `GET` | `/proposes/:id` | Get propose details |
| `PATCH` | `/proposes/:id/sign` | Counterparty signs (proposed → signed) |
| `DELETE` | `/proposes/:id` | Dissolve (proposed → dissolved) |
| `PATCH` | `/proposes/:id/honor` | Submit honor signature (signed → honored) |
| `PATCH` | `/proposes/:id/part` | Submit part signature (signed → parted) |

---

## 1. GET /proposes — List Proposes

Returns proposes where the specified public key is either the creator or the counterparty.

### Query Parameters

| Parameter | Required | Description |
|---|---|---|
| `publicKey` | ✅ | Public key to search by (Base64 / DER) |
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
      "counterpartyPublicKey": "BIrH...",
      "counterpartySignature": null,
      "honorCreatorSignature": null,
      "honorCounterpartySignature": null,
      "partCreatorSignature": null,
      "partCounterpartySignature": null,
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

The creator creates a new Propose. The creator signs `proposeId + contentHash + counterpartyPublicKey + createdAt`.

### Request Body

```json
{
  "proposeId": "550E8400-E29B-41D4-A716-446655440000",
  "contentHash": "abc123def456",
  "creatorPublicKey": "BHqG...",
  "creatorSignature": "MEUC...",
  "counterpartyPublicKey": "BIrH...",
  "createdAt": "2026-01-01T00:00:00Z"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `proposeId` | string | ✅ | UUID string (client-generated) |
| `contentHash` | string | ✅ | Hash of the content |
| `creatorPublicKey` | string | ✅ | Creator's public key |
| `creatorSignature` | string | ✅ | Creator's signature |
| `counterpartyPublicKey` | string | ✅ | Counterparty's public key |
| `createdAt` | string | ✅ | ISO8601 creation timestamp |

### Responses

| Status | Description |
|---|---|
| 201 Created | Propose created successfully |
| 400 | Invalid `proposeId` format |
| 401 | Signature verification failed |
| 409 Conflict | A Propose with the same ID already exists |

---

## 3. GET /proposes/:id — Get Propose Details

### Request Example

```
GET /v1/proposes/550E8400-E29B-41D4-A716-446655440000
```

### Response (200 OK)

Returns a Propose object (see Data Model above).

### Errors

| Status | Reason |
|---|---|
| 400 | Invalid UUID format |
| 404 | Propose not found |

---

## 4. PATCH /proposes/:id/sign — Counterparty Signs (proposed → signed)

The counterparty signs `proposeId + contentHash + counterpartyPublicKey + createdAt`, transitioning the Propose to `signed` state.

### Request Body

```json
{
  "counterpartySignature": "MEUC...",
  "createdAt": "2026-01-01T00:00:00Z"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `counterpartySignature` | string | ✅ | Counterparty's signature |
| `createdAt` | string | ✅ | Must match the Propose's `createdAt` |

### Responses

| Status | Description |
|---|---|
| 200 OK | Signed successfully; transitions to `signed` |
| 400 | `createdAt` mismatch or invalid UUID |
| 401 | Signature verification failed |
| 404 | Propose not found |
| 409 Conflict | Propose is not in `proposed` state |

---

## 5. DELETE /proposes/:id — Dissolve (proposed → dissolved)

Either the creator or counterparty signs `"dissolved." + proposeId + contentHash + timestamp` to dissolve the Propose. Only allowed from `proposed` state.

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

Each party signs `"honored." + proposeId + contentHash + timestamp`. Once both parties have submitted, the Propose automatically transitions to `honored`.

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
| 200 OK | Signature recorded; transitions to `honored` when both are submitted |
| 401 | Signature verification failed |
| 403 Forbidden | Public key does not belong to a participant |
| 404 | Propose not found |
| 409 Conflict | Propose is not in `signed` state |

---

## 7. PATCH /proposes/:id/part — Submit Part Signature (signed → parted)

Each party signs `"parted." + proposeId + contentHash + timestamp`. Once both parties have submitted, the Propose automatically transitions to `parted`.

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
| 200 OK | Signature recorded; transitions to `parted` when both are submitted |
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

### Create a Propose

```bash
curl -X POST http://localhost:8080/v1/proposes \
  -H "Content-Type: application/json" \
  -d '{
    "proposeId": "550E8400-E29B-41D4-A716-446655440000",
    "contentHash": "abc123def456",
    "creatorPublicKey": "BHqG...",
    "creatorSignature": "MEUC...",
    "counterpartyPublicKey": "BIrH...",
    "createdAt": "2026-01-01T00:00:00Z"
  }'
```

### Sign (counterparty)

```bash
curl -X PATCH http://localhost:8080/v1/proposes/550E8400-E29B-41D4-A716-446655440000/sign \
  -H "Content-Type: application/json" \
  -d '{
    "counterpartySignature": "MEUC...",
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
