# Makefile Reference

> **Author:** Mengty LIM

The root `Makefile` is the single entry point for working with this repo's infra — Terraform,
Ansible, Kubernetes/GitOps, security scans, and the local `kind` lab. CI calls the same targets
you run locally, so `make lint` / `make scan` passing on your machine means CI will pass too.

Run `make` or `make help` with no target to list every target with its description — the help
text is generated from the `## ` comments in the Makefile itself, so it never goes stale.

```bash
$ make help
lint                     Run all linters
lint-tf                  terraform fmt + validate + tflint
lint-ansible             ansible-lint + syntax check
lint-k8s                 Render kustomize overlays and lint them
scan                     Security scans: secrets, IaC, filesystem
tf-plan                  Plan infra for ENV (default dev)
tf-apply                 Apply the previously reviewed plan for ENV
ansible-check            Dry-run the full converge (always do this before apply)
ansible-apply            Converge hosts for ENV
ansible-idempotence      Run twice; second run must report zero changes
render                   Render a service's overlay (make render SVC=payment-service ENV=prod)
diff                     Diff an overlay against the live cluster
lab-up                   Create the local kind cluster + platform baseline
lab-down                 Destroy the local lab
```

---

## 1. Variables

| Variable | Default | Purpose |
|---|---|---|
| `ENV` | `dev` | Target environment. Passed to Terraform (`infra/terraform/environments/$(ENV)`) and Ansible (`inventories/$(ENV)/hosts.yml`). |
| `TF_DIR` | `infra/terraform/environments/$(ENV)` | Derived from `ENV` — the Terraform root module to plan/apply. |
| `ANSIBLE_DIR` | `infra/ansible` | Fixed location of the Ansible project. |
| `SVC` | *(none — required for `render`/`diff`)* | Which GitOps app under `gitops/business/` to render or diff. |

Override any variable inline: `make tf-plan ENV=prod`. Never edit the Makefile to change environment —
pass `ENV=` on the command line so the same targets work for every environment.

---

## 2. Quality gates — `lint`, `scan`

These mirror CI exactly (see [`05-cicd-automation.md`](05-cicd-automation.md)); run them before pushing.

- **`make lint`** → runs `lint-tf`, `lint-ansible`, `lint-k8s` in sequence.
  - `lint-tf`: `terraform fmt -check`, `terraform validate` (backend-less), `tflint --recursive`.
  - `lint-ansible`: `ansible-lint` + `--syntax-check` against `inventories/$(ENV)/hosts.yml`.
  - `lint-k8s`: renders every overlay under `gitops/business/*/overlays/*` with `kustomize build`
    and pipes it through `kube-linter`. Fails fast on the first bad overlay.
- **`make scan`** → secrets (`gitleaks`), Terraform misconfig (`checkov`), IaC/GitOps config
  (`trivy config`, HIGH/CRITICAL only), and app filesystem vuln + secret scan (`trivy fs`).

Both targets exit non-zero on the first failure — treat any failure as a merge blocker, not a warning.

---

## 3. Terraform — `tf-plan`, `tf-apply`

```bash
make tf-plan  ENV=prod     # terraform init + plan -out=tfplan
make tf-apply ENV=prod     # applies the exact plan file just written
```

- `tf-apply` refuses to run if `$(TF_DIR)/tfplan` doesn't exist — you cannot apply without a
  plan file that was reviewed first. This is the local equivalent of CI's plan-then-manual-approve-then-apply gate.
- The plan file is environment-specific (path derived from `ENV`), so a stale `dev` plan can
  never be accidentally applied to `prod`.
- Never run `tf-apply` against `prod` from a laptop in real usage — see the branching/change-control
  rules in [`02-repo-structure.md`](02-repo-structure.md#6-branching--change-control). In this repo
  it's fine as a learning exercise.

---

## 4. Ansible — `ansible-check`, `ansible-apply`, `ansible-idempotence`

```bash
make ansible-check      ENV=dev   # --check --diff, no changes made
make ansible-apply      ENV=dev   # actually converges the hosts
make ansible-idempotence ENV=dev  # runs the playbook twice; 2nd run must report changed=0
```

- Always run `ansible-check` before `ansible-apply` — it's a dry run with a diff of what would change.
- `ansible-idempotence` is the test that catches playbooks with hidden side effects: if the second
  run reports any `changed=` count above zero, the target fails with `NOT IDEMPOTENT`. Required
  before merging any role change.

---

## 5. GitOps — `render`, `diff`

```bash
make render SVC=payment-service ENV=prod   # kustomize build only, prints YAML to stdout
make diff   SVC=payment-service ENV=prod   # kustomize build | kubectl diff against the live cluster
```

- `SVC` must match a directory under `gitops/business/<SVC>/overlays/<ENV>`.
- `diff` requires a working `kubectl` context pointed at the cluster you want to compare against —
  it does not select or switch context for you.
- Use `render` to sanity-check an overlay before opening a PR; use `diff` against a real cluster to
  preview what ArgoCD/Flux would sync.

---

## 6. Local lab — `lab-up`, `lab-down`

```bash
make lab-up     # kind create cluster (local-lab/kind-cluster.yaml) + local-lab/bootstrap.sh
make lab-down   # kind delete cluster --name learn-devops
```

This is the only pair of targets not gated behind `ENV` — the local lab is a single fixed
`kind` cluster named `learn-devops`, used for trying out the GitOps/platform stack without
touching real cloud infra.

---

## 7. Typical workflows

**Changing a Terraform module:**
```bash
make lint-tf
make tf-plan ENV=dev
# review the plan output
make tf-apply ENV=dev
```

**Changing an Ansible role:**
```bash
make lint-ansible
make ansible-check ENV=dev
make ansible-apply ENV=dev
make ansible-idempotence ENV=dev
```

**Bumping an app's image in GitOps:**
```bash
make render SVC=payment-service ENV=dev   # confirm the overlay renders cleanly
make lint-k8s
make diff SVC=payment-service ENV=dev     # optional, needs cluster access
```

**Before opening any PR touching `infra/` or `gitops/`:**
```bash
make lint
make scan
```
