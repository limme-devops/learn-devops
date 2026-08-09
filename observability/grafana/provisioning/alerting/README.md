# `provisioning/alerting/` — deliberately almost empty

> **Author:** Mengty LIM

Grafana can provision alert rules, contact points and notification policies from
YAML files in this directory. **This platform does not use that mechanism**, and
the empty directory is here so nobody adds one by accident.

## Where alerting actually lives

| Object | Owned by | Location |
|---|---|---|
| Metric alert rules (burn rate, saturation, availability) | Prometheus | `gitops/business/*/base/prometheusrule.yaml` |
| Log-based and multi-datasource alert rules | Grafana, via Terraform | `../../terraform/alert-rules.tf` |
| Contact points | Grafana, via Terraform | `../../terraform/contact-points.tf` |
| Notification policy tree | Grafana, via Terraform | `../../terraform/notification-policy.tf` |
| Mute timings | Grafana, via Terraform | `../../terraform/notification-policy.tf` |

## Why Terraform instead of these files

Three reasons, in order of how much they will hurt you:

1. **Secrets.** A contact point needs a PagerDuty integration key or a Slack
   webhook. File provisioning wants it in the YAML. Terraform reads it from
   Vault at apply time and it never touches git. This alone decides it.
2. **Real diffs.** `terraform plan` shows exactly which routes change before you
   change them. A file-provisioning diff shows you a YAML blob and you find out
   what it meant afterwards.
3. **Ordering.** Notification policies reference contact points, which reference
   mute timings. Terraform resolves that graph. File provisioning applies in
   whatever order it reads the directory, and a dangling reference means alerts
   route to the default receiver — which usually means nowhere anyone is looking.

## Why metric rules stay in Prometheus, not here

**Your paging path must survive Grafana being down.** If Grafana is the only
thing that can page, a Grafana outage is a silent outage of everything else —
the worst failure mode in observability, because the dashboards go dark at the
same moment the alerts do.

Prometheus rules evaluate next to the data and hand off to Alertmanager. Neither
depends on Grafana running. Drill 3 in
[docs/15](../../../../docs/15-logging-monitoring-procedure.md) §8 tests exactly
this: stop Grafana entirely, confirm P1 alerts still page.

Grafana Alerting is used only for what Prometheus genuinely cannot do — query
Loki, and join across datasources.

## If you disagree with this split

Change it in one place and delete the other. What you must not end up with is
two systems evaluating similar rules: duplicate pages that resolve at different
times, and nobody able to say which one fired.
