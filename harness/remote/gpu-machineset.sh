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
GPU_MIN_REPLICAS="${GPU_MIN_REPLICAS:-1}"
GPU_MAX_REPLICAS="${GPU_MAX_REPLICAS:-2}"
TYPE_TAG=$(echo "$GPU_INSTANCE_TYPE" | tr '.' '-')

# Cluster-wide autoscaler singleton; cheap no-op via oc apply if already there.
oc apply -f - <<YAML
apiVersion: autoscaling.openshift.io/v1
kind: ClusterAutoscaler
metadata:
  name: default
spec:
  resourceLimits:
    maxNodesTotal: ${MAX_NODES_TOTAL:-20}
  scaleDown:
    enabled: true
    delayAfterAdd: 10m
    delayAfterDelete: 5m
    delayAfterFailure: 3m
    unneededTime: 10m
YAML

apply_gpu_autoscaler() {
  local ms_name="$1" autoscaler_name
  autoscaler_name=$(echo "$ms_name" | sed -E 's/^[a-z0-9]+-[a-z0-9]+-//')
  oc apply -f - <<YAML
apiVersion: autoscaling.openshift.io/v1beta1
kind: MachineAutoscaler
metadata:
  name: ${autoscaler_name}
  namespace: openshift-machine-api
spec:
  minReplicas: ${GPU_MIN_REPLICAS}
  maxReplicas: ${GPU_MAX_REPLICAS}
  scaleTargetRef:
    apiVersion: machine.openshift.io/v1beta1
    kind: MachineSet
    name: ${ms_name}
YAML
  echo "MachineAutoscaler/${autoscaler_name} -> ${ms_name} (min=${GPU_MIN_REPLICAS}, max=${GPU_MAX_REPLICAS})"
}

TEMPLATE=$(oc get machineset -n openshift-machine-api -o name | grep -- "-worker-${GPU_MACHINESET_AZ}\$")
[ -n "$TEMPLATE" ] || { echo "No plain worker MachineSet found for AZ ${GPU_MACHINESET_AZ} to clone" >&2; exit 1; }

BASE_NAME=$(oc get "$TEMPLATE" -n openshift-machine-api -o jsonpath='{.metadata.name}')
GPU_NAME="${BASE_NAME%-worker-*}-gpu-${TYPE_TAG}-${GPU_MACHINESET_AZ}"

if oc get machineset "$GPU_NAME" -n openshift-machine-api >/dev/null 2>&1; then
  echo "GPU MachineSet $GPU_NAME already exists. Skipping."
  apply_gpu_autoscaler "$GPU_NAME"
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
apply_gpu_autoscaler "$GPU_NAME"
echo "Waiting for node to join (this can take several minutes)..."
for _ in $(seq 1 60); do
  ready=$(oc get machineset "$GPU_NAME" -n openshift-machine-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  [ "$ready" = "$GPU_REPLICAS" ] && { echo "GPU MachineSet ready."; exit 0; }
  sleep 15
done
echo "GPU MachineSet not ready yet, check 'oc get machineset -n openshift-machine-api' later."
