# Platform Services on Kubernetes — Deployment Guide

General rules for every stateful service below:
- **Use the operator, not a raw StatefulSet**, where a mature one exists. Operators handle failover, backup, and upgrades that you would otherwise hand-roll badly.
- Dedicated namespace, dedicated ServiceAccount, `default-deny` NetworkPolicy with explicit allows.
- Storage: `ReadWriteOnce` replicated block (Longhorn/Ceph/vSphere CSI) with a `StorageClass` that has `allowVolumeExpansion: true` and `reclaimPolicy: Retain` for data.
- `PodDisruptionBudget` + `topologySpreadConstraints` across nodes/zones + anti-affinity.
- Backup job + **a verified restore procedure** before it is considered "deployed".
- Metrics exporter + ServiceMonitor + dashboard + alerts before it is considered "production".
- Order of deployment matters: **Vault → PostgreSQL → Keycloak → MinIO → everything else** (Keycloak needs a DB; everything needs secrets).

---

## 1. HashiCorp Vault

**Deploy:** official `hashicorp/vault` Helm chart, HA mode with integrated Raft storage.

```yaml
# values-prod.yaml (key excerpts)
global:
  tlsDisable: false
server:
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true
  auditStorage:
    enabled: true
    size: 20Gi
    storageClass: fast-retain
  dataStorage:
    enabled: true
    size: 20Gi
    storageClass: fast-retain
  extraEnvironmentVars:
    VAULT_CACERT: /vault/userconfig/vault-tls/ca.crt
  affinity: |
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels: { app.kubernetes.io/name: vault }
          topologyKey: kubernetes.io/hostname
  resources:
    requests: { cpu: 500m, memory: 1Gi }
    limits:   { cpu: "2",  memory: 4Gi }
injector:
  enabled: true
ui:
  enabled: true      # exposed internally only, behind OIDC + ingress allowlist
```

**Hardening checklist**
- Auto-unseal via HSM/cloud KMS. If Shamir: 5 key shares, threshold 3, custodians in separate physical safes, documented ceremony.
- TLS on the listener with certs from your internal CA (chicken-and-egg: bootstrap with cert-manager selfsigned, then migrate to Vault PKI).
- Audit devices: file (to a PV) **and** syslog → SIEM. Vault fails requests if it cannot audit — that is intentional, monitor for it.
- Policies as code in `security-policies/vault/`, applied by CI, never by hand in the UI.
- Disable the root token after setup; break-glass via `vault operator generate-root` with a documented, alerted ceremony.
- `vault operator raft snapshot save` hourly → MinIO/object storage with object-lock, encrypted with a separate key.

**Consumption pattern in K8s** — External Secrets Operator (declarative, GitOps-friendly):

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata: { name: vault-backend, namespace: app-payment }
spec:
  provider:
    vault:
      server: "https://vault.vault.svc:8200"
      path: "kv"
      version: "v2"
      caProvider: { type: Secret, name: vault-ca, key: ca.crt, namespace: app-payment }
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "payment-service"
          serviceAccountRef: { name: payment-sa }
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata: { name: payment-db, namespace: app-payment }
spec:
  refreshInterval: 15m
  secretStoreRef: { name: vault-backend, kind: SecretStore }
  target: { name: payment-db-secret, creationPolicy: Owner }
  data:
    - secretKey: username
      remoteRef: { key: payment/db, property: username }
    - secretKey: password
      remoteRef: { key: payment/db, property: password }
```

For truly dynamic, short-lived DB creds, use the Vault Agent Injector instead (annotations on the pod) so the credential never becomes a K8s Secret at all.

---

## 2. PostgreSQL — CloudNativePG (CNPG)

**Why CNPG:** native K8s failover, continuous WAL archiving to object storage, PITR, backup/restore as CRDs, no Patroni glue to maintain.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: payment-db, namespace: data-postgres }
spec:
  instances: 3                       # 1 primary + 2 sync/async standbys
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4
  primaryUpdateStrategy: unsupervised

  postgresql:
    parameters:
      max_connections: "200"
      shared_buffers: "2GB"
      wal_level: logical
      ssl: "on"
      log_connections: "on"
      log_disconnections: "on"
      log_statement: "ddl"           # audit DDL; use pgaudit for full audit
      password_encryption: scram-sha-256
    pg_hba:
      - hostssl all all 10.0.0.0/8 scram-sha-256
      - host all all 0.0.0.0/0 reject

  bootstrap:
    initdb:
      database: payment
      owner: payment_app
      encoding: UTF8
      dataChecksums: true

  storage:      { size: 200Gi, storageClass: fast-retain }
  walStorage:   { size: 50Gi,  storageClass: fast-retain }

  backup:
    retentionPolicy: "30d"
    barmanObjectStore:
      destinationPath: "s3://pg-backups/payment-db"
      endpointURL: "https://minio.data-minio.svc:9000"
      s3Credentials:
        accessKeyId:     { name: minio-creds, key: ACCESS_KEY_ID }
        secretAccessKey: { name: minio-creds, key: SECRET_ACCESS_KEY }
      wal:        { compression: gzip, maxParallel: 4 }
      data:       { compression: gzip, immediateCheckpoint: true }

  monitoring: { enablePodMonitor: true }

  resources:
    requests: { cpu: "1", memory: 4Gi }
    limits:   { cpu: "4", memory: 8Gi }

  affinity:
    enablePodAntiAffinity: true
    topologyKey: kubernetes.io/hostname
```

Scheduled base backup:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata: { name: payment-db-daily, namespace: data-postgres }
spec:
  schedule: "0 30 2 * * *"          # 02:30 daily (6-field cron)
  backupOwnerReference: self
  cluster: { name: payment-db }
```

**Security checklist**
- App connects with a **least-privilege role** (`CONNECT`, `SELECT/INSERT/UPDATE/DELETE` on its schema only — no `CREATE`, no superuser).
- Ideally: no static app password at all — Vault DB engine issues a per-pod, 1-hour role.
- TLS required (`sslmode=verify-full` on the client, cert from internal CA).
- `pgaudit` extension for regulated workloads (bank auditors will ask who read what).
- Encryption at rest via the storage layer (LUKS/Ceph encryption) + encrypted backups.
- Never expose a NodePort/LoadBalancer for the DB. Cluster-internal Service only, restricted by NetworkPolicy to the owning app namespace.
- PgBouncer (CNPG `Pooler` CRD) in front for connection pooling.

---

## 3. Keycloak

**Deploy:** Keycloak Operator (`Keycloak` + `KeycloakRealmImport` CRDs), backed by its own CNPG cluster.

```yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata: { name: keycloak, namespace: identity }
spec:
  instances: 3
  db:
    vendor: postgres
    host: keycloak-db-rw.data-postgres.svc
    database: keycloak
    usernameSecret: { name: keycloak-db, key: username }
    passwordSecret: { name: keycloak-db, key: password }
  http:
    tlsSecret: keycloak-tls
  hostname:
    hostname: https://sso.bank.internal
    strict: true                     # prevents Host-header-based redirect attacks
  proxy:
    headers: xforwarded
  features:
    enabled: ["token-exchange", "admin-fine-grained-authz"]
  resources:
    requests: { cpu: "1", memory: 1500Mi }
    limits:   { cpu: "2", memory: 3Gi }
  additionalOptions:
    - { name: cache, value: ispn }   # clustered Infinispan for session replication
    - { name: log-level, value: INFO }
```

**Production configuration checklist**
- Realm config as code (`KeycloakRealmImport` or `keycloak-config-cli`) in Git — clients, roles, mappers, flows, password policy. Never click-configure prod.
- **Separate the admin realm from user realms.** Admin console reachable only from the management zone, behind an ingress IP allowlist + MFA.
- Password policy: length ≥ 12, complexity, history 24, `hashAlgorithm: argon2` (or pbkdf2-sha512 with high iterations), brute-force detection ON with progressive lockout.
- MFA (OTP/WebAuthn) **required** for admin and privileged roles; conditional for customers based on risk.
- Token lifetimes: access 5–15 min, refresh 30 min idle / 8h absolute, SSO session idle 30 min. Revocation on logout.
- Clients: confidential clients with client-authentication; public clients must use PKCE. Exact redirect URIs — **no wildcards**.
- Disable unused flows: implicit grant, direct grant (ROPC), and unused identity providers.
- Event logging enabled (login, login-error, admin events with representation) → forwarded to SIEM. This is a core audit artifact for a bank.
- Session cache replication verified: kill a pod, confirm users stay logged in.
- Federate to AD/LDAP for staff; keep customer identities in Keycloak's own store.

**Integrations to wire:** GitLab, Grafana, ArgoCD, Vault, Harbor, Kubernetes API (OIDC authn) — one identity, one MFA policy, one offboarding action.

---

## 4. MinIO (S3-compatible object storage)

**Deploy:** MinIO Operator, distributed mode — minimum 4 servers × 4 drives for erasure coding.

```yaml
apiVersion: minio.min.io/v2
kind: Tenant
metadata: { name: storage, namespace: data-minio }
spec:
  image: quay.io/minio/minio:RELEASE.2024-10-02T17-50-41Z
  pools:
    - servers: 4
      name: pool-0
      volumesPerServer: 4
      volumeClaimTemplate:
        spec:
          storageClassName: bulk-retain
          accessModes: ["ReadWriteOnce"]
          resources: { requests: { storage: 1Ti } }
      resources:
        requests: { cpu: "2", memory: 8Gi }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector: { matchLabels: { v1.min.io/tenant: storage } }
  requestAutoCert: false
  externalCertSecret: [{ name: minio-tls, type: cert-manager.io/v1 }]
  configuration: { name: storage-env-config }   # root creds from Vault via ESO
  features: { bucketDNS: false }
  prometheusOperator: true
```

**Security & data checklist**
- **Object Lock (WORM) enabled on backup buckets** — this is what makes backups ransomware-resistant. Set retention in compliance mode for regulated data.
- Versioning ON for buckets holding backups or documents.
- Server-side encryption (SSE-KMS) with keys from Vault Transit/KES — not SSE-S3 with local keys.
- Per-application service accounts with scoped policies (bucket-prefix level), issued from Vault; no shared root credentials.
- Bucket policies default private. No anonymous access, ever. Verify with an unauthenticated `curl`.
- Lifecycle rules: transition/expire per retention policy (e.g. daily backups 30d, weekly 90d, monthly 7y).
- Site replication to the DR site for critical buckets.
- Audit log target → SIEM (`mc admin config set target audit_webhook`).

**What uses MinIO here:** PostgreSQL WAL + base backups (CNPG/Barman), Velero cluster backups, Loki log chunks, Thanos metric blocks, Vault raft snapshots, application documents. Because it becomes the backup substrate, **MinIO's own resilience is a top-tier concern** — it must not share a failure domain with what it backs up.

---

## 5. Redis (cache / session)

- Deploy via the Bitnami chart or Redis Operator in **Sentinel or Cluster** mode, ≥ 3 nodes.
- `requirepass` + ACL users per app (no shared password), TLS enabled, dangerous commands renamed/disabled (`FLUSHALL`, `CONFIG`, `KEYS`).
- Treat as **cache, not a database** unless you enable AOF `everysec` + replica persistence and back it up.
- `maxmemory-policy allkeys-lru` for cache; `noeviction` if used as a queue/session store (and then monitor memory hard).
- Never store PII/PAN in plaintext in Redis; encrypt values at the application layer.

## 6. Kafka (event backbone, if microservices need async)

- Strimzi operator, 3 brokers + KRaft (or 3 ZK), rack-aware across nodes.
- TLS everywhere, SASL/OAUTHBEARER against Keycloak, per-topic ACLs.
- `min.insync.replicas=2`, `replication.factor=3`, `acks=all` on producers for durability.
- Topic config as code (`KafkaTopic` CRDs) in GitOps; schema registry with compatibility enforcement.
- Retention set deliberately per topic — Kafka retention is not a backup; mirror critical topics (MirrorMaker2) to DR.

---

## 7. Deployment order & dependency graph

```
cert-manager ──► internal CA issuer
     │
     ├─► Vault (bootstrap TLS) ──► Vault PKI ──► (re-issue all certs from Vault)
     │        │
     │        └─► External Secrets Operator ──► all namespaces get secrets
     │
     ├─► CNPG operator ──► keycloak-db, app DBs
     │                          │
     ├─► MinIO ◄────────────────┘ (backup target; must exist before backups matter)
     │
     ├─► Keycloak ──► OIDC for Grafana, ArgoCD, GitLab, Harbor, K8s
     │
     ├─► Monitoring stack ──► scrape everything above
     │
     └─► Velero ──► cluster + PVC backups to MinIO
```
