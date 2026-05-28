# Aube auth tarball repro harness

This harness reproduces auth-header behavior differences on tarball downloads using a local authenticated Verdaccio registry.

## Prerequisites

- Docker + Docker Compose
- Node.js + npm
- Yarn
- Aube

## Files

- `docker-compose.yml` - starts local Verdaccio on `http://localhost:4873`
- `verdaccio/config.yaml` - requires authenticated access for `@testscope/*`
- `.npmrc` / `.yarnrc.yml` - token-based registry config (uses `VERDACCIO_TOKEN` env var)
- `scripts/run-repro.sh` - publish package, run Yarn + Aube installs, capture logs

## Run

```bash
cd /tmp/workspace/examosa/empty/repro-aube-auth
docker compose up -d
./scripts/run-repro.sh
```

## What to expect

- Yarn install succeeds for `@testscope/harmless`
- Aube install fails with `403` on tarball fetch when the bug reproduces
- Script writes artifacts in `/tmp/repro-aube-auth-run`, including:
  - `verdaccio.log`
  - `yarn-install.log`
  - `aube-install.log`

To confirm auth handling on `.tgz` fetches, inspect `verdaccio.log` entries for `harmless-1.0.0.tgz` and compare Yarn vs Aube behavior.
