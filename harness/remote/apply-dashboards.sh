#!/usr/bin/env bash
# Runs ON the bastion, after grafana-operator.sh. Wraps the Tier1/Tier2
# dashboard JSON (already scp'd to ~/ocp-install/) into GrafanaDashboard CRs
# and applies them, resolving ${DS_THANOS} to the thanos-querier datasource.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:?set MONITORING_NAMESPACE}"

apply_dashboard() {
  local name="$1" title="$2" json_path="$3"
  jq -n --arg name "$name" --arg title "$title" --rawfile dash "$json_path" '
    {
      apiVersion: "grafana.integreatly.org/v1beta1",
      kind: "GrafanaDashboard",
      metadata: { name: $name, namespace: env.MONITORING_NAMESPACE },
      spec: {
        instanceSelector: { matchLabels: { dashboards: "gpu-grafana" } },
        datasources: [ { inputName: "DS_THANOS", datasourceName: "thanos-querier" } ],
        json: $dash
      }
    }' | oc apply -f -
  echo "Applied GrafanaDashboard/$name ($title)"
}

apply_dashboard gpu-tier1-global "Tier1 Infra Global View" "$HOME/ocp-install/tier1-global.json"
apply_dashboard gpu-tier2-tenant "Tier2 Project Team View" "$HOME/ocp-install/tier2-tenant.json"
