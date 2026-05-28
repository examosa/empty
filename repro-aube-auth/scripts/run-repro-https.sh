#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run-repro-https.sh
#
# Like run-repro.sh but uses the HTTPS nginx proxy on port 4443 so that
# tarball URLs use https://localhost:4443/ — which is more like how GitHub
# Packages works (HTTPS, no explicit 80/8080 port).
#
# When Aube normalises the tarball URL and looks up the auth token it uses
# registry_uri_key() which strips the scheme.  On HTTP with an explicit
# non-default port (e.g. :4873) the key is unambiguous.  On HTTPS the
# implicit :443 can cause a mismatch between the stored key (//host/) and
# the resolved key (//host:443/).
#
# This script publishes via plain HTTP to Verdaccio and then does the install
# through the HTTPS proxy so the tarball URL seen by Aube is
# https://localhost:4443/…  — isolating the exact edge-case.
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/repro-aube-auth-https-run}"
REGISTRY_HTTP="${REGISTRY_HTTP:-http://localhost:4873}"
REGISTRY_HTTPS="${REGISTRY_HTTPS:-https://localhost}"
SCOPE="@testscope"
PACKAGE_NAME="${SCOPE}/harmless"
PACKAGE_VERSION="${PACKAGE_VERSION:-1.0.0-https.$(date +%s)}"
FULL_PACKAGE="${PACKAGE_NAME}@${PACKAGE_VERSION}"
USERNAME="${VERDACCIO_USERNAME:-repro-https-$(date +%s)}"
PASSWD="${VERDACCIO_PASSWORD:-repro-pass}"
EMAIL="${VERDACCIO_EMAIL:-repro@example.com}"

for cmd in npm yarn curl docker node; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
done
if ! command -v aube >/dev/null 2>&1; then
  echo "Missing required command: aube" >&2
  exit 1
fi

echo "[1/9] Preparing run directory: ${WORK_DIR}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/publisher" "${WORK_DIR}/consumer"

NPM_USERCONFIG="${WORK_DIR}/.npmrc.user"
export NPM_CONFIG_USERCONFIG="${NPM_USERCONFIG}"

cat > "${WORK_DIR}/publisher/package.json" <<JSON
{
  "name": "${PACKAGE_NAME}",
  "version": "${PACKAGE_VERSION}",
  "description": "Auth repro package (HTTPS)",
  "main": "index.js"
}
JSON
printf "module.exports = 'ok';\n" > "${WORK_DIR}/publisher/index.js"

cat > "${WORK_DIR}/consumer/package.json" <<JSON
{
  "name": "consumer",
  "private": true,
  "version": "1.0.0",
  "dependencies": {
    "${PACKAGE_NAME}": "${PACKAGE_VERSION}"
  }
}
JSON

echo "[2/9] Registering user via plain HTTP"
USER_PAYLOAD="$(printf '{"name":"%s","password":"%s","email":"%s","type":"user"}' "${USERNAME}" "${PASSWD}" "${EMAIL}")"
curl -sS -X PUT "${REGISTRY_HTTP}/-/user/org.couchdb.user:${USERNAME}" \
  -H "content-type: application/json" \
  --data "${USER_PAYLOAD}" >"${WORK_DIR}/verdaccio-adduser.json"

TOKEN="$(node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); if(!data.token){process.exit(1)} process.stdout.write(data.token)' "${WORK_DIR}/verdaccio-adduser.json" 2>"${WORK_DIR}/adduser.log" || true)"
if [[ -z "${TOKEN}" ]]; then
  echo "Could not obtain auth token" >&2
  cat "${WORK_DIR}/verdaccio-adduser.json" >&2 || true
  exit 1
fi
export VERDACCIO_TOKEN="${TOKEN}"

# Write npmrc pointing to the HTTPS endpoint for consumer installs
# Key: //localhost:4443/ — explicit non-standard port; or //localhost/ if we
# use real port 443. Both are tested here to surface normalisation differences.
cat > "${NPM_USERCONFIG}" <<EOF
@testscope:registry=${REGISTRY_HTTPS}/
//localhost/:_authToken=${TOKEN}
EOF

echo "[3/9] Publishing via plain HTTP"
cat > "${WORK_DIR}/publisher/.npmrc" <<EOF
@testscope:registry=${REGISTRY_HTTP}/
//localhost:4873/:_authToken=${TOKEN}
EOF
(
  cd "${WORK_DIR}/publisher"
  NPM_CONFIG_USERCONFIG="${WORK_DIR}/publisher/.npmrc" \
    npm publish --registry "${REGISTRY_HTTP}" --access public --tag repro >"${WORK_DIR}/npm-publish.log" 2>&1
)

echo "[4/9] Getting tarball URL (via HTTP)"
TARBALL_URL_HTTP="$(npm view "${PACKAGE_NAME}" dist.tarball --registry "${REGISTRY_HTTP}" | tr -d '\r')"
# Rewrite registry host to HTTPS proxy so Aube resolves auth against that host
TARBALL_URL_HTTPS="${TARBALL_URL_HTTP/http:\/\/localhost:4873/https:\/\/localhost}"
echo "Tarball URL (HTTP):  ${TARBALL_URL_HTTP}"
echo "Tarball URL (HTTPS): ${TARBALL_URL_HTTPS}"

echo "[5/9] Verifying HTTPS tarball auth requirement with curl"
CERT="${ROOT_DIR}/nginx/localhost.crt"
set +e
HTTP_NOAUTH="$(curl -sS -o /dev/null -w "%{http_code}" --cacert "${CERT}" "${TARBALL_URL_HTTPS}")"
HTTP_BEARER="$(curl -sS -o /dev/null -w "%{http_code}" --cacert "${CERT}" --oauth2-bearer "${TOKEN}" "${TARBALL_URL_HTTPS}")"
set -e
echo "curl (no auth)   HTTPS status: ${HTTP_NOAUTH}"
echo "curl (with auth) HTTPS status: ${HTTP_BEARER}"

echo "[6/9] Preparing consumer .npmrc / .yarnrc.yml pointing at HTTPS"
cat > "${WORK_DIR}/consumer/.npmrc" <<EOF
@testscope:registry=${REGISTRY_HTTPS}/
//localhost/:_authToken=${TOKEN}
EOF
cat > "${WORK_DIR}/consumer/.yarnrc.yml" <<YAML
npmScopes:
  testscope:
    npmRegistryServer: "${REGISTRY_HTTPS}"
    npmAlwaysAuth: true
    npmAuthToken: "${TOKEN}"
YAML

echo "[7/9] Install with Yarn (expected success)"
cd "${WORK_DIR}/consumer"
rm -rf node_modules yarn.lock package-lock.json aube.lock
set +e
NODE_TLS_REJECT_UNAUTHORIZED=0 yarn install >"${WORK_DIR}/yarn-install.log" 2>&1
YARN_EXIT=$?
set -e
echo "yarn exit code: ${YARN_EXIT}"

echo "[8/9] Install with Aube (expected 403 / auth-drop failure when bug reproduces)"
rm -rf node_modules aube.lock yarn.lock
set +e
NODE_TLS_REJECT_UNAUTHORIZED=0 aube install >"${WORK_DIR}/aube-install.log" 2>&1
AUBE_EXIT=$?
set -e
echo "aube exit code: ${AUBE_EXIT}"

echo "[9/9] Snapshot Verdaccio logs"
docker compose -f "${ROOT_DIR}/docker-compose.yml" logs --no-color verdaccio > "${WORK_DIR}/verdaccio.log"

echo ""
echo "=== Summary ==="
echo "curl (no auth)   HTTPS: ${HTTP_NOAUTH}"
echo "curl (with auth) HTTPS: ${HTTP_BEARER}"

echo ""
echo "--- Verdaccio tarball lines ---"
ESCAPED="${PACKAGE_VERSION//./\\.}"
grep -n "${ESCAPED}\.tgz" "${WORK_DIR}/verdaccio.log" || echo "(no tarball log lines)"

echo ""
echo "--- Yarn tail ---"
tail -n 30 "${WORK_DIR}/yarn-install.log"

echo ""
echo "--- Aube tail ---"
tail -n 30 "${WORK_DIR}/aube-install.log"

if [[ "${YARN_EXIT}" -eq 0 ]]; then
  echo "Yarn: PASS"
else
  echo "Yarn: FAIL (exit ${YARN_EXIT})"
fi

if [[ "${AUBE_EXIT}" -ne 0 ]]; then
  if grep -q "403\|401\|unauthorized\|forbidden" "${WORK_DIR}/aube-install.log" 2>/dev/null; then
    echo "Aube: FAILS WITH AUTH ERROR (repro matched expected bug)"
  else
    echo "Aube: FAILS (different error — see aube-install.log)"
  fi
else
  echo "Aube: PASS (bug not reproduced)"
fi

echo ""
echo "Artifacts: ${WORK_DIR}"
