# Secure Deployment Platform — Master Plan

> Target posture: regulated / bank-grade production (PCI-DSS, ISO 27001, SOC 2 controls map cleanly onto this).
> Two delivery tracks run in parallel: **Track A — VM servers**, **Track B — Kubernetes**.

## 1. Assumptions (change these first if wrong)

| Item | Assumption |
|---|---|
| Hosting | On-prem / private cloud (VMware or bare metal), no public cloud dependency in prod |
| OS | RHEL 9 / Rocky 9 (CIS Level 2 hardened image) |
| Kubernetes | Self-managed RKE2 (or kubeadm), 3 control-plane + N workers, per-environment clusters |
| SCM + CI | GitLab (self-hosted) as SCM + primary CI; Jenkins retained for VM/legacy and long-running jobs |
| CD | ArgoCD (GitOps, pull-based) for K8s; Ansible (push) for VMs |
| IaC | Terraform for infra (vSphere/network/DNS/LB/cloud), Ansible for config |
| Secrets | HashiCorp Vault is the single source of truth; nothing else stores a long-lived credential |
| Identity | Keycloak as the IdP for apps + platform tooling (OIDC everywhere) |
| Registry | Harbor (private, with Trivy scanning + Cosign signature verification) |

## 2. Environments

| Env | Purpose | Cluster/VMs | Data | Approval to deploy |
|---|---|---|---|---|
| `dev` | Fast iteration | shared cluster, small VM pool | synthetic | auto on merge |
| `sit`/`test` | Integration + QA | separate namespaces | masked copy | auto on merge |
| `uat`/`staging` | Prod-mirror, perf + DR drills | separate cluster | masked prod copy | 1 approver |
| `prod` | Live | dedicated cluster, dedicated VMs | live | 2 approvers + change ticket |
| `dr` | Warm standby | second site | async replicated | break-glass |

**Non-negotiables:** prod is network-isolated from lower envs; no shared credentials, no shared Vault namespace, no shared cluster, no data flowing *upward* (prod → lower) except through an approved masking pipeline.

## 3. The 10 core concepts this platform is built on

1. **Everything as code** — no manual change reaches any environment. Console/SSH access is break-glass only, alerted, and time-boxed.
2. **Immutable artifacts** — build once, promote the same digest through envs. Never rebuild per environment. Tag by digest, never `latest`.
3. **Pull-based delivery (GitOps)** — the cluster reconciles from Git; CI never holds prod cluster credentials.
4. **Zero standing privilege** — short-lived, dynamically issued creds (Vault DB engine, OIDC federation, K8s SA tokens). Humans get JIT elevation.
5. **Defence in depth** — hardened host → hardened image → pod security → network policy → mTLS → app authz. Any one layer may fail.
6. **Default deny** — network, RBAC, egress, and firewall all start closed and get explicit allows.
7. **Shift-left security** — SAST/SCA/secret-scan/IaC-scan block the pipeline *before* an artifact exists; runtime scanning catches the rest.
8. **Observability as a product** — golden signals, SLOs, error budgets, correlation IDs, and runbooks attached to every alert.
9. **Recoverability over uptime** — a system you cannot restore is not in production. Backups are proved by restore drills, not by green checkmarks.
10. **Auditability** — every change traceable to a commit, an approver, and a ticket; logs immutable and retained per regulation (typically 1 year hot / 7 years cold for banking).

## 4. Delivery roadmap (phased, ~6 months)

| Phase | Weeks | Deliverable | Exit criteria |
|---|---|---|---|
| **0. Foundations** | 1–2 | Repo structure, branching, pre-commit, Terraform state backend, Vault dev | `terraform plan` clean from CI; pre-commit blocks secrets |
| **1. VM track baseline** | 3–5 | Golden image pipeline (Packer), Ansible hardening roles, Jenkins/GitLab runner fleet | CIS scan ≥ 90%, image rebuilt weekly, app deploys via Ansible only |
| **2. Secrets + identity** | 5–7 | Vault HA + auto-unseal, Keycloak HA, OIDC for GitLab/Grafana/K8s/Argo | Zero static secrets in repos and CI variables; SSO on all consoles |
| **3. K8s platform** | 7–11 | RKE2 clusters via Terraform+Ansible, CNI+NetworkPolicy, Ingress, cert-manager, storage | Default-deny NetPol enforced; PSA `restricted` on app namespaces |
| **4. GitOps + CD** | 11–14 | ArgoCD, app-of-apps, Helm/Kustomize per env, progressive delivery (Argo Rollouts) | Prod deploy is a Git merge; rollback < 5 min, drilled |
| **5. Stateful services** | 13–17 | PostgreSQL (CloudNativePG), MinIO, Keycloak, Vault, Redis, Kafka on K8s | Each with backup + verified restore + HA failover test |
| **6. Observability** | 15–19 | Prometheus/Thanos, Loki, Tempo, Grafana, Alertmanager, SLOs | Every service has RED dashboard + 2 burn-rate alerts + runbook |
| **7. DevSecOps hardening** | 18–22 | Full pipeline gates, Falco, Kyverno/OPA, Harbor+Cosign, SBOM | Unsigned or critical-CVE image cannot start in prod |
| **8. BC/DR + audit** | 22–26 | Backup (Velero + WAL + object lock), DR site, game days, evidence pack | Full restore drill meets RTO/RPO; auditor-ready evidence |

## 5. Document map

| Doc | Covers |
|---|---|
| `01-architecture.md` | VM track + K8s track topology, network zones, traffic flow |
| `02-repo-structure.md` | Folder layout for infra, apps, GitOps, Ansible |
| `03-security-baseline.md` | DevSecOps controls, hardening, pipeline gates, compliance mapping |
| `04-platform-services.md` | Keycloak, PostgreSQL, MinIO, Vault, Redis, Kafka on K8s |
| `05-cicd-automation.md` | GitLab CI, Jenkins, Ansible, Terraform, ArgoCD, promotion model |
| `06-observability.md` | Metrics, logs, traces, SLOs, alerting, on-call |
| `07-backup-dr.md` | Backup strategies per data type, RTO/RPO, restore drills |
| `08-microservices.md` | Service design, communication, resilience, service mesh |
| `09-runbooks.md` | Operational procedures, incident response, break-glass |
