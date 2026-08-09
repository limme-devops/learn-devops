# NGINX — Interview Q&A

---

## Architecture

**Q1. Why is NGINX fast compared to Apache prefork?**
Event-driven, non-blocking architecture: a small number of worker processes (one
per core), each handling thousands of connections in an epoll loop, rather than
a process or thread per connection. Memory per connection is kilobytes instead of
megabytes, and there's no context-switch storm at high concurrency. The trade-off
is that any blocking operation in a worker stalls every connection that worker
owns — which is why disk I/O uses `aio`/thread pools and why you don't run
heavy in-process logic in NGINX.

**Q2. Reload vs restart.**
`nginx -s reload` re-reads the config, validates it, then forks new workers with
the new config while old workers finish their in-flight requests and exit. No
connection is dropped. A restart kills everything. The important operational
consequence: *validate before reload* (`nginx -t`), because if the config is
invalid the reload is refused — which is good — but if it's valid-but-wrong you
have just deployed it to every site on the box simultaneously. That's why config
is templated, validated, and rolled out host by host behind an LB drain.

**Q3. How does location matching work?**
Precedence, not file order: exact `=` wins immediately; then `^~` prefix
(short-circuits regex); then regex `~`/`~*` in the order they appear in the file,
first match wins; then the longest matching plain prefix. People assume top-to-
bottom like a firewall and are then surprised that a longer prefix lower in the
file wins over a shorter one above it.

---

## Proxying

**Q4. What does the trailing slash in `proxy_pass` change?**
Everything. `proxy_pass http://up;` passes the URI through unchanged.
`proxy_pass http://up/;` treats the value as a URI and **strips the matched
location prefix**, so `location /api/ { proxy_pass http://up/; }` turns
`/api/v1/pay` into `/v1/pay`. It's the single most common NGINX bug, and it
shows up as 404s from the backend rather than an NGINX error, so people debug
the wrong system for an hour.

**Q5. Why do I need `proxy_http_version 1.1` and `proxy_set_header Connection ""`?**
NGINX talks HTTP/1.0 to upstreams by default and sends `Connection: close`, so
the `keepalive` pool in the upstream block does nothing and every request pays a
fresh TCP handshake — plus a TLS handshake if you re-encrypt. Setting version
1.1 and clearing the Connection header enables connection reuse. At any real
throughput this is a large latency and ephemeral-port win.

**Q6. How do you get the real client IP?**
`X-Forwarded-For` is client-controlled, so you must not trust it blindly — a
client that sets its own XFF defeats per-IP rate limiting and poisons your logs.
Use `real_ip_module`: `set_real_ip_from <CDN/LB CIDR>` plus
`real_ip_header X-Forwarded-For` and `real_ip_recursive on`, so NGINX only
accepts the header from known proxies and rewrites `$remote_addr` accordingly.
At L4 with HAProxy in front, the PROXY protocol is cleaner because it's out of
band and can't be forged by the client.

**Q7. When should NGINX retry a failed upstream?**
`proxy_next_upstream` retries on error/timeout by default, which is fine for
idempotent GETs and dangerous for anything else. On a payments POST, a timeout
doesn't mean the request wasn't processed — it means you don't know. Retrying can
double-charge a customer. So: retries off (or restricted to `error` on
connection establishment only) for non-idempotent routes, and correctness comes
from an idempotency key in the application, not from the proxy.

---

## TLS and security

**Q8. Walk me through a good TLS config.**
TLS 1.2 and 1.3 only; ECDHE key exchange with AEAD ciphers (GCM/ChaCha20) for
forward secrecy; `ssl_prefer_server_ciphers off` under TLS 1.3 because the
client's preference is fine and often better for its hardware; session cache on,
session *tickets* off unless keys are rotated (a static ticket key breaks forward
secrecy); OCSP stapling with `ssl_stapling_verify on`; HSTS with a long max-age
and `includeSubDomains`; certificate and key delivered by cert-manager or Vault
PKI with automated rotation, never a file someone copied. Then verify externally
— `testssl.sh` or an SSL Labs scan — because config intent and negotiated reality
diverge more often than you'd like.

**Q9. Why does `add_header` sometimes silently disappear?**
`add_header` directives are inherited from the enclosing block only if the child
block defines **none** of its own. Add one header inside a `location` and every
inherited header — including HSTS and CSP — vanishes for that location. Also,
without `always`, headers are only emitted on successful responses, so your
security headers are missing from exactly the error pages an attacker is probing.
The fix is a single `include security-headers.conf` repeated in each location,
and a test that asserts the headers on both a 200 and a 404.

**Q10. Design rate limiting at the edge.**
`limit_req_zone` is a leaky bucket: `rate` is the drain rate, `burst` the bucket
depth, `nodelay` serves the burst immediately rather than queuing it. Key it on
`$binary_remote_addr` (after real_ip fixes it) for cheap volumetric protection,
and return 429 with a `Retry-After`. But per-IP limiting at the edge is a blunt
instrument — behind a corporate NAT or a mobile carrier, thousands of users share
an IP. So the edge does volumetric defence per IP, and *fairness* limiting per
authenticated consumer happens at the API gateway where identity exists. Never
use the same key at two layers — the limits multiply unpredictably and nobody can
explain the 429.

**Q11. Should NGINX validate JWTs?**
Only if it's the only gateway you have (and OSS NGINX needs njs or a third-party
module to do it at all). In a layered edge, authentication belongs in exactly one
place — the API gateway — because two implementations of token validation will
drift in clock skew, algorithm allowlists, key rotation and audience checks, and
one of them will end up accepting a token the other rejects. That's a security
finding, not a redundancy.

---

## Performance and caching

**Q12. Explain proxy caching and one way it goes badly wrong.**
`proxy_cache_path` defines the store; `proxy_cache_key` decides what "the same
response" means; `proxy_cache_valid` sets TTLs per status. `proxy_cache_lock`
collapses a stampede into a single origin request, and
`proxy_cache_use_stale` + `background_update` serves slightly stale content
during an origin outage instead of a 502 — which converts an incident into a
degradation. The way it goes badly wrong: caching an authenticated response
without the identity in the cache key, so user A's balance is served to user B.
Rule: never cache anything with `Authorization`/`Cookie` unless you have
explicitly reasoned about the key, and `X-Cache-Status` in responses so you can
prove what happened.

**Q13. What do 502, 504 and 499 tell you?**
502 — NGINX reached the upstream and it failed or refused: process down, wrong
port, upstream crashed mid-response, or a keepalive connection reused after the
backend closed it. 504 — the upstream accepted but didn't answer within
`proxy_read_timeout`: the backend is slow or hung, and raising the timeout is
usually treating the symptom. 499 — the *client* gave up first; this is NGINX
reporting your own latency back to you, and it often correlates with a client-side
timeout shorter than yours, which means your timeout budget is inconsistent
across the stack.

**Q14. Load testing shows a hard ceiling. Where do you look?**
Layer by layer: `worker_connections` × workers versus concurrency (remembering
each proxied request consumes two connections), file descriptor limits
(`worker_rlimit_nofile` and the systemd unit's `LimitNOFILE`), ephemeral port
exhaustion toward upstreams (fixed by keepalive pools), `somaxconn`/backlog and
`tcp_max_syn_backlog`, TLS handshake CPU (fixed by session resumption and
keepalive), and only then the upstream itself. `stub_status` gives you
active/waiting/handled counts, and the gap between `request_time` and
`upstream_response_time` tells you whether the cost is yours or the backend's.

---

## Kubernetes

**Q15. Ingress vs Gateway API — what would you deploy today?**
Gateway API for anything new. Ingress's feature set stops at host/path routing,
so everything real — rate limits, rewrites, canary weights, auth — lives in
controller-specific annotations that are unvalidated strings, unportable, and
frequently a security surface. Gateway API separates the roles (platform team
owns Gateway, app team owns HTTPRoute) and makes traffic splitting and header
matching typed fields. I'd still run ingress-nginx where it exists rather than
migrating for its own sake.

**Q16. Why disable snippet annotations in ingress-nginx?**
`configuration-snippet` and `server-snippet` let any user who can create an
Ingress inject raw NGINX config into the shared edge — read other namespaces'
secrets via the controller's service account, log request bodies, or route
traffic elsewhere. It's been a repeated CVE class. Set
`allow-snippet-annotations: false`, and if a team needs behaviour the annotations
don't cover, that's a platform request with review, not a self-service escape
hatch. _(regulated)_ This is also the difference between "the edge is a product"
and "the edge is a shared config file".

**Q17. How do you do a canary with ingress-nginx?**
A second Ingress object with the same host and path, `canary: "true"` and
`canary-weight: "5"`, pointing at the canary Service — or `canary-by-header` for
a targeted cohort. That's the mechanism. What makes it a *safe* canary is the
part outside NGINX: metrics scoped to the canary pods only, an automated analysis
step that aborts on error rate or p99, and an alert when it aborts. A human
watching a dashboard is not a gate, and a silent auto-rollback that nobody
investigates just ships the same bug again next week.
