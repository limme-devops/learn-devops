# VPN & Private Access — Interview Q&A

> **Author:** Mengty LIM

---

## Fundamentals

**Q1. Is a VPN a security control?**
It's a *network* control, not an authorisation control. It answers "may this
packet reach this address", never "may this person use this application". Treated
as the whole answer it produces the flat internal network: one VPN credential and
every back-office system is browsable, which is a finding, not a hypothetical. So
I use it to shrink who can attempt, and put OIDC with an entitlement check at the
gateway to decide who succeeds — plus default-deny network policy so nothing can
reach the workload except the gateway.

**Q2. What is zero trust, minus the marketing?**
Stop treating network position as a trust signal. Every request is authenticated,
authorised against *that specific resource*, and evaluated with device state,
whether it came from the office, a VPN or a café. Practically it means per-app
SSO with group entitlements, short-lived credentials, mTLS or workload identity
service-to-service, and logging every access decision. The VPN doesn't disappear
— it becomes network hygiene rather than the boundary. The honest caveat: it's a
direction, not a product, and anyone selling it as a box is selling a VPN.

**Q3. WireGuard vs IPsec/IKEv2 vs OpenVPN?**
WireGuard: tiny auditable codebase, modern crypto with no negotiation (so no
downgrade attacks), fast handshakes, roams cleanly between networks — my default
where I control the clients. IPsec/IKEv2: native support in Windows, macOS and
iOS with MFA via EAP, and the interop story with enterprise appliances, at the
cost of real configuration complexity — proposal and traffic-selector mismatches
are the classic failure. OpenVPN: extremely portable and TCP/443-capable so it
traverses hostile networks, but userspace and slower. What WireGuard notably
lacks is users, MFA and device posture — it has keys, so you bolt identity on
around it.

**Q4. Explain `AllowedIPs` in WireGuard.**
It's two things simultaneously, which is why people misconfigure it. Outbound
it's a route: traffic for those prefixes goes into the tunnel. Inbound it's a
cryptographic ACL: packets from that peer are only accepted if their source
address falls in the range. So on a client, `0.0.0.0/0` means full tunnel; on a
server's peer block, `0.0.0.0/0` means that peer may claim any source address —
almost never what you want. Per-device `/32`s on the server side are how you get
attributable, filterable access.

---

## DNS and routing

**Q5. "The VPN is connected but the app doesn't work." Debug it.**
Nine times out of ten it's DNS. Internal names are split-horizon, so if the
client kept its local resolver, the name simply doesn't exist. Check
`resolvectl status` (or `scutil --dns` on macOS, NRPT on Windows) to see which
resolver the tunnel interface is actually using, then `dig` the name against the
internal resolver and against a public one to confirm the split is behaving. If
DNS resolves, move to routing — `ip route get <dst>` tells you whether the packet
takes the tunnel, and the usual cause of "no" is `AllowedIPs` not covering the
destination. If routing is right, then firewall and finally the app.

**Q6. Why split-horizon DNS, and what's the anti-pattern?**
Internal names should resolve only on internal resolvers. A public A record
pointing at RFC1918 space leaks your topology and lands in passive-DNS datasets
that attackers mine for free. The anti-pattern I push back on hardest is
publishing internal host records "so Let's Encrypt DNS-01 works" — instead,
delegate a dedicated validation subzone so the ACME credential can only write TXT
records in one place and can't touch real zones. Or issue from the internal CA
and avoid the question.

**Q7. Split tunnel or full tunnel?**
Split by default: push internal CIDRs only, keep personal traffic personal, and
don't size your egress for the entire fleet's video calls. Full tunnel is
defensible when DLP or egress inspection is a stated requirement on managed
devices — but then it must be a deliberate decision with capacity planning, not a
default nobody revisited. Either way the security argument matters less than
people think: with endpoint controls and per-app authentication, routing all
traffic through the office doesn't buy much.

**Q8. Two sites both use 192.168.1.0/24. Now what?**
Overlapping RFC1918 is the recurring real-world problem, and there's no clever
fix at connect time — the client's home router wins for its own subnet, so
resources at the far end become unreachable. Options: re-plan address space (the
right answer, painful at scale), NAT at the tunnel edge so each site sees the
other through a unique range, or move to per-application access (an
identity-aware proxy) where you never route networks together at all. The last
one is increasingly why people abandon site-to-site VPNs for app-level access.

**Q9. Large requests hang but small ones work over the tunnel.**
MTU. The tunnel adds encapsulation overhead, so the effective MTU is lower than
the physical link — 1420 is the usual WireGuard starting point, 1280 is safe
almost everywhere. If PMTU discovery is broken because something drops ICMP
"fragmentation needed" (extremely common on the internet), you get a black hole:
the handshake and small packets succeed, anything above the threshold vanishes.
Bisect with `ping -M do -s <size>`, then set the interface MTU and clamp TCP MSS.

---

## Design

**Q10. Design private access for an internal admin console holding customer data.**
Model: internal-only *plus* per-app OIDC — reachability alone is not acceptable
for that data class. Concretely: hostname under the internal zone, split-horizon
DNS, deployed behind a **separate** internal ingress controller with an RFC1918
load balancer address (not the public controller with an IP allowlist bolted on,
because one annotation shouldn't be able to publish it). Per-service short-lived
certificate from the internal CA. Kong enforcing an OIDC flow against Keycloak
with an explicit `groups_required`, exact redirect URIs, no wildcards.
Default-deny NetworkPolicy so only the gateway namespace can reach the workload.
VPN access via per-device short-lived keys with SSO, MFA and posture checks, on a
route set that doesn't include the management zone. Then the part people skip:
verify from every position — public internet, VPN unauthenticated, VPN
authenticated but unentitled, another namespace — and run the public-exposure
checks continuously.

**Q11. Wildcard certificate for `*.internal` — good idea?**
Convenient and usually the wrong default. One private key that can impersonate
every internal application is the worst single artifact you can have; revocation
touches everything at once, rotation becomes a rehearsed event rather than
continuous, and the audit answer to "which service holds which key" becomes "all
of them". I'd issue per-service short-lived certs from Vault PKI via cert-manager
and reserve the wildcard for cases where per-name automation is genuinely
impossible — a legacy appliance — as a documented exception with an owner and an
expiry, scoped to the ingress namespace. One more argument that often settles it:
a *public* wildcard for internal names publishes your internal naming scheme to
Certificate Transparency logs.

**Q12. VPN or identity-aware proxy for contractors?**
Proxy, usually. There's no client to install, no network route to grant, and
access is per-application rather than per-network — a contractor who needs one
system gets one system, not a route into the app zone. The trade-off is honest
and I'd state it: you've put a listener back on the public internet, so the edge
controls become load-bearing, and you're now dependent on the proxy's
availability and its device-posture signals. For staff on managed laptops needing
broad access to many internal systems, a VPN is still simpler.

**Q13. How do you handle joiner/mover/leaver?**
The IdP is the single lifecycle point — that's the design property that makes it
work. VPN keys are issued per device after an OIDC flow with a short TTL, so
disabling the account in Keycloak stops renewal and access expires on its own;
app entitlements are IdP groups, so they follow too. Contractors get time-boxed
group membership with an automatic expiry rather than a calendar reminder.
Quarterly, each service owner confirms their group's membership. The test I'd
apply to any implementation: disable a test account and see whether VPN access
survives. If it does, you have two identity systems and one of them is wrong.

**Q14. What do you log, and why?**
VPN session records (user, device, source IP, start/end), gateway access logs
carrying the authenticated subject and the authorisation decision, and IdP
authentication events — all to the SIEM on an append-only path the platform team
can't delete. The question this answers, and it gets asked after every incident
and in every audit, is "who could have reached that system on the 14th, and did
they?" Without the authenticated subject in the gateway log you have IP
addresses and guesswork.

---

## Operations

**Q15. You push a VPN config change and the fleet drops. What now?**
Revert — the concentrator config is in Git, so it's a revert and reload, not
freehand repair. The prerequisite is the thing I'd emphasise: an out-of-band
admin path that does not depend on the VPN you just broke, whether that's console
access, a separate management link, or a bastion reachable from an admin range.
If the only route to fix the VPN is through the VPN, you don't have a rollback
plan, you have hope. I'd also change how it was deployed: concentrators in an HA
pair, changes rolled to one node with a canary group of devices before the fleet.

**Q16. How do you give developers `kubectl` access to a private cluster?**
Private API endpoint with no public listener, reachable over the VPN, and OIDC
authentication (`kubectl oidc-login`) so the credential is a short-lived token
tied to a human identity rather than a long-lived kubeconfig token that lives in
a laptop forever. RBAC scoped to their namespaces, no `cluster-admin`, and
elevation via a time-boxed JIT request. Everything the API server does is in the
audit log, so `kubectl port-forward` to reach an internal service ad hoc is
acceptable and attributable — which is why it's a better answer than "expose a
NodePort temporarily", the thing that survives for two years.

**Q17. A service that should be internal has a public IP. How did that happen and
how do you stop the next one?**
Usually a load balancer scheme annotation dropped or renamed during a Helm chart
upgrade, or an Ingress that got the public class. Immediate action is to remove
the exposure first — revert the manifest or delete the Ingress — then investigate,
because diagnosis while exposed is the wrong order. Prevention is layered:
separate internal ingress controller so the classes can't be confused, Kyverno
policy forbidding the public class in internal namespaces and restricting hosts
per namespace, and a continuous check asserting every internal LoadBalancer
address is RFC1918 that alerts if one becomes public. Point-in-time verification
doesn't catch regressions; the check has to keep running.

**Q18. Someone asks you to open a firewall rule "temporarily". How do you handle it?**
Find out what they actually need, because it's usually narrower than the request
— frequently a single port to a single host, not a subnet. Then make it
time-boxed with an actual expiry, attributable to a person and a ticket, and
carry a written reason in the rule itself. The systemic point I'd make: a
firewall estate degrades to allow-all over five years precisely because nobody
can justify any individual rule, so nobody dares delete one. Rules with a
documented reason and an owner can be reviewed; rules without one accumulate
forever.
