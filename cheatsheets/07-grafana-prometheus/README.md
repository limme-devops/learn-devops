# Grafana & Prometheus Cheat Sheet

Metrics, PromQL, recording and alerting rules, dashboards, SLOs, burn rates.

Companion: [docs/06-observability.md](../../docs/06-observability.md).

---

## 1. The stack

```
app /metrics ──scrape──► Prometheus ──remote_write──► Mimir/Thanos (long term)
                            │  rules
                            ├──► recording rules  (pre-computed series)
                            └──► alerting rules ──► Alertmanager ──► PagerDuty/Slack
                            ▲
Grafana ────────────────────┘  (also queries Loki for logs, Tempo for traces)
```

Prometheus **pulls**. Push only via the Pushgateway for batch jobs that die
before a scrape — and that gateway is a stateful liability, so keep it small.

---

## 2. Metric types

| Type | Semantics | Query with |
|---|---|---|
| **Counter** | Monotonic, resets to 0 on restart | `rate()`, `increase()` — **never** the raw value |
| **Gauge** | Goes up and down | Raw value, `avg_over_time`, `delta` |
| **Histogram** | Bucketed observations (`_bucket`, `_sum`, `_count`) | `histogram_quantile()` |
| **Summary** | Client-computed quantiles | Cannot be aggregated across instances — prefer histograms |

Naming: `<namespace>_<subsystem>_<name>_<unit>_total`, e.g.
`http_server_requests_seconds_count`. Base units (seconds, bytes), `_total`
suffix on counters. Consistency matters more than beauty — dashboards break on
renames.

**Cardinality is the cost model.** Every unique label-value combination is a
time series in memory. Never put user ids, request ids, emails, full URLs or raw
error messages in a label. `path="/users/12345"` is a self-inflicted outage;
`path="/users/:id"` is a metric.

---

## 3. PromQL

```promql
# --- rates and errors ---
rate(http_requests_total[5m])                        # per-second, handles resets
sum by (service) (rate(http_requests_total[5m]))
sum(rate(http_requests_total{status=~"5.."}[5m]))
  / sum(rate(http_requests_total[5m]))               # error ratio

# --- latency from a histogram ---
histogram_quantile(0.99,
  sum by (le, service) (rate(http_request_duration_seconds_bucket[5m])))

# --- saturation ---
100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes
predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 4*3600) < 0

# --- kubernetes ---
sum by (namespace) (kube_pod_container_resource_requests{resource="cpu"})
rate(container_cpu_cfs_throttled_periods_total[5m])          # CPU limit pain
kube_pod_container_status_restarts_total > 3
rate(container_cpu_usage_seconds_total{container!=""}[5m])

# --- meta ---
up == 0                                              # target down
count(count by (__name__)({__name__=~".+"})) # metric-name count (cardinality audit)
topk(10, count by (__name__)({__name__=~".+"}))
```

Operators and gotchas:

| Thing | Note |
|---|---|
| `rate` vs `irate` | `rate` = average over the window (use in alerts/graphs); `irate` = last two samples (spiky, debugging only) |
| `rate` vs `increase` | `increase(x[5m]) == rate(x[5m]) * 300`. Same data |
| Range must be ≥ 4× scrape interval | Otherwise `rate()` sees too few points and goes empty at the worst moment |
| `sum(rate(...))` not `rate(sum(...))` | Always rate *before* aggregating — sum first hides counter resets |
| `by` / `without` | `by` keeps only listed labels; `without` drops listed ones |
| Vector matching | `on(label)` / `ignoring(label)`, `group_left` for many-to-one joins |
| `offset 1w` / `@ end()` | Compare to last week; pin evaluation time |
| `absent()` / `absent_over_time()` | Alert when a metric *stops existing* — the alert nobody writes until they need it |

```promql
# join a metric to metadata (classic group_left)
sum by (pod) (rate(container_cpu_usage_seconds_total[5m]))
  * on(pod) group_left(owner_name) kube_pod_owner
```

---

## 4. Scrape config and relabeling

```yaml
scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs: [{ role: pod }]
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
    metric_relabel_configs:
      - source_labels: [__name__]           # drop a cardinality bomb at ingest
        action: drop
        regex: "go_gc_duration_seconds.*"
```
`relabel_configs` runs **before** the scrape (decides targets and labels);
`metric_relabel_configs` runs **after** (drops or rewrites returned series). Use
the second one to kill high-cardinality metrics you don't own.

With the Prometheus Operator, prefer `ServiceMonitor`/`PodMonitor` CRDs:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata: { name: api, labels: { release: kube-prometheus-stack } }
spec:
  selector: { matchLabels: { app: api } }
  endpoints: [{ port: http, path: /metrics, interval: 30s }]
```

---

## 5. Recording and alerting rules

```yaml
groups:
  - name: api.recording
    interval: 30s
    rules:
      - record: job:http_requests:rate5m
        expr: sum by (job) (rate(http_requests_total[5m]))
      - record: job:http_errors:ratio_rate5m
        expr: |
          sum by (job) (rate(http_requests_total{status=~"5.."}[5m]))
          / sum by (job) (rate(http_requests_total[5m]))

  - name: api.alerts
    rules:
      - alert: ApiHighErrorRate
        expr: job:http_errors:ratio_rate5m{job="api"} > 0.01
        for: 5m                          # ← suppresses the flap
        labels: { severity: page, team: payments }
        annotations:
          summary: "api error ratio {{ $value | humanizePercentage }}"
          runbook_url: "https://wiki/runbooks/api-high-error-rate"
          dashboard_url: "https://grafana/d/api"
```

Recording rules exist for two reasons: expensive dashboard queries become cheap,
and alert expressions become readable and consistent with the dashboards. Naming
convention: `level:metric:operations`.

**Every alert must have**: a `for:` duration, a severity, an owning team, a
runbook link, and a reason it's worth waking someone. An alert without a runbook
is a page that ends in "I don't know, let's watch it".

```bash
promtool check rules rules.yml
promtool test rules tests.yml       # unit-test alerts — yes, really
promtool query instant http://prom:9090 'up == 0'
```

---

## 6. SLOs and burn-rate alerting

Alert on **symptoms users feel** (error budget burn), not causes (CPU 90%).

```
SLO: 99.9% of requests succeed over 30 days
Error budget = 0.1% of requests
Burn rate = (observed error ratio) / (1 - SLO)      # 1.0 = exactly on budget
```

Multi-window, multi-burn-rate — the standard Google SRE pattern:

| Alert | Burn rate | Windows | Budget consumed | Action |
|---|---|---|---|---|
| Fast | 14.4× | 5m **and** 1h | 2% in 1h | Page |
| Slow | 6× | 30m **and** 6h | 5% in 6h | Page |
| Trickle | 3× | 2h **and** 1d | 10% in 1d | Ticket |
| Slow trickle | 1× | 6h **and** 3d | — | Ticket |

```yaml
- alert: ApiErrorBudgetFastBurn
  expr: |
    (job:http_errors:ratio_rate5m{job="api"} > 14.4 * 0.001)
    and
    (job:http_errors:ratio_rate1h{job="api"} > 14.4 * 0.001)
  for: 2m
  labels: { severity: page }
```
The short window makes it fast; the long window stops a 30-second blip from
paging. Requiring both is the whole trick.

---

## 7. Alertmanager

```yaml
route:
  group_by: [alertname, cluster, namespace]   # NOT by instance — that's a page storm
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: slack-default
  routes:
    - matchers: [severity="page"]
      receiver: pagerduty
      continue: false
inhibit_rules:
  - source_matchers: [severity="page", alertname="ClusterDown"]
    target_matchers: [severity=~"page|warn"]
    equal: [cluster]                          # cluster down ⇒ suppress the rest
receivers:
  - name: pagerduty
    pagerduty_configs: [{ service_key_file: /etc/am/pd-key }]
```

```bash
amtool alert query
amtool silence add alertname=ApiHighErrorRate --duration=2h --comment "change CHG-123"
amtool config routes test severity=page team=payments   # which receiver would fire?
```

Inhibition and grouping are what keep an incident from producing 400 notifications.
Silences must carry a comment and an expiry — an unexplained permanent silence is
how outages get missed.

---

## 8. Grafana

- **Provision everything as code**: datasources and dashboards from ConfigMaps or
  files, not clicked in the UI. `grafana.com/dashboards` JSON in Git, imported by
  the sidecar. UI-created dashboards vanish with the pod.
- **Variables**: `$namespace`, `$service`, `$__rate_interval` (use this instead of
  a hardcoded `[5m]` — it adapts to the panel's time range and scrape interval).
- **Dashboard hierarchy**: one *overview* per service showing the four golden
  signals (traffic, errors, latency, saturation), then drill-down dashboards.
  Twenty panels of everything is a dashboard nobody reads at 3am.
- **Alerting**: prefer Prometheus rules over Grafana-managed alerts — the rules
  live in Git next to the recording rules and evaluate even if Grafana is down.
- **Auth** _(regulated)_: SSO via OIDC, no local admin, viewers by default,
  editors per team folder. Datasources use read-only credentials.
- **Loki/Tempo**: derived fields link a trace id in a log line straight to the
  trace, and exemplars link a latency histogram bucket to a sample trace. That
  chain — dashboard → log → trace — is what makes an incident 5 minutes instead
  of 50.

```
Golden signals per service panel row:
  Traffic     sum(rate(http_requests_total[$__rate_interval]))
  Errors      error ratio, plus a 5xx-by-route table
  Latency     p50 / p95 / p99 from the histogram
  Saturation  CPU throttling, memory vs limit, connection pool, queue depth
```

---

## 9. Operating Prometheus

| Concern | Guidance |
|---|---|
| Retention | 15–30d local; long term to Thanos/Mimir via `remote_write`. Local disk is the failure mode |
| HA | Two identical Prometheus replicas scraping the same targets; dedupe at Thanos Querier/Alertmanager |
| Memory | Roughly proportional to active series. Cardinality is your capacity plan |
| Federation | Don't use it to build a global view — `remote_write` to Mimir/Thanos instead |
| Backups | Local TSDB is disposable if remote storage exists; rules and dashboards live in Git |
| Sharding | `hashmod` relabeling across replicas when a single instance can't hold the series |

Health queries: `prometheus_tsdb_head_series` (cardinality),
`rate(prometheus_target_scrapes_exceeded_sample_limit_total[5m])`,
`prometheus_rule_group_last_duration_seconds` (rules slower than the interval =
silently skipped evaluations), `up`.

---

## 10. Best practices checklist

- [ ] Every service exposes `/metrics` with RED signals; infra has USE signals
- [ ] No unbounded label values — cardinality reviewed before merge
- [ ] Histograms, not summaries, for latency
- [ ] Recording rules for anything a dashboard or alert queries repeatedly
- [ ] Alerts are symptom-based, with `for:`, severity, owner and a runbook link
- [ ] SLOs defined per service with multi-window burn-rate alerts
- [ ] Alertmanager grouping + inhibition tuned; silences require a comment and expiry
- [ ] Dashboards provisioned from Git; `$__rate_interval` not hardcoded windows
- [ ] Alert rules unit-tested with `promtool test rules` in CI
- [ ] Long-term storage configured; local retention is not your archive
- [ ] Prometheus itself monitored (a dead Prometheus is a silent one) — plus a dead-man's-switch alert that pages if it *stops* firing

➡ [Interview Q&A](interview-qna.md)
