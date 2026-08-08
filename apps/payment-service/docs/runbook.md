# payment-service — Runbook

**Severity range:** P1–P3 | **Owner:** payments-team | **Last tested:** 2026-08-08

Every alert in `prometheusrule.yaml` links here. If you add an alert without
adding a section below, the alert is not finished.

---

## PaymentServiceFastErrorBudgetBurn (P1 — page)

### What this means
More than 1.4% of payment API requests are failing. At this rate the entire
monthly error budget is gone in about two days. Customers are seeing errors now.

### Blast radius
All payment initiation and status queries. **Not** affected: already-settled
payments, the ledger, other services.

### First 3 commands
```bash
kubectl get rollout payment-service -n app-payment          # mid-rollout?
kubectl get pods -n app-payment -l app.kubernetes.io/name=payment-service
kubectl logs -n app-payment -l app.kubernetes.io/name=payment-service --tail=100 | jq 'select(.level=="ERROR")'
```

### Decision tree
- **A rollout is in progress** → `kubectl argo rollouts abort payment-service -n app-payment`. Traffic returns to stable within seconds. Then investigate the canary.
- **Pods are CrashLooping** → see *PaymentServicePodCrashLooping* below.
- **Errors are database-related** (`connection refused`, `too many connections`) → check `kubectl get cluster payment-db -n data-postgres`; go to *DB connection failures*.
- **Errors are auth-related** (401/403 spike) → check Keycloak: `kubectl get pods -n identity`. A JWKS fetch failure invalidates every token.
- **None of the above** → check whether a dependency changed: `kubectl get events -n app-payment --sort-by=.lastTimestamp | tail -20`.

### Mitigation
```bash
# 1. If a recent deploy is implicated, roll back first, diagnose second.
kubectl argo rollouts undo payment-service -n app-payment
kubectl argo rollouts status payment-service -n app-payment

# 2. If load-related, scale out (the HPA may be lagging).
kubectl scale rollout payment-service --replicas=12 -n app-payment

# 3. ⚠ If a single pod is poisoning the pool, remove it from service WITHOUT
#    deleting it — keep it for forensics.
kubectl label pod <pod> app.kubernetes.io/name- -n app-payment
```

### Verification
```bash
# Error rate must be back under 0.1%.
curl -sG https://prometheus.bank.internal/api/v1/query \
  --data-urlencode 'query=sum(rate(http_requests_total{service="payment-service",status=~"5.."}[5m])) / sum(rate(http_requests_total{service="payment-service"}[5m]))' \
  | jq -r '.data.result[0].value[1]'
```
"Looks fine on the dashboard" is not verification. Read the number.

### Rollback
If the mitigation made things worse, `kubectl argo rollouts undo payment-service -n app-payment --to-revision=<N>` returns to a known-good revision. `kubectl argo rollouts history payment-service -n app-payment` lists them.

### Escalation
payments-oncall → payments-lead (15 min) → platform-lead (30 min) → CTO (SEV1, 60 min).
If money movement is affected, notify Finance Ops **immediately** — there may be a regulatory reporting clock.

### Post-incident
Blameless postmortem required within 5 business days.

---

## PaymentServicePodCrashLooping (P1 — page)

### First 3 commands
```bash
kubectl describe pod <pod> -n app-payment | tail -30      # events + last state
kubectl logs <pod> -n app-payment --previous              # logs from BEFORE the crash
kubectl get events -n app-payment --field-selector involvedObject.name=<pod>
```

### Common causes
| Symptom | Cause | Fix |
|---|---|---|
| `OOMKilled` in last state | Memory limit too low, or a leak | Raise `limits.memory` in the overlay; if it recurs after a raise, it is a leak — get a heap dump before restarting |
| `CreateContainerConfigError` | Secret missing | `kubectl get externalsecret -n app-payment` — Vault auth or a missing key |
| Exit code 1 immediately | Bad config or failed migration | Check the PreSync job: `kubectl logs job/payment-service-migrate -n app-payment` |
| Liveness probe failing during startup | Slow start, missing startupProbe | The startupProbe allows 150s; a slower boot needs a higher `failureThreshold` |
| `ImagePullBackOff` | Unsigned image, or Harbor unreachable | `kubectl describe pod` shows whether Kyverno rejected the signature |

⚠ **Do not delete a crash-looping pod before capturing `--previous` logs.** The evidence goes with it.

---

## DB connection failures (P1)

### First 3 commands
```bash
kubectl get cluster payment-db -n data-postgres -o wide
kubectl cnpg status payment-db -n data-postgres
kubectl logs -n data-postgres payment-db-1 --tail=50
```

### Decision tree
- **No primary** → CNPG is failing over. Wait 60s, then `kubectl cnpg promote payment-db <instance> -n data-postgres` if it is stuck.
- **`too many connections`** → check the pooler: `kubectl get pooler payment-db-pooler -n data-postgres`. Often an HPA scale-out multiplied by pool size exceeded `max_connections`.
- **Auth failures** → Vault dynamic credentials may have failed to renew: `kubectl logs -n external-secrets deploy/external-secrets`.
- **Disk full** → the WAL volume is separate for exactly this reason. `kubectl exec -n data-postgres payment-db-1 -- df -h /var/lib/postgresql/wal`. Expanding a PVC is safe; deleting WAL is **not**.

### Escalation
DBA on-call. If data loss is suspected, stop writes before doing anything else and follow the PITR runbook (`docs/07-backup-dr.md` §7).

---

## PaymentReconciliationDrift (P1 — page, Finance Ops)

### What this means
The ledger does not balance. Money is unaccounted for. This is the most serious
alert this service can raise.

### Do NOT
- Restart pods (may lose in-flight state)
- Re-run failed payments (may double-charge)
- "Wait and see if it resolves"

### Do
1. Freeze new payment processing: set `FEATURE_PAYMENTS_ENABLED=false` in the prod overlay and sync.
2. Capture the drift: `kubectl exec -n data-postgres payment-db-1 -- psql -d payment -c "SELECT * FROM reconciliation_drift ORDER BY detected_at DESC LIMIT 20"`
3. Notify Finance Ops and the payments-lead **immediately**.
4. Preserve evidence: no restarts, no deletes, no schema changes until Finance signs off.
5. Expect a regulatory reporting obligation with a hard deadline.

---

## Routine: scaling for a known traffic peak

```bash
# Raise the floor ahead of the event — do not rely on the HPA to react in time.
kubectl patch hpa payment-service -n app-payment --type=merge \
  -p '{"spec":{"minReplicas":10}}'

# Confirm the database can take the extra connections first.
kubectl get pooler payment-db-pooler -n data-postgres -o yaml | grep -A3 pgbouncer
```
Revert `minReplicas` after the event, or you pay for the capacity all month.

---

## Routine: rolling back a release

| Situation | Command | Time |
|---|---|---|
| Rollout in progress | `kubectl argo rollouts abort payment-service -n app-payment` | < 60s |
| Rollout completed | `kubectl argo rollouts undo payment-service -n app-payment` | 1–3 min |
| Proper GitOps rollback | `git revert <sha>` in the gitops repo | 2–5 min |
| VM track | `ansible-playbook ... -e app_version=<previous> -e rollback=true` | 5–15 min |

The GitOps revert is the correct one — a `kubectl` rollback is reverted by Argo's
`selfHeal` at the next sync. Use `kubectl` only to stop the bleeding, then
immediately land the revert commit.

**A schema migration is never rolled back.** Roll forward with a fix.
