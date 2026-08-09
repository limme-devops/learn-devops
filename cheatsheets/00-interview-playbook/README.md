# Interview Playbook

How to answer DevOps / platform / SRE interview questions so the answer survives
the follow-up.

---

## 1. The shape of a good answer

Most candidates give an answer. Strong candidates give an answer **with a
trade-off and a failure mode**. The structure that works for nearly every
technical question:

```
1. Direct answer          "Use a histogram, not a summary."
2. Why                    "Summaries compute quantiles client-side, so they
                           can't be aggregated across replicas."
3. Trade-off / limit      "Histograms cost more series, so bucket choice matters."
4. What you'd do          "I'd define buckets around the SLO threshold."
```

Four sentences. Then stop talking. Silence invites the follow-up you want, and
the follow-up is where you differentiate.

### Signals interviewers are actually scoring

| They're testing | You show it by |
|---|---|
| Depth vs buzzwords | Naming a specific failure you've seen, not the feature list |
| Judgement | Saying what you'd *not* do, and when the "best practice" is wrong |
| Blast-radius thinking | Mentioning what breaks and who it affects, unprompted |
| Operational maturity | Rollback, runbook, alert, and "how do I know it worked" |
| Honesty | "I haven't run that in production, but here's how I'd reason about it" |
| Collaboration | Talking about the developers who use your platform as users |

---

## 2. For incident / experience questions: STAR, briefly

**Situation → Task → Action → Result**, with the result quantified and a lesson.
Keep it under 90 seconds; offer depth rather than delivering it uninvited.

> "Our checkout API started returning 5xx at 20% (S). I was on call and owned
> mitigation (T). Error rate correlated with a deploy 6 minutes earlier, so I
> rolled back the digest commit before diagnosing; recovery took 4 minutes (A).
> Root cause was a liveness probe that checked the database, so a DB failover
> restarted the whole fleet. We changed liveness to be dependency-free and added
> a test that asserts it. Same DB failover happened two months later with no
> customer impact (R)."

The last sentence is the one that lands: you fixed the class, not the instance.

**Have three of these ready**: an outage you mitigated, a system you designed,
and a disagreement you resolved. Rehearse them out loud once — written-out
answers sound written-out.

---

## 3. Cross-cutting questions and how to attack them

**"Design a deployment pipeline for us."**
Ask two questions first: what's the compliance/regulatory context, and what's the
current rollback story. Then answer in layers — source and review, build once
with gates, artifact registry with immutable digests, promotion as a reviewed
commit, pull-based deployment, progressive delivery with automated analysis,
observability and rollback. Name the trade-off you chose: e.g. "manual gate on
prod promotion, which costs lead time and buys an audit-friendly control point".

**"Walk me through what happens when a user's request is slow."**
Follow the request path and say which signal you'd check at each hop: DNS →
CDN/WAF → LB → ingress (its own latency vs upstream latency) → gateway (plugin
overhead) → service (traces) → database (slow query log, lock waits) → downstream
dependencies. The skill being tested is having a *path*, not knowing the answer.

**"How do you know your system is healthy?"**
SLOs on user-facing symptoms, error budget burn, the four golden signals per
service, plus business metrics that catch failures the technical ones miss (a
provider returning HTTP 200 with a declined body looks perfect on an error-rate
dashboard). Add the meta-answer: a dead-man's switch, because a monitoring system
that dies silently is worse than none.

**"Your team wants to deploy on Friday afternoon. What do you say?"**
The strong answer isn't yes or no — it's "what makes Friday different?" If you
have canary with automated abort, tested rollback, and on-call coverage, Friday
is Tuesday. If the answer is "we'd be scared", the fix is the deploy process, not
the calendar. Blocking Friday deploys permanently just makes Monday's batch
bigger and riskier.

**"How would you improve our platform?"**
Never lead with a tool. Lead with a question about what hurts: lead time,
incident frequency, on-call load, developer self-service. Then propose the
smallest change with the largest effect, and say how you'd measure whether it
worked. Proposing a service mesh in the first five minutes is the fastest way to
look junior.

**"What's your biggest weakness / a mistake you made?"**
Pick a real one with a real consequence and a systemic fix. "I once ran a
`terraform apply` against the wrong workspace and deleted a staging database. It
was recoverable, but the lesson was that the guardrail was missing, not that I
was careless — we added workspace confirmation and separate credentials per
environment." Avoid the humblebrag; interviewers hear it every time.

---

## 4. Questions to ask them (these are scored too)

- How do you deploy to production, and how long does a rollback take?
- What's the on-call rota and load? Who carries the pager for this team?
- What broke most recently, and what changed afterwards?
- How much of the platform is reproducible from Git alone?
- What's the biggest source of toil, and who owns reducing it?
- How do developers get a new service into production — self-service or ticket?

The answers tell you whether the job is engineering or firefighting.

---

## 5. Rapid-fire definitions

| Term | One-line answer |
|---|---|
| Idempotency | Applying twice produces the same result as once |
| Immutable infrastructure | Replace, never mutate; drift becomes impossible |
| Declarative vs imperative | Describe the destination vs the steps |
| Blue/green | Two full environments, flip traffic |
| Canary | Small traffic slice to the new version, measured, then widened |
| Feature flag | Release decoupled from deploy; toggle is the rollback |
| SLI / SLO / SLA | Measurement / internal target / external contract with penalties |
| Error budget | 1 − SLO; the failure you're allowed before you stop shipping |
| Toil | Manual, repetitive, automatable work that scales with the service |
| MTTR / MTBF | Time to restore / time between failures. Optimise MTTR first |
| RTO / RPO | How long to recover / how much data you can lose |
| 3-2-1-1-0 backup | 3 copies, 2 media, 1 offsite, 1 immutable, 0 unverified restores |
| Least privilege | Minimum access, for minimum time |
| Zero standing privilege | No credential exists until it's needed; it expires itself |
| Defence in depth | Independent layers, so one bypass isn't a breach |
| Blast radius | How much breaks when this breaks |
| Cattle not pets | Named, hand-tended servers vs interchangeable replaceable ones |
| Shift left | Move checks earlier — without removing the ones on the right |
| Chaos engineering | Deliberately inject failure to verify the resilience you claim |
| Circuit breaker | Stop calling a failing dependency so you fail fast, not slowly |
| Backpressure | Signal upstream to slow down instead of collapsing |
| Thundering herd | Everything retries at once and finishes the victim off |
| Idempotency key | Client-supplied id that makes a retried write safe |
| Expand/contract | Schema change split so old and new code both work |
| Golden signals | Traffic, errors, latency, saturation |
| RED / USE | Rate-Errors-Duration for services / Utilization-Saturation-Errors for resources |
| Cardinality | Number of unique label combinations — Prometheus's cost model |
| SBOM | Machine-readable inventory of everything in an artifact |
| SLSA | Supply-chain integrity levels for build provenance |
| GitOps | Git is desired state; an in-cluster agent pulls and reconciles |
| Sidecar | Helper container sharing a pod's network and lifecycle |
| Service mesh | Sidecar/eBPF layer providing mTLS, retries, telemetry east-west |
| Admission control | In-apiserver gate that can reject any object, however submitted |
| Fail closed | On control failure, deny — the safe default for security |

---

## 6. Red flags to avoid saying

| Don't say | Say instead |
|---|---|
| "We just SSH in and fix it" | "Manual changes are an incident; here's the break-glass path" |
| "Kubernetes because it's standard" | "Kubernetes buys X, costs a platform team; here's when I wouldn't" |
| "100% test coverage" | "Coverage of the paths that carry risk, plus contract tests" |
| "We never have outages" | "Our change failure rate is N%; here's how we shrink blast radius" |
| "Security slows us down" | "Gates that block on actionable findings, with an expiring exception path" |
| "We'd roll forward" (unqualified) | "Roll forward when it's demonstrably faster than back — and we've measured" |
| "latest is fine internally" | "Digest pinning everywhere; mutable tags break rollback and provenance" |
| Naming a tool as the answer | Naming the problem, then the tool, then its cost |

---

## 7. Preparation checklist

- [ ] Three STAR stories rehearsed out loud: an outage, a design, a disagreement
- [ ] Can draw your last system's architecture from memory, including the request path
- [ ] Can state your rollback procedure and how long it takes
- [ ] Know the numbers: fleet size, RPS, p99, error budget, deploy frequency
- [ ] Can explain one thing you got wrong and what changed systemically
- [ ] Have read the company's engineering blog and postmortems, if public
- [ ] Six questions ready for them (§4)
- [ ] For each tool on your CV, one failure mode you've personally debugged

The last item is the highest-leverage preparation on this page. Interviewers
distinguish "I used Kubernetes" from "I've debugged a CrashLoopBackOff at 3am" in
about two questions.
