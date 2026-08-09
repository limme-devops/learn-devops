# DevSecOps — Interview Q&A

> **Author:** Mengty LIM

These are the questions where interviewers are listening for judgement rather
than tool names. Say what you'd enforce, what you'd let through, and why.

---

## Philosophy

**Q1. What does DevSecOps actually mean beyond the buzzword?**
Security controls expressed as code, run automatically on every change, that fail
the build — plus enforcement at the last mile because pipelines only protect
what goes through them. The cultural half matters as much: developers get
findings in seconds in their own workflow, with a fix suggestion, rather than a
PDF two weeks before go-live. If the security team is the bottleneck, engineers
route around them, and you've made things worse than before.

**Q2. Shift left — where does that argument go wrong?**
It's right and incomplete. Left-only misses everything that happens after build:
a new CVE in something already running, an expired certificate, a credential
rotated out from under a service, drift from someone with kubectl, a dependency
takeover upstream. So I shift left *and* keep the right: continuous rescanning of
deployed digests, admission control, runtime detection, and drift reconciliation.
The pipeline is a filter, not a guarantee.

**Q3. Your gates block a critical release. What do you do?**
Depends on the finding, and I'd want the exception path designed before that
night rather than invented during it. If it's exploitable and internet-facing, it
doesn't ship — that's the point of the gate. If it's a critical with no available
fix in a dependency the code never calls, that's an exception: recorded, with a
named owner, a compensating control (WAF rule, network restriction), and an
expiry date. What I won't do is disable the gate, because a gate that gets turned
off under pressure isn't a control, and the next team learns the same trick.

---

## Pipeline

**Q4. Walk me through the security stages of a build pipeline.**
Pre-commit: secret scanning and linters, so feedback is instant. CI on push:
secret scan over full history, SAST, dependency/SCA scan with licence checks,
IaC scanning. Then build the image on an ephemeral runner with no persistent
credentials, generate an SBOM, scan the image, sign the digest. Then deploy to an
ephemeral environment and run DAST plus contract tests. Push to the internal
registry with immutable tags. Deployment is a separate pull-based system —
ArgoCD — and the cluster's admission controller independently verifies the
signature and registry. The design property I'd highlight: no single identity can
both produce and deploy an artifact.

**Q5. SAST vs DAST vs SCA vs IAST?**
SAST reads source for vulnerable patterns — fast, early, and noisy with false
positives. SCA checks your dependencies against vulnerability databases, which is
where most real findings actually are, since most of your code isn't yours. DAST
attacks a running application, so it finds configuration and auth issues that
source analysis can't see, but needs a deployed environment and finds things
late. IAST instruments the running app to combine both. In practice SCA gives the
best return per unit of effort, SAST needs tuning to a curated ruleset or people
stop reading it, and DAST is a baseline scan on every build with a deeper
authenticated scan on a schedule.

**Q6. How do you avoid scan fatigue?**
Fail only on actionable findings: `--ignore-unfixed`, severity thresholds, and a
curated ruleset rather than every check the tool ships. Deduplicate across tools.
Route findings to the owning team automatically, with an SLA per severity rather
than "fix everything". And measure the gate itself — if a check produces mostly
false positives, it gets tuned or removed, because a wall of red that everyone
scrolls past is worse than no scanning, since it also gives false assurance.

---

## Secrets and supply chain

**Q7. How do you manage secrets across VM and Kubernetes tracks?**
Vault as the single broker. On VMs, a Vault Agent authenticates with the machine
identity and writes short-lived credentials to tmpfs, renewing them
automatically. In Kubernetes, External Secrets Operator or the Vault sidecar,
authenticating with the pod's ServiceAccount token. In both cases: database
credentials are *dynamic* with a one-hour TTL, cloud access uses OIDC workload
identity so there's no key material at all, and nothing long-lived sits in a
file. The property I'm buying is that a leaked credential expires on its own —
zero standing privilege makes disclosure survivable rather than catastrophic.

**Q8. A secret was committed to Git. Walk me through the response.**
Rotate first. The commit is already in every clone, every fork, every CI cache
and possibly a scraper's database, so removing it from history proves nothing
about exposure — treat it as disclosed from the moment it was pushed. Then: check
the audit logs for use of that credential during the exposure window, revoke it,
purge the history if the repo is private and you can coordinate the rewrite, and
add the detection that should have caught it (gitleaks in pre-commit and CI over
full history). Finally the systemic fix — if this credential could be pasted into
code at all, it was long-lived, and the real remediation is making it dynamic.

**Q9. How do you secure the software supply chain?**
Pin everything by digest — dependencies with lockfiles and checksums, base
images and CI actions by SHA, because a mutable tag is the standard attack path.
Build on ephemeral runners with no standing credentials and egress only to an
allowlisted mirror. Produce an SBOM and sign both image and SBOM with cosign.
Verify the signature at admission so the control can't be bypassed by pushing
directly. Mirror third-party dependencies internally so an upstream deletion or
takeover doesn't reach production. And separate duties so the build identity
can't deploy. That's roughly SLSA level 2–3, which is the language procurement
and auditors increasingly use.

**Q10. What is an SBOM good for, concretely?**
Answering "which of our images contains this package at this version" in seconds
instead of a week of rescanning. On the Log4Shell morning, teams with SBOM
attestations knew their exposure before lunch; teams without were grepping build
logs for days. It's also the input to licence compliance and, increasingly, a
contractual requirement.

---

## Kubernetes and runtime

**Q11. Why is admission control the last line of defence?**
Because it's in the apiserver request path, so it applies regardless of *how* the
object arrived — CI, ArgoCD, or a human with kubectl and a bad idea. A pipeline
gate only inspects things that went through the pipeline. So Kyverno or Gatekeeper
enforces the invariants that must hold no matter what: signed images from the
internal registry, no privileged pods, no `:latest`, resource limits present,
required ownership labels.

**Q12. Fail-open or fail-closed admission webhooks?**
Fail closed (`failurePolicy: Fail`) for security policies — otherwise an outage
of the policy engine silently disables every control, which is exactly when an
attacker would want it disabled. That commitment obliges you to run the engine
HA, exclude kube-system so you can still repair the cluster, and have a documented
break-glass. Fail-open is defensible only for advisory or mutating conveniences,
and I'd say so explicitly rather than pretending it's a free choice.

**Q13. What runtime detections would you deploy first?**
Interactive shell spawned in a container, writes to `/etc` or binary paths,
reading service account tokens or `/etc/shadow`, unexpected outbound connections,
and `kubectl exec` into a production pod. But I'd pair each with prevention:
default-deny egress means a compromised workload can't reach a C2 server at all,
which beats an alert saying it did. Detection without a responder is a log entry;
each rule needs a route to someone on call and a runbook.

**Q14. How do you handle a compromised container in production?**
Contain first: isolate it with a NetworkPolicy that denies all traffic rather
than killing it, because killing destroys the evidence and the attacker's
foothold may exist elsewhere. Snapshot the node and the container filesystem,
capture the process list and connections. Then rotate every credential that pod
could reach — its ServiceAccount token, its Vault leases, any database
credentials — assuming they're compromised. Then eradicate: replace the node,
redeploy from a known-good digest, patch the entry vector. Then the post-incident
review, focused on why the control that should have caught it didn't, without
blaming the person who tripped it.

---

## Governance

**Q15. How do you satisfy separation of duties with a fully automated pipeline?**
The pipeline itself provides it, better than a manual approval does. Developers
propose changes as pull requests; CODEOWNERS requires review from someone else;
protected branches prevent self-merge; CI builds and signs but holds no
production credentials; ArgoCD in the cluster pulls from Git. So the act of
deploying to prod is a reviewed commit, and no single human can push code to
production alone. The evidence is Git history plus the ArgoCD sync record — which
is stronger and more searchable than a change-advisory-board minute.

**Q16. What evidence would you show an auditor?**
System-produced artefacts, not documents describing intent: Git history showing
review on every prod change; ArgoCD sync logs correlating commit to deployment
time; signed image attestations and their SBOMs; pipeline logs showing gates
running and their results; Vault audit logs showing credential issuance;
Kubernetes audit logs; the access-review records; and the timed results of
restore drills. The pattern to state clearly is that we don't write documents
claiming compliance — the platform emits the evidence as a side effect of
operating, which is why it's trustworthy.

**Q17. Break-glass access — how do you design it?**
It exists, because pretending it doesn't just produces an undocumented one.
Design: a separate identity requiring MFA and a second approver, time-boxed
(short TTL, auto-expiring), with elevated permissions issued dynamically by
Vault rather than a standing role, every action logged to an append-only store
the user cannot reach, an automatic page to the security channel on use, and a
mandatory post-use review. The test of the design is whether using it is *easy
enough* under pressure that nobody keeps a backdoor "just in case".

**Q18. How do you introduce all of this into an organisation that has none of it?**
Sequenced by risk reduced per unit of friction, and in *warn* mode first so you
learn the baseline before you break anyone's build. Order I'd argue for: secret
scanning (highest impact, near-zero false positives, easiest to justify), then
dependency scanning, then image scanning and pinned base images, then IaC
scanning, then admission control in audit mode, then flip to enforce with a
migration window, then signing, then runtime detection. Publish the SLA table
and exception process before the first gate blocks anything, and make sure the
first team you onboard is a willing one — a successful pilot recruits better
than a mandate.
