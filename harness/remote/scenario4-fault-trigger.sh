#!/usr/bin/env bash
# Cordons + drains whichever node fault-workload is currently on, simulating
# "DCGM caught repeated XID errors here, infra team isolates the node" --
# scenario 1's control action from the doc (cordon & drain + evict the
# offending pod). The Deployment controller re-creates the pod immediately;
# since the faulty node is now unschedulable, it lands on the other GPU node
# automatically -- no manual rescheduling needed.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-fault-scenario-4}"

POD=$(oc get pods -n "${DEMO_NAMESPACE}" -l app=fault-workload -o jsonpath='{.items[0].metadata.name}')
NODE=$(oc get pod "$POD" -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}')
[ -n "$NODE" ] || { echo "fault-workload pod not scheduled yet" >&2; exit 1; }

echo "Simulated fault detected on node ${NODE} (DCGM repeated XID errors)."
echo "--- cordon: blocking new work on ${NODE} ---"
oc adm cordon "$NODE"

echo "--- drain: evicting fault-workload from ${NODE} ---"
oc adm drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s

echo "Waiting for fault-workload to reschedule onto a healthy node..."
for _ in $(seq 1 30); do
  NEWPOD=$(oc get pods -n "${DEMO_NAMESPACE}" -l app=fault-workload -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "$NEWPOD" ] || { sleep 3; continue; }
  PHASE=$(oc get pod "$NEWPOD" -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$PHASE" = "Running" ] && break
  sleep 3
done
NEWNODE=$(oc get pod "$NEWPOD" -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "<pending>")

echo ""
echo "fault-workload moved: ${NODE} -> ${NEWNODE} (pod=${NEWPOD}, phase=${PHASE:-Unknown})"
echo "Watch Grafana Tier1 -> GPU Utilization by Node: ${NODE} drops to 0%, ${NEWNODE} climbs to 100%."
echo "Node ${NODE} is still cordoned (SchedulingDisabled). Uncordon it with:"
echo "  oc adm uncordon ${NODE}"
echo "Or just run: ~/scenario4-fault-stop.sh"
