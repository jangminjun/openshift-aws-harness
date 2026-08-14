#!/usr/bin/env bash
# Scenario 6: PriorityClass downgrade + Preemption. Deploys bad-code-workload
# (the offender from scenario 5) on g5.2xlarge with a Low PriorityClass, as
# if the infra team had already downgraded it after detection. This alone
# has no visible effect until a normal-priority workload actually needs that
# capacity -- that's scenario6-preempt-trigger.sh.
#
# g5's MachineAutoscaler max is temporarily capped at 1 (its current
# replica count) so the autoscaler can't just add a second node to dodge
# preemption -- Preemption becomes the only way to satisfy the next pod.
# scenario6-preempt-stop.sh restores it to 2.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-preempt-scenario-6}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.2xlarge}"

oc apply -f - <<YAML
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: low-priority-team
value: -1000000
globalDefault: false
description: "Assigned to teams flagged for GPU-inefficient code (scenario 5) -- first in line for preemption."
---
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
  name: bad-code-workload
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: bad-code-workload
spec:
  restartPolicy: Never
  priorityClassName: low-priority-team
  nodeSelector:
    node.kubernetes.io/instance-type: ${INSTANCE_TYPE}
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: bad-code-workload
    image: docker.io/pytorch/pytorch:latest
    command: ["python3", "-c"]
    args:
    - |
      import torch
      x = torch.rand((8192, 8192), device="cuda")
      print("bad-code-workload: running with low-priority-team (demoted after scenario 5 detection)...", flush=True)
      while True:
          y = torch.matmul(x, x)
    resources:
      limits:
        nvidia.com/gpu: 1
YAML

TYPE_TAG=$(echo "$INSTANCE_TYPE" | tr '.' '-')
MACHINESET=$(oc get machineset -n openshift-machine-api -o name | grep -- "-gpu-${TYPE_TAG}-us-east-1a\$" | sed 's#.*/##')
CURRENT=$(oc get machineset "$MACHINESET" -n openshift-machine-api -o jsonpath='{.spec.replicas}')
AUTOSCALER=$(echo "$MACHINESET" | sed -E 's/^[a-z0-9]+-[a-z0-9]+-//')
oc patch machineautoscaler "$AUTOSCALER" -n openshift-machine-api --type merge -p "{\"spec\":{\"maxReplicas\":${CURRENT}}}"
echo "MachineAutoscaler/${AUTOSCALER} max capped at ${CURRENT} (current replicas) -- no scale-out possible, preemption is the only path."

echo "Waiting for bad-code-workload to start Running..."
for _ in $(seq 1 40); do
  PHASE=$(oc get pod bad-code-workload -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$PHASE" = "Running" ] && break
  sleep 5
done
NODE=$(oc get pod bad-code-workload -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "<pending>")
echo "bad-code-workload phase=${PHASE:-Unknown} on node=${NODE} (priority=low-priority-team)"
echo "It's occupying the only GPU on ${INSTANCE_TYPE}."
echo "Next: ~/scenario6-preempt-trigger.sh"
