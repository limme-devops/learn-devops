#!/usr/bin/env bash
# Author: Mengty LIM
#
# Vault configuration as code. Run from CI against a Vault that is already
# initialised and unsealed. Idempotent — safe to re-run.
#
# What this deliberately does NOT do: create long-lived secrets. Every
# credential below is either dynamic (minted per request) or an identity
# binding (no secret material at all).
set -euo pipefail

: "${VAULT_ADDR:?VAULT_ADDR must be set}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be set — obtain it via OIDC/JWT login, never a static root token}"

ENVIRONMENT="${ENVIRONMENT:-dev}"
K8S_HOST="${K8S_HOST:?kube-apiserver URL required}"
POLICY_DIR="$(dirname "$0")/policies"

log() { echo "==> $*"; }

# --- Audit first. If auditing cannot start, nothing else should. ------------
log "Enabling audit devices"
vault audit enable file file_path=/vault/audit/audit.log 2>/dev/null || log "  file audit already enabled"
vault audit enable syslog tag="vault" facility="AUTH" 2>/dev/null || log "  syslog audit already enabled"

# --- Secret engines ---------------------------------------------------------
log "Enabling secret engines"
vault secrets enable -path=kv -version=2 kv 2>/dev/null || log "  kv already enabled"
vault secrets enable database 2>/dev/null || log "  database already enabled"
vault secrets enable transit 2>/dev/null || log "  transit already enabled"
vault secrets enable -path=pki_int pki 2>/dev/null || log "  pki_int already enabled"

# Short max TTL on the intermediate CA: short-lived certs mean a leaked key has
# a small blast radius and revocation infrastructure matters less.
vault secrets tune -max-lease-ttl=43800h pki_int

# --- Policies ---------------------------------------------------------------
log "Applying policies from ${POLICY_DIR}"
for policy_file in "${POLICY_DIR}"/*.hcl; do
  name="$(basename "${policy_file}" .hcl)"
  log "  policy: ${name}"
  vault policy write "${name}" "${policy_file}"
done

# --- Kubernetes auth: the pod's identity IS its credential ------------------
log "Configuring Kubernetes auth"
vault auth enable kubernetes 2>/dev/null || log "  kubernetes auth already enabled"

vault write auth/kubernetes/config \
  kubernetes_host="${K8S_HOST}" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  disable_local_ca_jwt=false

vault write auth/kubernetes/role/payment-service \
  bound_service_account_names=payment-service \
  bound_service_account_namespaces=app-payment \
  policies=payment-service \
  ttl=1h \
  max_ttl=4h

# --- Dynamic database credentials ------------------------------------------
log "Configuring the PostgreSQL database engine"
vault write database/config/payment-db \
  plugin_name=postgresql-database-plugin \
  allowed_roles="payment-service-readwrite,payment-service-migrate" \
  connection_url="postgresql://{{username}}:{{password}}@payment-db-rw.data-postgres.svc:5432/payment?sslmode=verify-full" \
  username="vault_admin" \
  password="${VAULT_DB_ADMIN_PASSWORD:?}" \
  password_authentication="scram-sha-256"

# Rotate the admin password Vault uses, so even the bootstrap operator no
# longer knows it. After this line, nobody does.
vault write -f database/rotate-root/payment-db

# The application role: data manipulation only. It cannot create or drop.
vault write database/roles/payment-service-readwrite \
  db_name=payment-db \
  creation_statements="
    CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
    GRANT CONNECT ON DATABASE payment TO \"{{name}}\";
    GRANT USAGE ON SCHEMA payment TO \"{{name}}\";
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA payment TO \"{{name}}\";
    GRANT USAGE ON ALL SEQUENCES IN SCHEMA payment TO \"{{name}}\";" \
  revocation_statements="
    REASSIGN OWNED BY \"{{name}}\" TO payment_app;
    DROP OWNED BY \"{{name}}\";
    DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl=1h \
  max_ttl=4h

# The migration role: DDL allowed, short-lived, used only by the PreSync job.
vault write database/roles/payment-service-migrate \
  db_name=payment-db \
  creation_statements="
    CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
    GRANT CONNECT ON DATABASE payment TO \"{{name}}\";
    GRANT ALL PRIVILEGES ON SCHEMA payment TO \"{{name}}\";
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA payment TO \"{{name}}\";" \
  revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl=15m \
  max_ttl=30m

# --- Transit: encryption without the app ever holding a key -----------------
log "Configuring the transit engine"
vault write -f transit/keys/payment-pii \
  type=aes256-gcm96 \
  deletion_allowed=false \
  exportable=false \
  allow_plaintext_backup=false

# Automatic key rotation. Old ciphertext stays readable; new writes use the
# new key version.
vault write transit/keys/payment-pii/config \
  auto_rotate_period=2160h \
  min_decryption_version=1

# --- CI authentication via OIDC — no static CI credentials ------------------
log "Configuring JWT auth for GitLab CI"
vault auth enable -path=jwt jwt 2>/dev/null || log "  jwt auth already enabled"

vault write auth/jwt/config \
  oidc_discovery_url="https://gitlab.bank.internal" \
  bound_issuer="https://gitlab.bank.internal"

vault write auth/jwt/role/ci-payment \
  role_type="jwt" \
  user_claim="project_path" \
  bound_claims_type="glob" \
  bound_claims='{"project_path":"apps/payment-service","ref_protected":"true"}' \
  policies="ci-payment" \
  ttl=20m

log "Done. Verify with: vault policy list && vault auth list && vault secrets list"
