# Kubernetes — Interview Q&A

---

## Architecture

**Q1. Walk me through what happens when you run `kubectl apply -f deployment.yaml`.**
kubectl resolves the context and sends an authenticated request to the
kube-apiserver. The apiserver authenticates (cert/OIDC/token), authorises
(RBAC), runs mutating admission webhooks, validates the schema, runs validating
admission (PSA, Kyverno), and persists the object in etcd. The Deployment
controller sees the new object via a watch and creates a ReplicaSet; the
ReplicaSet controller creates Pods; the scheduler filters and scores nodes and
binds each Pod; the kubelet on that node pulls the image, asks the CRI runtime
to start containers, and the CNI plugin wires the network namespace. The
endpoints controller adds the Pod to EndpointSlices once readiness passes, and
kube-proxy (or eBPF) programs the dataplane. Nothing in that chain is a
transaction — it's independent control loops converging.

**Q2. Why is etcd the thing you protect most?**
It holds the entire cluster state, including Secrets, which are only base64
encoded by default. Read access to etcd is read access to every credential in
the cluster. So: encryption at rest, mTLS between members and the apiserver, no
network path from workloads, dedicated disks (it's fencing-sensitive to latency
— slow disks cause leader elections and apiserver timeouts), odd member count
for quorum, and regularly *restored* snapshots.

**Q3. Deployment vs StatefulSet vs DaemonSet.**
Deployment: interchangeable stateless replicas, random names, rolling update via
ReplicaSets. StatefulSet: stable ordinal identity (`db-0`, `db-1`), stable DNS
via a headless Service, a dedicated PVC per ordinal that survives the pod, and
ordered create/update/delete — for quorum systems that need to know who they
are. DaemonSet: exactly one pod per (matching) node for node-level agents.
Caveat worth mentioning: a StatefulSet gives you *identity*, not a database —
replication, failover and backup are still the operator's job, which is why we
run CloudNativePG rather than a hand-rolled StatefulSet.

---

## Networking

**Q4. How does a Service actually route traffic?**
A Service is a stable virtual IP plus a label selector. The endpoints controller
watches Pods matching the selector and writes the **Ready** ones into
EndpointSlices. kube-proxy (iptables/IPVS) or the CNI's eBPF datapath programs
each node so that traffic to the ClusterIP is DNAT'd to one of those Pod IPs.
There is no proxy process in the path in iptables mode — it's kernel-level
rewriting, which is why you can't see a Service in `netstat`. Load balancing is
random/round-robin per connection, not per request, which matters for HTTP/2 and
gRPC: long-lived connections pin to one pod, so you need client-side LB or a mesh.

**Q5. My Service returns connection refused. Debug it.**
`kubectl get endpointslices` first — empty means either the selector doesn't
match any pod's labels, or no pod is Ready (which is a probe problem, not a
network problem). If endpoints exist, curl a Pod IP directly from a debug pod:
success means the app is fine and the problem is the Service/kube-proxy layer;
failure means the app isn't listening on that port or is bound to 127.0.0.1
instead of 0.0.0.0. Then check `targetPort` vs `containerPort`, then
NetworkPolicy — including the DNS egress rule, which is the single most common
cause of "it worked until we turned on default-deny".

**Q6. Explain NetworkPolicy semantics.**
They're additive allowlists enforced by the CNI (so they do nothing if your CNI
doesn't implement them — a real trap on some managed clusters). A pod is
unrestricted until *some* policy selects it; then it's default-deny for the
policyTypes listed, and the union of all matching policies forms the allowlist.
There is no deny rule and no ordering. Two subtleties: `namespaceSelector` and
`podSelector` inside the same `from` element is AND, but as separate list items
it's OR — easy to accidentally allow a whole namespace; and standard
NetworkPolicy is L3/L4 only, so "allow GET /health but not POST" needs a mesh or
gateway.

**Q7. Ingress vs Gateway API vs service mesh.**
Ingress is the legacy L7 north-south API — simple, but every real feature lives
in controller-specific annotations, which are unportable and unvalidated.
Gateway API is its role-aware replacement: infra teams own `GatewayClass`/
`Gateway`, app teams own `HTTPRoute`, and traffic splitting/header matching are
typed fields rather than annotation strings. A service mesh handles *east-west*:
mTLS identity between pods, retries, circuit breaking, and per-hop telemetry.
They're complementary. I'd add a mesh when I need workload-identity mTLS or
fine-grained traffic policy between services — not for "observability", which is
cheaper to get from instrumentation.

---

## Reliability

**Q8. Difference between the three probes, and the classic mistake.**
Startup gates the other two while a slow app boots. Readiness controls Service
membership. Liveness restarts the container. The classic mistake is a liveness
probe that checks the database: when the DB has a blip, every replica fails
liveness at once and the platform restarts the entire fleet, turning a partial
degradation into a full outage — and the restarts then hammer the recovering DB.
Liveness must only answer "is this process wedged?"; dependency health belongs in
readiness, and even there you should think hard, because a shared dependency
failing will drop your whole fleet out of the load balancer.

**Q9. How do you achieve zero-downtime deploys?**
Five things together, and missing any one gives you 502s: `maxUnavailable: 0`
with `maxSurge`, so capacity never dips; a readiness probe that goes false at
the *start* of shutdown so the endpoint is removed first; a `preStop` sleep
longer than the LB/kube-proxy deregistration lag (endpoint removal is
eventually consistent — the pod can receive traffic after it got SIGTERM); an
app that handles SIGTERM by draining in-flight requests; and
`terminationGracePeriodSeconds` longer than preStop + drain. Plus a PDB so
voluntary disruptions like node drains respect the same rules.

**Q10. What is a PodDisruptionBudget and how do you get it wrong?**
It bounds *voluntary* disruptions (drains, evictions) — not crashes or node
failure. You get it wrong by setting `minAvailable` equal to `replicas`, which
makes every drain block forever and stalls cluster upgrades; or by setting it on
a single-replica deployment, same result. It also doesn't help if the app can't
survive losing one replica in the first place.

**Q11. A node goes NotReady. What happens and how fast?**
The kubelet stops heartbeating; after `node-monitor-grace-period` (~40s) the node
controller marks it NotReady and taints it; pods get `NoExecute` tolerations with
a default 300s, so eviction begins ~5 minutes later. StatefulSet pods with
attached volumes may not reschedule until the volume detaches or you force-delete
— which is dangerous for quorum systems, because force-deleting a pod the
cluster still believes is running risks split brain. Faster failover means tuning
tolerationSeconds and having a storage layer that fences properly.

---

## Security

**Q12. How do you secure a multi-tenant cluster?**
Namespace per tenant with ResourceQuota and LimitRange; RBAC scoped to the
namespace with no cluster-wide read on secrets; Pod Security Admission at
`restricted`; default-deny NetworkPolicy in every namespace; separate node pools
with taints for sensitive workloads; and admission policies (Kyverno) enforcing
signed images from the internal registry, required labels, and no `hostPath`. I'd
be honest that namespaces are a *soft* boundary — shared kernel, shared control
plane — so for genuinely hostile tenancy the answer is separate clusters or
sandboxed runtimes, not more YAML.

**Q13. Are Kubernetes Secrets secure?**
Not by themselves — base64 in etcd, visible to anyone with `get secrets` in the
namespace or read access to etcd or a node's kubelet. Minimum bar: encryption at
rest with a KMS provider, tight RBAC, `automountServiceAccountToken: false`. The
real answer is to stop storing long-lived secrets: External Secrets Operator or
Vault Agent injection issues short-lived, per-workload credentials — dynamic DB
credentials with a 1-hour TTL make a leaked secret a much smaller event, and
rotation stops being a project.

**Q14. What is admission control and why does it matter more than policy docs?**
Admission webhooks run inside the apiserver request path, so they're the last
place a bad object can be stopped regardless of how it was submitted — CI,
ArgoCD, or a human with kubectl. Mutating webhooks can inject sidecars/defaults;
validating webhooks (Kyverno, Gatekeeper) reject. The important design decision
is `failurePolicy: Fail` — fail-closed, so an outage of the policy engine can't
silently disable your controls — paired with high availability and namespace
exclusions for kube-system so you can't lock yourself out of your own cluster.

---

## Resources and scale

**Q15. Should you set CPU limits?**
Requests, always — that's what the scheduler and the guaranteed share use. CPU
limits cause CFS throttling: the container is stopped for the rest of each 100ms
period once it burns its quota, which produces p99 latency spikes even on an idle
node. My default is memory request + memory limit (memory is incompressible, so
an unbounded leak takes the whole node), CPU request, and no CPU limit for
latency-sensitive services; CPU limits for untrusted or batch workloads where
predictability matters more than tail latency. And I'd say it's a stance to
validate with throttling metrics (`container_cpu_cfs_throttled_periods_total`),
not a religion.

**Q16. Explain QoS classes and eviction order.**
`Guaranteed` (requests == limits for every container), `Burstable` (requests set,
lower than limits), `BestEffort` (nothing set). Under node memory pressure the
kubelet evicts BestEffort first, then Burstable pods most over their requests,
then Guaranteed. So requests aren't just scheduling hints — they're your
survival ranking.

**Q17. HPA, VPA, Cluster Autoscaler — how do they interact?**
HPA changes replica count based on metrics; VPA changes the requests of
individual pods; Cluster Autoscaler (or Karpenter) adds/removes nodes when pods
are unschedulable or nodes are underused. HPA and VPA must not both act on CPU
for the same workload — they fight, because VPA lowering requests raises measured
utilisation, which makes HPA scale out. Practical combination: HPA on a
meaningful metric (RPS or queue depth via KEDA, not just CPU), VPA in
recommendation mode to inform requests, Cluster Autoscaler underneath. Also:
scale-out is bounded by pod startup time, so the honest answer to bursty traffic
often includes headroom/over-provisioning, not just autoscaling.

---

## Operations

**Q18. Helm or Kustomize?**
Both, for different jobs. Helm is a package manager — right for third-party
software with dependencies and a versioned release artifact. Kustomize is
patching — right for our own manifests across environments, with no templating
language between you and the YAML you'll debug at 3am. What I care about more
than the choice: both are rendered from Git by ArgoCD, so there's no imperative
`helm install` state that differs from the repo.

**Q19. What is GitOps and what does it actually buy you?**
Git is the single source of desired state; an in-cluster agent pulls and
reconciles continuously. Concretely it buys: a complete audit trail of who
changed what in prod, with review, for free; drift detection and auto-repair of
manual changes; rollback as `git revert`; and — the one people undersell — CI
never needs prod credentials, because the cluster pulls instead of the pipeline
pushing. _(regulated)_ That last point is often what makes the separation-of-
duties control workable at all.

**Q20. Production is down, pods are CrashLoopBackOff. Walk me through it.**
`kubectl logs --previous` first — the crashed container's output is the actual
error and the current container's logs are usually empty. In parallel,
`describe` for events and exit code: 137 means OOMKilled, exit 1 in the first
seconds means bad config or a failed migration, healthy-then-killed around the
probe interval means the liveness probe. Then the real question: what changed?
Check the last ArgoCD sync / image digest / ConfigMap revision. If it correlates
with a deploy, roll back first (`rollout undo` or revert the Git commit) and
diagnose from the artifacts afterwards — mitigation before root cause. If it
doesn't correlate with a deploy, look for an external change: expired cert,
rotated credential, a dependency's incident, disk full on nodes.

**Q21. How do you upgrade a production cluster?**
Read the release notes and the deprecated-API report first (`kubectl deprecations`
/ Pluto) — removed APIs break manifests silently. Upgrade the control plane one
minor version at a time, never skipping. Then nodes, by cordon → drain (respecting
PDBs) → replace, ideally by rolling in new nodes from a fresh image rather than
in-place upgrade. Do it in dev → staging → prod with a soak period, off peak, with
etcd snapshots taken and *restore-tested* beforehand, and with a documented
rollback (which for the control plane usually means restore from snapshot, so
that snapshot had better be good).

**Q22. When would you *not* use Kubernetes?**
When the operational cost outweighs the benefit: a handful of services with no
elasticity requirement, a small team with no platform capacity, workloads that
are a bad fit (heavy stateful databases better run managed or on VMs), or strict
latency/kernel requirements. Kubernetes buys you a common declarative API and a
scheduler; it charges you an entire platform team. This repo deliberately keeps a
VM track alongside the K8s track for exactly that reason.
