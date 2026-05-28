# Aube auth tarball repro harness

This harness tests whether auth tokens are sent on tarball download requests,
comparing Yarn (known-good) against Aube, to reproduce the reported bug where
Aube fails with 403 on authenticated registries (GitHub Packages, Verdaccio
with auth) while Yarn succeeds.

## Prerequisites

- Docker + Docker Compose (for `run-repro.sh` and `run-repro-https.sh`)
- Node.js ≥ 18 + npm + yarn
- [Aube](https://github.com/endevco/aube) — install from [GitHub Releases](https://github.com/endevco/aube/releases)

Install Aube (Linux x86-64):
```bash
curl -L https://github.com/endevco/aube/releases/download/v1.9.1/aube-v1.9.1-x86_64-unknown-linux-gnu.tar.gz \
  | tar xz
install -m 755 aube ~/.local/bin/aube
export PATH="$HOME/.local/bin:$PATH"
```

## Scripts

| Script | Description |
|---|---|
| `scripts/run-repro.sh` | Verdaccio HTTP test (explicit port 4873). Both tools pass — baseline. |
| `scripts/run-repro-mock.sh` | Node.js mock registry + CDN on separate ports. No Docker needed. Tests auth-header presence per request. |
| `scripts/run-repro-https.sh` | HTTPS variant via nginx proxy. Blocked on Aube TLS (see below). |

## Quick start — mock test (no Docker needed)

```bash
cd repro-aube-auth
./scripts/run-repro-mock.sh
```

The mock test runs two local HTTP servers (no Docker, no TLS):

- **Registry** on port 14873 — serves the packument, requires `Authorization: Bearer` (returns 401 if absent)
- **CDN** on port 14874 — serves the tarball, returns **403** (not 401) when auth is absent, matching GitHub Packages behavior exactly

The `.npmrc` has an auth entry for the registry port (`//localhost:14873/`) but **not** for the CDN port (`//localhost:14874/`). This mirrors the real-world scenario where the tarball URL doesn't match the registry key.

**Expected output:**
```
CDN GET /@testscope/harmless/-/....tgz auth=NO   ← Aube gets 403, no retry
CDN GET /@testscope/harmless/-/....tgz auth=NO   ← Yarn also gets 403
```
Both tools behave identically when no `.npmrc` entry covers the tarball host.

## Full Verdaccio test (requires Docker)

```bash
docker compose up -d
./scripts/run-repro.sh
```

On a single-host HTTP registry (explicit port 4873), **both Yarn and Aube authenticate correctly** — the auth key `//localhost:4873/` matches the tarball URL `http://localhost:4873/...` exactly and both tools pass.

## HTTPS test (blocked — see findings)

`scripts/run-repro-https.sh` targets an nginx HTTPS proxy on port 443. It is currently blocked because **Aube 1.9.1 uses baked-in Mozilla root CAs** (`webpki-roots`) and does not read the system cert store, so it rejects our self-signed certificate with a TLS transport error before any auth check occurs.

## Findings

### What was tested

| Scenario | Yarn | Aube 1.9.1 | Notes |
|---|---|---|---|
| HTTP, explicit port (4873), matching `.npmrc` key | ✅ PASS | ✅ PASS | No bug observed |
| Mock CDN: tarball on different host/port, no matching key | ❌ FAIL | ❌ FAIL | Both fail identically — auth=NO on CDN |
| HTTPS, port 443 (default, no explicit port) | ✅ PASS | ❌ TLS error | Blocked — Aube rejects self-signed cert |

### Code analysis — Aube 1.9.1 auth key normalization

`fetch_tarball_bytes` calls `authed_get(tarball_url, tarball_url)`, which calls
`registry_config_for(tarball_url)` → `registry_uri_key(tarball_url)` →
`lookup_by_uri_prefix(auth_by_uri, key)`.

For a tarball URL `https://npm.pkg.github.com/@org/pkg/-/pkg-1.0.0.tgz`:

1. `registry_uri_key` strips `https:` and calls `strip_authority_port_suffix` with `:443` — since the authority `npm.pkg.github.com` carries no explicit `:443`, the key is `//npm.pkg.github.com/@org/pkg/-/pkg-1.0.0.tgz`.
2. `lookup_by_uri_prefix` walks the path upward until it reaches `//npm.pkg.github.com/` — which **matches** the `.npmrc` key `//npm.pkg.github.com/:_authToken`.

**The key normalization in Aube 1.9.1 is correct** for the standard GitHub Packages case. The suspected normalization bug does not appear to be present in v1.9.1 based on static analysis.

### Most likely root cause of the real-world 403

Two remaining hypotheses that could not be tested locally:

1. **HTTPS default-port edge case** — some code path that is only exercised with a real HTTPS connection where the library or TLS layer adds an explicit `:443` to the URL before the auth lookup. This would cause `registry_uri_key` to produce `//npm.pkg.github.com:443/...` which does NOT match the stored key `//npm.pkg.github.com/`. The HTTPS test was blocked by Aube's TLS cert handling.

2. **`send_with_retry_timed` does not retry 403** — confirmed in source: "401, 403 — is returned verbatim." If auth is not attached on the first tarball request (for any reason), GitHub Packages returns 403 with no second chance. Yarn may issue a fresh 401-challenge/retry cycle or cache credentials differently.

### How to fully test HTTPS scenario

To run the HTTPS variant against a trusted cert:

```bash
# Option A: use mkcert (installs a local CA that both curl and Aube 1.16.0+ trust)
mkcert -install
mkcert localhost
# Replace nginx/localhost.crt + nginx/localhost.key with mkcert output, then:
docker compose up -d
./scripts/run-repro-https.sh

# Option B: obtain a real cert for a local hostname via Let's Encrypt + DNS challenge
```

Aube 1.16.0 adds `with_webpki_root_fallback` which includes native system roots in the TLS trust chain. After `mkcert -install`, Aube 1.16.0 should trust the mkcert CA and the HTTPS test can run end-to-end.

## Files

```
repro-aube-auth/
├── docker-compose.yml         # Verdaccio + nginx HTTPS proxy
├── verdaccio/
│   └── config.yaml            # Requires auth for @testscope/*
├── nginx/
│   ├── nginx.conf             # HTTPS reverse proxy to Verdaccio
│   ├── localhost.crt          # Self-signed cert (not trusted by Aube 1.9.1)
│   └── localhost.key
├── scripts/
│   ├── run-repro.sh           # HTTP/Verdaccio test
│   ├── run-repro-mock.sh      # Node.js mock registry+CDN, no Docker
│   └── run-repro-https.sh     # HTTPS variant (blocked by TLS)
└── README.md
```
