#!/usr/bin/env bash
# Deletes the bad-code / efficient workload comparison pods.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-badcode-scenario-5}"
oc delete pod bad-code-workload efficient-workload -n "${DEMO_NAMESPACE}" --ignore-not-found
echo "bad-code-workload and efficient-workload deleted."
