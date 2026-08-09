# Kubernetes Cheat Sheet

Workloads, networking, storage, security, scheduling, debugging.

---

## 1. Control plane in one paragraph

`kube-apiserver` is the only thing that talks to `etcd`; everything else is a
client. You `POST` desired state; controllers in `kube-controller-manager` (and
CRD controllers) watch and reconcile actual toward desired; `kube-scheduler`
binds Pods to Nodes; `kubelet` on each node makes the Pod real via the container
runtime; `kube-proxy`/CNI programs the network. **Everything is a control loop.**
That is why "why is it still coming back after I deleted it?" is always answered
by "something owns it" — find the owner reference.

---

## 2. kubectl survival kit

```bash
# context / namespace
kubectl config get-contexts
kubectl config use-context prod
kubectl config set-context --current --namespace=payments

# look around
kubectl get pods -o wide --sort-by=.status.startTime
kubectl get events --sort-by=.lastTimestamp -A | tail -40   # the first place to look
kubectl describe pod api-7d9f-abc                            # events at the bottom
kubectl get pod api-7d9f-abc -o yaml | less
kubectl api-resources                                        # what kinds exist here
kubectl explain deployment.spec.strategy.rollingUpdate       # built-in docs

# logs
kubectl logs -f deploy/api --tail=200
kubectl logs api-7d9f-abc -c sidecar --previous              # previous crash!
kubectl logs -l app=api --max-log-requests=10 --prefix

# exec / debug
kubectl exec -it deploy/api -- sh
kubectl debug -it pod/api-7d9f-abc --image=nicolaka/netshoot --target=api
kubectl debug node/node-3 -it --image=busybox                # node-level
kubectl run tmp --rm -it --image=curlimages/curl --restart=Never -- sh

# traffic
kubectl port-forward svc/api 8080:80
kubectl get endpointslices -l kubernetes.io/service-name=api  # is the Service wired?

# rollout
kubectl rollout status deploy/api --timeout=300s
kubectl rollout history deploy/api
kubectl rollout undo deploy/api --to-revision=3
kubectl rollout restart deploy/api                            # re-pull secrets/config
kubectl scale deploy/api --replicas=6

# capacity
kubectl top nodes; kubectl top pods --sort-by=memory
kubectl describe node node-3 | sed -n '/Allocated/,/Events/p'
kubectl get pods -A --field-selector spec.nodeName=node-3

# rbac
kubectl auth can-i create deployments --as=system:serviceaccount:payments:ci -n payments
kubectl auth can-i --list --as=system:serviceaccount:payments:api

# apply safely
kubectl diff -f manifest.yaml           # ALWAYS before apply
kubectl apply -f manifest.yaml --server-side --field-manager=me
kubectl delete pod api-7d9f --grace-period=30
```

Output tricks:
```bash
-o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}'
-o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount'
--watch  --show-labels  --field-selector status.phase=Failed
```

---

## 3. Workload objects — which to use

| Kind | Use for | Key property |
|---|---|---|
| **Deployment** | Stateless services | ReplicaSets give you rolling update + `rollout undo` |
| **StatefulSet** | Databases, brokers, quorum systems | Stable network id + stable PVC per ordinal, ordered rollout |
| **DaemonSet** | Node agents (log shipper, CNI, Falco) | One per node, tolerates node taints |
| **Job / CronJob** | Batch, migrations | `backoffLimit`, `ttlSecondsAfterFinished`, `concurrencyPolicy: Forbid` |
| **Argo Rollout** (CRD) | Canary / blue-green with automated analysis | Replaces Deployment for prod-critical services |

### A Deployment worth copying

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: api, namespace: payments }
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }   # 0 = never lose capacity
  selector: { matchLabels: { app: api } }
  template:
    metadata:
      labels: { app: api, version: "1.4.2" }
    spec:
      serviceAccountName: api
      automountServiceAccountToken: false      # unless the app calls the API server
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile: { type: RuntimeDefault }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector: { matchLabels: { app: api } }
      terminationGracePeriodSeconds: 45
      containers:
        - name: api
          image: registry.internal/api@sha256:0000…   # digest, not tag
          imagePullPolicy: IfNotPresent
          ports: [{ name: http, containerPort: 8080 }]
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits:   { memory: 512Mi }          # no CPU limit — see §8
          startupProbe:                          # slow starters: protects liveness
            httpGet: { path: /healthz, port: http }
            failureThreshold: 30
            periodSeconds: 5
          readinessProbe:                        # "send me traffic?"
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:                         # "kill me?" — keep it dumb
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            failureThreshold: 6
          lifecycle:
            preStop: { exec: { command: ["sleep", "10"] } }   # let the LB deregister
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
      volumes:
        - { name: tmp, emptyDir: { medium: Memory, sizeLimit: 64Mi } }
```

Always ship alongside it: `Service`, `PodDisruptionBudget`, `NetworkPolicy`,
`ServiceAccount`, `HorizontalPodAutoscaler`, `PrometheusRule`, dashboard, runbook.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: api }
spec:
  minAvailable: 2          # or maxUnavailable: 1 — NOT minAvailable == replicas
  selector: { matchLabels: { app: api } }
```
> A PDB with `minAvailable` equal to the replica count blocks every node drain
> forever. This is the single most common cause of "the cluster upgrade is stuck".

---

## 4. Probes — the rules people get wrong

| Probe | Question | Failure means |
|---|---|---|
| `startupProbe` | "Has it finished booting?" | Others are suspended until it passes |
| `readinessProbe` | "Can it serve now?" | Removed from Service endpoints. Pod keeps running |
| `livenessProbe` | "Is it wedged beyond recovery?" | Container is **killed** and restarted |

- **Liveness must not check dependencies.** If `/healthz` pings the database, a
  DB blip restarts every pod in the fleet simultaneously — you converted a
  degradation into an outage. Dependencies belong in readiness (at most).
- Readiness must fail **before** shutdown begins, and `preStop` must outlive the
  LB's deregistration interval, otherwise you get 502s on every deploy.
- Use `startupProbe` for JVM/slow apps instead of a huge `initialDelaySeconds`.

---

## 5. Networking

```
Pod ──> Service (ClusterIP, stable VIP) ──> EndpointSlice ──> Pod IPs
                                   ▲ managed by the endpoints controller,
                                     membership = readiness
Ingress / Gateway API ──> Service ──> Pods
```

| Service type | Use |
|---|---|
| `ClusterIP` | Default. In-cluster only |
| `NodePort` | Rarely direct; the plumbing under a cloud LB |
| `LoadBalancer` | Cloud LB or MetalLB on-prem |
| `ExternalName` | CNAME to something outside |
| Headless (`clusterIP: None`) | StatefulSet peers, client-side LB, per-pod DNS |

DNS: `svc.ns.svc.cluster.local`. A pod in the same namespace can just use `svc`.
**`ndots:5`** means unqualified lookups try 4–5 search domains first — a common
source of DNS load; fully-qualify hot lookups (trailing dot) if it hurts.

### NetworkPolicy — default deny (and the DNS rule everyone forgets)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny, namespace: payments }
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: api-allow, namespace: payments }
spec:
  podSelector: { matchLabels: { app: api } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kong } }
          podSelector: { matchLabels: { app: kong } }
      ports: [{ port: 8080, protocol: TCP }]
  egress:
    - to: [{ podSelector: { matchLabels: { app: postgres } } }]
      ports: [{ port: 5432, protocol: TCP }]
    - to:                                        # ← the forgotten one
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector: { matchLabels: { k8s-app: kube-dns } }
      ports: [{ port: 53, protocol: UDP }, { port: 53, protocol: TCP }]
```

Policies are **additive allowlists**: any policy selecting a pod flips it to
deny-by-default for the listed `policyTypes`; there is no "deny" rule. Note also
that `namespaceSelector` + `podSelector` in *one* `from` element is AND; as two
list items it is OR — a classic silent over-permission.

---

## 6. Config, secrets, storage

```bash
kubectl create configmap app-cfg --from-file=app.yaml --dry-run=client -o yaml
kubectl create secret generic db --from-literal=pw=… --dry-run=client -o yaml
```

- Secrets are **base64, not encrypted** — enable etcd encryption-at-rest and
  restrict RBAC. Better: don't store them at all; use External Secrets Operator
  or Vault Agent injection so the value is short-lived and issued per workload.
- A ConfigMap/Secret change does **not** restart pods. Either hash the content
  into a pod annotation (Kustomize/Helm do this) or `kubectl rollout restart`.
- Mounted ConfigMaps update in-place (~60s, kubelet sync) — but only if the app
  re-reads the file. `envFrom` values never update.

| Storage | Note |
|---|---|
| `emptyDir` | Dies with the pod. `medium: Memory` counts against the memory limit |
| PVC + StorageClass | `volumeBindingMode: WaitForFirstConsumer` avoids scheduling a pod into a zone with no volume |
| `reclaimPolicy: Retain` _(regulated)_ | Deleting a PVC must not delete the data |
| `volumeClaimTemplates` | StatefulSet only; PVCs survive pod deletion and are **not** deleted when you delete the StatefulSet |

---

## 7. RBAC and workload security

```yaml
kind: Role                      # namespace-scoped; ClusterRole for cluster-wide
rules:
  - apiGroups: [""]
    resources: ["pods","pods/log"]
    verbs: ["get","list","watch"]
```
`RoleBinding` grants a Role (or a ClusterRole, scoped to that namespace) to a
subject. Verify with `kubectl auth can-i --list --as=…` rather than reading YAML.

Never grant: `cluster-admin`, `escalate`, `bind`, `impersonate`, `*` on `*`,
`create` on `pods/exec` in prod, or `secrets: list` cluster-wide (that's every
secret in the cluster).

**Pod Security Admission** — label the namespace:
```bash
kubectl label ns payments \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.30
```
`restricted` = non-root, no privilege escalation, drop ALL caps, seccomp
RuntimeDefault, no hostPath/hostNetwork/hostPID. Anything PSA can't express
(image registry allowlists, required labels, signature verification) goes to
Kyverno/Gatekeeper in `Enforce`/fail-closed mode.

---

## 8. Scheduling, resources, autoscaling

**QoS classes:** `Guaranteed` (requests == limits on every container) →
`Burstable` (requests set, limits differ) → `BestEffort` (nothing set, first to
be evicted). Set requests on everything; BestEffort in prod is negligence.

**CPU limits are contentious.** Requests give you a guaranteed share; a CPU
*limit* causes CFS throttling that shows up as p99 latency even when the node is
idle. Common production stance: always set memory requests **and** limits
(memory is incompressible — no limit means one leak takes the node), set CPU
requests, and omit CPU limits except for untrusted or noisy batch workloads.

```yaml
# spread and placement
nodeSelector: { workload: payments }
tolerations: [{ key: dedicated, operator: Equal, value: payments, effect: NoSchedule }]
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector: { matchLabels: { app: api } }
```

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: api }
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
  behavior:
    scaleDown: { stabilizationWindowSeconds: 300 }   # don't flap
```
HPA scales on load; **Cluster Autoscaler / Karpenter** adds nodes when pods are
`Pending`; **VPA** right-sizes requests (never run VPA and HPA on the same CPU
metric). `PriorityClass` decides who gets preempted when the cluster is full.

---

## 9. Debugging decision tree

```
Pod not Running?
├── Pending           → kubectl describe pod → Events
│     "Insufficient cpu/memory"  → node capacity / requests too big
│     "didn't match node selector/affinity/taint" → placement
│     "waiting for volume"       → PVC unbound, wrong zone, no provisioner
├── ContainerCreating → image pull, secret/configmap missing, CNI failure
│     ErrImagePull / ImagePullBackOff → wrong digest, no imagePullSecret, registry down
├── CrashLoopBackOff  → kubectl logs --previous  ← the actual error is here
│     exit 137 = OOMKilled (raise memory limit / fix leak)
│     exit 1 at 2s   = bad config / missing env / migration failure
│     healthy then killed at ~30s = liveness probe too aggressive
├── Running, not Ready → readiness failing: kubectl describe → probe output
└── Terminating forever → finalizer stuck, or a PDB/graceful shutdown hang
```

```
Service returns nothing?
1. kubectl get endpointslices  → empty means NO pod is Ready, or selector mismatch
2. kubectl exec into a debug pod → curl the pod IP directly (app vs network?)
3. curl the ClusterIP           → kube-proxy / iptables layer
4. Check NetworkPolicy          → is DNS (53/UDP) allowed?
5. Check Ingress → Service name/port, TLS secret, ingress class
```

Useful one-liners:
```bash
kubectl get pods -A | grep -Ev 'Running|Completed'
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -30
kubectl get pods -A -o json | jq -r '.items[]|select(.status.containerStatuses[]?.restartCount>3)|"\(.metadata.namespace)/\(.metadata.name)"'
kubectl get --raw /metrics | grep apiserver_request_total | head
```

---

## 10. Helm vs Kustomize (say this in the interview)

| | Helm | Kustomize |
|---|---|---|
| Model | Go templates + values → render | Patch/overlay real YAML |
| Strength | Distributing third-party software, packaging, dependencies | Environment variants of *your own* manifests, no templating language |
| Weakness | Template soup; `helm install` is imperative state in-cluster | No loops/conditionals; deep patches get verbose |
| Typical use | Platform components (Kong, Prometheus, cert-manager) | Your services: `base/` + `overlays/{dev,stg,prod}` |

Practical hybrid, and the one this repo uses: Helm for vendor charts (rendered by
ArgoCD, never `helm install` by hand), Kustomize for business services, ArgoCD
reconciling both from Git.

```bash
helm upgrade --install kong kong/kong -n kong --create-namespace -f values.yaml --atomic --wait
helm template kong kong/kong -f values.yaml | kubectl diff -f -    # see it first
helm rollback kong 3
kubectl kustomize overlays/prod | kubectl diff -f -
```

---

## 11. Best practices checklist

- [ ] Images by digest from an internal registry; admission verifies signature
- [ ] Requests on everything; memory limits set; CPU limits deliberate
- [ ] Three probes configured, liveness dependency-free
- [ ] `terminationGracePeriodSeconds` > `preStop` + real drain time
- [ ] PDB present and not equal to replica count
- [ ] Topology spread across zones/nodes; anti-affinity for singletons
- [ ] Default-deny NetworkPolicy per namespace, DNS explicitly allowed
- [ ] Dedicated ServiceAccount, token automount off unless needed
- [ ] PSA `restricted` enforced; Kyverno fail-closed for the rest
- [ ] No secret material in Git; ESO/Vault issues it short-lived
- [ ] etcd encrypted at rest, audit log shipped to the SIEM _(regulated)_
- [ ] Everything in Git, reconciled by ArgoCD; `kubectl apply` by a human is an incident
- [ ] etcd + PV backups (Velero) with a **drilled, timed** restore

➡ [Interview Q&A](interview-qna.md)
