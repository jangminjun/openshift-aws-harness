#!/usr/bin/env bash
# Installs the Red Hat OpenShift GitOps Operator (ArgoCD) cluster-wide.
# Generic building block, not scenario-specific -- scenario12 uses it to
# demonstrate GitOps-managed Kueue queue resources, but any future ArgoCD
# Application can target the same default `openshift-gitops` instance the
# operator creates automatically. Runs ON the bastion. Idempotent.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

oc apply -f - <<YAML
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML

# This cluster's openshift-operators OperatorGroup uses Manual InstallPlan
# approval (confirmed live, sandbox2576 2026-10-01 -- servicemeshoperator3/
# dns-operator InstallPlans here are also Manual, just pre-approved by
# RHOAI-Toolkit's own install script). Without this, the Subscription just
# sits there forever with an unapproved InstallPlan and no CSV ever appears
# -- the wait loop below would silently time out with nothing to show for
# it. Find and approve this Subscription's InstallPlan explicitly.
echo "Waiting for the InstallPlan and approving it (Manual approval mode)..."
for _ in $(seq 1 20); do
  plan=$(oc get subscription openshift-gitops-operator -n openshift-operators \
    -o jsonpath='{.status.installplan.name}' 2>/dev/null || true)
  [ -n "$plan" ] && break
  sleep 10
done
if [ -n "${plan:-}" ]; then
  oc patch installplan "$plan" -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
fi

echo "Waiting for OpenShift GitOps Operator CSV..."
for _ in $(seq 1 40); do
  oc get csv -n openshift-operators 2>/dev/null | grep -i openshift-gitops | grep -qi succeeded && break
  sleep 15
done

echo "Waiting for the default ArgoCD instance (openshift-gitops/openshift-gitops)..."
for _ in $(seq 1 40); do
  oc get argocd openshift-gitops -n openshift-gitops >/dev/null 2>&1 && break
  sleep 15
done

oc get pods -n openshift-gitops
route_host=$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || true)
echo "OpenShift GitOps installed."
if [ -n "$route_host" ]; then
  echo "ArgoCD UI: https://${route_host} (login via OpenShift OAuth)"
fi
