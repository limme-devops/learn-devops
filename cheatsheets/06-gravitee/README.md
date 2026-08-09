# Gravitee Cheat Sheet

API management (APIM), policies, plans and subscriptions, Access Management (AM).

> **Naming check.** This covers **Gravitee.io** — the open-source API management
> platform. If you meant Grafana dashboards, see
> [07-grafana-prometheus](../07-grafana-prometheus/); if you meant Graylog, the
> log-platform equivalents are in [08-elk-kibana](../08-elk-kibana/).

---

## 1. Gateway vs API management

Kong is a gateway with management bolted on. Gravitee is an **API management
platform** where the gateway is one component:

```
┌─────────────────────────────────────────────────────────┐
│  Management API + Management Console   (design, publish) │
│  Developer Portal                      (discover, subscribe)
│  Analytics (Elasticsearch)             (usage, billing)  │
└──────────────────────┬──────────────────────────────────┘
                       │ sync (poll or event)
              ┌────────▼────────┐
   client ───►│  APIM Gateway   │───► backend
              └─────────────────┘
      (stateless, horizontally scalable, holds no source of truth)
```

Pick Gravitee when the API is a **product exposed to third parties**: you need a
portal, self-service subscription with approval workflow, tiered plans, API
lifecycle stages and consumption analytics for billing. Pick Kong when you need
a fast programmable proxy in front of internal services and you'll manage
consumers in Git.

---

## 2. Core concepts

| Concept | Meaning |
|---|---|
| **API** | A published proxy definition: listener (context path/vhost), endpoints, flows |
| **Endpoint group** | Backends + load balancing + health check + failover |
| **Plan** | The contract: authentication type, rate limits, terms, approval mode |
| **Subscription** | A consumer application bound to a plan; issues the API key / client id |
| **Application** | The consumer-side registration (owned by a developer in the portal) |
| **Flow** | A set of policies scoped to a phase and condition |
| **Policy** | A single behaviour (rate limit, JWT validation, transform, cache) |
| **Sharding tags** | Which gateways an API deploys to — how you isolate zones/environments |
| **Environment / Organization** | Multi-tenancy above the API level |

**v4 APIs** add native event-driven support (Kafka, MQTT, WebSocket, SSE) and a
reworked policy engine; **v2** is the classic HTTP proxy model. Know which one
the job description means.

---

## 3. Plans — the concept Kong doesn't have

A Plan is the published contract. One API can expose several simultaneously:

| Plan type | Auth | Typical use |
|---|---|---|
| Keyless | none | Public read-only API |
| API Key | `X-Gravitee-Api-Key` | Server-to-server partners |
| OAuth2 | token introspection against an AS | Delegated user access |
| JWT | signature + claims validation | Machine-to-machine with an IdP |
| mTLS / Push | client certificate | Bank B2B _(regulated)_ |

Each plan carries its own rate limits, quotas, and a subscription mode
(`AUTO` or `MANUAL` approval). This is what lets you sell "Bronze: 1k
calls/day" and "Gold: 100k calls/day" without touching the API definition —
and why partner onboarding becomes a portal workflow instead of a ticket to the
platform team.

Plan lifecycle: `STAGING → PUBLISHED → DEPRECATED → CLOSED`. Closing a plan
terminates its subscriptions, so deprecating with an overlap window is how you
migrate consumers off an old contract.

---

## 4. Flows and policies

A flow = **phase** (request / response) + **condition** (EL expression) + an
ordered list of policies. Flows can be scoped at:

```
Platform (all APIs in the environment)
   └─ API level
        └─ Plan level          ← per-contract behaviour
             └─ Flow condition ← path / method / header matching
```

Execution: platform flows first, then API, then plan; within a flow, policies run
in list order. `Best match` vs `Best match with fallback` decides how path
selectors resolve.

Common policies:

| Purpose | Policy |
|---|---|
| AuthN | `jwt`, `oauth2`, `api-key`, `ssl-enforcement` |
| AuthZ | `role-based-access-control`, `resource-filtering` |
| Traffic | `rate-limit` (short burst), `quota` (long window), `spike-arrest` |
| Transform | `transform-headers`, `json-to-xml`, `assign-attributes`, `groovy` |
| Resilience | `circuit-breaker`, `retry`, `mock`, `latency` (fault injection) |
| Caching | `cache` (keyed on an EL expression — include identity!) |
| Validation | `json-validation`, `xml-validation`, `request-validation` (schema from OpenAPI) |
| Observability | `metrics`, `logging`, `assign-content` |

Expression Language appears everywhere:
```
{#request.headers['X-Tenant'][0] == 'retail'}
{#context.attributes['user'].email}
{#request.path matches '/v1/payments/.*'}
```

Gravitee reads OpenAPI directly: import a spec to create the API, and use
`request-validation` to reject anything that doesn't match the contract at the
gateway. That's a genuinely strong control — schema enforcement at the perimeter
without touching the service.

---

## 5. Deployment shape

```
management-api  ──► MongoDB / JDBC        (config source of truth)
                └─► Elasticsearch          (analytics + gateway logs)
gateway (N pods) ──► pulls config on interval (default 5s) or via event bus
management-ui, portal-ui  ──► static SPAs served behind the edge
```

Helm:
```bash
helm repo add graviteeio https://helm.gravitee.io
helm upgrade --install apim graviteeio/apim -n gravitee --create-namespace \
  -f values.yaml --atomic --wait
```
```yaml
# values.yaml (essentials)
mongo:  { uri: "mongodb://…" }          # or jdbc for Postgres
es:     { endpoints: ["https://es:9200"] }
gateway:
  replicaCount: 3
  sharding: { tags: "internal,prod" }   # this gateway only serves those APIs
  autoscaling: { enabled: true, minReplicas: 3, maxReplicas: 12 }
  services: { sync: { delay: 5000 } }
api:     { enabled: true }              # management API
ui:      { enabled: true }              # console
portal:  { enabled: true }
```

**Kubernetes-native option:** the Gravitee Kubernetes Operator lets you define
`ApiV4Definition` / `ApiDefinition` CRDs, so API config lives in Git and is
reconciled by ArgoCD like everything else — strongly preferred over clicking in
the console _(regulated)_, because the console is a mutable source of truth with
no review step.

```yaml
apiVersion: gravitee.io/v1alpha1
kind: ApiDefinition
metadata: { name: payment-api, namespace: gravitee }
spec:
  name: Payment API
  version: "1.0"
  proxy:
    virtual_hosts: [{ path: /v1/payments }]
    groups:
      - name: default
        endpoints: [{ name: primary, target: https://payment.app-payment.svc:8443 }]
  plans:
    - name: partner-gold
      security: JWT
      flows:
        - path-operator: { path: /, operator: STARTS_WITH }
          pre:
            - policy: rate-limit
              configuration: { rate: { limit: 100, periodTime: 1, periodTimeUnit: SECONDS } }
```

---

## 6. Sharding tags — the isolation primitive

Tag a gateway (`sharding.tags: internal,prod`) and tag an API; the API deploys
only to gateways carrying a matching tag. This is how you run one control plane
with separate DMZ-facing and internal gateways, or keep a PCI-scoped API on
dedicated nodes _(regulated)_. Getting tags wrong is how an internal API ends up
published on the internet-facing gateway — so tag assignment belongs in the
reviewed CRD, not the console.

---

## 7. Gravitee Access Management (AM)

A separate product: an IdP / OAuth2 + OIDC authorization server with
multi-factor, adaptive policies, identity provider federation (LDAP, SAML,
social) and a step-up flow engine. In this platform Keycloak fills that role; the
comparison to make in an interview is that AM integrates natively with APIM's
plans (token introspection, dynamic client registration), whereas Keycloak is
more widely deployed and has broader community support. Both speak standard
OIDC, so the gateway policy config is nearly identical.

---

## 8. Analytics and troubleshooting

Gateway logs and metrics land in Elasticsearch and are surfaced in the console
per API, plan, application and status code — which is what makes consumption
billing and "which partner is causing the 5xx" answerable without a separate
data pipeline. Retention is an ILM policy on those indices; full request/response
logging is *expensive* and, for a bank, a data-protection problem — enable it per
API, sampled, with body logging off by default.

| Symptom | Check |
|---|---|
| 404 from the gateway | Context path / virtual host mismatch, or the API is not deployed to that gateway's sharding tag |
| Config change not live | Sync delay (default 5s), gateway can't reach the management API/DB, or the API was saved but not **deployed** (a real two-step in Gravitee) |
| 401 with a valid key | Wrong plan selected, subscription not active, key header name mismatch |
| Rate limit inconsistent across pods | Local counters — configure the distributed (Redis/Hazelcast) rate-limit repository |
| Slow gateway | A Groovy policy in the hot path, or synchronous introspection without token caching |
| Analytics empty | Elasticsearch unreachable, index template/ILM misconfigured |

---

## 9. Best practices checklist

- [ ] API definitions in Git via the Kubernetes Operator (or exported JSON + CI import) — never console-only
- [ ] "Save" and "Deploy" are distinct; CI must do both and verify
- [ ] Sharding tags reviewed — no internal API on an internet-facing gateway
- [ ] Plans, not ad-hoc config, express contracts; deprecate with an overlap window
- [ ] `request-validation` from the OpenAPI schema enabled at the perimeter
- [ ] Distributed rate-limit repository configured for multi-pod gateways
- [ ] No Groovy policy in a hot path without a benchmark
- [ ] Full request/response logging off by default; sampled and body-free when on _(regulated)_
- [ ] Management API and console reachable only from the admin zone
- [ ] MongoDB/Postgres and Elasticsearch backed up, with restores drilled
- [ ] Gateways stateless and horizontally scaled; config sync failures alerted on

➡ [Interview Q&A](interview-qna.md)
