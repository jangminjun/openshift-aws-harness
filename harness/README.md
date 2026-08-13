# OpenShift + OpenShift AI on AWS — reusable harness

Stands up a self-managed OpenShift (IPI) cluster on AWS via a bastion jump
host, then installs the NVIDIA GPU stack and Red Hat OpenShift AI (RHOAI) on
top of it. Every subcommand is idempotent — re-running it reuses whatever it
already finds (via `state/<cluster>.env`) instead of duplicating resources.

## Prerequisites

- AWS credentials in your local `~/.aws/credentials` (`aws sts get-caller-identity` must work) — these get copied to the bastion during `bastion-bootstrap`.
- A public Route53 hosted zone matching `BASE_DOMAIN`.
- A Red Hat pull secret saved locally, default path `~/.openshift/pull-secret.json` (get one from console.redhat.com/openshift/install/pull-secret).

## Configuration

Defaults live in `config.env`. Override any value via environment before
invoking `harness.sh`, e.g.:

```bash
CLUSTER_NAME=demo2 AWS_REGION=us-west-2 BASE_DOMAIN=example.com \
  GPU_INSTANCE_TYPE=g5.2xlarge ./harness.sh bastion-up
```

## Usage

```bash
cd harness
./harness.sh bastion-up          # create (or reuse) VPC/subnet/IGW/SG/keypair/EC2 bastion
./harness.sh bastion-bootstrap   # install openshift-install/oc on the bastion
./harness.sh push-pull-secret    # copy your pull secret to the bastion
./harness.sh install-config      # generate install-config.yaml on the bastion
./harness.sh create-cluster      # start `openshift-install create cluster` in the background
./harness.sh wait-cluster        # block/tail until install completes or fails (~35-45 min)
./harness.sh status              # bastion + cluster status at any point
./harness.sh kubeconfig          # pull kubeconfig to ./state/<cluster>-kubeconfig
./harness.sh gpu-machineset      # clone a worker MachineSet onto a GPU instance type
./harness.sh gpu-operator        # install Node Feature Discovery + NVIDIA GPU Operator
./harness.sh rhoai               # install OpenShift AI operator + DataScienceCluster

# or run the whole thing end to end:
./harness.sh all
```

Add more NVIDIA GPU flavors side by side by re-running `gpu-machineset` with a
different type — `gpu-operator`'s ClusterPolicy covers every node
cluster-wide, so it only needs to run once:

```bash
GPU_INSTANCE_TYPE=g6.2xlarge GPU_MACHINESET_AZ=us-east-1a ./harness.sh gpu-machineset
```

### Autoscaling GPU node pools

`gpu-machineset` wires up autoscaling automatically: it applies the
cluster-wide `ClusterAutoscaler` singleton (idempotent, so this only really
takes effect the first time) and a `MachineAutoscaler` for the GPU
MachineSet it just created (or already found), bounded by `GPU_MIN_REPLICAS`
/ `GPU_MAX_REPLICAS` (default `1`/`2`). No extra steps needed:

```bash
GPU_INSTANCE_TYPE=g6.2xlarge GPU_MACHINESET_AZ=us-east-1a \
  GPU_MIN_REPLICAS=1 GPU_MAX_REPLICAS=2 ./harness.sh gpu-machineset
```

IPI clusters already ship the cluster-autoscaler-operator, so this is just
CRs — no extra install. The autoscaler name is derived from the MachineSet
name with its `<cluster>-<id>-` prefix stripped. For non-GPU MachineSets
(or to override bounds after the fact), use the two underlying CRs
directly:

```bash
./harness.sh cluster-autoscaler   # once per cluster (MAX_NODES_TOTAL, default 20)

MACHINESET_NAME=myocp-77p88-gpu-worker-1a MIN_REPLICAS=1 MAX_REPLICAS=2 \
  ./harness.sh machine-autoscaler   # once per MachineSet you want autoscaled
```

`AUTOSCALER_NAME` defaults to the MachineSet name with its
`<cluster>-<id>-` prefix stripped; set it explicitly if you don't like the
derived name. Find MachineSet names with `oc get machineset -n
openshift-machine-api`.

### NPU (AWS Inferentia2 / Trainium via Neuron) — currently blocked, not wired into `all`

**Status: tried and abandoned 2026-08-11.** `neuron-machineset` and
`neuron-operator` below got an inf2.xlarge node joined, NFD correctly
labeling it from the real PCI ID (`1d0f:7264`), and KMM + the AWS Neuron
Operator installed cleanly — but KMM never created a `NodeModulesConfig` for
the node and `ModuleImagesConfig.spec.images` stayed permanently empty, with
no error anywhere in either controller's logs. Tried: restarting both
operator pods (fixed two separate real bugs along the way, see below),
deleting/recreating the `DeviceConfig` from scratch, and removing/restoring
the node taint — none of it unstuck the build pipeline. Whether this is a
KMM 2.6.1 / AWS Neuron Operator 1.2.0 incompatibility or an OCP 4.22-specific
issue wasn't confirmed (research on it was cut short). Revisit if a newer
Neuron Operator release addresses it, or switch to hand-rolling a KMM
`Module` with `literal:` (exact kernel version) instead of the operator's
`regexp: "^.+$"` build-based one, plus the AWS device-plugin manifest
directly — see `aws-neuron/aws-neuron-sdk` for the raw manifests, bypassing
the operator layer entirely.

Adds an AWS Neuron NPU worker alongside the NVIDIA GPU worker, using the
**community** AWS Neuron Operator (not Red Hat certified, published Dec 2025,
documented against OCP 4.19+ — treat as a pilot). It builds the
`aws-neuronx-dkms` driver against RHCOS via the Kernel Module Management
(KMM) operator + Driver Toolkit, same mechanism the certified NVIDIA GPU
Operator uses under the hood.

```bash
./harness.sh neuron-machineset   # clone a worker MachineSet onto NEURON_INSTANCE_TYPE (default inf2.xlarge)
./harness.sh neuron-operator     # KMM + AWS Neuron Operator + NodeFeatureRule + DeviceConfig
```

`NEURON_MACHINESET_AZ` (default `us-east-1a`) must be an AZ that actually
offers the instance type — check with:

```bash
aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters "Name=instance-type,Values=$NEURON_INSTANCE_TYPE" --region "$AWS_REGION"
```

Verify once the driver DaemonSet is running:

```bash
oc get nodes -L feature.node.kubernetes.io/aws-neuron   # NFD label from PCI vendor 1d0f (Amazon)
oc get node <neuron-node> -o jsonpath='{.status.allocatable}' | jq
# expect aws.amazon.com/neuron: "1", aws.amazon.com/neuroncore: "2"  (inf2.xlarge)
```

### GPU monitoring / demo control-plane

Implements the monitoring foundation from `openshift-monitoring` (scenario doc)
on top of the cluster above: DCGM metrics, Tier1 (infra) / Tier2 (tenant)
Grafana dashboards, and GPU temp/XID alerts routed to Slack. Requires
`gpu-operator` (dcgm-exporter) to already be installed.

```bash
SLACK_WEBHOOK_URL='https://hooks.slack.com/services/...' \
  SLACK_CHANNEL='#alarm-gpu-monitoring' ./harness.sh monitoring-all

# or step by step:
./harness.sh enable-monitoring   # turn on User Workload Monitoring (used for dashboard queries)
./harness.sh grafana             # Grafana Operator + datasource against Thanos Querier
./harness.sh dcgm-alerts         # standalone Prometheus + Alertmanager (temp>=70C, XID errors) + Slack routing
./harness.sh dashboards          # Tier1 global + Tier2 per-namespace Grafana dashboards
```

**`dcgm-alerts` runs its own Prometheus + Alertmanager**, installed via a
second, separately-scoped community Prometheus Operator subscription in
`gpu-monitoring` — not OpenShift's own User Workload Monitoring (UWM). UWM's
tenant isolation (`enforcedNamespaceLabel` on rules, `OnNamespace` matching on
Alertmanager routes, neither overridable from the ConfigMap on this cluster
and not durable via direct CR patch — `cluster-monitoring-operator` reverts
it on resync) requires every alert to belong to exactly one namespace, which
a fleet-wide "any GPU overheating" alert never satisfies. The standalone
stack sidesteps that entirely instead of fighting it. See the comment block
at the top of `remote/dcgm-alerts.sh` for the full story. Dashboards still
read through UWM/Thanos Querier as before — only alerting was moved.

If `SLACK_WEBHOOK_URL` is left empty, `dcgm-alerts` still stands up the whole
stack with a placeholder webhook in the `alertmanager-gpu-alertmanager`
secret — just re-run `dcgm-alerts` with `SLACK_WEBHOOK_URL` set once you have
a real one; no other step needs re-running.

Only scenario 1 (GPU overheat/XID monitoring + alerting, per the doc's own
numbering) and the Tier1/Tier2 dashboard shells are wired up so far.
Scenarios 2-4 (workload downsizing, bad-code penalty, chargeback/quota
enforcement) and the power-saving / auto-shutdown pieces from the doc are not
yet automated.

Three standalone demo workloads are available (numbered by presentation order,
not the doc's scenario numbers above):

```bash
./harness.sh scenario1-autoscale-demo        # 2 training-job pods pinned to one GPU flavor -> MachineSet scale-out
./harness.sh scenario1-autoscale-demo-stop
./harness.sh scenario2-alert-demo            # gpu-burn pod -> Tier1 dashboard temp climb -> GPUHighTemperature -> Slack
./harness.sh scenario2-alert-demo-stop
./harness.sh scenario3-powercap-start        # provisions g6.2xlarge, power-load pod at full (72W) draw
./harness.sh scenario3-powercap-apply 50     # nvidia-smi -pl 50 on the power-load node -> Tier1 "Power Draw per GPU" drops
./harness.sh scenario3-powercap-apply        # no arg = reset to the card default power limit
./harness.sh scenario3-powercap-stop         # delete the pod, reset power limit to default
```

Equivalent standalone scripts also live directly on the bastion
(`~/scenario1-autoscale-start.sh` / `-stop.sh`, `~/scenario2-alert-start.sh` /
`-stop.sh`, `~/scenario3-powercap-start.sh` / `-apply.sh` / `-stop.sh`) for
running without a local harness checkout mid-demo.

## Teardown

```bash
./harness.sh destroy-cluster        # openshift-install destroy cluster
./harness.sh destroy-bastion --yes  # terminate bastion + delete its VPC/subnet/IGW/SG/keypair
```

`destroy-bastion` requires `--yes` since it deletes real AWS resources.

## Known gotchas (already fixed in these scripts)

Found while running this end to end once; kept here so nobody re-debugs them:

- **NFD / GPU Operator OperatorGroups need `targetNamespaces`.** Both only
  support `SingleNamespace`/`OwnNamespace` install mode. An OperatorGroup
  without `spec.targetNamespaces` defaults to `AllNamespaces`, which fails
  the CSV with `UnsupportedOperatorGroup`. `remote/gpu-operator.sh` sets
  `targetNamespaces` explicitly for both.
- **`ClusterPolicy` can't be applied with an empty `spec: {}`.** The CRD
  requires several subsections (`driver`, `dcgm`, `toolkit`, ...).
  `remote/gpu-operator.sh` pulls the fully-populated default from the GPU
  Operator CSV's `alm-examples` annotation instead of hand-rolling one.
- **`kserve` errors without Service Mesh + Serverless.** Its default
  deployment mode needs both operators installed. `remote/rhoai.sh` sets
  `defaultDeploymentMode: RawDeployment` and `serving.managementState:
  Removed` so it comes up standalone.
- **2 workers (m5.xlarge) isn't enough for RHOAI.** dashboard/kserve/
  modelmeshserving pods sit `Pending` on CPU. `WORKER_REPLICAS` defaults to
  `3` for this reason — if you still see `Pending` pods with `Insufficient
  cpu` events, scale another per-AZ MachineSet in `openshift-machine-api`
  (`oc get machineset -n openshift-machine-api`, then `oc scale machineset
  <name> -n openshift-machine-api --replicas=1`) or bump `WORKER_TYPE`.

- **KMM operator also only supports `AllNamespaces`.** Same failure mode as
  NFD/GPU Operator above but in the opposite direction — its OperatorGroup
  must NOT set `targetNamespaces`, or the CSV fails with `OwnNamespace
  InstallModeType not supported`. `remote/neuron-operator.sh` leaves it
  unset.

## Layout

- `config.env` — non-secret defaults (region, sizes, replica counts).
- `lib.sh` — shared shell helpers (state file, SSH wrappers).
- `harness.sh` — the CLI entrypoint (subcommands above).
- `remote/*.sh` — scripts that get piped over SSH and run *on* the bastion.
- `state/<cluster>.env` — per-cluster runtime state (VPC/instance IDs, IP). Gitignored.

## Notes

- Secrets (AWS keys, pull secret) are never written into these scripts — they
  come from your local `~/.aws/credentials` and `$PULL_SECRET_FILE` at
  runtime and are copied to the bastion over SSH.
- GPU quota: check `aws service-quotas get-service-quota --service-code ec2
  --quota-code L-DB2E81BA` (G/VT instance vCPUs) before requesting more than
  a couple of GPU workers.
