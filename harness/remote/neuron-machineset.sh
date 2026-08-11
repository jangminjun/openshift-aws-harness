#!/usr/bin/env bash
# Runs ON the bastion, after the cluster is up. Clones an existing worker MachineSet
# and repoints it at an AWS Inferentia2/Trainium (Neuron) instance type.
# Idempotent: skips if the Neuron MachineSet already exists.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

NEURON_INSTANCE_TYPE="${NEURON_INSTANCE_TYPE:?set NEURON_INSTANCE_TYPE}"
NEURON_REPLICAS="${NEURON_REPLICAS:-1}"
NEURON_MACHINESET_AZ="${NEURON_MACHINESET_AZ:?set NEURON_MACHINESET_AZ (must be an AZ where the instance type is offered)}"

TEMPLATE=$(oc get machineset -n openshift-machine-api -o name | grep -- "-worker-${NEURON_MACHINESET_AZ}\$")
[ -n "$TEMPLATE" ] || { echo "No worker MachineSet found for AZ ${NEURON_MACHINESET_AZ} to clone" >&2; exit 1; }

BASE_NAME=$(oc get "$TEMPLATE" -n openshift-machine-api -o jsonpath='{.metadata.name}')
NEURON_NAME="${BASE_NAME%-worker-*}-npu-worker-$(oc get "$TEMPLATE" -n openshift-machine-api -o jsonpath='{.metadata.name}' | awk -F- '{print $NF}')"

if oc get machineset "$NEURON_NAME" -n openshift-machine-api >/dev/null 2>&1; then
  echo "Neuron MachineSet $NEURON_NAME already exists. Skipping."
  exit 0
fi

oc get "$TEMPLATE" -n openshift-machine-api -o json \
  | jq --arg name "$NEURON_NAME" --arg itype "$NEURON_INSTANCE_TYPE" --argjson replicas "$NEURON_REPLICAS" '
    .metadata.name = $name
    | .spec.replicas = $replicas
    | .spec.selector.matchLabels["machine.openshift.io/cluster-api-machineset"] = $name
    | .spec.template.metadata.labels["machine.openshift.io/cluster-api-machineset"] = $name
    | .spec.template.spec.providerSpec.value.instanceType = $itype
    | .spec.template.spec.taints = [{"key":"aws.amazon.com/neuron","value":"","effect":"NoSchedule"}]
    | del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.generation, .status)
  ' | oc create -f -

echo "Created Neuron MachineSet $NEURON_NAME ($NEURON_INSTANCE_TYPE x $NEURON_REPLICAS)"
echo "Waiting for node to join (this can take several minutes)..."
for _ in $(seq 1 60); do
  ready=$(oc get machineset "$NEURON_NAME" -n openshift-machine-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  [ "$ready" = "$NEURON_REPLICAS" ] && { echo "Neuron MachineSet ready."; exit 0; }
  sleep 15
done
echo "Neuron MachineSet not ready yet, check 'oc get machineset -n openshift-machine-api' later."
