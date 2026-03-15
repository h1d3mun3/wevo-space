# WevoSpace

💧 A project built with the Vapor web framework.

An API server for recording and managing two-party agreements with cryptographic signatures.

> 日本語版: [README_ja.md](README_ja.md)

## Features

### 🔒 Security
- **Signature Verification**: All state transitions are secured by P-256 ECDSA verification
- **Rate Limiting**: 60 requests/minute per IP address
- **Request Size Limit**: 1 MB max per request
- **Duplicate Check**: Prevents duplicate Propose IDs

### 📡 API Endpoints

All endpoints are prefixed with `/v1`.

| Method | Path | Description |
|---|---|---|
| `GET` | `/v1/proposes` | List proposes (filter by publicKey and status) |
| `POST` | `/v1/proposes` | Create a propose |
| `GET` | `/v1/proposes/:id` | Get propose details |
| `PATCH` | `/v1/proposes/:id/sign` | Counterparty signs (proposed → signed) |
| `DELETE` | `/v1/proposes/:id` | Dissolve (proposed → dissolved) |
| `PATCH` | `/v1/proposes/:id/honor` | Honor signature (signed → honored) |
| `PATCH` | `/v1/proposes/:id/part` | Part signature (signed → parted) |

### State Transitions

```
proposed ──sign──→ signed ──honor (both)──→ honored
    │                 │
  dissolve          part (both)
    │                 │
    ↓                 ↓
dissolved           parted
```

Rate limit headers:
- `X-RateLimit-Limit` / `X-RateLimit-Remaining` / `X-RateLimit-Reset`
- On limit exceeded: `429 Too Many Requests` + `Retry-After`

See [docs/PROPOSE_API.md](docs/PROPOSE_API.md) / [docs/PROPOSE_API_ja.md](docs/PROPOSE_API_ja.md) for full documentation.

---

## Getting Started

### Prerequisites

- Swift 6.0 or later
- PostgreSQL 12+ (production)
- Docker & Docker Compose (optional, for local PostgreSQL)

### Database Setup

WevoSpace uses SQLite in development and PostgreSQL in production.

#### Development (SQLite — default)

No configuration needed.

```bash
swift run
# db.sqlite is created automatically
```

#### Production (PostgreSQL)

See [POSTGRESQL_SETUP.md](Sources/WevoSpace/POSTGRESQL_SETUP.md) for details.

Quick start with Docker:

```bash
# Start PostgreSQL
docker-compose up -d postgres

# Run migrations
swift run WevoSpace migrate

# Start server
swift run
```

### Build & Run

```bash
# Build
swift build

# Start server
swift run

# Run tests
swift test
```

---

## Configuration

### Environment Variables

```bash
# PostgreSQL (production)
DATABASE_URL=postgres://username:password@localhost:5432/wevospace

# Or individual variables
DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_USERNAME=vapor
DATABASE_PASSWORD=password
DATABASE_NAME=wevospace
```

### Rate Limiting

Configurable in `configure.swift`:

```swift
app.middleware.use(RateLimitMiddleware(requestLimit: 60, timeWindow: 60))
app.routes.defaultMaxBodySize = "1mb"
```

---

## Architecture

### Database

- **Development**: SQLite (no configuration required)
- **Production**: PostgreSQL (recommended)

Switches automatically based on environment.

### Data Model

**Propose** — the core entity for two-party agreements

| Field | Description |
|---|---|
| `contentHash` | Hash of the content |
| `creatorPublicKey` / `creatorSignature` | Creator's key and signature |
| `counterpartyPublicKey` / `counterpartySignature` | Counterparty's key and signature |
| `honorCreator/CounterpartySignature` | Honor signatures (both parties) |
| `partCreator/CounterpartySignature` | Part signatures (both parties) |
| `status` | Current state |
| `createdAt` | Creation timestamp (client-generated) |
| `updatedAt` | Last updated timestamp (server-managed) |

### Security Principles

1. All state transitions are secured by P-256 ECDSA signature verification
2. No authentication tokens — the public key proves participation via signature
3. Server handles only stateless verification

---

## API Documentation

- English: [docs/PROPOSE_API.md](docs/PROPOSE_API.md)
- 日本語: [docs/PROPOSE_API_ja.md](docs/PROPOSE_API_ja.md)
- OpenAPI (English): [api/propose-api.en.openapi.yaml](api/propose-api.en.openapi.yaml)
- OpenAPI (日本語): [api/propose-api.openapi.yaml](api/propose-api.openapi.yaml)

## References

- [Vapor Website](https://vapor.codes)
- [Vapor Documentation](https://docs.vapor.codes)
