#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/repro-aube-auth-run}"
REGISTRY_URL="${REGISTRY_URL:-http://localhost:4873}"
SCOPE="@testscope"
PACKAGE_NAME="${SCOPE}/harmless"
PACKAGE_VERSION="${PACKAGE_VERSION:-1.0.0-repro.$(date +%s)}"
FULL_PACKAGE="${PACKAGE_NAME}@${PACKAGE_VERSION}"
USERNAME="${VERDACCIO_USERNAME:-repro-user-$(date +%s)}"
PASSWD="${VERDACCIO_PASSWORD:-repro-pass}"
EMAIL="${VERDACCIO_EMAIL:-repro@example.com}"

for cmd in npm yarn curl docker; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
done
if ! command -v aube >/dev/null 2>&1; then
  echo "Missing required command: aube" >&2
  exit 1
fi

echo "[1/8] Preparing run directory: ${WORK_DIR}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/publisher" "${WORK_DIR}/consumer"

NPM_USERCONFIG="${WORK_DIR}/.npmrc.user"
export NPM_CONFIG_USERCONFIG="${NPM_USERCONFIG}"

cat > "${WORK_DIR}/publisher/package.json" <<JSON
{
  "name": "${PACKAGE_NAME}",
  "version": "${PACKAGE_VERSION}",
  "description": "Auth repro package",
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

cp "${ROOT_DIR}/.npmrc" "${WORK_DIR}/consumer/.npmrc"
cp "${ROOT_DIR}/.yarnrc.yml" "${WORK_DIR}/consumer/.yarnrc.yml"

echo "[2/8] Logging in to Verdaccio"
USER_PAYLOAD="$(printf '{"name":"%s","password":"%s","email":"%s","type":"user"}' "${USERNAME}" "${PASSWD}" "${EMAIL}")"
curl -sS -X PUT "${REGISTRY_URL}/-/user/org.couchdb.user:${USERNAME}" \
  -H "content-type: application/json" \
  --data "${USER_PAYLOAD}" >"${WORK_DIR}/verdaccio-adduser.json"

TOKEN="$(node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); if(!data.token){process.exit(1)} process.stdout.write(data.token)' "${WORK_DIR}/verdaccio-adduser.json" 2>"${WORK_DIR}/npm-adduser.log" || true)"
if [[ -z "${TOKEN}" ]]; then
  echo "Could not obtain auth token from Verdaccio user creation response" >&2
  cat "${WORK_DIR}/verdaccio-adduser.json" >&2 || true
  exit 1
fi
export VERDACCIO_TOKEN="${TOKEN}"
cat > "${NPM_USERCONFIG}" <<EOF
@testscope:registry=${REGISTRY_URL}/
//localhost:4873/:_authToken=${TOKEN}
always-auth=true
EOF

echo "[3/8] Publishing ${FULL_PACKAGE}"
(
  cd "${WORK_DIR}/publisher"
  npm publish --registry "${REGISTRY_URL}" --access public --tag repro >"${WORK_DIR}/npm-publish.log" 2>&1
)

echo "[4/8] Getting tarball URL"
TARBALL_URL="$(npm view "${PACKAGE_NAME}" dist.tarball --registry "${REGISTRY_URL}" | tr -d '\r')"
if [[ -z "${TARBALL_URL}" ]]; then
  echo "Failed to obtain tarball URL" >&2
  exit 1
fi
echo "Tarball URL: ${TARBALL_URL}"

echo "[5/8] Verifying tarball auth requirement with curl"
set +e
HTTP_NOAUTH="$(curl -sS -o /dev/null -w "%{http_code}" "${TARBALL_URL}")"
HTTP_BEARER="$(curl -sS -o /dev/null -w "%{http_code}" --oauth2-bearer "${TOKEN}" "${TARBALL_URL}")"
set -e
echo "curl (no auth) status : ${HTTP_NOAUTH}"
echo "curl (with auth) status: ${HTTP_BEARER}"

echo "[6/8] Install with Yarn (expected success)"
cd "${WORK_DIR}/consumer"
rm -rf node_modules yarn.lock package-lock.json aube.lock
set +e
yarn install >"${WORK_DIR}/yarn-install.log" 2>&1
YARN_EXIT=$?
set -e
echo "yarn exit code: ${YARN_EXIT}"

echo "[7/8] Install with Aube (expected 403 failure when bug reproduces)"
rm -rf node_modules aube.lock
set +e
aube install >"${WORK_DIR}/aube-install.log" 2>&1
AUBE_EXIT=$?
set -e
echo "aube exit code: ${AUBE_EXIT}"

echo "[8/8] Snapshot Verdaccio logs"
docker compose -f "${ROOT_DIR}/docker-compose.yml" logs --no-color verdaccio > "${WORK_DIR}/verdaccio.log"

echo "\n=== Summary ==="
grep -n "harmless-${PACKAGE_VERSION}\.tgz" "${WORK_DIR}/verdaccio.log" || true

if [[ -f "${WORK_DIR}/yarn-install.log" ]]; then
  echo "\n--- Yarn tail ---"
  tail -n 30 "${WORK_DIR}/yarn-install.log"
fi
if [[ -f "${WORK_DIR}/aube-install.log" ]]; then
  echo "\n--- Aube tail ---"
  tail -n 30 "${WORK_DIR}/aube-install.log"
fi

if [[ "${YARN_EXIT}" -eq 0 ]]; then
  echo "Yarn: PASS (expected success)"
else
  echo "Yarn: FAIL (unexpected non-zero exit)"
fi

if [[ "${AUBE_EXIT}" -ne 0 ]] && grep -q "403" "${WORK_DIR}/aube-install.log"; then
  echo "Aube: FAILS WITH 403 (repro matched expected bug)"
else
  echo "Aube: did not fail with 403 (bug not reproduced in this run)"
fi

echo "\nArtifacts are in: ${WORK_DIR}"
echo "Inspect ${WORK_DIR}/verdaccio.log for tarball request lines and user/auth behavior."
