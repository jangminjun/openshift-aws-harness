#!/usr/bin/env bash
# Tears down scenario12 (Kueue GitOps demo). Deleting the ArgoCD Application
# does NOT prune the resources it owned (pruning only happens on sync, and
# there's no sync left to run once the Application is gone) -- so the
# cluster-scoped Kueue objects it created are deleted explicitly here too.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-kueue-scenario-12}"

oc delete application kueue-scenario-12-queues -n openshift-gitops --ignore-not-found
oc delete hardwareprofile kueue-demo-profile -n redhat-ods-applications --ignore-not-found
oc delete clusterqueue demo-cluster-queue --ignore-not-found
oc delete resourceflavor demo-flavor --ignore-not-found
oc delete namespace "${DEMO_NAMESPACE}" --ignore-not-found
echo "Kueue GitOps demo torn down."
