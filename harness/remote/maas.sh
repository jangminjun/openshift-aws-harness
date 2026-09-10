#!/usr/bin/env bash
# Runs ON the bastion, after rhoai.sh (RHOAI operator installed, no DSC yet).
# Creates the DataScienceCluster (with kserve.modelsAsService: Managed) and
# the rest of the MaaS stack (RHCL/Kuadrant/Authorino/Limitador, Service
# Mesh 3, Gateway API, PostgreSQL, Redis-backed rate limiting) by delegating
# to RHOAI-Toolkit's install-rhoai-34.sh, which already handles all of that
# (idempotently, with its own retries) rather than reimplementing it here.
#
# Safe to re-run: clones-or-pulls the toolkit, patches modelsAsService onto a
# pre-existing DSC that lacks it (so install-rhoai-34.sh's own
# create_datasciencecluster() -- which only acts when no DSC exists at all --
# doesn't skip past a stale one), then runs the installer with flags matching
# what this harness already did (RHOAI operator, NFD/GPU operator, node
# sizing, admin user).
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

RHOAI_CHANNEL="${RHOAI_CHANNEL:-stable-3.4}"
MAAS_TOOLKIT_REPO="${MAAS_TOOLKIT_REPO:-https://github.com/hyogrin/RHOAI-Toolkit.git}"
MAAS_TOOLKIT_REF="${MAAS_TOOLKIT_REF:-}"
TOOLKIT_DIR="$HOME/RHOAI-Toolkit"

if [ -d "$TOOLKIT_DIR/.git" ]; then
  echo "Updating RHOAI-Toolkit in $TOOLKIT_DIR..."
  git -C "$TOOLKIT_DIR" fetch --quiet origin
  git -C "$TOOLKIT_DIR" checkout --quiet "${MAAS_TOOLKIT_REF:-main}"
  git -C "$TOOLKIT_DIR" pull --quiet --ff-only || true
else
  echo "Cloning RHOAI-Toolkit into $TOOLKIT_DIR..."
  git clone --quiet "$MAAS_TOOLKIT_REPO" "$TOOLKIT_DIR"
  [ -n "$MAAS_TOOLKIT_REF" ] && git -C "$TOOLKIT_DIR" checkout --quiet "$MAAS_TOOLKIT_REF"
fi

# A DSC created by the old rhoai.sh (pre-MaaS, no modelsAsService field) or
# any other non-3.4 source would make install-rhoai-34.sh's own
# create_datasciencecluster() skip past it entirely (it only acts when no DSC
# exists at all) -- merge-patch modelsAsService onto it instead of deleting
# it. A full delete+recreate was tried here initially and it briefly knocked
# the rhods-operator pods into a crash/restart loop (deleting an in-use DSC
# and its DSCInitialization mid-reconcile upset the operator's webhook
# server); a scoped patch changes only the one field that matters and never
# touches the resource's existence, so it can't trigger that.
if oc get datasciencecluster default-dsc &>/dev/null; then
  has_maas=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}' 2>/dev/null || true)
  if [ "$has_maas" != "Managed" ]; then
    echo "Existing DataScienceCluster predates MaaS support -- patching kserve.modelsAsService onto it."
    oc patch datasciencecluster default-dsc --type=merge -p \
      '{"spec":{"components":{"kserve":{"modelsAsService":{"managementState":"Managed"}}}}}'
  fi
fi

echo "Running RHOAI-Toolkit install-rhoai-34.sh (channel ${RHOAI_CHANNEL})..."
cd "$TOOLKIT_DIR/scripts"
chmod +x install-rhoai-34.sh
# --skip-admin-user / --skip-node-scaling: this harness already created the
# admin user (create-admin-user) and sized the cluster (config.env
# WORKER_TYPE/WORKER_REPLICAS) -- don't let the toolkit second-guess either.
# `yes ""` feeds a blank line to any interactive `read -p` the toolkit hits
# (e.g. the SearXNG MCP deployment mode prompt) so it takes that prompt's
# own default non-interactively instead of dying on EOF under `set -e`.
# `yes` itself always dies of SIGPIPE (128+13=141) once the installer stops
# reading, and `pipefail` propagates that as the pipeline's status even when
# install-rhoai-34.sh itself succeeded -- worse, `set -e` (active for this
# whole script) would abort right at that pipeline before a later
# `exit "${PIPESTATUS[1]}"` line ever ran. Disable errexit for just this one
# command so it can't do that, then report install-rhoai-34.sh's own exit
# code instead of the pipeline's.
set +e
yes "" | ./install-rhoai-34.sh --skip-admin-user --skip-node-scaling --channel "$RHOAI_CHANNEL"
status="${PIPESTATUS[1]}"
set -e
exit "$status"
