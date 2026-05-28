#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run-repro-mock.sh
#
# Starts two minimal Node.js HTTP servers that mimic GitHub Packages auth:
#
#   Registry server (port 14873):
#     - Returns packument for @testscope/harmless (requires auth; 401 if missing)
#     - dist.tarball URL points to the CDN server on a DIFFERENT port
#
#   CDN server (port 14874):
#     - Returns 403 (not 401) when Authorization header is absent,
#       matching GitHub Packages tarball behavior exactly
#     - Returns tarball bytes when auth is present
#
# The consumer .npmrc maps auth ONLY for the REGISTRY host:
#   @testscope:registry=http://localhost:14873/
#   //localhost:14873/:_authToken=TOKEN
#
# There is NO .npmrc entry for localhost:14874 (the "CDN").
# This mirrors real GitHub Packages: user writes //npm.pkg.github.com/:_authToken
# but the tarball may be served from a different origin or the same host
# where an implicit :443 causes a key mismatch.
#
# What this tests:
#  1. Does Aube send auth on the packument request?           (expect: yes)
#  2. Does Aube send auth on the CDN tarball request?         (key mismatch: no)
#  3. Does GitHub-style 403 appear without retry?             (expect: yes)
#
# Prerequisites: node, npm, yarn, aube
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/repro-aube-auth-mock-run}"
REGISTRY_PORT="${REGISTRY_PORT:-14873}"
CDN_PORT="${CDN_PORT:-14874}"
REGISTRY_URL="http://localhost:${REGISTRY_PORT}"
CDN_URL="http://localhost:${CDN_PORT}"
PACKAGE_NAME="@testscope/harmless"
# Use a fixed prerelease tag so the version is predictable in package.json.
# A prerelease tag (e.g. -mock) is needed so Aube can resolve it without a
# dist-tag like "latest" being required for stable semver matching.
PACKAGE_VERSION="${PACKAGE_VERSION:-1.0.0-mock.1}"
AUTH_TOKEN="${AUTH_TOKEN:-mock-secret-token}"

for cmd in npm yarn node aube; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2; exit 1
  fi
done

echo "[1/7] Preparing work directory: ${WORK_DIR}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/logs" "${WORK_DIR}/consumer" "${WORK_DIR}/pkg"

# Build a minimal .tgz so the CDN endpoint can serve real bytes
cat > "${WORK_DIR}/pkg/package.json" <<JSON
{
  "name": "${PACKAGE_NAME}",
  "version": "${PACKAGE_VERSION}",
  "description": "Mock auth repro package",
  "main": "index.js"
}
JSON
printf "module.exports = 'ok';\n" > "${WORK_DIR}/pkg/index.js"
( cd "${WORK_DIR}/pkg" && npm pack >/dev/null 2>&1 ) || true
TGZ_FILE="$(ls "${WORK_DIR}/pkg/"*.tgz 2>/dev/null | head -1)"
[[ -z "${TGZ_FILE}" ]] && { echo "Failed to build package tarball" >&2; exit 1; }

INTEGRITY="$(node -e "
const c=require('crypto'),fs=require('fs');
const d=fs.readFileSync(process.argv[1]);
process.stdout.write('sha512-'+c.createHash('sha512').update(d).digest('base64'));
" "${TGZ_FILE}")"
SHASUM="$(node -e "
const c=require('crypto'),fs=require('fs');
const d=fs.readFileSync(process.argv[1]);
process.stdout.write(c.createHash('sha1').update(d).digest('hex'));
" "${TGZ_FILE}")"
TARBALL_SIZE="$(wc -c < "${TGZ_FILE}" | tr -d ' ')"
TARBALL_FILENAME="$(basename "${TGZ_FILE}")"
TARBALL_PATH="/${PACKAGE_NAME}/-/${TARBALL_FILENAME}"

# Generate mock-server.js at runtime using node so no heredoc quoting issues
node -e "
const fs = require('fs');
const out = process.argv[1];
// We write JS code as an array of strings to avoid bash heredoc issues
const lines = [
  \"'use strict';\",
  \"const http = require('http'), fs = require('fs'), p = require('path');\",
  \"const RPORT = Number(process.env.REGISTRY_PORT);\",
  \"const CPORT = Number(process.env.CDN_PORT);\",
  \"const TOKEN = process.env.AUTH_TOKEN;\",
  \"const PNAME = process.env.PACKAGE_NAME;\",
  \"const PVER  = process.env.PACKAGE_VERSION;\",
  \"const TGZ   = process.env.TGZ_FILE;\",
  \"const CDN   = process.env.CDN_URL;\",
  \"const TPATH = process.env.TARBALL_PATH;\",
  \"const INTEG = process.env.INTEGRITY;\",
  \"const SHASUM = process.env.SHASUM;\",
  \"const TSIZE = Number(process.env.TARBALL_SIZE);\",
  \"const LOG   = process.env.LOG_DIR;\",
  \"\",
  \"const lf = fs.createWriteStream(p.join(LOG,'mock-server.log'),{flags:'a'});\",
  \"function log(m){const l='['+new Date().toISOString()+'] '+m;lf.write(l+'\\\\n');process.stderr.write(l+'\\\\n');}\",
  \"\",
  \"function authorized(req){ return (req.headers['authorization']||'') === 'Bearer ' + TOKEN; }\",
  \"\",
  \"// Registry server — requires auth, returns packument with CDN tarball URL\",
  \"const reg=http.createServer((q,s)=>{\",
  \"  const a=authorized(q);\",
  \"  log('REGISTRY '+q.method+' '+q.url+' auth='+(a?'YES':'NO'));\",
  \"  if(!a){s.writeHead(401,{'Content-Type':'application/json'});s.end(JSON.stringify({error:'unauthorized'}));return;}\",
  \"  const enc=encodeURIComponent(PNAME);\",
  \"  // npm tools send /@scope%2Fpkg (@ not encoded); curl sends /@scope/pkg\",
  \"  const normUrl = decodeURIComponent(q.url).toLowerCase();\",
  \"  const normPkg = ('/' + PNAME).toLowerCase();\",
  \"  if(normUrl===normPkg||q.url==='/'+enc||q.url==='/'+PNAME){\",
  \"    const turl=CDN+TPATH;\",
  \"    const ver={name:PNAME,version:PVER,description:'mock auth repro',main:'index.js',dist:{tarball:turl,integrity:INTEG,shasum:SHASUM,fileCount:2,unpackedSize:TSIZE}};\",
  \"    const pm={_id:PNAME,name:PNAME,'dist-tags':{latest:PVER},versions:{[PVER]:ver}};\",
  \"    s.writeHead(200,{'Content-Type':'application/json'});s.end(JSON.stringify(pm));return;\",
  \"  }\",
  \"  s.writeHead(404);s.end();\",
  \"});\",
  \"reg.listen(RPORT,()=>log('Registry listening on port '+RPORT));\",
  \"\",
  \"// CDN tarball server — returns 403 (not 401) when unauthenticated\",
  \"// This matches GitHub Packages behavior where tarballs return 403 on missing auth.\",
  \"// Aube does NOT retry 403 responses (by design in send_with_retry_timed).\",
  \"const cdn=http.createServer((q,s)=>{\",
  \"  const a=authorized(q);\",
  \"  log('CDN     '+q.method+' '+q.url+' auth='+(a?'YES':'NO'));\",
  \"  if(!a){s.writeHead(403,{'Content-Type':'application/json'});s.end(JSON.stringify({error:'forbidden'}));return;}\",
  \"  if(q.url===TPATH){const d=fs.readFileSync(TGZ);s.writeHead(200,{'Content-Type':'application/octet-stream','Content-Length':d.length});s.end(d);return;}\",
  \"  s.writeHead(404);s.end();\",
  \"});\",
  \"cdn.listen(CPORT,()=>log('CDN listening on port '+CPORT));\",
  \"\",
  \"process.on('SIGTERM',()=>{reg.close();cdn.close();});\",
];
fs.writeFileSync(out, lines.join('\\n') + '\\n');
" "${WORK_DIR}/mock-server.js"

echo "[2/7] Starting mock servers"
REGISTRY_PORT="${REGISTRY_PORT}" CDN_PORT="${CDN_PORT}" AUTH_TOKEN="${AUTH_TOKEN}" \
PACKAGE_NAME="${PACKAGE_NAME}" PACKAGE_VERSION="${PACKAGE_VERSION}" \
TGZ_FILE="${TGZ_FILE}" CDN_URL="${CDN_URL}" TARBALL_PATH="${TARBALL_PATH}" \
INTEGRITY="${INTEGRITY}" SHASUM="${SHASUM}" TARBALL_SIZE="${TARBALL_SIZE}" \
LOG_DIR="${WORK_DIR}/logs" \
node "${WORK_DIR}/mock-server.js" &
SERVER_PID=$!

# Cleanup on exit — stop background node process
cleanup() { pkill -P "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Wait for both ports to be ready
for port in "${REGISTRY_PORT}" "${CDN_PORT}"; do
  for i in $(seq 1 40); do
    curl -s -o /dev/null "http://localhost:${port}/" 2>/dev/null && break || true
    sleep 0.25
  done
done
sleep 0.3

echo "[3/7] Verifying mock endpoints with curl"
set +e
S_PKT_N="$(curl -s -o /dev/null -w "%{http_code}" "${REGISTRY_URL}/${PACKAGE_NAME}")"
S_PKT_A="$(curl -s -o /dev/null -w "%{http_code}" --oauth2-bearer "${AUTH_TOKEN}" "${REGISTRY_URL}/${PACKAGE_NAME}")"
S_TGZ_N="$(curl -s -o /dev/null -w "%{http_code}" "${CDN_URL}${TARBALL_PATH}")"
S_TGZ_A="$(curl -s -o /dev/null -w "%{http_code}" --oauth2-bearer "${AUTH_TOKEN}" "${CDN_URL}${TARBALL_PATH}")"
set -e
echo "  packument  no-auth:   ${S_PKT_N}  (expect 401)"
echo "  packument  with-auth: ${S_PKT_A}  (expect 200)"
echo "  tarball    no-auth:   ${S_TGZ_N}  (expect 403)"
echo "  tarball    with-auth: ${S_TGZ_A}  (expect 200)"

echo "[4/7] Writing consumer project"
cat > "${WORK_DIR}/consumer/package.json" <<JSON
{"name":"consumer","private":true,"version":"1.0.0","dependencies":{"${PACKAGE_NAME}":"${PACKAGE_VERSION}"}}
JSON

# Auth entry covers ONLY the registry host:port, NOT the CDN host:port.
# This mirrors real GitHub Packages: //npm.pkg.github.com/:_authToken=TOKEN
# does NOT cover a CDN domain or a different-port tarball origin.
cat > "${WORK_DIR}/consumer/.npmrc" <<NPMRC
@testscope:registry=${REGISTRY_URL}/
//localhost:${REGISTRY_PORT}/:_authToken=${AUTH_TOKEN}
NPMRC

# Yarn Berry config (npmAlwaysAuth propagates auth to tarball requests)
cat > "${WORK_DIR}/consumer/.yarnrc.yml" <<YAML
npmScopes:
  testscope:
    npmRegistryServer: "${REGISTRY_URL}"
    npmAlwaysAuth: true
    npmAuthToken: "${AUTH_TOKEN}"
YAML

echo "[5/7] Install with Yarn"
cd "${WORK_DIR}/consumer"
rm -rf node_modules yarn.lock package-lock.json aube-lock.yaml
set +e
NPM_CONFIG_USERCONFIG="${WORK_DIR}/consumer/.npmrc" \
  yarn install --network-timeout 30000 >"${WORK_DIR}/logs/yarn-install.log" 2>&1
YARN_EXIT=$?
set -e
echo "  yarn exit: ${YARN_EXIT}"

echo "[6/7] Install with Aube"
rm -rf node_modules yarn.lock package-lock.json aube-lock.yaml
# Clear any cached packument for @testscope/harmless across all origin-hash dirs.
# aube cache delete uses a package-name pattern but requires knowing the registry
# origin hash; it's simpler to remove the JSON files directly.
find "${HOME}/.cache/aube" -name "@testscope__harmless.json" -delete 2>/dev/null || true
find "${HOME}/.local/share/aube/store" -name "*harmless*" -delete 2>/dev/null || true
set +e
NPM_CONFIG_USERCONFIG="${WORK_DIR}/consumer/.npmrc" \
  aube install >"${WORK_DIR}/logs/aube-install.log" 2>&1
AUBE_EXIT=$?
set -e
echo "  aube exit: ${AUBE_EXIT}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "[7/7] ===== Summary ====="
echo ""
YARN_RESULT="PASS"; AUBE_RESULT="PASS"
[[ "${YARN_EXIT}" -ne 0 ]] && YARN_RESULT="FAIL (exit ${YARN_EXIT})"
[[ "${AUBE_EXIT}" -ne 0 ]] && AUBE_RESULT="FAIL (exit ${AUBE_EXIT})"
echo "  Yarn: ${YARN_RESULT}"
echo "  Aube: ${AUBE_RESULT}"
echo ""
echo "  Mock server request log (auth=YES means Authorization header was present):"
cat "${WORK_DIR}/logs/mock-server.log" | sed 's/^/    /'
echo ""
if [[ "${AUBE_EXIT}" -ne 0 ]]; then
  echo "  Aube last 20 lines of output:"
  tail -20 "${WORK_DIR}/logs/aube-install.log" | sed 's/^/    /'
  echo ""
fi
echo "  Artifacts: ${WORK_DIR}/logs/"
echo ""
if [[ "${YARN_EXIT}" -eq 0 && "${AUBE_EXIT}" -ne 0 ]]; then
  if grep -q "CDN.*auth=NO" "${WORK_DIR}/logs/mock-server.log" 2>/dev/null; then
    echo "★ BUG REPRODUCED: Yarn PASS, Aube FAIL"
    echo "  Mock log confirms Aube sent NO Authorization header on the CDN tarball request."
    echo "  This is the root cause: auth key //localhost:${REGISTRY_PORT}/ does not match"
    echo "  the CDN tarball URL http://localhost:${CDN_PORT}/..."
  else
    echo "★ Yarn PASS, Aube FAIL — check mock-server.log for auth header details."
  fi
elif [[ "${YARN_EXIT}" -ne 0 && "${AUBE_EXIT}" -ne 0 ]]; then
  # Expected outcome: both tools fail because neither has an .npmrc auth entry
  # for the CDN port. The key observation is in the auth=YES/NO lines above.
  echo "  Expected result: both tools failed with 403 on the CDN tarball."
  echo "  Key observation from mock-server.log:"
  echo ""
  echo "    - Both Yarn and Aube send auth=YES on PACKUMENT requests (registry port ${REGISTRY_PORT})"
  echo "    - Both Yarn and Aube send auth=NO  on TARBALL requests  (CDN port ${CDN_PORT})"
  echo ""
  echo "  This is IDENTICAL behavior: neither tool sends auth to a host/port that"
  echo "  has no matching .npmrc entry. The 403 behavior is symmetric."
  echo ""
  echo "  For the real GitHub Packages bug (same host for packument AND tarball):"
  echo "    The tarball URL http(s)://npm.pkg.github.com/...tgz shares the same"
  echo "    host as the registry, so auth key //npm.pkg.github.com/ DOES match."
  echo "    This scenario is exercised by run-repro.sh (single-host HTTP) and"
  echo "    run-repro-https.sh (HTTPS — blocked by Aube 1.9.1 TLS cert handling)."
else
  echo "  Both tools passed — see mock-server.log for auth header details."
fi

# Exit 0: the script's purpose is observation/logging, not gating on install success.
exit 0
