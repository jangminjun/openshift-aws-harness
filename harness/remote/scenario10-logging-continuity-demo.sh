#!/usr/bin/env bash
# Scenario 10 (logging half): proves logs stay continuous across a pod
# being replaced, not just "survives one pod's death". Wakes scenario 9
# TWICE (each wake creates a brand new pod once the previous one scales
# back to 0), then queries Loki ONCE across the whole window and shows both
# pod generations' logs coming back together in a single query -- exactly
# what you'd want when investigating an issue that spans a scale-down/
# scale-up cycle. Requires scenario 9 and OpenShift Logging
# (`./harness.sh openshift-logging`) to already be deployed.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

NS9="${NS9:-gpu-kserve-scenario-9}"
LOGGING_NAMESPACE="${LOGGING_NAMESPACE:-openshift-logging}"
GATEWAY_URL="https://$(oc get route logging-loki -n "${LOGGING_NAMESPACE}" -o jsonpath='{.spec.host}')"

wait_for_zero() {
  for _ in $(seq 1 20); do
    COUNT=$(oc get pods -n "${NS9}" -l serving.knative.dev/configuration=qwen-vllm-serverless-predictor --no-headers 2>/dev/null | wc -l)
    [ "${COUNT:-0}" = "0" ] && return 0
    sleep 15
  done
  echo "Timed out waiting for scale-to-zero" >&2
  return 1
}

wake_once() {
  local marker="$1"
  local url
  url=$(oc get inferenceservice qwen-vllm-serverless -n "${NS9}" -o jsonpath='{.status.components.predictor.url}')
  curl -sk --max-time 150 "${url}/v1/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"qwen-vllm-serverless\", \"prompt\": \"${marker}\", \"max_tokens\": 5}" > /dev/null
  oc get pods -n "${NS9}" -l serving.knative.dev/configuration=qwen-vllm-serverless-predictor -o jsonpath='{.items[0].metadata.name}'
}

echo "=== Wake #1 (creates pod generation A) ==="
POD_A=$(wake_once "continuity-marker-A")
echo "pod A = ${POD_A}"

echo "=== Waiting for pod A to scale back to 0 ==="
wait_for_zero

echo "=== Wake #2 (creates a brand new pod generation B) ==="
POD_B=$(wake_once "continuity-marker-B")
echo "pod B = ${POD_B}"

echo "=== Waiting for pod B to scale back to 0 ==="
wait_for_zero

echo ""
echo "Both pods are gone now -- confirm oc logs can't see either:"
oc logs "${POD_A}" -n "${NS9}" -c kserve-container 2>&1 | tail -3 || true
oc logs "${POD_B}" -n "${NS9}" -c kserve-container 2>&1 | tail -3 || true

echo ""
echo "=== Single Loki query spanning both pod generations ==="
TOKEN=$(oc create token logging-log-reader -n "${LOGGING_NAMESPACE}" --duration=10m)
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "${GATEWAY_URL}/api/logs/v1/application/loki/api/v1/query_range" \
  --data-urlencode "query={kubernetes_namespace_name=\"${NS9}\", kubernetes_container_name=\"kserve-container\"}" \
  --data-urlencode "start=$(date -u -d "-10 minutes" +%s)000000000" \
  --data-urlencode "end=$(date -u +%s)000000000" \
  --data-urlencode "limit=500" \
  --data-urlencode "direction=forward" \
  -G | python3 -c "
import json, sys
d = json.load(sys.stdin)
res = d['data']['result']
print(f'{len(res)} pod generations found in ONE query (should be 2: pod A and pod B):')
for s in res:
    print(f'  {s[\"stream\"].get(\"kubernetes_pod_name\")}: {len(s[\"values\"])} lines')
"
echo ""
echo "This is the proof point: querying by namespace+container (a label"
echo "that stays constant across pod replacement) returns both generations'"
echo "logs together, not just whichever pod happens to be alive right now."
