#!/usr/bin/env bash
# Runs ON the bastion, after the GPU operator is installed. Installs the
# Red Hat OpenShift AI operator only -- the DataScienceCluster (including
# MaaS) is created by `maas.sh`, not here, so there's exactly one place that
# owns the DSC spec instead of two scripts fighting over it.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

RHOAI_CHANNEL="${RHOAI_CHANNEL:-stable-3.4}"

if oc get csv -n redhat-ods-operator 2>/dev/null | grep -qi rhods; then
  echo "RHOAI operator already installed, skipping."
else
  oc create namespace redhat-ods-operator 2>/dev/null || true
  oc apply -f - <<YAML
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
  channel: ${RHOAI_CHANNEL}
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML

  echo "Waiting for OpenShift AI operator CSV (channel ${RHOAI_CHANNEL})..."
  for _ in $(seq 1 60); do
    oc get csv -n redhat-ods-operator 2>/dev/null | grep -qi succeeded && break
    sleep 15
  done
fi

echo "RHOAI operator installed on channel ${RHOAI_CHANNEL}."
echo "Next: ./harness.sh maas   -- creates the DataScienceCluster (with MaaS) and the rest of the MaaS stack."
