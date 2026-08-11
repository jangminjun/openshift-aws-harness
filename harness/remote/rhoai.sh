#!/usr/bin/env bash
# Runs ON the bastion, after the GPU operator is installed. Installs the
# Red Hat OpenShift AI operator and stands up a default DataScienceCluster.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

oc apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: redhat-ods-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: stable
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML

echo "Waiting for OpenShift AI operator CSV..."
for _ in $(seq 1 60); do
  oc get csv -n redhat-ods-operator 2>/dev/null | grep -qi succeeded && break
  sleep 15
done

oc apply -f - <<'YAML'
apiVersion: dscinitialization.opendatahub.io/v1
kind: DSCInitialization
metadata:
  name: default-dsci
spec:
  applicationsNamespace: redhat-ods-applications
  monitoring:
    managementState: Managed
    namespace: redhat-ods-monitoring
---
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    dashboard:
      managementState: Managed
    workbenches:
      managementState: Managed
    kserve:
      managementState: Managed
      defaultDeploymentMode: RawDeployment
      serving:
        managementState: Removed
    modelmeshserving:
      managementState: Managed
    datasciencepipelines:
      managementState: Managed
YAML

echo "OpenShift AI operator + DataScienceCluster submitted."
echo "Dashboard route (once ready): oc get route -n redhat-ods-applications rhods-dashboard"
