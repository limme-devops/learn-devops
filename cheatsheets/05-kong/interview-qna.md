# Kong — Interview Q&A

---

## Concepts

**Q1. What does an API gateway do that a reverse proxy doesn't?**
A reverse proxy routes and load balances. A gateway adds the *API product*
concerns: consumer identity, credentials and their rotation, per-consumer quotas
and plans, request/response transformation, protocol mediation, and per-API
analytics. The distinguishing primitive is the **Consumer** — once the gateway
knows who is calling, rate limits, ACLs and billing become possible. NGINX has
no concept of "who".

**Q2. Explain Kong's entity model.**
A Service is the upstream API. Routes match incoming requests (host, path,
method, header, SNI) onto a Service. Consumers are identified clients, with
credentials attached (API key, JWT public key, mTLS cert). Upstreams and Targets
give Kong its own load-balancing ring with active and passive health checks.
Plugins attach at global, service, route or consumer scope, with the most
specific combination winning. Understanding the scope precedence is what stops
you from debugging "the rate limit isn't applying" for an hour.

**Q3. DB-less vs database mode — which and why?**
DB-less by default: configuration is a declarative file in Git, every gateway pod
is identical and immutable, there's no Postgres to run, back up, patch and
secure, and the Admin API's write path — the most dangerous surface Kong has —
simply doesn't exist. Costs: no runtime writes (a feature, not a bug, in a
regulated shop), rate-limiting counters need Redis rather than the database, and
a few plugins that require persistence (OAuth2 token storage, consumer
self-service in the portal) are unavailable. If I needed those, I'd use hybrid
mode — control plane with a database, stateless data planes — rather than giving
every gateway node a database connection.

---

## Plugins and ordering

**Q4. Why did enabling auth break our browser client but not curl?**
Almost always CORS ordering. Browsers send a preflight `OPTIONS` with no
credentials — that's the spec — so if the auth plugin runs before CORS, the
preflight gets a 401 and the browser never sends the real request. Kong executes
access-phase plugins in descending priority, and CORS (~2000) must sit above auth
(~1450). curl doesn't preflight, which is why it "works".

**Q5. Rate limiting: `local` vs `redis` policy?**
`local` keeps counters in each Kong worker's memory, so with N pods and M workers
the effective limit is N×M times what you configured — and it resets on every
restart and rebalances on every scale event. `redis` gives cluster-wide truth at
the cost of a Redis round trip per request and a new dependency in the hot path.
For a real limit, use redis with `fault_tolerant: true` so a Redis outage
degrades to allowing traffic rather than failing the API — you have to decide
that trade-off deliberately, because the other choice (fail closed) turns a cache
outage into an API outage.

**Q6. Where should rate limiting live in a layered edge?**
At several layers, but with **different keys**. The CDN/WAF limits per source IP
for volumetrics. The ingress does a cheap per-IP limit as a backstop. Kong limits
per authenticated *consumer*, which is the only limit that expresses fairness —
per-IP is meaningless when thousands of mobile users share a carrier NAT. The
rule I'd state explicitly: never limit on the same key at two layers, because the
limits interact unpredictably and no one can explain the 429 to the customer.

**Q7. How do you rotate an API key with zero downtime?**
Kong consumers can hold multiple credentials, so: issue a second key, publish it
to the consumer, wait for traffic on the old key to reach zero — which you can
see because the gateway logs which credential was used — then delete the old one.
The pattern generalises: overlap, observe, remove. The observability step is the
one people skip, and then the removal is a guess.

---

## Security

**Q8. Why must the Admin API never be exposed?**
It's unauthenticated by default and it's total control: add a route to exfiltrate
traffic, disable auth plugins, dump consumer credentials. There have been real
breaches from Admin APIs bound to 0.0.0.0. Defence is structural, not
documentary: DB-less removes the write path, and the NetworkPolicy in this repo
has no ingress rule mentioning port 8444 at all, so it's unreachable from
anywhere in the cluster. Access is via `kubectl port-forward`, which is
authenticated and audited.

**Q9. How would you implement OIDC authentication at the gateway with Keycloak?**
The `openid-connect` plugin (Enterprise) does discovery against Keycloak, caches
JWKS and honours key rotation, validates issuer, audience, expiry and algorithm,
and optionally introspects opaque tokens. Kong then forwards a verified identity
to upstreams — as a signed header or the original token — so services don't each
reimplement validation. On OSS, the `jwt` plugin validates signature and claims
against a per-consumer public key, but you own JWKS rotation yourself. Two things
I'd insist on either way: the algorithm allowlist must be explicit (`alg: none`
and RS256/HS256 confusion are classic bypasses), and upstream services must not
trust identity headers from anywhere except the gateway — which is what the
default-deny NetworkPolicy enforces.

**Q10. Should upstream services still authenticate requests?**
They should verify *something*, because "the gateway checked it" is only true
while nothing can bypass the gateway. The layered answer: network policy so only
Kong can reach the service, mTLS so the service can prove the caller is Kong, and
the service validating the forwarded identity token rather than a plain header.
What they should *not* do is implement a second, independent authentication
policy — that's the drift problem again. Verify the gateway's assertion; don't
duplicate the gateway's decision.

---

## Operations

**Q11. How do you manage Kong config as code?**
On Kubernetes, the Kong Ingress Controller with CRDs (KongPlugin,
KongClusterPlugin, KongConsumer, plus Ingress/HTTPRoute), all in Git and
reconciled by ArgoCD. Outside Kubernetes, decK: `deck gateway diff` in the merge
request so a reviewer sees the exact change, `deck gateway sync` in the deploy
job. Either way the same principle as the rest of the platform — Git is the
intent, a controller converges, and a human running `curl` against the Admin API
is an incident, not a workflow.

**Q12. A gateway config change took down all APIs. How do you prevent that?**
Treat the gateway as a product with a release process, because it's the one
component where a single bad line affects every service. Concretely: schema
validation in CI (`deck validate`), a rendered diff in the MR, deployment to a
non-prod gateway with contract tests, canary rollout of the gateway pods
themselves (a second deployment taking a slice of traffic), automated rollback on
error-rate, and a change window with a tested revert commit. Plus blast-radius
design: separate gateway instances or at least separate ingress paths for
critical versus non-critical APIs, so "all APIs" is a smaller set than it sounds.

**Q13. Latency went up after adding plugins. How do you find the culprit?**
Kong exports total request latency and upstream latency separately; the gap is
Kong's own processing, so first confirm the regression is in the gap and not in
the backend. Then bisect by scope — plugins are additive per route, so disable
the newest one on a canary route and compare. The usual offenders are anything
making a network call in the access phase: introspection without token caching,
Redis rate limiting on a hot path, external auth callouts, and body-transforming
plugins that force full request buffering.

**Q14. Kong or Envoy/Istio?**
Different jobs. Envoy is a superb dataplane and, as a mesh, owns east-west mTLS,
retries and per-hop telemetry. Kong owns north-south API-product concerns:
consumers, credentials, quotas, plans, transformations. In this platform they
coexist — mesh for service-to-service identity, Kong for the API perimeter. I'd
push back on "replace Kong with Istio ingress": you'd be reimplementing consumer
management in EnvoyFilters, which is a worse version of a solved problem.

**Q15. Why `retries: 0` on a payments service?**
Because a timeout doesn't tell you the request wasn't processed. Kong's default
of 5 retries on a POST that debits an account is a double-charge generator. The
correct design is idempotency keys in the application so a retry is *safe*, and
until that exists, no retries at the gateway. More generally: retries belong at
one layer only, with a budget, on requests that are provably idempotent —
otherwise a slow dependency gets retry-amplified into an outage.

**Q16. Kong vs Gravitee — when would you pick each?**
Kong when the primary need is a fast, programmable gateway in front of internal
services, managed as code, with a strong plugin ecosystem. Gravitee when the API
is a *product* sold or exposed to third parties and you need the management
layer: a developer portal, self-service subscriptions, plans with tiers and
approval workflows, API lifecycle stages, and consumption analytics for billing.
You can build a portal on top of Kong (Enterprise has one), but if the portal
and subscription workflow are the point, Gravitee starts closer to done.
