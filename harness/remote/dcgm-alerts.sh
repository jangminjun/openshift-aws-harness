#!/usr/bin/env bash
# Runs ON the bastion, after gpu-operator. Installs a standalone Prometheus +
# Alertmanager (its own community Prometheus Operator instance, installed
# SingleNamespace-scoped to MONITORING_NAMESPACE) dedicated to GPU hardware
# alerting.
#
# Why not OpenShift's own User Workload Monitoring (UWM)? UWM's
# ThanosRuler/Alertmanager enforce that every PrometheusRule/AlertmanagerConfig
# belongs to exactly one tenant namespace (enforcedNamespaceLabel +
# alertmanagerConfigMatcherStrategy: OnNamespace, neither overridable from the
# ConfigMap on this cluster, and a direct CR patch gets reverted by
# cluster-monitoring-operator whenever it resyncs). GPU overheat/XID faults
# are a fleet-wide infra concern, not any one tenant's, so they never fit that
# model — the rule silently never fires. A fully separate stack sidesteps the
# tenant model entirely instead of fighting it. Idempotent (oc apply).
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:?set MONITORING_NAMESPACE}"
GPU_TEMP_THRESHOLD_C="${GPU_TEMP_THRESHOLD_C:-70}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SLACK_CHANNEL="${SLACK_CHANNEL:-#alarm-gpu-monitoring}"

oc apply -f - <<YAML
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: prometheus-operator-standalone
  namespace: ${MONITORING_NAMESPACE}
spec:
  channel: beta
  name: prometheus
  source: community-operators
  sourceNamespace: openshift-marketplace
YAML

echo "Waiting for standalone Prometheus Operator CSV..."
for _ in $(seq 1 40); do
  oc get csv -n "$MONITORING_NAMESPACE" 2>/dev/null | grep -i prometheusoperator | grep -qi succeeded && break
  sleep 15
done

oc apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gpu-alert-prometheus
  namespace: ${MONITORING_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gpu-alert-prometheus
rules:
- apiGroups: [""]
  resources: ["nodes", "nodes/metrics", "services", "endpoints", "pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch"]
- nonResourceURLs: ["/metrics"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gpu-alert-prometheus
subjects:
- kind: ServiceAccount
  name: gpu-alert-prometheus
  namespace: ${MONITORING_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: gpu-alert-prometheus
  apiGroup: rbac.authorization.k8s.io
YAML

# The operator was installed SingleNamespace-scoped (OLM restricts its own
# controller RBAC to MONITORING_NAMESPACE), so it can't discover the
# ServiceMonitor GPU Operator already created in nvidia-gpu-operator — this
# declares an equivalent one INSIDE our namespace instead, pointed at that
# namespace via namespaceSelector. The Prometheus pod's own ClusterRole above
# already has cross-namespace scrape access; only the operator's own
# object-discovery was namespace-limited.
oc apply -f - <<YAML
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: gpu-alert-dcgm-exporter
  namespace: ${MONITORING_NAMESPACE}
  labels:
    app: nvidia-dcgm-exporter
spec:
  namespaceSelector:
    matchNames:
    - nvidia-gpu-operator
  selector:
    matchLabels:
      app: nvidia-dcgm-exporter
  endpoints:
  - port: gpu-metrics
    path: /metrics
YAML

oc apply -f - <<YAML
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-scenario1-alerts-standalone
  namespace: ${MONITORING_NAMESPACE}
  labels:
    role: gpu-alert-rules
spec:
  groups:
  - name: gpu-overheat-and-faults
    rules:
    - alert: GPUHighTemperature
      expr: DCGM_FI_DEV_GPU_TEMP >= ${GPU_TEMP_THRESHOLD_C}
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "GPU {{ \$labels.gpu }} on {{ \$labels.Hostname }} is over ${GPU_TEMP_THRESHOLD_C}C"
        description: "DCGM_FI_DEV_GPU_TEMP={{ \$value }}C for 2m+. Candidate for cordon/drain per scenario 1."
    - alert: GPUXidError
      expr: DCGM_FI_DEV_XID_ERRORS != 0
      for: 0m
      labels:
        severity: critical
      annotations:
        summary: "XID error on GPU {{ \$labels.gpu }} ({{ \$labels.Hostname }})"
        description: "DCGM_FI_DEV_XID_ERRORS={{ \$value }}. Possible NVLink/hardware fault."
YAML

# Raw Alertmanager config (not the AlertmanagerConfig CRD) — this Alertmanager
# is entirely self-managed, so there's no tenant matcher to fight and no
# reason to route through a secret-ref indirection.
cat > /tmp/gpu-alertmanager.yaml <<YAML
global: {}
route:
  receiver: slack-gpu-alerts
  group_by: ["alertname", "Hostname"]
  group_wait: 10s
  group_interval: 5m
  repeat_interval: 1h
receivers:
- name: slack-gpu-alerts
  slack_configs:
  - api_url: "${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/PLACEHOLDER}"
    channel: "${SLACK_CHANNEL}"
    send_resolved: true
    title: "{{ .CommonAnnotations.summary }}"
    text: "{{ .CommonAnnotations.description }}"
YAML
oc create secret generic alertmanager-gpu-alertmanager -n "${MONITORING_NAMESPACE}" \
  --from-file=alertmanager.yaml=/tmp/gpu-alertmanager.yaml \
  --dry-run=client -o yaml | oc apply -f -
rm -f /tmp/gpu-alertmanager.yaml

oc apply -f - <<YAML
apiVersion: monitoring.coreos.com/v1
kind: Alertmanager
metadata:
  name: gpu-alertmanager
  namespace: ${MONITORING_NAMESPACE}
spec:
  replicas: 1
  serviceAccountName: gpu-alert-prometheus
---
apiVersion: v1
kind: Service
metadata:
  name: gpu-alertmanager
  namespace: ${MONITORING_NAMESPACE}
spec:
  selector:
    alertmanager: gpu-alertmanager
  ports:
  - name: web
    port: 9093
    targetPort: 9093
YAML

oc apply -f - <<YAML
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: gpu-alert-prom
  namespace: ${MONITORING_NAMESPACE}
spec:
  replicas: 1
  serviceAccountName: gpu-alert-prometheus
  serviceMonitorSelector:
    matchLabels:
      app: nvidia-dcgm-exporter
  serviceMonitorNamespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: ${MONITORING_NAMESPACE}
  ruleSelector:
    matchLabels:
      role: gpu-alert-rules
  ruleNamespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: ${MONITORING_NAMESPACE}
  alerting:
    alertmanagers:
    - namespace: ${MONITORING_NAMESPACE}
      name: gpu-alertmanager
      port: web
YAML

echo "Waiting for standalone Prometheus + Alertmanager pods..."
for _ in $(seq 1 30); do
  oc get pods -n "$MONITORING_NAMESPACE" -l prometheus=gpu-alert-prom 2>/dev/null | grep -q Running && \
  oc get pods -n "$MONITORING_NAMESPACE" -l alertmanager=gpu-alertmanager 2>/dev/null | grep -q Running && break
  sleep 10
done

if [ -z "$SLACK_WEBHOOK_URL" ]; then
  echo "NOTE: SLACK_WEBHOOK_URL was empty — alertmanager-gpu-alertmanager secret has a placeholder URL."
  echo "  Re-run with SLACK_WEBHOOK_URL set to wire it up for real."
else
  echo "Slack webhook wired to channel ${SLACK_CHANNEL}."
fi
echo "Standalone GPU alerting stack ready in ${MONITORING_NAMESPACE} (decoupled from UWM tenant isolation)."
