#!/bin/bash
# Step 2: Install the DSF addon on the hub and patch for RHACM
# Usage: bash scripts/02-install-addon.sh

set -euo pipefail

echo "=== Step 2: Install DSF Addon ==="

# Add Helm repo
helm repo add ocm https://open-cluster-management-io.github.io/helm-charts 2>/dev/null || true
helm repo update

# Install (or upgrade if already installed)
if helm status dynamic-scoring-framework -n open-cluster-management &>/dev/null; then
  echo "DSF addon already installed, upgrading..."
  helm upgrade dynamic-scoring-framework ocm/dynamic-scoring-framework \
    -n open-cluster-management
else
  echo "Installing DSF addon..."
  helm install dynamic-scoring-framework ocm/dynamic-scoring-framework \
    -n open-cluster-management --create-namespace
fi

# Wait for ClusterManagementAddOn to be created by the controller
echo ""
echo "Waiting for ClusterManagementAddOn to appear..."
for i in $(seq 1 30); do
  if oc get clustermanagementaddon dynamic-scoring-framework -n open-cluster-management &>/dev/null; then
    echo "ClusterManagementAddOn ready."
    break
  fi
  if [ "$i" = "30" ]; then
    echo "WARNING: ClusterManagementAddOn not found after 60s. You may need to patch manually."
  fi
  sleep 2
done

# Patch for RHACM global placement
# The helm chart creates a Placement in open-cluster-management, but on RHACM the
# MultiClusterHub operator owns that namespace and removes resources it doesn't manage.
# Redirect to the pre-existing global placement in open-cluster-management-global-set.
echo ""
echo "Patching ClusterManagementAddOn for RHACM global placement..."
oc patch clustermanagementaddon dynamic-scoring-framework --type=json -p='[
  {"op": "replace", "path": "/spec/installStrategy/placements/0/name", "value": "global"},
  {"op": "replace", "path": "/spec/installStrategy/placements/0/namespace", "value": "open-cluster-management-global-set"}
]'

# Newer chart versions already wire AddonDeploymentConfig via installStrategy
# (agentInstallNamespace=dynamic-scoring). Skip obsolete supportedConfigs patch.

echo ""
echo "Waiting for addon to deploy to managed clusters..."
echo "Run: oc get managedclusteraddon -A | grep dynamic-scoring-framework"
echo ""
oc get managedclusteraddon -A | grep dynamic-scoring-framework || true
