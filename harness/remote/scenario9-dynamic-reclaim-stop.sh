#!/usr/bin/env bash
# Cleans up scenario 9 (whether or not the trigger already reclaimed
# dynamic-workload) and force-resets the MachineSet back to 1 replica, same
# as scenario 1's stop script -- so a back-to-back re-run of this demo (or
# scenario 1) doesn't start from an already-scaled-out MachineSet.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-dynamic-scenario-9}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.2xlarge}"

oc delete pod anchor-workload dynamic-workload -n "${DEMO_NAMESPACE}" --ignore-not-found

MACHINESET=$(oc get machineset -n openshift-machine-api -o name | grep "${INSTANCE_TYPE//./-}" | head -1)
if [ -n "$MACHINESET" ]; then
  oc scale "$MACHINESET" -n openshift-machine-api --replicas=1
  echo "${MACHINESET} reset to 1 replica."
fi

echo "scenario9 stopped."
