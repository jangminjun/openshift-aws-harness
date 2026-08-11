#!/usr/bin/env bash
# Runs ON the bastion, after enable-monitoring.sh. Installs the community
# Grafana Operator (v5 API, grafana.integreatly.org/v1beta1) and wires a
# datasource against the in-cluster Thanos Querier so GPU/DCGM metrics from
# openshift-monitoring + openshift-user-workload-monitoring show up in Grafana.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:?set MONITORING_NAMESPACE}"

oc apply -f - <<YAML
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${MONITORING_NAMESPACE}
  namespace: ${MONITORING_NAMESPACE}
spec:
  targetNamespaces:
  - ${MONITORING_NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: ${MONITORING_NAMESPACE}
spec:
  channel: v5
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
YAML

echo "Waiting for Grafana Operator CSV..."
for _ in $(seq 1 40); do
  oc get csv -n "$MONITORING_NAMESPACE" 2>/dev/null | grep -qi succeeded && break
  sleep 15
done

oc apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: grafana-thanos-reader
  namespace: ${MONITORING_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: grafana-thanos-reader-binding
subjects:
- kind: ServiceAccount
  name: grafana-thanos-reader
  namespace: ${MONITORING_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: cluster-monitoring-view
  apiGroup: rbac.authorization.k8s.io
YAML

TOKEN=$(oc create token grafana-thanos-reader -n "$MONITORING_NAMESPACE" --duration=87600h)
oc create secret generic grafana-thanos-token -n "$MONITORING_NAMESPACE" \
  --from-literal=authHeader="Bearer ${TOKEN}" \
  --dry-run=client -o yaml | oc apply -f -

oc apply -f - <<YAML
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: gpu-grafana
  namespace: ${MONITORING_NAMESPACE}
  labels:
    dashboards: "gpu-grafana"
spec:
  config:
    security:
      admin_user: admin
  route:
    spec:
      tls:
        termination: edge
YAML

echo "Waiting for Grafana instance to become ready..."
for _ in $(seq 1 40); do
  oc get pods -n "$MONITORING_NAMESPACE" -l app=gpu-grafana 2>/dev/null | grep -q Running && break
  sleep 10
done

oc apply -f - <<YAML
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: thanos-querier
  namespace: ${MONITORING_NAMESPACE}
spec:
  instanceSelector:
    matchLabels:
      dashboards: "gpu-grafana"
  datasource:
    name: thanos-querier
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    isDefault: true
    jsonData:
      timeInterval: 30s
      tlsSkipVerify: true
      httpHeaderName1: Authorization
    secureJsonData:
      httpHeaderValue1: ""
  valuesFrom:
  - targetPath: "secureJsonData.httpHeaderValue1"
    valueFrom:
      secretKeyRef:
        name: grafana-thanos-token
        key: authHeader
YAML

ROUTE=$(oc get route gpu-grafana-route -n "$MONITORING_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "(route not ready yet)")
echo "Grafana Operator installed. Dashboard URL: https://${ROUTE}  (user: admin / see 'oc get secret gpu-grafana-admin-credentials -n ${MONITORING_NAMESPACE}')"
