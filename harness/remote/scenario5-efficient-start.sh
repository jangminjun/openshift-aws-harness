#!/usr/bin/env bash
# Scenario 5 (efficient-code half): same training loop and same matmul rep
# count (10, ~0.33s of compute per step) as scenario5-badcode-start.sh, same
# synthetic 0.2s-per-sample dataset cost -- the ONLY difference is
# num_workers=4 instead of 0, isolating that one variable for a clean
# apples-to-apples comparison. Background workers prefetch the next batch
# while the GPU computes the current one, so the GPU idles far less. Run
# after scenario5-badcode-start.sh to compare step counts over the same
# duration. Runs alone (no time-slicing) so it has the whole physical GPU
# to itself.
#
# Gotcha (measured 2026-08-21): with only 0.33s of compute per step against
# Prometheus's 30s scrape interval, the Grafana GPU_UTIL graph mostly reads
# 0% for both this AND scenario5-badcode-start.sh, with only occasional
# lucky spikes -- the graph shape doesn't clearly distinguish the two here,
# even though the step-count throughput does (this script's whole point).
# For a version where the GPU_UTIL graph itself also renders cleanly
# (continuously high, no gaps) run scenario5-more-efficient-start.sh
# instead, which bumps matmul reps to 60 so per-step compute time exceeds
# the scrape interval-relevant timescale.
#
# Exposes a real Prometheus counter (train_steps_total) on :9091/metrics --
# see scenario5-badcode-start.sh's header for why this is more reliable
# than the GPU_UTIL gauge for graphing throughput. Idempotent.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-badcode-scenario-5}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-gpu-monitoring}"
PER_SAMPLE_SLEEP="${PER_SAMPLE_SLEEP:-0.2}"
BATCH_SIZE="${BATCH_SIZE:-32}"
NUM_WORKERS="${NUM_WORKERS:-4}"
OBSERVE_SECONDS="${OBSERVE_SECONDS:-180}"

TRAIN_SCRIPT='
from torch.utils.data import Dataset, DataLoader
import torch, time, os, threading, http.server

_step = {"n": 0}

class _MetricsHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            n = _step["n"]
            body = ("# TYPE train_steps_total counter\n"
                    f"train_steps_total {n}\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *a):
        pass

threading.Thread(
    target=lambda: http.server.HTTPServer(("0.0.0.0", 9091), _MetricsHandler).serve_forever(),
    daemon=True,
).start()

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

w = torch.rand((4096, 4096), device="cuda")
for batch in loader:
    x = batch.to("cuda")
    for _ in range(10):
        y = torch.matmul(w, w)
    torch.cuda.synchronize()
    _step["n"] += 1
    n = _step["n"]
    if n % 5 == 0:
        print(f"step={n}", flush=True)
'

oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${DEMO_NAMESPACE}
  labels:
    team: demo-team-a
---
apiVersion: v1
kind: Service
metadata:
  name: scenario5-metrics
  namespace: ${DEMO_NAMESPACE}
  labels:
    scenario5-metrics: "true"
spec:
  selector:
    scenario5-metrics: "true"
  ports:
  - name: metrics
    port: 9091
    targetPort: 9091
---
apiVersion: v1
kind: Pod
metadata:
  name: efficient-workload
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: efficient-workload
    scenario5-metrics: "true"
spec:
  restartPolicy: Never
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: efficient-workload
    image: docker.io/pytorch/pytorch:latest
    env:
    - name: NUM_WORKERS
      value: "${NUM_WORKERS}"
    - name: BATCH_SIZE
      value: "${BATCH_SIZE}"
    - name: PER_SAMPLE_SLEEP
      value: "${PER_SAMPLE_SLEEP}"
    command: ["python3", "-c"]
    args:
    - |
$(echo "$TRAIN_SCRIPT" | sed 's/^/      /')
    ports:
    - containerPort: 9091
      name: metrics
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

oc apply -f - <<YAML
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: scenario5-metrics
  namespace: ${MONITORING_NAMESPACE}
  labels:
    app: scenario5-metrics
spec:
  namespaceSelector:
    matchNames:
    - ${DEMO_NAMESPACE}
  selector:
    matchLabels:
      scenario5-metrics: "true"
  endpoints:
  - port: metrics
    path: /metrics
    honorLabels: true
YAML

echo "Waiting for efficient-workload to start Running..."
phase=""
for _ in $(seq 1 40); do
  phase=$(oc get pod efficient-workload -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$phase" = "Running" ] && break
  sleep 5
done
node=$(oc get pod efficient-workload -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "<pending>")
echo "efficient-workload: phase=${phase:-Unknown} node=${node}"

echo "Observing efficient-workload for ${OBSERVE_SECONDS}s (num_workers=${NUM_WORKERS})..."
sleep "$OBSERVE_SECONDS"

last_step=$(oc logs efficient-workload -n "${DEMO_NAMESPACE}" 2>/dev/null | grep -oE 'step=[0-9]+' | tail -1 | cut -d= -f2 || true)
echo ""
echo "=== Result (${OBSERVE_SECONDS}s) ==="
echo "efficient-workload (num_workers=${NUM_WORKERS}): ${last_step:-0} steps"
echo "Grafana Tier2 -> \"DataLoader Throughput (steps/sec)\" (select namespace=${DEMO_NAMESPACE})."

oc delete pod efficient-workload -n "${DEMO_NAMESPACE}" --ignore-not-found >/dev/null
echo "Compare against bad-code-workload's step count from scenario5-badcode-start.sh."
echo "Next (optional): ~/scenario5-more-efficient-start.sh -- same num_workers=4 but with a longer compute burst per step, so the GPU_UTIL graph itself also renders cleanly (continuously high, no gaps)."
