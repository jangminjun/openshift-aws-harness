#!/usr/bin/env bash
# Sends a real inference request to the Scenario 8 InferenceService. If it's
# currently at 0 replicas, first demonstrates the actual failure mode (a
# request against a headless Service with no endpoints fails at DNS
# resolution -- confirmed 2026-08-20, not just "connection refused"), then
# manually scales it to 1 to continue the demo, since KEDA's
# Prometheus-on-vllm's-own-metric trigger cannot detect demand while no pod
# exists to emit that metric (see the note in scenario8-kserve-vllm-start.sh
# and Scenario 10 in the docs). This mirrors what a human operator or an
# external system (e.g. a router-metric-based trigger) would have to do
# today; it is not KEDA scaling itself up.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-kserve-scenario-8}"
PROMPT="${PROMPT:-The capital of France is}"

REPLICAS=$(oc get deploy qwen-vllm-predictor -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)

if [ "${REPLICAS:-0}" = "0" ]; then
  echo "Currently at 0 replicas. Demonstrating the real 0-replica request failure first..."
  oc run curl-test-cold -n "${DEMO_NAMESPACE}" --image=curlimages/curl:latest --rm -i --restart=Never --command -- \
    curl -sv --max-time 10 http://qwen-vllm-predictor."${DEMO_NAMESPACE}".svc.cluster.local/v1/completions 2>&1 | tail -6 || true
  echo ""
  echo "That's the known gap: a headless Service with zero endpoints fails DNS"
  echo "resolution outright (not a graceful queue) -- KEDA's own trigger has no"
  echo "way to detect this request either, since it reads a metric the (absent)"
  echo "pod would have emitted. Scaling up manually to continue the demo..."
  oc scale deploy/qwen-vllm-predictor -n "${DEMO_NAMESPACE}" --replicas=1
  echo "Waiting for the pod to become Ready..."
  for _ in $(seq 1 30); do
    POD=$(oc get pods -n "${DEMO_NAMESPACE}" -l app=isvc.qwen-vllm-predictor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [ -n "$POD" ] || { sleep 5; continue; }
    READY=$(oc get pod "$POD" -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.containerStatuses[?(@.name=="kserve-container")].ready}' 2>/dev/null || true)
    [ "$READY" = "true" ] && break
    sleep 5
  done
fi

POD=$(oc get pods -n "${DEMO_NAMESPACE}" -l app=isvc.qwen-vllm-predictor -o jsonpath='{.items[0].metadata.name}')
echo ""
echo "Sending a real completion request (prompt: \"${PROMPT}\")..."
oc exec -n "${DEMO_NAMESPACE}" "$POD" -c kserve-container -- curl -s -X POST http://localhost:8080/v1/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"qwen-vllm\", \"prompt\": \"${PROMPT}\", \"max_tokens\": 15}"
echo ""
echo ""
echo "No more requests -> KEDA scales this back to 0 after cooldownPeriod (60s)"
echo "once its poll (every 15s) sees the trigger inactive. Watch it happen:"
echo "  oc get deploy qwen-vllm-predictor -n ${DEMO_NAMESPACE} -w"
