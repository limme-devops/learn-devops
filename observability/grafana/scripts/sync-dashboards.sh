#!/usr/bin/env bash
# Author: Mengty LIM
#
# Sync dashboard JSON from git into Grafana via the HTTP API.
# Runs in CI on merge to main. Idempotent — safe to re-run.
#
#   ./sync-dashboards.sh [--dry-run]
#
# Requires: GRAFANA_URL, GRAFANA_TOKEN (service-account token, Editor on the
# target folders). In CI the token comes from Vault via OIDC — never a CI
# variable. See docs/14-promotion-procedure.md §4.
#
set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

: "${GRAFANA_URL:?GRAFANA_URL is required}"
: "${GRAFANA_TOKEN:?GRAFANA_TOKEN is required}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DASHBOARD_DIR="${REPO_ROOT}/observability/grafana/dashboards"

# Directory name -> folder UID. Must match terraform/folders.tf and
# provisioning/dashboards/providers.yaml. Three places, one value; a mismatch
# silently files dashboards into "General" where nobody looks.
declare -A FOLDERS=(
  ["services"]="services"
  ["platform"]="platform"
  ["security"]="security"
)

fail=0
count=0

for dir in "${!FOLDERS[@]}"; do
  folder_uid="${FOLDERS[$dir]}"
  [[ -d "${DASHBOARD_DIR}/${dir}" ]] || continue

  for file in "${DASHBOARD_DIR}/${dir}"/*.json; do
    [[ -e "$file" ]] || continue
    name="$(basename "$file")"

    # --- Validate before sending -------------------------------------------
    if ! jq empty "$file" 2>/dev/null; then
      echo "INVALID JSON: ${dir}/${name}"
      fail=1
      continue
    fi

    # A dashboard must have a pinned uid. Without one, every sync creates a
    # NEW dashboard instead of updating the existing one, and you end up with
    # fourteen copies of the payments dashboard.
    if [[ "$(jq -r '.uid // empty' "$file")" == "" ]]; then
      echo "MISSING uid: ${dir}/${name}"
      fail=1
      continue
    fi

    # Every panel must name its datasource explicitly. A panel that inherits
    # the default renders fine in the authoring instance and breaks on rebuild.
    if jq -e '[.panels[]? | select(.datasource == null)] | length > 0' "$file" >/dev/null; then
      echo "PANEL WITHOUT DATASOURCE: ${dir}/${name}"
      fail=1
      continue
    fi

    if $DRY_RUN; then
      echo "would sync: ${dir}/${name} -> folder ${folder_uid}"
      count=$((count + 1))
      continue
    fi

    # --- Push ---------------------------------------------------------------
    # id: null is essential. A dashboard exported from one Grafana carries an
    # `id` that refers to a DIFFERENT dashboard in another instance. Leaving it
    # in is how an import overwrites the wrong dashboard.
    payload="$(jq --arg folder "$folder_uid" \
      '{dashboard: (. + {id: null}), folderUid: $folder, overwrite: true,
        message: "synced from git"}' "$file")"

    if ! curl -sfS -X POST "${GRAFANA_URL}/api/dashboards/db" \
        -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
        -H 'Content-Type: application/json' \
        --data "$payload" > /dev/null; then
      echo "SYNC FAILED: ${dir}/${name}"
      fail=1
      continue
    fi

    echo "synced: ${dir}/${name}"
    count=$((count + 1))
  done
done

if [[ $fail -ne 0 ]]; then
  echo
  echo "One or more dashboards failed. Nothing is retried automatically —"
  echo "a partially-synced dashboard set is worse than a stale one."
  exit 1
fi

echo
echo "OK — ${count} dashboard(s) processed."
