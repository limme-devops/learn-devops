# Deployment Strategies — Choosing and Implementing

> **Author:** Mengty LIM

## 1. Decision table

| Strategy | Downtime | Cost | Rollback speed | Blast radius on bad release | Use when |
|---|---|---|---|---|---|
| **Recreate** | Yes | 1× | redeploy old (slow) | 100% | Dev only, or a singleton that cannot run two versions |
| **Rolling** | No | 1.25× | rollout undo (minutes) | grows as it rolls | Default for internal/low-risk services |
| **Blue/Green** | No | 2× | instant (flip traffic) | 100% at switch, but instant undo | VM fleets, DB-coupled apps, big-bang cutovers |
| **Canary** | No | 1.1× | instant (shift back) | 1–5% of users | **Default for prod customer-facing services** |
| **A/B (traffic-split by attribute)** | No | 1.1× | instant | selected cohort | Feature/UX experiments, not reliability |
| **Shadow / dark launch** | No | 2× | n/a (no user traffic) | 0% | Validating a rewrite against real traffic |
| **Feature flag** | No | 1× | instant (flag off) | controllable per-user | Decoupling deploy from release — pair with any of the above |

**The rule for a bank:** deploy ≠ release. Ship code dark behind a flag, then release progressively. That way a bad *release* is a config toggle, not a redeploy.

## 2. Canary with Argo Rollouts (K8s, prod default)

Implemented in `gitops/business/payment-service/overlays/prod/`.

```
5% ──5m──► analysis ──25%──10m──► analysis ──50%──10m──► 100%
             │                        │
             └── success-rate < 99%   └── p99 latency > 300ms
                        │
                   auto-abort → 100% back to stable, alert fires
```

Key points:
- **Analysis is automated.** A human watching Grafana is not a gate; a PrometheusRule query is.
- Metric queries must be scoped to the canary pods only (`rollouts-pod-template-hash` label), otherwise the stable pods' healthy traffic masks the canary's errors.
- `scaleDownDelaySeconds` keeps the old ReplicaSet warm so abort is instant.
- Abort must page. A silent auto-rollback that nobody investigates means the bug ships next time.

**Analysis template** (`gitops/business/payment-service/base/analysistemplate.yaml`):
```yaml
successCondition: result[0] >= 0.99
failureLimit: 2
interval: 1m
count: 5
```

## 3. Blue/Green on VMs (Track A)

Implemented in `infra/ansible/playbooks/deploy-app.yml`.

```
             HAProxy (VIP, keepalived)
             ┌────────┴────────┐
        backend_blue      backend_green
        (v1, live)         (v2, staged)
```

Two variants, pick one:

**(a) Node-by-node rolling within one pool** — `serial: 1`, drain → deploy → health → smoke → soak → re-enable. Cheaper (no second fleet), but during the roll both versions serve traffic, so the versions must be compatible. This is what the playbook implements by default.

**(b) True blue/green with two pools** — deploy v2 to the idle pool, run the full test suite against it via a private VIP, then flip `haproxy` backend in one config reload. Instant rollback = flip back. Costs 2× VMs. Use for high-risk releases and DB-coupled changes.

Critical details the playbook handles:
- `drain: true` on HAProxy (not `disabled`) so in-flight sessions finish
- `max_fail_percentage: 0` — first failure stops the roll, leaving the rest on the old version
- health check + smoke test **before** returning the node to the pool
- a soak pause between nodes so error-rate alerts have time to fire
- `PREVIOUS_VERSION` recorded so the rollback path is a re-run, not an improvisation

## 4. Database migrations — expand / migrate / contract

This is the constraint that governs every other strategy: **you cannot roll back a schema.** So never make a release depend on one.

```
Release N   (expand)   Add nullable column / new table / new index CONCURRENTLY.
                       Old and new code both work. Safe to roll back.
Release N+1 (migrate)  New code writes both old and new. Backfill in batches.
                       Safe to roll back to N.
Release N+2 (contract) Stop reading the old column. Deploy. Verify.
Release N+3 (drop)     Drop the old column, after a soak period.
```

Rules:
- Migrations run as a **separate job before the app rollout** (K8s: Argo `PreSync` hook; VM: an Ansible pre_task on one host only), never in the app's startup path — otherwise N pods race the same migration.
- Every migration must be idempotent and re-runnable.
- No `ALTER TABLE` that takes an exclusive lock on a large hot table during business hours. Use `CREATE INDEX CONCURRENTLY`, batched backfills with sleep, `lock_timeout` set low so a blocked migration fails fast instead of queueing the whole database.
- Long migrations get their own change ticket and their own rollback plan (which is usually "roll forward").

## 5. Progressive delivery gates — what actually stops a bad release

| Gate | Where | Catches |
|---|---|---|
| Unit/integration tests | CI | logic regressions |
| Contract tests | CI | breaking API changes for consumers |
| Image scan + signature | CI + admission | vulnerable/unsigned artifacts |
| Deploy to dev → auto smoke | CD | packaging/config errors |
| Deploy to UAT → full regression + load test | CD | performance regressions |
| **Canary analysis (error rate, latency)** | CD | runtime failures under real traffic |
| SLO burn-rate alert | Runtime | slow-burn damage the canary window missed |
| Feature flag | Runtime | business-logic problems found post-release |

Each layer catches what the previous one couldn't. Removing one because "we have the others" is how outages happen.

## 6. Rollback playbook (per strategy)

| Strategy | Rollback command | Expected time |
|---|---|---|
| K8s rolling | `kubectl rollout undo deployment/<name> -n <ns>` | 1–3 min |
| Argo Rollouts canary | `kubectl argo rollouts abort <name> -n <ns>` then `promote --full` on the stable rev | < 60 s |
| GitOps (any) | `git revert <sha>` in the gitops repo, Argo syncs | 2–5 min |
| VM rolling | re-run `deploy-app.yml -e app_version=<previous>` | 5–15 min |
| VM blue/green | flip HAProxy backend, reload | < 30 s |
| Feature flag | toggle off | seconds |
| DB schema | **do not roll back** — roll forward with a fix | varies |

**Test the rollback in UAT as part of every release rehearsal.** An untested rollback is the second incident inside the first one.

## 7. Deployment windows and freeze periods (banking reality)

- Prod deploys during business hours with the owning team available. Not Friday afternoon, not the last day of the month.
- **Freeze periods**: month-end/quarter-end close, regulatory reporting windows, major public holidays, and any declared incident. Encode the freeze in the pipeline (a scheduled variable that fails `promote-prod`), don't rely on people remembering.
- Emergency releases may cross a freeze with named executive approval — recorded, and reviewed afterwards.
- Error-budget policy overrides everything: if the budget is exhausted, non-critical releases stop until it recovers (`06-observability.md` §3).

## 8. Pre-deploy checklist (attach to the change ticket)

- [ ] Artifact digest is the same one tested in UAT
- [ ] Migration (if any) is expand-phase only and has run successfully in UAT
- [ ] Rollback command written in the ticket, and tested
- [ ] Canary analysis thresholds reviewed for this release
- [ ] Owning team available for the 30-minute soak after 100%
- [ ] Dashboard + alert links in the ticket
- [ ] Downstream consumers notified if the API contract changed
- [ ] Not inside a freeze window; error budget healthy
