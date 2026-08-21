#!/usr/bin/env bash
# Sends a real inference request to scenario 9's Serverless InferenceService
# and times it. If idle (0 replicas), this is what triggers Knative's
# Activator to wake a pod -- the PVC-cached model (~49s to load) keeps cold
# start under the serving path's own timeout, so this same request succeeds
# on its own without a client retry (unlike scenario 8's KEDA, which never
# wakes automatically at all).
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-kserve-scenario-9}"
PROMPT="${PROMPT:-The capital of France is}"

URL=$(oc get inferenceservice qwen-vllm-serverless -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.components.predictor.url}')
REPLICAS=$(oc get pods -n "${DEMO_NAMESPACE}" -l serving.knative.dev/configuration=qwen-vllm-serverless-predictor --no-headers 2>/dev/null | wc -l)

if [ "${REPLICAS:-0}" = "0" ]; then
  echo "Currently at 0 replicas -- this request will trigger a real cold start (~50s)."
else
  echo "A pod is already running -- this will be a warm request (~0.3-0.5s)."
fi

echo "Sending request to ${URL}/v1/completions ..."
START=$(date +%s)
RESPONSE=$(curl -sk --max-time 150 "${URL}/v1/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"qwen-vllm-serverless\", \"prompt\": \"${PROMPT}\", \"max_tokens\": 15}")
END=$(date +%s)

echo "${RESPONSE}"
echo ""
echo "Took $((END - START))s."
echo "No more requests -> Knative scales this back to 0 automatically after"
echo "~60-90s idle (stable-window + scale-to-zero-grace-period, both in the"
echo "config-autoscaler ConfigMap in the knative-serving namespace)."
echo "Watch it: oc get pods -n ${DEMO_NAMESPACE} -w"
