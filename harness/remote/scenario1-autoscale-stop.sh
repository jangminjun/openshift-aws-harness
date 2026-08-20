#!/usr/bin/env bash
# Runs ON the bastion. Deletes the scenario 1 (worker autoscaling) demo pods.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-gpu-autoscale-scenario-1}"

oc delete pod training-job-1 training-job-2 -n "${DEMO_NAMESPACE}" --ignore-not-found
