#!/usr/bin/env bash
# Runs ON the bastion. Tears down scenario 3: deletes the power-load pod and
# resets the GPU's power limit back to the card default (if a driver pod is
# still reachable on the node the workload was on).
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-powercap-scenario-3}"

NODE=$(oc get pod power-load -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)

oc delete pod power-load -n "${DEMO_NAMESPACE}" --ignore-not-found

if [ -n "${NODE:-}" ]; then
  DRIVER_POD=$(oc get pods -n nvidia-gpu-operator -l app.kubernetes.io/component=nvidia-driver \
    --field-selector spec.nodeName="${NODE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$DRIVER_POD" ]; then
    DEFAULT_WATTS=$(oc exec -n nvidia-gpu-operator "$DRIVER_POD" -- \
      nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits 2>/dev/null | tr -d '[:space:]' || true)
    if [ -n "$DEFAULT_WATTS" ]; then
      oc exec -n nvidia-gpu-operator "$DRIVER_POD" -- nvidia-smi -i 0 -pl "$DEFAULT_WATTS" >/dev/null
      echo "Power limit reset to default (${DEFAULT_WATTS}W) on node ${NODE}."
    fi
  fi
fi

echo "scenario3 stopped."
