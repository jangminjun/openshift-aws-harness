#!/usr/bin/env bash
# Runs ON the bastion, after gpu-operator + monitoring-all + a g6.2xlarge
# (NVIDIA L4) GPU MachineSet. Stands up a demo "project team" namespace and a
# power-load pod pinned to the L4 node, running a bursty inference-style
# pattern (short matmul burst, then an idle gap) rather than a fully
# saturated stress loop — baseline for scenario 3 (GPU power capping /
# Green AI). Idempotent.
#
# Why bursty and not continuous 100% saturation: measured on this exact
# g6.2xlarge/L4 node, a fully-saturated FP32 matmul loop showed performance
# loss *exceeding* the power savings at every cap tested (72W->50W: -30.6%
# power but -41.3% throughput) — the classic "power capping only clips the
# inefficient boost region for free" argument assumes idle gaps the workload
# doesn't spend at peak clocks anyway, which a saturated stress loop doesn't
# have. A duty-cycled burst+idle pattern is a closer stand-in for real
# inference serving and is expected to show a more favorable ratio.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-powercap-scenario-3}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g6.2xlarge}"
BURST_COUNT="${BURST_COUNT:-3}"
IDLE_SEC="${IDLE_SEC:-0.5}"

oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${DEMO_NAMESPACE}
  labels:
    team: demo-team-a
---
apiVersion: v1
kind: Pod
metadata:
  name: power-load
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: power-load
spec:
  restartPolicy: Never
  nodeSelector:
    node.kubernetes.io/instance-type: ${INSTANCE_TYPE}
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: power-load
    image: docker.io/pytorch/pytorch:latest
    command: ["python3", "-c"]
    args:
    - |
      import torch, time
      x = torch.rand((8192, 8192), device="cuda")
      torch.cuda.synchronize()
      BURST_COUNT = ${BURST_COUNT}
      IDLE_SEC = ${IDLE_SEC}
      print(f"bursty inference-style load: {BURST_COUNT} matmuls then {IDLE_SEC}s idle, logging throughput every 5s...", flush=True)
      completed = 0
      window_start = time.time()
      while True:
          for _ in range(BURST_COUNT):
              y = torch.matmul(x, x)
          torch.cuda.synchronize()
          completed += 1
          time.sleep(IDLE_SEC)
          now = time.time()
          if now - window_start >= 5:
              rate = completed / (now - window_start)
              print(f"throughput: {rate:.2f} requests/sec", flush=True)
              completed = 0
              window_start = now
    resources:
      limits:
        nvidia.com/gpu: 1
YAML

echo "Waiting for power-load pod to schedule and start Running..."
for _ in $(seq 1 40); do
  PHASE=$(oc get pod power-load -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$PHASE" = "Running" ] && break
  sleep 5
done

NODE=$(oc get pod power-load -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "<pending>")
echo "power-load pod phase=${PHASE:-Unknown} on node=${NODE}"

if [ -n "${NODE:-}" ] && [ "$NODE" != "<pending>" ]; then
  echo "Sampling power draw (bursty workload -> expect it well under the card max, not pegged) (~30s)..."
  DRIVER_POD=$(oc get pods -n nvidia-gpu-operator -l app.kubernetes.io/component=nvidia-driver \
    --field-selector spec.nodeName="${NODE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$DRIVER_POD" ]; then
    for _ in $(seq 1 12); do
      DRAW=$(oc exec -n nvidia-gpu-operator "$DRIVER_POD" -- nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null || true)
      echo "  power.draw = ${DRAW:-?} W"
      sleep 5
    done
  fi
fi

echo "Watch it: Tier1 dashboard -> Power Draw per GPU"
echo "Apply a power cap with: ./harness.sh scenario3-powercap-apply <watts>  (or on the bastion: ~/scenario3-powercap-apply.sh <watts>)"
echo "Stop the demo any time with: oc delete pod power-load -n ${DEMO_NAMESPACE}"
