# Apollo Router v2.8.1 with HTTP/2 Header Limit Patch

## Summary

Successfully created a patched version of Apollo Router **v2.8.1** with the HTTP/2 header list size configuration fix.

## What's Included

This patched version includes:
- ✅ Base: Apollo Router v2.8.1 (official release)
- ✅ Patch: HTTP/2 header list size configuration fix
- ✅ New config option: `http2_max_header_list_size`
- ✅ Integration tests: `test-all-limits.sh`

## Branch Information

- **Branch name**: `v2.8.1-http2-header-limit-patch`
- **Base version**: v2.8.1 (tag: `efb0dcbfe`)
- **Patch commit**: `dc5eee2e5` (fix: add configurable HTTP/2 header list size limit to prevent 431 errors)
- **Binary location**: `./target/release/router`

## How to Use This Patched Version

### 1. Build the Patched Router

```bash
cd /Users/arajawat/src/oigql/router

# Switch to the patched branch (if not already on it)
git checkout v2.8.1-http2-header-limit-patch

# Build release version
cargo build --release --bin router

# Binary will be at: ./target/release/router
```

### 2. Configuration Example

Create your router configuration with the new HTTP/2 limit:

```yaml
supergraph:
  listen: 0.0.0.0:4000
  path: /

# Optional TLS configuration (required for HTTP/2)
tls:
  supergraph:
    certificate: ${file.cert.pem}
    certificate_chain: ${file.cert.pem}
    key: ${file.key.pem}

limits:
  # NEW: HTTP/2 header list size limit
  # Set higher than default 16KB if your application needs it
  http2_max_header_list_size: 32KiB
  
  # Existing HTTP/1.1 limits (optional)
  http1_max_request_headers: 100
  http1_max_request_buf_size: 21KiB
  
  # Request body size limit (both protocols)
  http_max_request_bytes: 2000000  # 2MB
```

### 3. Run the Router

```bash
./target/release/router \
  --supergraph your-supergraph.graphql \
  --config your-config.yaml
```

### 4. Verify the Fix Works

Run the integration tests:

```bash
# Generate test certificates
openssl req -x509 -newkey rsa:4096 -keyout test-key.pem -out test-cert.pem \
  -days 365 -nodes -subj "/CN=localhost"

# Start router
./target/release/router -s apollo-router/testing_schema.graphql -c test-fix.yaml

# In another terminal, run tests
chmod +x test-all-limits.sh
./test-all-limits.sh
```

Expected result: **All 20 tests should pass** ✅

## Deployment Options

### Option 1: Use the Built Binary Directly

Copy the binary to your deployment environment:

```bash
# Copy binary
cp ./target/release/router /path/to/deployment/router

# Make executable
chmod +x /path/to/deployment/router

# Run
/path/to/deployment/router --config your-config.yaml -s your-schema.graphql
```

### Option 2: Build a Docker Image

Create a Dockerfile:

```dockerfile
FROM rust:1.75 as builder

WORKDIR /build
COPY . .
RUN cargo build --release --bin router

FROM debian:bookworm-slim
COPY --from=builder /build/target/release/router /usr/local/bin/router
ENTRYPOINT ["router"]
```

Build and run:

```bash
docker build -t apollo-router:2.8.1-patched .
docker run -p 4000:4000 -v $(pwd)/config.yaml:/config.yaml \
  apollo-router:2.8.1-patched --config /config.yaml
```

## Comparison: Before vs After

### Before Patch (v2.8.1)
```
❌ HTTP/2 request with 20KB headers → 431 Request Header Fields Too Large
❌ No way to configure HTTP/2 header limits
❌ Stuck with Hyper's default 16KB limit
```

### After Patch (v2.8.1-patched)
```
✅ HTTP/2 request with 20KB headers → 200 OK (with http2_max_header_list_size: 32KiB)
✅ Configurable HTTP/2 header limits
✅ Independent HTTP/1.1 and HTTP/2 limits
✅ Backward compatible (defaults to 16KB if not configured)
```

## Testing the Patch

### Quick Test

```bash
# Start router with config
./target/release/router -s apollo-router/testing_schema.graphql -c test-fix.yaml

# Test HTTP/2 with 20KB header (should succeed with 32KB limit)
curl -k --http2 -v https://localhost:4000/ \
  -H "Content-Type: application/json" \
  -H "X-Large: $(head -c 20480 < /dev/zero | tr '\0' 'x')" \
  -d '{"query":"{ __typename }"}'
```

### Comprehensive Tests

Run the full test suite:

```bash
./test-all-limits.sh
```

This runs 20 tests covering:
- HTTP/1.1 header count limits
- HTTP/1.1 buffer size limits
- HTTP/2 header list size limits
- Request body size limits
- Protocol independence

## Quick Reference

| Item | Value |
|------|-------|
| **Version** | 2.8.1 (patched) |
| **Branch** | `v2.8.1-http2-header-limit-patch` |
| **Binary** | `./target/release/router` |
| **Config Option** | `limits.http2_max_header_list_size` |
| **Format** | `32KiB`, `"16384"`, `1MiB` |
| **Default** | 16KB (Hyper default) |

## Notes

- ✅ **Backward compatible** - existing configs work unchanged
- ✅ **Safe to deploy** - only adds functionality, doesn't change behavior without explicit config
- ⚠️ Remember to update to the official version once available

---

**Created**: November 19, 2025  
**Base Version**: Apollo Router v2.8.1  
**Patch**: HTTP/2 Header List Size Configuration

