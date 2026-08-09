# Edge & API Gateway — NGINX, Kong, and the Layers Between

The edge is the only part of the platform an attacker can reach without already
being inside. It is also the only place where one bad config line takes down
every service at once. Treat it as a **product with its own release process**,
not as plumbing someone edits over SSH at 23:00.

Companion to [10-deployment-strategies.md](10-deployment-strategies.md) (how you
ship) and [03-security-baseline.md](03-security-baseline.md) (what you enforce).

---

## 1. The tier map — one job per layer

The most common architectural mistake is doing the same job in four places.
Then nobody knows which layer returned the 403, and rate limits multiply
unpredictably. Decide once, write it down, enforce it in review.

```
Internet
   │
   ▼
[1] Edge WAF / DDoS / TLS front            public zone   (CDN, appliance, or cloud WAF)
   │      owns: volumetric defence, geo/IP reputation, OWASP CRS, bot scoring
   ▼
[2] L4 load balancer  (HAProxy + keepalived VIP)   DMZ
   │      owns: VIP failover, TCP health, PROXY protocol, zone crossing
   ▼
[3] Ingress  (ingress-nginx / Cilium Gateway API)  cluster edge
   │      owns: TLS termination, host/path routing, HSTS + security headers,
   │            crude per-IP rate limit, request-size cap, canary traffic split
   ▼
[4] API gateway  (Kong)                            cluster, app-facing
   │      owns: AuthN/AuthZ (OIDC/JWT via Keycloak), per-consumer quotas,
   │            API keys, request/response transforms, API-level analytics
   ▼
[5] Service mesh / NetworkPolicy                   east-west
   │      owns: mTLS between pods, L3/L4 identity, retries between services
   ▼
Application
```

**Rules that follow from the map:**

| Rule | Why |
|---|---|
| TLS terminates **once** for the public request, at [3] | Two terminations means two cert inventories and two places HSTS can be wrong |
| Re-encrypt [3]→[4]→app inside the cluster | Bank networks are not trusted networks. "Internal" is not a security control |
| Authentication lives at [4] **only** | If both the ingress and the gateway validate JWTs, one will drift and start accepting a token the other rejects |
| Rate limiting exists at [1], [3] and [4] with *different keys* | [1] per source IP for volumetrics, [3] per IP for cheap protection, [4] per authenticated consumer for fairness. Never the same key twice |
| Retries live at [5] only | See §6.4 — retries at the gateway on a payments API is how you double-charge a customer |
| Nothing at [3] or [4] holds a long-lived secret | Certs from cert-manager, credentials from Vault via External Secrets |

**If you are not running a mesh yet**, fold [5]'s mTLS job into [4]→app TLS and
rely on default-deny NetworkPolicy for identity. Do not skip the layer silently.

---

## 2. Choosing the edge components

| Need | Pick | Do not pick | Why |
|---|---|---|---|
| VM-track reverse proxy | **NGINX** (or HAProxy if you already run it for L4) | Apache | Lower memory per connection, config is a testable artefact, `nginx -t` is a real gate |
| VIP failover, TCP passthrough, k8s apiserver LB | **HAProxy + keepalived** | NGINX | HAProxy's L4 health checking and stick tables are better; already in `roles/haproxy/` |
| K8s ingress, single team, HTTP routing only | **ingress-nginx** | Kong | Simplest thing that works; huge operational corpus |
| K8s ingress, many teams sharing one gateway | **Gateway API** (Cilium/Envoy) | ingress-nginx annotations | `HTTPRoute` gives per-team RBAC on routing; annotations do not |
| API management: consumers, quotas, keys, OIDC, transforms | **Kong** | ingress-nginx | Annotation sprawl is not an authorization model |
| Both ingress and API management, one component | **Kong Ingress Controller** | two gateways in series | Fewer hops, one config source. Costs you ingress-nginx's ecosystem |

**Recommended for this platform:** ingress-nginx at [3] for platform/internal
traffic, Kong at [4] for the business APIs. If your only consumers are internal
services with mTLS and you have no external API programme, **drop Kong** — an
unused API gateway is a liability, not an asset.

---

## 3. NGINX on the VM track

Implemented as `infra/ansible/roles/nginx_edge/`. Config lives in git, is
rendered by Ansible, validated with `nginx -t`, and **reloaded, never
restarted** (`nginx -s reload` / `systemctl reload`) so in-flight requests
survive.

### 3.1 The hardened baseline, annotated

```nginx
# /etc/nginx/nginx.conf  (see roles/nginx_edge/templates/nginx.conf.j2)

user  nginx;
worker_processes      auto;      # one per core; do not hand-tune without evidence
worker_rlimit_nofile  65535;     # must exceed worker_connections, or you get
                                 # "too many open files" under load, not before

events {
    worker_connections  16384;
    multi_accept        on;
}

http {
    # --- identity hygiene ---------------------------------------------------
    server_tokens       off;     # hides the version. `more_clear_headers Server`
                                 # (headers-more module) removes the header entirely
    more_clear_headers  Server;

    # --- TLS ----------------------------------------------------------------
    ssl_protocols             TLSv1.2 TLSv1.3;   # 1.0/1.1 are PCI-DSS failures
    ssl_ciphers               ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;               # correct for TLS1.3; client order is fine
    ssl_session_cache         shared:SSL:50m;    # shared across workers or you
                                                 # renegotiate on every worker hop
    ssl_session_tickets       off;               # tickets break forward secrecy
                                                 # unless you rotate keys yourself
    ssl_stapling              on;
    ssl_stapling_verify       on;
    resolver                  10.0.0.10 valid=300s ipv6=off;   # REQUIRED for stapling

    # --- timeouts: every one of these is a DoS control ----------------------
    client_body_timeout    10s;   # Slowloris on the body
    client_header_timeout  10s;   # Slowloris on the headers
    send_timeout           10s;
    keepalive_timeout      65s;   # must exceed the LB's idle timeout upstream,
                                  # or the LB reuses a socket NGINX just closed
                                  # → sporadic 502s that look like app bugs
    reset_timedout_connection on;

    # --- request limits -----------------------------------------------------
    client_max_body_size       1m;    # raise per-location, never globally
    client_body_buffer_size    16k;   # bodies larger than this hit disk
    large_client_header_buffers 4 8k;

    # --- rate limiting: define zones here, apply per-location ---------------
    limit_req_zone  $binary_remote_addr zone=perip:10m   rate=20r/s;
    limit_conn_zone $binary_remote_addr zone=connperip:10m;
    limit_req_status  429;    # default is 503 — wrong, and it poisons your SLO
    limit_conn_status 429;

    # --- logging: JSON, correlated, PII-free --------------------------------
    log_format json escape=json '{'
        '"ts":"$time_iso8601",'
        '"remote_addr":"$remote_addr",'
        '"method":"$request_method",'
        '"uri":"$uri",'                      # NOT $request — that includes the
                                             # query string, which carries tokens
        '"status":$status,'
        '"bytes":$body_bytes_sent,'
        '"rt":$request_time,'
        '"urt":"$upstream_response_time",'
        '"request_id":"$request_id",'
        '"ssl_protocol":"$ssl_protocol",'
        '"ua":"$http_user_agent"'
    '}';
    access_log /var/log/nginx/access.log json;
}
```

### 3.2 The server block

```nginx
server {
    listen 443 ssl;
    http2  on;
    server_name payments.bank.internal;

    ssl_certificate     /etc/nginx/tls/tls.crt;   # rendered by vault-agent to tmpfs
    ssl_certificate_key /run/secrets/tls.key;     # key never touches disk

    # mTLS from the L4 tier (optional but recommended in a bank)
    ssl_client_certificate /etc/nginx/tls/ca.crt;
    ssl_verify_client      on;

    # Security headers. `always` matters: without it they are omitted on 4xx/5xx,
    # which is exactly when an error page might render attacker-controlled input.
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options    "nosniff"                             always;
    add_header X-Frame-Options           "DENY"                                always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin"     always;
    add_header Content-Security-Policy   "default-src 'none'; frame-ancestors 'none'" always;

    location /api/ {
        limit_req  zone=perip burst=40 nodelay;
        limit_conn connperip 20;

        proxy_pass http://app_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";            # enables upstream keepalive
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Request-ID      $request_id;

        proxy_connect_timeout 3s;      # fail fast to a healthy peer
        proxy_send_timeout    30s;
        proxy_read_timeout    30s;

        # Do NOT add `non_idempotent` here. Default behaviour already retries
        # idempotent requests only; adding it retries POSTs. See §6.4.
        proxy_next_upstream error timeout http_502 http_503;
        proxy_next_upstream_tries 2;
    }

    # Health endpoint for the L4 LB — plain, cheap, no auth, no upstream call.
    location = /nginx-health {
        access_log off;
        return 200 "ok\n";
    }
}

upstream app_backend {
    zone app_backend 64k;
    least_conn;
    keepalive 64;                       # without this every request opens a new
                                        # TCP+TLS connection to the app
    server 10.20.1.11:8080 max_fails=3 fail_timeout=10s;
    server 10.20.1.12:8080 max_fails=3 fail_timeout=10s;
}
```

### 3.3 Key notes — NGINX

1. **`add_header` is not inherited when a child block declares its own.** If a
   `location` has any `add_header`, it silently drops every header from the
   `server` block. This is the single most common cause of "HSTS is missing on
   one endpoint". Either declare them all in every block, or use the
   `headers-more` module's `more_set_headers`, which does inherit.
2. **`$request` in logs leaks tokens.** Anything in a query string ends up in
   your SIEM, which is retained for 7 years. Log `$uri`.
3. **Upstream keepalive requires three settings together**: `keepalive N` in the
   upstream, `proxy_http_version 1.1`, and `proxy_set_header Connection ""`.
   Miss any one and you get no reuse, plus TIME_WAIT exhaustion at ~28k
   connections.
4. **The keepalive timeout ordering rule**: downstream idle timeout < NGINX
   `keepalive_timeout` < upstream idle timeout. Violating it produces 502s at
   a low, steady rate that survives every restart and gets blamed on the app.
5. **`limit_req` counts before the request reaches the app** — so a rate-limited
   request never appears in app metrics. Your SLO denominator must come from
   NGINX, not the app, or throttling looks like success.
6. **Reload, don't restart.** `nginx -t && systemctl reload nginx`. The Ansible
   handler does exactly this and validates first — an invalid config never
   reaches a running process.
7. **Rate limit zones are per worker-shared-memory, not per node.** Ten nodes
   with `rate=20r/s` is 200r/s in aggregate. Size for the fleet, not the box.

---

## 4. ingress-nginx in Kubernetes

### 4.1 Controller-level hardening (the part people skip)

Per-Ingress annotations get all the attention; the controller ConfigMap is
where the security posture actually lives.

```yaml
# gitops/platform/ingress-nginx/values.yaml (Helm)
controller:
  replicaCount: 3
  allowSnippetAnnotations: false        # ← see the warning below
  config:
    # Global security headers — applied to every Ingress, no snippets needed
    hsts: "true"
    hsts-max-age: "31536000"
    hsts-include-subdomains: "true"
    ssl-protocols: "TLSv1.2 TLSv1.3"
    ssl-ciphers: "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384"
    server-tokens: "false"
    use-forwarded-headers: "false"      # true only if a trusted L7 proxy is in
                                        # front; otherwise clients spoof their IP
    proxy-real-ip-cidr: "10.10.0.0/16"  # the DMZ LB range, nothing wider
    enable-modsecurity: "true"
    enable-owasp-modsecurity-crs: "true"
    annotations-risk-level: "Critical"  # keep at default unless you audited it
    log-format-escape-json: "true"
    generate-request-id: "true"
  podDisruptionBudget:
    enabled: true
    minAvailable: 2
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
  metrics:
    enabled: true
    serviceMonitor: { enabled: true }
```

> **⚠ Snippet annotations are disabled by default since ingress-nginx v1.9, and
> for good reason.** `configuration-snippet` / `server-snippet` let anyone with
> permission to create an Ingress in *any* namespace inject arbitrary NGINX
> config into the shared controller — the root cause of a series of CVEs
> including the 2025 unauthenticated-RCE class of bugs in the admission
> controller. **Do not turn `allowSnippetAnnotations` back on to add security
> headers.** Use the `add-headers` ConfigMap or `hsts*` settings above instead.
>
> **This repo currently violates that**:
> `gitops/business/payment-service/overlays/prod/ingress.yaml` uses
> `nginx.ingress.kubernetes.io/configuration-snippet` for its headers and
> request-id. On a default controller those annotations are ignored — so the
> headers you think are set are not. Move them to the controller ConfigMap
> (`add-headers` → a ConfigMap of header key/values, plus
> `generate-request-id: "true"` which sets `X-Request-ID` natively).

Also required, regardless of version:

- **Restrict the admission webhook.** A NetworkPolicy allowing port 8443 *only*
  from the apiserver CIDR. The 2025 RCE was reachable because that endpoint was
  open pod-to-pod.
- **Pin the controller image by digest** and let Kyverno's signature policy
  verify it (`security/kyverno/baseline-policies.yaml`).
- **`kubectl auth can-i create ingress --as=...`** — treat Ingress creation as a
  privileged verb. It is routing for the whole cluster.

### 4.2 Per-Ingress annotations worth setting

| Annotation | Value | Why |
|---|---|---|
| `force-ssl-redirect` | `"true"` | `ssl-redirect` alone is skipped when TLS terminates upstream |
| `proxy-body-size` | `"1m"` | Default 1m is fine; raise per-route, never globally |
| `proxy-read-timeout` | `"30"` | Must be < the client's timeout, > p99.9 of the endpoint |
| `limit-rps` / `limit-burst-multiplier` | `"100"` / `"2"` | Cheap per-IP shield. Not a substitute for §5 quotas |
| `whitelist-source-range` | DMZ/partner CIDRs | For admin and partner-only paths |
| `auth-tls-secret` | `ns/ca-secret` | mTLS from partner banks |
| `backend-protocol` | `HTTPS` | Re-encrypt to the pod. Do this |
| `service-upstream` | `"true"` | Route via the Service ClusterIP so endpoint churn during a rollout doesn't strand connections |

**Do not** use `nginx.ingress.kubernetes.io/canary*` annotations when Argo
Rollouts owns the traffic split — both will try to manage the same weights and
the rollout will report success while sending 0% to the canary.

---

## 5. Kong Gateway

Implemented as `gitops/platform/kong/`.

### 5.1 Topology decision

| Mode | Config source | Use when | Notes |
|---|---|---|---|
| **DB-less + Ingress Controller** | Kubernetes CRDs, reconciled | ✅ Default for this platform | No Postgres to back up, config is GitOps-native, Admin API is read-only |
| DB-less + declarative file | `kong.yml` in a ConfigMap | Non-k8s / VM edge | Same benefits, but config drifts from the app repos |
| **Hybrid (CP/DP)** | Control plane, pushed over mTLS | Multi-cluster, or DPs in a DMZ the CP cannot live in | Best zone story: DPs in DMZ, CP in management zone |
| Traditional (DB-backed) | Admin API writes to Postgres | ❌ Avoid | Mutable state outside git, an Admin API that must be defended, one more DB to back up and restore |

**Rule: the Admin API is never exposed.** In DB-less mode it is read-only,
which is most of the mitigation. Still bind it to `127.0.0.1:8444`, put it
behind a NetworkPolicy, and never create an Ingress for it or for Kong Manager.
An exposed Kong Admin API is total compromise of every route and credential the
gateway holds.

### 5.2 Plugin execution order — the thing that bites everyone

Kong runs plugins in the access phase ordered by **descending `priority`**.
Higher number runs first. Getting this wrong produces subtle security holes:
rate-limit before auth and an attacker exhausts an anonymous bucket; ACL before
auth and there is no consumer to check.

The correct conceptual order, with representative priorities (**verify against
your Kong version's plugin docs — these numbers change between majors**):

```
higher priority = earlier
  ~2500  bot-detection            ┐
  ~2000  cors                     │ 1. cheap rejects, before any work
  ~1000  ip-restriction           ┘
  ~1450  jwt / oidc / key-auth      2. establish WHO (sets the consumer)
   ~950  acl                        3. establish WHAT they may do
   ~951  request-size-limiting       4. resource guards, now per-consumer
   ~910  rate-limiting             ┘
   ~800  request-transformer         5. shape the request
   ~100  proxy-cache                 6. serve or forward
     ~1  correlation-id              7. last: stamp the id onto the proxied req
```

**Key notes:**
- **Rate limiting must run after authentication** so the limit key can be the
  consumer, not the IP. A shared corporate NAT means IP-keyed limits throttle an
  entire branch office because one user misbehaved.
- **CORS must run before auth**, or the browser's preflight `OPTIONS` (which
  carries no credentials, by spec) gets a 401 and the real request is never sent.
- **`correlation-id` at priority 1** means it is the last thing stamped — so the
  id in your gateway log matches the id the upstream sees. Set
  `generator: uuid#counter`, `echo_downstream: true`.
- Ordering can be overridden per-plugin (`ordering.before/after`) in Kong
  Enterprise. In OSS, priority is fixed — if you need a different order, you need
  a different plugin.

### 5.3 The plugin set for a bank-grade API

| Plugin | Config that matters | Why |
|---|---|---|
| `openid-connect` (EE) or `jwt` (OSS) | Issuer = Keycloak realm, `verify_signature`, `maximum_expiration: 3600` | Delegate identity to Keycloak; the gateway validates, never issues |
| `acl` | `allow: [payments-read, payments-write]` | Groups come from the token; scope→group mapping is the authorization model |
| `rate-limiting-advanced` / `rate-limiting` | `policy: redis`, limit by `consumer` | **`policy: local` counts per data-plane pod** — 3 replicas = 3× your intended limit |
| `request-size-limiting` | `size_in_megabytes: 1` | Before the body is buffered |
| `request-termination` | On a route, temporarily | The clean way to shed a broken endpoint without a deploy |
| `ip-restriction` | Partner CIDRs on partner routes | Defence in depth with the network layer |
| `correlation-id` | `echo_downstream: true` | Ties gateway logs to app logs to traces |
| `prometheus` | `status_code_metrics`, `latency_metrics`, `per_consumer: true` (careful) | `per_consumer` explodes cardinality — enable only for a bounded consumer set |
| `http-log` / `file-log` | JSON to the log pipeline | Kong's log is the authoritative record of who called what |

**Never** put the `basic-auth` or `key-auth` plugin in front of a
customer-facing money-moving API. Keys do not expire, do not carry scope, and
end up in a partner's git repo. Use OIDC with short-lived tokens.

### 5.4 Secrets

Kong reads secrets from `{vault://...}` references. Wire it to Vault so no
credential is in a CRD:

```yaml
apiVersion: configuration.konghq.com/v1
kind: KongClusterPlugin
metadata:
  name: rate-limiting-global
config:
  redis:
    host: redis.platform.svc
    password: "{vault://kong-vault/redis/password}"
```

Otherwise use External Secrets to project a Kubernetes Secret and reference it
by `secretRef` — never a literal in a manifest that goes to git.

### 5.5 Upstream health and retries — read §6.4 before setting these

```yaml
apiVersion: configuration.konghq.com/v1
kind: KongIngress
metadata:
  name: payment-upstream
proxy:
  connect_timeout: 3000
  read_timeout:   30000
  write_timeout:  30000
  retries: 0            # ← NOT the default. Kong defaults to 5.
upstream:
  healthchecks:
    active:
      type: http
      http_path: /healthz
      healthy:   { interval: 5,  successes: 2 }
      unhealthy: { interval: 5,  http_failures: 3, timeouts: 3 }
    passive:
      unhealthy: { http_failures: 5, timeouts: 5 }
```

---

## 6. Cross-cutting key notes

### 6.1 TLS

- **Minimum TLS 1.2**, prefer 1.3. TLS 1.0/1.1 fail PCI-DSS outright.
- **Certificates come from cert-manager**, issued by the Vault PKI mount, with a
  **short lifetime (90 days or less)**. A cert you renew by hand once a year is
  a cert that expires on a Sunday.
- **Alert on days-to-expiry ≤ 21**, not on expiry. `ci/scripts/smoke.sh` already
  checks remaining days — wire the same check to a Prometheus blackbox probe.
- **HSTS `preload` is close to irreversible.** Once you submit the domain,
  removal takes months to propagate. Ship `max-age=31536000; includeSubDomains`
  for a full quarter before you even consider adding `preload`.
- **Re-encrypt to the backend.** `backend-protocol: HTTPS` on the Ingress,
  `proxy_ssl_verify on` on VM NGINX. Plaintext inside the cluster is still
  plaintext on someone's span port.

### 6.2 Header hygiene

| Header | Setting | Note |
|---|---|---|
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` | Set at exactly one layer |
| `X-Content-Type-Options` | `nosniff` | Always |
| `X-Frame-Options` / CSP `frame-ancestors` | `DENY` / `'none'` | CSP is the modern one; send both for old clients |
| `Content-Security-Policy` | `default-src 'none'` for pure APIs | An API serving JSON needs nothing |
| `Server`, `X-Powered-By` | **removed** | Version disclosure is free reconnaissance |
| `X-Forwarded-For` | **overwrite at the trusted edge, never append blindly** | If you trust a client-supplied XFF, every IP-based control and audit log is forgeable |

The last row is the one that gets missed. `use-forwarded-headers: "true"` with a
wide `proxy-real-ip-cidr` means an attacker sets their own source IP in your
audit trail. Set the CIDR to the DMZ load balancers and nothing else.

### 6.3 Rate limiting — a layered budget, not four copies of one number

| Layer | Key | Typical | Purpose |
|---|---|---|---|
| WAF/CDN | source IP | 1000 r/s | Volumetric / DDoS |
| ingress-nginx | source IP | 100 r/s burst 200 | Cheap shield, protects the cluster |
| Kong | **consumer** | 600 r/min (tiered per plan) | Fairness and commercial quota |
| Application | user + operation | 5 payment attempts/min | Business rule, not infrastructure |

Rules:
- Return **429** with a **`Retry-After`** header. A 503 makes throttling look
  like an outage in every SLO dashboard you own.
- **Exclude 429s from the error budget** in your SLI query — they are the system
  working as designed. Alert on the *rate* of 429s separately.
- Kong's `policy: local` counts per pod. Use `redis` for anything you would
  defend in a contract.

### 6.4 Retries: the payments trap

A gateway that retries a timed-out `POST /payments` can submit the payment
twice. The upstream may have processed the first attempt and simply been slow to
answer.

- **Kong `Service.retries` defaults to 5.** Set it to `0` for any
  non-idempotent route. This is the single highest-value line in the Kong config.
- **NGINX `proxy_next_upstream`** by default does not retry non-idempotent
  methods — do not add the `non_idempotent` flag to "fix" flakiness.
- Retries belong **between services** (layer [5]), where the caller can attach
  an idempotency key and the receiver can deduplicate.
- Require an `Idempotency-Key` header on every mutating public endpoint, and
  make the gateway reject requests without one (`request-termination` on a route
  predicate, or a `pre-function`). Then retries are safe everywhere.

### 6.5 Observability at the edge

The edge is where you learn the truth about availability, because it sees the
requests the app never received.

Log fields (JSON, from both NGINX and Kong):
`ts, request_id, consumer, route, method, uri (no query string), status,
request_time, upstream_time, upstream_status, bytes, tls_version, source_ip`.

Alerts that pay for themselves:

| Alert | Expression sketch | Why |
|---|---|---|
| Edge 5xx burn rate | multi-window 14.4×/6× on `status=~"5.."` | The real customer-facing SLI |
| Upstream unhealthy | `nginx_upstream_server_health == 0` | Backend gone before users notice |
| 429 spike | `rate(429) > 10× baseline` | Either an attack or a quota set too low |
| TLS cert expiry | `probe_ssl_earliest_cert_expiry - now < 21d` | The classic Sunday outage |
| Config reload failed | `nginx_ingress_controller_config_last_reload_successful == 0` | Controller is serving **stale config** and looks perfectly healthy |
| Latency at edge ≫ upstream latency | `request_time - upstream_time > 200ms` | Queueing, TLS handshake cost, or worker starvation |

The "config reload failed" alert is the non-obvious one. When ingress-nginx
rejects a bad config it keeps serving the previous one — your Ingress change
appears applied in git and in `kubectl`, but is not live. Nothing else catches
this.

### 6.6 Deploying the gateway itself

The gateway is a single point of failure for every service. It gets the same
discipline as an application, plus:

- **Config is validated before it is live.** `nginx -t` on VMs; the ingress-nginx
  admission webhook in k8s; `deck validate` / `deck diff` for Kong declarative
  config in CI.
- **≥3 replicas, spread across zones, with a PDB.** A `maxUnavailable` that
  drops the last replica takes down the whole estate.
- **Drain before terminate.** `preStop: sleep 15` plus a graceful shutdown
  timeout longer than your longest request, or you cut in-flight connections on
  every rollout.
- **Upgrade the controller like a service, not like a package.** Read the
  changelog for annotation/behaviour removals, deploy to dev, run the full smoke
  suite, then prod — in its own change window, alone.
- **Never edit config on the box.** The next Ansible run or Argo sync reverts
  it, usually at the worst moment, and now the outage has two causes.

---

## 7. Verification drills

Prove each of these once, then put them in CI. An unverified control is a belief.

| # | Drill | Pass condition |
|---|---|---|
| 1 | `curl -sI https://host/api/nonexistent` | Security headers present on the **404**, not just on 200 |
| 2 | `nmap --script ssl-enum-ciphers -p443 host` | No TLS 1.0/1.1, no CBC, no RC4 |
| 3 | `curl -H 'X-Forwarded-For: 1.2.3.4'` from outside | Your log shows the **real** source IP, not 1.2.3.4 |
| 4 | Send 200 requests in 1s | 429 with `Retry-After`, and the app never sees them |
| 5 | `curl https://host/` with an expired/forged JWT | 401 at Kong, request never reaches the app |
| 6 | `curl http://kong-admin:8001/` from an app pod | Connection refused / NetworkPolicy drop |
| 7 | Apply an Ingress with a deliberate syntax error | Admission webhook rejects it; if it lands, the reload-failed alert fires within 1m |
| 8 | Kill 2 of 3 ingress pods during a load test | Error rate stays at 0; PDB blocked the third |
| 9 | POST with a forced upstream timeout | Exactly **one** record created. Not two |
| 10 | `curl -X OPTIONS` preflight from a browser origin | 204 with CORS headers, no 401 |
| 11 | Request with a 10MB body | 413 at the edge, before the app allocates memory |
| 12 | Grep 24h of edge logs for `password\|token\|Bearer ` | Zero matches |

Drills 3, 6, 9 and 12 are the ones that fail most often in real environments.

---

## 8. Never do this

1. Expose the Kong Admin API, Kong Manager, or the NGINX stub-status endpoint.
2. Turn on `allowSnippetAnnotations` to add a header you could set globally.
3. Trust a client-supplied `X-Forwarded-For` (`use-forwarded-headers: true` with
   a wide CIDR).
4. Leave `Service.retries: 5` on a non-idempotent Kong route.
5. Use `policy: local` rate limiting and quote the number in a customer contract.
6. Authenticate at two layers. Pick one and delete the other.
7. Terminate TLS and forward plaintext "because it's internal".
8. Edit `/etc/nginx/` on a live box.
9. `systemctl restart nginx` when `reload` would do.
10. Return 503 for a rate limit and then wonder why the availability SLO is red.

---

## 9. Where the implementation lives

| Concept | File |
|---|---|
| Hardened NGINX on VMs | `infra/ansible/roles/nginx_edge/` |
| Validated reload handler | `infra/ansible/roles/nginx_edge/handlers/main.yml` |
| L4 VIP, keepalived | `infra/ansible/roles/haproxy/` |
| Kong DB-less controller | `gitops/platform/kong/values.yaml` |
| Kong global plugins | `gitops/platform/kong/plugins.yaml` |
| Kong network isolation | `gitops/platform/kong/networkpolicy.yaml` |
| Kong ArgoCD Application | `gitops/apps/platform/prod/kong-app.yaml` |
| Per-service Ingress | `gitops/business/payment-service/overlays/prod/ingress.yaml` |
| Edge smoke tests (drills 1, 2, 5) | `ci/scripts/smoke.sh` |
