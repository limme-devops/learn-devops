# Compose Lab — Keycloak + Postgres + Redis

> **Author:** Mengty LIM

A single-node stand-in for the platform services in
[`docs/04-platform-services.md`](../../docs/04-platform-services.md): Keycloak
(auth), Postgres (Keycloak's store), Redis (cache/session). No Kubernetes
required — this is for iterating on realm config, JWT flows, or app code
against a real OIDC provider without spinning up the kind cluster.

## Quick start

```bash
cd local-lab/compose
make up          # copies .env.example -> .env on first run, then starts + waits for health
make ps
```

Keycloak admin console: http://localhost:8080 (`admin` / see `.env`).

```bash
make down        # stop, keep data
make down-v      # stop and WIPE data (asks for confirmation)
```

All targets also work from the repo root as `make compose-up`, `make compose-down`, etc.

## Best practices baked into `docker-compose.yml`

| Practice | Where |
|---|---|
| Pinned image tags, never `latest` | every `image:` line |
| Secrets from `.env`, not hardcoded; `.env` gitignored, `.env.example` committed | `environment:` blocks, `${VAR:?...}` fails fast if unset |
| Healthchecks + `depends_on: condition: service_healthy` | keycloak won't start against a db that isn't ready |
| Named volumes, not bind mounts, for stateful data | `volumes:` top-level block |
| Isolated bridge network, not the default | `networks.backend` |
| Ports bound to `127.0.0.1` only, not `0.0.0.0` | `ports:` — nothing here should be reachable from the LAN |
| Resource limits on every service | `deploy.resources.limits` — a runaway container can't starve the host |
| Log rotation | `x-logging` anchor, `max-size`/`max-file` — prevents unbounded disk growth from `logs -f` in dev |
| `no-new-privileges` | `security_opt` on every service |
| `restart: unless-stopped` | survives a host reboot without masking a crash-loop (`always` would hide the latter) |

## Makefile targets (`local-lab/compose/Makefile`)

This Makefile is a **generic template** — `PROJECT` and `SERVICES` are derived
at runtime from `docker compose config`/`docker compose ps`, not hardcoded to
this stack. Copy it next to any `docker-compose.yml` and it works unmodified,
except the "convenience shells" section at the bottom (`psql`, `redis-cli`),
which is this project's own shortcut and should be edited or deleted per project.

| Target | Does |
|---|---|
| `services` | list service names defined in `docker-compose.yml` |
| `up` | `docker compose up -d`, waits for all healthchecks |
| `down` / `down-v` | stop; `down-v` also deletes named volumes (confirmation prompt) |
| `restart` / `restart-svc SVC=db` | restart everything, or one service |
| `recreate` | force-recreate containers after editing compose/.env, keeps volumes |
| `build` | rebuild any services with a `build:` section, no cache |
| `pull` | pull the pinned image tags |
| `ps` / `health` | container list / per-container healthcheck status |
| `logs` / `logs-svc SVC=db` | follow logs, all or one service |
| `inspect SVC=db` | `docker inspect` on that service's container |
| `stats` | live `docker stats` for every running container in the project |
| `top SVC=db` | processes running inside a service |
| `network` | `docker network inspect` on every network Compose created for this project |
| `volumes` | list the named volumes Compose created for this project |
| `config` | print the fully resolved, interpolated compose config |
| `exec SVC=db` | shell into a service |
| `psql` / `redis-cli` | drop straight into a db/redis session (project-specific) |
| `prune` | clean dangling images/build cache left by this project |

Run `make help` in this directory for the live list. `SVC` defaults to the
first service in `docker-compose.yml` if not given.

## What differs from a real deployment, and why

Same philosophy as the kind lab (see [`../README.md`](../README.md)):

| Production | Here | Reason |
|---|---|---|
| Keycloak `start` with a reverse proxy + real TLS | `start-dev` | dev mode skips cert/proxy setup so you can iterate on realm config fast; never use `start-dev` past a laptop |
| Vault-issued DB/Redis credentials | `.env` file | Vault Agent needs a Vault server; out of scope for a data-plane lab |
| Postgres HA (CloudNativePG) | single Postgres container | see `local-lab/README.md` — failover needs real nodes |
| Managed secret rotation | static passwords you set once | rotation is a Vault concept, not a Compose one |
