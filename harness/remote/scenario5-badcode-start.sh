#!/usr/bin/env bash
# Scenario 5: bad-code / DataLoader bottleneck detection. Deploys two pods
# running the SAME training loop against a synthetic "slow" Dataset (0.2s
# per-sample delay simulating real decode/augment cost) -- one with
# num_workers=0 (serial: GPU idles while each sample is fetched one at a
# time), one with num_workers=4 (parallel prefetch: workers prepare the next
# batch in the background while the GPU computes the current one). Both
# workloads and results are directly comparable on the same dashboard.
# Idempotent.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-badcode-scenario-5}"
PER_SAMPLE_SLEEP="${PER_SAMPLE_SLEEP:-0.2}"
BATCH_SIZE="${BATCH_SIZE:-32}"
GOOD_NUM_WORKERS="${GOOD_NUM_WORKERS:-4}"

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

oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${DEMO_NAMESPACE}
  labels:
    team: demo-team-a
YAML

deploy_pod "bad-code-workload" 0
deploy_pod "efficient-workload" "${GOOD_NUM_WORKERS}"

echo "Waiting for both pods to start Running..."
for name in bad-code-workload efficient-workload; do
  for _ in $(seq 1 40); do
    PHASE=$(oc get pod "$name" -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$PHASE" = "Running" ] && break
    sleep 5
  done
  NODE=$(oc get pod "$name" -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "<pending>")
  echo "${name}: phase=${PHASE:-Unknown} node=${NODE}"
done

echo ""
echo "bad-code-workload   : num_workers=0 (serial fetch, GPU idles between batches)"
echo "efficient-workload  : num_workers=${GOOD_NUM_WORKERS} (parallel prefetch, GPU stays busier)"
echo "Watch: oc logs -f bad-code-workload -n ${DEMO_NAMESPACE}"
echo "       oc logs -f efficient-workload -n ${DEMO_NAMESPACE}"
echo "Grafana Tier1 -> GPU Compute vs Memory Utilization (Cluster Avg) / Tier2 -> Stall Pattern panel"
