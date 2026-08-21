#!/usr/bin/env bash
# Deletes the bad-code / efficient / more-efficient workload comparison
# pods. Leaves the scenario5-metrics Service/ServiceMonitor in place
# (cluster-scoped-ish, reusable across re-runs).
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-badcode-scenario-5}"
oc delete pod bad-code-workload efficient-workload more-efficient-workload -n "${DEMO_NAMESPACE}" --ignore-not-found
echo "bad-code-workload, efficient-workload, and more-efficient-workload deleted."
