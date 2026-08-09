# Repository & Folder Structure

> **Author:** Mengty LIM

## 1. Multi-repo layout (recommended for regulated environments)

Separate repos give you separate access control and separate audit trails — which auditors will ask for. A monorepo is fine for learning; split before prod.

| Repo | Owner | Contains | Who can merge |
|---|---|---|---|
| `infra-terraform` | Platform | All IaC (network, VMs, clusters, cloud) | Platform + 2 approvers |
| `infra-ansible` | Platform | Host config, hardening roles, VM app deploy | Platform |
| `platform-gitops` | Platform | ArgoCD app-of-apps, platform Helm values | Platform |
| `apps-gitops` | Platform + Dev | Per-app env values, image digests | Dev proposes, Platform approves for prod |
| `app-<service>` | Dev team | Application source + Dockerfile + chart | Dev team |
| `security-policies` | Security | Kyverno/OPA policies, Falco rules, CIS profiles | Security only |
| `runbooks` | SRE | Operational docs, incident procedures | SRE |

**Critical rule:** application source and the GitOps deployment state live in *different* repos. A developer merging app code must not be able to change what runs in prod.

---

## 2. `infra-terraform`

```
infra-terraform/
├── README.md
├── .gitlab-ci.yml                 # fmt → validate → tflint → checkov → plan → (manual) apply
├── .pre-commit-config.yaml
├── modules/                       # reusable, versioned, no environment values inside
│   ├── network/                   # vpc/vlan, subnets, security groups, firewall rules
│   ├── compute-vm/                # VM + disks + tags + DNS record
│   ├── k8s-cluster/               # node pools, LB, etcd disks
│   ├── loadbalancer/
│   ├── dns/
│   ├── vault-cluster/
│   ├── object-storage/
│   └── observability-backend/
├── environments/
│   ├── dev/
│   │   ├── backend.tf             # remote state: per-env key, locking, encryption
│   │   ├── providers.tf           # pinned versions
│   │   ├── main.tf                # module composition only
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── terraform.tfvars
│   ├── sit/
│   ├── uat/
│   ├── prod/
│   └── dr/
├── global/                        # shared: DNS zones, IAM/roles, state bucket bootstrap
│   └── bootstrap/
├── policies/                      # OPA/Sentinel: deny public buckets, require encryption/tags
└── docs/
    └── adr/                       # ADR-0001-why-rke2.md, ADR-0002-state-layout.md, ...
```

Rules:
- `environments/*` contains **composition + values only** — no `resource` blocks.
- One state file per environment per layer (`network`, `platform`, `data`) — blast radius control. A `prod/network` mistake must not be able to destroy `prod/data`.
- State backend: encrypted, versioned, locked, access-restricted, MFA-delete where available.
- Never `terraform apply` from a laptop against prod. CI applies, with a manual gate.

---

## 3. `infra-ansible`

```
infra-ansible/
├── ansible.cfg
├── requirements.yml               # galaxy collections/roles, version-pinned
├── inventories/
│   ├── dev/
│   │   ├── hosts.yml              # or dynamic inventory plugin (vmware/aws)
│   │   ├── group_vars/
│   │   │   ├── all/
│   │   │   │   ├── vars.yml
│   │   │   │   └── vault.yml      # ansible-vault encrypted OR (better) lookups to Vault
│   │   │   ├── web.yml
│   │   │   └── db.yml
│   │   └── host_vars/
│   ├── uat/
│   └── prod/
├── playbooks/
│   ├── site.yml                   # full converge
│   ├── bootstrap.yml              # first boot: users, ssh, agents
│   ├── harden.yml                 # CIS
│   ├── k8s-install.yml            # RKE2 install/upgrade
│   ├── deploy-app.yml             # blue/green VM app rollout
│   ├── patch.yml                  # monthly patching
│   └── backup-verify.yml
├── roles/
│   ├── baseline/                  # ntp, dns, users, sssd, motd
│   ├── hardening_cis/
│   ├── firewall/
│   ├── podman_runtime/
│   ├── vault_agent/
│   ├── observability_agents/      # node_exporter, promtail, otel-collector
│   ├── haproxy/
│   ├── postgres/
│   └── app_deploy/
│       ├── defaults/main.yml
│       ├── tasks/main.yml
│       ├── handlers/main.yml
│       ├── templates/
│       ├── files/
│       └── molecule/default/      # role tests
├── filter_plugins/
└── collections/
```

Rules:
- Every role has a Molecule test scenario; CI runs `ansible-lint` + `molecule test`.
- Prod playbooks run with `--check --diff` in CI first; the apply is a separate manual job.
- No secrets in `group_vars` in plaintext — use `community.hashi_vault` lookups or `ansible-vault` with the key in CI's secret store.
- Idempotency test is mandatory: second run must report zero changes.

---

## 4. `platform-gitops` + `apps-gitops` (ArgoCD)

```
gitops/
├── bootstrap/
│   └── argocd/                    # ArgoCD install (Helm values), initial root app
├── apps/                          # app-of-apps: one Application per platform/app component
│   ├── platform/
│   │   ├── dev/
│   │   │   ├── cert-manager.yaml
│   │   │   ├── ingress-nginx.yaml
│   │   │   ├── external-secrets.yaml
│   │   │   ├── kyverno.yaml
│   │   │   ├── monitoring.yaml
│   │   │   └── velero.yaml
│   │   ├── uat/
│   │   └── prod/
│   └── business/
│       ├── dev/
│       │   ├── payment-service.yaml
│       │   └── account-service.yaml
│       ├── uat/
│       └── prod/
├── platform/                      # the actual manifests/values per component
│   ├── cert-manager/
│   │   ├── base/
│   │   └── overlays/{dev,uat,prod}/
│   ├── keycloak/
│   ├── vault/
│   ├── minio/
│   ├── postgres-operator/
│   └── monitoring/
├── business/
│   └── payment-service/
│       ├── base/                  # kustomize base or Helm chart ref
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   ├── serviceaccount.yaml
│       │   ├── networkpolicy.yaml
│       │   ├── hpa.yaml
│       │   ├── pdb.yaml
│       │   ├── externalsecret.yaml
│       │   └── servicemonitor.yaml
│       └── overlays/
│           ├── dev/    kustomization.yaml + values-dev.yaml   # image digest pinned here
│           ├── uat/
│           └── prod/
└── policies/                      # Kyverno ClusterPolicies synced by Argo
```

**Promotion = a commit that changes the image digest in the next overlay.** Nothing else.

---

## 5. `app-<service>` (application repo)

```
app-payment-service/
├── src/
├── tests/
├── Dockerfile                     # multi-stage, distroless/UBI-minimal, non-root, no shell in final
├── .dockerignore
├── .gitlab-ci.yml
├── .pre-commit-config.yaml        # gitleaks, lint, format
├── charts/payment-service/        # chart lives with the app; values live in gitops
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
├── deploy/
│   └── systemd/                   # for VM-track deployment of the same artifact
├── docs/
│   ├── api/openapi.yaml
│   ├── runbook.md                 # REQUIRED before prod
│   └── slo.md                     # REQUIRED before prod
└── security/
    ├── threat-model.md
    └── sbom/                      # generated in CI, published as artifact
```

---

## 6. Branching & change control

- `main` = what is deployable. Protected: no direct push, no force-push, signed commits required.
- Short-lived feature branches → MR → required approvals (dev repos: 1; infra/gitops prod: 2, one from Platform, one from Security for policy changes).
- MR template forces: change description, rollback plan, blast radius, ticket link.
- Tags are immutable and signed; releases are `vMAJOR.MINOR.PATCH`.
- CODEOWNERS enforces reviewer routing (`/environments/prod/ @platform-leads @security`).
