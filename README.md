# WevoSpace

💧 A project built with the Vapor web framework.

## Features

### 🔒 Security
- **Rate Limiting**: 60 requests per minute per IP address
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
// Default: 60 requests per 60 seconds (1 minute)
app.middleware.use(RateLimitMiddleware(maxRequests: 60, windowSeconds: 60))
```

## Architecture

### Data Models
- **Propose**: Contains payload hash and creation timestamp
- **Signature**: Contains public key and signature data linked to a Propose

### Security Features
1. All signatures are cryptographically verified using P-256 ECDSA
2. Proposals are immutable - payload hash cannot be changed
3. Signatures are append-only - cannot be deleted or modified
4. Rate limiting prevents abuse and DoS attacks

### See more

- [Vapor Website](https://vapor.codes)
- [Vapor Documentation](https://docs.vapor.codes)
- [Vapor GitHub](https://github.com/vapor)
- [Vapor Community](https://github.com/vapor-community)
