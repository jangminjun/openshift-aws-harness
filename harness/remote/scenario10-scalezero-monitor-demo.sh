#!/usr/bin/env bash
# Scenario 10: monitoring a scale-to-zero service. Contrasts what actually
# happens when scenario 8 (KEDA/RawDeployment) and scenario 9 (Knative
# Serverless) are both idle at 0 replicas and a real request comes in --
# KEDA fails outright (no pod exists to emit the trigger metric, and the
# headless Service has zero endpoints so the request fails at DNS
# resolution), Knative's Activator actually wakes a pod and the request
# succeeds. Read-only against both scenarios' own state; requires scenario 8
# and scenario 9 to already be deployed via their own start.sh scripts.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

NS8="${NS8:-gpu-kserve-scenario-8}"
NS9="${NS9:-gpu-kserve-scenario-9}"

echo "=== Replica count right now ==="
S8_REPLICAS="$(oc get deploy qwen-vllm-predictor -n "$NS8" -o jsonpath='{.status.replicas}' 2>/dev/null || true)"
echo "Scenario 8 (KEDA):    ${S8_REPLICAS:-0} replicas"
echo "Scenario 9 (Knative): $(oc get pods -n "$NS9" -l serving.knative.dev/configuration=qwen-vllm-serverless-predictor --no-headers 2>/dev/null | wc -l) replicas"
echo "(Grafana Tier1 dashboard -> 'Scale-to-Zero Monitoring (Scenario 10)'"
echo "row graphs both of these over time via kube-state-metrics.)"
echo ""

echo "=== 1/2: Scenario 8 (KEDA) -- sending a request at 0 replicas ==="
echo "Known finding: no pod exists to emit the metric KEDA's trigger reads,"
echo "and the headless Service has zero endpoints -- the request fails at"
echo "DNS resolution, not a graceful queue."
oc run curl-scenario10-keda -n "$NS8" --image=curlimages/curl:latest --rm -i --restart=Never --command -- \
  curl -sv --max-time 10 http://qwen-vllm-predictor."$NS8".svc.cluster.local/v1/completions 2>&1 | tail -8 || true
echo ""

echo "=== 2/2: Scenario 9 (Knative) -- sending a request at 0 replicas ==="
echo "Knative's Activator sits in the request path and actually wakes a pod."
echo "Watch it live in another terminal: oc get pods -n $NS9 -w"
URL=$(oc get inferenceservice qwen-vllm-serverless -n "$NS9" -o jsonpath='{.status.components.predictor.url}')
echo "Sending request (real cold start, ~50s with the PVC-cached model)..."
START=$(date +%s)
curl -sk --max-time 150 "${URL}/v1/completions" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen-vllm-serverless", "prompt": "The capital of France is", "max_tokens": 15}'
END=$(date +%s)
echo ""
echo "Succeeded in $((END - START))s -- no retry needed (see harness/GPUaaS-"
echo "SCENARIOS(KOR).md Scenario 9 for the before/after PVC-caching numbers)."
echo ""

echo "=== Live Knative autoscaler view (desiredScale/actualScale/reason) ==="
oc get pa -n "$NS9" 2>/dev/null || true
echo ""
echo "Same signal over time in Grafana; the KEDA side has no equivalent"
echo "success-path graph since the request never got a pod to observe."
