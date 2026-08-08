# DevSecOps Security Baseline

## 1. Pipeline gates — what blocks a build

Order matters: cheapest and fastest first, so developers get feedback in seconds.

| Stage | Tool | Blocks on | Runs |
|---|---|---|---|
| pre-commit (local) | `gitleaks`, formatter, linter | any secret match | every commit |
| **1. Secrets** | `gitleaks` / TruffleHog (full history on MR) | any verified secret | every push |
| **2. Lint/format** | language linter, `hadolint`, `yamllint` | errors | every push |
| **3. SAST** | Semgrep (+ Bandit/gosec/ESLint-security) | new High/Critical | every push |
| **4. SCA / deps** | Trivy fs, `npm audit`, OWASP DC, Grype | Critical, or High with a fix available | every push |
| **5. Unit tests** | pytest/jest/junit | fail, or coverage below threshold | every push |
| **6. IaC scan** | Checkov, tfsec, `kube-linter`, Kubesec | High+ misconfig | infra/gitops changes |
| **7. Build** | Docker BuildKit, reproducible, no secrets in layers | — | on merge |
| **8. Image scan** | Trivy image | Critical CVE (any), High > 30 days old | on merge |
| **9. SBOM + sign** | Syft SBOM, Cosign keyless/KMS sign, attestation | signing failure | on merge |
| **10. DAST** | OWASP ZAP against staging | new High | nightly / pre-release |
| **11. Admission** | Kyverno: verify Cosign signature, digest-pinned, non-root, limits set | any violation | at deploy time |
| **12. Runtime** | Falco, Cilium/Hubble, audit logs → SIEM | alert, not block | continuous |

**Exception process:** a gate can be waived only via a ticketed, time-boxed exception (max 30 days) approved by Security, recorded as a file in `security-policies/exceptions/` with an expiry date. CI fails when an exception expires. No `# nosec`-style inline suppressions without a linked ticket.

## 2. Secrets management — Vault as the only authority

**Rule: a human never sees a production credential.**

| Consumer | Auth method | Credential lifetime |
|---|---|---|
| K8s workload | Vault Kubernetes auth (SA token review) | 1h token, dynamic DB creds ≤ 1h |
| VM app | Vault AppRole / cert auth via vault-agent | 1h, auto-renewed |
| GitLab CI | JWT (OIDC) auth — `CI_JOB_JWT` → Vault role | job duration only |
| Jenkins | Vault plugin with AppRole, per-folder role | job duration |
| Terraform | Vault provider or short-lived cloud creds via OIDC | ≤ 1h |
| Humans | OIDC (Keycloak) → Vault, JIT, MFA | ≤ 8h, audited |

Vault engines to enable:
- **KV v2** — static config secrets (with versioning + rollback)
- **Database** — dynamic PostgreSQL/MySQL/Mongo creds, per-request user, auto-revoked
- **PKI** — internal CA, short-lived TLS for service-to-service and hosts
- **Transit** — encryption-as-a-service so apps never hold key material (critical for PII/PAN fields)
- **SSH** — signed SSH certs for break-glass host access, no static keys

Operational must-dos:
- HA (3+ nodes, Raft), auto-unseal via HSM/KMS, **unseal keys split (Shamir) across custodians in physical safes**
- Audit device enabled to file + syslog → SIEM; Vault must **fail closed** if audit logging fails
- Root token generated only for break-glass, then revoked; recorded in the change log
- Regular `vault operator raft snapshot` backups, encrypted, tested by restore

**Anti-patterns to eliminate:** secrets in GitLab CI variables, in `.env` committed anywhere, in ConfigMaps, in container image layers, in Ansible `group_vars` plaintext, in Jenkins job config, in Terraform state (mark outputs sensitive and treat state as a secret regardless).

## 3. Supply chain security

1. **Base images**: only from an internal, mirrored, curated set (UBI-minimal, distroless, Chainguard). Rebuilt weekly to pick up patches. Digest-pinned in Dockerfiles.
2. **Dependencies**: proxied through an internal Nexus/Artifactory — no direct pulls from public registries in CI or at runtime. Lockfiles committed and verified.
3. **Signing**: every image signed with Cosign; Kyverno `verifyImages` blocks unsigned images cluster-wide in prod.
4. **SBOM**: generated per build (Syft, CycloneDX), stored with the artifact, queryable when a new CVE drops ("which prod services ship log4j 2.14?" must be answerable in minutes).
5. **Provenance**: SLSA build attestation — the artifact records which pipeline, which commit, which runner built it.
6. **Runner isolation**: CI runners are ephemeral, network-restricted, and never reused across trust levels. A prod-deploying runner is separate from a PR-building runner.

## 4. Kubernetes security controls

```yaml
# Every app namespace
apiVersion: v1
kind: Namespace
metadata:
  name: app-payment
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

```yaml
# Default-deny, then allow only what's needed
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-all, namespace: app-payment }
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-dns, namespace: app-payment }
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector: { matchLabels: { k8s-app: kube-dns } }
      ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
```

Mandatory pod spec fields (enforced by Kyverno, not by hope):

```yaml
spec:
  serviceAccountName: payment-sa          # never default
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    fsGroup: 10001
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: app
      image: harbor.internal/app/payment@sha256:...   # digest, never a tag
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      resources:
        requests: { cpu: 100m, memory: 256Mi }
        limits:   { cpu: "1",  memory: 512Mi }
      livenessProbe:  { httpGet: { path: /healthz, port: 8080 }, initialDelaySeconds: 15, periodSeconds: 20 }
      readinessProbe: { httpGet: { path: /ready,   port: 8080 }, initialDelaySeconds: 5,  periodSeconds: 10 }
      startupProbe:   { httpGet: { path: /healthz, port: 8080 }, failureThreshold: 30, periodSeconds: 5 }
```

Kyverno policy set (minimum):
`require-signed-images`, `disallow-latest-tag`, `require-digest`, `require-run-as-nonroot`, `require-resource-limits`, `require-probes`, `disallow-host-namespaces`, `disallow-host-path`, `disallow-privileged`, `require-networkpolicy-exists`, `require-labels(owner,team,cost-center,data-class)`, `restrict-image-registries` (Harbor only), `require-pdb`.

Cluster hardening:
- etcd encryption at rest (`EncryptionConfiguration` with KMS provider, not `aescbc` with a local key)
- API server audit policy at `RequestResponse` for secrets/RBAC, shipped to SIEM
- RBAC: no `cluster-admin` for humans in prod — JIT elevation only; no wildcard verbs/resources; audit `ClusterRoleBinding` changes
- Disable anonymous auth, restrict kubelet API, rotate kubelet certs
- Control-plane nodes tainted, no workloads
- Run `kube-bench` (CIS) on a schedule, report to the compliance dashboard

## 5. Application security requirements

- **AuthN**: OIDC via Keycloak. Validate `iss`, `aud`, `exp`, `nbf`, signature against cached JWKS. Never accept `alg: none`. Short access tokens (5–15 min) + refresh rotation.
- **AuthZ**: enforced server-side on every request, at the resource level. Never trust a client-supplied role/tenant claim without verifying it against the token.
- **Input**: allowlist validation, parameterized queries only, output encoding at render, strict content-type checks, request size limits.
- **Crypto**: TLS 1.2+ (1.3 preferred), strong cipher suites only; data at rest encrypted; PII/PAN encrypted at field level via Vault Transit; passwords with Argon2id/bcrypt.
- **Session**: `HttpOnly`, `Secure`, `SameSite=Strict` cookies; server-side invalidation on logout; absolute + idle timeouts.
- **Headers**: HSTS, CSP, `X-Content-Type-Options`, `X-Frame-Options`/frame-ancestors, `Referrer-Policy`.
- **Rate limiting** + account lockout with exponential backoff at the gateway and in the app.
- **Logging**: log auth events, authz denials, admin actions, data exports. **Never log** passwords, tokens, PAN, national IDs, full card data, or session IDs. Mask before write.
- **Error handling**: no stack traces or SQL to clients; correlate to a `trace_id` the user can quote to support.

## 6. Compliance mapping (evidence you'll be asked for)

| Control area | Evidence produced automatically |
|---|---|
| Change management | Git history, MR approvals, ticket links, ArgoCD sync records |
| Access control | Keycloak/Vault audit logs, RBAC-as-code diffs, JIT elevation records |
| Vulnerability mgmt | Trivy/Semgrep reports per build, SBOM, exception register with expiry |
| Segregation of duties | CODEOWNERS, protected branches, separate app vs gitops repos, 2-approver prod |
| Encryption | Terraform/Kyverno policy results, cert inventory from cert-manager |
| Logging & monitoring | Immutable log retention config, SIEM ingest dashboards, alert history |
| BC/DR | Restore drill reports with timestamps and measured RTO/RPO |
| Data protection | Data classification labels on namespaces/resources, masking pipeline logs |

Build a `compliance/` folder with a script that collects this evidence into a dated pack — do not assemble it by hand at audit time.
