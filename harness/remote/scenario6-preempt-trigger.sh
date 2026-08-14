#!/usr/bin/env bash
# Deploys legitimate-workload at normal (default) priority on the same GPU
# flavor as bad-code-workload. Since the MachineAutoscaler max is capped
# (scenario6-preempt-start.sh) so no new node can be added, and the only GPU
# on that flavor is occupied by the low-priority bad-code-workload, the
# scheduler preempts (evicts) it to make room -- demonstrating that the
# PriorityClass downgrade from scenario 5's "infra team action" has real
# teeth once capacity is contested.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-preempt-scenario-6}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.2xlarge}"

echo "Before: $(oc get pod bad-code-workload -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo 'not found')"

oc apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: legitimate-workload
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: legitimate-workload
spec:
  restartPolicy: Never
  nodeSelector:
    node.kubernetes.io/instance-type: ${INSTANCE_TYPE}
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: legitimate-workload
    image: docker.io/pytorch/pytorch:latest
    command: ["python3", "-c"]
    args:
    - |
      import torch
      x = torch.rand((8192, 8192), device="cuda")
      print("legitimate-workload: normal priority, running on GPU...", flush=True)
      while True:
          y = torch.matmul(x, x)
    resources:
      limits:
        nvidia.com/gpu: 1
YAML

echo "Waiting for preemption + reschedule..."
for _ in $(seq 1 30); do
  LP_PHASE=$(oc get pod bad-code-workload -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Gone")
  NEW_PHASE=$(oc get pod legitimate-workload -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$NEW_PHASE" = "Running" ] && break
  sleep 3
done

echo ""
echo "bad-code-workload  : ${LP_PHASE} (evicted by preemption -- was low-priority-team)"
echo "legitimate-workload: ${NEW_PHASE:-Unknown} (normal priority, took the GPU)"
oc get events -n "${DEMO_NAMESPACE}" --field-selector reason=Preempted 2>/dev/null | tail -5
echo ""
echo "The Low PriorityClass from scenario 5's control action just cost bad-code-workload its GPU."
echo "Next: ~/scenario6-preempt-stop.sh"
