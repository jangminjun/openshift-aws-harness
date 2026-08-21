#!/usr/bin/env bash
# Scenario 9: KServe Serverless (Knative) + vLLM -- real request-triggered
# scale-to-zero, unlike scenario 8's KEDA/RawDeployment approach which never
# wakes automatically on real traffic. Installs OpenShift Serverless +
# Service Mesh (both genuinely required -- RHOAI's DSCInitialization
# hardcodes the ServiceMeshControlPlane name/namespace), configures the mesh
# with the settings this cluster actually needed in practice (ThirdParty
# token identity + PERMISSIVE mTLS; see harness/GPUaaS-SCENARIOS(KOR).md
# Scenario 9 for why each one was necessary -- Kubernetes/default identity
# needs automountServiceAccountToken=true on the pod, which KServe's own
# webhook sets false and Knative's own validation webhook refuses to let you
# override; STRICT mTLS blocks Knative's own internal metrics scraping and
# stalls scale-to-zero forever), then deploys the Qwen2.5-0.5B-Instruct
# InferenceService in Serverless mode with its model pre-cached on a PVC
# (skips the ~50-100s Hugging Face download on every cold start -- cuts
# cold start from ~70-110s to ~49s, which matters because it's what brings
# it under the serving path's own ~60s timeout). Idempotent.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-kserve-scenario-9}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g4dn.xlarge}"
MODEL_URI="${MODEL_URI:-hf://Qwen/Qwen2.5-0.5B-Instruct}"
STORAGE_CLASS="${STORAGE_CLASS:-gp3-csi}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-registry.redhat.io/rhoai/odh-vllm-cuda-rhel9@sha256:00ecb72d83019274410077c4bdf00138d3dce02be697c883745f4f8d970a5c9b}"
STORAGE_INIT_IMAGE="${STORAGE_INIT_IMAGE:-registry.redhat.io/rhoai/odh-kserve-storage-initializer-rhel9@sha256:0e900505bb5033e6e9dbc9bb096ee97cdd5abe5bb2030c0d53334b66916476b5}"

wait_for() {
  local desc="$1" tries="$2" interval="$3"; shift 3
  local i
  for i in $(seq 1 "$tries"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep "$interval"
  done
  echo "Timed out waiting for: ${desc}" >&2
  return 1
}

echo "=== 1/7: OpenShift Serverless + Service Mesh operators ==="
oc apply -f - <<YAML
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: serverless-operator
  namespace: openshift-operators
spec:
  channel: stable
  name: serverless-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator
  namespace: openshift-operators
spec:
  channel: stable
  name: servicemeshoperator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML

wait_for "serverless-operator CSV Succeeded" 40 15 bash -c '
  oc get csv -n openshift-operators -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if any(\"serverless-operator\" in i[\"metadata\"][\"name\"] and i[\"status\"][\"phase\"]==\"Succeeded\" for i in d[\"items\"]) else 1)
"'
wait_for "servicemeshoperator CSV Succeeded" 40 15 bash -c '
  oc get csv -n openshift-operators -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if any(\"servicemeshoperator.v\" in i[\"metadata\"][\"name\"] and i[\"status\"][\"phase\"]==\"Succeeded\" for i in d[\"items\"]) else 1)
"'

echo "=== 2/7: ServiceMeshControlPlane (must be named data-science-smcp -- RHOAI hardcodes this) ==="
oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: istio-system
---
apiVersion: maistra.io/v2
kind: ServiceMeshControlPlane
metadata:
  name: data-science-smcp
  namespace: istio-system
spec:
  version: v2.6
  tracing:
    type: None
  addons:
    grafana:
      enabled: false
    kiali:
      enabled: false
    prometheus:
      enabled: false
  security:
    dataPlane:
      mtls: false
    identity:
      type: ThirdParty
  gateways:
    ingress:
      enabled: true
    egress:
      enabled: false
YAML

wait_for "SMCP Ready" 30 15 bash -c \
  'oc get smcp data-science-smcp -n istio-system -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" | grep -q True'

echo "=== 3/7: label the ingress gateway so Knative's Gateway resource actually binds to it ==="
# Knative's "knative-ingress-gateway" Gateway selects pods labeled
# knative=ingressgateway, but the SMCP's default ingress gateway pod only
# carries istio=ingressgateway -- without this, TLS SNI handshakes to the
# external route fail outright (no gateway serves the config at all).
oc patch deployment istio-ingressgateway -n istio-system --type=merge \
  -p '{"spec":{"template":{"metadata":{"labels":{"knative":"ingressgateway"}}}}}'

echo "=== 4/7: mesh membership + RHOAI Serverless component ==="
oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${DEMO_NAMESPACE}
  labels:
    team: demo-team-a
---
apiVersion: maistra.io/v1
kind: ServiceMeshMemberRoll
metadata:
  name: default
  namespace: istio-system
spec:
  members:
  - knative-serving
  - ${DEMO_NAMESPACE}
YAML

DSC=$(oc get datasciencecluster -o name | head -1)
oc patch "$DSC" --type=merge -p '{"spec":{"components":{"kserve":{"serving":{"managementState":"Managed"}}}}}'

wait_for "KnativeServing Ready" 40 15 bash -c \
  'oc get knativeserving knative-serving -n knative-serving -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" 2>/dev/null | grep -q True'

# Default HA wants 2 replicas of every control-plane deployment (activator,
# webhook, controller, autoscaler...) -- on a small lab cluster that alone
# can starve node capacity. Drop to 1; harmless if the cluster has room.
oc patch knativeserving knative-serving -n knative-serving --type=merge \
  -p '{"spec":{"highAvailability":{"replicas":1}}}' || true

echo "=== 5/7: ServingRuntime (namespace-scoped -- ClusterServingRuntime isn't registered on this KServe version) ==="
oc apply -f - <<YAML
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: vllm-cuda-runtime
  namespace: ${DEMO_NAMESPACE}
  annotations:
    opendatahub.io/recommended-accelerators: '["nvidia.com/gpu"]'
    openshift.io/display-name: vLLM NVIDIA GPU ServingRuntime for KServe
  labels:
    opendatahub.io/dashboard: "true"
spec:
  annotations:
    opendatahub.io/kserve-runtime: vllm
    prometheus.io/path: /metrics
    prometheus.io/port: "8080"
  containers:
  - name: kserve-container
    image: ${RUNTIME_IMAGE}
    command: ["python", "-m", "vllm.entrypoints.openai.api_server"]
    args:
    - --port=8080
    - --model=/mnt/models
    - --served-model-name={{.Name}}
    - --max-model-len=2048
    - --enforce-eager
    - --gpu-memory-utilization=0.4
    env:
    - name: HF_HOME
      value: /tmp/hf_home
    ports:
    - containerPort: 8080
      protocol: TCP
    resources:
      limits:
        nvidia.com/gpu: "1"
      requests:
        nvidia.com/gpu: "1"
  multiModel: false
  supportedModelFormats:
  - autoSelect: true
    name: vLLM
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: qwen-model-cache
  namespace: ${DEMO_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: 5Gi
YAML

echo "=== 6/7: pre-cache the model into the PVC (one-off download, ~4-30s depending on network) ==="
oc delete job qwen-model-prefetch -n "${DEMO_NAMESPACE}" --ignore-not-found
oc apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: qwen-model-prefetch
  namespace: ${DEMO_NAMESPACE}
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        node.kubernetes.io/instance-type: ${INSTANCE_TYPE}
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      containers:
      - name: storage-initializer
        image: ${STORAGE_INIT_IMAGE}
        args: ["${MODEL_URI}", "/mnt/models"]
        env:
        - name: HF_HOME
          value: "/tmp"
        - name: HF_HUB_ENABLE_HF_TRANSFER
          value: "1"
        volumeMounts:
        - name: model-cache
          mountPath: /mnt/models
      volumes:
      - name: model-cache
        persistentVolumeClaim:
          claimName: qwen-model-cache
YAML
wait_for "model prefetch Job Complete" 40 15 bash -c \
  "oc get job qwen-model-prefetch -n ${DEMO_NAMESPACE} -o jsonpath='{.status.succeeded}' | grep -q 1"
echo "Model cached in PVC qwen-model-cache."

echo "=== 7/7: InferenceService (Serverless mode, PVC-backed model, minReplicas=0) ==="
oc apply -f - <<YAML
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: qwen-vllm-serverless
  namespace: ${DEMO_NAMESPACE}
  annotations:
    serving.kserve.io/deploymentMode: Serverless
spec:
  predictor:
    minReplicas: 0
    maxReplicas: 1
    model:
      modelFormat:
        name: vLLM
      resources:
        limits:
          memory: 12Gi
          nvidia.com/gpu: "1"
        requests:
          memory: 6Gi
          nvidia.com/gpu: "1"
      runtime: vllm-cuda-runtime
      storageUri: pvc://qwen-model-cache/
    nodeSelector:
      node.kubernetes.io/instance-type: ${INSTANCE_TYPE}
    tolerations:
    - effect: NoSchedule
      key: nvidia.com/gpu
      operator: Exists
YAML

if ! wait_for "InferenceService Ready" 15 10 bash -c \
  "oc get inferenceservice qwen-vllm-serverless -n ${DEMO_NAMESPACE} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True"
then
  echo "Not ready yet -- forcing a fresh reconcile (known gotcha: KServe's"
  echo "controller can cache stale CRD discovery if the InferenceService is"
  echo "created right as KnativeServing finishes rolling out, and that"
  echo "specific error is terminal/never auto-retried)..."
  oc rollout restart deployment kserve-controller-manager -n redhat-ods-applications
  oc rollout restart deployment odh-model-controller -n redhat-ods-applications
  oc rollout status deployment kserve-controller-manager -n redhat-ods-applications --timeout=120s
  oc rollout status deployment odh-model-controller -n redhat-ods-applications --timeout=120s
  wait_for "InferenceService Ready (retry)" 30 10 bash -c \
    "oc get inferenceservice qwen-vllm-serverless -n ${DEMO_NAMESPACE} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True"
fi

URL=$(oc get inferenceservice qwen-vllm-serverless -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.components.predictor.url}' 2>/dev/null || true)
echo ""
echo "InferenceService ready and idle (0 replicas -- stays that way until a real request arrives)."
echo "URL: ${URL:-<pending>}/v1/completions"
echo "Next: ~/scenario9-serverless-load.sh (times a real request -- ~50s if"
echo "cold, ~0.3s if warm; the request itself succeeds either way, no retry"
echo "needed, thanks to the PVC pre-cache)."
