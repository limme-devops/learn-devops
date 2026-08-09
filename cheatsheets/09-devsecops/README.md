# DevSecOps Cheat Sheet

> **Author:** Mengty LIM

Pipeline gates, SAST/DAST/SCA, secrets, supply chain, admission control,
runtime detection, compliance.

Companion: [docs/03-security-baseline.md](../../docs/03-security-baseline.md).

---

## 1. The idea in one line

Security controls are **code, run automatically, that fail the build** — not a
review meeting before go-live. If a control can be skipped by a tired engineer at
17:55 on a Friday, it is documentation, not a control.

Three properties separate real DevSecOps from security theatre:
1. **Automated** — it runs on every change without anyone remembering.
2. **Blocking** — a violation stops the pipeline, with an explicit, expiring,
   attributable exception process for the cases that must proceed.
3. **Enforced at the last mile** — admission control in the cluster, because a
   pipeline gate only protects things that went through the pipeline.

---

## 2. Where each control belongs

```
 IDE / pre-commit        gitleaks, hadolint, tflint, unit tests
        │
 CI: build              SAST (semgrep/CodeQL), SCA (dependency CVEs + licences),
        │               IaC scan (checkov/tfsec/kubesec), secret scan (history too)
        │               → build image → SBOM (syft) → image scan (trivy/grype)
        │               → sign digest (cosign)
        │
 CI: test               DAST (ZAP) against ephemeral env, API contract tests
        │
 Registry               immutable tags, continuous rescan of deployed digests
        │
 Deploy (ArgoCD)        Git is the only write path; CI holds no prod credentials
        │
 Admission (Kyverno)    signature verified, registry allowlisted, PSA restricted,
        │               no :latest, no privileged, limits required — fail CLOSED
        │
 Runtime                Falco, NetworkPolicy, audit log → SIEM, drift detection
        │
 Continuous             CVE feeds, pen tests, access reviews, DR drills
```

**Shift left, but keep the right.** Left-only misses everything that happens
after build: expired certs, rotated-away credentials, a new CVE in something
already deployed, a human with kubectl.

---

## 3. Pipeline gates and tools

| Gate | Tool | Fails on |
|---|---|---|
| Secret scanning | `gitleaks`, `trufflehog` | Any credential — including in git *history* |
| Lint / policy | `hadolint`, `ansible-lint`, `yamllint`, `conftest` | Dockerfile and manifest anti-patterns |
| SAST | `semgrep`, CodeQL, SonarQube | Injection, deserialisation, crypto misuse |
| SCA / dependencies | `trivy fs`, `grype`, `osv-scanner`, `dependency-check` | Known-vulnerable libs, disallowed licences |
| IaC | `checkov`, `tfsec`, `kube-score`, `kubesec` | Public S3, open SG, missing encryption, privileged pods |
| Container image | `trivy image` | OS/lib CVEs, misconfig, embedded secrets |
| SBOM | `syft` → SPDX/CycloneDX | (produces evidence, doesn't fail) |
| Signing | `cosign sign` / attest | (produces provenance) |
| DAST | OWASP ZAP baseline | Missing headers, auth issues on a live ephemeral env |
| Runtime | Falco, Tetragon | Shell in a container, unexpected egress, write to /etc |

```bash
gitleaks detect --source . --redact --log-opts="--all"
semgrep --config=p/owasp-top-ten --error .
trivy fs --scanners vuln,secret,misconfig --severity HIGH,CRITICAL --exit-code 1 .
trivy image --exit-code 1 --ignore-unfixed --severity HIGH,CRITICAL $IMAGE
checkov -d infra/terraform --framework terraform --soft-fail-on LOW
syft $IMAGE -o cyclonedx-json > sbom.json && grype sbom:sbom.json --fail-on high
cosign sign --key hashivault://cosign $IMAGE_DIGEST
cosign attest --predicate sbom.json --type cyclonedx --key … $IMAGE_DIGEST
cosign verify --key … $IMAGE_DIGEST
```

**`--ignore-unfixed` matters.** Failing a build on a CVE with no available fix
teaches everyone to bypass the gate. Fail on *actionable* findings; track the
rest with an SLA and an owner.

---

## 4. Vulnerability triage that people will actually follow

| Severity | Fix SLA _(regulated, typical)_ | Gate behaviour |
|---|---|---|
| Critical, exploitable, internet-facing | 24–72h | Block build and deploy |
| Critical / High with a fix | 7 days | Block build |
| High without a fix | 30 days, tracked | Warn + ticket |
| Medium | 90 days | Report |
| Low / informational | Backlog | Report |

Prioritise by **reachability and exposure**, not CVSS alone: a critical in a
transitive dependency you never call, in an internal service behind mTLS, is
less urgent than a medium in the edge's TLS stack. EPSS and KEV (CISA's
known-exploited list) are the practical inputs. Every exception has an owner, a
compensating control, and an **expiry date** — exceptions that never expire are
how a policy dies.

---

## 5. Secrets

| Anti-pattern | Replacement |
|---|---|
| Secret in Git | Vault + External Secrets Operator; `gitleaks` in pre-commit and CI |
| Secret in CI variables | OIDC federation to short-lived cloud credentials; Vault JWT auth from the runner |
| Long-lived DB password | Vault dynamic database credentials (TTL ~1h, rotated automatically) |
| Static cloud keys | Workload identity / IRSA / OIDC — no key material at all |
| Shared service account | One identity per workload, least privilege, auditable |

Rules: rotation must be **automatic**, not a calendar reminder; a leaked secret
is rotated *first* and investigated second; secrets live in memory or tmpfs, never
on disk; and every issuance is logged with who/what/when.

**Zero standing privilege** is the target: nothing has a credential until it
needs one, and it expires without human action. That is also what makes a leak
survivable.

---

## 6. Supply chain

The SLSA levels in plain terms: **L1** you have a build process that produces
provenance; **L2** the build runs on a hosted service and provenance is signed;
**L3** the build is on a hardened, isolated, non-falsifiable platform. Aim for
L2–L3 for anything reaching prod.

Practical controls:
- Pin dependencies with a lockfile **and** verify checksums; pin base images and
  GitHub Actions by digest/SHA, not tag (a compromised tag is the standard
  attack).
- Build in ephemeral runners with no persistent credentials and no network
  egress beyond an allowlisted proxy/artifact mirror.
- Generate an SBOM per build; store it as an attestation next to the image.
- Sign the digest with cosign; **verify at admission**, so an unsigned image
  cannot run even if someone pushes it directly.
- Separate duties: the identity that builds an artifact cannot deploy it.
- Mirror third-party dependencies into an internal registry so an upstream
  deletion or takeover doesn't reach prod _(regulated)_.

---

## 7. Admission control — the last line

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: { name: require-signed-images }
spec:
  validationFailureAction: Enforce      # not Audit. Enforce
  background: true
  webhookConfiguration: { failurePolicy: Fail }   # fail CLOSED
  rules:
    - name: verify-signature
      match: { any: [{ resources: { kinds: ["Pod"] } }] }
      verifyImages:
        - imageReferences: ["registry.internal/*"]
          attestors:
            - entries: [{ keys: { publicKeys: |-
                -----BEGIN PUBLIC KEY----- … } }]
    - name: registry-allowlist
      match: { any: [{ resources: { kinds: ["Pod"] } }] }
      validate:
        message: "images must come from registry.internal"
        pattern: { spec: { containers: [{ image: "registry.internal/*" }] } }
```

Policies worth having on day one: no `:latest`, internal registry only, signature
verified, no privileged / hostPath / hostNetwork, `runAsNonRoot`, resource limits
required, NetworkPolicy present in every namespace, required labels
(owner, data-classification), and no default ServiceAccount token automount.

`failurePolicy: Fail` means an outage of the policy engine blocks deployments
rather than silently disabling every control. That requires the engine to be HA
and to exclude `kube-system` — otherwise you can lock yourself out of your own
cluster, which is the classic first incident with fail-closed admission.

---

## 8. Runtime security

```yaml
# Falco: alert on a shell in a production container
- rule: Terminal shell in container
  condition: spawned_process and container and shell_procs and proc.tty != 0
  output: "Shell in container (user=%user.name container=%container.name)"
  priority: WARNING
```

Detections that earn their keep: interactive shell in a container, write to
`/etc` or a binary directory, unexpected outbound connection from a workload,
crypto-miner process names, reading `/etc/shadow` or service account tokens,
`kubectl exec` into a prod pod, container running as root when policy says
otherwise.

Pair detection with prevention: default-deny egress means a compromised workload
can't reach an attacker's C2 in the first place, which is worth more than an
alert about it.

_(regulated)_ Ship the Kubernetes **audit log**, host auditd, gateway access
logs and Vault audit devices to the SIEM, on an append-only path the platform
team cannot delete.

---

## 9. Compliance mapping (what auditors ask, and where the answer lives)

| Requirement | Where it's satisfied |
|---|---|
| Change control / segregation of duties | Git PR + review + protected branches; CI cannot deploy, ArgoCD pulls |
| Access control, least privilege | RBAC, Vault policies, quarterly access review |
| Encryption in transit / at rest | TLS everywhere, etcd encryption, disk encryption, KMS |
| Vulnerability management | Pipeline gates + SLA table + registry rescan evidence |
| Audit trail | Git history, K8s audit log, Vault audit device, SIEM retention |
| Backup & recovery | Snapshot policy + **drilled, timed** restore records |
| Incident response | Runbooks, on-call rota, post-incident reviews |
| Data classification | Required labels enforced at admission |

The recurring lesson: an auditor asks for **evidence produced by the system**,
not a document describing intent. Pipeline logs, signed attestations, Git
history and restore-drill timings *are* the evidence — which is a large part of
why the platform is built this way.

---

## 10. Threat-model prompts (STRIDE, applied to a pipeline)

| Threat | Concrete question |
|---|---|
| **S**poofing | Can someone push an image the cluster will run? Can a pod impersonate the gateway? |
| **T**ampering | Can a build be modified after signing? Can Git history be rewritten? |
| **R**epudiation | Can an admin delete the log of their own action? |
| **I**nformation disclosure | Where do secrets appear in logs, error pages, metrics labels? |
| **D**enial of service | What happens when the policy engine, Vault or the registry is down? |
| **E**levation of privilege | Which ServiceAccount can create pods? Who can approve their own PR? |

---

## 11. Best practices checklist

- [ ] Pre-commit hooks mirror the CI gates — feedback in seconds, not minutes
- [ ] Secrets scanning covers full git history, not just the diff
- [ ] SAST, SCA, IaC and image scanning all **block**, with `--ignore-unfixed`
- [ ] Exception process exists, is attributable, and every exception expires
- [ ] SBOM per build, stored as a signed attestation
- [ ] Images signed; signature verified at admission, fail-closed
- [ ] CI holds no production credentials; deployment is pull-based
- [ ] No human has standing write access to prod; break-glass is time-boxed and alerts
- [ ] Vault issues dynamic, short-lived credentials; rotation is automatic
- [ ] Default deny: network, egress, RBAC, admission, firewall
- [ ] Runtime detection deployed and its alerts routed to someone on call
- [ ] Audit logs append-only, off-platform, retained per regulation
- [ ] DR restore drilled and timed; result recorded
- [ ] Security findings have owners and SLAs, reviewed on a cadence

➡ [Interview Q&A](interview-qna.md)
