#!/usr/bin/env bash
# Runs ON the bastion, after gpu-operator + monitoring-all. Stands up a demo
# "project team" namespace and a gpu-burn pod that pegs a GPU at high
# utilization/temperature — for exercising scenario 1 (overheat detection +
# Slack alert) end to end against the dashboards built earlier. Idempotent.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-scenario1-demo}"

# docker.io/wilicc/gpu-burn (the usual go-to) is gated behind Docker Hub auth
# now, so this stresses the GPU with a plain PyTorch matmul loop instead —
# pytorch/pytorch is a well-known public image, no login needed.
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
  name: gpu-burn
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: gpu-burn
spec:
  restartPolicy: Never
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: gpu-burn
    image: docker.io/pytorch/pytorch:latest
    command: ["python3", "-c"]
    args:
    - |
      import torch
      x = torch.rand((8192, 8192), device="cuda")
      print("stressing GPU with repeated 8192x8192 matmul...", flush=True)
      while True:
          y = torch.matmul(x, x)
    resources:
      limits:
        nvidia.com/gpu: 1
YAML

echo "Waiting for gpu-burn pod to schedule and start Running..."
for _ in $(seq 1 40); do
  PHASE=$(oc get pod gpu-burn -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$PHASE" = "Running" ] && break
  sleep 5
done

NODE=$(oc get pod gpu-burn -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "<pending>")
echo "gpu-burn pod phase=${PHASE:-Unknown} on node=${NODE}"
echo "Watch it heat up: Tier1 dashboard -> Real-time GPU Temperature by Node"
echo "Stop the demo any time with: oc delete pod gpu-burn -n ${DEMO_NAMESPACE}"
