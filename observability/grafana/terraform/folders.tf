# Folders and permissions.
#
# Folder UIDs are pinned and must match:
#   - provisioning/dashboards/providers.yaml  (folderUid:)
#   - scripts/sync-dashboards.sh              (FOLDER_UID)
# An auto-generated UID breaks both on the first rebuild.

resource "grafana_folder" "platform" {
  title = "Platform"
  uid   = "platform"
}

resource "grafana_folder" "services" {
  title = "Services"
  uid   = "services"
}

resource "grafana_folder" "security" {
  title = "Security & Audit"
  uid   = "security"
}

# ---------------------------------------------------------------------------
# Teams. Membership is NOT managed here — it is synced from Keycloak groups via
# Grafana's OIDC team_sync. Managing members in Terraform means a leaver keeps
# access until someone remembers to run an apply.
resource "grafana_team" "this" {
  for_each = var.teams

  name = each.key
  # Explicitly empty: the identity provider owns this list.
  members = []

  lifecycle {
    ignore_changes = [members]
  }
}

# ---------------------------------------------------------------------------
# Permissions. Default posture: everyone can read, the owning team can edit,
# nobody gets Admin on a folder except the platform team.
resource "grafana_folder_permission" "services" {
  folder_uid = grafana_folder.services.uid

  permissions {
    role       = "Viewer"
    permission = "View"
  }
  permissions {
    team_id    = grafana_team.this["payments"].id
    permission = "Edit"
  }
  permissions {
    team_id    = grafana_team.this["platform"].id
    permission = "Admin"
  }
}

resource "grafana_folder_permission" "platform" {
  folder_uid = grafana_folder.platform.uid

  permissions {
    role       = "Viewer"
    permission = "View"
  }
  permissions {
    team_id    = grafana_team.this["platform"].id
    permission = "Admin"
  }
}

# Security folder is NOT world-readable. It renders audit-log trends from the
# Elasticsearch datasource, and routine engineering access to audit data is
# exactly what §3.2 of docs/15 restricts. No `role = "Viewer"` block here —
# that omission is the control.
resource "grafana_folder_permission" "security" {
  folder_uid = grafana_folder.security.uid

  permissions {
    team_id    = grafana_team.this["platform"].id
    permission = "View"
  }
}
