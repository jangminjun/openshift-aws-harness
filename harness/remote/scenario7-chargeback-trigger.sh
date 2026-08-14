#!/usr/bin/env bash
# Attempts to deploy a second GPU workload for the team -- with the
# ResourceQuota from scenario7-chargeback-start.sh in place, this is
# rejected immediately by the API server (admission control), not queued or
# scheduled. No wait, no race condition -- the quota either allows it or it
# doesn't, at request time.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-chargeback-scenario-7}"

echo "Team tries to deploy team-workload-2 (would bring GPU usage to 2, over the quota of 1)..."
echo ""
set +e
OUTPUT=$(oc apply -f - <<YAML 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: team-workload-2
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: team-workload-2
spec:
  restartPolicy: Never
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: team-workload-2
    image: docker.io/pytorch/pytorch:latest
    command: ["python3", "-c"]
    args:
    - |
      import torch
      x = torch.rand((8192, 8192), device="cuda")
      while True:
          y = torch.matmul(x, x)
    resources:
      limits:
        nvidia.com/gpu: 1
YAML
)
RC=$?
set -e

echo "$OUTPUT"
echo ""
if [ $RC -ne 0 ]; then
  echo "REJECTED at admission time (exit code ${RC}) -- no pod was created, no scheduling attempt happened."
  echo "The ResourceQuota from scenario 5/6's 'infra team downgrades this team' story just capped their spend."
else
  echo "WARNING: apply succeeded -- quota did not block it. Check GPU_QUOTA vs actual usage."
fi
echo ""
echo "Confirm nothing new was created:"
oc get pods -n "${DEMO_NAMESPACE}"
echo "Next: ~/scenario7-chargeback-stop.sh"
