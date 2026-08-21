#!/usr/bin/env bash
# Scenario 6: PriorityClass downgrade + Preemption. Deploys low-priority-workload
# (the offender from scenario 5, renamed here to avoid clashing with scenario
# 5's own bad-code-workload pod name) with a Low PriorityClass, as if the
# infra team had already downgraded it after detection. This alone has no
# visible effect until a normal-priority workload actually needs that
# capacity -- that's scenario6-preempt-trigger.sh.
#
# The target flavor's MachineAutoscaler max is temporarily capped at 1 (its
# current replica count) so the autoscaler can't just add a second node to
# dodge preemption -- Preemption becomes the only way to satisfy the next
# pod. scenario6-preempt-stop.sh restores it.
#
# Defaults to g4dn.xlarge (2026-08-21): the live cluster has no
# MachineAutoscaler for g5.2xlarge right now (scaled to 0/0), so that
# flavor would fail at the `oc patch machineautoscaler` step. g4dn.xlarge
# is already pinned at 1 replica (MachineAutoscaler min=1/max=1), so no
# patch is even needed -- this doubles as scenario 6-1 in the SCENARIOS
# docs. To run against g5.2xlarge instead, recreate its MachineAutoscaler
# (min=1, max=2) first and override INSTANCE_TYPE=g5.2xlarge.
#
# Note: a g4dn.xlarge -> g4dn.2xlarge resize was attempted 2026-08-21 to
# give scenario 8 more RAM headroom, but failed -- this sandbox account's
# vCPU quota for the "G and VT instances" bucket is a hard 4, and
# g4dn.2xlarge needs 8; reverted back to g4dn.xlarge. Kept anyway: the
# MachineSet's own object name contains the literal string "g4dn-xlarge"
# regardless of its actual instanceType (metadata.name is immutable, so a
# resize -- if one ever succeeds -- wouldn't rename it), which would break a
# TYPE_TAG-derived name-pattern match against INSTANCE_TYPE. The MachineSet
# is instead discovered below by tracing the actual running node's own
# Machine/MachineSet ownership, which stays correct regardless of naming.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-preempt-scenario-6}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g4dn.xlarge}"

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
  name: low-priority-workload
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: low-priority-workload
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
  - name: low-priority-workload
    image: docker.io/pytorch/pytorch:latest
    command: ["python3", "-c"]
    args:
    - |
      import torch
      x = torch.rand((8192, 8192), device="cuda")
      print("low-priority-workload: running with low-priority-team (demoted after scenario 5 detection)...", flush=True)
      while True:
          y = torch.matmul(x, x)
    resources:
      limits:
        nvidia.com/gpu: 1
YAML

NODE_FOR_TYPE=$(oc get nodes -l "node.kubernetes.io/instance-type=${INSTANCE_TYPE}" -o jsonpath='{.items[0].metadata.name}')
MACHINE_REF=$(oc get node "$NODE_FOR_TYPE" -o jsonpath='{.metadata.annotations.machine\.openshift\.io/machine}')
MACHINESET=$(oc get machine "${MACHINE_REF#*/}" -n openshift-machine-api -o jsonpath='{.metadata.ownerReferences[0].name}')
CURRENT=$(oc get machineset "$MACHINESET" -n openshift-machine-api -o jsonpath='{.spec.replicas}')
AUTOSCALER=$(echo "$MACHINESET" | sed -E 's/^[a-z0-9]+-[a-z0-9]+-//')
oc patch machineautoscaler "$AUTOSCALER" -n openshift-machine-api --type merge -p "{\"spec\":{\"maxReplicas\":${CURRENT}}}"
echo "MachineAutoscaler/${AUTOSCALER} max capped at ${CURRENT} (current replicas) -- no scale-out possible, preemption is the only path."

echo "Waiting for low-priority-workload to start Running..."
for _ in $(seq 1 40); do
  PHASE=$(oc get pod low-priority-workload -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$PHASE" = "Running" ] && break
  sleep 5
done
NODE=$(oc get pod low-priority-workload -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "<pending>")
echo "low-priority-workload phase=${PHASE:-Unknown} on node=${NODE} (priority=low-priority-team)"
echo "It's occupying the only GPU on ${INSTANCE_TYPE}."
echo "Next: ~/scenario6-preempt-trigger.sh"
