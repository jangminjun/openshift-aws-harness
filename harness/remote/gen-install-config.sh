#!/usr/bin/env bash
# Runs ON the bastion. Generates ~/ocp-install/install-config.yaml from env vars
# passed in by harness.sh (CLUSTER_NAME, AWS_REGION, BASE_DOMAIN, MASTER_*, WORKER_*).
set -euo pipefail

[ -f ~/ocp-install/pull-secret.json ] || { echo "pull-secret.json missing on bastion" >&2; exit 1; }

PULL_SECRET=$(cat ~/ocp-install/pull-secret.json)
SSH_PUBKEY=$(cat ~/.ssh/ocp-cluster-key.pub)

cat > ~/ocp-install/install-config.yaml <<YAML
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
platform:
  aws:
    region: ${AWS_REGION}
controlPlane:
  name: master
  replicas: ${MASTER_REPLICAS}
  platform:
    aws:
      type: ${MASTER_TYPE}
compute:
- name: worker
  replicas: ${WORKER_REPLICAS}
  platform:
    aws:
      type: ${WORKER_TYPE}
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
pullSecret: '${PULL_SECRET}'
sshKey: |
  ${SSH_PUBKEY}
YAML

cp ~/ocp-install/install-config.yaml ~/ocp-install/install-config.yaml.bak
echo "install-config.yaml written ($(wc -l < ~/ocp-install/install-config.yaml) lines)"
