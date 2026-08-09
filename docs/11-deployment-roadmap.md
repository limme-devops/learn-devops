# Deployment Roadmap — Step by Step

> **Author:** Mengty LIM

How to build this platform from nothing, in an order where each step is usable
on its own and nothing has to be rebuilt later.

**How to read a step.** Every step has the same shape:

- **Goal** — what is true when you finish
- **Why here** — why this step cannot move earlier or later
- **Do** — the actual work
- **Verify** — a command whose output you read, not a feeling
- **Exit criteria** — you are not done until every box is ticked
- **What bites people** — the failure this step exists to prevent

Do not start a step until the previous step's exit criteria are all ticked.
Skipping forward is how you end up retrofitting secrets management into a
running platform, which costs about four times what doing it in order costs.

---

# Part 0 — Core concepts to hold in mind before you touch anything

These are the ideas that decide whether the platform ages well. Everything in
Parts 1–8 is an application of one of them.

## 0.1 The twelve laws

| # | Law | What it means in practice | What it prevents |
|---|---|---|---|
| 1 | **Everything as code** | No change reaches any environment except through a commit | "It works but nobody knows why" |
| 2 | **Build once, promote the digest** | The bytes tested in UAT are the bytes running in prod | A prod-only bug that no environment could reproduce |
| 3 | **Immutable over mutable** | Replace servers and images; don't patch them in place | Configuration drift, snowflake servers |
| 4 | **Default deny** | Network, RBAC, egress, firewall, admission all start closed | Lateral movement after one compromise |
| 5 | **Zero standing privilege** | Credentials are minted per-request and expire | A stolen credential that stays useful for years |
| 6 | **Pull, don't push** | The cluster reconciles from Git; CI never holds prod creds | CI compromise becoming prod compromise |
| 7 | **Separate identity from authorisation** | Who you are (Keycloak) ≠ what you may do (RBAC/Vault policy) | Permission sprawl nobody can audit |
| 8 | **Recoverability beats uptime** | An unrestorable system is not in production | The backup that had never been tested |
| 9 | **Observability is a feature** | Ship probes, metrics, traces and a runbook with the code | A 3am page with no way to diagnose it |
| 10 | **Deploy ≠ release** | Ship dark behind a flag; release progressively | A bad release requiring a redeploy to fix |
| 11 | **Automate the boring, gate the dangerous** | Humans approve; machines execute | Fat-finger errors and 2am typos |
| 12 | **Every control produces evidence** | If an auditor can't see it, it doesn't count | Six weeks of manual evidence-gathering before an audit |

## 0.2 The four questions to answer before writing any YAML

Ask these in the kickoff, and write the answers down. Every technical decision
that follows is downstream of them.

| Question | Who answers it | Why it decides everything |
|---|---|---|
| **How much downtime is acceptable?** (RTO) | The business, not IT | Decides single vs multi-node, warm vs cold DR, and roughly half your budget |
| **How much data may we lose?** (RPO) | The business | Decides sync vs async replication, backup frequency, WAL archiving |
| **What is the data classification?** | Compliance/Legal | Decides encryption, retention, which region, who may see logs |
| **Who gets paged, and when?** | Operations | Decides alert routing, severity levels, and whether you need 24/7 coverage |

If you cannot get these answered, write down your assumption, state it in
writing, and proceed. An assumption on record is a decision; an assumption in
your head is a future argument.

## 0.3 The dependency order that cannot be reordered

```
Identity and secrets must exist before workloads.
Workloads must be observable before they are exposed.
Anything stateful must be restorable before it holds real data.
```

Concretely: **Vault → PKI → PostgreSQL → Keycloak → observability → apps.**
Every team that builds apps first and retrofits secrets ends up rewriting every
deployment manifest they wrote.

## 0.4 The three things that always take longer than estimated

1. **Networking and firewall approvals.** In a bank this is weeks, not days, and
   it is rarely on the critical path in anyone's plan. Raise firewall requests
   in week 1 for things you need in week 8.
2. **Certificate and PKI trust chains.** The chicken-and-egg of "Vault issues
   certs but Vault needs a cert" surprises everyone once.
3. **Getting real data into a lower environment legally.** Masking pipelines are
   a project, not a task. Start the conversation with Compliance early.

## 0.5 What "done" means for any component

A component is not done when it runs. It is done when:

- [ ] It is defined in code and deploys from a clean checkout
- [ ] It has health checks that report reality (readiness fails when a dependency is down)
- [ ] It has metrics, logs and traces landing in the platform
- [ ] It has at least one alert with a runbook attached
- [ ] It has a backup, and a restore that has been performed and timed
- [ ] It survives losing one node, tested
- [ ] Someone other than the author has deployed it from scratch using only the docs

That last one is the real test. If only the author can deploy it, you have built
a dependency on a person, not a platform.

---

# Part 1 — Foundations (weeks 1–2)

## Step 1 — Establish the repository and the gates

**Goal** — a repo where a secret cannot be committed and badly-formatted
infrastructure cannot be merged.

**Why here** — every later step commits code. Adding gates afterwards means
scanning history for secrets that are already in it, which is expensive and
never fully successful.

**Do**
```bash
git init && git branch -M main
# Copy the scaffold: .gitignore .gitleaks.toml .pre-commit-config.yaml Makefile
pip install pre-commit
pre-commit install
pre-commit run --all-files
```
Configure in the SCM: protected `main`, no force-push, signed commits required,
CODEOWNERS routing `/infra/terraform/environments/prod/` to platform + security.

**Verify**
```bash
echo 'aws_secret_access_key = "AKIAIOSFODNN7EXAMPLE"' > /tmp/leak.tf
cp /tmp/leak.tf ./leak.tf && git add leak.tf && git commit -m "test"
# MUST be rejected by gitleaks. If it commits, your gate is decoration.
rm leak.tf
```

**Exit criteria**
- [ ] A deliberate fake secret is blocked at commit time
- [ ] `main` cannot be pushed to directly, by anyone, including you
- [ ] CODEOWNERS requires two approvers for prod paths
- [ ] `make lint` runs clean on an empty repo

**What bites people** — installing pre-commit but never testing that it blocks
anything. A gate you have not tried to defeat is not a gate.

---

## Step 2 — Terraform state backend and the bootstrap chicken-and-egg

**Goal** — encrypted, locked, versioned remote state, created by code.

**Why here** — local state in a team is a corruption incident waiting to happen,
and migrating state later is a manual, risky operation.

**Do** — create `infra/terraform/global/bootstrap/` which provisions the state
bucket and lock table using *local* state, then migrates itself to remote. This
runs exactly once, ever, and its local state file is committed as a sealed
artifact or stored in the password manager.

Then per environment, per layer:
```
prod/network/terraform.tfstate
prod/platform/terraform.tfstate
prod/data/terraform.tfstate
```

**Verify**
```bash
cd infra/terraform/environments/dev && terraform init && terraform plan
# In a second terminal, run plan again simultaneously.
# The second MUST block on the state lock. If both proceed, locking is off.
```

**Exit criteria**
- [ ] State is encrypted at rest with a KMS key you control
- [ ] Bucket versioning is on (state corruption is recoverable)
- [ ] Concurrent runs block on the lock, demonstrated
- [ ] Separate state per environment **and** per layer
- [ ] No engineer has write credentials to prod state on their laptop

**What bites people** — one giant state file for everything. Then a typo in a
network module produces a plan that wants to destroy the database, and you find
out how good your review process really is.

---

## Step 3 — The golden image pipeline

**Goal** — a hardened OS image, rebuilt weekly, that every VM and Kubernetes
node is cloned from.

**Why here** — everything downstream inherits this image. Hardening the image
once is cheaper than hardening 200 running servers, and it makes "rebuild rather
than patch" possible.

**Do** — Packer builds RHEL/Rocky 9 with: CIS Level 2 profile, `auditd`, AIDE,
SSSD, monitoring agents, and the internal CA trust bundle. The pipeline runs
`oscap` and fails the build below the compliance floor.

**Verify**
```bash
# The scan runs in the build. Read the number, don't trust the green tick.
oscap xccdf eval --profile cis --results results.xml ssg-rhel9-ds.xml
# Then boot the image and confirm it is not trivially accessible:
ssh root@<new-vm>          # MUST fail
ssh -o PubkeyAuthentication=no user@<new-vm>   # MUST fail (no passwords)
```

**Exit criteria**
- [ ] CIS pass rate ≥ agreed floor, recorded as a build artifact
- [ ] Image rebuilds weekly on a schedule, unattended
- [ ] Image version is a date-stamped, immutable name
- [ ] Root login and password auth are both impossible
- [ ] The previous two image versions are retained for rollback

**What bites people** — building the image once by hand "to get started". Six
months later it is 200 CVEs behind and nobody remembers how it was made.

---

# Part 2 — Identity and secrets (weeks 3–5)

## Step 4 — Vault, properly

**Goal** — an HA Vault that is the only place a credential exists.

**Why here** — this is the step teams most often defer, and deferring it is the
single most expensive mistake in this roadmap. Every manifest, playbook and
pipeline written before Vault exists will contain a secret that must later be
found and removed.

**Do** — 3-node Raft cluster, auto-unseal via HSM/KMS, audit devices to file and
syslog, TLS from a bootstrap CA. Then enable engines in this order: KV v2 →
PKI → Database → Transit. Apply policies from
`security/vault/policies/*.hcl` via `security/vault/setup.sh`.

Run the unseal ceremony with real custodians and document it. If you use Shamir,
five shares, threshold three, custodians in separate physical safes, witnessed.

**Verify**
```bash
vault status                       # Sealed: false, HA Mode: active
vault operator raft list-peers     # 3 peers, one leader

# The critical test: does it fail CLOSED when audit breaks?
# Make the audit path unwritable, then attempt a read.
# Vault MUST refuse the request. If it serves it, you have no audit trail.

# Prove dynamic credentials actually rotate:
vault read database/creds/payment-service-readwrite   # note the username
vault read database/creds/payment-service-readwrite   # MUST be a different user
```

**Exit criteria**
- [ ] 3 nodes, auto-unseal works after a full restart of all three
- [ ] Audit logging to two destinations, and Vault fails closed without it
- [ ] Root token revoked after setup; break-glass procedure documented and rehearsed
- [ ] Dynamic DB credentials issue and auto-revoke, demonstrated
- [ ] Raft snapshots run hourly to object storage
- [ ] **A snapshot has been restored to a scratch Vault successfully**

**What bites people** — the unseal keys. Teams generate them, screenshot them
into a chat, and discover during a real outage that the custodians left the
company. Do the ceremony properly, once.

---

## Step 5 — Internal PKI, then re-issue everything

**Goal** — short-lived certificates issued automatically, with no manual
renewals in a calendar anywhere.

**Why here** — every service after this point needs TLS. Setting up PKI now
means they all get certs the same way.

**Do** — Vault PKI: offline root CA, online intermediate with a bounded max TTL.
Roles per service with tight `allowed_domains`. Then go back and re-issue the
bootstrap certificates from Step 4 so nothing is running on a self-signed cert.

**Verify**
```bash
vault write pki_int/issue/payment-service common_name=payments.bank.internal ttl=24h
openssl x509 -in cert.pem -noout -dates    # confirm the short TTL
# Confirm renewal is automatic: wait past one renewal cycle and re-check
# the certificate serial. If it hasn't changed, renewal isn't running.
```

**Exit criteria**
- [ ] Root CA private key is offline (HSM or physical safe), never on a server
- [ ] Certificate TTL ≤ 90 days, ideally ≤ 24 hours for service-to-service
- [ ] Renewal is automatic and has been observed to happen
- [ ] An expiry alert fires at 14 days remaining
- [ ] The internal CA is in the trust store of the golden image

**What bites people** — a five-year certificate "to avoid the hassle". Then it
expires on a Sunday, during a freeze, and nobody left knows how it was issued.

---

## Step 6 — Keycloak and single sign-on everywhere

**Goal** — one identity, one MFA policy, one offboarding action.

**Why here** — every console you install after this (Grafana, Argo, Harbor,
GitLab) should be wired to SSO on day one. Retrofitting SSO means auditing every
local account you created in the meantime.

**Do** — Keycloak operator on its own CNPG database. Realm configuration as
code. Password policy, brute-force detection, MFA mandatory for admin and
privileged roles. Federate staff identities to AD; keep customer identities
local. Wire GitLab, Grafana, ArgoCD, Vault, Harbor and the Kubernetes API to it.

**Verify**
```bash
# Import the realm from Git into a scratch instance — config must be reproducible.
kubectl apply -f keycloak-realm-import.yaml

# Then the tests that matter:
#  1. Disable a test user in AD -> confirm they lose access to every console
#  2. Attempt admin login without MFA -> MUST be refused
#  3. Attempt an ROPC/direct-grant token -> MUST be refused (flow disabled)
#  4. Confirm login and admin events reach the SIEM
```

**Exit criteria**
- [ ] Realm config is in Git; a rebuilt Keycloak produces the identical realm
- [ ] MFA enforced for every privileged role
- [ ] No wildcard redirect URIs on any client
- [ ] Implicit and direct-grant flows disabled
- [ ] Disabling one directory account removes access to all platform consoles, demonstrated
- [ ] Login/admin events reach the SIEM

**What bites people** — configuring the prod realm by clicking in the admin
console. It works, then it cannot be rebuilt, and no one can explain to the
auditor how the current configuration came to be.

---

# Part 3 — The Kubernetes platform (weeks 6–10)

## Step 7 — Cluster build, hardened from the first boot

**Goal** — a cluster whose control plane is not the weakest thing in the estate.

**Do** — Terraform provisions nodes; Ansible installs RKE2 with the CIS profile.
Enable etcd encryption at rest with a KMS provider, API server audit policy at
`RequestResponse` for secrets and RBAC, anonymous auth off, control planes
tainted. Install Cilium (NetworkPolicy enforcement is not optional).

**Verify**
```bash
kube-bench run --targets master,node          # read the failures, don't skim
kubectl get --raw /api/v1/namespaces/default/secrets  # as an anonymous user: MUST 401

# Confirm etcd encryption is real, not configured-but-inactive:
kubectl create secret generic canary --from-literal=k=SENTINELVALUE
# then on a control plane node:
etcdctl get /registry/secrets/default/canary | strings | grep SENTINELVALUE
# Finding the plaintext means encryption is NOT working.
```

**Exit criteria**
- [ ] `kube-bench` failures are zero or documented as accepted exceptions with expiry
- [ ] Secrets are demonstrably encrypted in etcd (the canary test above)
- [ ] API audit logs reach the SIEM
- [ ] Anonymous access returns 401
- [ ] etcd snapshots every 30 minutes, stored off-cluster
- [ ] **An etcd snapshot has been restored to a scratch cluster**
- [ ] Losing one control-plane node does not affect the API, tested

**What bites people** — the etcd encryption canary test. Many clusters have
encryption configured in a file that was never applied to already-existing
secrets. Encryption only applies on write; you must rewrite existing secrets.

---

## Step 8 — Platform baseline: policy before workloads

**Goal** — admission control that makes an insecure workload impossible, in
place *before* the first workload arrives.

**Why here** — reversed, you spend the next year chasing pods that were created
before the policy and are now exempt "temporarily".

**Do** — install cert-manager, External Secrets Operator, ingress-nginx,
Kyverno, Falco, the monitoring stack, Velero. Apply
`security/kyverno/baseline-policies.yaml` in **Audit** mode first.

**Verify**
```bash
kubectl get policyreport -A          # look at what would break TODAY
# Fix the estate until the report is clean, THEN flip to Enforce.

# After flipping, prove enforcement with a deliberately bad pod:
kubectl run bad --image=nginx:latest --overrides='{"spec":{"containers":[{"name":"bad","image":"nginx:latest","securityContext":{"privileged":true}}]}}'
# MUST be rejected on three counts: latest tag, unsigned, privileged.
```

**Exit criteria**
- [ ] Every policy ran in Audit long enough to prove the estate is clean
- [ ] Policies are now Enforce with `failurePolicy: Fail` (fail closed)
- [ ] A deliberately non-compliant pod is rejected, demonstrated
- [ ] Default-deny NetworkPolicy is auto-generated into every new app namespace
- [ ] Falco alerts reach SecOps

**What bites people** — going straight to Enforce and breaking the platform team's
own tooling on the first day, which produces pressure to add a blanket exemption
that then never gets removed.

---

## Step 9 — GitOps: make Git the only path to the cluster

**Goal** — nobody deploys with `kubectl apply`, including you.

**Do** — ArgoCD with SSO, AppProjects as guardrails, app-of-apps from
`gitops/bootstrap/argocd/`. `selfHeal: true`, `prune: false` in prod.
Notifications on sync-failed, health-degraded and out-of-sync.

**Verify**
```bash
# The drift test — this is the one that proves GitOps is real:
kubectl scale deployment/some-app --replicas=99 -n app-payment
# Within the reconcile window, Argo MUST revert it AND fire an out-of-sync alert.
# Reverted silently = you lose the signal that someone touched prod by hand.

# The permissions test:
# As a developer account, try to sync a prod Application. MUST be denied.
```

**Exit criteria**
- [ ] Manual cluster changes are reverted **and** alerted on
- [ ] Developers can view prod but not sync it
- [ ] AppProjects restrict source repos, destinations and cluster-scoped resources
- [ ] Argo's own config is managed by Argo
- [ ] Human `kubectl` write access to prod is removed (break-glass only)

**What bites people** — leaving `kubectl edit` access in place "just for
emergencies". Emergencies become Tuesdays, and drift becomes permanent.

---

# Part 4 — Stateful services (weeks 10–14)

## Step 10 — PostgreSQL with a proven restore

**Goal** — a database that survives a node loss and can be rewound to any point
in time.

**Do** — CloudNativePG cluster, 3 instances, WAL archiving to MinIO, daily base
backups, PgBouncer pooler, pgaudit enabled, app role without DDL rights.

**Verify** — the only verification that counts:
```bash
# 1. Write a known row with a known timestamp.
# 2. Note the time. Wait five minutes. DELETE the row.
# 3. Restore to a timestamp between the insert and the delete.
# 4. Confirm the row is present in the restored cluster.
# 5. WRITE DOWN how long steps 3-4 took. That is your real RTO.
```

**Exit criteria**
- [ ] PITR to an arbitrary timestamp performed, and the measured time recorded
- [ ] Killing the primary triggers automatic failover in < 60s, tested
- [ ] The application role cannot `DROP TABLE`, tested
- [ ] Connection pooling in place; HPA scale-out does not exhaust `max_connections`
- [ ] Backup failure raises a **P1** alert (not a warning)
- [ ] TLS required; `sslmode=verify-full` on the client

**What bites people** — configuring backups and never restoring. The most common
discovery during the first real restore is that the WAL archive has a gap
nobody noticed because nothing was checking.

---

## Step 11 — Object storage as the backup substrate, made ransomware-resistant

**Goal** — a backup an attacker with full production credentials cannot delete.

**Why here** — everything backs up *to* this, so it must be trustworthy before
anything depends on it.

**Do** — MinIO distributed tenant (4×4 minimum for erasure coding). Object Lock
in compliance mode on backup buckets. Versioning on. The backup writer identity
gets `PutObject` **only** — no delete, no lifecycle, no lock-config permission.
Different credentials, different network zone, different admin group from the
production Kubernetes admins.

**Verify**
```bash
# The test that matters — try to destroy your own backups:
mc rm --force --recursive backup-alias/backups-prod/postgres/
# MUST fail. If it succeeds, ransomware can do exactly the same thing.

mc ilm rule remove --all backup-alias/backups-prod    # MUST fail
mc anonymous get backup-alias/backups-prod            # MUST fail
```

**Exit criteria**
- [ ] The backup writer credential cannot delete anything, proven by trying
- [ ] Object Lock retention ≥ your RPO window
- [ ] Versioning on for every backup bucket
- [ ] Backup storage admins are a different group from prod K8s admins
- [ ] Alerts on: backup failure, size anomaly, mass-delete API calls, retention changes
- [ ] Site replication to DR configured for critical buckets

**What bites people** — giving the backup service account `s3:*` because it was
quicker. That single line converts your ransomware defence into a ransomware
target.

---

# Part 5 — Observability (weeks 13–16)

## Step 12 — Make the platform explain itself

**Goal** — when something breaks, the answer is on a screen, not in someone's
head.

**Do** — Prometheus + Thanos, Loki, Tempo, Grafana with SSO, Alertmanager
routing. Dashboards as code. Then instrument: RED per service, USE per resource,
and the business metrics that actually matter.

**Verify**
```bash
# Trace correlation is the real test of an observability stack:
# 1. Make a request with a known X-Request-ID
# 2. Find it in Loki
# 3. Jump from that log line to the trace in Tempo
# 4. From the trace, reach the metrics for that service and time window
# If any hop is manual copy-paste, correlation is not wired up.
```

**Exit criteria**
- [ ] Every service has a RED dashboard, generated from a template
- [ ] Log → trace → metric navigation works in one click
- [ ] No PII, PAN or tokens in any log, verified by searching for them
- [ ] Metric cardinality is bounded (no user IDs or raw paths as labels)
- [ ] Retention configured per the compliance matrix, in code
- [ ] Alertmanager routes to a real on-call rotation, and a test page arrives

**What bites people** — building beautiful dashboards nobody uses at 3am. The
dashboard that matters is the one linked from the alert.

---

## Step 13 — SLOs and alerts that are worth waking someone for

**Goal** — every page is actionable; nothing else pages.

**Do** — define SLIs from user-visible behaviour, agree SLO targets *with the
business*, calculate error budgets, write multi-window burn-rate alerts. Attach
a runbook to every paging alert.

**Verify** — audit the last 30 days of alerts and answer, per alert:
*did a human have to do something?* If no, delete or downgrade it. Repeat
monthly.

**Exit criteria**
- [ ] Every service has a written SLO with a named owner
- [ ] Error budget policy agreed with the business, including the freeze rule
- [ ] Every paging alert links to a runbook that exists
- [ ] Alert noise reviewed monthly; unactioned alerts removed
- [ ] The on-call rotation is staffed and someone has actually been paged in a test

**What bites people** — alerting on causes (CPU high) instead of symptoms (users
getting errors). You end up with fifty alerts that fire during every deploy and
one real problem that nobody notices in the noise.

---

# Part 6 — The delivery pipeline (weeks 15–18)

## Step 14 — CI with gates that actually block

**Do** — implement the twelve gates in order (`docs/03-security-baseline.md`
§1). Cheapest first so feedback arrives in seconds. Ephemeral, network-restricted
runners; the runner that builds a PR is not the runner that deploys.

**Verify** — attempt to defeat each gate deliberately:
```
Commit a secret          -> blocked?
Introduce an SQL injection -> SAST blocks?
Add a dependency with a known critical CVE -> blocked?
Build an image as root   -> admission rejects?
Push an unsigned image   -> admission rejects?
```
A gate you have not attacked is a gate you do not know the strength of.

**Exit criteria**
- [ ] Each gate demonstrably blocks its own class of problem
- [ ] The PR feedback path completes in under 10 minutes
- [ ] Exceptions live in a register with an owner and an expiry, and CI fails when one expires
- [ ] CI has no long-lived credentials; Vault issues them per job via OIDC
- [ ] SBOM generated and retained per build

**What bites people** — a 40-minute pipeline. Developers start batching changes
to avoid it, and large batches are what cause outages.

---

## Step 15 — Promotion and progressive delivery

**Goal** — deploying to production is a reviewed one-line commit, and a bad
release rolls itself back.

**Do** — `ci/scripts/bump-digest.sh` for promotion. Argo Rollouts canary with
automated analysis. Dev auto-promotes; UAT is manual; prod opens an MR that a
human with prod rights merges.

**Verify** — deploy a deliberately broken version to UAT:
```bash
# Ship a build that returns 500 on 10% of requests.
kubectl argo rollouts get rollout payment-service -n app-uat --watch
# The canary MUST abort on its own, within the first analysis window,
# without anyone intervening. Then confirm the alert fired.
```

**Exit criteria**
- [ ] A broken canary aborts automatically and pages someone
- [ ] Rollback measured end to end, and the number is written in the runbook
- [ ] The CI runner cannot merge to prod — only propose
- [ ] The same digest flows dev → uat → prod, verified by comparing digests
- [ ] Freeze windows are enforced by the pipeline, not by memory

**What bites people** — canary analysis that reads metrics across both canary
and stable pods. The healthy majority masks the failing minority and the canary
always passes. Check the `rollouts_pod_template_hash` selector.

---

## Step 16 — The VM track, to the same standard

**Do** — `infra/ansible/playbooks/deploy-app.yml`: `serial: 1`, drain, deploy,
health, smoke, re-enable, soak. Same image as the Kubernetes track, run under
Podman with systemd sandboxing.

**Verify**
```bash
make ansible-idempotence ENV=dev     # second run MUST report changed=0
# Then a rollout with a deliberately broken version:
# it MUST stop after the first node, leaving the rest on the old version.
```

**Exit criteria**
- [ ] Idempotent: second converge changes nothing
- [ ] A failing deploy halts after one node
- [ ] Rollback is the same playbook with the previous version, tested
- [ ] No secret is ever written to disk (tmpfs only), verified
- [ ] Blue/green or rolling documented, and the choice justified

---

# Part 7 — Proving it works (weeks 18–22)

## Step 17 — Restore drills, on a schedule

**Goal** — recovery times you have measured, not estimated.

**Do** — run the drill table in `docs/07-backup-dr.md` §5. Record for each:
date, operator, what was restored, **measured** RTO/RPO against target, what
failed, action items.

**Exit criteria**
- [ ] Single-table restore: done, timed
- [ ] Database PITR: done, timed, lands within RPO
- [ ] Namespace restore into a scratch cluster: done
- [ ] Vault snapshot restore: done
- [ ] Every drill has a written record with measured numbers
- [ ] Each drill is scheduled with a named owner

**What bites people** — the restore that works but takes 11 hours against a
4-hour RTO. Better to find that in a drill than in an incident. Measured
numbers also give you the evidence to ask for budget.

---

## Step 18 — Game days and chaos, with safety rails

**Goal** — confidence based on evidence.

**Do** — start in UAT, one variable at a time, smallest possible blast radius,
scripted abort that completes in under 30 seconds and has been tested *before*
the experiment.

Experiment order (each must pass before the next):
1. Kill one pod → does the PDB hold, do users notice?
2. Drain one node → do workloads reschedule inside the SLO?
3. Kill the database primary → does failover complete, how many requests fail?
4. Inject 300ms latency into a dependency → do timeouts and breakers behave, or does it cascade?
5. Make a dependency return errors → does the service degrade gracefully or fall over?
6. Lose an entire zone → does capacity hold?

**Exit criteria**
- [ ] Steady state defined and measured *before* every experiment
- [ ] Abort path tested before injection, every time
- [ ] Every experiment produces a written learning and at least one tracked fix
- [ ] Findings are fixed before running the same experiment in production

**What bites people** — running chaos in prod before the basics hold in UAT.
Chaos engineering finds weaknesses; it does not create resilience. Do not use it
to discover that you have no PDBs.

---

## Step 19 — DR failover, and failback

**Do** — full failover to the DR site with the business validating real
transactions. Then **fail back**, which is the half everyone skips and which is
usually undefined.

**Exit criteria**
- [ ] Failover meets the agreed RTO/RPO, measured
- [ ] Business validated end-to-end transactions at DR, signed off
- [ ] **Failback rehearsed and documented**
- [ ] Hidden dependencies confirmed available at DR: DNS, NTP, PKI, IdP, registry, secret store
- [ ] Honest DR capacity stated in writing (if it runs 40% of prod, say 40%)
- [ ] The declaration authority is named — who decides it is a disaster

**What bites people** — a DR site that cannot pull container images because the
registry is in the primary site. Everything looks ready until nothing starts.

---

# Part 8 — Operating it (ongoing)

## Step 20 — Hand over to operations properly

**Goal** — the platform survives its authors going on holiday.

**Exit criteria**
- [ ] Runbooks exist for the top ten alerts, and Ops has executed each once
- [ ] On-call rotation staffed, with primary and secondary
- [ ] Break-glass procedure rehearsed, including the alert it raises
- [ ] Escalation path documented with real names and contact methods
- [ ] **An operator who did not build it has deployed a change end to end, unaided**
- [ ] The routine operational calendar is in a scheduler with named owners

That second-to-last box is the actual handover test. Everything else is
paperwork.

---

## Step 21 — Keep it honest

| Cadence | What |
|---|---|
| Weekly | Golden image rebuild, CVE review, capacity trend |
| Monthly | Patching, restore drill, alert-noise review, access review, exception-register review |
| Quarterly | Cluster upgrade, PITR drill, DR readiness, secret rotation, SLO review |
| Half-yearly | Full rebuild drill, Vault unseal rehearsal, key rotation |
| Annually | DR failover **and failback**, ransomware restore drill, external pentest, threat-model review |

Anything not on a schedule with a named owner will not happen.

---

# Appendix A — The pre-deployment checklist

Run before every production deployment. Attach the result to the change ticket.

- [ ] The artifact digest is byte-identical to the one tested in UAT
- [ ] Migration is expand-phase only and has succeeded in UAT
- [ ] Rollback command is written in the ticket **and has been tested**
- [ ] Canary thresholds reviewed for this specific release
- [ ] The owning team is available for the 30-minute soak after 100%
- [ ] Dashboard and alert links are in the ticket
- [ ] Downstream consumers notified if the API contract changed
- [ ] Not inside a freeze window; error budget is healthy
- [ ] Change ticket approved by two people, one from platform

# Appendix B — Things never to do, and the reason

| Never | Because |
|---|---|
| Deploy `latest` | You cannot reproduce it, roll back to it, or say what is running |
| `kubectl apply` to prod by hand | Argo reverts it, or worse, it becomes permanent undocumented drift |
| Rebuild an image for production | You just invalidated every test you ran |
| Roll back a schema migration | Roll forward. Backwards migrations lose data |
| Grant `cluster-admin` "temporarily" | Temporary access is permanent access with a shorter memory |
| Store a secret in a CI variable | It is readable by everyone with pipeline access, and it never expires |
| Skip the staging environment "just this once" | The one time you skip it is the time it would have caught something |
| Deploy Friday at 17:00 | Not superstition — nobody is around when the slow-burn alert fires at 23:00 |
| Silence an alert without a ticket | Silenced alerts are permanently silenced alerts |
| Fix a problem directly in production | You now have an undocumented state nobody can reproduce |
