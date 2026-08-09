# Terraform Cheat Sheet

> **Author:** Mengty LIM

HCL, state, modules, workspaces vs directories, providers, policy gates, CI.

---

## 1. Mental model

Terraform is a **graph engine over a state file**. Three things exist and they
are always different: your **config** (what you declared), the **state** (what
Terraform last recorded), and the **real world** (what the cloud actually has).
`plan` is a three-way diff between them; `apply` walks the dependency graph to
close the gap.

Everything painful in Terraform is a state problem: state is stale, state is
locked, state has a resource the config doesn't, or two people have two states.
Understand that and most gotchas stop being surprising.

In this platform Terraform owns **infrastructure lifecycle** (network, VMs,
cluster, IAM, DNS). Ansible owns **what happens inside a host**. ArgoCD owns
**what runs inside the cluster**. Terraform emits the Ansible inventory; it does
not `remote-exec` a config script.

---

## 2. Commands

```bash
# lifecycle
terraform init                       # download providers/modules, configure backend
terraform init -upgrade              # re-resolve version constraints
terraform init -backend-config=env/prod.backend.hcl
terraform init -migrate-state        # backend changed; move state
terraform init -reconfigure          # backend changed; DON'T move state

terraform fmt -recursive -check      # CI gate
terraform validate                   # syntax + type checking, no cloud calls
terraform plan -out=tfplan           # ALWAYS write the plan to a file
terraform show -json tfplan | jq     # machine-readable plan → policy engine
terraform apply tfplan               # apply exactly what was reviewed
terraform destroy                    # never in prod without an approval gate

# scoping / debugging
terraform plan -target=module.vpc                # escape hatch, not a workflow
terraform plan -refresh=false                    # fast plan, trusts state
terraform plan -var-file=env/prod.tfvars
terraform console                                # try expressions interactively
terraform output -json | jq -r '.kubeconfig.value'
terraform graph | dot -Tsvg > graph.svg
TF_LOG=DEBUG TF_LOG_PATH=tf.log terraform apply  # TRACE for provider internals

# state surgery (dangerous — back it up first)
terraform state list
terraform state show aws_instance.web
terraform state pull > backup.tfstate
terraform state mv  aws_instance.web module.web.aws_instance.this
terraform state rm  aws_s3_bucket.legacy         # forget it, do not delete it
terraform import    aws_s3_bucket.data my-bucket # adopt an existing resource
terraform force-unlock <LOCK_ID>                 # only after confirming nobody is running

# providers / modules
terraform providers
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64
terraform get -update
```

Useful env vars: `TF_VAR_name=value` (sets `var.name`), `TF_IN_AUTOMATION=1`
(quieter CI output), `TF_CLI_ARGS_plan="-lock-timeout=5m"`, `TF_WORKSPACE`.

---

## 3. Language essentials

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }   # pin, always
  }
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "db_password" {
  type      = string
  sensitive = true        # redacted from plan output (NOT from state)
}

locals {
  name_prefix = "${var.project}-${var.environment}"
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner_team
    CostCentre  = var.cost_centre
  }
}

output "vpc_id" {
  description = "ID of the created VPC"
  value       = aws_vpc.this.id
}
```

**Meta-arguments worth knowing cold:**

| Meta-arg | Use |
|---|---|
| `count` | Toggle a resource on/off (`count = var.enabled ? 1 : 0`) |
| `for_each` | Collections — keys by name, so removing item #2 doesn't recreate #3 |
| `depends_on` | Only for hidden dependencies Terraform can't infer (IAM propagation) |
| `lifecycle { prevent_destroy }` | Databases, state buckets, KMS keys |
| `lifecycle { create_before_destroy }` | Zero-downtime replace (LB target groups, ASGs) |
| `lifecycle { ignore_changes = [tags["LastScanned"]] }` | Fields another system mutates |
| `provider = aws.eu` | Pin a resource to an aliased provider |
| `moved { }` | Rename/refactor without destroy-recreate — beats `state mv` because it is in code and reviewable |

**`count` vs `for_each`** is the single most consequential choice in day-2 life:

```hcl
# BAD: removing "b" shifts indexes → destroys and recreates "c"
resource "aws_subnet" "s" { count = length(var.cidrs)  cidr_block = var.cidrs[count.index] }

# GOOD: keyed by a stable string → removing "b" touches only "b"
resource "aws_subnet" "s" {
  for_each   = var.subnets           # map(string) name → cidr
  cidr_block = each.value
  tags       = merge(local.common_tags, { Name = "${local.name_prefix}-${each.key}" })
}
```

Expressions you'll reach for: `for` comprehensions
(`{ for k, v in var.m : k => upper(v) if v != "" }`), `dynamic` blocks for
repeated nested blocks, `try()` / `coalesce()` / `lookup()` for defaults,
`merge()` for tags, `templatefile()` for user-data, `jsonencode()` for policies
(never hand-write JSON in a heredoc), and `nonsensitive()` only when you have
genuinely thought about it.

---

## 4. State

State holds resource IDs, attribute values, dependency edges, and metadata. It is
**not** a secret store but it **contains every secret** any resource emitted —
RDS passwords, generated keys, `sensitive` variables in cleartext. Treat the
state file at the same classification as the credentials it holds.

```hcl
# S3 + native locking (Terraform 1.10+; use dynamodb_table on older versions)
terraform {
  backend "s3" {
    bucket       = "acme-tfstate-prod"
    key          = "platform/prod/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    kms_key_id   = "arn:aws:kms:eu-west-1:111122223333:key/…"
    use_lockfile = true
    # dynamodb_table = "terraform-lock"   # pre-1.10
  }
}
```

Non-negotiables _(regulated)_: remote backend, locking, encryption at rest with
a CMK, **versioning + MFA delete** on the bucket, access logged, and one state
per environment in a **separate account/subscription** so a dev credential can
never reach the prod state.

**Splitting state.** One giant state = slow plans, wide blast radius, and a
merge queue of one. Split along blast-radius and change-frequency lines:
`network/` → `platform/` (cluster, IAM) → `apps/`. Cross-state reads go through
`terraform_remote_state` (read-only, requires the reader to have state access) or
better, through the cloud's own discovery (SSM parameters, resource tags, data
sources) so the coupling isn't a state dependency at all.

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config  = { bucket = "acme-tfstate-prod", key = "network/prod/terraform.tfstate", region = "eu-west-1" }
}
# use: data.terraform_remote_state.network.outputs.vpc_id
```

**Never** hand-edit a state file. Use `terraform state` subcommands, or better,
`moved`/`import` blocks so the change lands through code review.

```hcl
# Terraform 1.5+: import as code, visible in the plan
import {
  to = aws_s3_bucket.data
  id = "acme-data-prod"
}

moved {
  from = aws_instance.web
  to   = module.web.aws_instance.this
}
```

---

## 5. Modules

```
modules/vpc/
├── main.tf         resources
├── variables.tf    inputs, with descriptions + validation
├── outputs.tf      outputs, with descriptions
├── versions.tf     required_version + required_providers
├── README.md       generated by terraform-docs
└── examples/basic/ a runnable example that CI actually applies
```

Rules that keep modules usable:

- **A module is an interface, not a folder.** Inputs are the contract; changing
  a variable's meaning is a breaking change even if the type is identical.
- **No `provider` blocks inside a module.** Pass providers in from the root
  (`providers = { aws = aws.eu }`). A module with its own provider can never be
  removed cleanly.
- **No backend blocks inside a module.** Root only.
- **Pin module versions** — a Git ref or registry version, never a floating
  branch: `source = "git::ssh://git@host/infra-modules.git//vpc?ref=v2.3.1"`.
- **Output everything a caller might need** (IDs, ARNs, names), but don't output
  the whole resource object — it makes every attribute part of your API.
- **Three layers max.** Root → composition module → resource module. Deeper and
  nobody can answer "where does this tag come from".
- Prefer **thin wrappers over well-maintained community modules** to owning a
  4,000-line VPC module you must keep current with provider releases.

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr
  tags = local.common_tags
}
```

---

## 6. Environments — directories, not workspaces

```
live/
├── prod/
│   ├── network/{main.tf,terraform.tfvars,backend.hcl}
│   └── platform/…
├── staging/…
└── dev/…
modules/…
```

Workspaces share one backend, one set of credentials, and one config — which
means a `terraform workspace select` typo applies dev's plan to prod, and you
cannot give prod different IAM. Fine for ephemeral PR/feature stacks; wrong as
your prod boundary. _(regulated)_ Directories per environment, separate state,
separate accounts, separate CI credentials.

Differences between environments live in `.tfvars` (sizes, counts, CIDRs), not
in `count = var.env == "prod" ? 1 : 0` scattered through the config. If prod's
topology genuinely differs, that's a different composition module — hiding it in
conditionals means staging stopped testing prod's code path.

---

## 7. Providers, auth, secrets

```hcl
provider "aws" {
  region = "eu-west-1"
  assume_role { role_arn = "arn:aws:iam::111122223333:role/terraform-exec" }
  default_tags { tags = local.common_tags }     # tags everything, cheaply
}

provider "aws" {
  alias  = "us"
  region = "us-east-1"                          # CloudFront certs, etc.
}
```

Auth: **OIDC federation from CI** (GitHub Actions / GitLab → AWS IAM role,
Azure workload identity, GCP WIF). No static access keys in CI, ever. Locally,
SSO + short-lived credentials.

Secrets: keep them out of config and out of your hands. Pull at apply time from
Vault / Secrets Manager / Key Vault via a data source, or — best — have the
resource generate its own and never round-trip through you.

```hcl
data "vault_kv_secret_v2" "db" { mount = "kv", name = "prod/db" }
resource "aws_db_instance" "this" {
  manage_master_user_password = true            # AWS generates + rotates; never in state
}
```

Remember: anything you *do* pass in lands in state in cleartext. `sensitive =
true` only hides it from CLI output.

---

## 8. Testing and policy gates

| Layer | Tool | Catches |
|---|---|---|
| Format | `terraform fmt -check -recursive` | Diff noise |
| Syntax/type | `terraform validate` | Bad references, wrong types |
| Lint | `tflint` (+ cloud ruleset) | Deprecated args, invalid instance types, unused decls |
| Static security | `checkov`, `tfsec`/`trivy config` | Public buckets, open SGs, unencrypted volumes |
| Policy as code | OPA/Conftest, Sentinel | "No 0.0.0.0/0 on 22", "must have CostCentre tag" |
| Unit | `terraform test` (1.6+, `.tftest.hcl`) | Module logic, validation rules — no cloud needed for `command = plan` |
| Integration | Terratest (Go) | Real apply → assert → destroy in a sandbox account |
| Cost | Infracost | "This PR adds $4,100/mo" |
| Drift | Scheduled `plan -detailed-exitcode` | Console changes; exit code 2 = drift → alert |

```hcl
# tests/vpc.tftest.hcl
run "rejects_bad_environment" {
  command = plan
  variables { environment = "producton" }
  expect_failures = [var.environment]
}
```

```bash
terraform test
terraform plan -detailed-exitcode    # 0 = no change, 1 = error, 2 = changes pending
conftest test tfplan.json -p policy/
```

---

## 9. CI/CD pipeline shape

```
PR opened
  → fmt · validate · tflint · checkov · terraform test          (fail fast, no creds)
  → plan -out=tfplan  (read-only role)                          (OIDC, per-env)
  → show -json | conftest test                                  (policy gate)
  → infracost diff                                              (cost comment)
  → post plan as a PR comment                                   (the review artifact)
merge to main
  → manual approval for prod                                    (regulated)
  → apply tfplan   ← the SAME plan file, not a fresh plan
  → drift check nightly, alert on exit code 2
```

Two details people get wrong. First, **apply the saved plan file**, not a
re-plan — otherwise you approved one thing and applied another. Second, the
plan job needs a **read-only** role and the apply job a separate privileged one;
if the plan role can write, a malicious PR is a shell in your cloud account.

Also: `-lock-timeout=10m` so concurrent pipelines queue rather than fail, and
serialize applies per state (GitHub `concurrency`, GitLab `resource_group`).

---

## 10. Gotchas

| Symptom | Cause / fix |
|---|---|
| Plan wants to destroy/recreate everything | `count` index shift after a list edit → use `for_each` |
| "Error acquiring the state lock" | A crashed run. Confirm nobody is applying, then `force-unlock <ID>` |
| Perpetual diff on the same attribute | Cloud normalizes the value (policy JSON, casing) → `ignore_changes`, or use `jsonencode()` |
| "Provider produced inconsistent final plan" | Provider bug or a computed value; often fixed by a provider upgrade |
| "Value depends on resource attributes that cannot be determined until apply" | `for_each` over unknown values → key off static input, or split the apply |
| Resource exists in cloud but not state | Someone clicked in the console → `import` block |
| Resource in state but not in cloud | Deleted out of band → `state rm`, then re-apply |
| Secret visible in plan output | Missing `sensitive = true` (and it's still in state regardless) |
| `terraform destroy` in prod | `lifecycle { prevent_destroy = true }` on stateful resources |
| Plans take 15 minutes | State too big → split it; `-refresh=false` for iteration only |
| Works locally, fails in CI | Different provider versions → commit `.terraform.lock.hcl` |
| Cycle error | Two resources reference each other → break with a separate association resource |

Never commit: `.terraform/`, `*.tfstate*`, `*.tfvars` containing secrets,
`crash.log`. Always commit: `.terraform.lock.hcl`.

---

## 11. Best practices checklist

- [ ] `required_version` and every provider pinned; `.terraform.lock.hcl` committed
- [ ] Remote state: encrypted with a CMK, locked, versioned, per-environment, separate account
- [ ] State split by blast radius (network / platform / apps), not one monolith
- [ ] `for_each` over `count` for anything that is a real collection
- [ ] `moved` and `import` blocks instead of manual `state mv` / `state import`
- [ ] Modules: no provider blocks, no backends, versioned sources, documented variables with `validation`
- [ ] Environments as directories + tfvars; workspaces only for ephemeral stacks
- [ ] `default_tags` (or a `common_tags` local) on everything — owner, cost centre, environment
- [ ] `prevent_destroy` on databases, KMS keys, state buckets
- [ ] CI: fmt · validate · tflint · checkov · `terraform test` · policy gate · cost diff
- [ ] Plan saved to a file and reviewed; **that** file is applied
- [ ] Plan role read-only; apply role separate and approval-gated _(regulated)_
- [ ] CI auth via OIDC — no static cloud keys
- [ ] Nightly drift detection on `-detailed-exitcode`, alerting on 2
- [ ] No secrets in `.tfvars`; prefer provider-managed generation and rotation

➡ [Interview Q&A](interview-qna.md)
