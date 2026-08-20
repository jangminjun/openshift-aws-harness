#!/usr/bin/env bash
# Scenario 5: bad-code / DataLoader bottleneck detection. Runs the SAME
# training loop against a synthetic "slow" Dataset (0.2s per-sample delay
# simulating real decode/augment cost) twice, SEQUENTIALLY -- once with
# num_workers=0 (serial: GPU idles while each sample is fetched one at a
# time), once with num_workers=4 (parallel prefetch: workers prepare the
# next batch in the background while the GPU computes the current one) --
# and compares throughput. Sequential rather than side-by-side because this
# cluster's GPU MachineSet is capped at 1 node (AWS G/VT vCPU quota; see
# AGENT.md), so only one of the two pods can hold the single GPU at a time.
# Idempotent.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-badcode-scenario-5}"
PER_SAMPLE_SLEEP="${PER_SAMPLE_SLEEP:-0.2}"
BATCH_SIZE="${BATCH_SIZE:-32}"
GOOD_NUM_WORKERS="${GOOD_NUM_WORKERS:-4}"
OBSERVE_SECONDS="${OBSERVE_SECONDS:-60}"

TRAIN_SCRIPT='
from torch.utils.data import Dataset, DataLoader
import torch, time, os

class SlowDataset(Dataset):
    def __len__(self):
        return 10_000_000
    def __getitem__(self, idx):
        time.sleep(float(os.environ["PER_SAMPLE_SLEEP"]))
        return torch.rand(3, 224, 224)

nw = int(os.environ["NUM_WORKERS"])
bs = int(os.environ["BATCH_SIZE"])
print(f"starting: num_workers={nw} batch_size={bs}", flush=True)
loader = DataLoader(SlowDataset(), batch_size=bs, num_workers=nw)

step = 0
w = torch.rand((4096, 4096), device="cuda")
for batch in loader:
    x = batch.to("cuda")
    for _ in range(10):
        y = torch.matmul(w, w)
    torch.cuda.synchronize()
    step += 1
    if step % 5 == 0:
        print(f"step={step}", flush=True)
'

deploy_pod() {
  local name="$1" num_workers="$2"
  oc apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: ${name}
spec:
  restartPolicy: Never
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: ${name}
    image: docker.io/pytorch/pytorch:latest
    env:
    - name: NUM_WORKERS
      value: "${num_workers}"
    - name: BATCH_SIZE
      value: "${BATCH_SIZE}"
    - name: PER_SAMPLE_SLEEP
      value: "${PER_SAMPLE_SLEEP}"
    command: ["python3", "-c"]
    args:
    - |
$(echo "$TRAIN_SCRIPT" | sed 's/^/      /')
    resources:
      limits:
        nvidia.com/gpu: 1
    volumeMounts:
    - name: dshm
      mountPath: /dev/shm
  volumes:
  - name: dshm
    emptyDir:
      medium: Memory
      sizeLimit: 1Gi
YAML
}

# Deploys $1 with num_workers=$2, waits for it to run, observes it for
# OBSERVE_SECONDS, then deletes it and sets RESULT_STEPS to the last step
# count reached. Sets a global (not a command-substitution return value) so
# its progress echoes print live instead of being swallowed by a capture pipe.
RESULT_STEPS=0
run_and_measure() {
  local name="$1" num_workers="$2"
  deploy_pod "$name" "$num_workers"

  echo "Waiting for ${name} to start Running..."
  local phase node
  for _ in $(seq 1 40); do
    phase=$(oc get pod "$name" -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$phase" = "Running" ] && break
    sleep 5
  done
  node=$(oc get pod "$name" -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "<pending>")
  echo "${name}: phase=${phase:-Unknown} node=${node}"

  echo "Observing ${name} for ${OBSERVE_SECONDS}s (num_workers=${num_workers})..."
  sleep "$OBSERVE_SECONDS"

  local last_step
  last_step=$(oc logs "$name" -n "${DEMO_NAMESPACE}" 2>/dev/null | grep -oE 'step=[0-9]+' | tail -1 | cut -d= -f2)
  echo "${name}: reached ${last_step:-0} steps in ${OBSERVE_SECONDS}s"

  oc delete pod "$name" -n "${DEMO_NAMESPACE}" --ignore-not-found >/dev/null
  RESULT_STEPS="${last_step:-0}"
}

oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${DEMO_NAMESPACE}
  labels:
    team: demo-team-a
YAML

echo "=== Phase 1/2: bad-code-workload (num_workers=0) ==="
run_and_measure "bad-code-workload" 0
BAD_STEPS="$RESULT_STEPS"

echo ""
echo "=== Phase 2/2: efficient-workload (num_workers=${GOOD_NUM_WORKERS}) ==="
run_and_measure "efficient-workload" "${GOOD_NUM_WORKERS}"
GOOD_STEPS="$RESULT_STEPS"

echo ""
echo "=== Result (${OBSERVE_SECONDS}s each, sequential -- only 1 GPU node available) ==="
echo "bad-code-workload  (num_workers=0): ${BAD_STEPS} steps"
echo "efficient-workload (num_workers=${GOOD_NUM_WORKERS}): ${GOOD_STEPS} steps"
if [ "${BAD_STEPS:-0}" -gt 0 ]; then
  echo "speedup: $(echo "scale=1; ${GOOD_STEPS:-0} / ${BAD_STEPS}" | bc)x"
fi
echo "Grafana Tier1 -> GPU Compute vs Memory Utilization (Cluster Avg) / Tier2 -> Stall Pattern panel"
