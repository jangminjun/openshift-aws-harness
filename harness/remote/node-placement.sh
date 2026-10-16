#!/usr/bin/env bash
# Runs ON the bastion. Pins existing components onto the router/infra/oai
# node pools node-pools.sh created, via nodeSelector + a matching toleration
# for each role's NoSchedule taint. Run this AFTER node-pools AND after
# rhoai + maas + monitoring-all + openshift-logging have all finished --
# every object patched here must already exist. Idempotent (patches are
# re-appliable).
#
# Live-verified end to end on sandbox1414, 2026-10-16 (router/infra pods
# confirmed landed on the right nodes; oai Subscription names below are the
# real ones, not a guess -- see the comment above OAI_SUBSCRIPTIONS). Two
# real bugs found and fixed along the way: the default IngressController
# runs 2 replicas with anti-affinity (only 1 router node here, so the 2nd
# sat Pending forever -- now pinned to replicas:1), and gpu-grafana-data's
# PVC carries whatever AZ it first provisioned in, which can mismatch
# NODE_POOL_AZ once Grafana is forced onto the single infra node (also
# fixed below). The Kueue OPERAND (kueue-controller-manager, as opposed to
# the openshift-kueue-operator controller pod) is a separate Deployment not
# covered by the Subscription-level nodeSelector patch and stays on
# cpu-worker nodes -- not fixed here, flag if that actually matters for a
# demo. After running this, always do a live sanity check:
#   oc get pods -A -o wide | grep -v openshift- # (skip core platform namespaces)
# and compare node placement against the role table in
# GPUaaS-SCENARIOS(KOR).md / lessonlearn.md.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-gpu-monitoring}"
LOGGING_NAMESPACE="${LOGGING_NAMESPACE:-openshift-logging}"
NODE_POOL_AZ="${NODE_POOL_AZ:-us-east-1a}"

node_selector_patch() {
  local role="$1"
  cat <<JSON
{"nodeSelector":{"node-role.kubernetes.io/${role}":""},"tolerations":[{"key":"node-role.kubernetes.io/${role}","operator":"Exists","effect":"NoSchedule"}]}
JSON
}

echo "=== router: IngressController nodePlacement ==="
# replicas must match the router node pool's size (node-pools.sh creates
# exactly 1) -- the default IngressController runs 2 replicas with
# pod anti-affinity spreading them across nodes, so with only 1 router
# node the 2nd replica sits permanently Pending otherwise. Hit live on
# sandbox1414, 2026-10-16.
oc patch ingresscontroller default -n openshift-ingress-operator --type=merge -p '{
  "spec": {
    "replicas": 1,
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
# gpu-grafana-data's EBS PV carries a zone nodeAffinity from whatever AZ the
# worker node it first ran on happened to be in (workers spread across
# a/b/c/d/f) -- if that doesn't match NODE_POOL_AZ, the pod becomes
# permanently unschedulable once pinned to the single infra node ("1
# node(s) didn't match PersistentVolume's node affinity"). Hit live on
# sandbox1414, 2026-10-16. Recreate the PVC so it (re)provisions, via
# WaitForFirstConsumer, in whatever zone the pod actually lands in this
# time -- losing Grafana's own dashboard/org DB is fine, GrafanaDashboard/
# GrafanaDatasource CRs reconcile it back declaratively.
GRAFANA_PV=$(oc get pvc gpu-grafana-data -n "$MONITORING_NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
if [ -n "$GRAFANA_PV" ]; then
  GRAFANA_PVC_ZONE=$(oc get pv "$GRAFANA_PV" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}' 2>/dev/null || true)
  if [ -n "$GRAFANA_PVC_ZONE" ] && [ "$GRAFANA_PVC_ZONE" != "$NODE_POOL_AZ" ]; then
    echo "  gpu-grafana-data PV is pinned to ${GRAFANA_PVC_ZONE}, not ${NODE_POOL_AZ} -- recreating so it reprovisions in the right zone"
    oc scale deployment gpu-grafana-deployment -n "$MONITORING_NAMESPACE" --replicas=0 2>/dev/null || true
    oc delete pvc gpu-grafana-data -n "$MONITORING_NAMESPACE" --wait=true --timeout=60s 2>/dev/null || true
    oc apply -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gpu-grafana-data
  namespace: ${MONITORING_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 2Gi
YAML
  fi
fi
oc patch grafana gpu-grafana -n "$MONITORING_NAMESPACE" --type=merge -p "{\"spec\":{\"deployment\":{\"spec\":{\"template\":{\"spec\":${INFRA_PATCH}}}}}}" 2>/dev/null || echo "  (gpu-grafana Grafana not found, skipping)"

echo "=== infra: User Workload Monitoring (prometheusOperator only) ==="
# prometheus/alertmanager keys deliberately NOT set here. UWM's Prometheus
# StatefulSet runs 2 replicas with pod anti-affinity and CMO's admission
# webhook rejects "prometheus.replicas" in this ConfigMap outright (not a
# supported override) -- with only 1 infra node, the 2nd replica sits
# Pending forever (confirmed live, sandbox1414, 2026-10-16). UWM
# Alertmanager isn't even deployed by this harness's config
# (enableUserAlertmanagerConfig just wires routing on the PLATFORM
# alertmanager-main, no separate UWM instance exists to move). Only
# prometheusOperator (a plain 1-replica Deployment) is safe to move onto a
# single-node pool. Moving the other two would need a 2+-node infra pool.
oc apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |
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

# OAI: live-verified on sandbox1414, 2026-10-16. RHOAI-Toolkit's
# install-rhoai-35.sh does NOT create per-component namespaces for its
# Subscriptions (the earlier guess of redhat-ods-applications/
# redhat-ai-gateway-infra/models-as-a-service/rhoai-model-registries/
# kuadrant-system was wrong -- those are workload namespaces, not where the
# Subscriptions live). The actual Subscriptions are centralized:
#   redhat-ods-operator/rhods-operator                                       (RHOAI itself)
#   openshift-operators/kueue-operator                                       (Kueue)
#   openshift-operators/rhcl-operator                                        (RHCL)
#   openshift-operators/authorino-operator-stable-redhat-operators-openshift-marketplace  (RHCL dep)
#   openshift-operators/limitador-operator-stable-redhat-operators-openshift-marketplace  (RHCL dep)
#   openshift-operators/servicemeshoperator3                                 (RHCL dep, Service Mesh 3)
# `openshift-operators` is a SHARED namespace that also hosts core cluster
# operators (e.g. dns-operator) this must NOT move -- hence an explicit
# name list here rather than patching every Subscription found in it.
echo "=== oai: RHOAI + RHOAI-Toolkit operator Subscriptions ==="
OAI_SUBSCRIPTIONS="${OAI_SUBSCRIPTIONS:-redhat-ods-operator/rhods-operator openshift-operators/kueue-operator openshift-operators/rhcl-operator openshift-operators/authorino-operator-stable-redhat-operators-openshift-marketplace openshift-operators/limitador-operator-stable-redhat-operators-openshift-marketplace openshift-operators/servicemeshoperator3}"
for pair in $OAI_SUBSCRIPTIONS; do
  ns="${pair%%/*}"; sub="${pair#*/}"
  oc patch subscription "$sub" -n "$ns" --type=merge -p "{\"spec\":{\"config\":$(node_selector_patch oai)}}" 2>/dev/null \
    && echo "  patched subscription/$sub -n $ns" \
    || echo "  subscription/$sub -n $ns not found, skipping"
done

echo "Node placement applied. Verify with: oc get pods -A -o wide"
