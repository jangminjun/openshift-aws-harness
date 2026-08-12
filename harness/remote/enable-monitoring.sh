#!/usr/bin/env bash
# Runs ON the bastion. Enables User Workload Monitoring so Prometheus scrapes
# GPU Operator's dcgm-exporter ServiceMonitor, and turns on user-defined
# Alertmanager config (namespace-scoped AlertmanagerConfig CRs, no matcher
# required) so the demo namespace can route its own alerts to Slack.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:?set MONITORING_NAMESPACE}"

# enableUserAlertmanagerConfig makes CMO set alertmanagerConfigSelector /
# alertmanagerConfigNamespaceSelector to non-nil on alertmanager-main — a nil
# selector means "match nothing", so without this, AlertmanagerConfig CRs in
# user namespaces are silently never picked up. (Older OCP used a nested
# alertmanagerMain.alertmanagerConfiguration.matcherStrategy field for this;
# it's been flattened/renamed here.)
oc apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
    alertmanagerMain:
      enableUserAlertmanagerConfig: true
YAML

for _ in $(seq 1 20); do
  oc get pods -n openshift-user-workload-monitoring 2>/dev/null | grep -q Running && break
  sleep 10
done

# NOTE: deliberately no openshift.io/cluster-monitoring: "true" label here —
# alertmanagerConfigNamespaceSelector (set above) explicitly excludes
# namespaces carrying it, so labeling this namespace with it would silently
# drop its AlertmanagerConfig from routing again.
oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${MONITORING_NAMESPACE}
YAML

echo "User Workload Monitoring enabled. Namespace ${MONITORING_NAMESPACE} ready."
