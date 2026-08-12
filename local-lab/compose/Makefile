# Author: Mengty LIM
#
# Generic Docker Compose ops Makefile. Everything below is derived at
# runtime from `docker compose config` / `docker compose ps` — nothing is
# hardcoded to this stack's service names. Copy this file into any project
# that has a docker-compose.yml next to it and it works unmodified. The
# only project-specific section is "convenience shells" at the bottom,
# clearly marked — delete or edit it per project.
.DEFAULT_GOAL := help
SHELL := /bin/bash

COMPOSE  := docker compose
PROJECT  := $(shell $(COMPOSE) config --format json 2>/dev/null | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' | head -1)
SERVICES := $(shell $(COMPOSE) config --services 2>/dev/null)
SVC      ?= $(firstword $(SERVICES))

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: services
services: ## List the service names defined in docker-compose.yml
	@echo $(SERVICES) | tr ' ' '\n'

## ---------- env ----------

.PHONY: env
env: ## Create .env from .env.example if missing
	@test -f .env.example && [ ! -f .env ] && { cp .env.example .env; echo "Created .env — edit it before 'make up'"; } || true

## ---------- lifecycle ----------

.PHONY: up
up: env ## Start the stack in the background
	$(COMPOSE) up -d
	@$(MAKE) --no-print-directory wait

.PHONY: down
down: ## Stop and remove containers (volumes kept)
	$(COMPOSE) down

.PHONY: down-v
down-v: ## Stop and remove containers AND named volumes (destroys data — confirm first)
	@read -p "This deletes all named volumes for project '$(PROJECT)'. Type 'yes' to continue: " ans; \
	  [ "$$ans" = "yes" ] || { echo "aborted"; exit 1; }
	$(COMPOSE) down -v

.PHONY: restart
restart: ## Restart every service (config unchanged)
	$(COMPOSE) restart

.PHONY: restart-svc
restart-svc: ## Restart one service: make restart-svc SVC=<name>
	$(COMPOSE) restart $(SVC)

.PHONY: recreate
recreate: env ## Recreate containers after a compose/env file change, without losing volumes
	$(COMPOSE) up -d --force-recreate --no-deps

.PHONY: build
build: ## Build (or rebuild) any services with a 'build:' section, no cache
	$(COMPOSE) build --no-cache

.PHONY: pull
pull: ## Pull the latest images for the pinned tags in docker-compose.yml
	$(COMPOSE) pull

## ---------- inspection ----------

.PHONY: ps
ps: ## List stack containers and their health/status
	$(COMPOSE) ps

.PHONY: logs
logs: ## Tail logs for all services
	$(COMPOSE) logs -f --tail=200

.PHONY: logs-svc
logs-svc: ## Tail logs for one service: make logs-svc SVC=<name>
	$(COMPOSE) logs -f --tail=200 $(SVC)

.PHONY: health
health: ## Show the healthcheck status of every container that defines one
	@for c in $$($(COMPOSE) ps -q); do \
	  name=$$(docker inspect -f '{{.Name}}' $$c | sed 's#^/##'); \
	  status=$$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' $$c); \
	  printf "%-30s %s\n" "$$name" "$$status"; \
	done

.PHONY: inspect
inspect: ## Full docker inspect of one service's container: make inspect SVC=<name>
	docker inspect $$($(COMPOSE) ps -q $(SVC))

.PHONY: stats
stats: ## Live CPU/mem/net stats for every running container in the stack
	docker stats $$($(COMPOSE) ps -q)

.PHONY: top
top: ## Show running processes inside one service: make top SVC=<name>
	$(COMPOSE) top $(SVC)

.PHONY: network
network: ## Inspect the network(s) Compose created for this project
	@for n in $$(docker network ls --filter label=com.docker.compose.project=$(PROJECT) -q); do \
	  docker network inspect $$n; \
	done

.PHONY: volumes
volumes: ## List the named volumes Compose created for this project
	docker volume ls --filter label=com.docker.compose.project=$(PROJECT)

.PHONY: config
config: ## Validate and print the fully resolved compose config
	$(COMPOSE) config

## ---------- access ----------

.PHONY: exec
exec: ## Shell into a running service: make exec SVC=<name>
	$(COMPOSE) exec $(SVC) sh

## ---------- lifecycle helpers ----------

.PHONY: wait
wait: ## Block until every container with a healthcheck reports healthy (used by 'up')
	@echo "Waiting for services to become healthy..."
	@for i in $$(seq 1 30); do \
	  ids=$$($(COMPOSE) ps -q); \
	  pending=$$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' $$ids 2>/dev/null | grep -vE '^(healthy|)$$' | wc -l); \
	  [ "$$pending" = "0" ] && { echo "All services healthy (or have no healthcheck)."; exit 0; }; \
	  sleep 5; \
	done; \
	echo "Timed out waiting for health — check 'make ps' / 'make logs'"; exit 1

.PHONY: clean
clean: down-v ## Alias for down-v (destroy containers + volumes)

.PHONY: prune
prune: ## Remove dangling images/build cache left behind by this project (no running containers touched)
	docker image prune -f
	docker builder prune -f

## ---------- convenience shells (project-specific — edit per project) ----------

.PHONY: psql
psql: ## Open a psql session against the db service
	$(COMPOSE) exec db psql -U $${POSTGRES_USER:-keycloak} -d $${POSTGRES_DB:-keycloak}

.PHONY: redis-cli
redis-cli: ## Open a redis-cli session against the redis service
	$(COMPOSE) exec redis sh -c 'redis-cli -a "$$REDIS_PASSWORD"'
