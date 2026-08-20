#!/usr/bin/env bash
# Samples dynamic-workload's real GPU utilization (same technique as
# scenario 8) and only reclaims (deletes) it if the measured average is
# actually below IDLE_THRESHOLD_PCT. Once the pod is gone, the node it was
# on has nothing left running on it (anchor-workload is on the OTHER node) --
# the MachineAutoscaler will scale that MachineSet back down automatically
# once ClusterAutoscaler's unneededTime (default 10min) elapses. This script
# reports that node's current pod count so you can see it emptied out, and
# offers a manual scale-down for demo speed instead of waiting.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-dynamic-scenario-9}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.2xlarge}"
IDLE_THRESHOLD_PCT="${IDLE_THRESHOLD_PCT:-3}"
SAMPLES="${SAMPLES:-10}"
SAMPLE_INTERVAL_SEC="${SAMPLE_INTERVAL_SEC:-1}"

NODE=$(oc get pod dynamic-workload -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
[ -n "$NODE" ] || { echo "dynamic-workload pod not found/scheduled in ${DEMO_NAMESPACE} -- run scenario9-dynamic-reclaim-start.sh first" >&2; exit 1; }

DRIVER_POD=$(oc get pods -n nvidia-gpu-operator -l app.kubernetes.io/component=nvidia-driver \
  --field-selector spec.nodeName="${NODE}" -o jsonpath='{.items[0].metadata.name}')
[ -n "$DRIVER_POD" ] || { echo "no nvidia-driver-daemonset pod found on node ${NODE}" >&2; exit 1; }

echo "Sampling GPU utilization of dynamic-workload on node ${NODE} (${SAMPLES} samples, ${SAMPLE_INTERVAL_SEC}s apart)..."
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

if [ "$AVG" -ge "$IDLE_THRESHOLD_PCT" ]; then
  echo "-> Not idle enough (>= ${IDLE_THRESHOLD_PCT}%) -- NOT reclaiming. Re-run this script to check again later."
  exit 0
fi

echo "-> Confirmed idle. Reclaiming: deleting dynamic-workload to free the GPU on ${NODE}."
oc delete pod dynamic-workload -n "${DEMO_NAMESPACE}"

REMAINING=$(oc get pods -A --field-selector spec.nodeName="${NODE}" -o json | \
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for p in d["items"] if not p["metadata"]["namespace"].startswith("openshift-") and p["metadata"]["namespace"] != "nvidia-gpu-operator"))')
echo "Node ${NODE} now has ${REMAINING} non-system workload pod(s) left on it."
echo ""
echo "The node itself isn't gone yet -- ClusterAutoscaler only scales a MachineSet"
echo "down after a node sits unneeded for its unneededTime (default 10min)."
echo "Watch it happen for real:"
echo "  oc get machineset -n openshift-machine-api | grep ${INSTANCE_TYPE//./-}"
echo "Or force it now for demo speed (same shortcut as scenario 1's stop script):"
MACHINESET=$(oc get machineset -n openshift-machine-api -o name | grep "${INSTANCE_TYPE//./-}" | head -1)
echo "  oc scale ${MACHINESET} -n openshift-machine-api --replicas=1"
