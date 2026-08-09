# Grafana-managed alert rules.
#
# ONLY rules Prometheus genuinely cannot express belong here:
#   - anything querying Loki (log patterns)
#   - anything joining two datasources
#
# Metric-only rules (burn rate, saturation, availability) live in
# gitops/business/*/base/prometheusrule.yaml so they keep working when Grafana
# does not. See provisioning/alerting/README.md for the full argument.

resource "grafana_rule_group" "log_based" {
  name             = "log-based-alerts"
  folder_uid       = grafana_folder.services.uid
  interval_seconds = 60

  # -------------------------------------------------------------------------
  rule {
    name      = "SecretPatternInLogs"
    condition = "threshold"
    for       = "0s" # fire on the first occurrence — one leaked token is enough

    data {
      ref_id = "query"
      relative_time_range {
        from = 300
        to   = 0
      }
      datasource_uid = "loki-prod"
      model = jsonencode({
        expr      = <<-EOT
          sum(count_over_time({env="prod"} |~ `(?i)"(password|secret|api[_-]?key)"\s*:\s*"[^"]{8,}"` [5m]))
        EOT
        queryType = "instant"
        refId     = "query"
      })
    }

    data {
      ref_id         = "threshold"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 300
        to   = 0
      }
      model = jsonencode({
        type       = "threshold",
        expression = "query",
        refId      = "threshold",
        conditions = [{
          evaluator = { type = "gt", params = [0] }
        }]
      })
    }

    labels = {
      severity = "critical"
      service  = "platform"
      env      = "prod"
    }

    annotations = {
      summary       = "Credential-shaped string found in production logs"
      description   = <<-EOT
        A log line in prod matched a secret pattern. Treat the matched credential
        as compromised: rotate it first, find the emitting service second.
        Masking is supposed to happen at the logger (docs/15 §2.1) — this alert
        firing means a service bypassed it.
      EOT
      runbook_url   = "https://wiki.bank.internal/runbooks/secret-in-logs"
      dashboard_url = "https://grafana.bank.internal/d/payment-service"
    }

    # No notification_settings override: this follows the root policy and pages
    # as a critical. Deliberate — a leaked credential is a P1 at any hour.
    no_data_state  = "OK" # no logs matching is the good outcome, not an error
    exec_err_state = "Alerting"
  }

  # -------------------------------------------------------------------------
  rule {
    name      = "GatewayJWKSFetchFailing"
    condition = "threshold"
    # 10m: JWKS is cached, so this is not instantly customer-visible — but it
    # WILL fail every request at the next key rotation, with no deploy to blame.
    # Alert on the fetch, not the symptom. See docs/15 §5.2.
    for = "10m"

    data {
      ref_id = "query"
      relative_time_range {
        from = 600
        to   = 0
      }
      datasource_uid = "loki-prod"
      model = jsonencode({
        expr      = "sum(count_over_time({namespace=\"platform-kong\"} |= `jwks` |~ `(?i)(error|timeout|refused|unreachable)` [10m]))"
        queryType = "instant"
        refId     = "query"
      })
    }

    data {
      ref_id         = "threshold"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        type       = "threshold",
        expression = "query",
        refId      = "threshold",
        conditions = [{
          evaluator = { type = "gt", params = [3] }
        }]
      })
    }

    labels = {
      severity = "critical"
      service  = "kong"
      env      = "prod"
    }

    annotations = {
      summary     = "API gateway cannot reach Keycloak JWKS endpoint"
      description = <<-EOT
        The gateway is serving on cached signing keys. When Keycloak rotates,
        every authenticated request will 401 simultaneously with no deploy and
        no obvious cause. Check the platform-kong -> platform-keycloak egress
        NetworkPolicy and Keycloak availability BEFORE the next rotation.
      EOT
      runbook_url = "https://wiki.bank.internal/runbooks/gateway-jwks"
    }

    no_data_state  = "OK"
    exec_err_state = "Alerting"
  }
}

# ---------------------------------------------------------------------------
# Meta-monitoring: alerts about the alerting. Cheap, and the only thing that
# catches a monitoring stack that has quietly stopped working.
resource "grafana_rule_group" "meta" {
  name             = "meta-monitoring"
  folder_uid       = grafana_folder.platform.uid
  interval_seconds = 60

  rule {
    name      = "LogIngestionStalled"
    condition = "threshold"
    for       = "5m"

    data {
      ref_id = "query"
      relative_time_range {
        from = 600
        to   = 0
      }
      datasource_uid = "loki-prod"
      model = jsonencode({
        # A prod cluster that logs nothing for 10 minutes is not quiet.
        # It is broken, and every other log-based alert is now blind.
        expr      = "sum(count_over_time({env=\"prod\"} [10m]))"
        queryType = "instant"
        refId     = "query"
      })
    }

    data {
      ref_id         = "threshold"
      datasource_uid = "__expr__"
      relative_time_range {
        from = 600
        to   = 0
      }
      model = jsonencode({
        type       = "threshold",
        expression = "query",
        refId      = "threshold",
        conditions = [{
          evaluator = { type = "lt", params = [1] }
        }]
      })
    }

    labels = {
      severity = "critical"
      service  = "loki"
      env      = "prod"
    }

    annotations = {
      summary     = "No logs ingested from prod in 10 minutes"
      description = "Collectors, Loki ingesters, or the whole pipeline. Every log-based alert is currently blind."
      runbook_url = "https://wiki.bank.internal/runbooks/log-pipeline-stalled"
    }

    # NOT "OK". No data here IS the alert condition — the one rule in this file
    # where an empty result must page.
    no_data_state  = "Alerting"
    exec_err_state = "Alerting"
  }
}
