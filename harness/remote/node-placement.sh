#!/usr/bin/env bash
# Runs ON the bastion. Pins existing components onto the router/infra/oai
# node pools node-pools.sh created, via nodeSelector + a matching toleration
# for each role's NoSchedule taint. Run this AFTER node-pools AND after
# rhoai + maas + monitoring-all + openshift-logging have all finished --
# every object patched here must already exist. Idempotent (patches are
# re-appliable).
#
# router and the "infra" pieces this harness fully owns the YAML for
# (its own standalone Prometheus/Alertmanager/Grafana, UWM config, the Loki/
# cluster-logging Subscriptions and LokiStack's own per-component
# placement) use long-stable, well-documented OpenShift APIs. The "oai"
# section is a first pass, NOT verified live yet (written 2026-10-16, no
# reachable cluster at the time) -- see the comment above OAI_NAMESPACES
# below. After running this, always do a live sanity check:
#   oc get pods -A -o wide | grep -v openshift- # (skip core platform namespaces)
# and compare node placement against the role table in
# GPUaaS-SCENARIOS(KOR).md / lessonlearn.md; fix up this script and record
# what was actually true once confirmed.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-gpu-monitoring}"
LOGGING_NAMESPACE="${LOGGING_NAMESPACE:-openshift-logging}"

node_selector_patch() {
  local role="$1"
  cat <<JSON
{"nodeSelector":{"node-role.kubernetes.io/${role}":""},"tolerations":[{"key":"node-role.kubernetes.io/${role}","operator":"Exists","effect":"NoSchedule"}]}
JSON
}

echo "=== router: IngressController nodePlacement ==="
oc patch ingresscontroller default -n openshift-ingress-operator --type=merge -p '{
  "spec": {
    "nodePlacement": {
      "nodeSelector": {"matchLabels": {"node-role.kubernetes.io/router": ""}},
      "tolerations": [{"key": "node-role.kubernetes.io/router", "operator": "Exists", "effect": "NoSchedule"}]
    }
  }
}'

echo "=== infra: standalone GPU-alerting Prometheus/Alertmanager ==="
INFRA_PATCH=$(node_selector_patch infra)
oc patch prometheus gpu-alert-prom -n "$MONITORING_NAMESPACE" --type=merge -p "{\"spec\":${INFRA_PATCH}}" 2>/dev/null || echo "  (gpu-alert-prom Prometheus not found, skipping)"
oc patch alertmanager gpu-alertmanager -n "$MONITORING_NAMESPACE" --type=merge -p "{\"spec\":${INFRA_PATCH}}" 2>/dev/null || echo "  (gpu-alertmanager Alertmanager not found, skipping)"

echo "=== infra: Grafana ==="
oc patch grafana gpu-grafana -n "$MONITORING_NAMESPACE" --type=merge -p "{\"spec\":{\"deployment\":{\"spec\":{\"template\":{\"spec\":${INFRA_PATCH}}}}}}" 2>/dev/null || echo "  (gpu-grafana Grafana not found, skipping)"

echo "=== infra: User Workload Monitoring (prometheus/alertmanager/prometheusOperator) ==="
oc apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |
    prometheus:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        operator: Exists
        effect: NoSchedule
    alertmanager:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        operator: Exists
        effect: NoSchedule
    prometheusOperator:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
      - key: node-role.kubernetes.io/infra
        operator: Exists
        effect: NoSchedule
YAML

echo "=== infra: Loki Operator + Cluster Logging Operator (operator pods only) ==="
oc patch subscription loki-operator -n openshift-operators-redhat --type=merge -p "{\"spec\":{\"config\":${INFRA_PATCH}}}" 2>/dev/null || echo "  (loki-operator Subscription not found, skipping)"
oc patch subscription cluster-logging -n "$LOGGING_NAMESPACE" --type=merge -p "{\"spec\":{\"config\":${INFRA_PATCH}}}" 2>/dev/null || echo "  (cluster-logging Subscription not found, skipping)"

echo "=== infra: LokiStack component pods (NOT the log-collector DaemonSet -- that must stay on every node) ==="
LOKISTACK_TEMPLATE=$(jq -n --argjson infra "$INFRA_PATCH" '
  {compactor:$infra, distributor:$infra, gateway:$infra, indexGateway:$infra, ingester:$infra, querier:$infra, queryFrontend:$infra}
  | {spec: {template: .}}
')
oc patch lokistack logging-loki -n "$LOGGING_NAMESPACE" --type=merge -p "$LOKISTACK_TEMPLATE" 2>/dev/null || echo "  (logging-loki LokiStack not found, skipping)"

# OAI: BEST-EFFORT FIRST PASS, NOT LIVE-VERIFIED (see header comment).
# Rather than hardcoding exact Subscription names we never confirmed live,
# this discovers whatever Subscriptions actually exist in the namespaces
# RHOAI/RHOAI-Toolkit are known (from this session's live output) to use,
# and patches all of them. After running, cross-check `oc get pods -A -o
# wide` against the role table and extend OAI_NAMESPACES / fix stragglers.
echo "=== oai: RHOAI + RHOAI-Toolkit operator Subscriptions (best-effort) ==="
OAI_NAMESPACES="${OAI_NAMESPACES:-redhat-ods-operator redhat-ods-applications redhat-ai-gateway-infra models-as-a-service rhoai-model-registries kuadrant-system}"
for ns in $OAI_NAMESPACES; do
  for sub in $(oc get subscription -n "$ns" -o name 2>/dev/null); do
    oc patch "$sub" -n "$ns" --type=merge -p "{\"spec\":{\"config\":$(node_selector_patch oai)}}" 2>/dev/null \
      && echo "  patched $sub -n $ns" \
      || echo "  failed to patch $sub -n $ns (check live)"
  done
done

echo "Node placement applied. Verify with: oc get pods -A -o wide"
