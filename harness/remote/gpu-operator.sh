#!/usr/bin/env bash
# Runs ON the bastion, after GPU nodes exist. Installs Node Feature Discovery +
# NVIDIA GPU Operator via OperatorHub subscriptions. Idempotent (oc apply).
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

oc apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nfd
  namespace: openshift-nfd
spec:
  targetNamespaces:
  - openshift-nfd
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: stable
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: v1
kind: Namespace
metadata:
  name: nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
  - nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: stable
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
YAML

echo "Waiting for NFD operator CSV..."
for _ in $(seq 1 40); do
  oc get csv -n openshift-nfd 2>/dev/null | grep -qi succeeded && break
  sleep 15
done

oc apply -f - <<'YAML'
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec: {}
YAML

echo "Waiting for GPU Operator CSV..."
for _ in $(seq 1 40); do
  oc get csv -n nvidia-gpu-operator 2>/dev/null | grep -qi succeeded && break
  sleep 15
done

GPU_CSV=$(oc get csv -n nvidia-gpu-operator -o name | grep gpu-operator-certified | head -1)
oc get "$GPU_CSV" -n nvidia-gpu-operator -o jsonpath='{.metadata.annotations.alm-examples}' \
  | jq '.[] | select(.kind=="ClusterPolicy")' \
  | oc apply -f -

echo "NFD + NVIDIA GPU Operator submitted. Check with: oc get pods -n nvidia-gpu-operator"
