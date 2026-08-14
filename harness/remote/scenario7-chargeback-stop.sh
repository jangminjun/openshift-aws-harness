#!/usr/bin/env bash
# Deletes the demo pods and ResourceQuota.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-chargeback-scenario-7}"

oc delete pod team-workload-1 team-workload-2 -n "${DEMO_NAMESPACE}" --ignore-not-found
oc delete resourcequota gpu-quota -n "${DEMO_NAMESPACE}" --ignore-not-found
echo "team-workload-1/2 and gpu-quota deleted."
