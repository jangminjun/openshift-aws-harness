#!/usr/bin/env bash
# Samples real GPU utilization (via nvidia-smi on the node's driver pod --
# same mechanism as scenario 3's power sampling) over a short window. Only
# reclaims (deletes) idle-workload if the *measured* average utilization is
# actually below IDLE_THRESHOLD_PCT -- this is a genuine check against live
# telemetry, not an unconditional delete, mirroring how a real idle-GPU
# reclaim policy would work (e.g. a controller watching
# DCGM_FI_DEV_GPU_UTIL and acting on it).
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-idle-scenario-8}"
IDLE_THRESHOLD_PCT="${IDLE_THRESHOLD_PCT:-3}"
SAMPLES="${SAMPLES:-10}"
SAMPLE_INTERVAL_SEC="${SAMPLE_INTERVAL_SEC:-1}"

NODE=$(oc get pod idle-workload -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
[ -n "$NODE" ] || { echo "idle-workload pod not found/scheduled in ${DEMO_NAMESPACE} -- run scenario8-idle-reclaim-start.sh first" >&2; exit 1; }

DRIVER_POD=$(oc get pods -n nvidia-gpu-operator -l app.kubernetes.io/component=nvidia-driver \
  --field-selector spec.nodeName="${NODE}" -o jsonpath='{.items[0].metadata.name}')
[ -n "$DRIVER_POD" ] || { echo "no nvidia-driver-daemonset pod found on node ${NODE}" >&2; exit 1; }

echo "Sampling GPU utilization on node ${NODE} (${SAMPLES} samples, ${SAMPLE_INTERVAL_SEC}s apart)..."
TOTAL=0
for i in $(seq 1 "$SAMPLES"); do
  UTIL=$(oc exec -n nvidia-gpu-operator "$DRIVER_POD" -- nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d '[:space:]')
  echo "  sample ${i}: utilization.gpu = ${UTIL:-0}%"
  TOTAL=$((TOTAL + ${UTIL:-0}))
  sleep "$SAMPLE_INTERVAL_SEC"
done
AVG=$((TOTAL / SAMPLES))

echo ""
echo "Average GPU utilization over ${SAMPLES} samples: ${AVG}% (idle threshold: ${IDLE_THRESHOLD_PCT}%)"

if [ "$AVG" -lt "$IDLE_THRESHOLD_PCT" ]; then
  echo "-> Confirmed idle. Reclaiming: deleting idle-workload to free the GPU on ${NODE}."
  oc delete pod idle-workload -n "${DEMO_NAMESPACE}"
  echo "GPU on ${NODE} is now free for other workloads."
else
  echo "-> Not idle enough (>= ${IDLE_THRESHOLD_PCT}%) -- NOT reclaiming. Re-run this script to check again later."
fi
