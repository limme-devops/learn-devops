# HashiCorp Vault — Interview Q&A

> **Author:** Mengty LIM

---

## Fundamentals

**Q1. What problem does Vault actually solve that an encrypted config file doesn't?**
Three, and only the first is about encryption. It centralizes *authorization* —
who may read which secret is a policy, evaluated per request, not a filesystem
permission. It gives you an **audit trail**: every read is attributable to an
identity, which is the difference between "we rotated everything" and "we know
exactly which three credentials that pod could have seen". And it issues
**dynamic, leased** credentials, so a secret can be revoked rather than merely
changed. An encrypted file gives you none of that: everyone who can decrypt it
holds everything in it, forever, and you can't tell who read what.

**Q2. Explain seal/unseal.**
Vault's data is encrypted with an encryption key that lives in the keyring; the
keyring is encrypted by the master key; the master key is protected either by
Shamir shares (k-of-n humans) or by a cloud KMS/HSM. When Vault starts it's
sealed — it holds ciphertext and answers nothing but seal status. Unsealing
reconstructs the master key in memory. In practice you use **auto-unseal** for
anything that must restart unattended, but you still hold recovery keys, because
`generate-root` and rekey ceremonies need them. Sealing is also an incident
control: `vault operator seal` stops all access instantly if you think the host
is compromised.

**Q3. Static vs dynamic secrets — why does it matter so much?**
A static secret is a shared long-lived string: you can rotate it, but rotation
is a coordinated outage-shaped event, and until you do, every past reader still
holds it. A dynamic secret is generated per request with a lease — Vault creates
a real Postgres user for that pod, and revokes it when the lease expires. Two
consequences. Breach response becomes `vault lease revoke -prefix`, seconds not
days. And the blast radius of a leaked credential is bounded by the TTL you
already chose, so you're not relying on detection speed. If a team is only using
KV, they've bought an expensive encrypted key-value store.

**Q4. Walk me through what happens when a pod reads a database credential.**
The pod's ServiceAccount token is presented to Vault's Kubernetes auth method;
Vault calls the cluster's TokenReview API to verify it, checks the SA name and
namespace against the role's `bound_service_account_names`/`_namespaces`, and
issues a Vault token carrying that role's policies with a 1h TTL. The pod then
reads `database/creds/payment-app`; the policy allows it, so Vault connects to
Postgres as its own admin user, runs the role's `creation_statements` to make a
unique user with a `VALID UNTIL`, and returns username/password plus a
`lease_id`. Vault Agent renews the lease in the background; at max_ttl it
re-authenticates. On revoke or expiry, Vault drops the Postgres user. Nothing
was ever stored anywhere.

---

## Design and integration

**Q5. Vault Agent Injector vs External Secrets Operator — which and why?**
ESO syncs Vault into a real Kubernetes `Secret`, which means the value lands in
etcd and lives there until something rewrites it, protected only by K8s RBAC.
The injector renders the secret into a tmpfs file in the pod and renews the
lease in place, so it never becomes a Kubernetes object at all. So: ESO for
static config where the app can only read env vars and you accept a synced copy;
the injector for anything dynamic or high-value, which in our platform is
database credentials. Either way the real requirement is that the **app can
survive the credential changing underneath it** — reload on file change or
reconnect on auth failure. If the only thing that picks up a new credential is a
pod restart, you don't have rotation, you have scheduled downtime.

**Q6. How do you authenticate CI to Vault without storing a credential in CI?**
JWT/OIDC. GitLab mints a signed token per job describing the project, ref, and
whether the branch is protected; Vault's `jwt` auth verifies the signature
against GitLab's JWKS and matches `bound_claims`. The critical part is binding
tightly — project path *and* ref *and* `ref_protected=true` — because a role
bound only to "some project in this GitLab" is a role any project can assume by
opening a branch. Token TTL is the job duration. No secret is stored anywhere,
so there is nothing to rotate and nothing to leak in a CI variable dump.

**Q7. What's the AppRole secret-zero problem and how do you handle it?**
AppRole needs a RoleID (non-secret, in config) and a SecretID (secret) — so you
still have to deliver one credential to bootstrap the rest. You can't eliminate
it, you make it tamper-evident: Vault issues the SecretID **response-wrapped**,
so the delivery mechanism gets a single-use wrapping token and never sees the
value. If someone intercepts and unwraps it, the legitimate unwrap fails loudly
and you know within seconds that you were compromised. Add a short
`secret_id_ttl` and `secret_id_num_uses=1`. On platforms with native identity —
Kubernetes, cloud instance metadata, TLS certs — prefer those and skip the
problem entirely; AppRole is for the places that have no such identity.

**Q8. How do you structure paths and policies for 40 teams?**
Paths mirror ownership: `kv/data/<team>/<app>/<env>/…`. Policies are **templated
on identity metadata** — one policy with
`kv/data/teams/{{identity.entity.metadata.team}}/*` — rather than 40 near-identical
files that drift. Auth is via OIDC groups from Keycloak mapped to Vault identity
groups, so offboarding happens once in the IdP. Everything is deny-by-default,
policies are committed and applied by CI, and no one authors policy in the UI —
an unreviewed policy change is a privilege escalation with no paper trail. On
Enterprise you'd use Namespaces for hard multi-tenancy; on OSS the boundary is
path prefixes plus discipline, and it's worth saying that out loud.

---

## Operations

**Q9. Vault is returning 500s and nothing changed. Where do you look first?**
Audit device. Vault **fails closed if it cannot write an audit log** — that's
deliberate, since an unauditable secret access is worse than an unavailable one
— so a full disk on the audit PV takes the whole cluster down. Check
`vault audit list`, check disk. After that: seal status per node (an auto-unseal
KMS outage seals nodes on restart), Raft peer health and leader election, and
whether something has exploded the lease count. The mitigation for the audit
case is two audit devices, so one failing doesn't stop the world, plus free-space
alerting well before the cliff.

**Q10. Someone leaked a token / we think a namespace is compromised. What do you do?**
Bound the damage first: revoke by prefix rather than hunting individual secrets —
`vault lease revoke -prefix database/creds/payment-app` kills every dynamic
credential that role ever issued, and `vault token revoke -mode=path auth/kubernetes/`
drops the tokens. If it's broad, `vault operator seal` stops everything while
you assess; that's an outage, but it's an outage you chose. Then use the audit
log to enumerate exactly what that identity read — this is where Vault pays for
itself, because the answer is a list, not a guess. Rotate anything static it
touched (dynamic secrets self-heal), and rotate the auth method's trust material
if the identity itself was forged.

**Q11. How do you back up and restore Vault?**
Hourly `vault operator raft snapshot save` to object storage with object-lock,
encrypted with a key that is **not** held by Vault. The subtlety people miss:
a snapshot can only be restored onto a cluster that can decrypt the master key,
so with auto-unseal your KMS key is part of the backup — lose it and the
snapshot is ciphertext forever. So the DR plan covers the KMS key material and
the recovery shares, not just the snapshot. And we test the restore on a
schedule into an isolated cluster _(regulated)_ — an untested snapshot is a hope,
and Vault is the one system where a failed restore means every other system
stays down too.

**Q12. Vault is a single point of failure for everything. How do you live with that?**
Accept it and design around it. HA Raft across failure domains with auto-unseal
so recovery doesn't need a human at 3am. Vault Agent's **local cache** means
running apps keep their current credential through a short Vault outage — the
failure mode is "no new leases and no renewals", which is survivable for the
length of a TTL, and that is a real argument for TTLs of an hour rather than five
minutes. Vault is tier-0 in the dependency graph, so it starts first (Vault →
Postgres → Keycloak → everything) and has its own runbook. What you don't do is
add a fallback path to static secrets "in case Vault is down" — that's an
always-on bypass of the control you just built.

**Q13. TTL vs max_ttl — explain the outage that happens on day 32.**
Renewal extends a lease within `max_ttl`; it doesn't reset it. So a token with
`ttl=1h, max_ttl=768h` renews happily for a month and then simply cannot be
renewed again — and an app that only implements renewal, not
re-authentication, dies at that boundary, weeks after anyone touched it. Vault
Agent handles both, which is the main reason to use it rather than writing the
loop yourself. It's also why the max_ttl boundary belongs in your load-testing
and chaos plan, since nothing in a normal test window will ever reach it.

---

## Rapid fire

- **Why `kv/data/...` in policies?** KV v2 mounts a versioned API under `data/`, `metadata/`, `delete/`, `destroy/`. The CLI hides it; policies don't.
- **`delete` vs `destroy` vs `metadata delete`?** Soft delete (undeletable), permanent removal of a version, removal of the secret and all versions.
- **`create` vs `update`?** `create` is a new path, `update` is an existing one — "write" needs both if the path may not exist.
- **Deny vs allow precedence?** Explicit `deny` always wins, at any specificity.
- **Response wrapping?** Vault returns a single-use token instead of the value; unwrapping is one-time, so interception is detectable.
- **Transit rotate vs rewrap?** Rotate creates a new key version for new writes; rewrap upgrades existing ciphertext without exposing plaintext.
- **`rotate-root`?** Rotates the admin password Vault uses for a database connection — run it right after configuring, or your bootstrap password is still live.
- **Enterprise-only features?** Namespaces, DR/performance replication, Sentinel policies, control groups, HSM auto-unseal. Know the names; don't design an OSS deployment that assumes them.
- **Vault vs cloud KMS/Secrets Manager?** Cloud-native is simpler and managed; Vault wins on multi-cloud/on-prem uniformity, dynamic credentials for arbitrary backends, PKI, and Transit. In a regulated on-prem estate that's usually decisive.
- **Vault vs Ansible Vault?** Unrelated products with a shared name. Ansible Vault is symmetric file encryption — everyone with the passphrase holds everything and rotation means re-encrypting every file. It's a floor for bootstrap material, not a secrets strategy.
