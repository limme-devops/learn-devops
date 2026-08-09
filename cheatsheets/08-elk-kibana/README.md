# ELK / Kibana Cheat Sheet

Elasticsearch, ingest (Beats / Logstash / Elastic Agent), ILM, KQL, Kibana,
log hygiene.

---

## 1. The stack

```
app (stdout, JSON) ─► Filebeat / Fluent Bit ─┐
host logs, auditd  ─►                        ├─► [Logstash or ingest pipeline]
network / gateway  ─►                        │        parse, enrich, redact
                                             ▼
                                       Elasticsearch  ──► Kibana
                                        (data streams,
                                         ILM: hot/warm/cold/frozen/delete)
```

Loki is the lighter alternative: it indexes only labels and stores compressed log
chunks, so it is far cheaper but can't do full-text search or aggregation over
message content. **Rule of thumb:** ELK when you need search, correlation and
retention as *evidence* _(regulated)_; Loki when you mostly grep by label and
care about cost.

---

## 2. Elasticsearch concepts

| Term | Meaning |
|---|---|
| Index / data stream | Logical collection. Time-series logs should use **data streams** (`logs-app-prod`), not manually rolled indices |
| Shard | A Lucene index. Primary + replicas. Immutable segments merged in the background |
| Document | One JSON event |
| Mapping | Field types. `text` = analysed for search; `keyword` = exact, aggregatable |
| ILM | Lifecycle: hot → warm → cold → frozen → delete |
| Node roles | master, data_hot/warm/cold, ingest, ml, coordinating |

**Shard sizing** is the whole capacity conversation: aim for **10–50 GB per
shard**, and keep total shards per node under ~20 per GB of heap. Thousands of
tiny shards is the most common self-inflicted Elasticsearch outage — each shard
costs heap and file handles regardless of how little data it holds.

**Heap:** ≤ 31 GB (above that you lose compressed object pointers), and no more
than half of RAM — the rest is the OS page cache Lucene depends on.

---

## 3. Operations (`_cat` and friends)

```bash
curl -s localhost:9200/_cluster/health?pretty
curl -s "localhost:9200/_cat/nodes?v&h=name,node.role,heap.percent,cpu,load_1m,disk.used_percent"
curl -s "localhost:9200/_cat/indices?v&s=store.size:desc&h=index,health,docs.count,store.size,pri,rep"
curl -s "localhost:9200/_cat/shards?v&s=state" | grep -v STARTED
curl -s "localhost:9200/_cat/thread_pool/write?v&h=node_name,active,queue,rejected"
curl -s localhost:9200/_cluster/allocation/explain?pretty      # why is a shard UNASSIGNED
curl -s localhost:9200/_nodes/stats/jvm?pretty | jq '.nodes[].jvm.mem.heap_used_percent'

# hot threads when the cluster is pegged
curl -s "localhost:9200/_nodes/hot_threads?threads=3"

# index lifecycle / templates
curl -s localhost:9200/_ilm/policy/logs-policy?pretty
curl -s localhost:9200/_index_template/logs-app?pretty
curl -XPOST localhost:9200/logs-app-prod/_rollover?pretty
```

**Cluster status meanings:** green = all primaries and replicas assigned; yellow
= replicas unassigned (usually a single-node cluster or a lost node — data is
safe, resilience isn't); red = a **primary** is unassigned, meaning you are
losing writes or reads for that shard. Red is an incident.

---

## 4. Index template + ILM

```json
PUT _index_template/logs-app
{
  "index_patterns": ["logs-app-*"],
  "data_stream": {},
  "priority": 200,
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 1,
      "index.lifecycle.name": "logs-policy",
      "index.codec": "best_compression",
      "index.refresh_interval": "10s"
    },
    "mappings": {
      "dynamic": "strict",
      "properties": {
        "@timestamp":       { "type": "date" },
        "service.name":     { "type": "keyword" },
        "log.level":        { "type": "keyword" },
        "trace.id":         { "type": "keyword" },
        "http.response.status_code": { "type": "short" },
        "message":          { "type": "text" },
        "user.id":          { "type": "keyword", "index": false }
      }
    }
  }
}
```

```json
PUT _ilm/policy/logs-policy
{
  "policy": { "phases": {
    "hot":   { "actions": { "rollover": { "max_primary_shard_size": "30gb", "max_age": "1d" } } },
    "warm":  { "min_age": "7d",  "actions": { "shrink": { "number_of_shards": 1 },
                                              "forcemerge": { "max_num_segments": 1 },
                                              "set_priority": { "priority": 50 } } },
    "cold":  { "min_age": "30d", "actions": { "searchable_snapshot": { "snapshot_repository": "s3-logs" } } },
    "delete":{ "min_age": "400d","actions": { "delete": {} } }
  }}
}
```

`dynamic: "strict"` is the single best defence against **mapping explosion** —
one service logging a map of arbitrary keys creates thousands of fields, which
degrades the whole cluster. Strict mapping fails the document instead; use
`dynamic: false` if you'd rather store-and-not-index the unknowns.

_(regulated)_ Retention is a compliance input, not a cost decision: audit and
transaction logs often have a mandated minimum (commonly 1–7 years), so the
`delete` phase must be justified in writing, and cold/frozen tiers plus
searchable snapshots are how you afford it. Snapshots for those tiers should be
in a **write-once / object-lock** bucket so ransomware or a rogue admin can't
delete the evidence.

---

## 5. Shipping logs

### Filebeat / Fluent Bit (Kubernetes)

```yaml
# filebeat DaemonSet essentials
filebeat.inputs:
  - type: container
    paths: ["/var/log/containers/*.log"]
    processors:
      - add_kubernetes_metadata: { host: ${NODE_NAME} }
      - drop_event: { when: { equals: { kubernetes.namespace: "kube-system" } } }
      - decode_json_fields:
          fields: ["message"]
          target: ""              # promote app JSON to top-level fields
          overwrite_keys: true
output.elasticsearch:
  hosts: ["https://es:9200"]
  index: "logs-%{[kubernetes.labels.app]}-%{[agent.version]}"
```

### Logstash (when you need heavy transformation)

```ruby
filter {
  json    { source => "message" }
  date    { match => ["ts", "ISO8601"] target => "@timestamp" }
  mutate  { remove_field => ["password","authorization","card_number","cvv"] }
  grok    { match => { "msg" => "%{IP:client} %{WORD:method} %{URIPATH:path}" } }
  ruby    { code => 'event.set("pan_masked", event.get("pan").to_s.gsub(/\d(?=\d{4})/,"*"))' }
}
output { elasticsearch { hosts => ["https://es:9200"] data_stream => true } }
```

Logstash gives you a persistent queue and rich filters at the cost of another JVM
fleet. Prefer **Elasticsearch ingest pipelines** for light parsing (they run in
the cluster and need no extra tier), and reach for Logstash when you need
buffering, fan-out to multiple destinations, or enrichment against an external
lookup.

Backpressure matters: a log pipeline must **never** block or crash the
application. Filebeat/Fluent Bit buffer to disk and drop with a metric when full.
Alert on the drop counter — silent log loss during an incident is the worst
possible failure.

---

## 6. Log hygiene — the part that gets you audited

- **Structured JSON, one event per line**, to stdout. Never write log files
  inside a container and never log multi-line stack traces unstructured (or
  configure multiline handling at the shipper).
- **ECS field names** (`service.name`, `log.level`, `trace.id`,
  `http.response.status_code`) so dashboards and correlation work across teams.
- **Include `trace.id` / `X-Request-ID`** from the gateway in every log line.
  This is what turns three tools into one investigation.
- **Never log**: passwords, tokens, full card numbers (PAN), CVV, full
  authorization headers, national ids, session cookies, full request bodies on
  payment endpoints. Redact at the shipper *and* fix the source — the shipper is
  a safety net, not a design.
- **Sample** high-volume success logs; keep 100% of errors and all security
  events.
- _(regulated)_ Audit and security logs go to a **separate, append-only index
  with restricted access** — the people whose actions are logged must not be able
  to delete the logs.

---

## 7. Kibana / KQL

```
service.name:"payment" and log.level:"ERROR"
http.response.status_code >= 500 and not url.path:"/healthz"
message:*timeout* and @timestamp >= now-15m
trace.id:"4bf92f3577b34da6a3ce929d0e0e4736"
user.id:("u1" or "u2")
_exists_:error.stack_trace
```
KQL is the default; Lucene syntax (`AND`, `OR`, `field:value~2`) is available via
the toggle. `*` leading wildcards are extremely expensive — avoid on `text`
fields at scale.

Kibana areas to know:
- **Discover** — ad-hoc search; save searches and reuse them in dashboards.
- **Dashboards / Lens** — visualisations over aggregations.
- **Data views** (formerly index patterns) — what fields are queryable.
- **Alerting** — threshold and query rules → connectors (Slack, PagerDuty,
  webhook, ServiceNow). Log-based alerts complement metric alerts: "audit log
  shows a role binding change outside a change window" is not a Prometheus query.
- **Spaces + RBAC** _(regulated)_ — per-team spaces, document-level and
  field-level security so support can search logs without seeing PII fields.
- **SIEM / Security app** — detection rules over the same data; the natural home
  for Falco and auditd events.

Query DSL when KQL isn't enough:
```json
GET logs-app-*/_search
{
  "size": 0,
  "query": { "bool": {
      "filter": [ { "range": { "@timestamp": { "gte": "now-1h" } } },
                  { "term":  { "service.name": "payment" } } ],
      "must_not": [ { "term": { "url.path": "/healthz" } } ] } },
  "aggs": { "by_status": { "terms": { "field": "http.response.status_code" } } }
}
```

---

## 8. Performance and troubleshooting

| Symptom | Cause / fix |
|---|---|
| Cluster **red** | Unassigned primary — `_cluster/allocation/explain`. Disk watermark, node loss, corrupt shard |
| Cluster **yellow** on a 1-node cluster | Replicas can't be assigned. Normal in a lab; set `number_of_replicas: 0` |
| Writes rejected (429) | Write thread pool queue full — too many small bulk requests, or too few hot nodes |
| Search slow | Too many shards, leading wildcards, `text` aggregation, no filter on `@timestamp` |
| Disk filling fast | ILM not applied (check the template priority), or a debug-level log flood |
| Field count explosion | Dynamic mapping + a service logging arbitrary keys. `dynamic: strict` |
| Nodes leaving the cluster | Long GC pauses (heap too big/too full) or network timeouts |
| Kibana "shard failures" | One index in the data view has a conflicting field type — the classic result of two services using the same field name differently |

Watermarks: `low 85%` (stop allocating new shards) → `high 90%` (relocate away)
→ `flood_stage 95%` (indices go **read-only** — and they don't come back
automatically; you must reset `index.blocks.read_only_allow_delete`).

Bulk indexing tips: batch 5–15 MB per bulk request, increase
`refresh_interval` during heavy ingest, use `best_compression` for logs, and
prefer more smaller bulk requests over one giant one.

---

## 9. Security _(regulated)_

- TLS everywhere: transport (node-to-node) and HTTP. Enabled by default in 8.x —
  do not turn it off to "simplify".
- Authentication + RBAC; no anonymous access; Kibana behind SSO.
- Field-level and document-level security so a support role can search without
  reading PII.
- Snapshots to object storage with **object lock / immutability**, and a
  restore that has been drilled and timed.
- Audit logging enabled on the cluster itself.
- Never expose 9200 beyond the platform network; Kibana is the only user-facing
  entry point.

---

## 10. Best practices checklist

- [ ] Apps log structured JSON to stdout, ECS field names, with `trace.id`
- [ ] Data streams + index templates + ILM, not hand-rolled daily indices
- [ ] `dynamic: strict` (or `false`) — mapping explosion is prevented, not monitored
- [ ] Shards 10–50 GB; total shard count per node bounded
- [ ] Heap ≤ 31 GB and ≤ 50% of RAM
- [ ] Secrets/PII redacted at the shipper *and* removed at the source
- [ ] Log pipeline cannot block the app; drop metrics are alerted on
- [ ] Retention encoded in ILM and justified against the compliance requirement
- [ ] Audit/security logs in a separate append-only index with restricted access
- [ ] Snapshots to immutable storage; restore drilled
- [ ] TLS + RBAC + SSO; 9200 never exposed
- [ ] Kibana dashboards and alert rules exported to Git (saved objects API) so they survive the cluster

➡ [Interview Q&A](interview-qna.md)
