#!/usr/bin/env bash
# Scenario 8: KServe + vLLM scale-to-zero via KEDA. Deploys a small LLM
# (Qwen2.5-0.5B-Instruct) behind KServe RawDeployment, with KServe's own
# autoscaler disabled and a KEDA ScaledObject (min=0, max=1) in its place --
# avoids the Service Mesh / Knative Serverless dependency RHOAI's
# RawDeployment mode was chosen to sidestep (see remote/rhoai.sh). Idempotent.
#
# Real gotchas hit building this (2026-08-20), kept here so nobody re-debugs
# them:
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
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-kserve-scenario-8}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g4dn.xlarge}"
MODEL_URI="${MODEL_URI:-hf://Qwen/Qwen2.5-0.5B-Instruct}"
VLLM_RUNTIME_IMAGE="${VLLM_RUNTIME_IMAGE:-registry.redhat.io/rhoai/odh-vllm-cuda-rhel9@sha256:00ecb72d83019274410077c4bdf00138d3dce02be697c883745f4f8d970a5c9b}"
STORAGE_INIT_IMAGE="${STORAGE_INIT_IMAGE:-registry.redhat.io/rhoai/odh-kserve-storage-initializer-rhel9@sha256:0e900505bb5033e6e9dbc9bb096ee97cdd5abe5bb2030c0d53334b66916476b5}"

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
    maxReplicas: 1
    model:
      modelFormat:
        name: vLLM
      runtime: vllm-cuda-runtime
      storageUri: "${MODEL_URI}"
      resources:
        limits:
          nvidia.com/gpu: "1"
          memory: 12Gi
        requests:
          nvidia.com/gpu: "1"
          memory: 6Gi
    nodeSelector:
      node.kubernetes.io/instance-type: ${INSTANCE_TYPE}
    tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
YAML

echo "Waiting for qwen-vllm-predictor to become Ready (model download + vLLM eager-mode startup, ~2-3min)..."
for _ in $(seq 1 40); do
  POD=$(oc get pods -n "${DEMO_NAMESPACE}" -l app=isvc.qwen-vllm-predictor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "$POD" ] || { sleep 10; continue; }
  READY=$(oc get pod "$POD" -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.containerStatuses[?(@.name=="kserve-container")].ready}' 2>/dev/null || true)
  [ "$READY" = "true" ] && break
  sleep 10
done
echo "qwen-vllm-predictor: pod=${POD:-<none>} ready=${READY:-false}"

echo "=== KEDA ScaledObject (min=0, max=1) ==="
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
  minReplicaCount: 0
  maxReplicaCount: 1
  cooldownPeriod: 60
  pollingInterval: 15
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

echo ""
echo "IMPORTANT (measured 2026-08-20): this Prometheus trigger reads the vLLM"
echo "pod's OWN metric -- which doesn't exist once replicas=0, so KEDA can"
echo "never observe demand to scale back up on its own. Automatic scale-DOWN"
echo "works correctly; automatic scale-UP-from-zero does not, with this"
echo "trigger. Use scenario8-kserve-vllm-load.sh to demo the working half and"
echo "see the real 0-replica failure mode; see Scenario 10 in the docs for"
echo "the honest writeup of why (same class of gap Knative's Activator solves"
echo "and this KEDA-only design does not, by design, to avoid Service Mesh)."
echo ""
echo "Send a request:  ~/scenario8-kserve-vllm-load.sh"
echo "Watch scaling:   oc get scaledobject,deploy -n ${DEMO_NAMESPACE} -w"
