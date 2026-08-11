#!/usr/bin/env bash
# Runs ON the bastion. Enables the cluster-wide ClusterAutoscaler singleton
# (idempotent, oc apply). No extra operator install needed — IPI clusters
# ship the cluster-autoscaler-operator already; this just creates its CR.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

MAX_NODES_TOTAL="${MAX_NODES_TOTAL:-20}"

oc apply -f - <<YAML
apiVersion: autoscaling.openshift.io/v1
kind: ClusterAutoscaler
metadata:
  name: default
spec:
  resourceLimits:
    maxNodesTotal: ${MAX_NODES_TOTAL}
  scaleDown:
    enabled: true
    delayAfterAdd: 10m
    delayAfterDelete: 5m
    delayAfterFailure: 3m
    unneededTime: 10m
YAML

echo "ClusterAutoscaler/default applied (maxNodesTotal=${MAX_NODES_TOTAL})."
