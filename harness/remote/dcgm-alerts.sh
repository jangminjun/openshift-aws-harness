#!/usr/bin/env bash
# Runs ON the bastion, after enable-monitoring.sh. Creates PrometheusRule
# alerts for GPU overheat / XID hardware errors (scenario 1 in
# openshift-monitoring), and an AlertmanagerConfig routing them to Slack.
# If SLACK_WEBHOOK_URL is empty, the structure is still created with a
# placeholder so it can be wired up later without re-running anything else.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:?set MONITORING_NAMESPACE}"
GPU_TEMP_THRESHOLD_C="${GPU_TEMP_THRESHOLD_C:-85}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SLACK_CHANNEL="${SLACK_CHANNEL:-#gpu-alerts}"

oc create secret generic slack-webhook -n "$MONITORING_NAMESPACE" \
  --from-literal=url="${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/PLACEHOLDER}" \
  --dry-run=client -o yaml | oc apply -f -

oc apply -f - <<YAML
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-scenario1-alerts
  namespace: ${MONITORING_NAMESPACE}
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

oc apply -f - <<YAML
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: gpu-slack-routing
  namespace: ${MONITORING_NAMESPACE}
spec:
  route:
    receiver: slack-gpu-alerts
    groupBy: ["alertname", "Hostname"]
    groupWait: 10s
    groupInterval: 5m
    repeatInterval: 1h
  receivers:
  - name: slack-gpu-alerts
    slackConfigs:
    - apiURL:
        name: slack-webhook
        key: url
      channel: "${SLACK_CHANNEL}"
      sendResolved: true
      title: '{{ .CommonAnnotations.summary }}'
      text: '{{ .CommonAnnotations.description }}'
YAML

if [ -z "$SLACK_WEBHOOK_URL" ]; then
  echo "NOTE: SLACK_WEBHOOK_URL was empty — 'slack-webhook' secret has a placeholder URL."
  echo "  Update it later with:"
  echo "  oc create secret generic slack-webhook -n ${MONITORING_NAMESPACE} --from-literal=url=<real-webhook> --dry-run=client -o yaml | oc apply -f -"
else
  echo "Slack webhook wired to channel ${SLACK_CHANNEL}."
fi
echo "PrometheusRule gpu-scenario1-alerts + AlertmanagerConfig gpu-slack-routing applied."
