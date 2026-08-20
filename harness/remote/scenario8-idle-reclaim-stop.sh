#!/usr/bin/env bash
# Cleans up scenario 8, whether or not the trigger already reclaimed the pod.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-idle-scenario-8}"

oc delete pod idle-workload -n "${DEMO_NAMESPACE}" --ignore-not-found
echo "idle-workload deleted (if it was still there)."
