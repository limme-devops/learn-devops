# `observability/` — the monitoring stack as code

Grafana holds nothing that is not in this directory. If a datasource, folder,
permission, contact point, notification route or dashboard exists only in the
running instance, it is a bug — and it disappears the day someone rebuilds.

Procedure and reasoning: **[docs/15-logging-monitoring-procedure.md](../docs/15-logging-monitoring-procedure.md)**.

---

## Layout

```
observability/
└── grafana/
    ├── provisioning/          Mounted into the pod, read at boot
    │   ├── datasources/       Prometheus, Loki, Tempo, Elasticsearch (uids PINNED)
    │   ├── dashboards/        Providers only — where to look on disk
    │   └── alerting/          Deliberately empty; see its README
    ├── dashboards/            Dashboard JSON, one folder per Grafana folder
    │   ├── services/          payment-service.json — the 4-row reference layout
    │   ├── platform/
    │   └── security/
    ├── terraform/             Folders, teams, permissions, contact points,
    │                          notification tree, log-based alert rules
    └── scripts/
        └── sync-dashboards.sh CI: push dashboards/ into Grafana
```

## Why three mechanisms and not one

Each object type has a different constraint. Using one mechanism for all three
means losing to whichever constraint you ignored.

| Objects | Mechanism | The constraint that decides it |
|---|---|---|
| Datasources | **Provisioning files** | Must exist *before* anything queries. Files load at boot; the API is only reachable afterwards |
| Folders, teams, permissions, contact points, notification tree, Grafana alert rules | **Terraform** | Contact points hold PagerDuty and Slack secrets. Terraform reads them from Vault at apply time; file provisioning would put them in git |
| Dashboards | **HTTP API in CI** | Changes constantly. No pod restart, and CI fails loudly on malformed JSON rather than Grafana skipping it in silence |

Two dashboards that must survive a total rebuild with no CI run (the platform
overview, the on-call landing page) are *also* file-provisioned via
`provisioning/dashboards/providers.yaml`. That is the one deliberate overlap.

## The invariant that breaks everything when violated

**UIDs are pinned, in three places, and must agree:**

| Value | Defined in | Also referenced by |
|---|---|---|
| Datasource uid (`prometheus-prod`, `loki-prod`, …) | `provisioning/datasources/datasources.yaml` | every dashboard panel, every Grafana alert rule |
| Folder uid (`services`, `platform`, `security`) | `terraform/folders.tf` | `provisioning/dashboards/providers.yaml`, `scripts/sync-dashboards.sh` |
| Dashboard uid | each dashboard JSON | dashboard links, alert `dashboard_url` annotations |

Let Grafana generate any of these and the first rebuild produces an instance
where every panel says *"Datasource not found"* and every dashboard has quietly
been filed into `General`. It looks like a catastrophic failure and it is one
line of config.

## Apply order

```bash
# 1. Datasources — via the Grafana Helm release (ConfigMap from provisioning/)
kubectl -n monitoring create configmap grafana-datasources \
  --from-file=observability/grafana/provisioning/datasources/ \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. Folders, teams, permissions, contact points, routing, alert rules
cd observability/grafana/terraform
terraform init && terraform plan   # review the routing diff — always
terraform apply

# 3. Dashboards (folders must exist first, hence the order)
export GRAFANA_URL=https://grafana.bank.internal
export GRAFANA_TOKEN="$(vault kv get -field=sync_token kv/observability/grafana)"
../scripts/sync-dashboards.sh --dry-run
../scripts/sync-dashboards.sh
```

Steps 2 and 3 run in CI on merge to `main`. Step 1 is part of the Grafana Helm
release, reconciled by ArgoCD.

## Adding a service dashboard

1. Copy `dashboards/services/payment-service.json`.
2. Change `uid`, `title`, and the `service` constant in `templating`.
3. Keep **all four rows in order** — RED, SLO, SATURATION, DEPENDENCY. The
   layout being identical everywhere is the feature; an engineer paged at 3am
   should not be reading a new dashboard for the first time.
4. Update the runbook link in `links`.
5. `./scripts/sync-dashboards.sh --dry-run` to validate, then commit.

The dry run enforces three things the API will not: the dashboard has a `uid`,
the JSON parses, and no panel inherits a default datasource.

## What is deliberately *not* here

| Not here | Where it is | Why |
|---|---|---|
| Metric alert rules (burn rate, saturation) | `gitops/business/*/base/prometheusrule.yaml` | Paging must survive Grafana being down |
| Grafana's own Helm values | `gitops/platform/monitoring/` | Deployment is GitOps; configuration is this directory |
| Kibana saved objects | *not yet written* — see docs/15 §10 | Different tier, different tool |
| Alert-rule linter (fails rules missing `runbook_url`) | *not yet written* — see docs/15 §6.2 | Belongs in `ci/scripts/` |

## Verification

From [docs/15](../docs/15-logging-monitoring-procedure.md) §8 — the two drills
that test *this* directory specifically:

- **Drill 2** — delete a dashboard in the UI. `allowUiUpdates: false` and
  `editable: false` should make Save unavailable; if someone deletes one via the
  API, the next CI sync restores it.
- **Drill 8** — rebuild Grafana from scratch. Every dashboard, datasource,
  folder, permission and alert route returns from git within 10 minutes.

Drill 8 is the one that proves this directory is doing its job. Run it once a
quarter against a scratch instance, not against prod.
