# GPU Demo Scenarios

Assumes the `myocp` cluster (OpenShift + OpenShift AI + GPU Operator +
monitoring stack) is already up. This document lays out the customer-demo
scenarios in **presentation order** — that numbering is different from the
`openshift-monitoring` doc's own scenario numbers (1: overheat/fault, 2: GPU
misuse, 3: inefficient code, 4: chargeback). This demo's "Scenario 2 (alert)"
maps to the doc's "Scenario 1", and "Scenario 3 (Power Capping)" maps to the
doc's separate "Green AI" section.

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

## Idea — GPU Fault Scenario (not started)

User-proposed: a scenario showing the response to an actual GPU hardware
fault (XID errors, etc). This connects to the doc's [Scenario 1] "infra-team
control actions" (cordon & drain, force-killing an overloading pod) — and
also ties into the earlier-discussed "kill the pod when the alert fires"
idea. Design to be continued in a future session. Candidate directions:
- Find a way to artificially trigger an XID error (reproducing a real
  hardware fault in software is tricky — need to check whether nvidia-smi can
  force one)
- Or force a node to `NotReady` to demonstrate just the "isolate the faulty
  node" flow

---

## Unimplemented Scenarios (for reference, numbered per the original `openshift-monitoring` doc)

The following are not yet automated in the harness. Detection conditions and
the infra-team's response plan are defined in the doc, but there's no actual
implementation (PrometheusRule, automated control action, etc).

### [Doc Scenario 3] Flagging Inefficient Code and Restricting Scheduling (Bad Code Penalty)

- **Situation**: a project team's inexperienced code creates a Data Loader
  bottleneck — the GPU periodically sits idle, or holds onto HBM memory
  without actually computing
- **Detection condition**: GPU memory utilization above 90% while compute
  utilization (`DCGM_FI_DEV_GPU_UTIL`) periodically drops to 0%
- **Infra team's response**: formally issue a code-improvement request citing
  "infrastructure resource efficiency harm," and downgrade that team's
  PriorityClass to Low until the code is fixed (an immediate preemption
  target under resource pressure)
- **Currently visibility-only**: Tier1 dashboard's "GPU Compute vs Memory
  Utilization (Cluster Avg)" panel, Tier2 dashboard's "Stall Pattern: High
  Memory, Low Compute" panel

### [Doc Scenario 4] Per-Project Cost Overrun (Chargeback) and Quota Enforcement

- **Situation**: a specific team over-consumes its allocated GPU-hour budget,
  risking a company-wide infrastructure budget overrun
- **Detection condition**: (allocated GPU count) × (uptime) × (instance unit
  price), accumulated, exceeds 70% of the target budget as of the
  mid-period checkpoint
- **Infra team's response**: adjust ResourceQuota to immediately cap that
  team's concurrently-running GPU count, and force a Node affinity policy
  change so its jobs only run during off-hours or on spare Spot instances
- **Currently visibility-only**: Tier1 dashboard's "GPUs Allocated" stat,
  Tier2 dashboard's "My Project GPU Quota (used / hard)" bargauge

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

- The two scenarios use different namespaces (`gpu-autoscale-scenario-1`,
  `gpu-alert-scenario-2`), so running them simultaneously doesn't interfere
  with each other.
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
