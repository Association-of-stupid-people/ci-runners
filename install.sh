#!/usr/bin/env bash
# Installs/updates every runner scale set in scale-sets/ (release name = file name) and the ci-<C>c-<G>g sets from
# CI_SIZES in config.env. Run after bootstrap.sh.
# Usage: sudo bash install.sh    (asks for the GitHub PAT when the secret is missing)
#        GH_PAT=... sudo -E bash install.sh    (automation / replacing the token; lands in shell history)
set -euo pipefail
cd "$(dirname "$0")"
. ./versions.env
. ./config.env
for s in ${CI_SIZES-}; do
  c=${s%%c*}; g=${s#*c}; g=${g%g}
  case "$s:$c:$g" in *c*g:[1-9]*:[1-9]*) ;; *) c=x ;; esac
  case "$c$g" in *[!0-9]*) echo "bad CI_SIZES entry: $s (<cores>c<GiB>g, e.g. \"2c2g 4c8g\")" >&2; exit 1 ;; esac
done
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

CHART=oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
for f in scale-sets/*.yaml; do
  helm upgrade --install "$(basename "$f" .yaml)" --namespace "$NS" --version "$ARC_VERSION" -f "$f" \
    --set githubConfigUrl="$GITHUB_CONFIG_URL" "$CHART"
done

# Sized sets ci-<C>c-<G>g: request = limit for CPU and memory (Guaranteed QoS). maxRunners = how many pods of that
# size the node fits on its own; when sizes are mixed the scheduler keeps the extra pods Pending (their jobs wait)
# until cores and memory free up. 512 MiB / 500m are left for system pods (coredns, metrics-server, ...).
mem=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}')
mem_b=$(numfmt --from=auto "$mem")
alloc_mib=$(( mem_b / 1048576 - 512 ))
cpu=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}')
case "$cpu" in *m) cpu_m=${cpu%m} ;; ''|*[!0-9]*) echo "unexpected allocatable cpu: $cpu" >&2; exit 1 ;; *) cpu_m=$(( cpu * 1000 )) ;; esac
cpu_m=$(( cpu_m - 500 ))
for s in ${CI_SIZES-}; do
  c=${s%%c*}; g=${s#*c}; g=${g%g}
  name="ci-${c}c-${g}g"
  max=$(( alloc_mib / (g * 1024) ))
  if [ $(( cpu_m / (c * 1000) )) -lt "$max" ]; then max=$(( cpu_m / (c * 1000) )); fi
  [ "$max" -ge 1 ] || { echo "skip $name: node has only ${cpu_m}m CPU / ${alloc_mib} MiB allocatable" >&2; continue; }
  # maxRunners must stay --set (int): as a string the chart drops it, which means unlimited.
  helm upgrade --install "$name" --namespace "$NS" --version "$ARC_VERSION" -f sized.yaml \
    --set githubConfigUrl="$GITHUB_CONFIG_URL" --set runnerScaleSetName="$name" --set maxRunners="$max" \
    --set-string template.spec.resources.requests.cpu="$c" --set-string template.spec.resources.limits.cpu="$c" \
    --set-string template.spec.resources.requests.memory="${g}Gi" \
    --set-string template.spec.resources.limits.memory="${g}Gi" "$CHART"
done
kubectl -n arc-systems get pods
