#!/usr/bin/env bash
# One-time host setup: k3s + helm + Actions Runner Controller. Safe to re-run: k3s and helm are installed only
# when missing (never upgraded here, see README), the ARC controller is upgraded to ARC_VERSION.
# Usage: sudo bash bootstrap.sh
set -euo pipefail
cd "$(dirname "$0")"
. ./versions.env
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Flags live in config.yaml (not INSTALL_K3S_EXEC) so a later installer run for an upgrade keeps them.
# Runners need no ingress or load balancer; system-reserved keeps the host responsive when CI fills it.
install -d /etc/rancher/k3s
k3s_config='disable:
  - traefik
  - servicelb
kubelet-arg:
  - system-reserved=cpu=500m,memory=1Gi'
if [ ! -e /etc/rancher/k3s/config.yaml ]; then
  printf '%s\n' "$k3s_config" > /etc/rancher/k3s/config.yaml
elif ! printf '%s\n' "$k3s_config" | cmp -s - /etc/rancher/k3s/config.yaml; then
  echo "note: /etc/rancher/k3s/config.yaml differs from bootstrap.sh's default, left as is" >&2
fi
if ! command -v k3s >/dev/null; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -
fi
for _ in $(seq 90); do
  [ -n "$(kubectl get nodes -o name 2>/dev/null)" ] && break
  sleep 2
done
kubectl wait --for=condition=Ready node --all --timeout=180s

# k3s.yaml is root-only; give the invoking user a copy so kubectl/helm work without sudo.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  group=$(id -gn "$SUDO_USER")
  if [ ! -e "$home/.kube/config" ]; then
    install -d -o "$SUDO_USER" -g "$group" -m 700 "$home/.kube"
    install -o "$SUDO_USER" -g "$group" -m 600 /etc/rancher/k3s/k3s.yaml "$home/.kube/config"
  elif ! cmp -s /etc/rancher/k3s/k3s.yaml "$home/.kube/config"; then
    echo "note: $home/.kube/config differs from /etc/rancher/k3s/k3s.yaml, left as is" >&2
  fi
  if [ -f "$home/.bashrc" ] && ! grep -q 'KUBECONFIG=' "$home/.bashrc"; then
    echo 'export KUBECONFIG=$HOME/.kube/config' >> "$home/.bashrc"
  fi
fi

if ! command -v helm >/dev/null; then
  curl -fsSL "https://raw.githubusercontent.com/helm/helm/$HELM_VERSION/scripts/get-helm-3" \
    | DESIRED_VERSION="$HELM_VERSION" HELM_INSTALL_DIR=/usr/local/bin bash
fi

helm upgrade --install arc --namespace arc-systems --create-namespace --version "$ARC_VERSION" --wait \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
kubectl -n arc-systems get pods
