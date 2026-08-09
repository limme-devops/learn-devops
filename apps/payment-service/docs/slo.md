# payment-service — Service Level Objectives

> **Author:** Mengty LIM

Required before production (docs/08-microservices.md §7). The numbers here must
match the canary analysis thresholds in
`gitops/business/payment-service/base/analysistemplate.yaml` and the alert
expressions in `prometheusrule.yaml` — if they diverge, one of them is lying.

## Owner

| Field | Value |
|---|---|
| Team | payments-team |
| On-call rotation | `payments-oncall` |
| Escalation | payments-lead → platform-lead → CTO |
| Tier (BC/DR) | Tier 0 — RTO 15 min, RPO ~0 |

## SLIs and SLOs

| # | SLI | Definition | SLO | Window |
|---|---|---|---|---|
| 1 | Availability | proportion of requests to `/api/v1/*` returning non-5xx | **99.9%** | 30d rolling |
| 2 | Latency | proportion of requests served in < 300ms (p99) | **99%** | 30d rolling |
| 3 | Completion | initiated payments that reach a terminal state within 60s | **99.5%** | 30d rolling |
| 4 | Correctness | ledger reconciliation drift | **0** | daily |

SLI 4 has no error budget. A single unit of drift is a P1 — money is either
accounted for or it is not.

## Error budget

```
Availability SLO 99.9% over 30 days
  → allowed downtime  = 0.001 × 30 × 24 × 60 = 43.2 minutes/month
  → at 10M requests/month, the budget is 10,000 failed requests
```

| Budget consumed | Policy |
|---|---|
| < 50% | Normal operation. Ship features. |
| 50–75% | Warning. Review recent incidents at the weekly. |
| 75–100% | Non-critical releases pause. Reliability work is prioritised. |
| > 100% | **Full release freeze** until the budget recovers. Only fixes that improve reliability ship. |

The freeze is enforced in the pipeline, not by memory — see the `deploy_freeze`
assertion in `infra/ansible/playbooks/deploy-app.yml` and the sync window in
`gitops/bootstrap/argocd/projects.yaml`.

## Burn-rate alerting

| Burn rate | Budget consumed | Detection window | Severity |
|---|---|---|---|
| 14.4× | 2% in 1 hour | 1h + 5m | **Page** |
| 6× | 5% in 6 hours | 6h + 30m | Ticket |
| 1× | steady-state consumption | 3d | Dashboard only |

## What is deliberately NOT an SLO

- CPU/memory utilisation — a resource signal, not a user experience. Alert on it
  for saturation, never call it an SLO.
- Individual pod health — users do not care which pod served them.
- Deployment frequency — a delivery metric, not a reliability target.

## Dependencies and their impact

| Dependency | Failure impact | Degradation strategy |
|---|---|---|
| PostgreSQL (payment-db) | Total outage — no degradation possible | Automatic CNPG failover, then PITR |
| Vault | New pods cannot start; running pods survive on cached leases for 1h | Existing capacity keeps serving; block deploys |
| Keycloak | No new logins; existing tokens valid until expiry | JWKS is cached for 5 min; short outages are invisible |
| ledger-service | Payments accepted but not settled | Queue and retry with a circuit breaker; alert on queue age |
| MinIO | Receipts not stored | Buffer locally, backfill; do not fail the payment |

## Review

Reviewed quarterly, and after any SEV1. If the SLO has not been breached in two
consecutive quarters it may be too loose — a target that is never at risk is not
telling you anything.
