# Microservices — Design & Operational Concerns

## 1. When NOT to use microservices

Start with a modular monolith unless you have: independent scaling needs, independent release cadence per team, or hard team-boundary reasons. Microservices trade in-process calls (fast, reliable, transactional) for network calls (slow, unreliable, eventually consistent) plus N× the operational surface. In a bank, that trade also multiplies your audit scope. Split only where a boundary genuinely exists.

## 2. Service boundaries

- Boundaries follow **business capabilities / DDD bounded contexts**, not technical layers. `payments`, `accounts`, `cards`, `onboarding` — not `controller-service`, `db-service`.
- **One database per service.** No shared schema, no cross-service joins, no other service reading your tables. This is the rule that makes the rest possible; violating it produces a distributed monolith.
- Each service owns: its data, its API contract, its deploy pipeline, its SLO, its on-call rotation, its runbook.
- Size heuristic: a team of 4–8 can own it; a rewrite would take weeks, not months.

## 3. Communication

| Pattern | Use for | Tool |
|---|---|---|
| Sync request/response | Query needing an immediate answer, user-facing reads | REST/gRPC over mTLS |
| Async events | State changes others react to, decoupling, buffering | Kafka |
| Async commands | Work handoff | Kafka / queue |
| Orchestrated saga | Multi-service business transactions | explicit orchestrator service |

**Never** do a synchronous call chain more than 2 deep for a user request. Each hop multiplies latency and failure probability (5 services at 99.9% each = 99.5% combined).

**Distributed transactions:** there are none. Use the **Saga pattern** with compensating actions, and make every step **idempotent** (idempotency key on every mutating endpoint and message handler). For financial operations, use the **Outbox pattern**: write the state change and the event to the DB in one local transaction, and publish the event from the outbox table with a relay. This is how you avoid "money moved but the event was lost".

**Contracts:** OpenAPI/protobuf/Avro schemas versioned in Git, backward-compatible changes only, consumer-driven contract tests (Pact) in CI. Breaking change = new version path, both running until consumers migrate.

## 4. Resilience patterns (mandatory in prod)

| Pattern | Purpose | Setting |
|---|---|---|
| **Timeout** | never wait forever | every outbound call, budget < caller's own SLO |
| **Retry with jitter** | survive transient blips | max 2–3 retries, exponential backoff + jitter, only on idempotent ops |
| **Circuit breaker** | stop hammering a dead dependency | open at 50% failures over 20 requests, half-open probe after 30s |
| **Bulkhead** | one slow dependency must not consume all threads/connections | separate connection pools per dependency |
| **Rate limit / load shed** | protect yourself | at gateway + in-service, return 429 with `Retry-After` |
| **Graceful degradation** | partial service beats none | serve cached/limited data when a non-critical dep is down |
| **Backpressure** | don't accept work you can't do | bounded queues, consumer lag alerts |

**Retry storms** are a classic self-inflicted outage: retries amplify load on an already-struggling service. Always pair retries with a circuit breaker and a global retry budget.

## 5. Kubernetes concerns per microservice

Every service ships with:
- `Deployment` (or `Rollout`) with resource requests/limits, probes, security context (see `03-security-baseline.md`)
- `Service`, `ServiceAccount`, `NetworkPolicy` (allow only its actual callers and callees)
- `HorizontalPodAutoscaler` — scale on a meaningful signal (RPS or queue depth via KEDA, not just CPU)
- `PodDisruptionBudget` (`minAvailable: 51%`) so node drains don't take the service down
- `ExternalSecret` for its credentials
- `ServiceMonitor` + `PrometheusRule` (its SLO alerts)
- `topologySpreadConstraints` across nodes/zones

**Graceful shutdown is where most "random 502s" come from:**
```yaml
terminationGracePeriodSeconds: 60
lifecycle:
  preStop:
    exec: { command: ["sleep", "10"] }   # let endpoints propagate before the process dies
```
The app must catch `SIGTERM`, stop accepting new requests, finish in-flight work, close DB connections, then exit.

## 6. Service mesh — decide deliberately

Adopt a mesh (Istio ambient / Linkerd) **only if** you need: automatic mTLS everywhere, L7 authorization policy, uniform retries/timeouts without touching code, or fine-grained traffic shifting across many services. Otherwise NetworkPolicy + app-level TLS + a library (Resilience4j/Polly) is less to operate and less to break at 03:00.

If you do adopt one: start with mTLS only, add policy later, and understand the failure mode of the sidecar/proxy before it's in prod.

## 7. Cross-cutting requirements checklist

Before any microservice reaches prod, it must have:

- [ ] `/healthz` (liveness — is the process alive) and `/ready` (readiness — can it serve, including deps) — **and they must differ**
- [ ] `/metrics` with RED metrics, correct metric types, controlled cardinality
- [ ] Structured JSON logs with `trace_id` propagation, no sensitive fields
- [ ] OpenTelemetry tracing with context propagated to DB, HTTP, and Kafka calls
- [ ] OpenAPI contract published and versioned
- [ ] Idempotency on all mutating endpoints
- [ ] Timeouts + circuit breaker on every outbound dependency
- [ ] Documented SLO + error budget owner
- [ ] Runbook with the top 5 failure modes and their mitigations
- [ ] Threat model reviewed by Security
- [ ] Backup/restore path for its data, tested
- [ ] Load-test result showing it meets its latency SLO at 2× expected peak
- [ ] Rollback procedure, tested in UAT

## 8. Data consistency in a banking context

- Money movements must be **idempotent, auditable, and reconcilable**. Every transaction gets a unique business ID, an immutable ledger entry, and a daily reconciliation job that alerts on mismatch.
- Prefer **event sourcing / append-only ledger** for financial state. Never `UPDATE` a balance in place without an accompanying immutable journal entry.
- Eventual consistency is acceptable for read models and notifications; it is **not** acceptable for authorization checks or balance-affecting decisions — those need a strongly consistent read against the owning service.
- Reconciliation is a first-class service, not a script someone runs. Alert on drift within minutes, not at end of day.
