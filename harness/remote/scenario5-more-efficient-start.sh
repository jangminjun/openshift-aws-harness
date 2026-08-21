#!/usr/bin/env bash
# Scenario 5 (more-efficient half): same as scenario5-efficient-start.sh
# (num_workers=4, same synthetic 0.2s-per-sample dataset cost), but with 60
# matmul reps per step instead of 10 -- ~1.88s of compute per step instead
# of ~0.33s. That pushes the per-step compute time past the ~1.6s it takes
# 4 background workers to produce the next batch, making this workload
# genuinely compute-bound instead of still (partially) DataLoader-bound.
#
# Why this exists (measured 2026-08-21): with only 10 matmul reps,
# efficient-workload's compute burst (~0.33s) is so short relative to
# Prometheus's 30s scrape interval that the Grafana GPU_UTIL graph reads
# mostly 0% for it too (duty cycle ~16.5%, not the "continuously busy"
# story scenario5-efficient-start.sh's throughput number actually proves).
# At 60 reps, live sampling showed efficient-workload's GPU_UTIL read
# 97-100% on 4 consecutive 10s samples (continuously high, no gaps) while
# scenario5-badcode-start.sh's still showed a clear on/off pattern
# (100,100,100,0,0,0,100,100) -- a much cleaner visual pair than the
# matmul=10 version. The peak value (100%) is the same either way; the
# distinguishing signal is whether it drops to 0% in between.
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
    for _ in range(60):
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
  name: more-efficient-workload
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: more-efficient-workload
    scenario5-metrics: "true"
spec:
  restartPolicy: Never
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: more-efficient-workload
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

echo "Waiting for more-efficient-workload to start Running..."
phase=""
for _ in $(seq 1 40); do
  phase=$(oc get pod more-efficient-workload -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$phase" = "Running" ] && break
  sleep 5
done
node=$(oc get pod more-efficient-workload -n "${DEMO_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "<pending>")
echo "more-efficient-workload: phase=${phase:-Unknown} node=${node}"

echo "Observing more-efficient-workload for ${OBSERVE_SECONDS}s (num_workers=${NUM_WORKERS}, 60 matmul reps/step)..."
sleep "$OBSERVE_SECONDS"

last_step=$(oc logs more-efficient-workload -n "${DEMO_NAMESPACE}" 2>/dev/null | grep -oE 'step=[0-9]+' | tail -1 | cut -d= -f2 || true)
echo ""
echo "=== Result (${OBSERVE_SECONDS}s) ==="
echo "more-efficient-workload (num_workers=${NUM_WORKERS}, 60 reps): ${last_step:-0} steps"
echo "Grafana Tier2 -> \"DataLoader Throughput (steps/sec)\" (select namespace=${DEMO_NAMESPACE})."
echo "Also watch Tier2 'GPU Utilization per Pod' -- this run should show a continuously high line (97-100%, no gaps), unlike scenario5-badcode-start.sh's on/off pattern."

oc delete pod more-efficient-workload -n "${DEMO_NAMESPACE}" --ignore-not-found >/dev/null
