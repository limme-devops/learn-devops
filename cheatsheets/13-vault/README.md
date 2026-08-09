# HashiCorp Vault Cheat Sheet

> **Author:** Mengty LIM

Seal/unseal, auth methods, engines, dynamic credentials, PKI, Transit, policies,
Kubernetes and CI integration, HA and disaster recovery.

---

## 1. Mental model

Vault is an **identity broker with a cryptographic barrier**, not a password
database. Everything is a path in a virtual filesystem, every request is
`method + path` checked against a policy, and every response can be
**leased** — issued now, revoked later, gone by design.

Four things to hold:

1. **Sealed vs unsealed.** On start, Vault holds only ciphertext. The *master
   key* decrypts the keyring; the master key itself is protected by unseal keys
   (Shamir shares) or a cloud KMS/HSM (auto-unseal). A sealed Vault answers
   nothing but `/sys/seal-status`.
2. **Authenticate to get a token.** Every auth method (Kubernetes, AppRole,
   OIDC, JWT, cert, AWS) is just a way of trading a platform-native identity for
   a Vault token with policies attached. The token is the only thing Vault
   actually authorizes on.
3. **Static vs dynamic secrets.** KV stores what you put in it. The Database,
   PKI, AWS, and SSH engines **generate** a credential per request, with a lease.
   Dynamic is the point of Vault; if you're only using KV you've bought an
   expensive encrypted key-value store.
4. **Leases and renewal.** A lease is a promise to revoke. Anything with a lease
   can be revoked instantly — per-secret, per-token, or by prefix during an
   incident. That's the property that makes breach response tractable.

Platform rule from this repo: **a human never sees a production credential.**

---

## 2. Commands

```bash
export VAULT_ADDR=https://vault.vault.svc:8200
export VAULT_CACERT=/etc/vault/ca.crt
# never export VAULT_TOKEN in a shared shell; use `vault login` (writes ~/.vault-token)

# status / seal
vault status
vault operator init -key-shares=5 -key-threshold=3     # ONCE, as a ceremony
vault operator unseal                                  # ×3 (skip if auto-unseal)
vault operator seal                                    # emergency stop
vault operator step-down                               # force leader re-election

# auth
vault login -method=oidc                               # humans, via Keycloak
vault login -method=userpass username=me
vault token lookup                                     # who am I, what policies, TTL
vault token renew          / vault token revoke -self
vault token create -policy=payment-ro -ttl=30m -use-limit=3
vault auth list            / vault auth enable kubernetes

# kv v2  (note the `kv` command hides the data/ and metadata/ path prefixes)
vault kv put    kv/payment/config db_host=pg.internal
vault kv patch  kv/payment/config log_level=debug      # partial update, no clobber
vault kv get    -field=db_host kv/payment/config
vault kv get    -version=3 kv/payment/config
vault kv rollback -version=3 kv/payment/config
vault kv metadata get kv/payment/config
vault kv delete kv/payment/config                      # soft
vault kv undelete -versions=4 kv/payment/config
vault kv destroy  -versions=4 kv/payment/config        # permanent
vault kv metadata delete kv/payment/config             # nukes all versions

# dynamic secrets + leases
vault read database/creds/payment-app                  # returns user/pass + lease_id
vault lease renew  <lease_id>
vault lease revoke <lease_id>
vault lease revoke -prefix database/creds/payment-app  # incident: kill them all
vault list sys/leases/lookup/database/creds/payment-app

# policies / engines
vault policy list / read payment-ro
vault policy write payment-ro payment-ro.hcl
vault secrets list -detailed
vault secrets enable -path=kv -version=2 kv
vault secrets tune -max-lease-ttl=8760h pki_root

# debugging authorization
vault token capabilities <token> kv/data/payment/config   # → read, list …
vault read sys/internal/ui/mounts/kv/data/payment/config

# operations
vault operator raft list-peers
vault operator raft snapshot save  snap-$(date +%F).snap
vault operator raft snapshot restore snap.snap
vault audit list -detailed
vault monitor -log-level=debug
```

---

## 3. Seal, unseal, and the recovery ceremony

| Mode | How it unseals | Use |
|---|---|---|
| Shamir | k-of-n unseal keys typed in by humans | Air-gapped; painful on every restart |
| Auto-unseal (KMS/HSM/Transit) | Cloud KMS or another Vault decrypts the master key | Default for anything that must restart unattended |

_(regulated)_ Even with auto-unseal you still hold **recovery keys** — they're
what `generate-root` and rekey ceremonies need. Split them across custodians in
separate physical safes, never let one person hold a threshold, and record the
ceremony.

```bash
vault operator init -key-shares=5 -key-threshold=3 \
  -pgp-keys="custodian1.asc,custodian2.asc,…"   # shares encrypted per custodian
```

Root tokens are for bootstrap and break-glass only. Revoke immediately after
setup (`vault token revoke -self`); regenerate under a documented, alerted
ceremony when genuinely needed:

```bash
vault operator generate-root -init -otp=<otp>   # then k unseal-key holders each run:
vault operator generate-root -nonce=<nonce>
vault operator generate-root -decode=<encoded> -otp=<otp>
```

Rekey (change the shares) and rotate (change the encryption key) are different
operations — `vault operator rekey` vs `vault operator rotate`. Both are
routine; neither re-encrypts your data, they roll the key hierarchy.

---

## 4. Auth methods — mapping platform identity to Vault identity

| Consumer | Method | Why |
|---|---|---|
| K8s workload | `kubernetes` (ServiceAccount TokenReview) | The pod's SA *is* the identity; nothing to distribute |
| VM app | `approle` (or TLS `cert`) via vault-agent | RoleID in config, SecretID delivered response-wrapped |
| GitLab CI | `jwt` / OIDC on `CI_JOB_JWT` | Bound to project + ref + protected branch; no stored creds |
| Terraform | `jwt`/OIDC or the Vault provider with a short TTL | ≤ 1h |
| Humans | `oidc` via Keycloak, MFA, JIT | ≤ 8h, audited, group → policy mapping |

```bash
# Kubernetes auth
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc"      # short-lived JWT flow (1.21+)

vault write auth/kubernetes/role/payment \
  bound_service_account_names=payment \
  bound_service_account_namespaces=app-payment \
  policies=payment-ro \
  ttl=1h  max_ttl=4h

# GitLab CI (JWT) — bind tightly or any project can assume the role
vault write auth/jwt/role/gitlab-payment \
  role_type=jwt user_claim=user_email bound_audiences=vault \
  bound_claims_type=glob \
  bound_claims='{"project_path":"platform/payment-service","ref":"main","ref_protected":"true"}' \
  policies=payment-ci ttl=15m

# AppRole for VMs — SecretID is response-wrapped so it is single-use in transit
vault write auth/approle/role/vm-app token_policies=vm-app \
  secret_id_ttl=10m token_ttl=1h token_max_ttl=4h secret_id_num_uses=1
vault write -wrap-ttl=60s -f auth/approle/role/vm-app/secret-id
```

**The AppRole trap** is the classic interview question: whoever delivers the
SecretID could use it. Response-wrapping fixes it — the delivery agent gets a
single-use wrapping token, and if it was intercepted the unwrap fails loudly and
you know you were compromised. That's *tamper evidence*, not prevention.

---

## 5. Secrets engines

```bash
# KV v2 — static config only
vault secrets enable -path=kv -version=2 kv

# Database — dynamic Postgres creds, per-request user, auto-revoked
vault secrets enable database
vault write database/config/payment-pg \
  plugin_name=postgresql-database-plugin \
  allowed_roles="payment-app,payment-ro" \
  connection_url="postgresql://{{username}}:{{password}}@pg.internal:5432/payment?sslmode=verify-full" \
  username="vault-admin" password="…"
vault write database/roles/payment-app \
  db_name=payment-pg default_ttl=1h max_ttl=24h \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
                       GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"
vault write -f database/rotate-root/payment-pg   # ← do this immediately after config

# PKI — internal CA, short-lived service certs
vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=43800h pki_int
vault write pki_int/roles/internal \
  allowed_domains="svc.cluster.local,internal" allow_subdomains=true \
  max_ttl=72h  key_type=rsa key_bits=2048
vault write pki_int/issue/internal common_name="payment.app-payment.svc.cluster.local" ttl=24h

# Transit — encryption as a service; the app never holds key material
vault secrets enable transit
vault write -f transit/keys/pan  type=aes256-gcm96
vault write transit/encrypt/pan plaintext=$(base64 <<< "4111111111111111")
vault write transit/decrypt/pan ciphertext="vault:v1:…"
vault write -f transit/keys/pan/rotate       # new version; old ciphertext still decrypts
vault write transit/rewrap/pan ciphertext="vault:v1:…"   # upgrade ciphertext, no plaintext exposure

# SSH — signed certs for break-glass, no static keys on hosts
vault secrets enable -path=ssh-client-signer ssh
vault write ssh-client-signer/sign/ops public_key=@~/.ssh/id_ed25519.pub valid_principals=ops ttl=15m
```

Two things that get missed: **`rotate-root`** after configuring the database
engine (otherwise the bootstrap password you typed is still valid and still in
your shell history), and **Transit rewrap** — rotating a key doesn't re-encrypt
existing data, you rewrap it, and rewrap never exposes plaintext to the caller.

---

## 6. Policies

Deny by default. A token with no policy can do nothing; `default` grants only
self-management.

```hcl
# payment-ro.hcl
path "kv/data/payment/*" {                 # note: data/ for kv-v2 reads
  capabilities = ["read"]
}
path "kv/metadata/payment/*" {             # needed to list/see versions
  capabilities = ["list", "read"]
}
path "database/creds/payment-app" {
  capabilities = ["read"]
}
path "kv/data/payment/rotation-owner" {
  capabilities = ["read"]
  required_parameters = []
}

# templated policy — one policy, per-entity scoping
path "kv/data/teams/{{identity.entity.metadata.team}}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# deny wins over any allow, at any specificity
path "kv/data/payment/prod/root-keys" { capabilities = ["deny"] }
```

Capabilities: `create` (PUT new), `update` (POST/PUT existing — **this is what
"write" means**), `read`, `delete`, `list`, `patch`, `sudo` (root-protected
paths), `deny`.

Gotchas that cost people an hour:
- **KV v2 paths are `kv/data/…` in policy** but `kv/…` on the CLI. Deleting
  versions needs `kv/delete/…`, `kv/destroy/…`, `kv/metadata/…`.
- `list` is separate from `read` — you can read a secret you can't enumerate,
  which is a feature (path names leak information).
- `+` matches one segment, `*` only at the end of a path.
- Policies are **deny-by-default and deny-overrides**; there is no allow that
  beats an explicit deny.

_(regulated)_ Policies live in `security-policies/vault/` and are applied by CI.
Nobody writes a policy in the UI — an unreviewed policy change is a privilege
escalation with no paper trail.

---

## 7. Kubernetes integration — three patterns

| Pattern | Secret lands as | Use when |
|---|---|---|
| **Vault Agent Injector** (sidecar/init, annotations) | A file in the pod, renewed in place | Dynamic creds; you don't want a K8s Secret to exist |
| **External Secrets Operator (ESO)** | A real `Secret` object | The app can only read env vars; you accept a synced copy |
| **Vault CSI provider** | A mounted volume | Similar to injector, no sidecar |

```yaml
# Agent Injector — annotations only, app code unchanged
annotations:
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/role: "payment"
  vault.hashicorp.com/agent-inject-secret-db: "database/creds/payment-app"
  vault.hashicorp.com/agent-inject-template-db: |
    {{- with secret "database/creds/payment-app" -}}
    DB_USER={{ .Data.username }}
    DB_PASS={{ .Data.password }}
    {{- end }}
  vault.hashicorp.com/agent-inject-file-db: "db.env"
  vault.hashicorp.com/secret-volume-path: "/vault/secrets"    # tmpfs, never disk
```

The distinction that matters: **ESO copies a secret into etcd** where it lives
until something rewrites it, so it suits static config. The **injector renders a
lease into tmpfs** and renews it, so the credential expires on its own and never
becomes a Kubernetes object with its own RBAC surface. For a dynamic DB
credential, use the injector.

Either way the app needs to survive the credential changing under it — reload on
file change, or reconnect on auth failure. A pattern that only works because the
pod restarts is not a rotation strategy.

---

## 8. Vault Agent (VMs and CI)

```hcl
# /etc/vault-agent.hcl
pid_file = "/run/vault-agent.pid"

auto_auth {
  method "approle" {
    config = {
      role_id_file_path                   = "/etc/vault/role_id"
      secret_id_file_path                 = "/run/vault/secret_id"
      remove_secret_id_file_after_reading = true
    }
  }
  sink "file" { config = { path = "/run/vault/token", mode = 0640 } }
}

cache { use_auto_auth_token = true }        # local proxy: app talks to 127.0.0.1

template {
  source      = "/etc/vault/db.env.tpl"
  destination = "/run/app/db.env"           # tmpfs
  perms       = "0600"
  command     = "systemctl reload app"      # or a SIGHUP the app handles
}
```

Agent does the boring, error-prone parts: authenticate, renew before expiry,
re-authenticate when renewal fails, render templates, and restart/reload the
consumer. Writing that loop into your app is how you end up with an outage at
the max_ttl boundary three months later.

---

## 9. HA, backup, disaster recovery

- **Raft (integrated storage)**, 3 or 5 nodes across failure domains. One
  active node writes; standbys forward. `vault operator raft list-peers`.
- **Auto-unseal** via cloud KMS/HSM so a node reboot doesn't need a human.
- **Snapshots**: `vault operator raft snapshot save` hourly → object storage with
  object-lock, encrypted with a key *not* held by Vault. A snapshot restores only
  onto a cluster with the same unseal/KMS key — losing the KMS key loses the data,
  so key backup is part of the DR plan, not an afterthought.
- **Test the restore.** _(regulated)_ An untested snapshot is a hope.
- **Audit devices**: file *and* syslog → SIEM. Vault **fails closed if it cannot
  write an audit log** — that is deliberate, and it means a full audit disk takes
  Vault down. Monitor free space and enable two devices so one failing doesn't
  stop the world.
- **Enterprise-only** (know the names, know you don't have them in OSS):
  Performance Replication, DR Replication, Namespaces, HSM auto-unseal, control
  groups, Sentinel policies.

Metrics worth alerting on: `vault.core.unsealed` (0 = sealed), seal status per
node, `vault.token.count.by_ttl`, `vault.expire.num_leases` (lease explosion),
`vault.core.handle_request` latency, audit device failures, and time until
`pki` CA expiry.

---

## 10. Gotchas

| Symptom | Cause / fix |
|---|---|
| `permission denied` on a KV path that looks allowed | KV v2 policy needs `kv/data/…`, not `kv/…` |
| Can read a secret but `vault kv list` fails | `list` capability is separate; add it on `kv/metadata/…` |
| Everything works, then breaks after 32 days | Hit `max_ttl` — renewal extends within max_ttl, it doesn't reset it. Re-authenticate |
| Vault sealed after a reboot | No auto-unseal configured |
| Vault returning 500s, no obvious cause | Audit device can't write (disk full) → fail-closed by design |
| Lease count climbing into millions | Something reads a dynamic secret per request instead of caching; use Agent caching, shorten TTLs, `lease revoke -prefix` |
| Dynamic Postgres creds exhaust connections | Every pod gets its own user; tune the pool and DB `max_connections`, or lengthen TTL |
| K8s auth fails with `service account name not authorized` | `bound_service_account_names`/`namespaces` mismatch, or the SA token audience |
| Performance standby returns stale reads | Read-after-write across nodes; use the active node or handle `X-Vault-Index` |
| Root token in a script | Never. Use a scoped auth method; root is break-glass only |
| Secret in `terraform.tfstate` after using the Vault provider | Inevitable — treat state as a secret, prefer Agent/injector over Terraform for app secrets |

---

## 11. Best practices checklist

- [ ] HA Raft, 3+ nodes across failure domains, auto-unseal via KMS/HSM
- [ ] Recovery/unseal shares split across custodians, PGP-encrypted, in separate safes _(regulated)_
- [ ] Root token revoked after bootstrap; `generate-root` is a documented, alerted ceremony
- [ ] Audit devices to file **and** syslog → SIEM; disk-space alerting because Vault fails closed
- [ ] Policies as code in Git, applied by CI, reviewed — never authored in the UI
- [ ] Deny-by-default; least privilege per app; templated policies over one policy per team
- [ ] Platform-native auth everywhere (K8s SA, OIDC/JWT, AppRole with response-wrapped SecretIDs)
- [ ] `database/rotate-root` run right after configuring each database connection
- [ ] Dynamic credentials for databases and cloud; KV v2 only for genuinely static config
- [ ] TTLs short (≤1h app, ≤8h human) and the app can survive a credential changing under it
- [ ] Secrets rendered to **tmpfs**, `0600`, never to `/etc` or a container layer
- [ ] PKI issuing short-lived certs (≤72h) with automated renewal; CA expiry alerted well ahead
- [ ] Transit for field-level PII/PAN — apps never hold key material; rewrap after rotation
- [ ] Hourly Raft snapshots to object-locked storage, encrypted with a key held outside Vault
- [ ] Restore tested on a schedule, KMS/unseal key backup included in the DR plan
- [ ] Break-glass path documented, time-bound, and alerted when used

➡ [Interview Q&A](interview-qna.md)
