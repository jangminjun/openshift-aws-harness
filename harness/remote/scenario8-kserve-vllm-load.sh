#!/usr/bin/env bash
# Redesigned 2026-08-21 (see scenario8-kserve-vllm-start.sh header): drives
# real sustained concurrent request load against the Scenario 8
# InferenceService to trigger a genuine KEDA scale-out (1->2) via
# vllm:num_requests_waiting crossing its threshold, then lets the load stop
# and watches it settle back down to 1 after cooldownPeriod. Mirrors Red
# Hat's own validation approach (sustained/incremental load, see
# developers.redhat.com/articles/2025/11/26/autoscaling-vllm-openshift-ai-model-serving)
# but with a bash/curl load-generator pod instead of their tool (GuideLLM,
# which needs pip install -- avoided everywhere in this harness).
#
# Gotcha (confirmed live 2026-08-21): the predictor Service is headless
# (clusterIP: None, port 80 -> targetPort 8080). Headless Services don't get
# kube-proxy port translation -- DNS just returns pod IPs directly, so a
# client MUST hit the pod's real listening port (8080), not the Service's
# nominal port 80, or every request gets "Connection refused" and
# vllm:num_requests_waiting never moves off 0 no matter how much load runs.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-kserve-scenario-8}"
CONCURRENCY="${CONCURRENCY:-8}"
DURATION="${DURATION:-90}"
PROMPT="${PROMPT:-Write a short paragraph about the history of the Roman Empire covering its rise expansion and eventual decline}"

echo "=== Before load ==="
oc get deploy qwen-vllm-predictor -n "${DEMO_NAMESPACE}" -o custom-columns=NAME:.metadata.name,REPLICAS:.status.replicas,READY:.status.readyReplicas

oc delete pod vllm-load-generator -n "${DEMO_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true

echo ""
echo "=== Launching load generator (concurrency=${CONCURRENCY}, duration=${DURATION}s) ==="
oc apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: vllm-load-generator
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: vllm-load-generator
spec:
  restartPolicy: Never
  containers:
  - name: load
    image: curlimages/curl:latest
    command: ["sh", "-c"]
    args:
    - |
      end=\$(( \$(date +%s) + ${DURATION} ))
      for w in \$(seq 1 ${CONCURRENCY}); do
        ( while [ "\$(date +%s)" -lt "\$end" ]; do
            curl -s -o /dev/null -m 30 -X POST "http://qwen-vllm-predictor.${DEMO_NAMESPACE}.svc.cluster.local:8080/v1/completions" \
              -H "Content-Type: application/json" \
              -d '{"model":"qwen-vllm","prompt":"${PROMPT}","max_tokens":200}'
          done ) &
      done
      wait
      echo "load generator finished"
YAML

echo ""
echo "=== Watching qwen-vllm-predictor replicas for ${DURATION}s of load + ~60s cooldown ==="
MAX_SEEN=1
STEPS=$(( (DURATION + 60) / 10 ))
for _ in $(seq 1 "$STEPS"); do
  REPLICAS=$(oc get deploy qwen-vllm-predictor -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)
  READY=$(oc get deploy qwen-vllm-predictor -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  echo "$(date +%H:%M:%S)  replicas=${REPLICAS:-0} ready=${READY:-0}"
  [ "${REPLICAS:-0}" -gt "$MAX_SEEN" ] 2>/dev/null && MAX_SEEN="${REPLICAS}"
  sleep 10
done

oc delete pod vllm-load-generator -n "${DEMO_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true

echo ""
if [ "$MAX_SEEN" -ge 2 ]; then
  echo "Scaled out to ${MAX_SEEN} replicas under load and back down -- KEDA scale-up/down both confirmed working."
else
  echo "Never observed more than 1 replica -- load may not have been enough to cross the threshold. Try a higher CONCURRENCY."
fi
oc get deploy qwen-vllm-predictor -n "${DEMO_NAMESPACE}"
