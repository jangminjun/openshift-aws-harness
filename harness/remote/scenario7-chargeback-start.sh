#!/usr/bin/env bash
# Scenario 7: Chargeback & Quota control. Deploys team-workload-1 (1 GPU,
# representing a team's existing usage), then applies a ResourceQuota
# capping the namespace at requests.nvidia.com/gpu=1 -- as if the infra team
# just responded to a budget-overrun alert by locking the team to its
# current footprint. No visible effect yet; scenario7-chargeback-trigger.sh
# is where the team tries to exceed it. Idempotent.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-chargeback-scenario-7}"
GPU_QUOTA="${GPU_QUOTA:-1}"

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
  name: team-workload-1
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: team-workload-1
spec:
  restartPolicy: Never
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: team-workload-1
    image: docker.io/pytorch/pytorch:latest
    command: ["python3", "-c"]
    args:
    - |
      import torch, time
      x = torch.rand((8192, 8192), device="cuda")
      print("team-workload-1: running (this team's existing GPU footprint)...", flush=True)
      while True:
          y = torch.matmul(x, x)
    resources:
      limits:
        nvidia.com/gpu: 1
YAML

echo "Waiting for team-workload-1 to start Running..."
for _ in $(seq 1 40); do
  PHASE=$(oc get pod team-workload-1 -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$PHASE" = "Running" ] && break
  sleep 5
done
echo "team-workload-1 phase=${PHASE:-Unknown}"

echo ""
echo "--- Infra team response: budget check flagged this namespace, locking GPU quota to ${GPU_QUOTA} ---"
oc apply -f - <<YAML
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota
  namespace: ${DEMO_NAMESPACE}
spec:
  hard:
    requests.nvidia.com/gpu: "${GPU_QUOTA}"
YAML

oc describe resourcequota gpu-quota -n "${DEMO_NAMESPACE}"
echo ""
echo "Namespace is now capped at ${GPU_QUOTA} GPU(s), matching current usage."
echo "Next: ~/scenario7-chargeback-trigger.sh"
