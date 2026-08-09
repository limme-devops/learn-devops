# VPN & Private Access Cheat Sheet

> **Author:** Mengty LIM

WireGuard, IPsec, split tunnel, split-horizon DNS, bastions, identity-aware
proxies, and private access to Kubernetes.

Procedure this compresses:
[docs/16-private-access-deployment.md](../../docs/16-private-access-deployment.md).

---

## 1. The one rule

> **Network reachability is not authorisation.**
> A VPN answers "may this packet reach the address?". It never answers "may this
> person use this application?". Private services need both — the VPN shrinks
> who can attempt, the gateway decides who succeeds.

The failure this prevents: a flat internal network where one VPN credential
browses every back-office system. Every private app therefore gets a network
path **and** OIDC at the gateway **and** default-deny NetworkPolicy.

---

## 2. Choosing an access model

| # | Model | Reachable from | Use for | Watch out for |
|---|---|---|---|---|
| A | Site VPN / client VPN only | Office + VPN clients | Low-sensitivity internal tooling | Reachability ≠ authorisation |
| B | **VPN + OIDC per app** | Same, but authenticated & entitled | **Default for internal apps** | Group claim must actually be checked |
| C | Identity-aware proxy (public listener, SSO + device posture) | Anywhere | Contractors, BYOD, no client to install | You are back on a public listener |
| D | Private link / VPC peering / MPLS | One named partner network | B2B integrations | Route overlap, no identity by itself |
| E | Bastion / PAM jump host | Management zone | Platform consoles, break-glass | Session recording + MFA are the point |
| F | Mesh VPN (Tailscale/Netbird/ZeroTier, WireGuard + coordination) | Enrolled devices | Small teams, labs, multi-cloud | Control plane is a third party _(regulated: usually self-hosted headscale/Netbird or nothing)_ |

**Zero-trust framing** (useful in interviews): stop treating "inside the network"
as a trust signal. Every request is authenticated (who), authorised (entitled to
*this* resource), and evaluated against device state — regardless of where it
came from. A VPN then becomes a network-hygiene tool, not a security boundary.

---

## 3. WireGuard

### Server (concentrator)

```ini
# /etc/wireguard/wg0.conf
[Interface]
Address    = 10.90.0.1/16
ListenPort = 51820
PrivateKey = <server key>            # from Vault, mode 0600, never in Git
MTU        = 1420
PostUp     = nft add rule inet filter forward iifname wg0 oifname eth0 accept
PostDown   = nft delete rule inet filter forward handle $HANDLE

[Peer]                                # one block per DEVICE, not per person
PublicKey           = <device pubkey>
AllowedIPs          = 10.90.4.17/32   # server side: this is a ROUTE + an ACL
PersistentKeepalive = 25
```

### Client

```ini
[Interface]
PrivateKey = <device key>
Address    = 10.90.4.17/32
DNS        = 10.30.0.10, 10.30.0.11   # internal resolvers — required for split-horizon

[Peer]
PublicKey  = <server pubkey>
Endpoint   = vpn.bank.com:51820
AllowedIPs = 10.30.0.0/16, 10.40.0.0/16   # split tunnel: app + data zones only
                                          # NOT 0.0.0.0/0, NOT the mgmt zone
PersistentKeepalive = 25
```

**`AllowedIPs` is the concept people get wrong.** It is two things at once:
outbound it is a *route* (send this traffic into the tunnel); inbound it is a
*filter* (accept packets from this peer only if the source is in that range).
`0.0.0.0/0` on a client means full tunnel; on a server peer block it means "this
peer may impersonate any source address" — almost never what you want.

```bash
wg-quick up wg0 ; wg-quick down wg0
systemctl enable --now wg-quick@wg0
wg show                        # handshakes, transfer, endpoints
wg show wg0 latest-handshakes  # >180s stale = peer is gone
wg genkey | tee priv | wg pubkey > pub
wg set wg0 peer <pub> allowed-ips 10.90.4.18/32   # add a peer without a restart
```

Why WireGuard is usually the right default: ~4k lines of kernel code (auditable),
modern crypto with no negotiation (no downgrade attacks), fast handshakes and
seamless roaming, stateless-ish design. What it doesn't give you: user identity,
MFA, device posture, or key lifecycle — you bolt those on (§4).

---

## 4. Making the VPN identity-aware

Raw WireGuard has no users, only keys. Production requirements:

| Requirement | Implementation |
|---|---|
| SSO + MFA at connect | IdP-integrated client (IPsec/IKEv2 with EAP, or a mesh VPN with OIDC enrolment), or an enrolment service that issues short-lived WireGuard keys after an OIDC flow |
| One key per **device**, not per person | Revoke a stolen laptop without disrupting the human |
| Short TTL, auto-renew | An offboarded device loses access without anyone remembering |
| Device posture (disk encryption, EDR, patch level) | MDM attestation checked at enrolment/renewal |
| Per-group route sets | Finance gets no route to the Kubernetes API. Cheapest segmentation you own |
| Session logging to the SIEM | user, device, source IP, duration — the evidence for "who could reach X on the 14th" |
| Concentrator runs nothing else | It is internet-facing. No app, no DB, no shared credential |

**Lifecycle rule:** the IdP is the single lifecycle point. If disabling an
account in Keycloak doesn't remove VPN *and* app access, you have two identity
systems and one of them is wrong.

### IPsec/IKEv2 quick reference (when the enterprise mandates it)

```
IKE_SA_INIT ──► negotiate DH, nonces
IKE_AUTH    ──► authenticate (cert or EAP/SSO), create first CHILD_SA
CHILD_SA    ──► the actual ESP tunnel (rekeyed on a timer)
```
```bash
swanctl --list-sas          # active tunnels (strongSwan)
swanctl --initiate --child net-net
ipsec statusall
```
IKEv2 wins on native OS clients (Windows/macOS/iOS have built-in support with
MFA via EAP) and on interop with appliances. It loses on complexity: proposal
mismatches are the classic failure, and both ends must agree on encryption,
integrity, DH group *and* traffic selectors.

---

## 5. Split tunnel, DNS, and the routing table

### Split vs full tunnel

| | Split tunnel | Full tunnel |
|---|---|---|
| Routes pushed | Internal CIDRs only | `0.0.0.0/0` |
| Privacy | Personal traffic stays personal | All browsing traverses corporate egress |
| Bandwidth | Minimal | Size the concentrator + egress for the whole fleet |
| Security argument | Endpoint controls (EDR) protect the device | Corporate DLP/proxy inspects everything |

Default here is **split tunnel with internal DNS pushed**. If policy mandates
full tunnel for managed devices _(regulated — DLP and egress inspection are the
usual drivers)_, say so explicitly and size for it rather than discovering it at
09:00 on a Monday.

### Split-horizon DNS — the #1 "VPN connected but nothing works" cause

Internal names must resolve **only** on internal resolvers. So the tunnel must
push those resolvers, and the client must actually use them.

```bash
# what am I actually resolving with?
resolvectl status                     # systemd-resolved: per-link DNS + domains
resolvectl domain wg0 ~app.bank.internal   # route only this suffix to the tunnel
scutil --dns                          # macOS
Get-DnsClientNrptPolicy               # Windows NRPT

dig payments.prod.app.bank.internal @10.30.0.10   # internal resolver: expect an A
dig payments.prod.app.bank.internal @1.1.1.1      # public: expect NXDOMAIN/REFUSED
```

Rules:
- Never publish an internal name in public DNS "so ACME works" — delegate a
  validation subzone for DNS-01 instead.
- One authoritative internal zone; office resolvers and VPN-pushed resolvers
  both forward to it. Two half-updated resolver estates is a permanent bug factory.
- Split-DNS by suffix (`~app.bank.internal`) beats "all DNS through the tunnel"
  on a split tunnel — it keeps personal lookups off the corporate resolver.

### Routing checks

```bash
ip route get 10.30.10.20              # which interface will this take?
ip -4 route show table all | grep wg0
ip rule show                          # policy routing (fwmark from wg-quick)
mtr -n 10.30.10.20                    # where does it die
ss -tnp state established '( dport = :443 )'
```

**Overlapping RFC1918 ranges** are the recurring real-world problem: the
customer site, the home router and the cloud VPC all use `192.168.1.0/24`. Fix
by planning non-overlapping space up front, or NAT at the tunnel edge — never by
hoping.

---

## 6. Firewalling the private path

```bash
# nftables: only the VPN pool and office may reach the internal ingress VIP
nft add rule inet filter forward ip saddr 10.90.0.0/16 ip daddr 10.30.10.20 tcp dport 443 accept
nft add rule inet filter forward ip saddr 10.90.0.0/16 ip daddr 10.99.0.0/16 drop  # no mgmt zone
nft list ruleset | less

# verify from the wrong side — this must FAIL
nc -vz -w5 10.30.10.20 443
```

Every rule carries a written reason referencing a document. A firewall rule
nobody can justify is a rule nobody dares delete, and the estate silently becomes
allow-all over five years.

Kubernetes side (defence in depth, not the control):

```yaml
# only the gateway namespace may reach the workload
ingress:
  - from: [{ namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: platform-kong } } }]
    ports: [{ port: 8443, protocol: TCP }]
```

---

## 7. Bastion / SSH access (model E)

```
# ~/.ssh/config
Host bastion
  HostName bastion.prod.bank.internal
  User ansible
  IdentityFile ~/.ssh/id_ed25519-sk        # hardware-backed key
Host 10.30.*
  ProxyJump bastion                        # never ProxyCommand+nc in 2020s
  StrictHostKeyChecking yes
```

```bash
ssh -J bastion app-01.prod.bank.internal
ssh -L 8443:payments.prod.app.bank.internal:443 bastion   # local forward
ssh -D 1080 bastion                                        # SOCKS proxy
```

Bastion hardening: key-only (ideally SSH **certificates** with a short TTL from
Vault, so there is no `authorized_keys` file to drift), MFA, `AllowGroups`,
session recording, no agent forwarding (use `ProxyJump`, which doesn't expose
your agent to the jump host), and the bastion in the management zone reachable
only from the VPN or an admin range.

```bash
vault write -field=signed_key ssh-client-signer/sign/admin \
  public_key=@$HOME/.ssh/id_ed25519.pub > ~/.ssh/id_ed25519-cert.pub   # 8h TTL
```

---

## 8. Private access to Kubernetes

| Need | Do | Don't |
|---|---|---|
| `kubectl` from a laptop | Private API endpoint + VPN + OIDC auth (`kubectl oidc-login`) | Public API server with a token in `~/.kube/config` |
| Reach one internal service ad hoc | `kubectl port-forward` (audited via the API server's audit log) | Expose a NodePort "temporarily" |
| Expose internal web apps | Second ingress controller, internal LB class, per-app OIDC | Public ingress + `whitelist-source-range` as the only control |
| Debug a pod's network | `kubectl debug --image=netshoot --target=api` | Adding a shell to the prod image |

```bash
kubectl port-forward -n app-payment svc/payments 8443:8443
kubectl get svc -A -o json | jq -r '.items[]
  | select(.spec.type=="LoadBalancer")
  | "\(.metadata.namespace)/\(.metadata.name)\t\(.status.loadBalancer.ingress[0].ip)"'
  # ↑ run this on a schedule: any public IP here should be a deliberate decision
```

Continuous check worth automating: assert every internal LoadBalancer address is
RFC1918, and alert if one becomes public. Chart upgrades silently rename scheme
annotations more often than you'd like.

---

## 9. Certificates for private names

- **Per-service, short-lived, from the internal CA (Vault PKI via cert-manager)**
  is the default. A wildcard private key that can impersonate every internal app
  is the worst single artifact in an estate.
- Wildcard is an *exception* with an owner and expiry: ingress namespace only,
  never mounted by an app, rotated in a rehearsed window.
- `*.example.com` matches **one** label — `a.env.app…` yes, `a.b.env.app…` no.
- A **public** wildcard for internal names publishes your naming scheme to
  Certificate Transparency logs. For internal-only names, that alone usually
  decides it in favour of the internal CA _(regulated)_.

```bash
openssl s_client -connect 10.30.10.20:443 \
  -servername payments.prod.app.bank.internal </dev/null 2>/dev/null \
  | openssl x509 -noout -dates -issuer -ext subjectAltName
```

---

## 10. Verification matrix — test from every position

"It works from my laptop on the VPN" verifies one cell.

| From | Expected |
|---|---|
| Public internet, DNS | NXDOMAIN / REFUSED |
| Public internet, TCP to the VIP | timeout, no route |
| VPN, unauthenticated | 302 to SSO — never the app |
| VPN, authenticated, **not** in the group | 403 + an audit log entry |
| VPN, authenticated, entitled | 200 |
| Wrong hostname on the wildcard | 444/404 from the default server, **not** another app |
| Other cluster namespace | blocked by NetworkPolicy |
| Gateway namespace | 200 |
| Certificate | correct SAN, short expiry, internal CA chain |

Automate the two public rows and the NetworkPolicy row as a recurring job — they
are the ones that silently regress when someone "temporarily" changes an
annotation.

---

## 11. Troubleshooting table

| Symptom | Likely cause | Check |
|---|---|---|
| Handshake never completes | UDP blocked, wrong port, NAT, clock skew | `wg show latest-handshakes`, `tcpdump -ni any udp port 51820` |
| Handshake OK, no traffic | `AllowedIPs` doesn't cover the destination | `ip route get <dst>`, compare to `AllowedIPs` |
| Connects, drops after ~2 min | No `PersistentKeepalive` behind NAT | Set 25s on the client |
| Small requests fine, large ones hang | **MTU / PMTU black hole** | Lower to 1420 (or 1280); `ping -M do -s 1392` to bisect; clamp MSS |
| Names don't resolve | Internal resolvers not pushed, or client kept its own | `resolvectl status`, `scutil --dns` |
| Resolves on VPN, not in the office | Two resolver estates, one updated | Single authoritative internal zone |
| Some sites break while connected | Route/CIDR overlap with home LAN | Re-plan address space, or NAT at the edge |
| Everyone with a VPN session can open the app | Model A shipped where B was intended | Add OIDC + a group requirement. This is a security finding |
| App unreachable after NetworkPolicy | DNS egress (53/UDP+TCP) not allowed | Add the kube-dns rule |
| Internal LB got a public IP | Scheme annotation dropped in a chart upgrade | Assert RFC1918 continuously |
| Offboarded employee still connects | Device key not tied to the IdP lifecycle | Short-lived IdP-issued keys |
| Fixed the VPN config, now nobody can connect (including you) | No out-of-band admin path | Console/bastion access that doesn't depend on the VPN |

That last row is the one people learn the hard way: **if the only way to fix the
VPN is through the VPN, your rollback plan does not exist.**

---

## 12. Best practices checklist

- [ ] Access model (A–F) chosen per service and recorded, justified against data classification
- [ ] OIDC at the gateway with an explicit group/entitlement check — reachability is never the authorisation
- [ ] Exact redirect URIs (no wildcards); algorithm allowlist explicit; client secret from Vault
- [ ] Split tunnel with internal resolvers pushed; management zone **not** routed
- [ ] One key per device, short TTL, IdP-driven issue and revoke; MFA at connect
- [ ] Device posture checked at enrolment and renewal
- [ ] Per-group route sets; concentrator runs nothing else and is HA
- [ ] Internal names split-horizon only; nothing internal in public DNS
- [ ] Per-service short-lived certs from the internal CA; wildcard only as an expiring exception
- [ ] Internal ingress is a **separate** controller with an RFC1918 LB address
- [ ] Kyverno restricts ingress hosts per namespace and forbids the public class
- [ ] Default-deny NetworkPolicy; only the gateway may reach the workload
- [ ] Firewall rules carry a documented reason
- [ ] Every row of the §10 matrix executed, and the public-exposure rows run continuously
- [ ] VPN sessions, gateway access and IdP events shipped to the SIEM, append-only
- [ ] Joiner/mover/leaver flows verified end to end; quarterly access review scheduled
- [ ] Out-of-band admin path exists and has been used at least once in a drill

➡ [Interview Q&A](interview-qna.md)
