#!/usr/bin/env bash
# Cleans up scenario 9's namespace-scoped resources (InferenceService,
# ServingRuntime, PVC, prefetch Job, namespace) and drops it from the
# Service Mesh member roll. Leaves the cluster-wide infra installed by
# scenario9-serverless-start.sh in place (Serverless/Service Mesh operators,
# the data-science-smcp control plane, KnativeServing) since it's reusable
# and slow to reinstall -- same pattern as scenario 8 leaving hf-hub in
# place.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-kserve-scenario-9}"

oc delete inferenceservice qwen-vllm-serverless -n "${DEMO_NAMESPACE}" --ignore-not-found
oc delete servingruntime vllm-cuda-runtime -n "${DEMO_NAMESPACE}" --ignore-not-found
oc delete job qwen-model-prefetch -n "${DEMO_NAMESPACE}" --ignore-not-found
oc delete pvc qwen-model-cache -n "${DEMO_NAMESPACE}" --ignore-not-found
oc delete namespace "${DEMO_NAMESPACE}" --ignore-not-found

oc patch smmr default -n istio-system --type=json \
  -p '[{"op":"replace","path":"/spec/members","value":["knative-serving"]}]' \
  2>/dev/null || true

echo "scenario9 (KServe Serverless/Knative) stopped. Serverless/Service Mesh"
echo "operators, data-science-smcp, and KnativeServing left in place"
echo "(cluster-scoped, reusable)."
