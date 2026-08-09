# Kong Cheat Sheet

DB-less config, entities, plugins and their order, consumers, JWT/OIDC, Kong
Ingress Controller.

Repo implementation: [`gitops/platform/kong/`](../../gitops/platform/kong/) ·
design rationale: [docs/13-edge-gateway.md](../../docs/13-edge-gateway.md).

---

## 1. What Kong is for

Kong is the **API gateway** tier: authentication and authorisation, per-consumer
quotas, API keys, request/response transformation, and API-level analytics. It
sits *behind* the ingress/edge (which owns TLS termination, host routing and
volumetric rate limiting) and *in front of* your services.

The one rule that prevents most gateway incidents: **authentication happens here
and nowhere else.** If the ingress also validates JWTs, the two implementations
will drift on clock skew, algorithm allowlist, audience or key rotation, and one
will accept a token the other rejects.

---

## 2. Entity model

```
Consumer ──(credentials)──┐
                          ▼
Client ─► Route ─► Service ─► upstream (Target × N, health-checked)
            │        │
            └── Plugins can attach at: global > consumer > route > service
```

| Entity | Meaning |
|---|---|
| **Service** | The upstream API (a URL or an `Upstream` name) |
| **Route** | Match rules (host, path, method, header, SNI) → one Service |
| **Consumer** | An identified API client. Credentials and quotas hang off it |
| **Upstream / Target** | Kong-side load balancing ring + active/passive health checks |
| **Plugin** | Behaviour attached at a scope; runs in phases by priority |
| **Credential** | key-auth key, JWT public key, OAuth2 app, mTLS cert, per Consumer |

**Plugin precedence when the same plugin is attached at several scopes** (most
specific wins): consumer+route+service → consumer+route → consumer+service →
route+service → consumer → route → service → global.

---

## 3. DB-less declarative config

DB-less (`declarative_config`) is the right default: no Postgres to run, back up
and secure; config is a file in Git; every gateway node is identical and
immutable. You lose runtime Admin API writes (which is a feature) and some
plugins that need persistence (rate-limiting counters need a Redis policy, and
OAuth2 token storage doesn't work at all).

```yaml
# kong.yaml
_format_version: "3.0"
_transform: true

services:
  - name: payment
    url: https://payment.app-payment.svc:8443
    retries: 0                # ← payments: NEVER retry a non-idempotent request
    connect_timeout: 3000
    write_timeout: 10000
    read_timeout: 10000
    routes:
      - name: payment-v1
        paths: ["/v1/payments"]
        strip_path: false
        protocols: ["https"]
        https_redirect_status_code: 426
    plugins:
      - name: rate-limiting
        config: { minute: 600, policy: redis, redis_host: redis.platform.svc }

consumers:
  - username: mobile-app
    keyauth_credentials:
      - key: "$KEY_FROM_VAULT"      # rendered by ESO/Vault, never committed
    acls:
      - group: retail

plugins:                             # global
  - name: correlation-id
    config: { header_name: X-Request-ID, echo_downstream: true }
```

```bash
kong config -c kong.conf parse kong.yaml     # validate before shipping
deck gateway validate kong.yaml
deck gateway diff  --state kong.yaml         # ← what would change
deck gateway sync  --state kong.yaml
deck gateway dump  --output-file current.yaml
```

`decK` is the GitOps tool for Kong outside Kubernetes: `diff` in the merge
request, `sync` in the deploy job. Never `curl` the Admin API by hand.

---

## 4. Kong Ingress Controller (CRDs)

```yaml
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata: { name: rate-limit-consumer, namespace: app-payment }
plugin: rate-limiting
config:
  minute: 600
  policy: redis           # local = per-pod counters; redis = cluster-wide truth
  limit_by: consumer
  fault_tolerant: true    # Redis down → allow, don't fail the API
---
apiVersion: configuration.konghq.com/v1
kind: KongClusterPlugin      # cluster-scoped; label global:"true" to apply to all
metadata:
  name: correlation-id
  labels: { global: "true" }
plugin: correlation-id
config: { header_name: X-Request-ID, generator: uuid#counter, echo_downstream: true }
---
apiVersion: configuration.konghq.com/v1
kind: KongConsumer
metadata:
  name: mobile-app
  annotations: { kubernetes.io/ingress.class: kong }
username: mobile-app
credentials: ["mobile-app-key"]      # Secret names, delivered by ESO from Vault
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: payment
  annotations:
    konghq.com/plugins: rate-limit-consumer,jwt   # attach plugins to the route
spec:
  parentRefs: [{ name: kong }]
  rules:
    - matches: [{ path: { type: PathPrefix, value: /v1/payments } }]
      backendRefs: [{ name: payment, port: 8443 }]
```

Attach plugins with the `konghq.com/plugins` annotation on an Ingress/HTTPRoute
(route scope), a Service (service scope), or a KongConsumer (consumer scope).

Useful annotations: `konghq.com/strip-path`, `konghq.com/protocols: https`,
`konghq.com/methods`, `konghq.com/read-timeout`, `konghq.com/retries: "0"`,
`konghq.com/override` (KongIngress for upstream/health-check tuning).

---

## 5. Plugin execution order — the part that bites

Kong runs access-phase plugins in **descending priority**. The order is not
cosmetic:

```
cors (~2000) ─► auth: jwt/key-auth/oidc (~1450) ─► acl (~950)
   ─► request-size-limiting (~951) ─► rate-limiting (~910) ─► proxy
```

- **CORS before auth.** A browser preflight `OPTIONS` carries no credentials by
  specification. Auth-first returns 401 to the preflight and the real request is
  never sent — the classic "works in curl, broken in the browser".
- **Auth before ACL and before rate-limiting-by-consumer.** Both need a consumer
  to exist. Rate limiting keyed on a consumer that hasn't been established yet
  silently falls back to IP.
- Priorities change between Kong majors. Verify against your version's docs
  rather than a number memorised from a blog post.

Phases: `certificate` → `rewrite` → `access` → (proxy) → `header_filter` →
`body_filter` → `log`. Only `rewrite` runs before route matching.

---

## 6. Plugins worth knowing

| Category | Plugin | Notes |
|---|---|---|
| AuthN | `key-auth` | Simple; key in header/query. Rotate via a second key on the consumer |
| AuthN | `jwt` | Validates signature/exp against a per-consumer public key |
| AuthN | `openid-connect` (Enterprise) | Full OIDC with Keycloak: discovery, introspection, JWKS rotation |
| AuthN | `mtls-auth` (Enterprise) | Client certs mapped to consumers — common for bank B2B |
| AuthZ | `acl` | Group allow/deny after authentication |
| Traffic | `rate-limiting`, `rate-limiting-advanced` | `policy: redis` for cluster-wide counters |
| Traffic | `proxy-cache` | Never cache authenticated responses without identity in the key |
| Traffic | `request-size-limiting`, `request-termination` | Cheap protection; maintenance mode |
| Resilience | `circuit-breaker` / upstream health checks | Passive (from real traffic) + active (probe) |
| Transform | `request-transformer`, `response-transformer` | Strip internal headers on the way out |
| Observability | `correlation-id`, `prometheus`, `opentelemetry`, `http-log` | Correlation id echoed downstream so a customer can quote it |
| Security | `ip-restriction`, `bot-detection`, `cors` | |

```yaml
# Strip anything internal before the response leaves the perimeter
plugin: response-transformer
config:
  remove:
    headers: ["X-Upstream-Node", "Server", "X-Powered-By"]
```

---

## 7. Health checks and retries

```yaml
upstreams:
  - name: payment-upstream
    healthchecks:
      active:
        type: https
        http_path: /readyz
        healthy:   { interval: 5, successes: 2 }
        unhealthy: { interval: 5, http_failures: 3, timeouts: 3 }
      passive:
        unhealthy: { http_failures: 5, timeouts: 5 }
```

**Retries.** Kong's `retries` defaults to 5. On a payments API that is a
double-charge waiting to happen: a timeout does not mean the request wasn't
processed. Set `retries: 0` on any non-idempotent service and make correctness
the application's job via an idempotency key. Retries belong at the mesh layer
for genuinely idempotent calls, with a budget so a slow dependency doesn't get
retry-amplified into an outage.

---

## 8. Security operations

- **Never expose the Admin API** (8001/8444). It is full control of the gateway
  with no authentication by default. In this repo, no NetworkPolicy ingress rule
  mentions 8444 at all — reach it via `kubectl port-forward`, which is audited,
  or not at all.
- DB-less removes the Admin API write path entirely. Prefer it.
- Kong pods hold no long-lived secret: certs from cert-manager, consumer
  credentials from Vault via External Secrets.
- Default-deny NetworkPolicy on the gateway namespace; the only ingress to the
  proxy port comes from the ingress tier, so nothing in the cluster can call an
  upstream directly and skip gateway controls.
- Kong runs as non-root with a read-only rootfs; the `kong` container needs no
  capabilities beyond binding its ports (>1024, so none).

---

## 9. Observability

```yaml
plugin: prometheus
config: { status_code_metrics: true, latency_metrics: true, upstream_health_metrics: true }
```

Key metrics: `kong_http_requests_total{code,service,consumer}`,
`kong_request_latency_ms` (total) vs `kong_upstream_latency_ms` (backend) —
the difference is **Kong's own overhead**, which is where you'll see a slow
plugin. Also `kong_upstream_target_health`.

Debug checklist:

| Symptom | Cause |
|---|---|
| 404 "no Route matched" | Host/path/protocol mismatch, or `strip_path` confusion |
| 401 on browser preflight only | CORS plugin priority below auth |
| 502 / 503 upstream | Upstream unhealthy, mTLS mismatch, wrong port, NetworkPolicy |
| Rate limit not enforced across pods | `policy: local` — counters are per-pod. Use redis |
| 429 nobody can explain | Two layers limiting on the same key. Pick one key per layer |
| Consumer is `anonymous` in logs | Auth plugin not attached at that scope, or ordered after the plugin reading it |
| Config change had no effect | Wrong plugin scope, or KIC didn't reconcile — check controller logs |

```bash
kubectl -n platform-kong logs deploy/kong-controller -f
kubectl -n platform-kong port-forward deploy/kong 8444:8444
curl -s localhost:8444/status | jq         # then STOP the port-forward
deck gateway diff --state kong.yaml        # drift between Git and running config
```

---

## 10. Kong vs the alternatives (one line each)

| | Position |
|---|---|
| **Kong** | Mature, huge plugin ecosystem, DB-less GitOps-friendly, Lua/OpenResty. Best plugin story; OIDC and advanced rate limiting are Enterprise |
| **NGINX / ingress-nginx** | Great proxy, not an API gateway — no consumers, no quotas, no key management |
| **Gravitee APIM** | API *management*, not just a gateway: portal, lifecycle, plans, subscriptions. See [06-gravitee](../06-gravitee/) |
| **Apache APISIX** | Similar architecture, etcd-backed, fully open-source features Kong reserves for Enterprise |
| **Envoy / Istio / Gateway API** | Best-in-class dataplane and east-west mesh; API-product features (consumers, plans, monetisation) are not its job |
| **Cloud gateways (AWS API GW, Apigee)** | Managed, less to run, more lock-in and less control over the request path |

---

## 11. Best practices checklist

- [ ] DB-less, config in Git, applied by ArgoCD/decK — no Admin API by hand
- [ ] Admin API unreachable on the network, not merely "not documented"
- [ ] Authentication exists at exactly one layer, and this is it
- [ ] Plugin order verified for your Kong version; CORS before auth
- [ ] Rate limiting keyed on **consumer** here, on IP at the edge — never the same key twice
- [ ] `policy: redis` with `fault_tolerant: true` for cluster-wide counters
- [ ] `retries: 0` on every non-idempotent service
- [ ] Active + passive health checks per upstream
- [ ] `correlation-id` global, echoed downstream, propagated into app logs and traces
- [ ] Internal headers stripped from responses
- [ ] Consumer credentials from Vault via ESO; rotation tested (two valid keys, then remove the old)
- [ ] Default-deny NetworkPolicy; only the ingress tier may reach the proxy port
- [ ] Gateway config changes go through the same review and canary as application code

➡ [Interview Q&A](interview-qna.md)
