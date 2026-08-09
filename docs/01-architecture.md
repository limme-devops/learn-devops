# Architecture — VM Track and Kubernetes Track

> **Author:** Mengty LIM

## 1. Network zoning (applies to both tracks)

Bank-grade deployments are zone-segmented. Traffic only ever moves *inward* through a controlled hop.

```
Internet
   │
[ Edge / WAF + DDoS ]            ── public zone
   │
[ Reverse proxy / LB (HAProxy/NGINX, mTLS terminate) ]   ── DMZ
   │
[ Application zone ]  ← K8s worker nodes / app VMs
   │
[ Data zone ]  ← PostgreSQL, MinIO, Kafka, Redis   (no direct internet, no direct DMZ access)
   │
[ Management zone ]  ← Vault, Keycloak, GitLab, Jenkins, Prometheus, bastion
```

Rules:
- Only the DMZ may receive inbound from the internet. App zone accepts only from DMZ. Data zone accepts only from app zone.
- **Egress is default-deny.** Outbound internet goes through an explicit forward proxy with an allowlist (needed for OS patches, image pulls — mirror these internally where possible).
- Management access only via bastion/PAM with MFA, session recording, and time-boxed approval.
- East-west traffic inside a zone is still restricted (NetworkPolicy in K8s, host firewall + microsegmentation on VMs).

## 2. Track A — VM server deployment

```
                 ┌─────────────── Terraform ───────────────┐
                 │  vSphere VMs, DNS, LB pools, firewall   │
                 └────────────────────┬────────────────────┘
                                      │
                 ┌───────────── Packer golden image ────────────┐
                 │  RHEL9 + CIS hardening + agents (node_exp,   │
                 │  promtail, falco, auditd, AV, patch chan)    │
                 └────────────────────┬────────────────────────┘
                                      │
                 ┌───────────── Ansible (config) ──────────────┐
                 │ roles: baseline, hardening, docker/podman,  │
                 │ app-runtime, tls, monitoring, backup-agent  │
                 └────────────────────┬────────────────────────┘
                                      │
     Jenkins / GitLab CI  ──►  artifact (rpm / tar / container)  ──►  Ansible deploy
                                      │
                    HAProxy (2 nodes, keepalived VIP) → app VMs (N) → PostgreSQL (primary+standby)
```

**Key decisions for the VM track**
- **Immutable-ish**: prefer rebuilding from a new golden image (blue/green VM pool) over in-place mutation. Where in-place is unavoidable, Ansible must be idempotent and run in check-mode first.
- **Deployment strategy**: blue/green at the LB pool level — drain node from HAProxy, deploy, health-check, re-enable, move to next. Never all nodes at once.
- **App runtime**: run the app as a systemd unit under a non-root service account, or as a Podman rootless container (preferred — same image as K8s track).
- **Secrets**: `vault-agent` sidecar/systemd service renders templates to `tmpfs` (`/run/secrets`), never to disk, and signals the app on rotation.
- **TLS**: internal PKI (Vault PKI engine) issues short-lived (≤ 90 day, ideally 24h) certs; cert renewal automated by vault-agent.
- **Patching**: monthly patch window driven by Ansible against a mirrored repo (Satellite/Katello); emergency CVE path documented with a 72h SLA.

**Minimum host hardening checklist**
- CIS Level 2 benchmark, verified by `oscap`/Lynis in CI on the image build
- SSH: key-only, no root login, AllowGroups, port-knock or bastion-only source
- `auditd` rules for privileged commands, file integrity (AIDE) with daily report
- `firewalld`/nftables default-deny inbound + explicit egress rules
- SELinux enforcing, no permissive workarounds
- No local user accounts — central auth (SSSD → LDAP/AD), sudo via central rules
- Time sync (chrony) to internal NTP — critical for log correlation and TOTP
- Filesystem: separate `/var`, `/var/log`, `/tmp` with `noexec,nosuid,nodev`; LUKS at rest

## 3. Track B — Kubernetes deployment

```
                  ┌──── Terraform: nodes, LB, DNS, storage, firewall ────┐
                  └──────────────────────┬──────────────────────────────┘
                                         │
                  ┌──── Ansible: RKE2 install, etcd, CIS profile ────────┐
                  └──────────────────────┬──────────────────────────────┘
                                         │
   ┌─────────────────────────── Cluster ────────────────────────────────┐
   │ control-plane x3 (etcd, encrypted at rest, backed up every 30 min)  │
   │                                                                     │
   │ platform namespaces:                                                │
   │   ingress-nginx | cert-manager | external-secrets | argocd          │
   │   monitoring (Prom/Thanos/Grafana/Alertmanager) | logging (Loki)    │
   │   tracing (Tempo) | kyverno | falco | velero | metallb              │
   │                                                                     │
   │ data namespaces:  postgres (CNPG) | minio | keycloak | vault |      │
   │                   redis | kafka                                     │
   │                                                                     │
   │ app namespaces:   app-<service> per team/service, PSA=restricted    │
   └─────────────────────────────────────────────────────────────────────┘
```

**Cluster-level decisions**
| Concern | Choice | Why |
|---|---|---|
| Distribution | RKE2 | FIPS-capable, CIS-hardened defaults, air-gap friendly |
| CNI | Cilium | eBPF, NetworkPolicy + L7 policy, Hubble flow visibility, no kube-proxy |
| Ingress | ingress-nginx or Cilium Gateway API | mTLS, WAF (ModSecurity) at edge |
| Storage | Longhorn (or vSphere CSI / Ceph) | replicated block storage, snapshot support for stateful sets |
| Certs | cert-manager + Vault PKI issuer | short-lived internal certs, auto-rotation |
| Secrets | External Secrets Operator ← Vault | no secrets in Git, sync to K8s Secret |
| Policy | Kyverno | admission control: signed images, no root, required labels/limits |
| Runtime security | Falco + audit logs → SIEM | detect container escape, shell in prod pod |
| Registry | Harbor + Trivy + Cosign | scan on push, block critical CVE, verify signature at admission |
| Service mesh | Istio (ambient) or Linkerd — **only if** you need mTLS everywhere + fine-grained authz | adds ops burden; NetworkPolicy + app TLS may suffice |

**Cluster separation**: prod gets its own cluster (not just namespaces). Multi-tenancy by namespace is acceptable within dev/sit only. Rationale: a cluster-scoped compromise (CRD, admission webhook, node) crosses namespace boundaries.

**Baseline every app namespace gets**
- `PodSecurity: restricted` label (enforce + audit + warn)
- `default-deny-all` NetworkPolicy (ingress + egress) plus explicit allows to DNS, its DB, and its callers
- `ResourceQuota` + `LimitRange`
- Dedicated ServiceAccount per workload, `automountServiceAccountToken: false` unless needed
- No `default` ServiceAccount usage, no `hostNetwork`/`hostPath`/`privileged`

## 4. Traffic path for one request (prod, K8s track)

```
client → WAF → LB (VIP) → ingress-nginx (TLS term, mTLS client cert optional)
       → NetworkPolicy check → service → pod (app)
       → OIDC token validated against Keycloak (JWKS cached)
       → app requests DB creds from Vault (K8s auth, short TTL) [or ESO pre-synced]
       → PostgreSQL (TLS, cert-authenticated, row-level perms)
```

Every hop emits a span carrying the same `trace_id`; every log line carries `trace_id` + `request_id` for correlation.
