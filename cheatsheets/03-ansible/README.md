# Ansible Cheat Sheet

> **Author:** Mengty LIM

Inventory, playbooks, roles, idempotency, secrets, rolling VM deploys.

---

## 1. Mental model

Agentless push over SSH (WinRM for Windows). The control node renders a task
into a Python module, ships it to the target, runs it, collects JSON, deletes it.
Consequences worth knowing: the target needs Python (and enough of it), execution
is **serial per play by default**, and there is no daemon holding state — which
is why "converged" only means "converged the last time someone ran it". In this
platform Ansible owns **host configuration and VM app rollout**; Terraform owns
**infrastructure lifecycle**. Do not let them overlap.

---

## 2. Commands

```bash
# inventory
ansible-inventory -i inventories/prod --graph
ansible-inventory -i inventories/prod --host web-01 | jq

# ad-hoc (recon only — never a change you won't put in a playbook)
ansible all -i inventories/prod -m ping
ansible web -i inventories/prod -m setup -a 'filter=ansible_distribution*'
ansible web -i inventories/prod -m command -a 'uptime' --limit 'web-0[12]'

# playbooks
ansible-playbook -i inventories/prod playbooks/site.yml
  --check --diff            # dry run + show file changes  ← default habit
  --limit web-01            # blast-radius control
  --tags deploy,config
  --skip-tags slow
  --start-at-task "Install package"
  -e "app_version=1.4.2"    # extra vars: highest precedence
  -e @vars/release.yml
  --step                    # confirm each task
  -f 20                     # forks (parallelism)
  -vvv                      # -vvvv includes connection debug

# syntax / quality
ansible-playbook --syntax-check playbooks/site.yml
ansible-lint playbooks/ roles/
yamllint .

# vault
ansible-vault create   group_vars/prod/vault.yml
ansible-vault edit     group_vars/prod/vault.yml
ansible-vault view     group_vars/prod/vault.yml
ansible-vault rekey    group_vars/prod/vault.yml
ansible-vault encrypt_string 's3cr3t' --name 'db_password'
ansible-playbook … --vault-password-file ~/.vault-pass   # or --ask-vault-pass

# collections / roles
ansible-galaxy collection install -r requirements.yml
ansible-galaxy role init roles/app_deploy
```

`ansible.cfg` (repo-local, committed):
```ini
[defaults]
inventory            = inventories/prod
roles_path           = roles
collections_path     = collections
host_key_checking    = True          # never False in prod
forks                = 20
stdout_callback      = yaml
callbacks_enabled    = profile_tasks, timer
interpreter_python   = auto_silent
retry_files_enabled  = False
[ssh_connection]
pipelining           = True          # big speedup; needs requiretty off
ssh_args             = -o ControlMaster=auto -o ControlPersist=60s
```

---

## 3. Inventory and variables

```
inventories/prod/
├── hosts.yml            # generated from Terraform outputs — never hand-edited
├── group_vars/
│   ├── all.yml
│   ├── web.yml
│   └── prod/{vars.yml,vault.yml}
└── host_vars/web-01.yml
```

```yaml
# hosts.yml
all:
  children:
    web:
      hosts:
        web-01: { ansible_host: 10.20.1.11 }
        web-02: { ansible_host: 10.20.1.12 }
    db:
      hosts: { db-01: { ansible_host: 10.20.2.11 } }
    prod:
      children: { web: {}, db: {} }
```

**Variable precedence** (low → high, the parts that actually matter):
role defaults → inventory group_vars(all → specific) → inventory host_vars →
play vars → task vars → `include_vars` → `set_fact`/registered → `-e` extra vars.

Rule of thumb: **`defaults/main.yml` for anything you want overridable,
`vars/main.yml` for constants you don't** (vars/ beats inventory, which surprises
people). `-e` wins over everything — great for a release version, dangerous as a
habit.

---

## 4. Playbook and role anatomy

```yaml
- name: Configure web tier
  hosts: web
  become: true
  gather_facts: true
  serial: "25%"                    # rolling: quarter of the fleet at a time
  max_fail_percentage: 0           # stop the whole rollout on any failure
  any_errors_fatal: true
  vars:
    app_version: "1.4.2"
  pre_tasks:
    - name: Assert we know what we are shipping
      ansible.builtin.assert:
        that:
          - app_version is match('^\d+\.\d+\.\d+$')
          - app_digest is defined
        fail_msg: "app_version/app_digest must be passed explicitly"
  roles:
    - role: baseline
    - role: app_deploy
      tags: [deploy]
  post_tasks:
    - name: Smoke test
      ansible.builtin.uri:
        url: "http://{{ ansible_host }}:8080/healthz"
        status_code: 200
      retries: 10
      delay: 3
      register: smoke
      until: smoke.status == 200
  handlers:
    - name: restart app
      ansible.builtin.systemd: { name: app, state: restarted, daemon_reload: true }
```

Role layout:
```
roles/app_deploy/
├── defaults/main.yml      overridable knobs
├── vars/main.yml          constants
├── tasks/main.yml         entry point
├── handlers/main.yml      restart/reload, run once at end of play
├── templates/app.service.j2
├── files/
├── meta/main.yml          dependencies, supported platforms
└── molecule/default/      tests
```

---

## 5. Idempotency — the whole point

A correct playbook run twice in a row reports `changed=0` the second time.
Anything that always reports `changed` is either lying about the system or
triggering handlers (and therefore restarts) on every run.

| Instead of | Use | Why |
|---|---|---|
| `command: apt install -y nginx` | `ansible.builtin.package` | Module knows current state |
| `shell: "echo x >> /etc/hosts"` | `lineinfile` / `blockinfile` | Append runs every time |
| `command: mkdir -p /opt/app` | `file: state=directory` | Also sets owner/mode |
| `shell: curl … | bash` | `get_url` + `checksum:` then a real module | Unverified remote code |
| Nothing | `changed_when:` / `creates:` on `command` | Tells Ansible what "changed" means |

```yaml
- name: Run DB migration once
  ansible.builtin.command: /opt/app/bin/migrate
  args: { creates: /var/lib/app/.migrated-{{ app_version }} }
  changed_when: true

- name: Check config validity (never reports changed)
  ansible.builtin.command: nginx -t
  changed_when: false
  check_mode: false
```

Use **FQCN** (`ansible.builtin.copy`, not `copy`) — short names are ambiguous
once collections are installed, and ansible-lint will fail you.

---

## 6. Templates, handlers, validation

```yaml
- name: Render nginx site
  ansible.builtin.template:
    src: site.conf.j2
    dest: /etc/nginx/conf.d/site.conf
    owner: root
    group: root
    mode: "0644"
    backup: true
    validate: "nginx -t -c %s"      # ← config never lands broken
  notify: reload nginx
```

Handlers run **once, at the end of the play**, only if notified.
`meta: flush_handlers` forces them earlier. If the play aborts before handlers
run, the change is on disk but not applied — an underrated source of "it worked
until the next reboot".

Useful Jinja:
```jinja
{{ var | default('fallback') }}
{{ var | mandatory }}
{{ list | join(',') }}   {{ dict | to_nice_json }}   {{ s | b64encode }}
{% for h in groups['web'] %}server {{ hostvars[h].ansible_host }}:8080;
{% endfor %}
{{ ansible_facts.default_ipv4.address }}
```

---

## 7. Secrets

Ansible Vault encrypts files at rest with a symmetric key. It is a floor, not a
strategy: everyone who runs the playbook holds the same key, and rotation means
re-encrypting every file.

_(regulated)_ Preferred pattern in this platform: **Vault (HashiCorp) via
`community.hashi_vault` lookups or a Vault Agent on the host**, so credentials
are short-lived, per-host, and auditable. Ansible Vault then holds only the
bootstrap material.

```yaml
- name: Fetch dynamic DB credentials
  ansible.builtin.set_fact:
    db_creds: "{{ lookup('community.hashi_vault.vault_read',
                  'database/creds/app-role') }}"
  no_log: true                       # ← or it is in the job log forever
```

Rules: `no_log: true` on any task touching a secret; never `debug` a secret;
secrets go to tmpfs (`/run/app/`), never to `/etc` on disk; `mode: "0600"` and a
dedicated user.

---

## 8. Blue/green VM rollout (the pattern to describe in interviews)

```yaml
- name: Rolling deploy with LB drain
  hosts: web
  serial: 1                              # one host at a time
  max_fail_percentage: 0
  tasks:
    - name: Drain from load balancer
      ansible.builtin.uri:
        url: "https://lb.internal/api/servers/{{ inventory_hostname }}/drain"
        method: POST
      delegate_to: localhost             # run on the control node, not the target
      throttle: 1

    - name: Wait for in-flight requests to finish
      ansible.builtin.wait_for: { timeout: 30 }

    - name: Deploy new artifact (by digest)
      ansible.builtin.include_role: { name: app_deploy }

    - name: Health gate
      ansible.builtin.uri:
        url: "http://localhost:8080/readyz"
        status_code: 200
      retries: 20
      delay: 3
      register: r
      until: r.status == 200

    - name: Return to load balancer
      ansible.builtin.uri:
        url: "https://lb.internal/api/servers/{{ inventory_hostname }}/enable"
        method: POST
      delegate_to: localhost
```

The three properties that make this safe: `serial: 1` bounds blast radius,
`max_fail_percentage: 0` stops the rollout at the first failure instead of
breaking the whole fleet, and the health gate runs **before** traffic returns.

Related keywords: `run_once: true`, `delegate_to`, `delegate_facts`,
`throttle`, `when`, `block/rescue/always`, `async` + `poll: 0` for long jobs.

```yaml
- block:
    - include_role: { name: risky_change }
  rescue:
    - include_role: { name: rollback }
    - fail: { msg: "rolled back on {{ inventory_hostname }}" }
  always:
    - include_role: { name: reenable_monitoring }
```

---

## 9. Testing

```bash
ansible-lint                       # style + a lot of real bugs
molecule test -s default           # create → converge → idempotence → verify → destroy
ansible-playbook --check --diff    # dry run against real hosts
```

Molecule's **idempotence** step is the one that earns its keep: it runs converge
twice and fails if the second run reports changes. Wire lint + molecule into CI
so a role cannot merge without proving idempotency.

---

## 10. Performance

| Lever | Effect |
|---|---|
| `pipelining = True` | Fewer SSH round trips per task — often 2× |
| `forks = 20–50` | Parallel hosts; bounded by control-node CPU |
| `gather_facts: false` (or `gather_subset: min`) | Fact gathering is often the slowest task |
| Fact caching (redis/jsonfile) | Reuse facts across plays and runs |
| `ControlPersist` | Reuse SSH connections |
| Loop over a module, not a module in a loop | `package: name={{ list }}` beats 30 `package` tasks |
| `strategy: free` | Hosts run independently; good for long, order-independent plays |

---

## 11. Gotchas

| Symptom | Cause |
|---|---|
| Playbook reports `changed` every run | `command`/`shell` without `creates`/`changed_when` |
| `--check` fails on a task that reads state | Add `check_mode: false` to the read-only command |
| Handler never fired | Play failed earlier, or the notifying task reported `ok` |
| Var not what you expect | Precedence — `vars/main.yml` beats inventory; `-e` beats all |
| Secret in the log | Missing `no_log: true` |
| Works on one host, breaks on another | Facts differ (distro, interface names). Assert, don't assume |
| `sudo: a password is required` | Missing `become_method`/NOPASSWD, or `--ask-become-pass` |
| Random SSH failures at scale | Too many forks, or the target's `MaxStartups`/`MaxSessions` |
| Slow at 100+ hosts | Fact gathering + no pipelining |

---

## 12. Best practices checklist

- [ ] Inventory generated from Terraform outputs; no hand-edited prod hosts
- [ ] FQCN everywhere; `ansible-lint` clean in CI
- [ ] Roles are single-purpose, with `defaults/` documented in the README
- [ ] Every role passes Molecule's idempotence step
- [ ] `--check --diff` run and reviewed before any prod play
- [ ] `serial:` + `max_fail_percentage: 0` on anything touching a fleet
- [ ] Health gate before returning a host to the load balancer
- [ ] `validate:` on every config template that has a validator
- [ ] Secrets from Vault, `no_log: true`, tmpfs, `0600`
- [ ] `host_key_checking = True`; run from a controlled bastion/CI runner
- [ ] Playbook runs are logged and attributable _(regulated)_ — AWX/Tower or a CI job, not a laptop

➡ [Interview Q&A](interview-qna.md)
