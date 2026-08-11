#!/usr/bin/env bash
# Runs ON the bastion, after a Neuron (inf2/trn1) worker node exists.
# Installs Kernel Module Management (KMM, needed to build the aws-neuronx
# driver against RHCOS), the AWS Neuron Operator (community operator,
# k8s.aws/DeviceConfig), a NodeFeatureRule so NFD labels Neuron nodes, and a
# DeviceConfig CR to drive the driver/device-plugin/scheduler deployment.
#
# NOTE: aws-neuron-operator is a community (not Red Hat certified) operator,
# publicly documented against OCP 4.19+ as of early 2026. Treat this as a
# pilot on 4.22 and verify `oc get pods -n aws-neuron-operator` carefully.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

# --- 1. Kernel Module Management operator (builds the neuron.ko driver) ---
oc apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-kmm
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-kmm
  namespace: openshift-kmm
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kernel-module-management
  namespace: openshift-kmm
spec:
  channel: stable
  name: kernel-module-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML

echo "Waiting for KMM operator CSV..."
for _ in $(seq 1 40); do
  oc get csv -n openshift-kmm 2>/dev/null | grep -qi succeeded && break
  sleep 15
done

# --- 2. NodeFeatureRule so NFD labels Neuron nodes (feature.node.kubernetes.io/aws-neuron) ---
# PCI vendor 1d0f = Amazon.com. Device IDs cover Inferentia/Inferentia2/Trainium.
oc apply -f - <<'YAML'
apiVersion: nfd.openshift.io/v1alpha1
kind: NodeFeatureRule
metadata:
  name: aws-neuron
  namespace: openshift-nfd
spec:
  rules:
  - name: aws-neuron-device
    labels:
      feature.node.kubernetes.io/aws-neuron: "true"
    matchFeatures:
    - feature: pci.device
      matchExpressions:
        vendor: {op: In, value: ["1d0f"]}
        device: {op: In, value: ["7064", "7065", "7066", "7067", "7164", "7264", "7364"]}
YAML

# --- 3. AWS Neuron Operator ---
oc apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: aws-neuron-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: aws-neuron-operator
  namespace: aws-neuron-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: aws-neuron-operator
  namespace: aws-neuron-operator
spec:
  channel: Stable
  name: aws-neuron-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
YAML

echo "Waiting for AWS Neuron Operator CSV..."
for _ in $(seq 1 40); do
  oc get csv -n aws-neuron-operator 2>/dev/null | grep -qi succeeded && break
  sleep 15
done

# --- 4. DeviceConfig (pulled from the installed CSV's alm-examples, known-good as of v1.2.0) ---
NEURON_CSV=$(oc get csv -n aws-neuron-operator -o name | grep aws-neuron-operator | head -1)
oc get "$NEURON_CSV" -n aws-neuron-operator -o jsonpath='{.metadata.annotations.alm-examples}' \
  | jq '.[] | select(.kind=="DeviceConfig") | .spec.selector = {"feature.node.kubernetes.io/aws-neuron": "true"}' \
  | jq --arg name "device-config" '{apiVersion:"k8s.aws/v1beta1", kind:"DeviceConfig", metadata:{name:$name, namespace:"aws-neuron-operator"}, spec:.spec}' \
  | oc apply -f -

echo "KMM + AWS Neuron Operator + DeviceConfig submitted."
echo "Check with: oc get pods -n aws-neuron-operator ; oc get pods -n openshift-kmm"
echo "Once the driver DaemonSet is Running, check: oc get node <neuron-node> -o jsonpath='{.status.allocatable}' | jq"
