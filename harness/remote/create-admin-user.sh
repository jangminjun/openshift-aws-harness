#!/usr/bin/env bash
# Runs ON the bastion. Adds an HTPasswd identity provider with one
# cluster-admin user, so you don't have to hand out the kubeadmin password.
# Idempotent: re-running with the same username just resets that user's password.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

ADMIN_USERNAME="${ADMIN_USERNAME:?set ADMIN_USERNAME}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?set ADMIN_PASSWORD}"

command -v htpasswd >/dev/null 2>&1 || sudo dnf install -y httpd-tools >/tmp/dnf-htpasswd.log 2>&1

HTPASSWD_FILE="$HOME/ocp-install/users.htpasswd"
if [ -f "$HTPASSWD_FILE" ]; then
  htpasswd -B -b "$HTPASSWD_FILE" "$ADMIN_USERNAME" "$ADMIN_PASSWORD"
else
  htpasswd -c -B -b "$HTPASSWD_FILE" "$ADMIN_USERNAME" "$ADMIN_PASSWORD"
fi

oc create secret generic htpass-secret --from-file=htpasswd="$HTPASSWD_FILE" \
  -n openshift-config --dry-run=client -o yaml | oc apply -f -

oc apply -f - <<YAML
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: htpasswd_provider
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpass-secret
YAML

oc adm policy add-cluster-role-to-user cluster-admin "$ADMIN_USERNAME" >/dev/null

echo "Waiting for the oauth-openshift pods to roll out with the new identity provider..."
for _ in $(seq 1 30); do
  oc get pods -n openshift-authentication 2>/dev/null | grep -q Running && break
  sleep 10
done

echo "Admin user '${ADMIN_USERNAME}' created with cluster-admin. Login:"
echo "  oc login -u ${ADMIN_USERNAME} -p '${ADMIN_PASSWORD}' https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443"
