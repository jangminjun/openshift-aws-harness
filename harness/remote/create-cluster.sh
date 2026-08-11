#!/usr/bin/env bash
# Runs ON the bastion. Idempotent: skips if an install is already running or finished.
set -euo pipefail
cd ~/ocp-install

if [ -f metadata.json ]; then
  echo "metadata.json already present - cluster already created (or in progress). Skipping."
  exit 0
fi

if pgrep -f "openshift-install create cluster" >/dev/null 2>&1; then
  echo "openshift-install is already running in the background."
  exit 0
fi

[ -f install-config.yaml ] || { echo "install-config.yaml missing, run 'install-config' first" >&2; exit 1; }

nohup openshift-install create cluster --dir="$HOME/ocp-install" --log-level=info \
  > "$HOME/ocp-install/install.log" 2>&1 < /dev/null &
disown
sleep 2
echo "openshift-install started in background (pid $(pgrep -f 'openshift-install create cluster' | head -1))"
