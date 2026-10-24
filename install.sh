#!/usr/bin/env bash
# Installs/updates every runner scale set in scale-sets/ (release name = file name). Run after bootstrap.sh.
# Usage: sudo bash install.sh    (asks for the GitHub PAT when the secret is missing)
#        GH_PAT=... sudo -E bash install.sh    (without a terminal, or to replace the token)
set -euo pipefail
cd "$(dirname "$0")"
. ./versions.env
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS=arc-runners

# The runner image runs as uid 1001; npm cache is shared by the bibg-light pods.
install -d -o 1001 -g 1001 /var/lib/bibg-ci/npm-cache
install -d /var/lib/bibg-ci/heavy-docker

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
if [ -n "${GH_PAT:-}" ] || ! kubectl -n "$NS" get secret arc-github >/dev/null 2>&1; then
  # Prompt instead of an env var so the token stays out of shell history.
  if [ -z "${GH_PAT:-}" ]; then
    [ -t 0 ] || { echo "no terminal to ask for the PAT: pass GH_PAT (see usage)" >&2; exit 1; }
    read -rsp "GitHub classic PAT (admin:org): " GH_PAT; echo
    [ -n "$GH_PAT" ] || { echo "empty PAT" >&2; exit 1; }
  fi
  # Via stdin so the token never shows up in the process list.
  printf %s "$GH_PAT" | kubectl -n "$NS" create secret generic arc-github --from-file=github_token=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -
fi
# BuildKit cache in the persistent bibg-heavy daemon is trimmed to this size.
kubectl -n "$NS" create configmap bibg-heavy-docker \
  --from-literal=daemon.json='{"builder":{"gc":{"enabled":true,"defaultKeepStorage":"40GB"}}}' \
  --dry-run=client -o yaml | kubectl apply -f -

for f in scale-sets/*.yaml; do
  helm upgrade --install "$(basename "$f" .yaml)" --namespace "$NS" --version "$ARC_VERSION" -f "$f" \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
done
kubectl -n arc-systems get pods
