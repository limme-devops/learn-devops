# Backup Strategy & Disaster Recovery

> **Author:** Mengty LIM

> A backup that has never been restored is a hypothesis, not a backup.

## 1. The core concepts

**3-2-1-1-0 rule**
- **3** copies of data
- **2** different media/storage types
- **1** copy off-site (DR site)
- **1** copy immutable / air-gapped (WORM, object-lock) — *this is your ransomware defence*
- **0** errors in the last verified restore test

**RTO** = how long you may take to restore service. **RPO** = how much data you may lose. Both are **business decisions**, not IT decisions — get them signed off, then engineer to them. Every additional nine costs money; make the business say the number.

**Backup types**
| Type | What | Use |
|---|---|---|
| Full | Everything | Weekly baseline |
| Incremental | Changes since last backup of any kind | Daily, cheap, slower restore |
| Differential | Changes since last full | Compromise |
| Continuous (WAL/CDC) | Every transaction | Low RPO, enables PITR |
| Snapshot | Point-in-time volume copy | Fast local rollback — **not a backup** (same failure domain) |

## 2. RTO/RPO targets per tier

| Tier | Example systems | RTO | RPO | Method |
|---|---|---|---|---|
| **Tier 0 — critical** | Core banking DB, payments, Keycloak, Vault | 15 min | ~0 (sync replica) | Sync replication + WAL streaming + hot standby at DR |
| **Tier 1 — important** | Customer portal, internal APIs, Kafka | 1 h | 15 min | Async replication + hourly backups |
| **Tier 2 — standard** | Reporting, internal tools | 4 h | 24 h | Nightly backup |
| **Tier 3 — low** | Dev/test | 24 h | 24 h | Nightly, best-effort |

Classify every system into a tier and **write it on the service's README**. Untiered systems get Tier 2 by default.

## 3. What to back up, per component

| Component | What | Tool | Frequency | Where |
|---|---|---|---|---|
| PostgreSQL | Base backup + continuous WAL | CNPG/Barman (or pgBackRest on VM) | base daily, WAL continuous | MinIO (object-lock) + DR site |
| Kubernetes cluster state | Namespaces, CRDs, workloads | **Git is the source of truth**; Velero for the rest | on change (Git) / daily (Velero) | Git + MinIO |
| PVC data | Volume contents | Velero + CSI snapshots (restic/Kopia for non-CSI) | daily | MinIO |
| etcd | Cluster state | `etcdctl snapshot save` / RKE2 built-in | every 30 min, keep 48 | encrypted, off-cluster |
| Vault | Raft snapshot + unseal key custody | `vault operator raft snapshot` | hourly | encrypted, separate key, object-lock |
| Keycloak | Its PostgreSQL DB + realm export | CNPG backup + `kc.sh export` | DB continuous, realm on change | MinIO + Git (realm config) |
| MinIO itself | Bucket data | Site replication + versioning | continuous | DR site MinIO |
| Kafka | Critical topics | MirrorMaker2 to DR | continuous | DR cluster |
| VM servers | Config = Ansible in Git; data volumes | Ansible (config) + Velero/Restic/backup agent (data) | daily | backup server + off-site |
| Golden images | Packer artifacts | artifact repo | per build | Harbor/Nexus, replicated |
| Secrets/PKI | Vault snapshot covers it; CA root offline | manual ceremony | on change | offline HSM/safe |
| Source & IaC | Everything | GitLab repo backup + replicated remote | daily | off-site |
| Monitoring | Thanos blocks / Loki chunks (already in MinIO) | lifecycle policy | continuous | MinIO + replication |
| CI/CD config | JCasC, GitLab CI, runners | in Git | on change | Git |

**Note the pattern:** if it's config, it belongs in Git and Git is the backup. Only *state* needs a backup product.

## 4. Immutability & ransomware resistance

This is the control that actually saves you, so build it deliberately:

1. Backup bucket in MinIO/S3 with **Object Lock in compliance mode** + versioning. Retention ≥ your RPO window (e.g. 35 days).
2. The backup writer identity has `PutObject` only — **no `DeleteObject`, no lock-config permission, no lifecycle permission**. Deletion is impossible even with stolen credentials.
3. The backup storage is in a different trust domain: separate credentials, separate network zone, separate admin group from production K8s admins.
4. An off-line/air-gapped copy for Tier 0 (tape, or a replicated cluster that only pulls, never accepts pushes).
5. Alert on: backup job failure, backup size anomaly (sudden shrink = something wrong), mass-delete API calls, retention-policy changes.
6. Encrypt backups with a key **not** stored in the environment being backed up.

## 5. Restore drills — the non-negotiable part

| Drill | Frequency | Success criteria |
|---|---|---|
| Restore a single DB table from backup | monthly | correct data, < 30 min |
| PITR a database to an arbitrary timestamp | quarterly | lands within RPO, app connects clean |
| Restore a namespace from Velero into a scratch cluster | quarterly | workloads healthy, data intact |
| Rebuild a cluster from scratch (IaC + GitOps + restore) | half-yearly | meets Tier-1 RTO |
| Full DR failover to secondary site | annually (regulators often mandate) | business validates transactions end-to-end |
| Vault unseal + restore ceremony | half-yearly | key custodians available, documented |
| Ransomware scenario (assume prod compromised, restore from immutable) | annually | restored without touching compromised creds |

Record every drill: date, who, what was restored, **measured** RTO/RPO vs target, what failed, action items. This record is the single most requested artifact in a BC/DR audit.

## 6. DR site design

```
        Primary site                          DR site
  ┌──────────────────────┐            ┌──────────────────────┐
  │ K8s prod cluster      │            │ K8s DR cluster        │
  │ PostgreSQL primary    │──async/sync│ PostgreSQL standby    │
  │ MinIO                 │──replicate─│ MinIO                 │
  │ Kafka                 │──MM2──────►│ Kafka                 │
  │ Vault (Raft)          │──perf repl─│ Vault (perf standby)  │
  │ Keycloak              │            │ Keycloak (DB-followed)│
  └──────────────────────┘            └──────────────────────┘
            ▲                                    ▲
            └────── GitOps repo (same source of truth) ──────┘
```

- **Warm standby** is the usual bank choice: DR runs the platform continuously, apps scaled to minimum, data replicating. Failover = scale up + DNS/GSLB switch + promote DB.
- Failover must be **documented, scripted, and rehearsed**, including the decision authority ("who declares a disaster") and the communication tree.
- **Test failback too.** Most teams rehearse failover and discover failback is undefined.
- Keep DR capacity honest: if DR can only run 40% of prod load, that's your real DR capability — state it, don't pretend.
- Watch the hidden dependencies: DNS, NTP, PKI, the IdP, the artifact registry, the secret store. A DR site that can't reach Vault or pull images cannot start anything.

## 7. Backup runbook skeleton (put one per system in `runbooks/`)

```
## Restore: payment-db to a point in time

Preconditions: incident declared, write traffic stopped, target timestamp agreed with business.
Blast radius: payment-service unavailable during restore; upstream queues will buffer ~2h.

1. Freeze writes:      kubectl scale deploy/payment-service --replicas=0 -n app-payment
2. Identify backup:    kubectl get backups -n data-postgres
3. Create recovery cluster from the Backup CR with `recoveryTarget.targetTime: "<ts>"`
4. Wait for recovery:  kubectl get cluster payment-db-restored -w
5. Validate:           row counts + last-transaction check against the app's reconciliation query
6. Repoint service:    update the Service/secret to the restored cluster
7. Resume:             kubectl scale deploy/payment-service --replicas=3
8. Verify:             smoke test + business sign-off
9. Record:             actual RTO, actual data loss, in the incident ticket

Rollback if restore is wrong: the original cluster is untouched — repoint back and retry with a different target time.
Escalation: DBA on-call → platform lead → CTO (SEV1)
```
