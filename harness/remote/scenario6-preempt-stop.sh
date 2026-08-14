#!/usr/bin/env bash
# Deletes both pods and restores the MachineAutoscaler max that
# scenario6-preempt-start.sh capped.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-preempt-scenario-6}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.2xlarge}"
RESTORE_MAX="${RESTORE_MAX:-2}"

oc delete pod bad-code-workload legitimate-workload -n "${DEMO_NAMESPACE}" --ignore-not-found

TYPE_TAG=$(echo "$INSTANCE_TYPE" | tr '.' '-')
MACHINESET=$(oc get machineset -n openshift-machine-api -o name | grep -- "-gpu-${TYPE_TAG}-us-east-1a\$" | sed 's#.*/##' || true)
if [ -n "$MACHINESET" ]; then
  AUTOSCALER=$(echo "$MACHINESET" | sed -E 's/^[a-z0-9]+-[a-z0-9]+-//')
  oc patch machineautoscaler "$AUTOSCALER" -n openshift-machine-api --type merge -p "{\"spec\":{\"maxReplicas\":${RESTORE_MAX}}}" || true
  echo "MachineAutoscaler/${AUTOSCALER} max restored to ${RESTORE_MAX}."
fi

echo "bad-code-workload and legitimate-workload deleted."
