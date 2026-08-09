#!/usr/bin/env bash
# Author: Mengty LIM
#
# Post-deployment smoke test, run through the public entry point rather than
# against a pod. It verifies the whole path — LB, ingress, TLS, auth, app, DB —
# which is what a user actually experiences.
#
#   smoke.sh <environment>
set -euo pipefail

ENVIRONMENT="${1:?environment required}"
BASE_URL="${SMOKE_BASE_URL:-https://payments.${ENVIRONMENT}.bank.internal}"
EXPECTED_DIGEST="${EXPECTED_DIGEST:-}"
TIMEOUT=10

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; exit 1; }

echo "Smoke testing ${BASE_URL}"

# --- reachability + TLS -----------------------------------------------------
echo "[1/7] TLS and reachability"
curl -sf --max-time "${TIMEOUT}" "${BASE_URL}/healthz" >/dev/null \
  || fail "health endpoint unreachable"
pass "health endpoint responding"

TLS_VERSION=$(curl -sI --max-time "${TIMEOUT}" -w '%{ssl_verify_result}' -o /dev/null "${BASE_URL}/healthz")
[[ "${TLS_VERSION}" == "0" ]] || fail "TLS certificate verification failed (code ${TLS_VERSION})"
pass "TLS certificate valid"

# Certificate expiry is a classic 2am outage — catch it while it is a ticket.
DAYS_LEFT=$(echo | openssl s_client -connect "${BASE_URL#https://}:443" -servername "${BASE_URL#https://}" 2>/dev/null \
  | openssl x509 -noout -enddate | cut -d= -f2 \
  | xargs -I{} date -d {} +%s | awk -v now="$(date +%s)" '{print int(($1-now)/86400)}')
(( DAYS_LEFT > 14 )) || fail "certificate expires in ${DAYS_LEFT} days"
pass "certificate valid for ${DAYS_LEFT} more days"

# --- readiness --------------------------------------------------------------
echo "[2/7] Readiness (dependencies)"
curl -sf --max-time "${TIMEOUT}" "${BASE_URL}/ready" >/dev/null \
  || fail "not ready — a dependency (DB/Vault/Keycloak) is unreachable"
pass "all dependencies reachable"

# --- version ----------------------------------------------------------------
echo "[3/7] Deployed version"
DEPLOYED=$(curl -sf --max-time "${TIMEOUT}" "${BASE_URL}/version" | jq -r '.digest // .version')
if [[ -n "${EXPECTED_DIGEST}" ]]; then
  [[ "${DEPLOYED}" == "${EXPECTED_DIGEST}" ]] \
    || fail "running ${DEPLOYED}, expected ${EXPECTED_DIGEST}"
fi
pass "running ${DEPLOYED}"

# --- security headers -------------------------------------------------------
echo "[4/7] Security headers"
HEADERS=$(curl -sI --max-time "${TIMEOUT}" "${BASE_URL}/healthz")
for header in "strict-transport-security" "x-content-type-options" "x-frame-options"; do
  grep -qi "^${header}:" <<< "${HEADERS}" || fail "missing ${header} header"
done
grep -qi "^server:" <<< "${HEADERS}" && fail "Server header is leaking implementation details"
pass "security headers present, no version disclosure"

# --- authentication is actually enforced ------------------------------------
echo "[5/7] Authentication enforcement"
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time "${TIMEOUT}" "${BASE_URL}/api/v1/payments")
[[ "${CODE}" == "401" || "${CODE}" == "403" ]] \
  || fail "unauthenticated request returned ${CODE} — expected 401/403"
pass "unauthenticated requests rejected (${CODE})"

# A forged token must be rejected too — an app that accepts `alg: none` returns
# 200 here and passes every other check in this script.
FORGED="eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJhdHRhY2tlciJ9."
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time "${TIMEOUT}" \
  -H "Authorization: Bearer ${FORGED}" "${BASE_URL}/api/v1/payments")
[[ "${CODE}" == "401" || "${CODE}" == "403" ]] \
  || fail "unsigned (alg:none) token returned ${CODE} — JWT validation is broken"
pass "forged token rejected (${CODE})"

# --- authenticated happy path ----------------------------------------------
echo "[6/7] Authenticated request"
if [[ -n "${SMOKE_TEST_TOKEN:-}" ]]; then
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time "${TIMEOUT}" \
    -H "Authorization: Bearer ${SMOKE_TEST_TOKEN}" "${BASE_URL}/api/v1/payments?limit=1")
  [[ "${CODE}" == "200" ]] || fail "authenticated request returned ${CODE}"
  pass "authenticated request succeeded"
else
  echo "  SKIP: SMOKE_TEST_TOKEN not set"
fi

# --- latency ----------------------------------------------------------------
echo "[7/7] Latency"
ELAPSED=$(curl -s -o /dev/null -w '%{time_total}' --max-time "${TIMEOUT}" "${BASE_URL}/healthz")
awk -v t="${ELAPSED}" 'BEGIN { exit (t < 1.0) ? 0 : 1 }' \
  || fail "health check took ${ELAPSED}s — something is already degraded"
pass "responded in ${ELAPSED}s"

echo
echo "SMOKE PASS: ${ENVIRONMENT} (${DEPLOYED})"
echo "Now watch the SLO dashboard for 30 minutes before considering this done."
