#!/usr/bin/env bash
#
# The promotion mechanism. Deploying to an environment means committing a new
# image digest to that environment's overlay — nothing else.
#
#   bump-digest.sh <gitops-repo-dir> <overlay-path> <image-digest> [--open-mr]
#
# For dev/uat this commits straight to main. For prod it opens an MR so a human
# with prod rights performs the merge: the CI runner must never be able to
# change production on its own (docs/05-cicd-automation.md §8).
set -euo pipefail

REPO_DIR="${1:?gitops repo directory required}"
OVERLAY="${2:?overlay path required, e.g. business/payment-service/overlays/prod}"
DIGEST="${3:?image digest required, e.g. sha256:abc...}"
OPEN_MR="${4:-}"

KUSTOMIZATION="${REPO_DIR}/${OVERLAY}/kustomization.yaml"
ENVIRONMENT="$(basename "${OVERLAY}")"
SERVICE="$(basename "$(dirname "$(dirname "${OVERLAY}")")")"

# --- validate ---------------------------------------------------------------
[[ -f "${KUSTOMIZATION}" ]] || { echo "No kustomization at ${KUSTOMIZATION}"; exit 1; }

# A digest is immutable; a tag is not. Refuse anything that is not a digest.
[[ "${DIGEST}" =~ ^sha256:[a-f0-9]{64}$ ]] || {
  echo "ERROR: '${DIGEST}' is not a sha256 digest. Tags are not promotable."
  exit 1
}

CURRENT="$(yq -r ".images[] | select(.name == \"${SERVICE}\") | .digest // \"none\"" "${KUSTOMIZATION}")"
if [[ "${CURRENT}" == "${DIGEST}" ]]; then
  echo "Already at ${DIGEST} — nothing to promote."
  exit 0
fi

# --- promote ----------------------------------------------------------------
echo "Promoting ${SERVICE} to ${ENVIRONMENT}"
echo "  from: ${CURRENT}"
echo "    to: ${DIGEST}"

cd "${REPO_DIR}"
BRANCH="promote/${SERVICE}-${ENVIRONMENT}-${DIGEST:7:12}"

yq -i "(.images[] | select(.name == \"${SERVICE}\")).digest = \"${DIGEST}\"" "${OVERLAY}/kustomization.yaml"

# Prove the result still renders before committing. A broken overlay committed
# to main blocks every other service's deploys until someone notices.
kustomize build "${OVERLAY}" > /dev/null || {
  echo "ERROR: overlay does not render after the bump — aborting"
  git checkout -- "${OVERLAY}/kustomization.yaml"
  exit 1
}

git config user.name  "gitlab-ci"
git config user.email "ci@bank.internal"

COMMIT_MSG="promote(${SERVICE}): ${ENVIRONMENT} -> ${DIGEST:0:19}

Source pipeline: ${CI_PIPELINE_URL:-manual}
Source commit:   ${CI_COMMIT_SHA:-unknown}
Previous digest: ${CURRENT}
Change ticket:   ${CHANGE_TICKET:-none}

Rollback: revert this commit; ArgoCD reconciles within 3 minutes."

if [[ "${ENVIRONMENT}" == "prod" || "${OPEN_MR}" == "--open-mr" ]]; then
  # Production: open an MR. The runner proposes; a human disposes.
  git checkout -b "${BRANCH}"
  git commit -am "${COMMIT_MSG}"
  git push origin "${BRANCH}" \
    -o merge_request.create \
    -o merge_request.target=main \
    -o merge_request.title="Promote ${SERVICE} to ${ENVIRONMENT}" \
    -o merge_request.description="${COMMIT_MSG}" \
    -o merge_request.label="promotion" \
    -o merge_request.label="${ENVIRONMENT}"
  echo "Merge request opened. Prod deploys require two approvals."
else
  # Lower environments: commit directly. Retry on a race with a concurrent
  # promotion of a different service.
  for attempt in 1 2 3; do
    git commit -am "${COMMIT_MSG}" || true
    if git push origin HEAD:main; then
      echo "Promoted. ArgoCD will sync within 3 minutes."
      exit 0
    fi
    echo "Push rejected (attempt ${attempt}); rebasing and retrying"
    git pull --rebase origin main
  done
  echo "ERROR: could not push after 3 attempts"
  exit 1
fi
