#!/usr/bin/env bash
# Scenario 8: KServe + vLLM load-based autoscaling via KEDA. Deploys a small
# LLM (Qwen2.5-0.5B-Instruct) behind KServe RawDeployment, with KServe's own
# autoscaler disabled and a KEDA ScaledObject (min=1, max=2) in its place --
# avoids the Service Mesh / Knative Serverless dependency RHOAI's
# RawDeployment mode was chosen to sidestep (see remote/rhoai.sh). Idempotent.
#
# Redesigned 2026-08-21 to follow Red Hat's official recommended pattern
# ("How to set up KServe autoscaling for vLLM with KEDA",
# developers.redhat.com/articles/2025/09/23/how-set-kserve-autoscaling-vllm-keda):
# minReplicaCount=1 (not 0) so there's always a pod emitting the
# vllm:num_requests_waiting metric KEDA reads -- this is what the earlier
# min=0 design got wrong (see REMAINING OPEN ITEM below, kept for history).
# Scale-up/down is now demonstrated with real sustained concurrent load
# (scenario8-kserve-vllm-load.sh) rather than a single request, matching how
# Red Hat's own validation used incremental load (GuideLLM) to trigger and
# observe the 1->2->1 curve. GuideLLM itself needs pip install, which this
# harness avoids everywhere else, so the load script uses a bash/curl load
# generator pod instead -- same effect (queue depth threshold crossed).
# `--max-num-seqs=2` caps how many sequences vLLM will run concurrently --
# without it, vLLM's default (256) easily absorbs a handful of concurrent
# demo clients with num_requests_waiting staying at 0 the whole time
# (confirmed live 2026-08-21: CONCURRENCY=8 never crossed the threshold).
# Capping it low makes modest load reliably produce a real queue.
#
# Real gotchas hit building this (2026-08-20), kept here so nobody re-debugs
# them -- memory number below is superseded by the memory incident/fix
# further down (2026-08-21: 12Gi was itself later found to OOM under the
# newer --gpu-memory-utilization=0.4/--max-num-seqs=2 config; the real fix
# was --swap-space=1, not a bigger limit):
# - `storageUri: hf://...` needs a ClusterStorageContainer registering the
#   `^hf://` regex -- none exists by default in RHOAI 2.25.8. Points at
#   RHOAI's own odh-kserve-storage-initializer-rhel9 image (already
#   downstream-patched to understand hf://), not the upstream kserve image.
# - CUDA graph capture hangs forever on this T4 node (0% GPU util, stuck
#   indefinitely at a fixed shape count) -- `--enforce-eager` is required,
#   permanently, not just as a first-boot workaround.
# - The default 8Gi container memory limit OOMKills the container after
#   model load, before it can finish starting -- needs at least 12Gi.
# - On a single-GPU cluster, an InferenceService spec change (e.g. the
#   memory fix above) creates a new ReplicaSet that can never schedule
#   while the old one still holds the only GPU and keeps crash-looping --
#   the old ReplicaSet has to be deleted manually to free the GPU for the
#   new one. This script's re-run is idempotent for a clean deploy, but a
#   mid-flight spec edit needs the same manual RS cleanup as when this was
#   first debugged.
#
# GPU time-slicing (ConfigMap + ClusterPolicy patch on nvidia.com/gpu,
# unrelated to MIG, works on any NVIDIA GPU incl. T4) is applied by THIS
# script (re-enabled cluster-wide 2026-08-21, see below) so the single
# physical GPU reports as 2 schedulable nvidia.com/gpu units -- needed for
# maxReplicaCount=2 to actually run 2 vLLM pods concurrently, not just have
# KEDA try and fail to schedule the 2nd one. Same mechanism validated live
# for scenario 5 on 2026-08-21 (two pods scheduled and ran Running
# concurrently on the same node). Trade-off: see the time-slicing block
# below for the DCGM/Grafana caveat this reintroduces.
#
# Memory incident (2026-08-21): the g4dn.xlarge node only has 16GiB RAM
# total. An earlier per-pod limit of 10Gi (2x10Gi=20Gi for 2 replicas)
# exceeded that, and the node's kubelet actually stopped responding
# (NotReady, "Kubelet stopped posting node status") under real load --
# required an EC2 instance reboot to recover. Tried bumping to g4dn.2xlarge
# (32GiB) instead, but this sandbox account's vCPU quota for the "G and VT
# instances" bucket is a hard 4, and g4dn.2xlarge needs 8 -- launch failed,
# reverted to g4dn.xlarge. Lowering the per-replica limit to 6Gi still
# OOMKilled under real load, and 8Gi OOMKilled even a single idle replica
# (confirmed live 2026-08-21, two node crashes total from this). `oc adm
# top` on a stable single replica at 10Gi showed ~8.65Gi actual usage --
# far more than the ~1GB the 0.5B model's weights account for, pointing at
# vLLM's own engine overhead rather than model size. Prime suspect:
# vLLM's default --swap-space is 4GiB of CPU RAM per instance (reserved for
# CPU-side KV-cache swap), unrelated to --gpu-memory-utilization (that's
# GPU VRAM, a separate pool). Added --swap-space=1 above -- confirmed via
# `oc adm top pod` this alone dropped real usage from ~8.65Gi to ~3.98Gi.
# Limit set to 6Gi/3Gi (request) accordingly; 2x6Gi=12Gi fits well inside
# the node's ~14.2Gi allocatable, unlike every larger value tried before.
#
# HISTORICAL FINDING (kept for reference, no longer applies to this script):
# a manual `oc scale deploy --replicas=N` does NOT stick once a KEDA
# ScaledObject targets that Deployment -- KEDA reconciles it back to its own
# calculated target within ~15s (one polling interval). This mattered when
# the old min=0 design's load script manually scaled 0->1 to route around
# KEDA's scale-from-zero gap. The redesigned load script no longer scales
# manually at all -- it drives real concurrent request load instead, so
# KEDA's own reconciliation is what performs the 1->2->1 scaling.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-kserve-scenario-8}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g4dn.xlarge}"
MODEL_URI="${MODEL_URI:-hf://Qwen/Qwen2.5-0.5B-Instruct}"
VLLM_RUNTIME_IMAGE="${VLLM_RUNTIME_IMAGE:-registry.redhat.io/rhoai/odh-vllm-cuda-rhel9@sha256:00ecb72d83019274410077c4bdf00138d3dce02be697c883745f4f8d970a5c9b}"
STORAGE_INIT_IMAGE="${STORAGE_INIT_IMAGE:-registry.redhat.io/rhoai/odh-kserve-storage-initializer-rhel9@sha256:0e900505bb5033e6e9dbc9bb096ee97cdd5abe5bb2030c0d53334b66916476b5}"

echo "=== GPU time-slicing (cluster-wide, so 2 replicas can share the one physical GPU) ==="
# This cluster only has 1 physical GPU per node, so maxReplicaCount=2 needs
# time-slicing to let a 2nd vLLM pod actually schedule and run concurrently
# -- without it, KEDA would try to scale to 2 but the 2nd pod would sit
# Pending forever (no GPU capacity). Trade-off (accepted 2026-08-21, same
# root cause documented in Scenario 5's history): while 2 pods are both
# Running on the shared GPU, DCGM's per-pod Grafana panels can misattribute
# samples (device-scoped metric, not per-process). Only matters if Scenario
# 5 and Scenario 8's 2-replica state happen to be live at the same instant.
oc apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: nvidia-gpu-operator
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        resources:
        - name: nvidia.com/gpu
          replicas: 2
YAML
oc patch clusterpolicy gpu-cluster-policy --type merge \
  -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"any"}}}}'
echo "Waiting for node GPU allocatable to reflect time-slicing (1 -> 2)..."
for _ in $(seq 1 12); do
  ALLOC=$(oc get nodes -l "node.kubernetes.io/instance-type=${INSTANCE_TYPE}" -o jsonpath="{.items[0].status.allocatable.nvidia\.com/gpu}" 2>/dev/null || true)
  [ "$ALLOC" = "2" ] && break
  sleep 10
done
echo "GPU allocatable on ${INSTANCE_TYPE}: ${ALLOC:-unknown}"

echo "=== ClusterStorageContainer for hf:// (cluster-scoped, only created if missing) ==="
oc get clusterstoragecontainer hf-hub >/dev/null 2>&1 || oc apply -f - <<YAML
apiVersion: serving.kserve.io/v1alpha1
kind: ClusterStorageContainer
metadata:
  name: hf-hub
spec:
  container:
    name: storage-initializer
    image: ${STORAGE_INIT_IMAGE}
    resources:
      requests:
        memory: 100Mi
        cpu: 100m
      limits:
        memory: 4Gi
        cpu: "1"
  supportedUriFormats:
  - regex: "^hf://"
YAML

echo "=== Namespace + ServingRuntime + InferenceService ==="
oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${DEMO_NAMESPACE}
  labels:
    team: demo-team-a
    modelmesh-enabled: "false"
---
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  annotations:
    opendatahub.io/recommended-accelerators: '["nvidia.com/gpu"]'
    openshift.io/display-name: vLLM NVIDIA GPU ServingRuntime for KServe
  labels:
    opendatahub.io/dashboard: "true"
  name: vllm-cuda-runtime
  namespace: ${DEMO_NAMESPACE}
spec:
  annotations:
    opendatahub.io/kserve-runtime: vllm
    prometheus.io/path: /metrics
    prometheus.io/port: "8080"
  containers:
  - args:
    - --port=8080
    - --model=/mnt/models
    - --served-model-name={{.Name}}
    - --max-model-len=2048
    - --enforce-eager
    - --gpu-memory-utilization=0.4
    - --max-num-seqs=2
    - --swap-space=1
    command:
    - python
    - -m
    - vllm.entrypoints.openai.api_server
    env:
    - name: HF_HOME
      value: /tmp/hf_home
    image: ${VLLM_RUNTIME_IMAGE}
    name: kserve-container
    ports:
    - containerPort: 8080
      protocol: TCP
  multiModel: false
  supportedModelFormats:
  - autoSelect: true
    name: vLLM
---
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: qwen-vllm
  namespace: ${DEMO_NAMESPACE}
  annotations:
    serving.kserve.io/deploymentMode: RawDeployment
    serving.kserve.io/autoscalerClass: external
spec:
  predictor:
    minReplicas: 1
    maxReplicas: 2
    model:
      modelFormat:
        name: vLLM
      runtime: vllm-cuda-runtime
      storageUri: "${MODEL_URI}"
      resources:
        limits:
          nvidia.com/gpu: "1"
          memory: 6Gi
        requests:
          nvidia.com/gpu: "1"
          memory: 3Gi
    nodeSelector:
      node.kubernetes.io/instance-type: ${INSTANCE_TYPE}
    tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
YAML

# KServe's RawDeployment controller only re-renders the Deployment's pod
# template when the InferenceService object itself changes generation --
# editing the referenced ServingRuntime alone (e.g. a container args change)
# does NOT trigger a re-render, confirmed live 2026-08-21 (repeatedly: a new
# arg sat in the ServingRuntime for several redeploys while the running
# Deployment's actual args stayed stale). Force it by deleting the
# Deployment; KServe recreates it fresh from the current ServingRuntime.
oc delete deploy qwen-vllm-predictor -n "${DEMO_NAMESPACE}" --ignore-not-found

echo "Waiting for qwen-vllm-predictor to become Ready (model download + vLLM eager-mode startup, ~2-3min)..."
for _ in $(seq 1 40); do
  POD=$(oc get pods -n "${DEMO_NAMESPACE}" -l app=isvc.qwen-vllm-predictor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "$POD" ] || { sleep 10; continue; }
  READY=$(oc get pod "$POD" -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.containerStatuses[?(@.name=="kserve-container")].ready}' 2>/dev/null || true)
  [ "$READY" = "true" ] && break
  sleep 10
done
echo "qwen-vllm-predictor: pod=${POD:-<none>} ready=${READY:-false}"

echo "=== KEDA ScaledObject (min=1, max=2) ==="
oc apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: keda-thanos-reader
  namespace: ${DEMO_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: keda-thanos-reader-binding-${DEMO_NAMESPACE}
subjects:
- kind: ServiceAccount
  name: keda-thanos-reader
  namespace: ${DEMO_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: cluster-monitoring-view
  apiGroup: rbac.authorization.k8s.io
YAML
TOKEN=$(oc create token keda-thanos-reader -n "${DEMO_NAMESPACE}" --duration=87600h)
oc create secret generic keda-thanos-token -n "${DEMO_NAMESPACE}" \
  --from-literal=bearerToken="${TOKEN}" \
  --dry-run=client -o yaml | oc apply -f -

oc apply -f - <<YAML
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: keda-thanos-auth
  namespace: ${DEMO_NAMESPACE}
spec:
  secretTargetRef:
  - parameter: bearerToken
    name: keda-thanos-token
    key: bearerToken
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: qwen-vllm-scaledobject
  namespace: ${DEMO_NAMESPACE}
spec:
  scaleTargetRef:
    name: qwen-vllm-predictor
  minReplicaCount: 1
  maxReplicaCount: 2
  cooldownPeriod: 30
  pollingInterval: 5
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 30
  triggers:
  - type: prometheus
    metadata:
      serverAddress: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
      namespace: ${DEMO_NAMESPACE}
      metricName: vllm_num_requests_waiting
      query: sum(vllm:num_requests_waiting{namespace="${DEMO_NAMESPACE}"}) or vector(0)
      threshold: "1"
      authModes: bearer
    authenticationRef:
      name: keda-thanos-auth
YAML

# Guard against a stale autoscaling.keda.sh/paused(-replicas) annotation
# left over from manual testing (oc annotate/oc edit bypasses `oc apply`'s
# three-way merge, so a plain re-apply above does not clear it).
oc annotate scaledobject qwen-vllm-scaledobject -n "${DEMO_NAMESPACE}" \
  autoscaling.keda.sh/paused- autoscaling.keda.sh/paused-replicas- --overwrite >/dev/null 2>&1 || true

echo ""
echo "Config follows Red Hat's recommended pattern (developers.redhat.com/"
echo "articles/2025/09/23/how-set-kserve-autoscaling-vllm-keda):"
echo "minReplicaCount=1 keeps a pod always emitting vllm:num_requests_waiting,"
echo "so KEDA always has a live metric to scale on -- no 0-replica cold start"
echo "and no scale-from-zero gap (that was scenario 8's old min=0 design,"
echo "which this replaces; see git history / AGENT.md for that finding)."
echo "pollingInterval=5s / threshold=1 matches Red Hat's article; cooldownPeriod=30s"
echo "is shortened from their default for demo visibility."
echo "(Gotcha confirmed live 2026-08-21: cooldownPeriod alone did NOT make"
echo "scale-down fast -- the underlying HPA's own default 300s"
echo "scaleDown.stabilizationWindowSeconds still applied on top of it, so"
echo "scale-down actually took ~5-6 minutes despite cooldownPeriod=30. Fixed"
echo "by setting advanced.horizontalPodAutoscalerConfig.behavior.scaleDown."
echo "stabilizationWindowSeconds=30 explicitly above.)"
echo ""
echo "Generate load to trigger a real 1->2 scale-out (and watch it settle"
echo "back to 1 after the load stops):"
echo "  ~/scenario8-kserve-vllm-load.sh"
echo "Watch scaling:   oc get scaledobject,deploy -n ${DEMO_NAMESPACE} -w"
