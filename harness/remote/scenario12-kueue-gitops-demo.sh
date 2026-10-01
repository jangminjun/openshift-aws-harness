#!/usr/bin/env bash
# Runs ON the bastion, after gitops-operator. Demonstrates two RHOAI 3.5 GA
# Kueue features together (confirmed live against this harness's own
# DataScienceCluster CRD, 2026-10-01 -- see lessonlearn.md):
#   1. Workbench scheduling visibility (Queued/Starting/Preempted states on
#      the Workbenches tab) -- needs a HardwareProfile with
#      spec.scheduling.type=Queue referencing a Kueue LocalQueue.
#   2. GitOps-managed queues (DataScienceCluster
#      spec.components.kueue.autoCreateQueues=false, already this harness's
#      default) -- the ResourceFlavor/ClusterQueue/LocalQueue themselves are
#      deliberately NOT oc-applied here. They're delivered by the ArgoCD
#      Application below, synced from harness/kueue-gitops/queues.yaml in
#      this repo, proving the queues can be fully GitOps-managed instead of
#      Operator-created.
# Idempotent.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-kueue-scenario-12}"
GITOPS_REPO="${GITOPS_REPO:-https://github.com/jangminjun/openshift-aws-harness.git}"
GITOPS_REVISION="${GITOPS_REVISION:-main}"

echo "=== Demo namespace (Data Science Project) ==="
oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${DEMO_NAMESPACE}
  labels:
    opendatahub.io/dashboard: "true"
YAML

echo "=== ArgoCD Application (GitOps-managed Kueue queues) ==="
oc apply -f - <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kueue-scenario-12-queues
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: ${GITOPS_REPO}
    targetRevision: ${GITOPS_REVISION}
    path: harness/kueue-gitops
  destination:
    server: https://kubernetes.default.svc
    namespace: ${DEMO_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
YAML

echo "Waiting for ArgoCD to sync the queue resources..."
for _ in $(seq 1 20); do
  oc get localqueue demo-local-queue -n "${DEMO_NAMESPACE}" >/dev/null 2>&1 && break
  sleep 15
done
oc get resourceflavor demo-flavor clusterqueue demo-cluster-queue 2>&1
oc get localqueue -n "${DEMO_NAMESPACE}" 2>&1

echo "=== HardwareProfile (wires workbenches to the Kueue LocalQueue) ==="
oc apply -f - <<YAML
apiVersion: infrastructure.opendatahub.io/v1alpha1
kind: HardwareProfile
metadata:
  name: kueue-demo-profile
  namespace: redhat-ods-applications
spec:
  identifiers:
  - identifier: cpu
    displayName: CPU
    resourceType: CPU
    defaultCount: "1"
    minCount: "1"
    maxCount: "2"
  - identifier: memory
    displayName: Memory
    resourceType: Memory
    defaultCount: 2Gi
    minCount: 1Gi
    maxCount: 4Gi
  scheduling:
    type: Queue
    kueue:
      localQueueName: demo-local-queue
YAML

cat <<MSG
Kueue GitOps demo ready.

1) GitOps proof: ArgoCD Application 'kueue-scenario-12-queues' (namespace
   openshift-gitops) owns the ResourceFlavor/ClusterQueue/LocalQueue -- edit
   harness/kueue-gitops/queues.yaml, push, and ArgoCD reconciles the live
   cluster (prune+selfHeal are on). Watch it sync:
     oc get application kueue-scenario-12-queues -n openshift-gitops -w

2) Visibility proof: in project '${DEMO_NAMESPACE}', create 2 workbenches
   using the 'kueue-demo-profile' hardware profile (CPU/memory only, no GPU
   needed -- nominal quota only fits one at a time). The Workbenches tab's
   Status column shows the second as Queued, then Starting once the first
   is stopped.

3) autoCreateQueues toggle (shows the Operator's own queue-creation path):
     oc patch datasciencecluster default-dsc --type merge \\
       -p '{"spec":{"components":{"kueue":{"autoCreateQueues":true}}}}'
   then back to false to hand control back to the ArgoCD Application above:
     oc patch datasciencecluster default-dsc --type merge \\
       -p '{"spec":{"components":{"kueue":{"autoCreateQueues":false}}}}'
MSG
