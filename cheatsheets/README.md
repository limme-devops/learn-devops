# Deployment Cheat Sheets

> **Author:** Mengty LIM

Fast-reference material for the tools this platform runs on, plus the interview
answers that go with them.

Each folder holds exactly two files:

| File | What it is | Read it when |
|---|---|---|
| `README.md` | The cheat sheet — commands, config snippets, best practices, gotchas | You are doing the work |
| `interview-qna.md` | Questions you will actually be asked, with answers that hold up to a follow-up | You are preparing for an interview or a design review |

The cheat sheets are opinionated toward a **regulated / bank-grade** environment,
which is the same posture as the rest of this repo. Where a rule exists only
because of that posture, it is marked _(regulated)_ so you can drop it in a
startup context and know what you traded away.

---

## Index

| # | Folder | Covers |
|---|---|---|
| 00 | [interview-playbook](00-interview-playbook/) | How to answer DevOps interview questions, cross-cutting system-design questions, red flags |
| 01 | [docker](01-docker/) | Images, layers, multi-stage builds, Compose, registries, runtime security |
| 02 | [kubernetes](02-kubernetes/) | Workloads, networking, storage, RBAC, scheduling, debugging, Helm/Kustomize |
| 03 | [ansible](03-ansible/) | Inventory, playbooks, roles, idempotency, Vault, rolling VM deploys |
| 04 | [nginx](04-nginx/) | Reverse proxy, TLS, caching, rate limits, headers, tuning, ingress-nginx |
| 05 | [kong](05-kong/) | DB-less config, plugins and their order, consumers, JWT/OIDC, Kong Ingress |
| 06 | [gravitee](06-gravitee/) | API management, policies, plans/subscriptions, APIM vs Kong, AM/OIDC |
| 07 | [grafana-prometheus](07-grafana-prometheus/) | PromQL, exporters, recording/alert rules, dashboards, SLOs, burn rates |
| 08 | [elk-kibana](08-elk-kibana/) | Elasticsearch indexing, ILM, Logstash/Beats, KQL, Kibana dashboards, log hygiene |
| 09 | [devsecops](09-devsecops/) | Pipeline gates, SAST/DAST/SCA, secrets, SBOM, signing, admission control, compliance |
| 10 | [cicd-gitops](10-cicd-gitops/) | GitLab CI, Jenkins, ArgoCD, promotion by digest, deployment strategies, rollback |
| 11 | [terraform](11-terraform/) | HCL, state and locking, modules, environments, drift, policy gates, CI pipeline |
| 12 | [vpn-private-access](12-vpn-private-access/) | WireGuard/IPsec, split tunnel, split-horizon DNS, bastions, identity-aware proxies, private K8s access |
| 13 | [vault](13-vault/) | Seal/unseal, auth methods, dynamic secrets, PKI, Transit, policies, K8s injection, HA and DR |

---

## The 8 rules that survive every tool change

Interviewers rarely care whether you remember a flag. They care whether you
hold these:

1. **Build once, promote the artifact.** The thing tested in staging must be the
   same digest that reaches prod. Rebuilding per environment is not a promotion,
   it is a new and untested release.
2. **Immutable over mutable.** New container/AMI/VM, never `apt upgrade` on a
   live prod host. Drift you cannot see is drift you cannot roll back.
3. **Declare, then converge.** Git is the intent; a controller (ArgoCD, Ansible,
   Terraform) makes reality match. Nobody types into prod.
4. **Default deny** — network, RBAC, egress, admission, firewall. Allowlists are
   auditable; denylists are a game of whack-a-mole.
5. **Secrets are issued, not stored.** Short-lived, dynamic, from a broker
   (Vault). If a secret exists in a file forever, its rotation plan is fiction.
6. **Every change has a tested rollback.** "We'd roll forward" is only an answer
   if you can demonstrate the forward path is faster than the back path.
7. **Deploy ≠ release.** Ship dark behind a flag, release progressively. Then a
   bad release is a toggle, not an incident.
8. **If it is not observable, it is not in production.** Probes, metrics, logs,
   an SLO, a dashboard, an alert and a runbook are part of the definition of
   done — not a follow-up ticket.

---

## Related repo docs

The cheat sheets compress; these documents explain the reasoning.

- [docs/01-architecture.md](../docs/01-architecture.md) — zoning and the request path
- [docs/03-security-baseline.md](../docs/03-security-baseline.md) — what is enforced and where
- [docs/06-observability.md](../docs/06-observability.md) — metrics, logs, traces, SLOs
- [docs/10-deployment-strategies.md](../docs/10-deployment-strategies.md) — canary, blue/green, rollback
- [docs/13-edge-gateway.md](../docs/13-edge-gateway.md) — NGINX / Kong tier map
- [docs/14-promotion-procedure.md](../docs/14-promotion-procedure.md) — dev → prod by digest
- [docs/16-private-access-deployment.md](../docs/16-private-access-deployment.md) — the full private-access procedure
