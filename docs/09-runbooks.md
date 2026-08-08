# Runbooks & Operational Procedures

## 1. Runbook template (copy this for every alert)

```markdown
# <Alert name / Procedure name>

**Severity:** P1 | **Owner:** <team> | **Last tested:** YYYY-MM-DD

## What this means
One sentence, in plain language, about user impact.

## Blast radius
Who/what is affected. What is NOT affected.

## First 3 commands
1. <command>   # what you're looking for
2. <command>
3. <command>

## Decision tree
- If X → do A (link)
- If Y → do B (link)
- If neither → escalate to <role>

## Mitigation
Steps, with exact commands. Mark destructive steps with ⚠.

## Verification
How you know it's fixed (specific metric/query, not "looks fine").

## Rollback
How to undo the mitigation if it makes things worse.

## Escalation
Primary → secondary → vendor/DBA/security. With contact method.

## Post-incident
Ticket to file, postmortem required Y/N.
```



## 2. Standard operating procedures to write first


| Procedure                              | Why it's first                             |
| -------------------------------------- | ------------------------------------------ |
| Deploy to prod (K8s and VM)            | Most frequent risky action                 |
| Roll back a deployment                 | You will need it under pressure            |
| Restore a database (PITR)              | See `07-backup-dr.md`                      |
| Break-glass production access          | Must be defined *before* the outage        |
| Rotate a compromised credential        | Security incident hour zero                |
| Scale a service under load             | Predictable event, shouldn't need thinking |
| Drain and patch a node                 | Monthly routine                            |
| Certificate expiry / emergency renewal | Classic 2am outage                         |
| Vault sealed / unseal ceremony         | Blocks everything else                     |
| Cluster upgrade                        | Quarterly, high blast radius               |
| Failover to DR                         | Annual drill, must be written              |




## 3. Break-glass access (define this explicitly)

Bank auditors will ask exactly how a human gets root in prod, and how you'd know.

1. Normal state: **no human has standing prod access.** Access is via GitOps, or via read-only observability tooling.
2. Break-glass requires: an incident ticket, approval from a second person (on-call lead), and a stated time box (default 2h).
3. Access is granted by Vault (short-lived SSH cert / K8s token bound to a temporary role), never by adding a permanent user.
4. The session is recorded (PAM/session recording) and every command is logged to an immutable store.
5. Granting break-glass **fires an alert to SecOps** — visibility, not permission, is the control.
6. Access auto-expires. Post-incident review verifies: was it needed, what was done, did it get revoked.



## 4. Change management flow (regulated environment)

```
Idea → MR (code/IaC/gitops)
     → automated gates pass (see 03-security-baseline.md)
     → peer review (CODEOWNERS)
     → change ticket raised (standard / normal / emergency)
     → CAB approval for normal+ changes (or pre-approved "standard change" template)
     → scheduled window (prod: business hours, not Fri PM, not month-end/quarter-end close)
     → deploy via pipeline (never manual)
     → verification: smoke test + SLO dashboard watch for 30 min
     → close ticket with evidence links (pipeline run, Argo sync, dashboards)
```

**Standard changes** (pre-approved, low risk, well-automated — e.g. a routine app version bump with an automated canary) should be the majority. If every deploy needs a CAB meeting, teams will batch changes, and big batches are what actually cause outages.

**Emergency changes:** allowed to bypass CAB, never allowed to bypass the pipeline or the audit trail. Retro-approval within 24h, postmortem mandatory.

## 5. Incident response flow

```
Detect (alert / customer report)
  → Declare severity + open incident channel + assign Incident Commander
  → Communicate (status page / stakeholders — in a bank, check the regulatory notification clock)
  → Mitigate first, diagnose second   ← restore service before finding root cause
  → Verify recovery against the SLI, not against a feeling
  → Stand down, write timeline while fresh
  → Blameless postmortem within 5 business days
  → Action items tracked to completion with owners and dates
```

Roles during an incident: **Incident Commander** (decides, doesn't debug), **Ops lead** (executes), **Comms** (updates stakeholders), **Scribe** (timeline). One person may hold two roles in a small team, but never IC + Ops.

**Security incident differences:** do not restart/rebuild before forensics decide — you may destroy evidence. Isolate rather than terminate. Notify Security first, and expect a regulatory reporting obligation with a hard deadline (often 24–72h).

## 6. Routine operational calendar


| Cadence     | Task                                                                                                              |
| ----------- | ----------------------------------------------------------------------------------------------------------------- |
| Daily       | Backup success check (automated alert), overnight batch verification, alert review                                |
| Weekly      | Golden image rebuild, dependency/CVE review, capacity trend check                                                 |
| Monthly     | OS patching window, restore drill (single table/object), alert-noise review, access review                        |
| Quarterly   | Cluster upgrade, PITR drill, namespace restore drill, DR readiness check, secret rotation, pentest of new surface |
| Half-yearly | Full cluster rebuild drill, Vault unseal ceremony rehearsal, key rotation                                         |
| Annually    | Full DR failover + failback, ransomware restore drill, external pentest, policy & threat-model review             |


Put every one of these in a scheduler with an owner. Anything not scheduled will not happen.

## 7. Capacity & cost hygiene

- Track: node CPU/memory allocation vs actual, PVC growth rate, log/metric ingest volume, and cost per service (via labels: `team`, `cost-center`, `data-class`).
- Right-size quarterly using VPA recommendations — over-requested resources are the #1 waste in K8s.
- Forecast growth 6 months out for storage and node count; procurement lead times in banks are long, so plan early.
- Alert on trends, not just thresholds: "PVC will be full in 14 days" beats "PVC is 95% full".

