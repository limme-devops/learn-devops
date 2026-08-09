# Terraform — Interview Q&A

> **Author:** Mengty LIM

---

## Fundamentals

**Q1. What is the state file actually for, and why can't Terraform work without it?**
It maps your config's logical addresses to real resource IDs, caches attribute
values, and records dependency edges. Without it Terraform can't tell "create a
new bucket" from "this bucket is the one I made last time", and it has no way to
know a resource you *deleted from the config* ever existed — so deletions would
be impossible. It's also why state is the security boundary: it contains every
attribute a provider returned, including generated passwords and keys, in
cleartext. We classify the state bucket at the same level as the credentials in
it — CMK encryption, versioning, MFA delete, access logging, and a separate
account per environment.

**Q2. Walk me through what `plan` does.**
It refreshes state against the real world (unless `-refresh=false`), builds the
resource graph from config, and produces a three-way diff between config, state
and reality — then annotates each resource as create, update in place, replace,
or destroy. The key operational habit is `-out=tfplan`: a plan you looked at and
a plan you apply must be the same artifact, otherwise the review meant nothing.
`terraform show -json tfplan` is also what you feed a policy engine, which is
how you get "no security group open to 0.0.0.0/0 on 22" enforced rather than
requested.

**Q3. `count` vs `for_each`.**
`count` addresses instances by integer index, so removing an element from the
middle of a list shifts every subsequent index and Terraform plans a
destroy-and-recreate for resources that didn't change at all. `for_each` keys by
a stable string, so removing one map entry touches exactly that entry. Use
`count` only for on/off toggles (`count = var.enabled ? 1 : 0`); use `for_each`
for anything that's genuinely a collection. This is the single most common cause
of "why does my plan want to rebuild the whole subnet layer".

**Q4. Terraform vs Ansible — where's the line?**
Terraform has state and manages resource *lifecycle*: it knows what exists and
can plan a deletion. Ansible has no state and configures things that already
exist. Our line: Terraform creates the network, VMs, cluster and IAM, and emits
an inventory; Ansible hardens the host and deploys the VM app; ArgoCD owns what
runs inside the cluster. Overlap is where the pain lives — two tools that both
believe they own a security group is a genuinely bad afternoon. Which is why we
don't use `provisioner "remote-exec"` for configuration: it's a one-shot at
create time, invisible to future plans, so it's drift by construction.

---

## State and day-2

**Q5. Someone changed a security group in the console. What now?**
The next plan shows a diff, which is the system working. Two questions: was the
change legitimate, and how did they have console write access in prod at all.
If legitimate, encode it and apply. If not, apply reverts it. We run a nightly
`plan -detailed-exitcode` per state and alert on exit code 2, so we find drift
on a schedule rather than during an unrelated deploy — the failure mode you're
avoiding is someone shipping a small change and being handed a plan that also
reverts three weeks of undocumented console edits.

**Q6. How do you bring an existing, hand-built resource under Terraform?**
Write the config to match, then adopt it with an `import` block rather than
`terraform import` — because a block is code, shows up in the plan, and goes
through review. Then plan and iterate until the diff is empty; a non-empty diff
means your config doesn't actually describe what's there, and applying would
mutate a production resource. For big estates, `terraform plan -generate-config-out`
gives you a starting HCL skeleton. Only remove the import block once it's applied.

**Q7. How do you refactor — move a resource into a module — without destroying it?**
`moved` blocks. `moved { from = aws_instance.web  to = module.web.aws_instance.this }`
tells Terraform the address changed, and the plan shows a move rather than a
destroy-recreate. `terraform state mv` does the same thing but as an untracked
imperative act on someone's laptop; the block is reviewable and reproducible in
CI. Leave `moved` blocks in place for a release or two so anyone on an older
state converges too.

**Q8. Your state file is 8,000 resources and plans take 20 minutes. Fix it.**
Split it. The boundaries follow blast radius and change frequency: network
(changes quarterly), platform — cluster, IAM, DNS (monthly), apps (daily). Each
gets its own state and its own pipeline, so a routine app change doesn't
refresh the entire VPC and can't accidentally destroy it. Cross-state coupling
goes through `terraform_remote_state` for reads, or better through the cloud's
own discovery — SSM parameters, tags, data sources — so the downstream stack
doesn't need read access to the upstream state at all. `-refresh=false` speeds up
iteration but is a workaround, not a fix.

**Q9. "Error acquiring the state lock." What do you do?**
Do not immediately `force-unlock`. Find out whether a run is genuinely in flight
— check CI, check who holds the lock (the error names the operation, who, and
when). A stale lock comes from a crashed or cancelled run; only then
`terraform force-unlock <ID>`. Forcing a lock while another apply is actually
running gives you two writers on one state, which is the fastest way to a
corrupted state file. Structurally: set `-lock-timeout=10m` so concurrent
pipelines queue instead of failing, and serialize applies per state with a CI
concurrency group.

---

## Design

**Q10. Workspaces or directories for environments?**
Directories, for prod. Workspaces share one backend, one credential set and one
config — so a mis-selected workspace applies dev's intent to prod, and you can't
give prod a different IAM role or a different state account. Directories per
environment with separate state, separate accounts and separate CI credentials
make the blast radius structural rather than procedural. Workspaces are good for
ephemeral things: a per-PR stack, a load-test environment. _(regulated)_ The
audit argument is decisive — you need to show that a dev credential cannot reach
prod state, and with workspaces you can't.

**Q11. How do you keep dev and prod from diverging while still sizing them differently?**
Same modules, same composition, differences in `.tfvars` — instance sizes,
counts, CIDRs, retention. What we avoid is `count = var.env == "prod" ? 1 : 0`
sprinkled through resources, because then staging has stopped testing prod's
code path and nobody notices until the prod-only branch fails on its first run.
If the topologies genuinely differ — prod is multi-region, dev is not — that's a
different composition module, stated explicitly, not a conditional in hiding.

**Q12. What makes a good module?**
It has an interface you'd be happy to version: descriptive inputs with `type`
and `validation`, outputs with descriptions, a README generated from the code,
and a runnable example that CI actually applies. It contains no `provider` and
no `backend` blocks — those belong to the root, and a module carrying its own
provider can never be cleanly removed. It's pinned by version, not a branch. And
it's shallow: root → composition → resource, three layers, or nobody can trace
where a tag came from. I'd also rather wrap a well-maintained community module
than own 4,000 lines of VPC code I have to keep current with every provider
release.

**Q13. How do you handle secrets?**
Assume anything Terraform touches ends up in state in cleartext — `sensitive =
true` only redacts CLI output. So the goal is to touch as few secrets as
possible. Best case, the resource generates and rotates its own
(`manage_master_user_password` on RDS, provider-managed keys). Next best, pull
at apply time from Vault or Secrets Manager via a data source and pass a
reference, not a value. Worst case is a secret in `.tfvars`, which is a file
somebody will commit. And whatever you do, the state backend is encrypted with a
CMK and access-controlled as if it were the secret store — because functionally
it is.

---

## Pipeline and safety

**Q14. Describe your Terraform CI pipeline.**
On PR: `fmt -check`, `validate`, `tflint`, `checkov`, `terraform test` — all
credential-free and fast. Then `plan -out=tfplan` using a **read-only** role,
`show -json` piped into Conftest for policy (mandatory tags, no public ingress,
approved regions), Infracost for a cost delta, and the plan posted as a PR
comment — that comment is the review artifact. On merge: manual approval for
prod, then `apply tfplan` — the same plan file, not a fresh plan. Nightly drift
detection with `-detailed-exitcode`. Auth is OIDC federation; there are no
static cloud keys in CI.

**Q15. Why does it matter that the plan role is read-only?**
Because `terraform plan` runs arbitrary code from the PR — providers, modules,
external data sources — before any human has reviewed it. If the plan job holds
write credentials, opening a pull request is remote code execution against your
cloud account. Split roles: read-only for plan on untrusted input, privileged
for apply on merged, approved code. This is the control people most often miss.

**Q16. How do you stop `terraform destroy` from being a career event?**
`lifecycle { prevent_destroy = true }` on databases, KMS keys, state buckets and
anything holding data. Deletion protection at the cloud level too, since that
survives someone commenting out the lifecycle block. Destroy is not a pipeline
step in prod — it requires a deliberate, approved run. And the review habit that
actually catches it: read the plan's summary line. "3 to destroy" when you
expected zero is the signal; the reason people miss it is that they apply from a
scrolled-past terminal instead of a reviewed plan artifact.

**Q17. A provider upgrade broke your plan. How do you manage provider versions?**
Pessimistic constraints (`~> 5.60`) in `required_providers`, and the
`.terraform.lock.hcl` committed so CI and laptops resolve identically — with
`terraform providers lock` run for every platform your team uses, or macOS users
will fight the lock file forever. Upgrades are a deliberate PR: bump the
constraint, `init -upgrade`, read the changelog for breaking changes, and look
hard at the plan for surprise replacements. Never a floating `>=` in prod, and
never an unpinned module `source` pointing at a branch.

**Q18. When is Terraform the wrong tool?**
For anything with fast, continuous reconciliation needs inside a cluster —
Terraform runs when you run it; ArgoCD converges constantly, so Kubernetes
workloads belong in Git-driven GitOps, not `kubernetes_manifest` resources. For
imperative, one-shot operations (a data migration, a failover drill) — those are
runbooks or scripts. And for anything where the provider is immature: a badly
maintained provider means perpetual diffs and state you can't trust, and at that
point a thin scripted wrapper you control is honestly safer than pretending
you have declarative management.

---

## Rapid fire

- **`terraform refresh`?** Deprecated as a standalone command; use `plan -refresh-only` so you review what changes in state before accepting it.
- **`-target`?** An incident escape hatch. Routine use means your state should have been split.
- **`depends_on`?** Only for dependencies Terraform can't infer from references — IAM propagation, side effects. Overuse serializes the graph and slows applies.
- **`null_resource` / `terraform_data`?** Last resort. It's a state entry with no real-world counterpart, so it lies to you by design.
- **`create_before_destroy`?** Zero-downtime replacement; needs unique names, so pair it with `name_prefix` instead of `name`.
- **Data source vs remote state?** Data source when the cloud can tell you (tags, SSM); remote state when it can't. Data sources decouple; remote state creates a dependency and requires state read access.
- **Exit code 2?** `plan -detailed-exitcode` found changes. That's the drift alarm.
