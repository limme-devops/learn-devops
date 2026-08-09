# Docker Cheat Sheet

> **Author:** Mengty LIM

Images, layers, builds, Compose, registries, runtime hardening.

---

## 1. Mental model in one paragraph

An **image** is an ordered stack of read-only layers plus a JSON config
(entrypoint, env, user). A **container** is that stack plus a thin writable
layer and a set of Linux namespaces (pid, net, mnt, uts, ipc, user) and cgroups.
Docker is not a VM: the kernel is shared. Every security control you get comes
from namespaces, cgroups, capabilities, seccomp and the fact that the image has
nothing useful in it.

---

## 2. Everyday commands

```bash
# --- images ---
docker build -t app:dev .                     # build from ./Dockerfile
docker build --target builder -t app:b .      # stop at a named stage
docker build --build-arg VER=1.2 --no-cache . # no cached layers
docker images --digests                       # see the sha256 you must promote
docker history app:dev                        # layer sizes — find the fat one
docker inspect app:dev | jq '.[0].Config'     # entrypoint/user/env actually baked in
docker image prune -af --filter until=168h    # reclaim disk (CI runners!)

# --- containers ---
docker run --rm -it app:dev sh                # throwaway shell
docker run -d --name api -p 8080:8080 app:dev
docker logs -f --tail 100 api
docker exec -it api sh                        # into a running container
docker stats                                  # live cpu/mem per container
docker top api                                # processes inside
docker cp api:/app/config.yaml ./             # pull a file out
docker diff api                               # what changed vs the image (drift!)

# --- debugging a distroless / no-shell image ---
docker run --rm -it --pid=container:api --network=container:api \
  --cap-add SYS_PTRACE nicolaka/netshoot      # sidecar with tools

# --- registry ---
docker login registry.internal
docker tag app:dev registry.internal/app:1.4.2
docker push registry.internal/app:1.4.2
docker pull registry.internal/app@sha256:abc… # pin by digest, always

# --- cleanup ---
docker system df                              # where the disk went
docker system prune -a --volumes              # DANGEROUS: deletes volumes too
```

### buildx / multi-arch

```bash
docker buildx create --use --name multi
docker buildx build --platform linux/amd64,linux/arm64 \
  -t registry.internal/app:1.4.2 --push .
docker buildx build --cache-to type=registry,ref=reg/app:cache,mode=max \
                    --cache-from type=registry,ref=reg/app:cache .
```

---

## 3. Dockerfile — the reference build

```dockerfile
# syntax=docker/dockerfile:1.7

##### stage 1: build (has compilers, never shipped) #####
FROM python:3.12-slim AS builder
WORKDIR /app
# deps first: this layer caches while your source churns
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --prefix=/install -r requirements.txt

##### stage 2: runtime (minimal) #####
FROM python:3.12-slim
# non-root, no shell login, fixed uid so k8s runAsUser matches
RUN groupadd -g 10001 app && useradd -u 10001 -g app -s /usr/sbin/nologin -M app
WORKDIR /app
COPY --from=builder /install /usr/local
COPY --chown=app:app src/ ./src/

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
USER 10001
EXPOSE 8080
# exec form: PID 1 is your app, so SIGTERM reaches it
ENTRYPOINT ["python", "-m", "src.main"]
```

### Rules, and the reason each exists

| Rule | Why it bites if you skip it |
|---|---|
| Order layers cheap→expensive; `COPY` deps before source | One source-file change invalidates the dependency install layer. 30s build becomes 6min |
| `.dockerignore` `.git`, `node_modules`, `*.env`, `tests/` | Build context bloat + credentials leaking into layers |
| Multi-stage: compilers stay in stage 1 | `gcc` and `curl` in a runtime image are an attacker's toolchain |
| Pin base image by **digest** `FROM python:3.12-slim@sha256:…` | Tags are mutable. Your "reproducible" build isn't |
| One process, `ENTRYPOINT` in **exec form** | Shell form makes `/bin/sh` PID 1 → SIGTERM is swallowed → 30s kill delay every deploy |
| `USER <numeric uid>` | K8s `runAsNonRoot` can't verify a username, only a uid |
| Never `ADD` a URL; use `COPY` (+ `curl` in a build stage with a checksum) | `ADD` auto-extracts archives and fetches unverified remote content |
| Secrets via `--mount=type=secret`, never `ARG`/`ENV` | `ARG` values land in image history and `docker history` prints them |
| `HEALTHCHECK` for Compose/Swarm only | K8s ignores it — use `livenessProbe`/`readinessProbe` there |
| `LABEL org.opencontainers.image.revision=$GIT_SHA` | Provenance: "which commit is running in prod?" must be answerable from the image |

### Secrets at build time (the correct way)

```dockerfile
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci
```
```bash
docker build --secret id=npmrc,src=$HOME/.npmrc .
```
The secret is mounted into that RUN only and never becomes a layer.

### Image size ladder

`ubuntu` (~78MB) → `debian-slim` (~30MB) → `alpine` (~5MB, musl — watch DNS &
glibc-compiled wheels) → `distroless` (no shell, no package manager) →
`scratch` (static Go/Rust binaries only).

_(regulated)_ Distroless or scratch for anything internet-facing. "I can't
exec into it" is the point — so is the auditor's face when you show them.

---

## 4. Networking, volumes, resources

```bash
# networks
docker network create --driver bridge app-net
docker run --network app-net --network-alias db postgres:16   # DNS name = alias
# host mode has no port mapping and no isolation — Linux only, avoid in prod
```

| Mount type | Syntax | Use |
|---|---|---|
| Named volume | `-v pgdata:/var/lib/postgresql/data` | Persistent state. Docker manages the path |
| Bind mount | `-v $PWD/src:/app/src` | Dev hot-reload only. Never prod (host path coupling) |
| tmpfs | `--tmpfs /tmp:rw,noexec,nosuid,size=64m` | Secrets/scratch that must never hit disk |

```bash
# resources — always set them; an unbounded container is a noisy neighbour
docker run --memory=512m --memory-swap=512m --cpus=1.5 \
           --pids-limit=200 --ulimit nofile=8192:8192 app:dev
```
Memory limit exceeded → the kernel OOM-kills PID 1 → exit code **137**. CPU limit
exceeded → throttling, not a kill (you see latency, not errors).

---

## 5. Runtime hardening

```bash
docker run \
  --read-only --tmpfs /tmp:rw,noexec,nosuid \
  --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
  --security-opt=no-new-privileges:true \
  --security-opt seccomp=default.json \
  --user 10001:10001 \
  --network app-net \
  app:1.4.2
```

**Never in production:** `--privileged`, `-v /var/run/docker.sock:…` (that is
root on the host), `--net=host`, `--pid=host`, `--cap-add=SYS_ADMIN`.

Scanning and provenance:
```bash
trivy image --severity HIGH,CRITICAL --exit-code 1 registry/app:1.4.2
syft registry/app:1.4.2 -o spdx-json > sbom.json      # SBOM
grype sbom:sbom.json                                   # scan the SBOM
cosign sign --key … registry/app@sha256:…              # sign the digest
cosign verify --key … registry/app@sha256:…
```

---

## 6. Docker Compose

`compose.yaml` (the modern name; `version:` is obsolete and warns).

```yaml
services:
  api:
    build:
      context: .
      target: builder          # dev builds stop at the fat stage
    image: registry.internal/app:1.4.2
    env_file: [.env]           # never commit .env
    environment:
      DB_DSN: postgres://app@db:5432/app
    ports: ["8080:8080"]       # "127.0.0.1:8080:8080" to avoid exposing on 0.0.0.0
    depends_on:
      db: { condition: service_healthy }   # waits for the healthcheck, not just start
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request;urllib.request.urlopen('http://localhost:8080/healthz')"]
      interval: 10s
      timeout: 3s
      retries: 5
      start_period: 20s
    deploy:
      resources:
        limits: { cpus: "1.5", memory: 512M }
    restart: unless-stopped
    networks: [back]

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets: [db_password]
    volumes: ["pgdata:/var/lib/postgresql/data"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      retries: 10
    networks: [back]

volumes: { pgdata: {} }
networks: { back: {} }
secrets:
  db_password: { file: ./secrets/db_password.txt }
```

```bash
docker compose up -d --build
docker compose ps
docker compose logs -f api
docker compose exec api sh
docker compose config                     # render the merged, resolved file
docker compose -f compose.yaml -f compose.prod.yaml up -d   # override layering
docker compose down -v                    # -v also deletes volumes
docker compose run --rm api pytest        # one-off task container
```

**Override pattern.** `compose.yaml` = shared truth. `compose.override.yaml`
(auto-loaded) = local dev only: bind mounts, debug ports, `target: builder`.
Prod-ish files are explicit `-f`. Keep the *image name* identical everywhere so
you cannot accidentally test a different artifact.

**Compose is not an orchestrator.** No rolling update, no self-healing across
hosts, no scheduling. Fine for local labs, CI integration tests, and a single
appliance box. Anything with an SLO goes to Kubernetes or a VM fleet under
Ansible.

---

## 7. Gotchas that cost real hours

| Symptom | Cause | Fix |
|---|---|---|
| Container takes 10s to stop, exit 143 | Shell-form CMD → sh is PID 1, doesn't forward SIGTERM | exec form, or `--init` / `tini` |
| Exit code 137 | OOM-killed | Raise memory limit, or fix the leak. Check `docker inspect --format '{{.State.OOMKilled}}'` |
| Works locally, fails in CI | Different arch or a cached layer | `--platform`, `--no-cache`, pin base digest |
| Alpine image: DNS or crypto weirdness | musl vs glibc | Use `-slim` for Python/Node with native wheels |
| Files written by container are root-owned on host | Bind mount + root in container | Run as your uid: `--user $(id -u):$(id -g)` |
| Image "same tag" but different content | Mutable tags | Promote by digest. `latest` is banned _(regulated)_ |
| Secret visible in `docker history` | `ARG`/`ENV` secret | BuildKit `--mount=type=secret` |
| Disk full on the runner | Dangling images/build cache | `docker builder prune`, scheduled `system prune` |
| Time drifts / TZ wrong | No tzdata in slim images | `ENV TZ=UTC` and keep everything UTC |

---

## 8. Best practices checklist

- [ ] Base image pinned by digest, rebuilt weekly to absorb CVE fixes
- [ ] Multi-stage; runtime stage has no compiler, no package manager, no curl
- [ ] Runs as a numeric non-root uid, read-only rootfs, `cap-drop=ALL`
- [ ] `.dockerignore` present and reviewed
- [ ] No secret in `ARG`, `ENV`, or any layer; build secrets via BuildKit mounts
- [ ] Resource limits set for every container
- [ ] Image labelled with git sha + build time; SBOM generated and stored
- [ ] Scanned in CI, pipeline **fails** on HIGH/CRITICAL with a fixed version available
- [ ] Signed with cosign; admission control verifies the signature _(regulated)_
- [ ] Logs to stdout/stderr as JSON — never to a file inside the container
- [ ] Config from env/mounted files; the same image runs in every environment

➡ [Interview Q&A](interview-qna.md)
