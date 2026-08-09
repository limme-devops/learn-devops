# Author: Mengty LIM
# Vault policy for the payment-service workload.
#
# Applied by CI (security/vault/setup.sh), never by hand in the UI. The policy
# file in Git is the authoritative record of what this service may access.

# --- Dynamic database credentials -------------------------------------------
# Vault mints a fresh PostgreSQL user per request with a 1-hour lease and
# revokes it automatically. There is no long-lived database password anywhere.
path "database/creds/payment-service-readwrite" {
  capabilities = ["read"]
}

# The migration job uses a separate role that MAY perform DDL. The application
# role cannot alter the schema — that limits what a compromised pod can do.
path "database/creds/payment-service-migrate" {
  capabilities = ["read"]
}

# --- Static configuration secrets -------------------------------------------
path "kv/data/payments/payment-service" {
  capabilities = ["read"]
}

path "kv/metadata/payments/payment-service" {
  capabilities = ["read", "list"]
}

# Explicitly deny the rest of the KV tree. Without this, a future wildcard
# grant elsewhere could silently widen this service's reach.
path "kv/data/*" {
  capabilities = ["deny"]
}

# --- Encryption as a service ------------------------------------------------
# The application encrypts PAN and PII by calling Vault Transit. It never holds
# key material, so a memory dump of the pod yields no decryption capability.
path "transit/encrypt/payment-pii" {
  capabilities = ["update"]
}

path "transit/decrypt/payment-pii" {
  capabilities = ["update"]
}

# Rewrap after key rotation — but NOT key export or deletion.
path "transit/rewrap/payment-pii" {
  capabilities = ["update"]
}

path "transit/keys/payment-pii" {
  capabilities = ["deny"]
}

# --- Service-to-service TLS -------------------------------------------------
path "pki_int/issue/payment-service" {
  capabilities = ["update"]
}

# --- Token self-management --------------------------------------------------
path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

# --- Explicit denies --------------------------------------------------------
# Defence in depth: even if a broader policy is attached by mistake, these
# cannot be overridden — an explicit deny always wins in Vault.
path "sys/*" {
  capabilities = ["deny"]
}

path "auth/*" {
  capabilities = ["deny"]
}

path "identity/*" {
  capabilities = ["deny"]
}
