# GPU Demo Scenarios

Assumes the `myocp` cluster (OpenShift + OpenShift AI + GPU Operator +
monitoring stack) is already up. This document lays out the customer-demo
scenarios in **presentation order** — that numbering is different from the
`openshift-monitoring` doc's own scenario numbers (1: overheat/fault, 2: GPU
misuse, 3: inefficient code, 4: chargeback). This demo's "Scenario 2 (alert)"
and "Scenario 4 (fault isolation)" both map to the doc's "Scenario 1" (one is
detection+alerting, the other is the response action), "Scenario 3 (Power
Capping)" maps to the doc's separate "Green AI" section, "Scenarios 5/6
(bad-code detection + PriorityClass/preemption)" both map to the doc's
"Scenario 3", and "Scenario 7 (Chargeback & Quota)" maps to the doc's
"Scenario 4".

Either of these works:
- Locally: `./harness.sh <command>` (needs a harness checkout + AWS profile)
- SSH into the bastion and run `~/scenario*.sh` directly (fastest, recommended mid-demo)

```bash
ssh -i ~/.ssh/myocp-bastion ec2-user@<bastion-public-ip>
```

---

## Scenario 1 — Worker Node Autoscaling

**What it shows**: when GPU demand exceeds current capacity, the infrastructure
scales out nodes automatically, with no human in the loop.

**Setup**:
- Two pods, `training-job-1` and `training-job-2`, both pinned to the **same
  GPU flavor** (`g5.2xlarge`, NVIDIA A10G)
- Each pod requests `nvidia.com/gpu: 1` — but the g5 MachineSet currently has
  only 1 node / 1 GPU
- One schedules, the other goes `Pending` (`Insufficient nvidia.com/gpu`)
- The `MachineAutoscaler` (min=1, max=2) detects this and scales the g5
  MachineSet from 1→2
- Once the new node joins, the pending pod gets scheduled

**Run**:
```bash
# on the bastion
~/scenario1-autoscale-start.sh

# or locally
./harness.sh scenario1-autoscale-demo
```

**Watch**:
```bash
oc get pods -n gpu-autoscale-scenario-1 -o wide -w
oc get machineset -n openshift-machine-api | grep g5-2xlarge
```

**Timing (measured)**:
| Stage | Duration |
|---|---|
| MachineSet replica 1→2 takes effect | ~30s |
| New EC2 instance Ready | ~4min |
| GPU driver/device recognition + pod scheduled | ~4min |
| Container image pull + start | ~2min |
| **Total** | **~10min** |

10 minutes is too long to watch live, so the recommended flow is: submit →
confirm Pending → (talk about something else while it scales) → confirm the
node count went up.

**Cleanup (always run after the demo)**:
```bash
~/scenario1-autoscale-stop.sh
# or: ./harness.sh scenario1-autoscale-demo-stop
```
Only the pods are deleted — the extra node is scaled back down by the
`ClusterAutoscaler` after 10 minutes of idle (`unneededTime`). **If you're
about to re-run this demo right away, re-running it while the node count is
still 2 won't produce a Pending pod, so the demo won't show anything** — force
a reset first:
```bash
oc scale machineset myocp-z4828-gpu-g5-2xlarge-us-east-1a -n openshift-machine-api --replicas=1
```

---

## Scenario 2 — GPU Overheat Alert

**What it shows**: when a GPU overheats, it shows up on the dashboard in real
time and triggers an automatic Slack notification.

**Setup**:
- A `gpu-burn` pod runs an unbounded loop of 8192×8192 PyTorch matmuls,
  pegging the GPU at 100% utilization
- Grafana's Tier1 dashboard "Real-time GPU Temperature by Node" panel shows
  the temperature climb live
- Once temperature stays at or above **70°C** (`GPU_TEMP_THRESHOLD_C`) for 2
  minutes, the `GPUHighTemperature` alert transitions to `firing`
- The standalone Prometheus + Alertmanager stack sends it to the Slack
  `#alert-demo` channel

**Run**:
```bash
# on the bastion
~/scenario2-alert-start.sh

# or locally
./harness.sh scenario2-alert-demo
```

**Watch**:
- Grafana: https://gpu-grafana-route-gpu-monitoring.apps.myocp.sandbox4099.opentlc.com
  (`admin` / `redhat`) → Dashboards → **GPU Control - Tier 1 (Infra Global View)**
- Slack `#alert-demo` channel

**Timing**: the GPU reaches 70°C within tens of seconds to a few minutes after
load starts (measured peak ~82°C — g5/g6 instances never come close to 85°C,
which is why the threshold is set as low as 70°C). Once it hits 70°C, the
alert fires after it **holds for 2 minutes** — Slack delivery follows within
seconds of that.

**Cleanup**:
```bash
~/scenario2-alert-stop.sh
# or: ./harness.sh scenario2-alert-demo-stop
```
After the pod is deleted and temperature drops, the alert automatically
transitions to `resolved` and Slack gets a resolved message too.

---

## Scenario 3 — GPU Power Capping (Green AI)

> **Status: fully wired into the harness + measurement-validated (2026-08-13).**

**What it shows**: lowering a GPU's power limit drops its power draw
immediately, visible live on the dashboard. The original intent was to
demonstrate the common Green AI expectation that "performance loss is small
while power drops a lot" (see the "Green AI" section above) — but **measuring
it against a 100%-saturated workload produced the opposite result (performance
loss exceeding power savings)**, so the workload was redesigned as a bursty
pattern (short compute bursts followed by idle gaps, closer to real inference
serving) and re-measured. Even that didn't clear breakeven on g6.2xlarge (L4,
40-72W) — but **switching to g5.2xlarge (A10G, 100-300W), a card with a much
larger power budget, and re-measuring the same way actually found a "loss <
savings" region (120W, average of 0.88x across repeated measurements)** —
directly confirming that this theory holds better the larger a card's
absolute power budget is. See the four measured datasets below (the default
target is L4's bursty pattern; A10G is deployed separately via
`DEMO_NAMESPACE`/`POWERCAP_INSTANCE_TYPE`).

**Setup**:
- The `power-load` pod runs `BURST_COUNT` (default 3) back-to-back 8192×8192
  FP32 matmuls, then sleeps `IDLE_SEC` seconds (default 0.5) — a duty-cycled
  workload standing in for the short request/wait pattern of real inference
  serving (g6.2xlarge, NVIDIA L4 — default/max power limit measured at 72W,
  minimum settable limit 40W). It prints `throughput: N requests/sec` on a
  5-second window to stdout, so `oc logs` gives a live performance readout
  (`torch.cuda.synchronize()` is required to measure the actual GPU-completion
  point — without it, CUDA's async queuing makes the throughput number
  meaningless)
- `./harness.sh scenario3-powercap-start` automatically provisions the
  g6.2xlarge GPU MachineSet (if missing) and then deploys the `power-load`
  pod — runs immediately with no extra prep even on a cluster freshly
  installed via `all`
- On the node the workload lands on, `nvidia-smi -pl` sets the power limit
  inside that node's `nvidia-driver-daemonset` pod (the driver pod's name has
  the RHCOS version baked in, so it's looked up via the
  `app.kubernetes.io/component=nvidia-driver` label — note that the
  `app=nvidia-driver-daemonset` label does **not** exist)
- Visible as an immediate drop on Grafana's Tier1 "Power Draw per GPU" panel
  (within the next scrape interval, ~30s)

**Run**:
```bash
# locally
./harness.sh scenario3-powercap-start        # provisions g6.2xlarge + deploys power-load pod (default: burst x3 + idle 0.5s)
./harness.sh scenario3-powercap-apply 60     # cap at 60W — the best-balanced point tested
./harness.sh scenario3-powercap-apply        # no argument resets to the default (72W)
./harness.sh scenario3-powercap-stop         # delete the pod + reset the power limit

# to re-test with a different idle gap (redeploy required — a pod's command/args are immutable)
oc delete pod power-load -n gpu-powercap-scenario-3
IDLE_SEC=1 ./harness.sh scenario3-powercap-start

# or directly on the bastion
~/scenario3-powercap-start.sh
~/scenario3-powercap-apply.sh 60
~/scenario3-powercap-stop.sh
```

**Measured result 1 — 100%-saturated workload (reference only, not the current default; equivalent to `IDLE_SEC=0`)**:

| Power cap | power.draw | Power saved (vs 72W) | Throughput (matmul/sec) | Perf lost (vs 72W) | Loss/savings ratio |
|---|---|---|---|---|---|
| 72W (default) | 71.58W | — | 10.66 | — | — |
| 65W | 65.11W | -9.7% | 9.44 | -11.4% | 1.18x |
| 60W | 59.61W | -16.7% | 8.60 | -19.3% | 1.16x |
| 50W | 49.86W | -30.6% | 6.26 | -41.3% | 1.35x |

**Measured result 2 — bursty workload, `IDLE_SEC=0.5` (current default, recommended)**:

| Power cap | avg power.draw (20 samples/5s) | Power saved (vs 72W) | Throughput (req/sec) | Perf lost (vs 72W) | Loss/savings ratio |
|---|---|---|---|---|---|
| 72W (no cap) | 51.02W | — | 1.31 | — | — |
| 60W | 47.74W | -6.4% | 1.225 | -6.5% | **1.02x (nearly 1:1)** |
| 50W | 43.27W | -15.2% | 1.08 | -17.6% | 1.16x |
| 45W | 40.72W | -20.2% | 1.01 | -22.9% | 1.13x |

Cross-checked against Thanos Querier (`DCGM_FI_DEV_POWER_USAGE`, the same
datasource Grafana reads) — matches the nvidia-smi readings, confirming the
drop shows up on Grafana's "Power Draw per GPU" panel as-is.

**Measured result 3 — an idle gap that's too long (`IDLE_SEC=3`) makes capping meaningless (a lesson learned)**:

Redeploying with `IDLE_SEC=3` and measuring showed the average power draw
*with no cap applied* already sitting at **38.94W** — below L4's minimum
settable power limit (`power.min_limit=40W`). In other words, the workload is
idle enough of the time that no valid cap (40-72W) has any measurable effect
on average power (the cap always sits above the workload's natural average
consumption). For reference, true idle power with no pod running at all is
**16.72W** — a 0.5s idle window doesn't get anywhere near that (suspected
cause: the L4's P-state transitions have second-scale latency — 0.5s is too
short to fully drop, and 3s is so long that the cap never binds at all).

**L4 conclusion**: switching to the bursty pattern clearly improved the
loss/savings ratio over the 100%-saturated case (worst case 1.35x → best case
1.02x). Even so, this specific GPU (L4) and workload combination never
achieved "performance loss < power savings" (ratio below 1.0) at any tested
point — **60W is effectively the breakeven point (1.02x) and the most
reasonable of the points tested.**

**Measured result 4 — switching to a card with a bigger power budget (A10G, g5.2xlarge) reveals a genuine win region**:

Hypothesizing that L4 failed because the card's own power budget is too small
to leave much boost headroom to trim, the same bursty workload was deployed
(`DEMO_NAMESPACE=gpu-powercap-a10g POWERCAP_INSTANCE_TYPE=g5.2xlarge
./harness.sh scenario3-powercap-start`) onto the g5.2xlarge (NVIDIA A10G,
`power.min_limit=100W` / `power.default_limit=power.max_limit=300W`) node
already running in the cluster, to re-verify. **Each point was measured twice,
independently, to check reproducibility**:

| Power cap | avg power.draw | Power saved | Throughput (req/sec) | Perf lost | Loss/savings ratio (run 1 → run 2) |
|---|---|---|---|---|---|
| 300W (no cap) | 144.62W → 144.57W | — | 1.56 → 1.56 | — | — |
| **120W** | 106.78W → 105.18W | -26.2% → -27.3% | 1.19 → 1.195 | -23.7% → -23.4% | **0.90x → 0.86x (avg 0.88x, favorable)** |
| 100W (floor) | 99.61W → 97.76W | -31.1% → -32.4% | 0.9925 → 0.995 | -36.4% → -36.2% | 1.17x → 1.12x (avg 1.15x, unfavorable again) |

Baseline, 120W, and 100W all reproduced within 2% across the two runs. **120W
is clearly below breakeven (average 0.88x)** — clearing a line that L4 never
managed at any tested point on A10G. Pushing further down to the floor (100W)
flips it unfavorable again, the same pattern seen on L4 — "trimming only the
boost region is a win; cutting into the normal operating range is a loss
again" holds consistently across both GPUs.

**Overall conclusion**: whether power capping is a net win or loss can't be
generalized from a single GPU — it depends on **the card's absolute power
budget and how aggressively the cap is set.** Based on these measurements:
- Small card (L4, 40-72W): no win region found within the tested range (best
  case 60W, at breakeven — 1.02x)
- Large card (A10G, 100-300W): a clear win region exists (120W, average
  0.88x) — but pushing to the floor (100W) flips it back to a loss
For the demo, avoid overclaiming "cutting power is always a win" — show the
data on how workload duty cycle (saturated vs. bursty), the card's absolute
power budget, and how hard the cap is set all shape the outcome. The scatter
plot below makes that case in a single view (power saved vs. performance
lost, with the breakeven line, across all 3 L4/A10G series).

**[Power saved vs. performance lost scatter plot →](https://claude.ai/code/artifact/aa3204e9-0ca9-4c43-b041-a154efd8d0ec)**

---

## Scenario 4 — GPU Node Fault Isolation and Automatic Rescheduling

> **Status: fully wired into the harness + measurement-validated (2026-08-14).**

**What it shows**: when a GPU node develops a fault, the infra team just has
to isolate it (cordon & drain) — the workload reschedules onto a healthy GPU
node automatically, no human moving it by hand. Reproduces the doc's
[Scenario 1] "infra-team control action" (cordon & drain, force-evict the
offending pod, reschedule to a healthy node) exactly.

**Why we don't reproduce a real hardware fault**: there's no safe way to
force an XID error via `nvidia-smi`, and actually damaging a cloud GPU is
obviously out of the question. Instead, we assume "DCGM caught repeated XID
errors on this node" and execute the infra team's **response action** (cordon
& drain) directly — a natural continuation of the XID Errors panel/alert
structure already shown in Scenario 2.

**Setup**:
- `fault-workload` is deployed as a **Deployment (not a bare Pod)** — this is
  what lets the controller re-create the pod automatically once its node is
  drained (a bare Pod just disappears when deleted; it doesn't come back on
  its own)
- No GPU flavor pin (no `nodeSelector`) — the scheduler places it on whichever
  GPU node (g5 or g6) has room
- Reuses the same PyTorch 8192×8192 matmul load container as Scenarios 1-3

**Run**:
```bash
# locally
./harness.sh scenario4-fault-start      # deploy fault-workload, note which node it landed on
./harness.sh scenario4-fault-trigger    # cordon+drain that node -> confirm auto-reschedule
./harness.sh scenario4-fault-stop       # cleanup (delete the deployment + uncordon all GPU nodes)

# or directly on the bastion
~/scenario4-fault-start.sh
~/scenario4-fault-trigger.sh
~/scenario4-fault-stop.sh
```

**Watch**:
```bash
oc get nodes -l nvidia.com/gpu.present=true -w   # watch the cordoned node go SchedulingDisabled
oc get pods -n gpu-fault-scenario-4 -o wide -w   # watch the pod reschedule to the other node
```
- Grafana Tier1 "GPU Utilization by Node" panel — the isolated node drops to
  0%, the node it moved to climbs to 100%, live

**Measured result** (2026-08-14): with `fault-workload` running on
`ip-10-0-17-5.ec2.internal`, triggering the fault → cordon → drain (evicts
all non-daemonset pods, including `fault-workload`) → the Deployment
controller immediately creates a new pod → it's auto-scheduled onto
`ip-10-0-1-245.ec2.internal` (the other GPU node) → confirmed `Running`
within about a minute. Cross-checked GPU utilization via Thanos Querier —
the original node accurately reads 0%, the new node reads 100%.

**Timing**: the whole cycle is **under a minute** — much faster than
Scenarios 1/3 (~10 min each), since there's no new instance to provision.
It does require both g5 and g6 GPU nodes to already be up (there has to be a
"healthy node" to reschedule onto) — either the default state (1 each) or the
temporarily-scaled-to-2 state right after Scenario 1 both work fine.

**Cleanup**: `scenario4-fault-stop.sh` deletes the deployment and uncordons
all GPU nodes in one call, so even if you stop mid-trigger, this one script
returns the cluster to a clean state.

---

## Scenario 5 — Bad Code Detection (Bad Code Penalty)

> **Status: fully wired into the harness + measurement-validated. Sequential
> on 2026-08-20 (sandbox G/VT vCPU quota only allows 1 GPU node) ->
> concurrent via GPU time-slicing on 2026-08-21 morning -> **back to
> sequential, final, same afternoon**. Reason: with time-slicing, two pods
> sharing the physical GPU made Grafana's per-pod GPU_UTIL panel render
> broken/discontinuous lines. Root cause: DCGM metrics like
> `DCGM_FI_DEV_GPU_UTIL` are **per-device, not per-process** — when
> time-slicing lets multiple pods take turns on the same physical GPU, DCGM
> can only attribute the metric to one "owner" pod per scrape, and which pod
> wins can flip between scrapes (measured: 2 pods concurrently `Running`,
> but only 1 series existed, with labels behaving unexpectedly). This isn't
> a config mistake in this project — it's a fundamental observability
> limitation of time-slicing itself (which multiplexes compute cycles
> without isolation, unlike MIG). Reverted to two fully separate scripts,
> each getting the whole physical GPU to itself for 3 minutes, in sequence.**

**What it shows**: how much a single `DataLoader` setting — `num_workers` —
can idle an expensive GPU, using the exact same training code, measured and
graphed. Reproduces the doc's [Doc Scenario 3] "the GPU sits idle because of
a Data Loader bottleneck" using the actual PyTorch mechanism (not a `sleep`
standing in for it — a real difference in DataLoader worker count).

**Why compare via `num_workers`**: with `num_workers=0`, the main process
fetches samples **one at a time, serially** — the GPU sits completely idle
until an entire batch is ready. With `num_workers>0`, separate worker
processes **prefetch the next batch in the background while the GPU computes
the current one**, cutting idle time sharply. This is the single most common
real-world cause of — and fix for — "why is my GPU utilization so low."

**Setup**:
- Both pods run **identical code** — `Dataset.__getitem__` sleeps 0.2s per
  sample (standing in for real image decode/augmentation cost), and each
  "training step" runs a 4096×4096 matmul 10 times per batch (32 samples)
- `bad-code-workload`: `num_workers=0`
- `efficient-workload`: `num_workers=4`
- **Gotcha**: with `num_workers>0`, PyTorch passes tensors between worker and
  main processes via `/dev/shm` (shared memory) — the container default of
  ~64MB is too small and crashes with `Bus error` /
  `DataLoader worker exited unexpectedly`. Fixed by mounting an
  `emptyDir(medium: Memory, sizeLimit: 1Gi)` at `/dev/shm` (found and fixed
  via measurement on 2026-08-14)

**How the training code works (brief)**:
```python
step = 0
w = torch.rand((4096, 4096), device="cuda")
for batch in loader:                  # DataLoader hands over one batch at a time
    x = batch.to("cuda")
    for _ in range(10):
        y = torch.matmul(w, w)        # GPU compute -- identical for both pods
    torch.cuda.synchronize()
    step += 1
    if step % 5 == 0:
        print(f"step={step}", flush=True)   # progress line every 5 steps
```
With `num_workers=0`, this `for batch in loader:` line blocks in the main
process for 0.2s × 32 samples (~6.4s) on every single batch before moving
on. With `num_workers=4`, separate worker processes prefetch the next batch
in the background while the GPU is busy with `matmul`, so the main loop
barely waits at all — the only code difference between the two workloads is
that one `num_workers` value.

**How "throughput" (step count) is actually measured**:
```bash
oc logs "$1" -n "${DEMO_NAMESPACE}" 2>/dev/null | grep -oE 'step=[0-9]+' | tail -1 | cut -d= -f2
```
After sleeping for `OBSERVE_SECONDS`, every `step=N` line in that pod's logs
is matched and the **last one** is taken as the count. So "throughput" here
means "how many batches (32 samples each) got fully processed in the same
wall-clock window" — a direct proxy for how much the GPU actually worked
instead of sitting idle. Since both workloads run the exact same compute
(60 matmuls per step), the step-count gap reflects nothing but how fast each
one could feed the next batch to the GPU — i.e., purely the DataLoader
bottleneck.

**Run (sequential, two fully separate scripts)**: `bad-code-workload` and
`efficient-workload` each have their own script — run them one after the
other and each gets the whole physical GPU to itself for
`OBSERVE_SECONDS` (default 180s / 3 minutes).
```bash
# locally
./harness.sh scenario5-badcode-start      # deploys bad-code-workload alone, observes 3min, prints result, cleans up
./harness.sh scenario5-efficient-start    # then efficient-workload alone, same duration
./harness.sh scenario5-badcode-stop       # safety net (start already cleans up at the end of each)

# adjust the observation window (default 180s each)
OBSERVE_SECONDS=120 ./harness.sh scenario5-badcode-start
OBSERVE_SECONDS=120 ./harness.sh scenario5-efficient-start
```

**Watch**:
- Each script's own output — steps reached over the observation window
- Grafana Tier1 "GPU Compute vs Memory Utilization (Cluster Avg)" —
  fleet-wide average, both runs appear back to back on the timeline (not
  simultaneous, but clearly contrasted in sequence)
- Grafana Tier2 "GPU Utilization per Pod" / "GPU Memory Used per Pod" —
  already side by side in the same row, giving a clean per-pod
  compute-vs-memory comparison
- Grafana Tier2 "DataLoader Throughput (steps/sec)" — driven by
  `train_steps_total`, a counter the script exposes itself, so it's
  accurate regardless of scrape timing

**Measured result (2026-08-21, sequential, observed over 100s — the real run uses the 180s default)**:

| Workload | Throughput (steps, same 100s window) |
|---|---|
| `bad-code-workload` (num_workers=0) | 10 |
| `efficient-workload` (num_workers=4) | 50 (5x) |

**Tuning — increased matmul reps from 10 to 60 (2026-08-21)**: originally 10
matmul reps took only 0.33s of compute — far shorter than Prometheus's 30s
scrape interval, so the GPU_UTIL graph mostly read 0% for *both* workloads
with only occasional lucky spikes (measured duty cycle: bad-code ~5%,
efficient only ~16.5% — not "0% vs 100%," just two flavors of "mostly
idle"). Bumping reps to 60 (compute time ~1.88s) pushed `efficient-workload`'s
compute time past its 4-worker data-production time (~1.6s), making it
genuinely **compute-bound** — and the measured graph pattern split cleanly:
- `efficient-workload`: 4 consecutive samples (40s) all read 97-100%
  GPU_UTIL — **continuously high, no gaps**
- `bad-code-workload`: `100,100,100,0,0,0,100,100` — **clearly alternates
  on and off**

**How to read the graph (important)**: both workloads hit 100% during an
actual compute burst — the peak value itself is the same. The signal to
look for is **whether it drops to 0% in between** — bad code idles
completely between bursts while waiting for the next batch, so the graph
shows clear gaps; efficient has the next batch ready ahead of time, so it
stays unbroken. The step-count throughput the script itself prints remains
the most reliable number either way.

**Note — GPU time-slicing was tried and reverted (2026-08-21)**: made the
single physical GPU report as 2 schedulable `nvidia.com/gpu` units
(`ClusterPolicy.spec.devicePlugin.config` -> `time-slicing-config`,
`replicas: 2`) and got both pods genuinely `Running` at once (the 5x
throughput gap held up fine). But Grafana's per-pod GPU_UTIL panel showed
broken lines — measured directly: with 2 pods concurrently
`Running`, only 1 DCGM series existed, with labels behaving unexpectedly.
DCGM metrics like `DCGM_FI_DEV_GPU_UTIL` are per-device, not per-process, so
when time-slicing lets multiple pods take turns on one physical GPU, DCGM
can only attribute the metric to one pod per scrape, and it can flip
between scrapes — a real observability limitation of time-slicing itself
(no isolation, unlike MIG), not a misconfiguration here. Reverted
(`ClusterPolicy.spec.devicePlugin.config` removed, node allocatable
confirmed back to 1) since a clean sequential run makes for a better demo
graph. Time-slicing itself still works fine on every GPU generation here
(T4/A10G/L4, unlike MIG) and remains a valid option for a scenario that
needs real concurrency but doesn't care about per-pod graph accuracy.

**Final 3-way comparison (2026-08-21, measured from a real Grafana Tier2
screenshot)**: ran all three scripts in sequence (`bad-code` ->
`efficient` -> `more-efficient`) and watched "GPU Utilization per Pod",
"GPU Memory Used per Pod", and "DataLoader Throughput (steps/sec)"
together:

![Scenario 5 result: Tier2 dashboard comparing GPU utilization, memory, and throughput across the bad-code/efficient/more-efficient workloads](image/scenario5-result.png)

| Workload | GPU_UTIL pattern | Throughput (steps/sec) | GPU memory |
|---|---|---|---|
| `bad-code-workload` (num_workers=0, matmul×10) | mostly 0%, one brief spike (~90%) | ~0.13–0.15 | ~380MB |
| `efficient-workload` (num_workers=4, matmul×10) | alternates 0%↔100% (2 spikes) | ~0.5–0.65 | ~430MB |
| `more-efficient-workload` (num_workers=4, matmul×60) | rises once, then **continuously 100%, no gaps** | ~0.35–0.55 | ~450MB |

Split exactly as intended — bad-code is mostly idle, efficient spikes
repeatedly (not yet fully continuous), more-efficient is unbroken once it
ramps up.

One interesting wrinkle: **raw throughput (steps/sec) for
`more-efficient` is actually slightly lower than `efficient`'s.**
`efficient` is bottlenecked by data production (~1.6s, the num_workers=4
limit) since its compute (matmul×10, ~0.33s) finishes faster than that;
`more-efficient` deliberately lengthened compute (matmul×60, ~1.88s) past
that same data-production time, making **compute itself the bottleneck**
instead. Making the graph look clean traded away some raw steps/sec — a
real tradeoff the measurement makes visible rather than hiding. GPU memory
sits in a similar ~380–450MB range for all three, which makes sense: the
model (one 4096×4096 tensor) and batch size are identical, so memory usage
doesn't depend on num_workers or matmul rep count.

**Not done yet — PriorityClass downgrade + preemption**: showing the doc's
"infra team response" (code-improvement request + PriorityClass downgrade to
Low, immediate preemption target under resource pressure) is Scenario 6.

---

## Scenario 6 — PriorityClass Downgrade and Preemption in Practice

> **Status: fully wired into the harness + measurement-validated (2026-08-14).**

**What it shows**: say the infra team downgraded a team's PriorityClass to
Low after Scenario 5 flagged it — does that actually do anything? The moment
capacity gets contested, Kubernetes **automatically** evicts (preempts) that
team's pod and hands the GPU to a normal-priority workload. Reproduces the
doc's "PriorityClass downgraded to Low → immediate preemption target under
resource pressure" directly.

**Core design — removing the race with the autoscaler**: `bad-code-workload`
and `legitimate-workload` are both pinned to the same GPU flavor
(g5.2xlarge, 1 node / 1 GPU) so that capacity is genuinely contested — but
left alone, `MachineAutoscaler` could just add a second node and resolve it
without any preemption at all (a race condition). To remove that,
`scenario6-preempt-start.sh` temporarily **caps g5's MachineAutoscaler `max`
at its current replica count (1)**, ruling out scale-out entirely so
preemption is the only path forward. `scenario6-preempt-stop.sh` restores it
to 2.

**Setup**:
- `PriorityClass/low-priority-team` (value: -1000000) — the "assigned to the
  team flagged in Scenario 5" concept
- `bad-code-workload`: `priorityClassName: low-priority-team`, pinned to
  g5.2xlarge, requests 1 GPU — occupies the only GPU
- `legitimate-workload`: default priority (no PriorityClass set, default
  value 0 > -1000000), also pinned to g5.2xlarge, requests 1 GPU

**Run**:
```bash
# locally
./harness.sh scenario6-preempt-start      # bad-code-workload takes the GPU at low priority
./harness.sh scenario6-preempt-trigger    # deploy legitimate-workload -> confirm preemption
./harness.sh scenario6-preempt-stop       # cleanup + restore MachineAutoscaler max (2)
```

**Watch**:
```bash
oc get pods -n gpu-preempt-scenario-6 -w
oc get events -n gpu-preempt-scenario-6 --field-selector reason=Preempted
```

**Measured result** (2026-08-14): with `bad-code-workload` `Running` on g5's
only GPU at `low-priority-team` priority, deploying `legitimate-workload`
(default priority) produced this event **about 34 seconds later**:
```
Normal   Preempted   pod/bad-code-workload   Preempted by pod 9a6d9af0-... on node ip-10-0-1-245.ec2.internal
```
`bad-code-workload` was evicted (`Gone`), and `legitimate-workload` took over
the GPU as `Running`. The explicit "Preempted by pod ..." event is the
evidence this was a real preemption, not a coincidental restart.

**Cleanup**: `scenario6-preempt-stop.sh` handles both pod deletion and
restoring the MachineAutoscaler max (2) in one call — even stopping mid-
trigger, this one script returns the cluster to its normal state (min=1/
max=2 on each flavor).

---

## Scenario 7 — Responding to a Cost Overrun (Chargeback & Quota)

> **Status: fully wired into the harness + measurement-validated (2026-08-14).**

**What it shows**: once the infra team decides a team is out of budget, a
single `ResourceQuota` is enough to stop them from growing their GPU
footprint any further — and it's rejected **immediately at admission time**,
with no scheduling wait at all. Unlike Scenarios 4 and 6 (which resolve
through scheduling/preemption), this is the fastest scenario of all — there's
no wait whatsoever.

**Cost visibility**: added an **"Estimated GPU Cost ($/hr)"** stat to Tier1's
"Fleet Overview" row — computed as `sum(allocated GPUs) x $1.10` (an assumed
blended rate between g5.2xlarge and g6.2xlarge on-demand pricing). This is
explicitly an **estimate**, and its panel description says so — it isn't
wired to a real billing system, so don't overstate it in the demo as an exact
match to the actual AWS bill.

**Setup**:
- `team-workload-1`: requests 1 GPU, deployed (stands in for the team's
  "already in use" footprint)
- Infra team applies a `ResourceQuota` (`requests.nvidia.com/gpu: "1"`) —
  capped at exactly the current usage (the endpoint of the doc's "immediately
  cap it once the budget hits 70%" response)
- `team-workload-2`: an attempt to request one more GPU — with the quota
  already full, the API server **rejects it immediately**

**Run**:
```bash
# locally
./harness.sh scenario7-chargeback-start      # deploy team-workload-1 + apply the quota
./harness.sh scenario7-chargeback-trigger    # attempt team-workload-2 -> confirm the instant rejection
./harness.sh scenario7-chargeback-stop       # cleanup
```

**Measured result** (2026-08-14): with the `ResourceQuota` applied at
`requests.nvidia.com/gpu: "1"` (usage also at 1), deploying `team-workload-2`
produced:
```
Error from server (Forbidden): error when creating "STDIN": pods "team-workload-2" is
forbidden: exceeded quota: gpu-quota, requested: requests.nvidia.com/gpu=1,
used: requests.nvidia.com/gpu=1, limited: requests.nvidia.com/gpu=1
```
The pod was never even created (doesn't show up in `oc get pods`) — blocked
at the API server's admission stage before the scheduler ever got involved.
Faster than Scenario 4 (cordon+drain, ~1 min) and Scenario 6 (preemption,
~34s), and the most deterministic of all — no wait, no race condition to
worry about.

**Not done yet — Node affinity (off-hours/Spot only)**: the doc's second
response action ("force a Node affinity change so jobs only run during
off-hours or on spare Spot instances") isn't implemented — the cluster's GPU
MachineSets are On-Demand instances, there's no real Spot node to target, and
standing one up is a separate MachineSet exercise out of scope here.

---

## Scenario 8 — KServe + vLLM Scale-Down on Idle

> **Status: wired into the harness + measurement-validated. Scale-down
> works correctly; scale-up has a confirmed structural limitation
> (2026-08-20).**

**What it shows**: in a real GPUaaS platform, an idle GPU shouldn't need a
human (or a script) watching it and deleting things — **the serving
platform itself should give it back automatically based on real traffic**.
Serving a vLLM model through KServe, replicas scale to 0 (full GPU release)
automatically once requests stop. (As measured below, "scales back up
automatically the moment a new request arrives" does **not** hold for this
particular setup — the honest reason, and the alternative, are covered too.)

**Why KEDA instead of Knative Serverless**: KServe's scale-to-zero is
normally a feature of its Knative (Serverless) deployment mode, but this
cluster's RHOAI is deliberately installed in `RawDeployment` mode in
`remote/rhoai.sh` specifically to avoid a Service Mesh dependency
(`defaultDeploymentMode: RawDeployment`, `serving.managementState: Removed`).
RawDeployment doesn't support scale-to-zero on its own — but Red Hat
documented an officially-supported way to get it anyway in late 2025: add the
**OpenShift Custom Metrics Autoscaler (KEDA-based) operator**, disable
KServe's built-in HPA (`serving.kserve.io/autoscalerClass: external`), and
replace it with a KEDA `ScaledObject` that supports `minReplicaCount: 0`.

**Setup**:
- `openshift-custom-metrics-autoscaler-operator` (namespace `openshift-keda`,
  channel `stable`) + a `KedaController` CR
- An `InferenceService` serving `Qwen/Qwen2.5-0.5B-Instruct` through RHOAI's
  actual vLLM `ServingRuntime` (`vllm-cuda-runtime`), `RawDeployment` mode
- A `KEDA ScaledObject` (`minReplicaCount: 0`, `maxReplicaCount: 1` — only
  one GPU exists) triggered on the Thanos Querier vLLM queue metric
  (`vllm:num_requests_waiting`)

**Run**:
```bash
# locally
./harness.sh scenario8-kserve-vllm-start      # deploy InferenceService + KEDA ScaledObject
./harness.sh scenario8-kserve-vllm-load       # send a real inference request (manually scales up from 0 if needed)
./harness.sh scenario8-kserve-vllm-stop       # cleanup

# or directly on the bastion
~/scenario8-kserve-vllm-start.sh
~/scenario8-kserve-vllm-load.sh
~/scenario8-kserve-vllm-stop.sh
```

**Real problems hit while building this (all fixed, encoded in the scripts)**:
1. **`storageUri: hf://...` doesn't work out of the box** — RHOAI 2.25.8
   ships no `ClusterStorageContainer` registering the `hf://` regex, so one
   had to be created (`hf-hub`, using RHOAI's own
   `odh-kserve-storage-initializer-rhel9` image). Once added, it genuinely
   pulled from Hugging Face (model download: **11 seconds**).
2. **CUDA graph capture hangs forever on this T4** — confirmed via
   `nvidia-smi`: 0% GPU utilization, 27W (near-idle) power draw, stuck for
   3+ minutes at a fixed capture step. `--enforce-eager` (skips graph
   capture) fixes it — not a one-time workaround, this needs to stay on
   permanently for this GPU.
3. **Default 8Gi container memory limit gets OOMKilled** — the process dies
   (exit 137, OOMKilled) right after model load finishes. Raising it to 12Gi
   fixed it.
4. **A rolling update deadlocks on a single-GPU cluster** — every time #2/#3
   above required a spec change, the old ReplicaSet's pod kept holding the
   only GPU and crash-looping while the new ReplicaSet's pod sat `Pending`
   forever with nowhere to schedule. `oc delete rs <old-replicaset>` to
   force it out is required — a pattern that repeated every single time.

**Measured results**:
- Cold start (scheduled → Ready): model download (11s) + vLLM eager-mode
  load, **~75-90 seconds total**
- Real inference confirmed: `"The capital of France is"` → `" Paris. It is
  the most populous city in Europe"` (correct, coherent completion)
- KServe's own HPA is genuinely absent (`autoscalerClass: external`
  confirmed working) — only `keda-hpa-qwen-vllm-scaledobject` exists
- **Scale-down (1→0)**: near-instantaneous — KEDA deactivated the target on
  its very first reconcile after the ScaledObject became Ready
  (`KEDAScaleTargetDeactivated`), without even waiting a full polling
  interval (15s)
- **Scale-up (0→1, on request) — confirmed NOT working**: querying Thanos
  for `vllm:num_requests_waiting` while at 0 replicas returns `"result":[]`
  — a completely empty result, not even a zero — because there's no pod to
  emit that metric in the first place. KEDA polls metrics from outside the
  request path, so it has no way to observe an incoming request when
  nothing is running to report on it.
- **A real request at 0 replicas**: `curl` fails at **DNS resolution**
  (`Could not resolve host`), a step earlier than "connection refused" —
  because the predictor `Service` is headless (`ClusterIP: None`), and DNS
  returns no records at all once it has zero backing endpoints.

**Conclusion — what Red Hat actually recommends**: even the Red Hat article
this was built from uses `minReplicaCount: 1` in its own example (not 0) —
meaning Red Hat's own documented guidance for RawDeployment+KEDA targets
**elastic scaling among already-warm replicas under load**, not genuine
wake-from-zero. True request-triggered scale-from-zero is, by Red Hat's own
architecture, a **KServe Serverless (Knative)** feature — precisely the
dependency this whole design avoided to sidestep Service Mesh. (The KEDA
HTTP Add-on is a community project that can add request-based wake-up
without full Service Mesh, but Red Hat's official support for it wasn't
confirmed — worth evaluating in a future session.) For the demo: present
scale-down as fully automatic and scale-up as currently requiring a
manual/external trigger — an honest tradeoff, not a bug.

Sources: [How to set up KServe autoscaling for vLLM with KEDA](https://developers.redhat.com/articles/2025/09/23/how-set-kserve-autoscaling-vllm-keda),
[Custom Metrics Autoscaler on OpenShift](https://www.redhat.com/en/blog/custom-metrics-autoscaler-on-openshift),
[Boost AI efficiency with GPU autoscaling on OpenShift](https://developers.redhat.com/articles/2025/08/12/boost-ai-efficiency-gpu-autoscaling-openshift)

---

## Scenario 9 — KServe Serverless (Knative) + vLLM, Real Scale-to-Zero

> **Status: complete, measurement-validated (2026-08-21, built and verified
> live on the sandbox623 cluster). Flips Scenario 8's measured limitation
> (KEDA never wakes on a real request at 0 replicas) around, and confirms
> whether Knative's Activator sitting in the request path actually solves
> it.**

**What it shows**: same model (`Qwen/Qwen2.5-0.5B-Instruct`), same vLLM
config, deployed via Serverless+Knative to check whether **genuine
request-triggered 0→1 wake** actually works — this is the deployment mode
KServe's scale-to-zero was originally designed around.

**Setup (as actually applied)**:
- `OpenShift Serverless Operator` (`serverless-operator`, stable channel) +
  `Red Hat OpenShift Service Mesh 2` (`servicemeshoperator`, stable
  channel) — **Service Mesh turned out to be a hard requirement**: RHOAI's
  `DSCInitialization` hardcodes the `ServiceMeshControlPlane` name/namespace
  as `istio-system/data-science-smcp`; any other name silently produces
  `KserveReady=False (ServiceMesh is not ready)`.
- `ServiceMeshMemberRoll/default` listing `knative-serving` plus the
  namespace hosting the InferenceService (`gpu-kserve-scenario-9`)
- DataScienceCluster: `kserve.serving.managementState: Managed` — RHOAI's
  own operator then creates the `KnativeServing` CR automatically
- `InferenceService` with `serving.kserve.io/deploymentMode: Serverless`
  and `minReplicas: 0` (instead of RawDeployment) — reusing everything
  already confirmed in Scenario 8 (`--enforce-eager`, 12Gi memory, same
  model). `ServingRuntime` is namespace-scoped, so it needed its own copy in
  this namespace too.

**Real problems hit (all a function of this being a small, first-time
Knative-on-Service-Mesh install)**:
1. Knative's default HA control plane (activator etc. want 2 replicas each)
   had nowhere to schedule — needed one more worker node
2. The Knative `Gateway` resource's selector (`knative: ingressgateway`)
   didn't match the actual istio-ingressgateway pod's label (`istio:
   ingressgateway`) — TLS SNI handshakes failed outright until the
   Deployment got the matching label added
3. `automountServiceAccountToken: false` (KServe's own default on the
   InferenceService) starved the istio sidecar of the token it needs to
   authenticate to istiod — fixed by switching the SMCP's identity type to
   `ThirdParty` (its own dedicated bound token), since Knative's webhook
   flatly rejects any attempt to override that field on a Revision
4. Mesh-wide STRICT mTLS blocked Knative's own internal metrics scraping,
   which silently prevented scale-down forever — fixed by switching to
   PERMISSIVE
5. Any control-plane pod (activator, autoscaler) that had already been
   running before the above config changes stayed stuck in an
   authentication-failure loop with the old sidecar config — required an
   explicit `oc rollout restart` on each. **Lesson: changing Knative's
   identity/mTLS settings after initial install requires restarting every
   already-running control-plane component, not just applying the new
   config.**

**Measured results (1st pass — `hf://`, re-downloading from Hugging Face Hub
on every cold start)**:
| Metric | Value |
|---|---|
| Cold start (pod created → 3/3 Ready, model loaded) | ~70–110s |
| Warm response time | 0.3–0.5s |
| **Automatic 0→1 wake itself** | **Works** — the key difference from Scenario 8 |
| **Success of the specific request that triggered the cold start** | **Usually fails** — something in the serving path (Activator/gateway) times out around ~60s, shorter than the actual model load time (70–110s), regardless of how long a timeout the client sets. A retry immediately after that failure succeeds instantly, since the pod kept starting in the background and is ready by then |

**Improvement — PVC pre-caching**: found that the `storage-initializer` init
container was re-fetching `hf://Qwen/Qwen2.5-0.5B-Instruct` into a pod-local
`emptyDir` (gone the moment the pod is) on every single cold start →
pre-downloaded the model once into a PVC (`gp3-csi`, `ReadWriteOnce`, 5Gi —
RWX not needed since there's only one GPU node) and switched the
InferenceService's `storageUri` from `hf://...` to
`pvc://qwen-model-cache/`, so later cold starts mount the PVC directly with
no network download at all.

| Metric | Before (`hf://`) | After (`pvc://`) |
|---|---|---|
| Pod created → model ready (`Application startup complete`) | ~70–110s | **~49s** (measured: `01:00:35` → `01:01:24`) |
| The request that triggered the cold start | usually fails, needs a retry | **succeeds** — real response in 50.47s, no retry needed |

**Conclusion**: unlike Scenario 8, Knative Serverless **genuinely wakes up
automatically from zero** — that's the real difference. Initially this
wasn't *fast* (loading an LLM onto a GPU alone took 70–110s, longer than the
serving path's own default timeout). **PVC pre-caching removed the
redundant model re-download, which brought cold start down to ~49s — under
that timeout wall — and the very request that triggers the wake now
succeeds on its own, no retry needed.** ~50s is still slow for something a
user is waiting on in real time, though, so client-side retry-with-backoff
remains good practice as a safety net — consistent with Scenario 10's
already-planned approach of showing the cold-start gap honestly instead of
hiding it.

---

## Scenario 10 — Monitoring a Scale-to-Zero Service (KEDA vs Knative)

> **Status: complete, both metrics and logging measurement-validated
> (2026-08-21).**

**What it shows**: with Scenario 8 (KEDA) and Scenario 9 (Knative) both idle
at 0 replicas, what's actually observable side by side. Replica count needs
to stay visible whether or not a pod exists, and the cold-start-triggering
request itself needs to be shown honestly too — KEDA fails outright, Knative
succeeds after a delay.

**Real problem hit — our standalone Prometheus wasn't seeing
kube-state-metrics at all**: the existing Tier1 dashboard's "Estimated GPU
Cost" panel used `kube_pod_container_resource_requests`, and it turned out
to always be empty when actually queried — that panel had been silently
broken from the start. Two causes:
1. There was no ServiceMonitor scraping kube-state-metrics from our
   standalone Prometheus at all → added one, but the platform's
   kube-state-metrics sits behind kube-rbac-proxy on its `https-main` port,
   so a plain scrape doesn't work — needed to bind `cluster-monitoring-view`
   to the `gpu-alert-prometheus` ServiceAccount, create a token Secret for
   it, and reference that via `authorization.credentials` on the endpoint.
2. The Prometheus CR (`gpu-alert-prom`)'s `serviceMonitorSelector` was
   pinned to `{matchLabels: {app: nvidia-dcgm-exporter}}`, so it silently
   ignored the new ServiceMonitor entirely — had to widen it to `{}` (match
   everything). Note: `oc patch --type=merge` with an empty `{}` does
   **not** clear existing matchLabels (merge patches can't express
   deletion) — needed `--type=json` with a `replace` op to actually take
   effect.
3. kube-state-metrics' own `namespace` label (its kube-rbac-proxy sidecar's
   identity) collides with the workload's real `namespace` label; even with
   `honorLabels: true` the conflicting label gets pushed to
   **`exported_namespace`** instead of being overwritten cleanly (similar
   symptom to the DCGM case, but not identical) — real queries need to
   filter on `exported_namespace`, not `namespace`.

**Monitoring layers (as actually built)**:
1. **Replica count over time** — new "Scale-to-Zero Monitoring (Scenario
   10)" row on the Tier1 Grafana dashboard, two panels:
   `kube_deployment_status_replicas{exported_namespace="gpu-kserve-scenario-8", deployment="qwen-vllm-predictor"}` (KEDA) and
   `kube_deployment_status_replicas{exported_namespace="gpu-kserve-scenario-9", deployment=~"qwen-vllm-serverless-predictor.*"}` (Knative) — works whether or not a pod currently exists.
2. **The cold-start gap, shown honestly** —
   `~/scenario10-scalezero-monitor-demo.sh` sends a real request to each,
   measured live:
   - KEDA (Scenario 8): `Could not resolve host` — fails at DNS resolution outright
   - Knative (Scenario 9): succeeds after 51s with a real response
     (`{"id":"cmpl-...","choices":[...]}`), no retry needed — thanks to
     Scenario 9's PVC-caching fix, the very first request now succeeds
   - The Knative side also demos `oc get pa -n gpu-kserve-scenario-9` live,
     showing `DESIREDSCALE`/`ACTUALSCALE`/`REASON` transition in real time
     (`NoTraffic` → `Queued` → ...)
3. Knative's own control-plane metrics (activator/autoscaler `/metrics` on
   port 9090) were attempted but are **still not working** — flipping
   `config-observability`'s `metrics.backend-destination` from `none` to
   `prometheus` and restarting activator/autoscaler didn't open the port at
   all. This looks like something deeper than a simple config flag, so
   pragmatically fell back to the already-proven kube-state-metrics signal
   instead; Knative's native metrics remain a follow-up investigation.

**Logging — complete, measurement-validated (2026-08-21)**: actually
installed `./harness.sh openshift-logging` (MinIO + Loki Operator +
LokiStack + ClusterLogForwarder) on this cluster, woke Scenario 9 to
generate a real log line, let it scale back to 0 (pod deleted), and
confirmed logs survive: `oc logs <the now-deleted pod>` returns `NotFound`,
but the same logs are still returned from Loki by `kubernetes_pod_name` —
this is the scenario's core proof point.

Four real problems hit along the way (all fixed in `openshift-logging.sh`):
1. **Operator channel names didn't match the docs** — neither
   `loki-operator` nor `cluster-logging` has a `stable` channel. Worse, **the
   same package name exposes different channels per catalog** — the
   `community-operators` version of `loki-operator` only has `alpha`, while
   the `redhat-operators` version (the one actually used) has
   `stable-6.5`/`stable-6.6`. Querying `oc get packagemanifest <name>`
   without pinning the catalog can silently show the wrong catalog's
   channels — always confirm with `--field-selector` or
   `-o custom-columns=...CATALOG:.status.catalogSource`.
2. **No collector pod ever scheduled on the GPU node** — the
   `nvidia.com/gpu:NoSchedule` taint isn't tolerated by the collector
   DaemonSet by default, so every GPU workload's logs (Scenario 8, 9, all of
   them) were never being collected at all. Fixed via
   `ClusterLogForwarder.spec.collector.tolerations`.
3. **LokiStack gateway TLS trust failure** — "self-signed certificate in
   certificate chain". The `logging-loki-ca-bundle` ConfigMap looks like the
   obvious fix but is actually the **wrong CA** (it holds Loki Operator's own
   internal signing CA). The real gateway certificate
   (`logging-loki-gateway-http`) is signed by **OpenShift's platform
   service-ca**, so the correct reference is the standard
   `openshift-service-ca.crt` ConfigMap that's auto-injected into every
   namespace.
4. **403 Forbidden on writes** — `collect-application-logs` only grants
   permission to *read* node-local log files, not to *write* to the
   LokiStack gateway. The actual write permission lives in a separate
   ClusterRole, `logging-collector-logs-writer`
   (`loki.grafana.com/application`, resourceName `logs`, verb `create`), and
   **a ClusterRoleBinding alone wasn't enough** — a RoleBinding in the same
   namespace (`openshift-logging`) was also required before it actually took
   effect.

---

## Scenario 11 — Kueue + Dynamic Resource Allocation (DRA)

> **Status: design confirmed, harness implementation and live validation in
> progress (2026-08-20 — the original version was MachineAutoscaler-based
> "dynamic allocation + reclaim," but that idea is already covered
> separately by Scenario 1 (allocation) and the old Scenario 8 (reclaim), so
> this was redesigned to show a genuinely more sophisticated GPUaaS
> scheduling layer instead: Kueue + DRA. Pushed back to 11 on 2026-08-20 once
> Scenarios 8-9 filled up with the KServe scale-to-zero comparison, KEDA vs.
> Knative).**

**What it shows**: every scenario so far leans on the plain Kubernetes
scheduler plus integer `nvidia.com/gpu: N` counting (Pending →
MachineAutoscaler, PriorityClass → preemption, etc). A real multi-tenant
GPUaaS platform layers **Kueue** (job queueing — per-team quota, fair
sharing, and priority, managed *before* the scheduler ever gets involved) and
**DRA** (Dynamic Resource Allocation — the modern Kubernetes-standard way of
requesting/allocating GPUs via a structured `ResourceClaim` API instead of
the old device-plugin integer count, GA in OpenShift since 4.21) on top of
that.

**Note — no MIG (GPU slicing) here**: one of DRA's headline use cases is
pairing with NVIDIA MIG (splitting one GPU into several). This cluster's GPU
flavors (A10G, L4, and the T4 in g4dn.xlarge) **don't support MIG in
hardware** (MIG needs dedicated partitioning circuitry that only ships on
A100/H100-class datacenter parts — confirmed 2026-08-20). So this scenario
is not about slicing a GPU into pieces; it's about showing that even a
request for one whole GPU goes through Kueue's queue/quota and gets
allocated via DRA's structured claim API. (Note: sharing one GPU across
multiple pods *without* MIG is possible via the separate mechanism of
NVIDIA time-slicing — the idea raised in Scenario 8's discussion.)

**Flow (planned)**:
1. Install Kueue (the Red Hat build of Kueue) — configure a `ClusterQueue`
   with a GPU quota per team `LocalQueue` (its resource flavor references a
   DRA `DeviceClass`).
2. Two teams submit several GPU-requesting Jobs at once, together exceeding
   the quota.
3. The Jobs over quota **sit in Kueue's admission queue** — never even
   handed to the scheduler (not "Pending on the scheduler," genuinely held
   back by Kueue) — `kubectl get workloads` distinguishes Admitted from
   queued.
4. Once an earlier Job finishes and frees quota, a queued Job is admitted
   automatically per Kueue's fair-share/priority rules.
5. The actual GPU allocation happens via `ResourceClaim`/`ResourceSlice`
   (DRA objects) — visibly a structured claim, not a bare
   `nvidia.com/gpu: 1` integer request.

**Harness implementation not written yet**: Kueue/DRA's exact CRD fields and
API versions will be confirmed against this cluster's actual installed
versions before any scripts get written — no speculative YAML, same
verify-against-the-real-cluster discipline used throughout this session.

Sources: [Improve GPU utilization with Kueue in OpenShift AI](https://developers.redhat.com/articles/2025/05/22/improve-gpu-utilization-kueue-openshift-ai),
[Dynamic resource allocation goes GA in Red Hat OpenShift 4.21](https://developers.redhat.com/articles/2026/03/25/dynamic-resource-allocation-goes-ga-red-hat-openshift-421-smarter-gpu),
[Multitenant AI inference with dynamic resource allocation on OpenShift](https://developers.redhat.com/articles/2026/08/03/multitenant-ai-inference-dynamic-resource-allocation-openshift)

---

## Unimplemented Scenarios (for reference, numbered per the original `openshift-monitoring` doc)

The following are not yet automated in the harness. Detection conditions and
the infra-team's response plan are defined in the doc, but there's no actual
implementation (PrometheusRule, automated control action, etc).

### Green AI — RHCOS-based GPU Power Savings

A scenario that uses RHCOS's (Red Hat Enterprise Linux CoreOS) immutability
to declaratively govern node/GPU power. Made up of 3 approaches:

1. **Node Tuning Operator (NTO) based CPU Power Profile** — controlling idle
   CPU power draw on RHCOS nodes via a Tuned Custom Resource. Dev/test nodes
   keep the `powersave` profile, production nodes keep `performance`.
   > **Can't be turned into a measurable scenario on AWS EC2 (confirmed 2026-08-13).**
   > Checked directly on this cluster's worker nodes:
   > - `/sys/class/powercap/` (RAPL — the interface for reading a CPU
   >   package's actual power draw) is **empty**. AWS's Nitro/KVM hypervisor
   >   does not pass RAPL MSRs through to guest VMs — a structural limitation
   >   common to cloud VMs in general, not a limitation of OpenShift or RHCOS.
   > - `/sys/devices/system/cpu/cpu0/cpufreq/` (the standard Linux interface
   >   for switching the governor between `powersave`/`performance`) **does
   >   not exist at all** — the guest kernel has no cpufreq subsystem exposed
   >   to it, so even if Tuned applies the `powersave` profile, there's
   >   nothing to change: it's effectively a no-op.
   > - `turbostat` is also unusable, since MSR access is blocked.
   >
   > The reason the GPU side (Scenario 3) worked is that NVIDIA passes GPU
   > hardware power telemetry straight through to the guest via its own
   > management interface, NVML. AWS keeps that path open (it's core to what
   > a GPU instance is for), but most cloud hypervisors block the
   > general-purpose CPU power-management paths (RAPL/cpufreq). Actually
   > measuring and demonstrating this scenario would require **bare-metal
   > RHCOS nodes** (physical servers, or a bare-metal cloud instance type that
   > passes RAPL through).
2. **NVIDIA GPU Power Capping** — placing an upper limit (in watts) on how
   much power a GPU can draw. Set via `nvidia-smi -i 0 -pl <watt>` (or a
   DaemonSet that runs this automatically at node boot).
   - **Why it works**: under load, a GPU boosts its clocks as high as
     possible to squeeze out performance, and power draw at that point rises
     roughly with the cube of the clock speed. Performance, by contrast,
     rises far more gently — meaning the topmost boost region is "the worst
     region for performance-per-watt." Trimming it cuts power a lot while
     costing little performance.
   - **Concrete example**: lowering a GPU's power limit from 400W to 300W:
     - Power savings: (400 − 300) ÷ 400 = **25% reduction**
     - The measured performance loss in that case isn't 25% — it's only
       **between 5% and 10%**
     - In other words: "power dropped 25% but performance only dropped
       5-10%" — the power savings far outweigh the performance loss, a net
       win.
     - **Caveat**: this is a generic example (for a large GPU / large power
       budget), and it did **not** reproduce when actually measured in
       [Scenario 3] on a g6.2xlarge (L4, 40-72W). On the 100%-saturated FP32
       matmul workload, going 72W→50W cut power by 30.6% but performance
       actually dropped *more*, by 41.3%; even switching to a bursty
       (inference-serving-like, burst+idle) pattern only got the best case
       (72W→60W) down to essentially 1:1 loss-to-savings (1.02x) — breakeven
       at best. "Loss < savings" was not achieved at any tested point. This
       theory holds better the more idle/bursty the workload is, and the
       larger the card's absolute power budget is — and it can fail on a
       card that's already small (like L4) run with only a short idle gap.
       Show [Scenario 3]'s measured tables alongside this claim in the demo
       so it isn't overstated.
3. **Bare-metal / AWS Auto-Shutdown** — fully powering off (scale to 0, or
   IPMI power-off) unused RHCOS worker nodes during weekend/night hours to
   eliminate unnecessary power draw entirely.

- **Currently visibility-only**: Tier1 dashboard's "Total GPU Power Draw",
  "Power Draw per GPU" panels (Power & Memory Capacity row)

---

## Notes

- The scenarios use different namespaces (`gpu-autoscale-scenario-1`,
  `gpu-alert-scenario-2`, `gpu-powercap-scenario-3`, `gpu-fault-scenario-4`,
  `gpu-badcode-scenario-5`, `gpu-preempt-scenario-6`,
  `gpu-chargeback-scenario-7`), so running them simultaneously doesn't
  interfere with each other. One exception: Scenario 6 temporarily caps
  g5.2xlarge's MachineAutoscaler max, so don't run it at the same time as
  Scenario 1 (which uses the same g5.2xlarge autoscaling demo).
- The alerting pipeline is **not** OpenShift's default User Workload
  Monitoring — it's split off into an **independent Prometheus +
  Alertmanager** (the `gpu-monitoring` namespace). See the "GPU monitoring /
  demo control-plane" section of `harness/README.md` for the reasoning and
  background.
- Thresholds/channels etc. can be adjusted on redeploy:
  ```bash
  GPU_TEMP_THRESHOLD_C=70 SLACK_CHANNEL='#alert-demo' \
    SLACK_WEBHOOK_URL='...' ./harness.sh dcgm-alerts
  ```
