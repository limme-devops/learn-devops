# CI/CD & GitOps — Interview Q&A

---

**Q1. What is GitOps, and what does it buy you over a push pipeline?**
Git holds the declarative desired state; an agent inside the target environment
continuously pulls and reconciles. Four concrete benefits: a complete, reviewed
audit trail of every production change for free; drift detection and automatic
repair of manual changes; rollback as `git revert`; and — the one people
undersell — CI never needs production credentials, because the cluster pulls
instead of the pipeline pushing. In a regulated environment that last point is
often what makes separation of duties workable without adding a manual approval
board.

**Q2. Why "build once, promote the digest"?**
Because rebuilding per environment produces a different artifact, and every test
you ran against the first one no longer applies. Different base image resolution,
different transitive dependency versions, a different build machine — any of them
can change behaviour. So CI builds one image, records its digest, and promotion
to each environment is a commit that changes that digest in the environment's
manifest. It also makes "what's in prod and which commit produced it" a question
you answer from the repo, and rollback a revert of one line.

**Q3. Where do environment differences live?**
In overlays or values files in one repo on one main branch — never in the image,
never in a branch per environment. Branch-per-environment is the classic
anti-pattern: branches drift, cherry-picks get missed, and merge conflicts hide
exactly the config changes you most need reviewed. The image must be identical
everywhere, configured at runtime, or you've broken the promotion guarantee.

**Q4. How do you do zero-downtime deployments?**
Mechanically: `maxUnavailable: 0` with surge so capacity never dips, readiness
failing at the start of shutdown so the endpoint is removed first, a `preStop`
delay longer than the load balancer's deregistration lag, an app that drains
in-flight requests on SIGTERM, and a grace period longer than all of that. Then
the part people forget: the *database*. During a rolling deploy both versions run
simultaneously, so every schema change must be backward compatible with N-1 —
expand, migrate, switch, contract as separate releases. Combining a schema change
with the code that requires it in one release is what makes rollback impossible.

**Q5. Canary vs blue/green — how do you choose?**
Blue/green when the cutover must be atomic and you can afford double capacity:
VM fleets, database-coupled applications, big-bang migrations. Rollback is
instant (flip the LB back), but at the moment of switch 100% of traffic is on the
new version, so your blast radius is everything for however long it takes to
notice. Canary when you want to *discover* the problem with 5% of users instead
of all of them; it costs about 10% extra capacity and needs both versions to
coexist, including against the same schema. For customer-facing production
services canary is my default, precisely because it converts "did it work?" from
a question into a measurement.

**Q6. What makes a canary actually safe?**
The automation, not the traffic split. Metric queries scoped to the canary pods
only — otherwise the stable pods' healthy traffic dilutes the canary's errors and
the analysis passes while users suffer. Automated abort on error rate and latency
thresholds, because a human watching a dashboard is not a gate. The old
ReplicaSet kept warm so abort is instant. And an alert when an abort happens: a
silent auto-rollback that nobody investigates means the same bug ships next week
with more confidence.

**Q7. Production is broken after a deploy. What's your sequence?**
Mitigate first, diagnose second. Roll back — revert the digest commit, or
`argocd app rollback` for speed and fix Git immediately after — then confirm
recovery with the same metrics that told you it was broken. Only then investigate
from the artifacts: logs, traces, the diff of the reverted commit. The
communication half matters: declare an incident, put someone on comms so the
responder isn't answering questions, and record the timeline as you go because
nobody reconstructs it accurately afterwards. Then a blameless review focused on
why the canary or the tests didn't catch it.

**Q8. How do you handle secrets in CI?**
Ideally there aren't any long-lived ones: the runner authenticates to Vault or
the cloud with its OIDC identity and receives short-lived credentials scoped to
the job. Where a stored credential is unavoidable, it's masked, environment-
scoped, protected so only protected branches can read it, and rotated
automatically. What I insist on: CI has no production deployment credential at
all — that's the pull model's job — so a compromised runner can't reach prod
directly.

**Q9. ArgoCD `selfHeal` and `prune` — would you enable them in production?**
Yes, both, and I'd expect pushback on each. `selfHeal` reverts manual changes,
which is exactly what you want — it makes "just patch it quickly in prod" stop
working and forces the fix through review — but it means an emergency manual
change gets undone, so the incident runbook must say "pause the Application
first". `prune` deletes resources removed from Git, which keeps reality matching
the repo but will happily delete a PVC someone removed by accident; mitigate with
`Prune=false` on stateful resources and by never letting two Applications own
overlapping resources.

**Q10. How do you prevent two deploys racing?**
`resource_group` in GitLab, `disableConcurrentBuilds` in Jenkins, or in GitOps
terms it's mostly moot because reconciliation converges to whatever Git says
rather than applying a sequence. The subtler race is deploy-versus-migration:
serialise them with sync waves or a PreSync hook so the migration Job completes
before the new pods start, and make the migration itself idempotent and safe to
run concurrently, because eventually it will be.

**Q11. Jenkins or GitLab CI — and does it matter?**
Less than people argue. GitLab CI is declarative, config lives in the repo, and
runners are naturally ephemeral — lower operational cost and better defaults.
Jenkins is more flexible and often already deeply embedded in an enterprise's VM
and approval workflows, which is why this platform keeps it for the VM rollout
track. What actually matters in either: pipeline definition in the repo, ephemeral
agents, no logic configured through a UI, credentials from a broker, and the same
gates. A Jenkins with everything in a shared library and Kubernetes agents is
better than a GitLab CI with fifty copy-pasted `.gitlab-ci.yml` files.

**Q12. What are the DORA metrics and how would you use them?**
Deployment frequency, lead time for change, change failure rate, and time to
restore. They're useful read together and dangerous read alone — optimising
frequency alone rewards recklessness, optimising change failure rate alone
rewards never shipping. I'd use them as a conversation starter about batch size:
long lead times and high failure rates almost always mean changes are too big,
and the fix is smaller, more frequent, better-guarded releases rather than more
process. And I'd resist making them team-comparison KPIs, because they're trivial
to game the moment someone's bonus depends on them.

**Q13. How do you test infrastructure changes before prod?**
Layered. Static: `terraform validate`, `tflint`, `checkov`, `kubectl diff`,
`helm template | kubectl diff`, `conftest` policy tests. Plan review: a
`terraform plan` in the merge request that a human reads, with destroy
operations flagged loudly. Ephemeral environments: spin up the change in a
throwaway namespace or workspace and run integration tests. Then staged rollout:
dev → staging with a soak period → prod, with prod itself canaried. And for the
Ansible track, Molecule tests including the idempotence check, plus
`--check --diff` against staging.

**Q14. What's in your definition of done for a production service?**
Beyond the code: a Dockerfile that meets the base standards, resource requests
and limits, three probes, a PodDisruptionBudget, a default-deny NetworkPolicy, a
dedicated ServiceAccount, an SLO with burn-rate alerts, a dashboard, a runbook
for each alert, a tested rollback, a backup with a drilled restore if it holds
state, and an entry in the service catalogue with an owning team. If any of those
is a follow-up ticket, the service isn't done — it's just running, which is a
different thing.
