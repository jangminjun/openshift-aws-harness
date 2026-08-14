#!/usr/bin/env bash
# Scenario 4: GPU node fault isolation. Deploys fault-workload (a Deployment,
# not a bare Pod, so the controller re-creates it automatically once its node
# is drained) requesting 1 GPU with no flavor pin -- the scheduler lands it
# on whichever GPU node has room. Idempotent.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-fault-scenario-4}"

oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${DEMO_NAMESPACE}
  labels:
    team: demo-team-a
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fault-workload
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: fault-workload
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fault-workload
  template:
    metadata:
      labels:
        app: fault-workload
    spec:
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      containers:
      - name: fault-workload
        image: docker.io/pytorch/pytorch:latest
        command: ["python3", "-c"]
        args:
        - |
          import torch
          x = torch.rand((8192, 8192), device="cuda")
          print("fault-workload: running on GPU...", flush=True)
          while True:
              y = torch.matmul(x, x)
        resources:
          limits:
            nvidia.com/gpu: 1
YAML

echo "Waiting for fault-workload pod to start Running..."
for _ in $(seq 1 40); do
  POD=$(oc get pods -n "${DEMO_NAMESPACE}" -l app=fault-workload -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "$POD" ] || { sleep 5; continue; }
  PHASE=$(oc get pod "$POD" -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$PHASE" = "Running" ] && break
  sleep 5
done
NODE=$(oc get pod "$POD" -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "<pending>")
echo "fault-workload pod=${POD} phase=${PHASE:-Unknown} on node=${NODE}"
echo "This is the node we'll simulate a hardware fault on."
echo "Next: ~/scenario4-fault-trigger.sh"
