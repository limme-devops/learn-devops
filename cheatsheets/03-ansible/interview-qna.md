# Ansible — Interview Q&A

> **Author:** Mengty LIM

---

## Fundamentals

**Q1. Why agentless, and what does it cost you?**
No agent to install, upgrade, secure or debug; the trust model is just SSH plus
sudo, which security teams already understand. The costs: you need Python on the
target, throughput is bounded by the control node and SSH round trips, and
because nothing runs continuously, configuration drift between runs is invisible.
Pull-based tools (Puppet/Chef) converge on a timer; with Ansible you have to
*schedule* convergence yourself — we run the hardening playbook on a cron from
CI in check mode and alert on any `changed`, which gives drift detection without
surprise remediation.

**Q2. Ansible vs Terraform — where's the line?**
Terraform manages resource *lifecycle* with state: it knows what exists and can
plan a delta, including deletion. Ansible manages configuration *inside* things
that already exist, and has no state file, so it can't tell you "this host should
no longer exist". The line we draw: Terraform creates the VM, network, and
cluster and emits an inventory; Ansible hardens and configures the host and
deploys the app. Overlap is where the pain lives — two tools both believing they
own the security group is a genuinely bad afternoon.

**Q3. What is idempotency and how do you actually guarantee it?**
Running the playbook twice produces the same state and the second run reports
zero changes. Modules give it to you; `command`/`shell` do not, which is why any
raw command needs `creates:`, `removes:`, or an explicit `changed_when:`. The
guarantee isn't a promise, it's a test: Molecule's idempotence step runs converge
twice and fails the build if anything changed. Beyond correctness it matters
operationally — a task that always reports `changed` notifies its handler, so
every run restarts the service.

**Q4. Explain variable precedence and where people get burned.**
Roughly: role `defaults/` (lowest) → inventory group_vars → host_vars → play
vars → role `vars/` → set_fact/registered → `-e` extra vars (highest). Two
traps. First, role `vars/main.yml` beats inventory, so a variable you "override
in group_vars" silently doesn't — put anything overridable in `defaults/`.
Second, `-e` beats everything including safety checks, which is fine for
`app_version` in a pipeline and awful as a human habit, because it makes the
run un-reproducible from the repo.

---

## Design

**Q5. How do you structure a repo for 300 hosts and 6 teams?**
Inventory per environment with group_vars keyed to the group hierarchy;
single-purpose roles with documented `defaults/`; playbooks that are thin —
mostly `roles:` lists and pre/post checks; collections pinned in
`requirements.yml`. Environment differences live in group_vars only, never in
`when:` conditionals scattered through tasks, because that's how you get a play
that's been silently skipping prod for six months. Every role gets Molecule tests
and CODEOWNERS. And the inventory for prod is generated from Terraform, not
maintained by hand.

**Q6. How do you do a zero-downtime rolling deploy across a VM fleet?**
`serial: 1` (or a percentage) to bound blast radius, and `max_fail_percentage: 0`
so the rollout stops at the first failure instead of marching through the fleet.
Per host: drain from the load balancer (`delegate_to: localhost` so the API call
runs from the control node), wait for in-flight requests, deploy the new
artifact by digest, gate on a health check with retries, then re-enable in the
LB. Rollback is the same playbook with the previous artifact version — which is
only true if deployment is artifact-based rather than "build on the host", so
that's a prerequisite, not a detail.

**Q7. `block/rescue/always` — when do you reach for it?**
When a task sequence has a real compensating action: put the change in `block`,
the rollback in `rescue`, and anything that must happen either way — re-enabling
monitoring, returning the host to the LB, removing a maintenance flag — in
`always`. It's the difference between a failed deploy and a host left drained
and silently out of service.

**Q8. Push vs pull, and would you ever add AWX?**
Push is simpler and gives you a natural place to gate (a CI job). It doesn't
self-heal, and it needs credentials on whatever runs it. AWX/Automation Controller
adds RBAC, credential storage, scheduled runs, and — the reason it usually gets
funded in a bank — an audit trail of who ran which playbook against which
inventory with which approval. _(regulated)_ Running prod playbooks from an
engineer's laptop fails an audit even when the playbook is perfect.

---

## Security

**Q9. How do you handle secrets?**
Ansible Vault is the floor: it encrypts files at rest, but everyone who runs the
playbook shares one key and rotation means re-encrypting everything. The target
state is dynamic secrets — a Vault Agent on the host or `hashi_vault` lookups —
so credentials are short-lived, scoped per host/role, and every issuance is
audited. Whichever you use: `no_log: true` on tasks that touch secrets (otherwise
they're in the job output and therefore in your log platform forever), write them
to tmpfs not disk, `0600`, dedicated user.

**Q10. Is `host_key_checking = False` acceptable?**
No, not in prod — it disables the only protection against a MITM on your
management path, and Ansible has root on every host it touches. Provisioning
should populate a known_hosts file (from Terraform output or SSH certificates),
which also fixes the ergonomic problem that made people disable it in the first
place. In a throwaway local lab, fine.

**Q11. How would you use Ansible for CIS hardening and prove compliance?**
Roles implement the controls (sysctl, auditd rules, PAM, SSH config, file
permissions), each tagged with its CIS control ID. Then compliance is measured
separately from being applied: a scheduled `--check --diff` run reports drift
without changing anything, and an independent scanner (OpenSCAP/Lynis) produces
the evidence, because "the playbook that applies the control also reports the
control is applied" is not evidence an auditor accepts. Exceptions live in
group_vars with an expiry date and a ticket reference.

---

## Operations

**Q12. A playbook fails on host 47 of 200. What now?**
That depends on whether I wrote it defensively. With `max_fail_percentage: 0` /
`any_errors_fatal`, the run has already stopped, and 46 hosts are on the new
version while 154 are on the old — which is fine if the versions are compatible,
and a design problem if they aren't. I diagnose with the failed task's output,
fix forward or roll back the completed hosts with `--limit`, and use
`--start-at-task` or tags to resume rather than re-running the whole play. The
thing I'd flag to the interviewer: mixed-version fleets during rollout are
normal, so the app and its schema must tolerate N and N-1 simultaneously.

**Q13. Playbook takes 45 minutes on 200 hosts. Speed it up.**
Measure first — `profile_tasks` callback tells you where it goes, and it's
usually fact gathering plus per-task SSH overhead. Then: enable pipelining and
ControlPersist, raise forks to what the control node can handle, disable or
narrow fact gathering (`gather_subset: min`) with a fact cache, collapse loops
into single module calls with a list, move long operations to `async`+`poll: 0`
with a later wait, and consider `strategy: free` if the play doesn't need hosts
in lockstep. If it's still slow, the honest answer may be that host configuration
belongs in a golden image built once, with Ansible only applying the delta.

**Q14. How do you test Ansible?**
Three layers. `ansible-lint` + `yamllint` in pre-commit for style and a
surprising number of real bugs. Molecule per role: create a container/VM,
converge, assert idempotence, run verify assertions (Testinfra or Ansible
asserts), destroy — all in CI on every PR. Then `--check --diff` against a
staging inventory as the last gate before prod. `--check` isn't perfect: tasks
that depend on a previous task's real effect report false results, so mark
read-only commands `check_mode: false` and don't treat a clean check as proof.

**Q15. What's a handler and what's the classic failure?**
A task that runs only when notified, once, at the end of the play — so ten
config changes cause one restart instead of ten. The classic failure is that if
the play aborts before handlers flush, your config file is on disk but the
service is still running the old config: correct at rest, wrong in reality, and
it "fixes itself" at the next reboot, which is a fun incident to diagnose. Use
`meta: flush_handlers` at a safe point, and `--force-handlers` when you need them
to run despite a failure.

**Q16. When is Ansible the wrong tool?**
When you're mutating long-lived servers that should be immutable instead — if
every deploy is "converge the running host", you accumulate drift no playbook
describes. Better: bake a golden image (Packer, with the same roles), and let
Ansible do only the small per-host delta. Also wrong for orchestration with
complex state machines, for anything needing sub-second reaction, and inside
Kubernetes, where the reconciliation loop already exists and a push tool fights
it.
