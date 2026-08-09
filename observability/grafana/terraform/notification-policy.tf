# Author: Mengty LIM
# The notification policy tree — how a firing alert finds a human.
#
# Read top to bottom. The FIRST matching child policy wins unless it sets
# `continue = true`. Order is significant and is the most common source of
# "why didn't that page?" — a broad matcher above a narrow one swallows it.

resource "grafana_notification_policy" "root" {
  # Grouping determines how many notifications you get. Group too coarsely and
  # one alert hides behind another; too finely and a single incident sends 40
  # messages. service+env+alertname is the balance that survives contact with
  # a real outage.
  group_by = ["alertname", "service", "env"]

  contact_point   = grafana_contact_point.slack_unrouted.name
  group_wait      = "30s"
  group_interval  = "5m"
  repeat_interval = "4h"

  # -------------------------------------------------------------------------
  # 1. Non-prod never pages. Ever. This policy is FIRST because a P1-severity
  #    alert firing in dev must not reach PagerDuty just because the severity
  #    label happens to say critical.
  policy {
    matcher {
      label = "env"
      match = "!="
      value = "prod"
    }
    contact_point   = grafana_contact_point.slack_platform.name
    group_wait      = "5m"
    repeat_interval = "24h"
    mute_timings    = [grafana_mute_timing.non_business_hours.name]
  }

  # -------------------------------------------------------------------------
  # 2. P1 — page immediately, 24x7, no mute timings.
  policy {
    matcher {
      label = "severity"
      match = "="
      value = "critical"
    }
    contact_point = grafana_contact_point.pagerduty_p1.name
    # Short group_wait: a P1 that batches for 30s is a P1 that arrives late.
    group_wait      = "10s"
    group_interval  = "1m"
    repeat_interval = "1h"

    # Also post to Slack so the rest of the team has context without being
    # paged. `continue` is what makes both fire.
    continue = true
  }

  policy {
    matcher {
      label = "severity"
      match = "="
      value = "critical"
    }
    contact_point   = grafana_contact_point.slack_platform.name
    group_wait      = "10s"
    repeat_interval = "1h"
  }

  # -------------------------------------------------------------------------
  # 3. P2 — pages during business hours, tickets otherwise.
  policy {
    matcher {
      label = "severity"
      match = "="
      value = "warning"
    }
    contact_point   = grafana_contact_point.pagerduty_p2.name
    group_wait      = "5m"
    group_interval  = "10m"
    repeat_interval = "12h"
    mute_timings    = [grafana_mute_timing.non_business_hours.name]
  }

  # -------------------------------------------------------------------------
  # 4. Config drift gets its own low-noise channel. It is never urgent and it is
  #    always worth reading.
  policy {
    matcher {
      label = "category"
      match = "="
      value = "drift"
    }
    contact_point   = grafana_contact_point.slack_drift.name
    group_wait      = "10m"
    repeat_interval = "24h"
  }
}

# ---------------------------------------------------------------------------
resource "grafana_mute_timing" "non_business_hours" {
  name = "non-business-hours"

  intervals {
    times {
      start = "18:00"
      end   = "24:00"
    }
    weekdays = ["monday:friday"]
    location = "Asia/Phnom_Penh"
  }
  intervals {
    times {
      start = "00:00"
      end   = "09:00"
    }
    weekdays = ["monday:friday"]
    location = "Asia/Phnom_Penh"
  }
  intervals {
    weekdays = ["saturday", "sunday"]
    location = "Asia/Phnom_Penh"
  }
}

# Month-end and quarter-end settlement. Deploys are frozen (docs/09) but alerting
# is the opposite of frozen — this window exists to be REFERENCED by dashboards
# and change tooling, not to mute anything. It is deliberately not attached to
# any policy.
resource "grafana_mute_timing" "settlement_window" {
  name = "settlement-window-do-not-mute"

  intervals {
    days_of_month = ["-2:-1", "1"]
    location      = "Asia/Phnom_Penh"
  }
}
