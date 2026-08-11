#!/usr/bin/env bash
# Runs ON the bastion. Installs openshift-install/oc/kubectl (latest stable) if missing.
set -euo pipefail

sudo dnf install -y tar gzip jq git >/tmp/dnf.log 2>&1

if ! command -v openshift-install >/dev/null 2>&1; then
  cd /tmp
  curl -sL -o openshift-install-linux.tar.gz \
    https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest/openshift-install-linux.tar.gz
  curl -sL -o openshift-client-linux.tar.gz \
    https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest/openshift-client-linux.tar.gz
  tar xzf openshift-install-linux.tar.gz
  tar xzf openshift-client-linux.tar.gz
  sudo mv openshift-install oc kubectl /usr/local/bin/
  rm -f openshift-install-linux.tar.gz openshift-client-linux.tar.gz README.md
fi

mkdir -p ~/ocp-install
[ -f ~/.ssh/ocp-cluster-key ] || ssh-keygen -t ed25519 -f ~/.ssh/ocp-cluster-key -N "" -C "ocp-cluster" -q

echo "openshift-install: $(openshift-install version | head -1)"
echo "oc: $(oc version --client | head -1)"
