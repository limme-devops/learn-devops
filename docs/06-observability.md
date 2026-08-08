# Observability, Monitoring & Alerting

## 1. Stack

| Signal | Tool | Storage / retention |
|---|---|---|
| Metrics | Prometheus (per cluster) + Thanos | 15d local, 13 months in MinIO via Thanos |
| Logs | Promtail/Alloy → Loki | 30d hot, 1y warm, 7y cold (object-lock) for audit logs |
| Traces | OpenTelemetry Collector → Tempo | 7–14d (sampled) |
| Dashboards | Grafana (SSO via Keycloak) | dashboards as code (JSON in Git, provisioned) |
| Alerting | Alertmanager → PagerDuty/Opsgenie + Slack/Teams | — |
| Uptime | Blackbox exporter + external synthetic checks | — |
| Security events | Falco, audit logs, Keycloak/Vault events → SIEM (Wazuh/Splunk/Elastic) | per regulation |

VM track uses the same backends: `node_exporter` + `promtail` + `otel-collector` installed by Ansible, scraped via file_sd or Consul.

## 2. What to instrument (the four golden signals + one)

| Signal | Metric | Where |
|---|---|---|
| **Latency** | `http_request_duration_seconds` histogram, by route + status | app |
| **Traffic** | `http_requests_total` counter, by route + method + status | app |
| **Errors** | ratio of 5xx (and business errors) to total | app |
| **Saturation** | CPU throttling, memory vs limit, connection pool usage, queue depth | app + infra |
| **Business** | payments/min, failed logins, settlement lag, queue age | app — *this is what the bank actually cares about* |

Instrumentation rules:
- Structured JSON logs, one event per line, with `trace_id`, `span_id`, `request_id`, `user_id` (pseudonymised), `service`, `env`.
- **Never log** passwords, tokens, PAN, CVV, national ID, full account numbers. Mask at the logger, not at the ingest pipeline.
- Trace context propagated (W3C `traceparent`) across HTTP, gRPC, and Kafka headers.
- Cardinality discipline: never label a metric with user ID, request ID, email, or full URL path. It will kill Prometheus.

## 3. SLOs — define before you alert

Template per service (`docs/slo.md` in each app repo):

```
Service: payment-service
SLI (availability): proportion of HTTP requests to /api/v1/* returning non-5xx
SLI (latency):      proportion of requests served < 300ms (p99)
SLO:                99.9% availability, 99% of requests < 300ms, 30-day rolling window
Error budget:       0.1% → 43.2 min/month of unavailability
Policy on burn:     >50% budget consumed → freeze non-critical releases, reliability work prioritised
                    >100% consumed → full release freeze until budget recovers
Owner:              payments team | Escalation: payments-oncall
```

Pick SLOs from **user-visible behaviour**, not CPU. "The API responded correctly and fast enough" is an SLO; "CPU < 80%" is not.

## 4. Alerting — the discipline

**Alert on symptoms, page on user impact.** Every paging alert must (a) mean a human must act now and (b) link to a runbook.

Three tiers:
- **P1 / page** — user-facing impact or imminent (fast error-budget burn, service down, data at risk). Wakes someone.
- **P2 / ticket** — degradation, slow burn, capacity trending to exhaustion. Business hours.
- **P3 / info** — dashboard-only. Never notifies.

**Multi-window burn-rate alerts** (avoids both flapping and slow detection):

```yaml
groups:
  - name: slo-payment-availability
    rules:
      # Page: 2% of monthly budget burned in 1h  (14.4x burn)
      - alert: PaymentErrorBudgetFastBurn
        expr: |
          (
            sum(rate(http_requests_total{service="payment",status=~"5.."}[1h]))
            / sum(rate(http_requests_total{service="payment"}[1h]))
          ) > (14.4 * 0.001)
          and
          (
            sum(rate(http_requests_total{service="payment",status=~"5.."}[5m]))
            / sum(rate(http_requests_total{service="payment"}[5m]))
          ) > (14.4 * 0.001)
        for: 2m
        labels: { severity: critical, team: payments, page: "true" }
        annotations:
          summary: "payment-service burning error budget 14x — {{ $value | humanizePercentage }} error rate"
          runbook_url: "https://wiki.internal/runbooks/payment-high-errors"
          dashboard: "https://grafana.internal/d/payment-red"

      # Ticket: 5% of budget in 6h (6x burn)
      - alert: PaymentErrorBudgetSlowBurn
        expr: |
          (
            sum(rate(http_requests_total{service="payment",status=~"5.."}[6h]))
            / sum(rate(http_requests_total{service="payment"}[6h]))
          ) > (6 * 0.001)
        for: 15m
        labels: { severity: warning, team: payments }
        annotations:
          summary: "Sustained error budget consumption on payment-service"
          runbook_url: "https://wiki.internal/runbooks/payment-slow-burn"
```

**Platform alerts everyone needs** (each with a runbook):

| Alert | Expression sketch | Tier |
|---|---|---|
| Node not ready | `kube_node_status_condition{condition="Ready",status="true"}==0` for 5m | P1 |
| Pod crash-looping | `increase(kube_pod_container_status_restarts_total[15m]) > 3` | P2 |
| PVC nearly full | `kubelet_volume_stats_available_bytes / capacity < 0.15` | P2 (P1 at <5%) |
| etcd no leader / high fsync | `etcd_server_has_leader==0` | P1 |
| Certificate expiring | `certmanager_certificate_expiration_timestamp - time() < 14d` | P2 |
| Vault sealed | `vault_core_unsealed == 0` | P1 |
| PostgreSQL replication lag | `cnpg_pg_replication_lag > 30` | P1 |
| **Backup did not run** | `time() - backup_last_success_timestamp > 26h` | **P1** |
| **Backup restore drill overdue** | custom gauge > 90d | P2 |
| Kafka consumer lag growing | `kafka_consumergroup_lag > threshold` for 15m | P2 |
| Falco critical rule fired | `falco_events{priority="Critical"}` | P1 → SecOps |
| Failed logins spike | `rate(keycloak_failed_login_attempts[5m])` anomalous | P1 → SecOps |
| Node/host disk, memory, inode pressure | USE method | P2 |

**Anti-alert-fatigue rules:** inhibition (node-down suppresses its pod alerts), grouping by cluster/service, `for:` durations tuned to avoid transient flaps, and a monthly alert review — any alert that fired and required no action gets deleted or downgraded.

## 5. Dashboards

- **RED per service** (Rate, Errors, Duration) — auto-generated from a template, one per service.
- **USE per resource** (Utilization, Saturation, Errors) — nodes, disks, network, DB pools.
- **Business dashboard** — transactions, failures, latency of critical journeys. This is the screen on the wall.
- **SLO dashboard** — current burn rate, budget remaining, trend to end of window.
- **Security dashboard** — auth failures, policy violations, image scan drift, privileged access events.
- **Deployment overlay** — annotate all dashboards with deploy events from ArgoCD/CI, so "what changed?" is one glance.

Dashboards live in Git and are provisioned; nobody edits prod dashboards in the UI.

## 6. On-call

- Rotation with a documented primary/secondary, business-hours and after-hours coverage.
- Every P1 alert links to a runbook containing: what it means, blast radius, first three diagnostic commands, mitigation, escalation contact.
- **Incident severity levels** (SEV1–4) with defined response times, comms channels, and stakeholder notification (in a bank, SEV1 may carry a regulatory reporting clock — know your window).
- Blameless postmortem required for every SEV1/SEV2 within 5 business days: timeline, contributing factors, what detected it, what delayed recovery, action items with owners and due dates.
- Track: MTTD, MTTR, page volume per shift, % of pages that were actionable, toil hours. If toil > 50%, stop feature work and automate.

## 7. Log retention & audit (banking)

| Log type | Hot | Warm | Cold | Immutable? |
|---|---|---|---|---|
| Application logs | 30d | 90d | 1y | no |
| Access/auth logs (Keycloak) | 90d | 1y | 7y | **yes (object-lock)** |
| Vault audit | 90d | 1y | 7y | **yes** |
| K8s API audit | 30d | 1y | 7y | **yes** |
| Database audit (pgaudit) | 90d | 1y | 7y | **yes** |
| CI/CD & change records | in Git forever | — | — | yes (signed commits) |

Confirm exact retention with your compliance officer — jurisdictions differ. Configure it in code, and alert if a retention policy drifts.
