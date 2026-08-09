# Private-Access Deployment Procedure — Internal Apps, Wildcard DNS/TLS, VPN

> **Author:** Mengty LIM

How to deploy a service that must **not** be reachable from the internet, and
how the people who are allowed to reach it actually get there.

Companion to [13-edge-gateway.md](13-edge-gateway.md) (the public request path),
[14-promotion-procedure.md](14-promotion-procedure.md) (how the artifact arrives)
and [03-security-baseline.md](03-security-baseline.md) (what is enforced).

---

## 0. The rule this document exists to enforce

> **Network reachability is not authorisation.**
> A VPN answers "is this packet allowed on the network?". It does not answer
> "is this person allowed in this application?". Every private service still
> needs authentication and authorisation at the gateway — the VPN only shrinks
> who can attempt it.

The failure this prevents is the flat internal network: one VPN credential, and
every internal app is browsable. In a bank that is not a hypothetical finding,
it is the finding.

So a private service gets **both**:

```
[ VPN / private network path ]   ← can you reach the address at all?
              +
[ OIDC at the gateway ]          ← who are you, and are you entitled to THIS app?
              +
[ NetworkPolicy / firewall ]     ← can this workload be reached by anything else?
```

---

## 1. Choose the access model first

Do this before any DNS or certificate work — it determines everything after.

| # | Model | Reachable from | Use when | Cost |
|---|---|---|---|---|
| **A** | **Internal-only, corporate network / VPN** | Office LAN + VPN clients | Internal tooling, admin UIs, back-office apps | VPN fleet, client rollout, split-DNS |
| **B** | **Internal-only + OIDC at the gateway** | Same as A, but authenticated per app | **Default for internal apps** | A + a Keycloak client per app |
| **C** | **Identity-aware proxy, public listener** | Anywhere, after SSO + device posture | Third-party/contractor access, no VPN client possible | Public edge exposure, stronger IdP requirements |
| **D** | **Private link / peering** | A named partner network only | B2B partner integrations | Per-partner network engineering |
| **E** | **Bastion / jump host only** | Management zone via PAM | Infrastructure consoles, break-glass | Session recording, MFA, approval workflow |

**Default for this platform:** **B** for internal applications, **E** for
anything that manages the platform itself (Vault UI, ArgoCD, Grafana admin,
Kubernetes dashboards). **C** only with a documented decision — it moves the
service back into the public blast radius, and the whole point of a private
deployment was to leave it.

> **Say the quiet part in the design review:** model A alone means anyone with a
> VPN session reaches the app. That is acceptable for a canteen menu and not for
> a reconciliation console. If someone proposes A for a system holding customer
> data, the answer is B.

---

## 2. Naming and DNS plan

### 2.1 Zone layout

One private zone per environment, never shared with the public zone:

```
app.bank.internal            ← internal applications (this document)
  *.dev.app.bank.internal
  *.stg.app.bank.internal
  *.prod.app.bank.internal
mgmt.bank.internal           ← platform/management consoles (bastion only)
bank.com                     ← public zone, separate authority, separate certs
```

Rules:

| Rule | Why |
|---|---|
| Private names resolve **only** on internal resolvers (split-horizon) | A public NXDOMAIN is fine; a public A record pointing at RFC1918 leaks your topology and shows up in passive-DNS datasets |
| Never publish an internal name in public DNS "for convenience with ACME" | Use DNS-01 on a **delegated** validation zone (§3.3), not by publishing the host record |
| One name per service per environment, no reuse across environments | `payments.prod.app.bank.internal` is unambiguous in a log at 03:00; `payments.app.bank.internal` is not |
| Wildcard **DNS** record for the ingress VIP is fine; wildcard **TLS** is a separate decision (§3) | They are routinely conflated and they have very different blast radii |

### 2.2 The wildcard DNS record

One record per environment, pointing at that environment's **internal** ingress
VIP. New services then need no DNS change at all — which is the point, and also
the risk (§2.3).

```
; internal zone: prod.app.bank.internal
@                 IN  NS    ns1.bank.internal.
*.prod.app        IN  A     10.30.10.20        ; internal ingress VIP (no public route)
```

Terraform, so it is reviewed rather than typed into a DNS console:

```hcl
resource "dns_a_record_set" "internal_ingress_wildcard" {
  zone      = "prod.app.bank.internal."
  name      = "*"
  addresses = [module.network.internal_ingress_vip]
  ttl       = 300
}
```

### 2.3 What the wildcard record costs you

A wildcard A record means **every** name under it resolves, including names
nobody created. Consequences to design around:

- A typo (`paymnets.prod.app.bank.internal`) resolves and reaches the ingress
  instead of failing fast at DNS. Mitigate with a **default server that returns
  444/404** for unmatched hosts (see [13-edge-gateway.md](13-edge-gateway.md)) —
  never a default backend that serves a real app.
- Host-header routing becomes the only thing separating services. That is fine
  when the ingress config is in Git and reviewed; it is not fine when people can
  create Ingress objects with arbitrary hosts. Enforce with a Kyverno policy that
  restricts each namespace to its own host suffix (§5.4).
- Certificate scope: see next section.

---

## 3. TLS: wildcard certificate or per-service?

### 3.1 Decide with this table

| | Wildcard cert (`*.prod.app.bank.internal`) | Per-service cert (`payments.prod.app...`) |
|---|---|---|
| New service onboarding | Zero cert work | Automated, but a real object per service |
| Private key blast radius | **One key impersonates every internal app** | One key, one service |
| Revocation | Rotating it touches every service at once | Contained |
| Rotation cadence achievable | Manual-ish, 90d–1y | Automated, 24h–90d |
| Audit answer to "which service holds which key" | "All of them" | A one-to-one inventory |
| Right for | The **edge/ingress listener** in one place, under one team | **Everything behind the ingress** |

**This platform's position:** per-service, short-lived certificates from the
Vault PKI mount via cert-manager, for both ingress listeners and pod-to-pod
mTLS. A wildcard is permitted **only** where an automated per-name issue is
genuinely impossible — a legacy appliance, or a third-party product that accepts
one static cert — and then it is a documented exception with an owner and an
expiry, stored in Vault, never in Git, and never mounted into more than the one
workload that needs it.

> The argument you will hear is "a wildcard is simpler". It is — right up to the
> incident where one compromised internal app's key can impersonate the SSO
> callback host, the admin console and the payment API. Then it is the single
> worst decision in the estate.

### 3.2 Per-service certificate (the default path)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: payments-tls
  namespace: app-payment
spec:
  secretName: payments-tls
  duration: 24h                     # short-lived: rotation is continuous, not an event
  renewBefore: 8h
  privateKey: { algorithm: ECDSA, size: 256, rotationPolicy: Always }
  issuerRef: { name: vault-internal-ca, kind: ClusterIssuer }
  commonName: payments.prod.app.bank.internal
  dnsNames: ["payments.prod.app.bank.internal"]
```

`rotationPolicy: Always` matters — without it cert-manager reuses the same
private key forever and you have short-lived *certificates* wrapped around a
long-lived *key*, which is most of the risk you were trying to remove.

### 3.3 Wildcard certificate, if the exception is granted

Public CA + DNS-01 on a **delegated validation zone**, so the ACME credential
can only write TXT records in one place and cannot touch your real zones:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: wildcard-internal, namespace: ingress-internal }
spec:
  secretName: wildcard-internal-tls
  issuerRef: { name: acme-dns01, kind: ClusterIssuer }
  commonName: "*.prod.app.bank.internal"
  dnsNames: ["*.prod.app.bank.internal", "prod.app.bank.internal"]
```

Constraints that must accompany a wildcard:

- Lives in the **ingress namespace only**. No application namespace mounts it.
- `*.example` matches one label — `a.prod.app…` yes, `a.b.prod.app…` no. Plan
  the hierarchy or you will be issuing two wildcards, which doubles the problem.
- A public wildcard for an internal name appears in **Certificate Transparency
  logs**, publishing your internal naming scheme to the world. For internal-only
  names this is usually the deciding argument for using the internal Vault PKI
  instead of a public CA _(regulated)_.
- Rotation is a scheduled, rehearsed change with a rollback, because it is a
  simultaneous change to every service.

---

## 4. The VPN track

### 4.1 Topology

```
laptop (managed device)
   │ WireGuard / IPsec, always-on, SSO-authenticated
   ▼
[ VPN concentrator ]  ── DMZ, HA pair, its own public IP, nothing else on it
   │  pushes: routes for 10.30.0.0/16 only, internal DNS servers
   │  enforces: SSO + MFA, device posture, per-group route sets
   ▼
[ Internal ingress VIP 10.30.10.20 ]  ← app zone entry point
   │  still terminates TLS, still requires OIDC per app
   ▼
services
```

### 4.2 Configuration rules

| Rule | Why |
|---|---|
| **Split tunnel** — push only internal CIDRs | Full tunnel sends personal traffic through the corporate egress: a privacy problem, a bandwidth bill, and an incident-response distraction. _(regulated)_ If policy mandates full tunnel for managed devices, say so explicitly and size the egress for it |
| Push **internal DNS servers** with the tunnel | Split-horizon names must not resolve on a coffee-shop resolver. This is the #1 "VPN is connected but the app doesn't work" cause |
| Authenticate with **SSO + MFA**, not a shared key | A shared VPN key cannot be attributed, cannot be revoked per person, and never gets rotated |
| **Per-group route sets** | Finance does not need routes to the Kubernetes API. Route sets are the cheapest segmentation you own |
| Device posture check (disk encryption, EDR, patch level) | A VPN into the app zone from an unmanaged laptop is a bridge, not a control |
| Certificates/keys issued per device, short TTL, auto-renew | An offboarded laptop must lose access without a human remembering |
| Concentrator does **nothing else** | It is internet-facing. It carries no app, no database, no shared credential |
| Log every session (user, device, source IP, duration) to the SIEM | This is the evidence for "who could have reached that system on the 14th" |

### 4.3 Client config (WireGuard example)

```ini
[Interface]
PrivateKey = <device key, issued per device, never shared>
Address    = 10.90.4.17/32
DNS        = 10.30.0.10, 10.30.0.11      # internal resolvers — required for split-horizon

[Peer]
PublicKey  = <concentrator key>
Endpoint   = vpn.bank.com:51820
AllowedIPs = 10.30.0.0/16, 10.40.0.0/16  # split tunnel: app + data zones only.
                                          # NOT 0.0.0.0/0, and NOT the mgmt zone
PersistentKeepalive = 25
```

Management-zone access (`10.99.0.0/16`) is deliberately absent: that path is the
bastion with PAM, MFA and session recording, per
[01-architecture.md](01-architecture.md) §Management zone.

### 4.4 VPN is not the only answer

An identity-aware proxy (model C) — a public listener that requires SSO, MFA and
device posture before any traffic reaches the app — is often better for
contractors and for BYOD, because there is no client to install and no network
route to grant. The trade-off is honest: you have moved the service back onto a
public listener, so the edge controls in
[13-edge-gateway.md](13-edge-gateway.md) become load-bearing. Choose it
deliberately, per service, not as a blanket replacement.

---

## 5. The deployment procedure

Assumes the artifact has already been promoted per
[14-promotion-procedure.md](14-promotion-procedure.md) — this section adds only
what makes it *private*.

### 5.0 Pre-flight (before writing any manifest)

- [ ] Access model chosen from §1 and recorded in the service's entry in the
      catalogue (A/B/C/D/E)
- [ ] Data classification known — it drives whether model A is permissible at all
- [ ] Owning team and an approver group identified (this becomes the Keycloak
      group and the access-review subject)
- [ ] Hostname agreed: `<service>.<env>.app.bank.internal`
- [ ] Decision recorded: per-service certificate (default) or wildcard exception
      with expiry

### 5.1 A separate internal ingress controller

Do not put private services on the public ingress and rely on a NetworkPolicy to
save you. Use a second controller, with its own class and an **internal** load
balancer. One misconfigured annotation should not be able to publish an internal
app.

```yaml
# gitops/platform/ingress-internal/values.yaml
controller:
  ingressClassResource: { name: ingress-internal, default: false }
  ingressClass: ingress-internal
  service:
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-scheme: internal   # or the
      # equivalent for your provider / MetalLB address pool
    loadBalancerIP: 10.30.10.20
  allowSnippetAnnotations: false        # see 13-edge-gateway.md
  config:
    hsts: "true"
    ssl-redirect: "true"
```

Verify the LB really is internal before anything is deployed behind it:

```bash
kubectl -n ingress-internal get svc ingress-internal-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'   # must be RFC1918
# and from outside the perimeter, this must NOT connect:
curl -m 5 https://10.30.10.20/   # expected: timeout / no route
```

### 5.2 The Ingress (or HTTPRoute)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: payments
  namespace: app-payment
  annotations:
    cert-manager.io/cluster-issuer: vault-internal-ca
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"   # re-encrypt to the pod
    nginx.ingress.kubernetes.io/whitelist-source-range: "10.90.0.0/16,10.20.0.0/16"
    #                                        VPN pool ─┘          office LAN ─┘
spec:
  ingressClassName: ingress-internal          # ← not the public class
  tls:
    - hosts: [payments.prod.app.bank.internal]
      secretName: payments-tls
  rules:
    - host: payments.prod.app.bank.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: payments, port: { number: 8443 } } }
```

`whitelist-source-range` is defence in depth, not the control — it depends on
`real_ip` being configured correctly for the internal LB, and it is a *network*
statement about a *person* problem. The control is §5.3.

### 5.3 Authentication at the gateway (model B — the default)

Authentication belongs at the API gateway and **nowhere else**
([13-edge-gateway.md](13-edge-gateway.md) §1). For a private web app that means
an OIDC flow against Keycloak before any request reaches the service.

```yaml
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata: { name: payments-oidc, namespace: app-payment }
plugin: openid-connect
config:
  issuer: https://sso.bank.internal/realms/internal/.well-known/openid-configuration
  client_id: payments-console
  client_secret: null            # from Vault via ESO — never inline
  scopes: ["openid", "profile"]
  audience_required: ["payments-console"]
  groups_claim: ["groups"]
  groups_required: ["payments-operators"]     # ← entitlement to THIS app
  verify_signature: true
  ssl_verify: true
```

Non-negotiables:
- Exact redirect URIs on the Keycloak client — **no wildcards**
  ([04-platform-services.md](04-platform-services.md) §Keycloak).
- An explicit algorithm allowlist; reject `none`.
- `groups_required` (or an equivalent claim check) — otherwise every SSO user in
  the company is authorised, which is model A wearing a badge.
- The client secret comes from Vault via External Secrets; it is never in Git.

For non-browser callers (jobs, scripts, partner systems) use client credentials
or mTLS with a Kong consumer, not a shared human account.

### 5.4 Lock the host suffix per namespace

With a wildcard DNS record, host-header routing is the boundary. Make it
enforceable rather than conventional:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: { name: restrict-ingress-hosts }
spec:
  validationFailureAction: Enforce
  rules:
    - name: host-must-match-namespace-suffix
      match: { any: [{ resources: { kinds: ["Ingress"] } }] }
      validate:
        message: "Ingress host must end with the namespace's allotted suffix"
        foreach:
          - list: "request.object.spec.rules"
            deny:
              conditions:
                any:
                  - key: "{{ element.host }}"
                    operator: NotEquals
                    value: "?*.{{ request.namespace }}.prod.app.bank.internal"
```

Pair it with a policy that forbids `ingressClassName: nginx` (the public class)
in application namespaces that are marked internal-only.

### 5.5 Network policy — default deny, both directions

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: payments-allow, namespace: app-payment }
spec:
  podSelector: { matchLabels: { app: payments } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: platform-kong }
      ports: [{ port: 8443, protocol: TCP }]
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
          podSelector: { matchLabels: { k8s-app: kube-dns } }
      ports: [{ port: 53, protocol: UDP }, { port: 53, protocol: TCP }]
    - to: [{ podSelector: { matchLabels: { app: postgres } } }]
      ports: [{ port: 5432, protocol: TCP }]
```

Note the ingress rule names the **gateway namespace only**. Nothing else in the
cluster can reach the service directly and skip the OIDC check — which is what
makes "authentication lives at the gateway" a true statement rather than an
aspiration.

### 5.6 Firewall / zone rules (VM track and cluster edges)

```hcl
# infra/terraform/modules/network — one justified exception per rule
rule {
  name        = "vpn-to-internal-ingress"
  source      = var.vpn_pool_cidr        # 10.90.0.0/16
  destination = var.internal_ingress_vip
  ports       = [443]
  reason      = "Private app access per docs/16-private-access-deployment.md §5.6"
}
```

Every rule carries a `reason` referencing a document. A firewall rule whose
justification nobody can name is a rule nobody dares delete.

### 5.7 VM-track equivalent

Same shape, different mechanism — an internal NGINX vhost rendered by Ansible:

```yaml
- name: Render internal vhost
  ansible.builtin.template:
    src: internal-site.conf.j2
    dest: /etc/nginx/conf.d/payments-internal.conf
    mode: "0644"
    validate: "nginx -t -c %s"
  notify: reload nginx
```
```nginx
server {
    listen 10.30.10.20:443 ssl;          # bind the internal address explicitly
    http2 on;
    server_name payments.prod.app.bank.internal;

    ssl_certificate     /etc/nginx/tls/payments.crt;   # vault-agent renders these
    ssl_certificate_key /run/nginx/tls/payments.key;   # key on tmpfs

    allow 10.90.0.0/16;   # VPN pool
    allow 10.20.0.0/16;   # office
    deny  all;

    auth_request /_oidc;                  # or proxy through the gateway
    location / { proxy_pass https://127.0.0.1:8443; }
}
server { listen 443 default_server; return 444; }   # unmatched host: drop
```

Binding to the internal address rather than `0.0.0.0` means a firewall mistake
alone is not sufficient to expose the service.

---

## 6. Verification — test from every position, not just yours

Deployment is not done until each row has been executed and recorded. "It works
from my laptop on the VPN" verifies one cell of this table.

| From | Expected | Command |
|---|---|---|
| Public internet | **No DNS answer**, no route | `dig payments.prod.app.bank.internal @1.1.1.1` → NXDOMAIN/REFUSED |
| Public internet | **No TCP** to the VIP | `nc -vz -w5 10.30.10.20 443` → timeout |
| VPN, unauthenticated | Redirect to SSO, never the app | `curl -sI https://payments.prod.app.bank.internal/` → 302 to `sso.bank.internal` |
| VPN, authenticated, **not** in the group | **403**, and an audit log entry | Browser with a test account outside `payments-operators` |
| VPN, authenticated, in the group | 200 | Browser |
| Office LAN, authorised user | 200 | Browser |
| Inside the cluster, from another namespace | **Blocked by NetworkPolicy** | `kubectl -n other run t --rm -it --image=curlimages/curl -- curl -m5 https://payments.app-payment.svc:8443/` → timeout |
| Inside the cluster, from the gateway namespace | 200 | same, from `platform-kong` |
| Wrong hostname on the wildcard | **444/404 from the default server**, not another app | `curl -k -H 'Host: typo.prod.app.bank.internal' https://10.30.10.20/` |
| Certificate | Correct SAN, short expiry, chains to the internal CA | `openssl s_client -connect 10.30.10.20:443 -servername payments.prod.app.bank.internal </dev/null \| openssl x509 -noout -dates -ext subjectAltName` |

Automate the first two and the NetworkPolicy row as a recurring job — they are
the ones that silently regress when someone "temporarily" changes an annotation.

---

## 7. Failure modes you will actually hit

| Symptom | Cause | Fix |
|---|---|---|
| "VPN is connected but the app doesn't resolve" | Client kept its local DNS; split-horizon names don't exist there | Push internal resolvers with the tunnel; verify with `nslookup … <internal-ns>` |
| Resolves on VPN, not on the office LAN (or vice versa) | Two resolver estates, one zone updated | One authoritative internal zone, both estates forward to it |
| A typo'd hostname serves a different application | Wildcard DNS + a default backend that serves a real app | Default server returns 444/404; Kyverno host-suffix policy (§5.4) |
| Certificate valid but browser complains | Wildcard covers one label only; `a.b.env.app…` isn't matched | Per-service certs, or fix the name hierarchy |
| Works for the deploying engineer, 403 for everyone else | Group claim missing or `groups_required` wrong | Check the token's claims directly; fix the Keycloak client mapper |
| Everyone with a VPN session can open the app | Model A shipped where B was intended | Add the OIDC plugin and a `groups_required` — this is a security finding, treat it as one |
| Service unreachable after a NetworkPolicy is applied | DNS egress not allowed | Add the 53/UDP+TCP kube-dns rule ([02-kubernetes cheat sheet](../cheatsheets/02-kubernetes/README.md) §5) |
| Internal LB got a public IP after a Helm upgrade | Scheme annotation dropped or renamed between chart versions | Assert RFC1918 in a post-deploy check; alert on it continuously |
| Cert renewed but the app still serves the old one | App doesn't reload on secret change | `rollout restart`, or a sidecar/reloader watching the secret |
| Offboarded employee still has access | Device key or VPN profile not tied to the IdP lifecycle | Short-lived, IdP-issued device certs; §8 |

---

## 8. Access lifecycle _(regulated)_

Private access is a *grant*, and grants rot. The procedure is incomplete without
the exit path.

| Event | Required action | Owner |
|---|---|---|
| New joiner | Group membership in the IdP; VPN profile issued per device with short TTL | Manager + IT |
| Role change | Group membership updated; access re-derived, not accumulated | Manager |
| Leaver | IdP account disabled → VPN and every app follow automatically | HR-triggered |
| Contractor | Time-boxed group membership with an automatic expiry date | Sponsor |
| Quarterly | Access review: every group's membership confirmed by the owning team | Service owner |
| Break-glass | Time-boxed elevation, MFA, second approver, pages the security channel, reviewed after use | On-call |

The design property that makes this work: **the IdP is the single lifecycle
point**. If disabling an account in Keycloak does not remove VPN access and app
access, you have two identity systems and one of them will be wrong.

Evidence to retain: VPN session logs (user, device, source IP, duration), gateway
access logs with the authenticated subject, IdP authentication events, and the
signed-off quarterly review — all shipped to the SIEM on an append-only path
([09-devsecops cheat sheet](../cheatsheets/09-devsecops/README.md) §9).

---

## 9. Rollback

| What went wrong | Rollback |
|---|---|
| App broken after deploy | `git revert` the digest commit — unchanged from [14-promotion-procedure.md](14-promotion-procedure.md) |
| Exposure mistake (public LB, wrong ingress class) | **Scale the Ingress out of existence first** (`kubectl delete ingress` or revert the manifest), then fix. Removing exposure precedes diagnosis |
| Certificate rotation broke clients | Previous secret is still in the cluster until pruned — revert the Certificate spec and `rollout restart`; for a wildcard, this is why the change needed a rehearsed window |
| OIDC misconfiguration locks everyone out | Break-glass path (§8) — never "temporarily disable auth". Fix the client config with the elevated session |
| VPN change breaks connectivity for the fleet | Concentrator config is in Git; revert and reload. Keep one out-of-band admin path that does not depend on the VPN you just broke |

The last row is the one people learn the hard way: if the only way to fix the
VPN is through the VPN, your rollback plan does not exist.

---

## 10. Checklist

**Design**
- [ ] Access model (A–E) chosen, recorded, and justified against the data classification
- [ ] Hostname follows `<service>.<env>.app.bank.internal`
- [ ] Per-service certificate chosen — or a wildcard exception with an owner and expiry

**DNS & TLS**
- [ ] Internal zone is split-horizon; no internal name in public DNS
- [ ] Wildcard A record points at the **internal** ingress VIP, managed in Terraform
- [ ] Certificates issued by Vault PKI via cert-manager, short TTL, `rotationPolicy: Always`
- [ ] Unmatched hosts hit a default server that returns 444/404

**Exposure**
- [ ] Deployed on the internal ingress class, behind an LB with an RFC1918 address
- [ ] Kyverno restricts ingress hosts per namespace and forbids the public class
- [ ] Default-deny NetworkPolicy; only the gateway namespace may reach the service
- [ ] Firewall rules carry a `reason` referencing this document

**Identity**
- [ ] OIDC enforced at the gateway with an explicit group/entitlement requirement
- [ ] Exact redirect URIs, no wildcards; algorithm allowlist explicit
- [ ] Client secret from Vault via ESO, never in Git
- [ ] Non-human callers use client credentials or mTLS, not a shared account

**VPN**
- [ ] SSO + MFA, per-device short-lived keys, device posture checked
- [ ] Split tunnel with internal DNS pushed; management zone **not** routed
- [ ] Per-group route sets; sessions logged to the SIEM

**Proof**
- [ ] Every row of the §6 verification table executed and recorded
- [ ] External-reachability and NetworkPolicy checks run continuously, not once
- [ ] Rollback for exposure mistakes documented and tested
- [ ] Access review scheduled; leaver path verified end to end
