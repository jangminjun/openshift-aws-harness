#!/usr/bin/env bash
# Runs ON the bastion, after the cluster is up. Clones an existing worker MachineSet
# and repoints it at a GPU instance type. Idempotent: skips if a MachineSet for that
# exact instance type already exists. Safe to run repeatedly with different
# GPU_INSTANCE_TYPE values to add multiple GPU flavors side by side.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:?set GPU_INSTANCE_TYPE}"
GPU_REPLICAS="${GPU_REPLICAS:-1}"
GPU_MACHINESET_AZ="${GPU_MACHINESET_AZ:?set GPU_MACHINESET_AZ (must be an AZ where the instance type is offered)}"
TYPE_TAG=$(echo "$GPU_INSTANCE_TYPE" | tr '.' '-')

TEMPLATE=$(oc get machineset -n openshift-machine-api -o name | grep -- "-worker-${GPU_MACHINESET_AZ}\$")
[ -n "$TEMPLATE" ] || { echo "No plain worker MachineSet found for AZ ${GPU_MACHINESET_AZ} to clone" >&2; exit 1; }

BASE_NAME=$(oc get "$TEMPLATE" -n openshift-machine-api -o jsonpath='{.metadata.name}')
GPU_NAME="${BASE_NAME%-worker-*}-gpu-${TYPE_TAG}-${GPU_MACHINESET_AZ}"

if oc get machineset "$GPU_NAME" -n openshift-machine-api >/dev/null 2>&1; then
  echo "GPU MachineSet $GPU_NAME already exists. Skipping."
  exit 0
fi

oc get "$TEMPLATE" -n openshift-machine-api -o json \
  | jq --arg name "$GPU_NAME" --arg itype "$GPU_INSTANCE_TYPE" --argjson replicas "$GPU_REPLICAS" '
    .metadata.name = $name
    | .spec.replicas = $replicas
    | .spec.selector.matchLabels["machine.openshift.io/cluster-api-machineset"] = $name
    | .spec.template.metadata.labels["machine.openshift.io/cluster-api-machineset"] = $name
    | .spec.template.spec.providerSpec.value.instanceType = $itype
    | .spec.template.spec.taints = [{"key":"nvidia.com/gpu","value":"","effect":"NoSchedule"}]
    | del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.generation, .status)
  ' | oc create -f -

echo "Created GPU MachineSet $GPU_NAME ($GPU_INSTANCE_TYPE x $GPU_REPLICAS)"
echo "Waiting for node to join (this can take several minutes)..."
for _ in $(seq 1 60); do
  ready=$(oc get machineset "$GPU_NAME" -n openshift-machine-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  [ "$ready" = "$GPU_REPLICAS" ] && { echo "GPU MachineSet ready."; exit 0; }
  sleep 15
done
echo "GPU MachineSet not ready yet, check 'oc get machineset -n openshift-machine-api' later."
