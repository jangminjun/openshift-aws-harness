#!/usr/bin/env bash
# Runs ON the bastion, after the GPU operator is installed. Installs the
# Red Hat OpenShift AI operator only -- the DataScienceCluster (including
# MaaS) is created by `maas.sh`, not here, so there's exactly one place that
# owns the DSC spec instead of two scripts fighting over it.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

RHOAI_CHANNEL="${RHOAI_CHANNEL:-stable-3.4}"

# OLM can't compute a channel switch across a major-version boundary (no
# `replaces` chain links 2.x CSVs to 3.x ones) -- `oc patch subscription
# --type=merge -p '{"spec":{"channel":"stable-3.4"}}'` on an existing
# 2.x subscription just sits there with status.currentCSV still pointing at
# the old CSV and no new InstallPlan ever appears. Confirmed live
# (basic-demo/lessonlearn.md #7): the only way to actually move is to delete
# the Subscription + its CSV and let a fresh Subscription install cleanly
# on the new channel.
EXISTING_CHANNEL=$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.spec.channel}' 2>/dev/null || true)
if [ -n "$EXISTING_CHANNEL" ] && [ "$EXISTING_CHANNEL" != "$RHOAI_CHANNEL" ]; then
  echo "RHOAI operator subscribed to channel '${EXISTING_CHANNEL}', want '${RHOAI_CHANNEL}' -- OLM won't cross-upgrade major versions in place. Deleting Subscription+CSV for a clean reinstall."
  EXISTING_CSV=$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)
  oc delete subscription rhods-operator -n redhat-ods-operator --ignore-not-found
  [ -n "$EXISTING_CSV" ] && oc delete csv "$EXISTING_CSV" -n redhat-ods-operator --ignore-not-found
fi

if oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.spec.channel}' 2>/dev/null | grep -qx "$RHOAI_CHANNEL" \
   && oc get csv -n redhat-ods-operator 2>/dev/null | grep -qi succeeded; then
  echo "RHOAI operator already installed on channel ${RHOAI_CHANNEL}, skipping."
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
  # RHOAI_CHANNEL defaults to stable-3.4, not "stable" (which resolves to
  # the 2.x line on this catalog) -- MaaS (kserve.modelsAsService) needs
  # RHOAI 3.3+; 3.4.4 is the version this harness's MaaS tooling was
  # verified against.
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
