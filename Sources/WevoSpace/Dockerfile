# syntax=docker/dockerfile:1.7

# ---- Build stage ----
FROM swift:6.0 as build

WORKDIR /build

# Optimize dependency caching
COPY Package.* ./
RUN swift package resolve

# Copy sources and build
COPY . .
RUN swift build -c release --static-swift-stdlib

# ---- Runtime stage ----
FROM debian:bookworm-slim

# Minimal runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libatomic1 tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the release binary (adjust name if executable target changes)
COPY --from=build /build/.build/release/WevoSpace ./WevoSpace

# Create non-root user
RUN useradd -m -u 10001 vapor
USER vapor

# Expose the default Vapor port
EXPOSE 8080

# Run the server; allow overriding port via env PORT
ENV PORT=8080
ENTRYPOINT ["./WevoSpace"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
