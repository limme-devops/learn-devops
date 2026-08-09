#!/usr/bin/env bash
# Author: Mengty LIM
#
# Bring the local lab to a state where the manifests in gitops/ actually apply.
# Deliberately installs the *enforcing* components (Cilium, Kyverno, Argo
# Rollouts) — a lab without policy enforcement will happily run manifests that
# production rejects, which is the opposite of useful.
#
#   make lab-up
set -euo pipefail

CLUSTER="learn-devops"
CTX="kind-${CLUSTER}"

log() { printf '\n==> %s\n' "$*"; }
need() { command -v "$1" >/dev/null || { echo "Missing required tool: $1"; exit 1; }; }

for tool in kind kubectl helm kustomize; do need "$tool"; done

kubectl config use-context "${CTX}"

# --- CNI: required, since kind-cluster.yaml disables the default one ---------
log "Installing Cilium (NetworkPolicy enforcement + kube-proxy replacement)"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.16.3 \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="${CLUSTER}-control-plane" \
  --set k8sServicePort=6443 \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --wait --timeout 5m

kubectl wait --for=condition=Ready nodes --all --timeout=300s

# --- Ingress ----------------------------------------------------------------
log "Installing ingress-nginx"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

# --- Admission policy -------------------------------------------------------
log "Installing Kyverno"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --set replicaCount=1 \
  --wait --timeout 5m

# --- Progressive delivery ---------------------------------------------------
log "Installing Argo Rollouts"
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

log "Installing Argo CD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --namespace argocd \
  --for=condition=available deployment --all --timeout=600s

# --- Namespace with the same guardrails as production -----------------------
log "Creating app-payment namespace with Pod Security Admission"
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: app-payment
  labels:
    kubernetes.io/metadata.name: app-payment
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
EOF

log "Applying Kyverno policies in Audit mode"
# Audit, not Enforce, locally: the lab has no Harbor and no Cosign signatures,
# so image-signature enforcement would block everything. You still SEE the
# violations, which is the teaching value.
kustomize build ../security/kyverno 2>/dev/null \
  || sed 's/validationFailureAction: Enforce/validationFailureAction: Audit/' \
       ../security/kyverno/baseline-policies.yaml | kubectl apply -f -

cat <<'EOF'

Lab is up.

  kubectl get nodes --show-labels
  kubectl get pods -A

Try the manifests:
  kustomize build gitops/business/payment-service/overlays/dev | kubectl apply -f -

See what policy would have blocked in production:
  kubectl get policyreport -A

Watch a canary rollout:
  kubectl argo rollouts get rollout payment-service -n app-payment --watch

Argo CD UI:
  kubectl port-forward svc/argocd-server -n argocd 8081:443
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

Tear down:  make lab-down
EOF
