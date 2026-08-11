#!/usr/bin/env bash
# Runs ON the bastion. Creates/updates a MachineAutoscaler for one MachineSet.
# Idempotent (oc apply). Requires the ClusterAutoscaler singleton to exist
# first (see cluster-autoscaler.sh) or the autoscaler pod won't act on it.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

MACHINESET_NAME="${MACHINESET_NAME:?set MACHINESET_NAME (oc get machineset -n openshift-machine-api)}"
MIN_REPLICAS="${MIN_REPLICAS:?set MIN_REPLICAS}"
MAX_REPLICAS="${MAX_REPLICAS:?set MAX_REPLICAS}"
AUTOSCALER_NAME="${AUTOSCALER_NAME:-$(echo "$MACHINESET_NAME" | sed -E 's/^[a-z0-9]+-[a-z0-9]+-//')}"

oc apply -f - <<YAML
apiVersion: autoscaling.openshift.io/v1beta1
kind: MachineAutoscaler
metadata:
  name: ${AUTOSCALER_NAME}
  namespace: openshift-machine-api
spec:
  minReplicas: ${MIN_REPLICAS}
  maxReplicas: ${MAX_REPLICAS}
  scaleTargetRef:
    apiVersion: machine.openshift.io/v1beta1
    kind: MachineSet
    name: ${MACHINESET_NAME}
YAML

echo "MachineAutoscaler/${AUTOSCALER_NAME} -> ${MACHINESET_NAME} (min=${MIN_REPLICAS}, max=${MAX_REPLICAS})"
