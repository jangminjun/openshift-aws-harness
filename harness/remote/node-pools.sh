#!/usr/bin/env bash
# Runs ON the bastion, after the cluster is up (and ideally after
# gpu-machineset, so GPU nodes already exist to retroactively label).
# Creates 3 new 1-node-each MachineSets (router/infra/oai) by cloning the
# plain worker MachineSet template for NODE_POOL_AZ, the same way
# gpu-machineset.sh clones it for GPU flavors -- and retroactively labels
# already-Ready plain-worker and GPU nodes as cpu-worker/gpu-worker so
# `oc get nodes` shows a clean 5-way role split:
#   router / infra / oai / cpu-worker / gpu-worker
# Each new MachineSet's nodes get BOTH a node-role.kubernetes.io/<role>
# label (so `oc get nodes` shows it and nodeSelectors can target it -- the
# standard OpenShift "infrastructure node" convention) and a matching
# NoSchedule taint (so nothing lands there without an explicit toleration --
# see node-placement.sh for the workloads that get one). cpu-worker gets a
# label only, no taint -- it stays the default scheduling target for
# untargeted/general workloads. Idempotent.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

NODE_POOL_INSTANCE_TYPE="${NODE_POOL_INSTANCE_TYPE:-m5.xlarge}"
NODE_POOL_AZ="${NODE_POOL_AZ:?set NODE_POOL_AZ (must be an AZ where NODE_POOL_INSTANCE_TYPE is offered)}"

TEMPLATE=$(oc get machineset -n openshift-machine-api -o name | grep -- "-worker-${NODE_POOL_AZ}\$")
[ -n "$TEMPLATE" ] || { echo "No plain worker MachineSet found for AZ ${NODE_POOL_AZ} to clone" >&2; exit 1; }
BASE_NAME=$(oc get "$TEMPLATE" -n openshift-machine-api -o jsonpath='{.metadata.name}')

create_role_machineset() {
  local role="$1" ms_name="${BASE_NAME%-worker-*}-${1}-${NODE_POOL_AZ}"

  if oc get machineset "$ms_name" -n openshift-machine-api >/dev/null 2>&1; then
    echo "MachineSet $ms_name already exists. Skipping."
    return 0
  fi

  oc get "$TEMPLATE" -n openshift-machine-api -o json \
    | jq --arg name "$ms_name" --arg itype "$NODE_POOL_INSTANCE_TYPE" --arg role "$role" '
      .metadata.name = $name
      | .spec.replicas = 1
      | .spec.selector.matchLabels["machine.openshift.io/cluster-api-machineset"] = $name
      | .spec.template.metadata.labels["machine.openshift.io/cluster-api-machineset"] = $name
      | .spec.template.spec.providerSpec.value.instanceType = $itype
      | .spec.template.spec.metadata.labels[("node-role.kubernetes.io/" + $role)] = ""
      | .spec.template.spec.taints = [{"key":("node-role.kubernetes.io/" + $role),"value":"","effect":"NoSchedule"}]
      | del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.generation, .status)
    ' | oc create -f -

  echo "Created $role MachineSet $ms_name ($NODE_POOL_INSTANCE_TYPE x 1)"
}

for role in router infra oai; do
  create_role_machineset "$role"
done

echo "Waiting for router/infra/oai nodes to join (this can take several minutes)..."
for _ in $(seq 1 60); do
  all_ready=true
  for role in router infra oai; do
    ms_name="${BASE_NAME%-worker-*}-${role}-${NODE_POOL_AZ}"
    ready=$(oc get machineset "$ms_name" -n openshift-machine-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    [ "$ready" = "1" ] || all_ready=false
  done
  $all_ready && break
  sleep 15
done
oc get machineset -n openshift-machine-api | grep -E "router|infra|oai" || true

echo "Labeling existing plain-worker nodes as cpu-worker..."
for node in $(oc get nodes -l 'node-role.kubernetes.io/worker,!nvidia.com/gpu.present,!node-role.kubernetes.io/router,!node-role.kubernetes.io/infra,!node-role.kubernetes.io/oai' -o name); do
  oc label "$node" node-role.kubernetes.io/cpu-worker= --overwrite
done

echo "Labeling existing GPU nodes as gpu-worker..."
for node in $(oc get nodes -l 'nvidia.com/gpu.present=true' -o name 2>/dev/null); do
  oc label "$node" node-role.kubernetes.io/gpu-worker= --overwrite
done

echo "Node pools ready. Current roles:"
oc get nodes -L 'node-role.kubernetes.io/router,node-role.kubernetes.io/infra,node-role.kubernetes.io/oai,node-role.kubernetes.io/cpu-worker,node-role.kubernetes.io/gpu-worker'
