#!/usr/bin/env bash
# Runs ON the bastion, after scenario3-powercap-start.sh. Applies (or resets)
# an NVIDIA GPU power limit via `nvidia-smi -pl` on the node running the
# power-load pod, by exec'ing into that node's nvidia-driver-daemonset pod
# (same mechanism the GPU Operator itself uses to manage the driver host).
# Idempotent: safe to re-run with a new wattage at any time.
#
# Usage: scenario3-powercap-apply.sh [watts]
#   no argument -> reset to the card's default/max power limit
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-powercap-scenario-3}"
WATTS="${1:-}"

NODE=$(oc get pod power-load -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
[ -n "$NODE" ] || { echo "power-load pod not found/scheduled in ${DEMO_NAMESPACE} — run scenario3-powercap-start.sh first" >&2; exit 1; }

DRIVER_POD=$(oc get pods -n nvidia-gpu-operator -l app.kubernetes.io/component=nvidia-driver \
  --field-selector spec.nodeName="${NODE}" -o jsonpath='{.items[0].metadata.name}')
[ -n "$DRIVER_POD" ] || { echo "no nvidia-driver-daemonset pod found on node ${NODE}" >&2; exit 1; }

if [ -z "$WATTS" ]; then
  WATTS=$(oc exec -n nvidia-gpu-operator "$DRIVER_POD" -- \
    nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits | tr -d '[:space:]')
  echo "No wattage given — resetting to card default power limit: ${WATTS}W"
else
  echo "Applying power cap: ${WATTS}W on node ${NODE}"
fi

oc exec -n nvidia-gpu-operator "$DRIVER_POD" -- nvidia-smi -i 0 -pl "$WATTS"

echo "Waiting for power draw to settle under the new cap (~15s)..."
for _ in $(seq 1 6); do
  DRAW=$(oc exec -n nvidia-gpu-operator "$DRIVER_POD" -- nvidia-smi --query-gpu=power.draw,power.limit --format=csv,noheader 2>/dev/null || true)
  echo "  power.draw, power.limit = ${DRAW:-?}"
  sleep 5
done

echo "Check Tier1 dashboard -> Power Draw per GPU for the drop (next scrape, ~30s)."
