# Cross-Cutting Interview Q&A

Questions that don't belong to a single tool: system design, reliability
judgement, and behavioural. Tool-specific questions live in the other folders.

---

## System design

**Q1. Design a deployment platform for a bank's payment service.**
Start by pinning the constraints, because they drive everything: regulatory audit
requirements, RTO/RPO, whether the workload is PCI-scoped, and existing estate.
Then the shape I'd propose: network zoning with default-deny between zones;
infrastructure from Terraform, host config from Ansible, everything in Git;
immutable artifacts built once and promoted by digest; pull-based deployment via
ArgoCD so CI holds no production credentials; Vault issuing short-lived dynamic
credentials so nothing has standing privilege; canary releases with automated
analysis and abort; observability with SLOs and burn-rate alerts; and admission
control enforcing the invariants fail-closed. The bank-specific parts are the
audit trail (Git history plus audit logs to an append-only SIEM), separation of
duties enforced by the pipeline structure rather than a review board, and backups
that are immutable with *drilled and timed* restores. I'd deliberately keep a VM
track alongside Kubernetes for workloads that don't belong in a scheduler.

**Q2. How would you make this system survive the loss of a data centre?**
Define RTO and RPO per tier first — the honest version is that "everything, zero
data loss" isn't a requirement, it's a budget request. Then: stateless services
run active/active across sites behind global load balancing; databases replicate
synchronously within a region and asynchronously across, with a documented,
practised failover; state that can't replicate gets a documented data-loss
window. The parts people forget: DNS TTLs short enough to actually fail over,
capacity in the surviving site to take 100% of load (not 50%), the secrets and
CI/CD infrastructure also being multi-site, and a *tested* failover — a DR plan
that has never been executed is a document, not a capability.

**Q3. A service's p99 latency has doubled. No deploys. Investigate.**
Confirm the signal first — is it all routes or one, all instances or a subset,
all customers or one tenant? That partition usually names the cause. Then walk
the path with the telemetry: gateway total-vs-upstream latency to see whether
it's the edge or the backend; traces to find which span grew; the database's slow
query log and lock waits; saturation signals (CPU throttling, connection pool
exhaustion, GC pauses, queue depth). "No deploys" doesn't mean nothing changed —
data volume crosses a threshold and an index stops being used, a dependency
deployed, a certificate rotated, a neighbour on the node got noisy, a cache hit
rate dropped. I'd also check whether the traffic *mix* changed rather than the
volume.

**Q4. How do you decide between Kubernetes and VMs for a workload?**
Elasticity, packing density and a common declarative API argue for Kubernetes;
the cost is an entire platform capability you must staff. I'd put stateless,
horizontally scalable services with variable load on Kubernetes; and keep on VMs
the things that fit badly — heavy stateful databases (or use a managed service),
workloads with kernel or licensing constraints, and anything where the team's
operational familiarity is the binding constraint. The answer I'd resist is
"everything on Kubernetes because it's standard": running a single-instance
database on a StatefulSet gives you the complexity of Kubernetes and none of its
benefits.

**Q5. How do you keep a platform's cost under control?**
Attribution first — you can't manage what isn't allocated, so labels/tags on
every resource enforced at admission, and a per-team dashboard. Then the usual
big levers: right-sizing requests (most clusters are 3–5× over-provisioned
because requests were guessed once), autoscaling with real headroom rather than
fixed peak capacity, spot/preemptible for fault-tolerant workloads, storage
lifecycle policies (logs and snapshots are usually the surprise line item), and
turning off non-prod out of hours. The cultural lever matters more than any of
them: showing teams their own spend changes behaviour faster than a central
optimisation project.

---

## Reliability judgement

**Q6. What's your approach to on-call?**
Every page must be actionable and have a runbook; anything that pages twice
without action gets fixed or deleted. The rota needs enough people that it's
sustainable, compensation, and explicit permission to fix the causes of pages
during working hours — otherwise on-call load only grows. I'd track pages per
shift as a first-class metric alongside DORA. And handover matters: a short
written handover beats a heroic individual who's the only one who knows how the
system behaves.

**Q7. What's a blameless postmortem and why does the "blameless" part matter?**
A written timeline, contributing factors, and action items with owners, focused
on why the system allowed the failure rather than who typed the command. It's not
about being nice: if people expect blame, they stop reporting near-misses and you
lose the cheapest source of information you have. The concrete test of whether
yours is blameless is whether the action items are systemic ("add a confirmation
guard", "make the rollback automatic") or personal ("Alice will be more
careful").

**Q8. When is chaos engineering appropriate, and when is it theatre?**
It's appropriate once you have observability good enough to detect the failure
you inject and a hypothesis you're actually testing — "we believe losing one AZ
causes no customer impact" is an experiment; "let's kill random pods" is
vandalism with a nice name. Start in staging, define blast radius and an abort
condition, run in business hours with the owning team present, and treat a
failed experiment as a success (you found it before a customer did). It's theatre
when it's run to satisfy a slide rather than to falsify a specific belief.

**Q9. How do you set an SLO for a service that has never had one?**
Measure current performance for a few weeks first — an SLO invented in a meeting
is either trivially met or immediately violated, and both are useless. Pick SLIs
that reflect user experience (successful request ratio, latency at a threshold
users notice), set the target slightly above current performance so it's
achievable but meaningful, and then use the error budget as a real decision tool:
when it's exhausted, feature work pauses for reliability work. If the
organisation won't honour that consequence, be honest with yourself that you have
a dashboard, not an SLO.

**Q10. Roll forward or roll back?**
Roll back by default, because it's the path you've tested and its outcome is
known. Roll forward when the previous version is genuinely not a safe target —
an irreversible migration, or the bug is in the old version too — and when you
can demonstrate the forward path is faster. The important discipline: decide
which one *before* the incident, per change, and record it in the change; a team
that improvises this at 3am chooses roll-forward because it feels productive, and
then debugs under pressure with customers affected.

---

## Behavioural

**Q11. Tell me about a production incident you handled.**
Use STAR and keep it to 90 seconds. Mitigate-then-diagnose should be visible in
the narrative, the result should be quantified, and the lesson should be systemic
— you fixed the class of failure, not the instance. If the incident was partly
your change, say so plainly; owning it reads as senior, not weak.

**Q12. Tell me about a technical disagreement and how it ended.**
Pick one where you were partly wrong, or where you lost and executed the other
decision well — those are more informative than a story where you were right.
What interviewers are listening for: did you argue from evidence or from
preference, did you find the shared constraint, and could you commit to a
decision you disagreed with without sabotaging it. "We agreed to try their
approach with a defined checkpoint, and at that checkpoint the data was clear"
is a strong ending in either direction.

**Q13. How do you handle a developer who wants an exception to a security gate?**
Understand the actual need first — the request is usually a symptom of a
platform gap, and "the scan blocks us" often means "our exception process takes
two weeks". If the finding isn't exploitable in their context, grant a
time-boxed, attributable exception with a compensating control and an expiry.
If it is, help them fix it, including doing some of the work. What I won't do is
silently disable the gate, because that trades a control for goodwill and the
next team learns the workaround. The long game is making the secure path the
easy path so exceptions become rare.

**Q14. You join and the platform has no tests, no monitoring, and manual deploys.
What do you do in the first 90 days?**
Days 1–30: listen and measure. Find out what breaks, how often, what on-call
actually does, and where lead time goes — with numbers, not impressions. Days
30–60: fix the thing that reduces risk fastest, which is almost always
observability (you can't improve what you can't see) followed by a repeatable
deploy and a tested rollback. Days 60–90: make it self-service for one willing
team and let the result recruit the others. What I'd avoid is arriving with a
target architecture: rewriting the platform before understanding why it looks
that way is how newcomers lose credibility in month four.

**Q15. Why do you want to work in platform/DevOps rather than product engineering?**
Answer honestly, but have one. A version that lands: the leverage — a platform
change improves every team at once, and the work sits where correctness,
security and operability meet, which is the part of software I find most
interesting. Mention that your users are developers, and that treating them as
users (with feedback loops, docs, and golden paths) rather than as ticket
submitters is what separates a platform from a gatekeeper. That framing tells an
interviewer you'll build something people adopt voluntarily.
