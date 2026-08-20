#!/usr/bin/env bash
# Scenario 9: full elastic lifecycle -- dynamic GPU allocation (scenario 1's
# mechanism) followed by measured idle reclaim (scenario 8's mechanism), so
# capacity that gets allocated on demand also gets given back automatically
# once nothing is using it. Runs ON the bastion, after gpu-machineset +
# cluster-autoscaler + machine-autoscaler.
#
# anchor-workload occupies the GPU flavor's existing single node (busy,
# stays running for the whole demo). dynamic-workload then requests a
# second GPU on the same flavor -- Pending until the MachineAutoscaler
# scales that MachineSet out (dynamic allocation), then once scheduled it
# does one small op and goes idle (simulating the requester finishing their
# work and walking away, same pattern as scenario 8's idle-workload).
# Idempotent.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-dynamic-scenario-9}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.2xlarge}"

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
  name: anchor-workload
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: anchor-workload
spec:
  restartPolicy: Never
  nodeSelector:
    node.kubernetes.io/instance-type: ${INSTANCE_TYPE}
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: anchor-workload
    image: docker.io/pytorch/pytorch:latest
    command: ["python3", "-c"]
    args:
    - |
      import torch
      x = torch.rand((8192, 8192), device="cuda")
      print("anchor-workload: occupying the existing GPU node...", flush=True)
      while True:
          y = torch.matmul(x, x)
    resources:
      limits:
        nvidia.com/gpu: 1
---
apiVersion: v1
kind: Pod
metadata:
  name: dynamic-workload
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: dynamic-workload
spec:
  restartPolicy: Never
  nodeSelector:
    node.kubernetes.io/instance-type: ${INSTANCE_TYPE}
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: dynamic-workload
    image: docker.io/pytorch/pytorch:latest
    command: ["python3", "-c"]
    args:
    - |
      import torch, time
      x = torch.rand((1024, 1024), device="cuda")
      y = torch.matmul(x, x)
      torch.cuda.synchronize()
      print("dynamic-workload: GPU initialized on newly-allocated node, going idle...", flush=True)
      time.sleep(999999)
    resources:
      limits:
        nvidia.com/gpu: 1
YAML

echo "Submitted anchor-workload (occupies the existing node) and dynamic-workload"
echo "(requests a second GPU on ${INSTANCE_TYPE} -- stays Pending until the"
echo "MachineAutoscaler dynamically allocates a new node)."
echo ""
echo "Watch scheduling:  oc get pods -n ${DEMO_NAMESPACE} -o wide -w"
echo "Watch the MachineSet scale out:  oc get machineset -n openshift-machine-api | grep ${INSTANCE_TYPE//./-}"
echo "Timing: same as scenario 1 (~10min for the new node to be ready and dynamic-workload scheduled)."
echo "Once dynamic-workload is Running, it goes idle almost immediately."
echo "Next: ~/scenario9-dynamic-reclaim-trigger.sh (only reclaims if actually idle)"
