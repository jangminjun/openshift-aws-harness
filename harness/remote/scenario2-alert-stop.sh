#!/usr/bin/env bash
# Runs ON the bastion. Deletes the scenario 2 (GPU overheat alert) demo pod.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-alert-scenario-2}"

oc delete pod gpu-burn -n "${DEMO_NAMESPACE}" --ignore-not-found
