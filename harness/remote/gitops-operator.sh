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
[ -n "$route_host" ] && echo "ArgoCD UI: https://${route_host} (login via OpenShift OAuth)"
