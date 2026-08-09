# ELK / Kibana — Interview Q&A

> **Author:** Mengty LIM

---

## Elasticsearch

**Q1. Explain shards, replicas, and how you size them.**
An index is split into primary shards, each a self-contained Lucene index, and
each primary can have replicas for redundancy and read throughput. Shard count
per index is fixed at creation (you can only change it by reindexing or
shrinking), so it's a decision you live with. Target 10–50 GB per shard, and keep
total shards per node roughly under 20 per GB of heap. The failure people
actually hit is the opposite of what they fear: not shards too big, but thousands
of tiny daily indices, each costing heap and file handles, until the master node
can't hold the cluster state. Rollover on size via ILM rather than "one index per
day" fixes it.

**Q2. Cluster is yellow. Is that an outage?**
No — yellow means all primaries are assigned but some replicas aren't, so data is
intact and queryable but you've lost redundancy. Common on a single-node cluster
(where it's expected and you should set replicas to 0) or after a node leaves.
Red is the outage: a primary is unassigned, so part of your data is unreadable
and writes to that shard fail. For red, `_cluster/allocation/explain` tells you
why — usually disk watermark, a node that hasn't come back, or a shard that needs
manual allocation.

**Q3. What is mapping explosion and how do you prevent it?**
Dynamic mapping creates a field the first time it appears. A service that logs a
map of arbitrary keys — say, per-customer attributes — creates a field per key,
and field count degrades cluster state, memory and search performance for
everyone sharing that cluster. Prevention: `dynamic: "strict"` in the index
template so unexpected fields are rejected loudly at ingest, or
`dynamic: false` to store without indexing. Plus `index.mapping.total_fields.limit`
as a backstop. The related trap is a *field type conflict*: two services using
`user.id` as a keyword and a number, which produces "shard failures" in Kibana
for everyone querying the data view — which is why ECS naming isn't cosmetic.

**Q4. Why is heap capped at ~31 GB?**
Above roughly 32 GB the JVM can no longer use compressed ordinary object
pointers, so references double in size and you effectively get *less* usable
heap. And you should give Elasticsearch no more than half the machine's RAM,
because Lucene relies on the OS page cache for the segment files — starving the
page cache to feed the heap makes search slower, not faster.

**Q5. How does ILM work and how would you set retention for a bank?**
ILM moves an index through phases based on age or size: hot (actively written,
fast disks, rollover), warm (read-only, force-merged and shrunk, cheaper nodes),
cold or frozen (searchable snapshots backed by object storage), then delete.
For a bank the delete phase isn't a cost decision — audit and transaction logs
often carry a mandated minimum retention, so I'd separate streams by retention
class: application debug logs at 7–30 days, operational logs at 90, audit and
security events at whatever the regulation says, in a separate append-only index
with restricted access and snapshots in an object-locked bucket. Cheap tiers are
what make the long retention affordable.

---

## Ingest

**Q6. Beats vs Logstash vs ingest pipelines — when do you use which?**
Beats (or Fluent Bit) is the shipper: lightweight, runs as a DaemonSet, buffers
to disk, does light processing. Ingest pipelines run inside Elasticsearch and
handle most parsing without an extra tier — my default for grok/date/rename work.
Logstash earns its JVM fleet when you need a persistent queue in front of the
cluster, fan-out to multiple destinations (ES *and* the SIEM *and* an archive),
or enrichment against an external lookup. Adding Logstash "because that's what
the L stands for" is how people end up with a tier they can't justify.

**Q7. Elasticsearch is down. What happens to my application?**
Nothing, if the pipeline is built correctly — and that's the requirement I'd
state first. The shipper buffers to disk and, when the buffer fills, drops with a
counter you alert on. What must never happen is the logging path blocking or
crashing the app: I've seen a synchronous log appender to a remote endpoint take
down a service when the endpoint got slow. So: async appenders with a bounded
queue and a drop policy in the app, disk-buffered shipper on the node, and an
alert on drop rate — because silently losing logs during the incident you're
trying to debug is the worst version of this failure.

**Q8. How do you keep PII and secrets out of the logs?**
Defence in depth, and I'd be explicit that the shipper is a net, not the design.
At the source: a logging library configured to redact known-sensitive fields, code
review on log statements, and never logging request bodies on payment endpoints.
In the pipeline: `mutate remove_field` / redact processors for authorization
headers, tokens, PAN and CVV, and PAN masking for anything that must be retained.
In the platform: field-level security in Kibana so most roles can't read the
fields that do exist. Then detection: a scheduled query looking for card-number
patterns in `message`, because the one thing you can be sure of is that someone
will add a new log line.

---

## Kibana and use

**Q9. KQL query performance — what's expensive?**
Leading wildcards (`*timeout*`) on analysed text fields — they can't use the
inverted index efficiently and scan everything. Aggregating on a `text` field
(you want `keyword`). Querying without a time filter, so every index in the data
view is touched instead of a few. And very high-cardinality terms aggregations.
The cheap wins are: always bound by `@timestamp`, filter on `keyword` fields
first so the expensive full-text match runs on a smaller set, and use the filter
context rather than query context when you don't need scoring.

**Q10. ELK or Loki?**
Loki indexes only labels and stores compressed chunks, so it's dramatically
cheaper and integrates natively with Grafana and Prometheus labels — great when
your workflow is "filter by service and namespace, then grep". Elasticsearch
gives you real full-text search, aggregation over message content, and a mature
RBAC and SIEM story. For this platform I'd run Loki for application debugging
because of cost and the Grafana correlation, and Elasticsearch for audit,
security and anything with a retention mandate, where "we can search it and prove
who accessed it" is the requirement. What I wouldn't do is run both for the same
data.

**Q11. How do you correlate a customer complaint with logs and traces?**
The correlation id set at the gateway (`X-Request-ID`, echoed back to the client
so the customer can quote it), propagated as a header to every downstream
service, and emitted as `trace.id` in every log line. Then one Kibana query on
that id returns the whole request path, and a derived field links straight to the
trace. Without that id you're joining on timestamps and hoping — which works
right up until you have more than one request per second.

**Q12. What log-based alerts do you run that metrics can't give you?**
Security and audit conditions: a role binding or IAM policy change outside a
change window, a Vault policy change, repeated authentication failures for one
account, a privileged command on a production host, and any appearance of
card-number or secret patterns in log content. Also absence alerts — a service
that *stops* logging is usually more alarming than one logging errors. These are
conditions over content and identity, which metrics deliberately don't carry
because that's exactly the high-cardinality data you keep out of Prometheus.

**Q13. How do you make Kibana content survive a cluster rebuild?**
Export saved objects — data views, dashboards, visualisations, alert rules — via
the saved objects API and keep them in Git, then import as part of provisioning.
The same principle as Grafana dashboards: anything created by clicking is state
with no review history and no restore path. _(regulated)_ It's also the only way
to answer "who changed this detection rule and when".

**Q14. Writes are being rejected with 429. Diagnose it.**
That's the write thread pool queue full, so ingest is arriving faster than the
cluster can index. Check `_cat/thread_pool/write` for `rejected` counts per node
to see whether it's the whole cluster or one hot node with an unbalanced shard.
Usual causes: bulk requests too small (per-request overhead dominates — batch to
5–15 MB), too few hot-tier nodes, a refresh interval of 1s during a heavy backfill,
or one index taking all the writes because rollover isn't configured. Short term,
back off at the shipper (which it should do automatically) and raise the refresh
interval; longer term, add hot nodes or shard the write load.
