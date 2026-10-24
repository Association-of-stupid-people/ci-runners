#!/usr/bin/env bash
# Full setup of a runner host in one command: k3s + helm + ARC controller, then all scale sets.
# Usage: sudo bash setup.sh    (GH_PAT=... sudo -E bash setup.sh without a terminal)
set -euo pipefail
cd "$(dirname "$0")"
bash bootstrap.sh
bash install.sh
