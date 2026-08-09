# Local Lab

> **Author:** Mengty LIM

A local cluster you can actually break. The point of this directory is that
every pattern in `gitops/` and `security/` can be exercised without vSphere,
Vault, Harbor, or a bank.

## Prerequisites

| Tool | Purpose |
|---|---|
| `docker` / `podman` | container runtime for kind |
| `kind` | the cluster |
| `kubectl` | obviously |
| `helm` | Cilium, Kyverno |
| `kustomize` | rendering overlays |
| `kubectl-argo-rollouts` | watching canaries |

```bash
make lab-up      # ~5 minutes on first run
make lab-down
```

## What differs from production, and why

| Production | Lab | Reason |
|---|---|---|
| RKE2, 3 control planes | kind, 1 control plane | etcd quorum needs real nodes; the lab is not testing HA |
| Kyverno **Enforce** | Kyverno **Audit** | no Harbor, no Cosign signatures — Enforce would block every pod. `kubectl get policyreport -A` still shows what would have been rejected |
| Vault + External Secrets | plain Secrets | running Vault HA locally teaches Vault, not the platform |
| CloudNativePG cluster | single Postgres pod | failover needs three nodes with real storage |
| Real TLS from Vault PKI | self-signed | certificate *rotation* is the interesting part, and it needs Vault |

Everything else — NetworkPolicy, Pod Security Admission, resource limits,
probes, PDBs, topology spread, canary analysis — behaves the same. That is
deliberate: those are the things that silently do nothing if you get them wrong.

## Exercises worth doing

**1. Prove the NetworkPolicy works.** Most people write one and never test it.
```bash
kubectl run test --rm -it --image=nicolaka/netshoot -n app-payment -- bash
# from inside: curl payment-service:8080   -> should work
#              curl google.com             -> should hang (egress denied)
#              nslookup payment-service    -> should work (DNS explicitly allowed)
```
Now delete `payment-service-allow-dns` and watch everything break. That is the
lesson: forgetting the DNS rule is the single most common NetworkPolicy bug.

**2. Watch a canary abort.** Deploy a version that returns 500s and observe the
analysis fail the rollout automatically.
```bash
kubectl argo rollouts get rollout payment-service -n app-payment --watch
```

**3. See what policy would have blocked.**
```bash
kubectl get policyreport -A -o wide
kubectl get clusterpolicyreport -o wide
```
Try applying a pod running as root, with no limits, using `:latest`. Read the
report. Then fix the manifest until the report is clean — that is exactly the
loop that happens in a real MR.

**4. Break a probe on purpose.** Point `readinessProbe` at a path that 404s and
watch the rollout stall rather than serve traffic to a broken pod. Then point
`livenessProbe` at a dependency check and watch pods restart in a loop when the
dependency is down — the mistake this repo warns about in `rollout.yaml`.

**5. Drain a node with and without the PDB.**
```bash
kubectl drain learn-devops-worker --ignore-daemonsets --delete-emptydir-data
```
Delete the PDB and repeat. Notice how many replicas disappear at once.
