# Docker — Interview Q&A

> **Author:** Mengty LIM

Answers are written the way you should say them: the short answer first, then
the reason, then the trade-off. Interviewers probe the second sentence.

---

## Fundamentals

**Q1. What is the difference between a container and a VM?**
A VM virtualises hardware and runs its own kernel; a container is a process on
the host kernel isolated by namespaces (pid, net, mnt, uts, ipc, user) and
limited by cgroups. Consequences: containers start in milliseconds and cost
almost nothing in memory, but a kernel vulnerability is a shared blast radius,
and you cannot run a different kernel or OS family. When we need hard
multi-tenancy we add a sandboxed runtime (gVisor, Kata) or separate node pools —
not "just another namespace".

**Q2. Image vs container vs layer?**
An image is an immutable stack of layers plus a config (entrypoint, env, user,
exposed ports). Each Dockerfile instruction that changes the filesystem creates
a layer, content-addressed by digest and shared between images. A container is
that read-only stack with a writable copy-on-write layer on top plus its
namespaces. `docker diff` shows what's in that writable layer — in prod it
should be nearly empty, and if it isn't, someone is treating a container as a
server.

**Q3. `CMD` vs `ENTRYPOINT`?**
`ENTRYPOINT` is the executable, `CMD` is the default arguments. `docker run img
foo` replaces `CMD` but not `ENTRYPOINT`. Use `ENTRYPOINT ["app"]` +
`CMD ["--config","/etc/app.yaml"]`. Always the exec (JSON) form — the shell form
wraps you in `/bin/sh -c`, which becomes PID 1, doesn't forward SIGTERM, and your
container takes the full grace period to die on every deploy.

**Q4. `COPY` vs `ADD`?**
`COPY` copies. `ADD` additionally auto-extracts local tarballs and downloads
URLs — both are surprising side effects, and the URL fetch has no checksum
verification. Rule: always `COPY`; if you need a remote artifact, `curl` it in a
build stage and verify the SHA256 before use.

**Q5. Why is my image 1.2 GB?**
Usually one of four things: build tooling in the final stage (fix with
multi-stage), the whole build context copied in (fix with `.dockerignore`), a
package cache not cleaned in the *same* `RUN` layer (deleting it in a later
layer doesn't shrink the image — the bytes are still in the earlier layer), or a
fat base. Diagnose with `docker history --no-trunc` and `dive`.

**Q6. Explain layer caching and how you optimise build time.**
Docker reuses a layer if the instruction and its inputs are unchanged; the first
miss invalidates everything after it. So order instructions from least to most
frequently changing: base → system packages → dependency manifest → dependency
install → application source. Add BuildKit cache mounts
(`RUN --mount=type=cache,target=/root/.cache/pip`) so the package cache survives
even when the layer is rebuilt, and in CI export/import the cache to the registry
with `--cache-to/--cache-from`.

---

## Security

**Q7. How do you harden a container image?**
Layered, and I'd name them in this order because that's the order of impact:
minimal base (distroless/scratch — the fewer binaries, the less to exploit),
multi-stage so no compiler ships, numeric non-root `USER`, read-only root
filesystem with a tmpfs for `/tmp`, `--cap-drop=ALL` plus only what's needed,
`no-new-privileges`, a seccomp profile, pinned base digest, and CI scanning that
*fails the build*. Then provenance: SBOM with syft, signature with cosign, and
admission control that refuses unsigned images so the controls can't be bypassed
by pushing straight to the cluster.

**Q8. Someone put a secret in a Dockerfile `ENV`. What's wrong and what do you do?**
It's in the image config and in `docker history` — anyone who can pull the image
has it, and it's now in every registry replica and every developer's cache.
Response is incident-shaped, not fix-shaped: rotate the credential first (the
image is already distributed, deleting it proves nothing), then remove it from
the build, move it to a BuildKit `--mount=type=secret` or, better, fetch it at
runtime from Vault. Then add `gitleaks` to pre-commit and CI so the next one is
caught before it's built.

**Q9. Why is mounting `/var/run/docker.sock` dangerous?**
It's root on the host. Anyone with the socket can run a privileged container that
bind-mounts `/` and writes to it. It's the standard container-escape one-liner.
If a CI job needs to build images, use a rootless builder (BuildKit/Kaniko/
Buildah) instead, or a remote build service with its own credentials.

**Q10. Root inside a container — is that root on the host?**
Without user namespaces, uid 0 in the container is uid 0 on the host; you're
protected only by capabilities, seccomp and the fact that nothing is mounted.
With `--privileged` or a bad bind mount, that protection is gone. With user
namespace remapping (`userns-remap`, or rootless Docker/Podman) container root
maps to an unprivileged host uid, which is the real fix.

---

## Compose and runtime

**Q11. Is Docker Compose production-ready?**
For a single host with no availability target — a lab, an appliance, CI
integration tests — yes. It has no scheduling, no rolling update, no
self-healing across hosts, no declarative reconciliation. Anything with an SLO
goes to Kubernetes or a VM fleet under a configuration-management tool. I've
seen Compose in prod work fine right up until the host reboots.

**Q12. `depends_on` guarantees my DB is ready, right?**
No — plain `depends_on` only orders *start*, not readiness. You need
`condition: service_healthy` plus a real `healthcheck` on the dependency. Even
then, the application must retry its own connections with backoff, because the
DB can go away later and start order won't save you then.

**Q13. How do you persist data?**
Named volumes for state; bind mounts only for local development. Never store
state in the container's writable layer — it dies with the container and it isn't
in any backup. And a volume is not a backup: it needs a scheduled dump, off-host
storage, and a *restore* that has been drilled and timed.

**Q14. Container exits with 137 / 143 — what do they mean?**
`128 + signal`. 137 = SIGKILL (9), almost always the cgroup OOM killer — check
`docker inspect --format '{{.State.OOMKilled}}'`. 143 = SIGTERM (15), i.e. a
normal stop; if it takes the full 10s grace period, your PID 1 isn't handling
SIGTERM, which usually means shell-form CMD or a missing init.

**Q15. How do you debug a distroless container with no shell?**
Attach a sidecar sharing its namespaces:
`docker run --rm -it --pid=container:api --network=container:api nicolaka/netshoot`
(or `kubectl debug --image=netshoot --target=api` on K8s). Failing that,
`docker cp` files out and read logs/metrics. The right answer includes: I don't
add a shell to the prod image to make debugging easier — that's trading a
permanent attack surface for a one-off convenience.

---

## Delivery and tagging

**Q16. Why is `latest` banned in production?**
It's a mutable pointer. Two nodes pulling "the same" tag can run different code,
rollback has no target, and you can't answer "what is running right now?" We tag
semantically for humans and **deploy by digest** (`app@sha256:…`). The
promotion from staging to prod is a commit that changes one digest — the image
is never rebuilt, so what was tested is exactly what ships.

**Q17. What is an SBOM and why do you generate one?**
A machine-readable inventory of everything in the image (SPDX or CycloneDX,
produced with syft). It answers the only question that matters on a Log4Shell
morning: "which of our 300 images contains this package and version?" — in
seconds, without rescanning the estate. _(regulated)_ It's also increasingly a
procurement and audit requirement.

**Q18. How do you keep base images patched?**
Rebuild on a schedule, not on demand — a weekly pipeline rebuilds every service
image from its (freshly resolved) base and reruns the test suite, so a CVE fix
lands as an ordinary green deploy. Renovate/Dependabot bumps the pinned digest
in a PR. Continuous registry scanning tells you about images already deployed,
which is a different question from "is this build safe to ship".

---

## Scenario questions

**Q19. "The image builds on my laptop but fails in CI."**
Work down the differences: architecture (arm64 Mac vs amd64 runner — use
`buildx --platform`), build context (`.dockerignore` differences, files that are
gitignored locally but present in your tree), cached layers hiding a broken step
(`--no-cache` to confirm), unpinned base image resolving to a newer tag,
and network egress restrictions on the runner. Then make the finding permanent:
build the same image in CI and *use that artifact* rather than rebuilding
locally to "check".

**Q20. "Deploys are slow and users see 502s during rollout."**
Two separate bugs. The 502s: the app doesn't handle SIGTERM, or it stops
accepting new connections without draining in-flight ones, or the load balancer
still routes to a terminating instance — fix with exec-form entrypoint, a signal
handler that drains, a `preStop` sleep so the LB deregisters first, and a
readiness probe that fails *before* shutdown starts. The slowness: image too
large or no shared cache, so nodes spend minutes pulling — fix with a smaller
runtime stage and registry-side caching/pre-pull.

**Q21. "Design the container build stage of a pipeline for a regulated bank."**
Build with BuildKit on an ephemeral runner with no prod credentials. Stages:
lint (hadolint) → build multi-stage image, no secrets in layers → unit tests
inside the image → generate SBOM (syft) → scan image and SBOM (trivy/grype),
fail on HIGH+ with a fix available → sign the digest (cosign, keyless or Vault-
backed KMS) → push to the internal registry, immutable tags enforced server-side
→ record digest + git sha + SBOM in the artifact ledger. Deployment is a
separate, credential-holding system that only ever references the digest, and
cluster admission (Kyverno) rejects any image that is unsigned or not from the
internal registry. The point is that no single actor can both produce and
deploy an artifact.
