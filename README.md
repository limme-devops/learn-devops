# Secure Deployment Platform

Reference implementation and planning docs for a bank-grade secure deployment
platform across two delivery tracks: **VM servers** and **Kubernetes**.

This is a monorepo for learnability. In production, split it along the
boundaries in [docs/02-repo-structure.md](docs/02-repo-structure.md) §1 — app
code and deployment state must not share an access-control boundary.

> **Placeholders**: hostnames (`*.bank.internal`), UUIDs, image digests and
> checksums are marked `CHANGE_ME` or filled with zeros. Nothing here contains a
> real credential — that is enforced by `gitleaks` in pre-commit and CI.

---

## Layout

```
learn-devops/
├── docs/                  Planning: architecture, security, DR, strategies
├── infra/
│   ├── terraform/         Infrastructure lifecycle (VMs, network, clusters)
│   │   ├── modules/       Reusable: network, compute-vm, k8s-cluster
│   │   └── environments/  Composition + values only — no resource blocks
│   └── ansible/           Host config, hardening, VM app deployment
│       ├── inventories/   Static skeleton; hosts generated from Terraform
│       ├── playbooks/     site, bootstrap, harden, deploy-app, patch
│       └── roles/         baseline, hardening_cis, vault_agent, app_deploy,
│                          haproxy, observability_agents
├── gitops/                Everything inside Kubernetes
│   ├── bootstrap/argocd/  The only thing applied by hand
│   ├── apps/              App-of-apps Application definitions
│   ├── platform/          Platform components (CNPG, Vault, MinIO, …)
│   └── business/          Per-service base + per-environment overlays
├── apps/payment-service/  Reference service: Dockerfile, source, SLO, runbook
├── security/
│   ├── kyverno/           Admission policies (the last line of defence)
│   ├── vault/             Policies as code + setup script
│   └── falco/             Runtime detection rules
├── ci/
│   ├── gitlab/templates/  Reusable security stage
│   ├── jenkins/           VM rollout orchestration
│   └── scripts/           bump-digest (promotion), smoke (verification)
├── observability/         Grafana as code: datasources, dashboards, alert routing
├── local-lab/             kind cluster — run and break this locally
├── cheatsheets/           Per-tool quick reference + interview Q&A
└── Makefile               make help
```

## Documents

| # | Doc | Covers |
|---|---|---|
| 00 | [Master Plan](docs/00-master-plan.md) | Assumptions, environments, 10 core concepts, 26-week roadmap |
| 01 | [Architecture](docs/01-architecture.md) | Network zoning, VM track, K8s track, request path |
| 02 | [Repo Structure](docs/02-repo-structure.md) | Folder layout, branching, change control |
| 03 | [Security Baseline](docs/03-security-baseline.md) | Pipeline gates, Vault, supply chain, K8s controls, compliance |
| 04 | [Platform Services](docs/04-platform-services.md) | Vault, PostgreSQL, Keycloak, MinIO, Redis, Kafka |
| 05 | [CI/CD & Automation](docs/05-cicd-automation.md) | GitLab CI, Jenkins, Ansible, Terraform, ArgoCD |
| 06 | [Observability](docs/06-observability.md) | Metrics, logs, traces, SLOs, alerting, retention |
| 07 | [Backup & DR](docs/07-backup-dr.md) | 3-2-1-1-0, RTO/RPO tiers, immutability, restore drills |
| 08 | [Microservices](docs/08-microservices.md) | Boundaries, communication, resilience patterns |
| 09 | [Runbooks](docs/09-runbooks.md) | Templates, break-glass, change management, incidents |
| 10 | [Deployment Strategies](docs/10-deployment-strategies.md) | Canary, blue/green, migrations, rollback, freezes |
| 11 | [Deployment Roadmap](docs/11-deployment-roadmap.md) | **Step-by-step build order**, core concepts, verification per step |
| 12 | [Stakeholder Communication](docs/12-stakeholder-communication.md) | Working with PM, PO, Ops; question bank; meeting procedures |
| 13 | [Edge & API Gateway](docs/13-edge-gateway.md) | NGINX, ingress-nginx, Kong; TLS, headers, rate limits, retries |
| 14 | [Promotion Procedure](docs/14-promotion-procedure.md) | dev→staging→preprod→prod, image build/tagging, CI variable injection |
| 15 | [Logging & Monitoring Procedure](docs/15-logging-monitoring-procedure.md) | Loki/Kibana tiers, Grafana as code, Gravitee API metrics, alert lifecycle |
| 16 | [Private-Access Deployment](docs/16-private-access-deployment.md) | Internal-only services: split-horizon + wildcard DNS/TLS, VPN, OIDC per app, verification matrix |

**Reading order** — building: **11** → 01 → 02 → 03 → 05 → 10 → 04 → 06 → 07 ·
learning: 00 → 03 → 01 → 04 → 06 → 07 → 08 · auditing: 03 → 07 → 09 ·
before any meeting: 12

Start at **[docs/11-deployment-roadmap.md](docs/11-deployment-roadmap.md)** — it
sequences everything else into 21 steps, each with its own verification and exit
criteria.

## Cheat sheets

The `docs/` set explains *why this platform is built this way*.
**[cheatsheets/](cheatsheets/)** is the per-tool quick reference for when you are
doing the work — and the interview answers that go with each one. Every folder
holds a `README.md` (commands, config, best practices, gotchas) and an
`interview-qna.md`.

| Folder | Covers |
|---|---|
| [00-interview-playbook](cheatsheets/00-interview-playbook/) | How to answer, cross-cutting system design, red flags, rapid-fire definitions |
| [01-docker](cheatsheets/01-docker/) | Images, layers, multi-stage builds, Compose, registries, runtime hardening |
| [02-kubernetes](cheatsheets/02-kubernetes/) | Workloads, probes, networking, RBAC, scheduling, debugging, Helm/Kustomize |
| [03-ansible](cheatsheets/03-ansible/) | Inventory, roles, idempotency, Vault, rolling VM deploys |
| [04-nginx](cheatsheets/04-nginx/) | Reverse proxy, TLS, rate limits, caching, tuning, ingress-nginx |
| [05-kong](cheatsheets/05-kong/) | DB-less config, plugin order, consumers, JWT/OIDC, KIC |
| [06-gravitee](cheatsheets/06-gravitee/) | APIM, policies, plans/subscriptions, sharding tags, AM |
| [07-grafana-prometheus](cheatsheets/07-grafana-prometheus/) | PromQL, rules, dashboards, SLOs, burn-rate alerting |
| [08-elk-kibana](cheatsheets/08-elk-kibana/) | Elasticsearch, ILM, shipping, KQL, log hygiene |
| [09-devsecops](cheatsheets/09-devsecops/) | Pipeline gates, SBOM, signing, admission control, compliance evidence |
| [10-cicd-gitops](cheatsheets/10-cicd-gitops/) | GitLab CI, Jenkins, ArgoCD, promotion by digest, rollback |
| [11-terraform](cheatsheets/11-terraform/) | HCL, state and locking, modules, environments, drift, policy gates |
| [12-vpn-private-access](cheatsheets/12-vpn-private-access/) | WireGuard/IPsec, split tunnel, split-horizon DNS, bastions, identity-aware proxies |

## Start here

```bash
pip install pre-commit && pre-commit install   # same gates CI runs
make help                                      # all targets
make lab-up                                    # local kind cluster (~5 min)
```

Then read [local-lab/README.md](local-lab/README.md) — it lists five exercises
that make the abstract controls concrete (prove a NetworkPolicy works, watch a
canary abort, break a probe on purpose).

## Where the interesting parts live

| Concept | Implementation |
|---|---|
| Zone segmentation, default-deny firewall | `infra/terraform/modules/network/main.tf` |
| Golden-image VM pools, no in-place mutation | `infra/terraform/modules/compute-vm/main.tf` |
| Terraform → Ansible inventory handoff | `modules/*/outputs.tf` → `ansible_inventory` |
| CIS hardening, audit rules, SIEM shipping | `infra/ansible/roles/hardening_cis/` |
| Zero static credentials on a VM | `infra/ansible/roles/vault_agent/` (tmpfs + dynamic DB creds) |
| Blue/green VM rollout with LB drain | `infra/ansible/playbooks/deploy-app.yml` |
| Canary with automated analysis + abort | `gitops/business/payment-service/base/rollout.yaml` + `analysistemplate.yaml` |
| Default-deny NetworkPolicy (incl. the DNS rule people forget) | `.../base/networkpolicy.yaml` |
| Dynamic DB credentials in K8s | `.../base/externalsecret.yaml` |
| Expand/migrate/contract schema changes | `.../base/migration-job.yaml` |
| Burn-rate SLO alerts + business alerts | `.../base/prometheusrule.yaml` |
| Promotion = one digest commit | `ci/scripts/bump-digest.sh` |
| Admission control, fail-closed | `security/kyverno/baseline-policies.yaml` |
| Rebuild all of Grafana from git | `observability/grafana/` (pinned uids, Terraform routing) |
| Least-privilege Vault policy | `security/vault/policies/payment-service.hcl` |
| Hardened NGINX edge (validated reload, no snippet sprawl) | `infra/ansible/roles/nginx_edge/` |
| Kong DB-less gateway, plugin order, `retries: 0` on payments | `gitops/platform/kong/` |

## Non-negotiables

1. Everything as code — no manual change reaches any environment.
2. Build once, promote the same **digest**. Never `latest`.
3. CI never holds prod credentials — ArgoCD pulls, CI pushes a commit.
4. Vault is the only place a credential lives. Zero standing privilege.
5. Default deny: network, RBAC, egress, firewall, admission.
6. Every service ships with probes, limits, NetworkPolicy, SLO, dashboard, runbook.
7. A backup is not a backup until a restore has been drilled and timed.
8. Every prod change has a **tested** rollback.
