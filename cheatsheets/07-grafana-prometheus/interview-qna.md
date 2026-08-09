# Grafana & Prometheus — Interview Q&A

> **Author:** Mengty LIM

---

## Fundamentals

**Q1. Why does Prometheus pull instead of push?**
Pull gives you target discovery as a first-class concept — the scrape config
knows what *should* exist, so a missing target is detectable (`up == 0`), whereas
with push a silent service is indistinguishable from a healthy quiet one. It also
puts rate limiting on the collector side, makes targets trivially debuggable
(curl `/metrics` yourself), and avoids every app needing collector credentials.
The exception is short-lived batch jobs that finish between scrapes: those push
to a Pushgateway, which you keep small because it's a stateful component that
will happily serve stale metrics forever.

**Q2. Counter, gauge, histogram, summary — and which for latency?**
Counter: monotonic, resets on restart, always query with `rate()`/`increase()`.
Gauge: current value, up and down. Histogram: bucketed counts plus sum and count,
quantiles computed at query time. Summary: quantiles computed in the client.
Latency should be a histogram, because summaries cannot be aggregated — averaging
per-instance p99s is mathematically meaningless, so the moment you have more
than one replica a summary stops answering the question you asked.

**Q3. Why is cardinality the thing you police?**
Every unique combination of label values is a separate time series held in
memory. A label with unbounded values — user id, request id, full URL, raw error
string — turns one metric into millions of series and takes Prometheus down,
which means you lose monitoring exactly when something is going wrong. The rules
I enforce: labels must have bounded, known-in-advance values; templated route
patterns not raw paths; and `metric_relabel_configs` drop rules for third-party
exporters you don't control. High-cardinality dimensions belong in logs or
traces, which are indexed differently for that reason.

**Q4. `rate` vs `irate` vs `increase`?**
`rate()` is the per-second average over the range, computed from the first and
last samples with extrapolation and counter-reset handling — this is what you use
in alerts and dashboards. `irate()` uses only the last two samples: very
responsive, very spiky, useful for interactive debugging and wrong in an alert.
`increase()` is `rate() × range` — same computation, different unit. And the
range must be at least four scrape intervals, otherwise the query goes empty
under load when scrapes get slow, which is the worst possible time.

**Q5. Why `sum(rate(x))` and never `rate(sum(x))`?**
`rate()` needs to see the individual counter series to detect resets. If you sum
first, a pod restarting looks like the aggregate counter dropping, and `rate()`
either misinterprets it or, in the aggregate, the reset is smeared across
series. Rate first, aggregate second — always.

---

## Alerting

**Q6. What makes a good alert?**
It's actionable, symptom-based, and owned. Symptom-based means it fires on
something a user experiences — error rate, latency, unavailability — not a cause
like "CPU > 90%", which may be perfectly fine. Actionable means there is a
documented thing to do, linked as a runbook. Owned means a team label routes it.
It also needs a `for:` duration so a transient blip doesn't page, and a severity
that distinguishes "wake someone" from "look at it Monday". The test I'd apply:
if the responder's only possible action is to acknowledge and watch, it should
not have been a page.

**Q7. Explain multi-window multi-burn-rate SLO alerting.**
You define an SLO — say 99.9% success over 30 days — which gives an error budget
of 0.1%. Burn rate is your observed error ratio divided by the budget rate: 1.0
means you'll exactly exhaust the budget at the end of the window, 14.4 means
you'll burn it in about 2 days. You then alert on combinations: a 14.4× burn
sustained over both a 5-minute *and* a 1-hour window pages immediately; a 3×
burn over 2 hours and 1 day opens a ticket. The short window gives detection
speed, the long window prevents a 30-second spike from paging, and requiring both
gives you good precision and recall simultaneously. It's better than a static
"error rate > 1%" threshold because it's tied to what you actually promised.

**Q8. How do you stop alert storms?**
Grouping in Alertmanager (by alertname/cluster/namespace, never by instance, or a
node failure produces one page per pod), inhibition rules so a cluster-down alert
suppresses the hundred downstream symptoms it causes, `for:` durations to kill
flapping, and alerting on aggregates rather than per-instance where possible.
Then the cultural half: every page is reviewed, and an alert that fires often
without action gets deleted or fixed. Alert fatigue is a reliability problem, not
a preference — an on-call who ignores pages is worse than no alerts.

**Q9. How do you know your monitoring is working?**
A dead-man's switch: an alert that always fires, routed to a receiver that pages
if it *stops* arriving (Alertmanager's Watchdog into a heartbeat service like
Dead Man's Snitch). Plus monitoring Prometheus itself from somewhere else,
`up == 0` alerts per job, `absent_over_time()` for metrics that should always
exist, and alerts on rule evaluation duration — rule groups that take longer than
their interval silently skip evaluations, so alerts stop firing with no error
anywhere.

---

## Design and scale

**Q10. Prometheus is OOMing. What do you do?**
Confirm it's cardinality: `prometheus_tsdb_head_series` and `topk(20, count by
(__name__)({__name__=~".+"}))` to find the offending metric, and `count by (job)`
to find the offending target. Short term, drop it with `metric_relabel_configs`
and, if needed, cut retention. Medium term, fix the source — usually a label with
an id in it — and add a `sample_limit` per scrape so a single bad deploy can't
take the server down. Long term, shard by service or team with hashmod
relabeling and push to Mimir/Thanos for long-term storage, so a single instance
holds fewer active series.

**Q11. How do you do HA and long-term storage?**
HA: two identical Prometheus replicas scraping the same targets, both feeding
Alertmanager (which deduplicates identical alerts by their labels), with queries
deduped by Thanos Querier. Long term: `remote_write` to Thanos or Mimir with
local retention of a couple of weeks, so the local TSDB becomes disposable and a
node loss isn't data loss. I'd explicitly avoid federation as a global-view
mechanism — it looks simple, but it's a scrape of a scrape, it drops data
silently under load, and it doesn't give you a queryable long-term archive.

**Q12. What's the difference between the RED and USE methods?**
RED — Rate, Errors, Duration — is for request-driven services and maps to the
user experience. USE — Utilization, Saturation, Errors — is for resources: CPU,
memory, disk, queues. You want both: RED to detect that users are having a bad
time, USE to explain why. A dashboard that has only USE will show you a busy
node and never tell you customers are getting 500s.

---

## Grafana

**Q13. How do you manage Grafana dashboards?**
As code, provisioned from Git — JSON in a ConfigMap picked up by the sidecar, or
Grafana's provisioning files, or Terraform/Grizzly. UI-edited dashboards are lost
when the pod restarts and have no review history, which for a bank means no
evidence of who changed the thing the auditor is asking about. I'd also keep
alerting in Prometheus rules rather than Grafana-managed alerts, so alerts live
next to the recording rules they depend on and keep evaluating if Grafana is down.

**Q14. What does a dashboard for on-call look like?**
One overview screen per service, above the fold: traffic, error rate, latency
percentiles, saturation, and current SLO burn — the four golden signals plus the
budget. Everything else is a drill-down linked from it. Template variables for
namespace/service so one dashboard serves every instance, `$__rate_interval`
instead of hardcoded ranges, and links out to the runbook, the logs (pre-filtered
to that service) and traces. The design constraint is that someone woken at 3am
should reach a hypothesis in under a minute; forty panels of everything fails
that test.

**Q15. How do metrics, logs and traces fit together?**
Metrics tell you *something is wrong* and are cheap enough to keep for everything.
Traces tell you *where* in a distributed request the time or the error went.
Logs tell you *what exactly happened* for one request. The value is in the links:
exemplars attach trace ids to histogram buckets, so you click a slow bucket and
land on a real slow trace; derived fields in Loki turn a trace id in a log line
into a link to Tempo; and a correlation id propagated from the gateway ties all
three to a customer complaint. Without the correlation id — set at the edge and
carried through — you have three tools and no thread between them.

**Q16. What would you monitor for a payments service specifically?**
The technical golden signals, plus business metrics that catch failures the
technical ones miss: payment success rate by provider, settlement lag, queue
depth of unprocessed transactions, and reconciliation mismatches. The failure mode
that motivates this: an upstream that returns HTTP 200 with a declined body looks
perfect on error-rate dashboards while every customer payment fails. A business
metric with an SLO catches it in minutes; a technical dashboard catches it when
someone phones support.
