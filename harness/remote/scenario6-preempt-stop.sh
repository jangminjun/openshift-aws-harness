#!/usr/bin/env bash
# Deletes both pods and restores the MachineAutoscaler max that
# scenario6-preempt-start.sh capped.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-preempt-scenario-6}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g4dn.xlarge}"
RESTORE_MAX="${RESTORE_MAX:-1}"

oc delete pod low-priority-workload high-priority-workload -n "${DEMO_NAMESPACE}" --ignore-not-found

# MachineSet found via the node's own Machine/MachineSet ownership, not a
# name-pattern match against INSTANCE_TYPE -- see scenario6-preempt-start.sh
# for why (MachineSet metadata.name doesn't track instanceType resizes).
NODE_FOR_TYPE=$(oc get nodes -l "node.kubernetes.io/instance-type=${INSTANCE_TYPE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
MACHINESET=""
if [ -n "$NODE_FOR_TYPE" ]; then
  MACHINE_REF=$(oc get node "$NODE_FOR_TYPE" -o jsonpath='{.metadata.annotations.machine\.openshift\.io/machine}' 2>/dev/null || true)
  [ -n "$MACHINE_REF" ] && MACHINESET=$(oc get machine "${MACHINE_REF#*/}" -n openshift-machine-api -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)
fi
if [ -n "$MACHINESET" ]; then
  AUTOSCALER=$(echo "$MACHINESET" | sed -E 's/^[a-z0-9]+-[a-z0-9]+-//')
  oc patch machineautoscaler "$AUTOSCALER" -n openshift-machine-api --type merge -p "{\"spec\":{\"maxReplicas\":${RESTORE_MAX}}}" || true
  echo "MachineAutoscaler/${AUTOSCALER} max restored to ${RESTORE_MAX}."
fi

echo "low-priority-workload and high-priority-workload deleted."
