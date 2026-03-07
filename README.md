# WevoSpace

💧 A project built with the Vapor web framework.

## Features

### 🔒 Security
- **Rate Limiting**: 60 requests per minute per IP address
- **Request Size Limiting**: Maximum 1MB per request
- **Field Size Validation**: 
  - Payload hash: 256 characters max
  - Signatures per request: 1000 max
  - Public key: 500 characters max
  - Signature data: 500 characters max
- **Cryptographic Signatures**: P-256 ECDSA signature verification
- **Input Validation**: Comprehensive validation of all inputs
- **Immutable Data**: Append-only architecture for proposals

### 📡 API Endpoints

#### Proposes
- `POST /proposes` - Create a new proposal with signatures
- `PUT /proposes/:id` - Add signatures to existing proposal
- `GET /proposes/:id` - Get proposal details
- `GET /proposes?publicKey=xxx` - List proposals by public key

All API responses include rate limit headers:
- `X-RateLimit-Limit`: Maximum requests allowed
- `X-RateLimit-Remaining`: Remaining requests in current window
- `X-RateLimit-Reset`: Unix timestamp when the limit resets

When rate limit is exceeded, the API returns:
- Status: `429 Too Many Requests`
- Header: `Retry-After` - Seconds until retry is allowed

## Getting Started

To build the project using the Swift Package Manager, run the following command in the terminal from the root of the project:
```bash
swift build
```

To run the project and start the server, use the following command:
```bash
swift run
```

To execute tests, use the following command:
```bash
swift test
```

## Configuration

Rate limiting can be configured in `configure.swift`:

```swift
// Rate Limiting: 60 requests per 60 seconds (1 minute)
app.middleware.use(RateLimitMiddleware(maxRequests: 60, windowSeconds: 60))

// Request size limit: 1MB
app.routes.defaultMaxBodySize = "1mb"
```

Field size limits are enforced in `ProposeController`:
- `payloadHash`: 256 characters maximum
- `signatures`: 1000 signatures per request maximum
- `publicKey`: 500 characters maximum (Base64 encoded)
- `signature`: 500 characters maximum (Base64 encoded)

## Architecture

### Data Models
- **Propose**: Contains payload hash and creation timestamp
- **Signature**: Contains public key and signature data linked to a Propose

### Security Features
1. All signatures are cryptographically verified using P-256 ECDSA
2. Proposals are immutable - payload hash cannot be changed
3. Signatures are append-only - cannot be deleted or modified
4. Rate limiting prevents abuse and DoS attacks (60 requests/minute)
5. Request size limiting prevents memory exhaustion attacks (1MB max)
6. Individual field size validation prevents malformed data

### See more

- [Vapor Website](https://vapor.codes)
- [Vapor Documentation](https://docs.vapor.codes)
- [Vapor GitHub](https://github.com/vapor)
- [Vapor Community](https://github.com/vapor-community)
