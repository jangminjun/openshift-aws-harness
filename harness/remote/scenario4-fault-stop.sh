#!/usr/bin/env bash
# Deletes the fault-workload Deployment and uncordons any GPU node left
# SchedulingDisabled by scenario4-fault-trigger.sh, resetting the cluster
# back to a clean state for the next demo run.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-fault-scenario-4}"

oc delete deployment fault-workload -n "${DEMO_NAMESPACE}" --ignore-not-found

for NODE in $(oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[*].metadata.name}'); do
  if oc get node "$NODE" -o jsonpath='{.spec.unschedulable}' 2>/dev/null | grep -q true; then
    oc adm uncordon "$NODE"
  fi
done

echo "fault-workload deleted, GPU nodes uncordoned."
