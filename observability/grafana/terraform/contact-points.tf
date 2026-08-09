# Contact points — where a notification physically goes.
#
# Every integration key here comes from Vault. This file is the reason alerting
# is provisioned with Terraform rather than with YAML files: file provisioning
# would require these secrets in git. See provisioning/alerting/README.md.

resource "grafana_contact_point" "pagerduty_p1" {
  name = "pagerduty-p1"

  pagerduty {
    integration_key = data.vault_kv_secret_v2.pagerduty.data["p1_integration_key"]
    severity        = "critical"
    class           = "platform"
    component       = "{{ .CommonLabels.service }}"
    group           = "{{ .CommonLabels.env }}"
    # The summary is what a woken engineer reads first. Service and environment
    # up front, so they know whether to get out of bed before finishing the line.
    summary = "[{{ .CommonLabels.env }}] {{ .CommonLabels.service }}: {{ .CommonAnnotations.summary }}"
  }
}

resource "grafana_contact_point" "pagerduty_p2" {
  name = "pagerduty-p2"

  pagerduty {
    integration_key = data.vault_kv_secret_v2.pagerduty.data["p2_integration_key"]
    severity        = "warning"
    class           = "platform"
    summary         = "[{{ .CommonLabels.env }}] {{ .CommonLabels.service }}: {{ .CommonAnnotations.summary }}"
  }
}

resource "grafana_contact_point" "slack_platform" {
  name = "slack-platform"

  slack {
    url   = data.vault_kv_secret_v2.slack.data["platform_webhook"]
    title = "{{ .Status | toUpper }}: {{ .CommonLabels.alertname }}"
    # The runbook link is in the message body, not buried in an alert detail
    # page three clicks away. An alert without a runbook link is an alert that
    # gets escalated to whoever wrote the service.
    text = <<-EOT
      *{{ .CommonLabels.service }}* in *{{ .CommonLabels.env }}*
      {{ .CommonAnnotations.description }}
      <{{ .CommonAnnotations.runbook_url }}|Runbook> · <{{ .CommonAnnotations.dashboard_url }}|Dashboard>
    EOT
  }
}

resource "grafana_contact_point" "slack_drift" {
  name = "slack-drift"

  slack {
    url   = data.vault_kv_secret_v2.slack.data["drift_webhook"]
    title = "Config drift: {{ .CommonLabels.alertname }}"
    text  = "{{ .CommonAnnotations.description }}"
  }
}

# The default receiver. It exists so that a mis-labelled alert lands SOMEWHERE
# a human looks, rather than being silently dropped by the routing tree.
# Alerts arriving here are a bug — see the AlertMissingSeverityLabel rule.
resource "grafana_contact_point" "slack_unrouted" {
  name = "slack-unrouted"

  slack {
    url   = data.vault_kv_secret_v2.slack.data["unrouted_webhook"]
    title = "UNROUTED ALERT — this alert is missing routing labels"
    text  = <<-EOT
      {{ .CommonLabels.alertname }} reached the default receiver.
      It is missing a `severity` and/or `service` label. Fix the rule.
      {{ .CommonAnnotations.description }}
    EOT
  }
}
