#!/usr/bin/env bash
# Cleans up scenario 8: InferenceService, ServingRuntime, KEDA objects, and
# the namespace. Leaves the cluster-scoped ClusterStorageContainer (hf-hub)
# in place since it's reusable infrastructure, not demo state.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-kserve-scenario-8}"

oc delete inferenceservice qwen-vllm -n "${DEMO_NAMESPACE}" --ignore-not-found
oc delete scaledobject qwen-vllm-scaledobject -n "${DEMO_NAMESPACE}" --ignore-not-found
oc delete servingruntime vllm-cuda-runtime -n "${DEMO_NAMESPACE}" --ignore-not-found
oc delete clusterrolebinding "keda-thanos-reader-binding-${DEMO_NAMESPACE}" --ignore-not-found
oc delete namespace "${DEMO_NAMESPACE}" --ignore-not-found

echo "scenario8 (KServe+vLLM+KEDA) stopped. hf-hub ClusterStorageContainer left in place (cluster-scoped, reusable)."
