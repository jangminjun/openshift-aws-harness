#!/usr/bin/env bash
# Scenario 8: idle GPU reclaim. Deploys idle-workload -- a pod that requests
# a GPU, does one small op to prove it initialized CUDA (so it looks like a
# legitimate allocation), then goes to sleep forever. Simulates someone
# checking out an interactive/dev GPU session and forgetting about it: the
# GPU is "allocated" (nvidia.com/gpu: 1, counted against quota) but doing
# nothing. No flavor pin -- the scheduler lands it on whichever GPU node has
# room, same as scenario 4. Idempotent.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-idle-scenario-8}"

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
  name: idle-workload
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: idle-workload
spec:
  restartPolicy: Never
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: idle-workload
    image: docker.io/pytorch/pytorch:latest
    command: ["python3", "-c"]
    args:
    - |
      import torch, time
      x = torch.rand((1024, 1024), device="cuda")
      y = torch.matmul(x, x)
      torch.cuda.synchronize()
      print("idle-workload: GPU initialized, going idle (simulating an abandoned dev session)...", flush=True)
      time.sleep(999999)
    resources:
      limits:
        nvidia.com/gpu: 1
YAML

echo "Waiting for idle-workload pod to start Running..."
for _ in $(seq 1 40); do
  PHASE=$(oc get pod idle-workload -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$PHASE" = "Running" ] && break
  sleep 5
done

NODE=$(oc get pod idle-workload -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "<pending>")
echo "idle-workload pod phase=${PHASE:-Unknown} on node=${NODE}"
echo "It holds a GPU allocation (nvidia.com/gpu: 1) but is doing nothing -- a classic"
echo "'forgot to delete my dev pod' case. GPU utilization should settle near 0% shortly."
echo "Check with: ~/scenario8-idle-reclaim-trigger.sh (only reclaims if actually idle)"
