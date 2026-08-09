# Logging, Monitoring & Alerting — Operating Procedure

> **Author:** Mengty LIM

[06-observability.md](06-observability.md) decides *what* the stack is and *what*
to instrument. This document is the **procedure**: how logs get from a process
to a screen, how dashboards and alert rules are changed without clicking, how
API traffic is monitored, and what an engineer actually does when an alert
fires.

If 06 is the design, 15 is the operations manual.

---

## 1. The two-tier logging decision

You will be asked "why do we have both Loki and Elasticsearch?" Have the answer
ready, because the honest failure mode is drifting into *two copies of every
log*, paying twice and trusting neither.

| Tier | Tool | Contents | Consumers | Retention |
|---|---|---|---|---|
| **Operational** | Promtail/Alloy → **Loki** → Grafana | Application logs, gateway access logs, platform component logs | Engineers, during and after incidents | 30d hot, 1y warm |
| **Security & audit** | Filebeat/Alloy → **Elasticsearch** → **Kibana** | auditd, sshd, sudo, Kubernetes audit, Vault audit, Keycloak events, Falco, gateway auth decisions | SOC, auditors, forensics | 7y, immutable (object-lock) |

**The routing rule: a log line goes to exactly one tier.** Decide at the
collector, by source, not by copying everything to both:

- Anything that answers *"why is the service slow/erroring?"* → Loki.
- Anything that answers *"who did what, when, from where?"* → Elasticsearch.
- The small overlap (gateway logs answer both) is duplicated **deliberately**,
  documented, and is the only duplication permitted.

**Why not one tier for everything?** Different requirements, not different
fashions. Audit logs need write-once storage, 7-year retention, field-level
access control and legal hold. Operational logs need cheap high-volume ingest
and fast label-based search. Forcing either tool to do both job makes it bad at
its own.

> **Repo status:** `docs/06-observability.md` §1 already lists Loki for logs and
> "SIEM (Wazuh/Splunk/Elastic)" for security events. This document names that
> second tier concretely as Elasticsearch + Kibana. If you standardise on
> something else, change it in both places — a stack named two ways is a stack
> nobody can operate.

---

## 2. Procedure — the log pipeline, end to end

Six stages. Each has an owner and a verification.

```
[1] EMIT      app writes JSON to stdout          owner: service team
[2] COLLECT   Alloy/Promtail/Filebeat tails it   owner: platform
[3] PARSE     extract trace_id, level, route     owner: platform
[4] ENRICH    add env, cluster, namespace, pod   owner: platform
[5] ROUTE     operational → Loki | audit → ES    owner: platform
[6] RETAIN    ILM / compactor / object-lock      owner: platform + compliance
```

### 2.1 Stage 1 — Emit (the only stage service teams own)

Non-negotiable field schema. Every service, every language:

| Field | Example | Why |
|---|---|---|
| `ts` | `2026-08-09T14:22:01.334Z` | RFC3339, UTC, milliseconds. Never local time |
| `level` | `error` | Lowercase, fixed set |
| `service` | `payment-service` | Matches the Kubernetes label |
| `env` | `prod` | The one vocabulary from [14](14-promotion-procedure.md) §1 |
| `trace_id` / `span_id` | `4bf92f…` | W3C. The join key across logs, traces and metrics |
| `request_id` | from `X-Request-ID` | Stamped at the edge; the id a customer can quote |
| `msg` | `payment authorisation failed` | Human sentence, **no interpolated values** |
| `error.kind` / `error.msg` | `UpstreamTimeout` | Structured, so you can aggregate on it |
| `user_id` | pseudonymised | Never the raw identifier |

Rules:
- **One event per line. JSON. stdout.** Not a file, not syslog, not a
  library that phones home to a log service.
- **Mask at the logger, not at the ingest pipeline.**
  `apps/payment-service/src/main.py` implements `SENSITIVE_KEYS` masking in the
  formatter. Masking downstream means the secret existed in plaintext on a node
  filesystem, which is exactly what you were trying to prevent.
- **Never interpolate values into `msg`.** `msg="payment failed for 4111…"`
  is both unaggregatable and a PAN leak. Put values in fields.
- **Log level discipline:** `error` = a human must eventually look. `warn` = it
  self-healed but is worth counting. If everything is `error`, nothing is.

### 2.2 Stages 2–5 — Collect, parse, enrich, route

```river
// Grafana Alloy — the routing decision, made once, at the collector.
loki.process "app_logs" {
  stage.json {
    expressions = { level = "level", trace_id = "trace_id", service = "service" }
  }
  // Labels are INDEXED in Loki. Every distinct value is a stream.
  // service/env/level are bounded. request_id/user_id/trace_id are NOT —
  // labelling on them creates millions of streams and takes Loki down.
  stage.labels {
    values = { level = "", service = "" }
  }
  // Last-resort redaction. Belt and braces; §2.1 is the real control.
  stage.replace {
    expression = "(?i)(password|token|secret|authorization)\"\\s*:\\s*\"[^\"]*\""
    replace    = "${1}\":\"[REDACTED]\""
  }
  forward_to = [loki.write.operational.receiver]
}
```

**The cardinality rule, stated once:** in Loki, *labels* are indexed and must be
low-cardinality; everything else stays in the log line and is searched at query
time. In Prometheus, the same rule applies to metric labels. Violating it is the
single most common way to take down an observability stack — and it always
happens during an incident, when you need it most.

### 2.3 Verification (run these; do not assume)

| # | Check | Pass |
|---|---|---|
| 1 | `logcli query '{service="payment-service"} \|= "password"' --since=24h` | Zero results |
| 2 | Kill a pod mid-request; find the trace_id in Loki and Tempo | Same id, both tools |
| 3 | Stop the log backend for 10 minutes, restart | No gap — the collector buffered and replayed |
| 4 | Check collector lag metric during a load test | Lag returns to zero; if it grows monotonically you are dropping logs silently |
| 5 | Try to delete an audit index as the platform service account | Denied |

**Check 3 is the one people skip.** A collector with no disk buffer drops logs
during exactly the backend outage you most want logs for. Configure
`wal` / disk-assisted queues on every collector — `roles/observability_agents/`
does this for rsyslog; do the same for Alloy.

---

## 3. Procedure — Kibana (security & audit tier)

### 3.1 Index structure: data streams, not indices

Use data streams with a lifecycle policy. Time-based index naming managed by
hand is how clusters die at 3am.

```json
// ILM policy: audit-logs-7y
{
  "policy": {
    "phases": {
      "hot":    { "actions": { "rollover": { "max_primary_shard_size": "50gb", "max_age": "1d" } } },
      "warm":   { "min_age": "7d",   "actions": { "shrink": { "number_of_shards": 1 },
                                                  "forcemerge": { "max_num_segments": 1 } } },
      "cold":   { "min_age": "30d",  "actions": { "searchable_snapshot": { "snapshot_repository": "minio-audit" } } },
      "frozen": { "min_age": "365d", "actions": { "searchable_snapshot": { "snapshot_repository": "minio-audit" } } }
      // NOTE: there is deliberately NO "delete" phase. Audit data is removed by
      // an explicit, approved, ticketed process — never by a lifecycle policy
      // that a config typo could accelerate.
    }
  }
}
```

**The retention control that actually matters** is not the ILM policy — it is
the MinIO bucket the cold/frozen snapshots live in, with **Object Lock in
compliance mode** ([07-backup-dr.md](07-backup-dr.md)). Elasticsearch can be
compromised; a compliance-mode object lock cannot be shortened by anyone,
including the root account.

### 3.2 Access control procedure

| Role | Spaces | Indices | Notes |
|---|---|---|---|
| `soc-analyst` | `security` | read on `audit-*`, `falco-*` | No cluster privileges |
| `auditor` | `audit` | read on `audit-*` | Read-only, time-boxed, granted per engagement |
| `platform-eng` | `platform` | read on `platform-*`, **none** on `audit-*` | Engineers do not read audit logs routinely |
| `log-shipper` | — | `create_doc` **only** on `audit-*` | Cannot read, cannot delete. Same shape as the backup-writer identity |

**`log-shipper` having only `create_doc` is the important row.** A compromised
node can then append forged events but cannot read or erase the record of what
it did. Field-level and document-level security require a commercial licence in
Elastic (OpenSearch has its own equivalent) — check before you design around it.

**Kibana Spaces are not a security boundary by themselves** — they organise UI.
Back every space with a role that restricts the underlying indices.

### 3.3 Saved objects as code

Kibana's UI is for *investigating*, never for *configuring*. Anything you would
be sad to lose gets exported and committed:

```bash
# Export — run after any deliberate change, commit the result
curl -s -u "$KB_USER:$KB_PASS" -X POST \
  "$KIBANA/api/saved_objects/_export" \
  -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d '{"type":["dashboard","search","index-pattern","lens"],"includeReferencesDeep":true}' \
  > observability/kibana/saved-objects.ndjson

# Import — how a rebuilt Kibana gets its content back. Idempotent.
curl -s -u "$KB_USER:$KB_PASS" -X POST \
  "$KIBANA/api/saved_objects/_import?overwrite=true" \
  -H 'kbn-xsrf: true' -F file=@observability/kibana/saved-objects.ndjson
```

Put the import in CI on merge to `main`. A dashboard that exists only in one
Kibana instance is a dashboard you will lose.

### 3.4 Investigation queries (KQL) worth having on hand

```
# Who used break-glass access, and what did they do?
user.name: "breakglass-*" and not event.action: "login-failed"

# Vault: any policy or auth-method change (should be rare and always ticketed)
vault.request.path: ("sys/policy*" or "sys/auth*") and vault.request.operation: ("update" or "delete")

# Kubernetes audit: exec into a prod pod
objectRef.resource: "pods" and objectRef.subresource: "exec" and objectRef.namespace: "app-payment"

# Authentication anomalies: same user, multiple source countries, one hour
event.category: "authentication" and event.outcome: "success"
  # then visualise: unique count of source.geo.country_name by user.name

# Someone reading a secret they have never read before
vault.request.path: "kv/data/*" and vault.auth.display_name: *
```

**Turn each recurring query into a detection rule with an alert**, rather than
re-typing it. A query a human must remember to run is not a control.

---

## 4. Procedure — Grafana (operational tier)

### 4.1 The rule: nothing is configured in the UI

Grafana's UI is for *exploring*. Every persistent object — datasource,
dashboard, folder, alert rule, contact point — is provisioned from git. Set
`editable: false` on provisioned dashboards so the UI physically refuses to save
over them, which converts a policy into a control.

**Three ways to provision. Pick one per object type and be consistent:**

| Method | Best for | Trade-off |
|---|---|---|
| **Provisioning files** (`/etc/grafana/provisioning/…`) mounted from a ConfigMap | Datasources, folders, dashboards | Requires a Grafana restart/reload for some changes |
| **Terraform `grafana` provider** | Folders, RBAC, alert rules, contact points | State to manage, but real diffs and real review |
| **HTTP API** (`/api/v1/provisioning/*`) | CI-driven dashboard sync, bulk import | You own idempotency yourself |

Recommended split for this platform: **files** for datasources, **Terraform**
for folders/permissions/contact points, **API in CI** for dashboards.

```yaml
# observability/grafana/provisioning/datasources/loki.yaml
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    uid: loki-prod            # ← pin the uid. Dashboards reference it. An
                              #   auto-generated uid breaks every dashboard
                              #   the day you rebuild Grafana.
    url: http://loki-gateway.monitoring.svc:3100
    isDefault: false
    editable: false
    jsonData:
      derivedFields:
        # Turns trace_id in a log line into a clickable link to Tempo.
        # This one setting saves more incident minutes than any dashboard.
        - name: TraceID
          matcherRegex: '"trace_id":"(\w+)"'
          url: '$${__value.raw}'
          datasourceUid: tempo-prod
```

```hcl
# observability/grafana/terraform/alerting.tf
resource "grafana_folder" "payments" {
  title = "Payments"
}

resource "grafana_contact_point" "pagerduty_p1" {
  name = "pagerduty-p1"
  pagerduty {
    integration_key = data.vault_kv_secret_v2.pd.data["p1_key"]  # never a literal
    severity        = "critical"
  }
}

resource "grafana_notification_policy" "root" {
  contact_point = grafana_contact_point.slack_default.name
  group_by      = ["alertname", "service", "env"]

  policy {
    matcher { label = "severity" value = "critical" match = "=" }
    contact_point   = grafana_contact_point.pagerduty_p1.name
    group_wait      = "10s"     # page fast
    repeat_interval = "1h"
  }
  policy {
    matcher { label = "severity" value = "warning" match = "=" }
    contact_point   = grafana_contact_point.slack_default.name
    group_wait      = "5m"      # batch; nobody needs 40 Slack messages
    repeat_interval = "12h"
  }
}
```

```bash
# CI: sync dashboards from git. Runs on merge to main.
for f in observability/grafana/dashboards/*.json; do
  jq --arg folder "$FOLDER_UID" \
     '{dashboard: (.  + {id: null}), folderUid: $folder, overwrite: true}' "$f" \
  | curl -sf -X POST "$GRAFANA/api/dashboards/db" \
      -H "Authorization: Bearer $GRAFANA_TOKEN" \
      -H 'Content-Type: application/json' --data @- \
  || { echo "FAILED: $f"; exit 1; }
done
```

Note `id: null` — a dashboard JSON exported from one Grafana carries an `id`
that means something different in another. Leaving it in is why "the import
overwrote the wrong dashboard".

### 4.2 Where alert rules live — decide once

You can define alert rules in **Prometheus** (`PrometheusRule` CRs) or in
**Grafana Alerting**. Both is a trap: two systems evaluating similar rules
produce duplicate pages that resolve at different times, and nobody can find
which one fired.

**The split that works:**

| Rule type | Define in | Why |
|---|---|---|
| Metric-only (burn rate, saturation, availability) | **Prometheus** `PrometheusRule` | Evaluated next to the data, survives Grafana being down, already in git |
| Log-based (error pattern, audit event) | **Grafana Alerting** | Grafana can query Loki; Prometheus cannot |
| Multi-datasource (metric + log correlation) | **Grafana Alerting** | Only it can join across datasources |

**The critical property:** your alerting must survive Grafana. If Grafana is the
only thing that can page, a Grafana outage is a silent outage of everything
else. Keep the paging-severity metric alerts in Prometheus/Alertmanager.

### 4.3 Dashboard standards

Every service dashboard, same four rows, same order. Familiarity is the point —
at 3am an engineer should not have to learn a layout:

```
Row 1  RED         request rate · error rate · p50/p95/p99 latency
Row 2  SLO         error budget remaining · burn rate (1h/6h) · time to exhaustion
Row 3  SATURATION  CPU throttling · memory vs limit · connection pool · queue depth
Row 4  DEPENDENCY  DB latency · cache hit rate · upstream error rate by target
```

Rules:
- **Every panel answers a question someone actually asks.** If nobody can say
  what decision a panel drives, delete it.
- **Link the runbook from the dashboard**, and the dashboard from the alert.
- **Show the deploy markers** (annotations from ArgoCD/CI). "What changed?" is
  the first question in every incident and this answers it in one glance.
- **No dashboard is a substitute for an alert.** A dashboard nobody is looking
  at detects nothing.

---

## 5. Procedure — API monitoring with Gravitee

Gravitee is an API management platform (an alternative to Kong,
[13-edge-gateway.md](13-edge-gateway.md) §2). Its observability story is
different from Kong's in one important way: **Gravitee's native analytics are
built on Elasticsearch**, so it lands naturally in the Kibana tier — while your
service metrics live in Prometheus. Plan for that split rather than discovering
it.

### 5.1 The two signal paths

```
Gravitee Gateway
   ├── reporter (elasticsearch) ──► ES ──► Kibana / APIM Console analytics
   │      per-request records: API, plan, application (consumer), status,
   │      gateway latency, upstream latency, response size
   └── metrics endpoint (prometheus) ──► Prometheus ──► Grafana ──► alerts
          node-level: JVM heap, event-loop, connection pools, throughput
```

**Use both, for different questions:**
- *"Which consumer is burning their quota / getting 429s?"* → Elasticsearch.
  This is per-request, high-cardinality, and belongs in a search engine.
- *"Is the gateway healthy and should someone be paged?"* → Prometheus.
  This is low-cardinality time series and belongs in your alerting path.

Do not try to page from Elasticsearch analytics, and do not try to answer
per-consumer questions from Prometheus labels — that is the cardinality
explosion of §2.2 with extra steps.

```yaml
# gravitee.yml — gateway reporter configuration (verify keys against your
# Gravitee major version; the reporter block has changed shape across releases)
reporters:
  elasticsearch:
    enabled: true
    endpoints:
      - https://elasticsearch.platform.svc:9200
    index: gravitee
    bulk:
      actions: 1000
      flush_interval: 5      # seconds
    security:
      username: ${gravitee_es_user}
      password: ${gravitee_es_password}   # from Vault, never a literal
  file:
    enabled: false

services:
  metrics:
    enabled: true
    prometheus:
      enabled: true          # exposes /_node/metrics?type=prometheus
```

### 5.2 Per-API SLIs and the alerts worth having

| Alert | Signal | Severity | Why |
|---|---|---|---|
| API 5xx burn rate | Prometheus, multi-window 14.4×/6× | P1 / P2 | The customer-facing SLI |
| Upstream unhealthy | Gravitee health-check status | P1 | Backend gone before users notice |
| Gateway latency ≫ upstream latency | `gateway_latency - api_latency > 200ms` | P2 | Cost is in the gateway: policy chain, JWKS fetch, connection pool |
| 429 spike for one consumer | ES aggregation → detection rule | P3 | Quota set too low, or an integration bug at the partner |
| Auth failure spike | ES, `status:401` grouped by application | P2 | Credential rotation gone wrong, or an attack |
| Plan quota near exhaustion | ES, per-application counters | P3 | Commercial signal — tell the account manager *before* the customer notices |
| JWKS fetch failing | Gateway logs | P1 | Every request will 401 the moment cached keys expire. Genuinely confusing outage |

**The last row deserves emphasis** — it applies to Kong equally
([13](13-edge-gateway.md) §5). A gateway that cannot reach Keycloak keeps
working on cached signing keys until they rotate, then fails *everything* at
once, with no deploy and no obvious cause. Alert on the fetch, not on the
symptom.

### 5.3 Health checks

Gravitee's endpoint health-check is a *monitoring* feature and a *routing*
feature at the same time — a failing endpoint is taken out of the pool. Two
consequences:

1. **Point it at `/healthz`, not `/ready`, and never at a business endpoint.**
   A health check that exercises the database will eject every gateway node from
   the pool the moment the database has a slow minute.
2. **Alert on the health-check state changing**, not just on the current state.
   Flapping endpoints are the interesting signal; a steady-state graph hides them.

---

## 6. Procedure — the alert lifecycle

### 6.1 Severity, defined by response, not by feeling

| Sev | Definition | Route | Response |
|---|---|---|---|
| **P1** | Customer-visible loss of a critical journey, or regulatory breach risk | Page, 24×7 | Immediate, ack ≤5 min |
| **P2** | Degraded but working; or P1 imminent if untreated | Page in business hours, ticket out of hours | ≤1h |
| **P3** | Needs action this week; no customer impact | Ticket + Slack | Next working day |
| **P4** | Informational, trend | Dashboard only. **Never notifies** | — |

**The test for P1: would you wake a person for this?** If not, it is not P1.
Every alert routed to a pager that does not meet that bar trains the team to
ignore the pager — which is how a real P1 gets missed.

### 6.2 Every alert must carry these, enforced in CI

```yaml
- alert: PaymentServiceHighErrorBurn
  expr: |
    sum(rate(http_requests_total{service="payment-service",status=~"5.."}[5m]))
      / sum(rate(http_requests_total{service="payment-service"}[5m])) > 0.0144 * 0.01
  for: 2m
  labels:
    severity: critical        # → routing
    service: payment-service  # → ownership
    env: prod
  annotations:
    summary: "payment-service is burning error budget 14.4x"
    # WHAT THE RESPONDER DOES. Not what the alert measures.
    description: >-
      5xx rate over 5m implies the 30-day budget exhausts in ~2 days.
      Check recent deploys first (dashboard has deploy annotations).
    runbook_url: https://wiki.bank.internal/runbooks/payment-service-error-burn
    dashboard_url: https://grafana.bank.internal/d/payments/payment-service
```

**A CI check should fail any alert rule missing `severity`, `service`,
`runbook_url` and `summary`.** This is a five-line script and it prevents the
single most common on-call complaint: an alert nobody knows what to do with.

### 6.3 The lifecycle

| Phase | Action | Owner | Time |
|---|---|---|---|
| **Fire** | Alertmanager routes by `severity` + `service` | — | 0 |
| **Ack** | On-call acknowledges. Stops escalation. Does **not** mean fixed | On-call | ≤5m (P1) |
| **Triage** | Open the runbook. Check deploy annotations. Establish blast radius | On-call | ≤15m |
| **Communicate** | Post in the incident channel *before* you start fixing | Incident lead | ≤15m |
| **Mitigate** | Roll back, scale, fail over, flag off. **Restore service first** | On-call | — |
| **Resolve** | Alert clears on its own. Never "resolve" by silencing | — | — |
| **Review** | Blameless postmortem for P1/P2; alert-quality review for the rest | Team | ≤5 working days |

**"Restore service first, diagnose second"** is worth repeating because
engineers naturally invert it. The cause is still there in the logs an hour
later; the customers are not.

### 6.4 Silences and maintenance windows

- Silences are **always time-boxed** (max 24h) and **always carry a comment with
  a ticket reference**. An indefinite silence is a deleted alert with extra
  steps.
- Weekly: review active silences. Anything older than a week is a broken alert
  or a broken system — either way it needs a ticket, not another silence.
- Planned maintenance uses a **scheduled** silence created from the change
  ticket, not an ad-hoc one created at 02:00 by someone tired.

### 6.5 Alert quality review — monthly, 30 minutes

The one meeting that keeps monitoring healthy. For every alert that fired:

| Question | If the answer is bad |
|---|---|
| Did it require human action? | No → downgrade to P4 or delete |
| Was the runbook accurate? | No → fix the runbook *now*, in the meeting |
| Did it fire before customers noticed? | No → the threshold or the signal is wrong |
| Did it fire more than 3 times for one cause? | Yes → fix the grouping, or fix the system |

Track **alerts per on-call shift** as a real metric. If it rises above ~2
actionable pages per shift, stop feature work on the platform and fix it. Alert
fatigue is not a personality trait; it is a design defect.

---

## 7. Procedure — first 5 minutes of an incident

Print this. It is the whole point of the previous six sections.

```
1. ACK the page.                                        (stops escalation)
2. Open the runbook_url from the alert.
3. Answer: "what changed?"  → deploy annotations on the dashboard,
   ArgoCD sync history, recent MRs to the gitops repo.
4. Establish blast radius: one endpoint? one env? one region? all users?
5. POST IN THE CHANNEL before fixing:
      "P1 payment-service 5xx. Investigating. Suspect the 14:02 deploy.
       Next update 14:20."
6. Mitigate — in this order of preference:
      roll back  >  feature-flag off  >  scale out  >  fail over  >  code fix
7. Only after service is restored: find out why.
```

The 5-minute rule for step 5: **communicate before you understand.** A status
update saying "investigating, no cause yet" is more valuable to everyone else
than a perfect diagnosis 40 minutes later.

---

## 8. Verification drills

| # | Drill | Pass condition |
|---|---|---|
| 1 | Grep 24h of Loki for `password\|token\|Bearer ` | Zero results |
| 2 | Delete a Grafana dashboard in the UI | CI restores it on the next sync; or the UI refuses (`editable: false`) |
| 3 | Stop Grafana entirely | P1 metric alerts still page (they are in Alertmanager) |
| 4 | Stop the log backend for 10 min | No gap after recovery — collectors buffered |
| 5 | Fire a synthetic P1 | Page arrives ≤60s, on the right person, with a working runbook link |
| 6 | Try to delete an audit index as `log-shipper` | Denied |
| 7 | Block the gateway's egress to Keycloak | JWKS alert fires **before** tokens expire and requests start failing |
| 8 | Rebuild Grafana from scratch | All dashboards, datasources and alert rules return from git within 10 min |
| 9 | Pick a random alert from the last month; follow its runbook literally | It works, with no undocumented steps |
| 10 | Ask an engineer to find one request's full story from a `request_id` | Log → trace → metric, under 2 minutes |

Drills 8, 9 and 10 fail most often. Drill 9 in particular: runbooks rot faster
than code because nothing compiles them.

---

## 9. Never do this

1. Configure a dashboard, datasource or alert rule in a UI and leave it there.
2. Label a Loki stream or a Prometheus metric with `request_id`, `user_id`,
   `trace_id` or a full URL path.
3. Copy every log line into both tiers "to be safe".
4. Route a P4 to a pager.
5. Silence an alert indefinitely, or resolve an alert by silencing it.
6. Rely on Grafana as the only thing that can page.
7. Put a raw PAN, token, password or national ID in a log line — including in
   an exception stack trace, which is where it usually happens.
8. Point a gateway health-check at an endpoint that touches the database.
9. Let an ILM policy delete audit data. Deletion is ticketed and approved.
10. Ship an alert without a `runbook_url`.

---

## 10. Implementation map

| Concept | Location |
|---|---|
| Collector on VMs (rsyslog TLS, disk-assisted queue, PII redaction) | `infra/ansible/roles/observability_agents/` |
| Prometheus alert rules for the reference service | `gitops/business/payment-service/base/prometheusrule.yaml` |
| ServiceMonitor with canary-hash relabeling | `.../base/servicemonitor.yaml` |
| SLO definition template | `apps/payment-service/docs/slo.md` |
| Runbook template, incident flow, break-glass | `docs/09-runbooks.md` |
| Alerting design and retention matrix | `docs/06-observability.md` §4, §7 |
| Backup immutability (object lock) behind audit retention | `docs/07-backup-dr.md` |

> **Gaps to close before this procedure is real:**
> - `observability/grafana/{provisioning,dashboards,terraform}/` — does not exist yet.
> - `observability/kibana/saved-objects.ndjson` + the CI import step — does not exist yet.
> - The CI check that fails alert rules missing `runbook_url` (§6.2) — not written.
>
> Each is small. The Grafana provisioning tree is the highest-value one: it turns
> "we have dashboards" into "we can rebuild our observability from git".
