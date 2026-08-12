#!/usr/bin/env bash
# Runs ON the bastion, after gpu-machineset + cluster-autoscaler +
# machine-autoscaler. Stands up a demo namespace and 2 training-job pods
# pinned to the SAME GPU flavor (INSTANCE_TYPE) so they compete for that
# MachineSet's single node's capacity: one runs, one stays Pending
# (Insufficient nvidia.com/gpu) until ClusterAutoscaler scales that
# MachineSet out — scenario 1 (worker node autoscaling). Idempotent.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-autoscale-scenario-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.2xlarge}"

oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${DEMO_NAMESPACE}
  labels:
    team: demo-team-a
YAML

for i in 1 2; do
oc apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: training-job-${i}
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: training-job
spec:
  restartPolicy: Never
  nodeSelector:
    node.kubernetes.io/instance-type: ${INSTANCE_TYPE}
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: training-job
    image: docker.io/pytorch/pytorch:latest
    command: ["python3", "-c"]
    args:
    - |
      import torch
      x = torch.rand((8192, 8192), device="cuda")
      print("training-job-${i}: running on GPU...", flush=True)
      while True:
          y = torch.matmul(x, x)
    resources:
      limits:
        nvidia.com/gpu: 1
YAML
done

echo "Submitted training-job-1 and training-job-2 (both pinned to ${INSTANCE_TYPE})."
echo "Watch scheduling:  oc get pods -n ${DEMO_NAMESPACE} -o wide -w"
echo "Watch the MachineSet scale out:  oc get machineset -n openshift-machine-api | grep ${INSTANCE_TYPE//./-}"
echo "Timing: MachineSet replica bump ~30s, new node Ready ~4min, GPU detected + pod scheduled ~4min, image pull ~2min (~10min total)."
