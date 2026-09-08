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
  # Pinned to 3.4 (not "stable", which resolves to the 2.x line on this
  # catalog) — llm-d (LLMInferenceService) and MaaS (modelsAsService) need
  # RHOAI 3.3+; 3.4.4 is the version this harness's llm-d/MaaS tooling was
  # verified against. RHOAI 2.x -> 3.x is not an in-place OLM upgrade path,
  # so if 2.x is already installed, tear it down first (see harness README).
  channel: stable-3.4
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
