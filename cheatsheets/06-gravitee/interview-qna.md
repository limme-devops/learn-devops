# Gravitee — Interview Q&A

> **Author:** Mengty LIM

---

**Q1. What is Gravitee and how is it different from Kong?**
Gravitee is a full API management platform: a management API and console for
designing and publishing APIs, a developer portal where consumers discover APIs
and subscribe to plans, an analytics store, and a stateless gateway that enforces
the resulting policies. Kong is primarily a gateway — excellent at the data
path, with consumer management you typically drive from Git. The dividing
question is whether your API is an internal integration point or a *product*: if
partners need to self-serve a key against a published plan with an approval
workflow and you need consumption data for billing, Gravitee starts much closer
to done.

**Q2. Explain the component architecture.**
Management API is the source of truth, backed by MongoDB or a JDBC database.
Gateways are stateless and poll (or receive events) for their configuration —
default sync interval 5 seconds — so they can be scaled and replaced freely and
hold no local state. Analytics and gateway request logs go to Elasticsearch. The
management console and developer portal are SPAs on top of the management API.
The operational consequence: gateway availability doesn't depend on the
management API being up (it keeps serving the last synced config), but *config
changes* do.

**Q3. What is a Plan and why does it matter?**
A Plan is the published contract between the API and a consumer: authentication
type (keyless, API key, OAuth2, JWT, mTLS), rate limits and quotas, terms, and
whether subscription is automatic or requires approval. One API can publish
several plans at once, which is how you offer tiers without duplicating the API
definition. It also changes who does the work: onboarding a partner becomes a
portal subscription that an API owner approves, instead of a ticket to the
platform team. Plan lifecycle is staging → published → deprecated → closed, and
closing terminates subscriptions — so migrations need an overlap window.

**Q4. What are flows and how do policies execute?**
A flow is a phase (request or response) plus a condition plus an ordered list of
policies. Flows exist at platform, API and plan level and execute in that order,
with policies running in list order inside each. Conditions use Gravitee's
Expression Language over the request, context attributes and previously assigned
values. The practical debugging rule: when a policy "doesn't apply", it's nearly
always scope or condition — check whether the flow is on the plan the consumer
actually subscribed to.

**Q5. How do you manage Gravitee configuration as code?**
The Kubernetes Operator with `ApiDefinition` / `ApiV4Definition` CRDs, stored in
Git and reconciled by ArgoCD like everything else in the platform. The
alternative is exporting the API JSON and importing it via the management API in
CI. What I'd avoid is the console as the source of truth: it's a mutable store
with no review step, and in a regulated environment "who changed this API's
authentication and when" needs to be answerable from Git history, not a database
audit table.

**Q6. What are sharding tags?**
Labels that decide which gateways an API is deployed to. Tag a gateway
`internal,prod` and an API with `internal`, and only those gateways serve it.
It's the isolation primitive: one control plane, separate DMZ and internal
gateway fleets, or dedicated gateways for PCI-scoped APIs. It's also a foot-gun —
a mis-tagged API can be published on an internet-facing gateway — which is
exactly why tag assignment belongs in a reviewed manifest.

**Q7. A config change isn't taking effect. Debug it.**
First, Gravitee separates *saving* an API from *deploying* it — a genuinely
common trip-up, and CI must do both. Then: sync interval (default 5s, so wait
before concluding), gateway connectivity to the management API and database,
sharding tags (is this API deployed to the gateway you're testing?), and the plan
you're calling under. Gateway logs will show which plan and policy chain matched,
which usually ends the discussion.

**Q8. How do you enforce the API contract at the gateway?**
Import the OpenAPI spec and enable the `request-validation` policy, so requests
that don't match the schema are rejected before reaching the service. That's a
strong control: it moves input validation to the perimeter without changing the
backend, and it stops contract drift because the spec is the enforcement. Pair it
with `json-validation` on responses if you're exposing a third-party backend you
don't control.

**Q9. Rate limiting across multiple gateway pods?**
The default rate-limit repository is local to the node, so N pods give you N×
the configured limit. Configure the distributed repository (Redis or Hazelcast)
for cluster-wide counters. Also distinguish `rate-limit` (short burst window),
`quota` (long window — day/month, the thing your commercial plan sells) and
`spike-arrest` (smooths bursts). Selling a "1M calls/month" plan and enforcing it
with a per-node per-second limiter is a billing dispute waiting to happen.

**Q10. Gravitee AM vs Keycloak?**
Both are OIDC/OAuth2 authorization servers with MFA, federation and adaptive
policies. AM's advantage is native integration with APIM — dynamic client
registration from the portal, token introspection wired into plans. Keycloak's
advantage is ubiquity: bigger community, more integrations, more people who've
operated it at 3am. Since both speak standard OIDC, the gateway policy config is
nearly identical, so I'd pick on operational familiarity rather than features,
which is why this platform uses Keycloak.

**Q11. What are the operational risks you'd flag before adopting Gravitee?**
Three. It's a bigger surface than a gateway — management API, database,
Elasticsearch, console, portal — so it needs its own backups, upgrades and
restore drills, and the analytics Elasticsearch grows fast. Second, full
request/response logging is tempting and expensive, and in a bank it's a data-
protection problem, so it must be off by default and never log bodies. Third,
the console makes it easy to bypass code review; without the operator and a "no
manual changes" policy you lose the audit trail that justified buying an API
management platform in the first place.

**Q12. When would you run both Gravitee and Kong?**
Rarely by design, usually by history — an acquisition, or an internal platform on
Kong and a partner-facing product on Gravitee. If I inherited both I'd make the
boundary explicit rather than converging for tidiness: one owns the external API
product perimeter, the other the internal service perimeter, with a written rule
about which one authenticates. Two gateways that both do authentication is the
same drift problem as an ingress and a gateway both validating JWTs, just more
expensive.
